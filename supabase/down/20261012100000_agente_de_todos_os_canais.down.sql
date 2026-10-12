-- Desfaz o D76. A ordem: os leitores voltam primeiro ao que eram, depois saem
-- as funções novas, a tabela e as colunas — nenhum corpo fica apontando para o
-- que não existe.
--
-- O agente de todos os canais não tem para onde voltar: antes do D76 todo
-- agente tinha canal. Este down RECUSA enquanto existir um — apagá-lo em
-- silêncio seria tirar um agente de campanhas que contam com ele. Quem quiser
-- mesmo voltar desliga e remove esses agentes primeiro, sabendo o que faz.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM agents WHERE canal IS NULL) THEN
    RAISE EXCEPTION 'há agentes de todos os canais (canal nulo): o D76 não volta com eles no banco'
      USING ERRCODE = 'restrict_violation';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.respostas_para_o_agente(p_limite integer DEFAULT 20)
RETURNS TABLE(
  message_event_id uuid, tenant_id uuid, contact_id uuid, resposta_em timestamptz,
  canal canal, texto text, regra text,
  agent_id uuid, agente_nome text, papel text, descricao text, instrucoes text,
  escalar_quando text, limite_trocas integer, proibido text[], tamanho_maximo integer,
  credencial_id uuid, provedor text, modelo text, provedor_compoe boolean,
  contato_nome text, metadados jsonb, campanha text, historico jsonb, rascunhos_anteriores integer,
  autonomo boolean, composicoes_hoje integer, teto integer)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  WITH respostas AS (
    SELECT me.id, me.tenant_id, e.contact_id, me.ocorrido_em, m.canal, me.payload ->> 'texto' AS texto,
           e.campaign_id, m.contact_identity_id,
           row_number() OVER (PARTITION BY me.tenant_id, e.contact_id
                              ORDER BY me.ocorrido_em DESC, me.criado_em DESC) AS n
      FROM message_events me
      JOIN messages m    ON m.tenant_id = me.tenant_id AND m.id = me.message_id
      JOIN enrollments e ON e.tenant_id = m.tenant_id AND e.id = m.enrollment_id
     WHERE me.tipo = 'respondido'
       AND jsonb_typeof(me.payload -> 'texto') = 'string'
       AND me.ocorrido_em > now() - interval '7 days'
  )
  SELECT r.id, r.tenant_id, r.contact_id, r.ocorrido_em, r.canal, r.texto,
         (SELECT x.acao::text FROM privado.regra_da_resposta(r.tenant_id, r.texto) x LIMIT 1),
         a.id, a.nome, a.papel, a.descricao, a.instrucoes,
         a.escalar_quando, a.limite_trocas, a.proibido, a.tamanho_maximo,
         ac.id, ac.provedor, ac.modelo, coalesce(pc.tem_adapter AND ac.ativo, false),
         c.nome, c.metadados, camp.nome,
         -- A conversa até aqui, nos dois sentidos, mais antiga primeiro. Só o
         -- que saiu de verdade: rascunho de simulado não é conversa. A
         -- mensagem do agente entra como "nós", que é o que ela é.
         (SELECT coalesce(jsonb_agg(h.item ORDER BY h.quando), '[]'::jsonb) FROM (
            SELECT jsonb_build_object('de', 'nos', 'texto', m2.conteudo) AS item, m2.criado_em AS quando
              FROM messages m2 JOIN enrollments e2 ON e2.tenant_id = m2.tenant_id AND e2.id = m2.enrollment_id
             WHERE m2.tenant_id = r.tenant_id AND e2.contact_id = r.contact_id
               AND m2.status NOT IN ('simulado', 'cancelado', 'falha', 'pendente')
            UNION ALL
            SELECT jsonb_build_object('de', 'pessoa', 'texto', me2.payload ->> 'texto'), me2.ocorrido_em
              FROM message_events me2
              JOIN messages m3    ON m3.tenant_id = me2.tenant_id AND m3.id = me2.message_id
              JOIN enrollments e3 ON e3.tenant_id = m3.tenant_id AND e3.id = m3.enrollment_id
             WHERE me2.tenant_id = r.tenant_id AND e3.contact_id = r.contact_id
               AND me2.tipo = 'respondido' AND jsonb_typeof(me2.payload -> 'texto') = 'string'
            ORDER BY 2 DESC LIMIT 20) h),
         -- As trocas da conversa: texto pronto que saiu ou ficou com uma
         -- pessoa. O devolvido não conta — ele não foi uma troca.
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.contact_id = r.contact_id
             AND x.situacao = 'pronto' AND x.envio <> 'devolvido'),
         a.autonomo,
         -- (d): composições do cliente nas últimas 24h. Conta o que chamou o
         -- modelo; recusa, limite e falta de credencial não custaram nada.
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.criado_em > now() - interval '1 day'
             AND x.situacao IN ('pronto', 'escalar', 'bloqueado', 'erro')),
         t.teto_agente_dia
    FROM respostas r
    JOIN tenants t    ON t.id = r.tenant_id
    JOIN contacts c   ON c.tenant_id = r.tenant_id AND c.id = r.contact_id
    JOIN campaigns camp ON camp.tenant_id = r.tenant_id AND camp.id = r.campaign_id
    JOIN campaign_agents ca ON ca.tenant_id = r.tenant_id AND ca.campaign_id = r.campaign_id AND ca.canal = r.canal
    JOIN agents a     ON a.tenant_id = r.tenant_id AND a.id = ca.agent_id AND a.ativo
    -- A conta escolhida na campanha vale sobre a do agente (D68): o agente é
    -- uma persona que várias campanhas dividem, e a conta é decisão de cada uma.
    LEFT JOIN ai_credentials ac ON ac.tenant_id = a.tenant_id
                               AND ac.id = coalesce(camp.ai_credential_id, a.ai_credential_id)
    LEFT JOIN ai_provider_catalog pc ON pc.slug = ac.provedor
    JOIN contact_identities ci ON ci.tenant_id = r.tenant_id AND ci.id = r.contact_identity_id
   WHERE r.n = 1
     AND NOT EXISTS (SELECT 1 FROM rascunhos x WHERE x.tenant_id = r.tenant_id AND x.message_event_id = r.id)
     -- Nem rascunho para quem pediu para sair: um texto pronto é convite a
     -- uma pessoa mandar — e agora ao motor. A pessoa inteira e o endereço.
     AND NOT esta_suprimido(r.tenant_id, r.contact_id, r.canal, ci.valor_norm)
   ORDER BY r.ocorrido_em
   LIMIT least(coalesce(p_limite, 20), 100);
$$;

CREATE OR REPLACE FUNCTION public.agente_do_canal(p_campaign_id uuid, p_canal canal)
RETURNS agents
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $function$
  SELECT a.* FROM campaign_agents ca JOIN agents a ON a.id = ca.agent_id
   WHERE ca.campaign_id = p_campaign_id AND ca.canal = p_canal AND a.ativo;
$function$;

DROP FUNCTION IF EXISTS public.fila_do_agente(integer);
DROP FUNCTION IF EXISTS public.criar_agente(uuid, text, text, text, text, text, text, text, text, text, integer,
                                            text[], integer, uuid, boolean, canal[], uuid, canal[]);
DROP FUNCTION IF EXISTS public.quem_responde(uuid, uuid);
DROP FUNCTION IF EXISTS privado.agente_que_responde(uuid, uuid, canal);

ALTER POLICY campaign_agents_del ON campaign_agents USING (privado.pode_administrar(tenant_id));

DROP TRIGGER IF EXISTS campaign_agents_vigencia ON campaign_agents;
DROP TABLE IF EXISTS agentes_por_canal;
DROP FUNCTION IF EXISTS privado.renovar_vigencia_do_agente();
DROP FUNCTION IF EXISTS privado.validar_agente_do_canal();

-- "Ninguém nesta campanha" não existia: a linha sai, e sem linha ninguém
-- responde — que é o mesmo efeito de antes.
DELETE FROM campaign_agents WHERE agent_id IS NULL;
ALTER TABLE campaign_agents ALTER COLUMN agent_id SET NOT NULL;
ALTER TABLE campaign_agents DROP COLUMN IF EXISTS vigente_desde;

UPDATE agents SET tamanho_maximo = 700 WHERE tamanho_maximo IS NULL;
ALTER TABLE agents
  DROP CONSTRAINT IF EXISTS agents_persona_slug,
  DROP CONSTRAINT IF EXISTS agents_objetivo_slug,
  DROP CONSTRAINT IF EXISTS agents_sem_canal_tem_objetivo,
  DROP CONSTRAINT IF EXISTS agents_contexto_do_agente_novo,
  DROP COLUMN IF EXISTS persona,
  DROP COLUMN IF EXISTS objetivo,
  DROP COLUMN IF EXISTS tom,
  DROP COLUMN IF EXISTS contexto,
  ALTER COLUMN tamanho_maximo SET NOT NULL,
  ALTER COLUMN canal SET NOT NULL;

COMMENT ON COLUMN agents.canal IS NULL;
COMMENT ON COLUMN agents.tamanho_maximo IS NULL;

-- A grade volta à do D75: as colunas do D76 deixam de existir, o DELETE de
-- agents e a escrita de tabela inteira de campaign_agents voltam.
GRANT DELETE ON agents TO authenticated;
GRANT INSERT, UPDATE ON campaign_agents TO authenticated;
GRANT INSERT, UPDATE, DELETE ON opt_out_termos, recusa_termos TO authenticated;

CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  -- D54: por coluna onde a tela escreve.
  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id, ai_credential_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  -- D75: `rampa_dias` e `rampa_inicial` entram; o andamento da rampa, não.
  GRANT UPDATE (apelido, quota_diaria, estado, rampa_dias, rampa_inicial)
    ON sender_accounts TO authenticated;

  -- D62: a conta nasce pela tela com o que a tela preenche, e só. Com INSERT
  -- de tabela inteira dava para nascer com `credenciais_secret_id` apontando
  -- para o segredo de OUTRO cliente — o worker mandaria pela conta dele, o
  -- D59 na quarta tabela de credencial. E DELETE apagava em cascata as
  -- mensagens e os eventos da conta: história que é append-only (D62).
  REVOKE INSERT, DELETE ON sender_accounts FROM authenticated;
  GRANT INSERT (tenant_id, canal, provedor, identificador, apelido,
                tipo_permitido, quota_diaria, config)
    ON sender_accounts TO authenticated;

  -- D63: a blacklist é da tela, menos o dono da linha e a origem dela.
  REVOKE UPDATE ON blacklist_termos, blacklist_dominios FROM authenticated;
  GRANT UPDATE (termo, exige_uma_de, acao, nota, ativo) ON blacklist_termos TO authenticated;
  GRANT UPDATE (nota, ativo) ON blacklist_dominios TO authenticated;

  -- D54: as três do motor, leitura sim, escrita nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;

  -- D57: o funil. Renomear e reordenar estágio é da tela; mover card é de
  -- `mover_deal`, e sem esta revogação "porta única" seria convenção.
  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;

  -- D59, daqui para baixo.
  --
  -- As duas tabelas de credencial: a tela liga e desliga, e nada mais. Quem
  -- grava é a função DEFINER, que não usa privilégio do cliente.
  --
  -- O INSERT vai embora junto do UPDATE largo, e não é zelo a mais: com ele,
  -- dava para criar a linha com `credencial_secret_id` escolhido à mão,
  -- apontando para um segredo do Vault que não é desta conexão. Passar pela
  -- função é o que garante que o ponteiro nasce de `guardar_segredo`.
  REVOKE INSERT, UPDATE, DELETE ON ai_credentials, crm_connections FROM authenticated;
  GRANT UPDATE (ativo) ON ai_credentials TO authenticated;
  GRANT UPDATE (ativo) ON crm_connections TO authenticated;

  -- Servidor de provedor: nenhuma tela escreve. `salvar_servidor_provedor` é
  -- DEFINER, e `admin_secret_id` é ponteiro de Vault pelo mesmo motivo acima.
  REVOKE INSERT, UPDATE, DELETE ON provider_servers FROM authenticated;

  -- Catálogo é do produto, não do cliente. Nos três o RLS já recusa por falta
  -- de política de DML, e é justamente por isso que a revogação entra: confiar
  -- que "não tem política" é o mesmo que "não tem privilégio" é o D54 pela
  -- terceira vez. Quem lê continua lendo — `tem_adapter` e `campos` são o que
  -- a tela desenha.
  REVOKE INSERT, UPDATE, DELETE
      ON channel_provider_catalog, ai_provider_catalog, crm_provider_catalog
    FROM authenticated;

  -- D64. Vínculo e estrutura são do motor: a tela lê. Um vínculo escrito à
  -- mão é o fato de uma pessoa indo para o card de outra; uma estrutura
  -- escrita à mão é a tela oferecendo fase que não existe.
  REVOKE INSERT, UPDATE, DELETE ON crm_vinculos, crm_estruturas FROM authenticated;

  -- Ação e fonte são da tela, por coluna. Fora fica o dono da linha e, na
  -- fonte, o que a execução grava — `ultimo_resultado` escrito pela tela
  -- seria o painel dizendo que a fonte rodou quando não rodou.
  REVOKE INSERT, UPDATE ON crm_acoes, crm_fontes FROM authenticated;
  GRANT INSERT (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id, alvo_rotulo, valor, ordem, ativo)
    ON crm_acoes TO authenticated;
  GRANT UPDATE (alvo_id, alvo_rotulo, valor, ordem, ativo) ON crm_acoes TO authenticated;
  GRANT INSERT (tenant_id, conexao_id, nome, pipe_id, pipe_rotulo, fases, mapa,
                campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  GRANT UPDATE (nome, fases, mapa, campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  -- D66. O agente é da tela, por coluna: o que ele diz, quando passa para
  -- uma pessoa, o que nunca escreve e com que credencial. Fora fica o dono da
  -- linha e `pronto`, que é a marca de agente do catálogo. D69: e se ele
  -- responde sozinho.
  REVOKE UPDATE ON agents FROM authenticated;
  GRANT UPDATE (nome, papel, descricao, instrucoes, ai_credential_id, escalar_quando,
                limite_trocas, ativo, proibido, tamanho_maximo, autonomo)
    ON agents TO authenticated;

  -- O rascunho é do worker: a tela lê. Escrito à mão, seria um texto que
  -- parece ter sido composto pelo agente com os freios dele, sem ter sido —
  -- e, desde o D69, um `envio = 'fila'` sem mensagem nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;
END;
$function$;

-- Dentro de DO: migration que imprime resultado polui o stdout que o
-- `tests/run.sh` captura para nomear o banco.
DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
