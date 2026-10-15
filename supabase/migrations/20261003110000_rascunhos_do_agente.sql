-- O agente compõe; uma pessoa decide (D66).
--
-- O pedido é um motor autônomo, com agentes configuráveis: instrução, o que
-- nunca dizer, quando passar para uma pessoa. `PROPOSTA-CONVERSA.md` mostrou
-- por que o agente que RESPONDE sozinho encosta em três garantias — a
-- invariante 4, o gate do D40 e a chave `(enrollment_id, step_id)` — e
-- recomendou começar pelo que não encosta em nenhuma: o agente escreve o
-- rascunho, e a pessoa manda pelo aplicativo do canal. É isto.
--
-- Nada aqui envia. Não há linha nova em `messages`, nenhum caminho de envio
-- novo, e a invariante 4 continua absoluta. O que existe de novo é:
--
--   rascunhos   uma linha por resposta que o agente leu, com o texto ou com
--               o motivo de não haver texto — recusa, pedido de pessoa,
--               freio, limite de trocas, credencial que falta. "Sem
--               rascunho" nunca é silêncio: é uma situação com nome.
--   agents      ganha o que a operação pediu e não tinha onde morar: frases
--               que o agente NUNCA escreve (`proibido`) e o tamanho máximo.
--               E `limite_trocas` e `escalar_quando`, que existiam sem leitor
--               (PROPOSTA §6), passam a ser lidos.
--   catálogo    `ai_provider_catalog.tem_adapter`: quem sabe compor. Sem
--               esta coluna, um agente com credencial do Gemini apareceria
--               como "sem rascunho" sem ninguém dizer por quê (D31).
--
-- Quem lê a resposta para rascunhar é o worker, pela função abaixo, e ela
-- já exclui quem está suprimido: nem rascunho para quem pediu para sair,
-- porque rascunho pronto é convite a uma pessoa mandar.
--
-- Sem barra invertida (D32).
-- Reversível: supabase/down/20261003110000_rascunhos_do_agente.down.sql

-- ---------------------------------------------------------------------------
-- Quem sabe compor
-- ---------------------------------------------------------------------------

ALTER TABLE ai_provider_catalog ADD COLUMN tem_adapter boolean NOT NULL DEFAULT false;

-- Os que falam o protocolo do Claude ou o de "chat completions". O Gemini
-- fica de fora: protocolo próprio, e adapter que ninguém escreveu é promessa.
UPDATE ai_provider_catalog SET tem_adapter = true
 WHERE slug IN ('anthropic', 'openai', 'deepseek', 'openrouter', 'perplexity', 'compativel');

-- ---------------------------------------------------------------------------
-- O que o agente nunca faz
-- ---------------------------------------------------------------------------

ALTER TABLE agents
  ADD COLUMN proibido text[] NOT NULL DEFAULT '{}',
  ADD COLUMN tamanho_maximo integer NOT NULL DEFAULT 700,
  ADD CONSTRAINT agents_tamanho_maximo CHECK (tamanho_maximo BETWEEN 80 AND 4000);

COMMENT ON COLUMN agents.proibido IS
  'Frases que o rascunho nunca contém. Conferidas em código depois da composição, '
  'não só pedidas no texto da instrução: o modelo pode desobedecer, o freio não.';

-- ---------------------------------------------------------------------------
-- O rascunho
-- ---------------------------------------------------------------------------

CREATE TABLE rascunhos (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  message_event_id uuid NOT NULL,
  contact_id       uuid NOT NULL,
  agent_id         uuid,
  -- O instante da resposta, igual ao `ocorrido_em` do evento: é por ele e
  -- pelo contato que a tela de Respostas acha o rascunho de cada linha.
  resposta_em      timestamptz NOT NULL,
  situacao         text NOT NULL CHECK (situacao IN
                     ('pronto', 'recusa', 'escalar', 'bloqueado', 'limite', 'sem_credencial', 'erro')),
  texto            text,
  motivo           text,
  modelo           text,
  criado_em        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rascunhos_tenant_id_uk UNIQUE (tenant_id, id),
  -- Uma resposta, um rascunho. O worker que roda duas vezes não paga duas
  -- chamadas de modelo nem mostra dois textos.
  CONSTRAINT rascunhos_evento_uk UNIQUE (tenant_id, message_event_id),
  CONSTRAINT rascunhos_texto_so_pronto CHECK ((situacao = 'pronto') = (texto IS NOT NULL)),
  CONSTRAINT rascunhos_evento_fkey FOREIGN KEY (tenant_id, message_event_id)
    REFERENCES message_events (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT rascunhos_contato_fkey FOREIGN KEY (tenant_id, contact_id)
    REFERENCES contacts (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT rascunhos_agente_fkey FOREIGN KEY (tenant_id, agent_id)
    REFERENCES agents (tenant_id, id) ON DELETE SET NULL (agent_id)
);
CREATE INDEX rascunhos_contato_idx ON rascunhos (tenant_id, contact_id, resposta_em);

ALTER TABLE rascunhos ENABLE ROW LEVEL SECURITY;
ALTER TABLE rascunhos FORCE ROW LEVEL SECURITY;
CREATE POLICY rascunhos_sel ON rascunhos FOR SELECT
  USING (privado.pertence_ao_tenant(tenant_id));

-- ---------------------------------------------------------------------------
-- O que o worker lê e grava
-- ---------------------------------------------------------------------------

-- Respostas que esperam rascunho: a mais recente de cada pessoa, com texto,
-- dos últimos sete dias, de quem NÃO está suprimido, numa campanha que tem
-- agente no canal. Junto vem tudo o que o agente precisa — e nada além.
CREATE FUNCTION public.respostas_para_rascunhar(p_limite integer DEFAULT 20)
RETURNS TABLE(
  message_event_id uuid, tenant_id uuid, contact_id uuid, resposta_em timestamptz,
  canal canal, texto text, regra text,
  agent_id uuid, agente_nome text, papel text, descricao text, instrucoes text,
  escalar_quando text, limite_trocas integer, proibido text[], tamanho_maximo integer,
  credencial_id uuid, provedor text, modelo text, provedor_compoe boolean,
  contato_nome text, metadados jsonb, campanha text, historico jsonb, rascunhos_anteriores integer)
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
         -- que saiu de verdade: rascunho de simulado não é conversa.
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
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.contact_id = r.contact_id AND x.situacao = 'pronto')
    FROM respostas r
    JOIN contacts c   ON c.tenant_id = r.tenant_id AND c.id = r.contact_id
    JOIN campaigns camp ON camp.tenant_id = r.tenant_id AND camp.id = r.campaign_id
    JOIN campaign_agents ca ON ca.tenant_id = r.tenant_id AND ca.campaign_id = r.campaign_id AND ca.canal = r.canal
    JOIN agents a     ON a.tenant_id = r.tenant_id AND a.id = ca.agent_id AND a.ativo
    LEFT JOIN ai_credentials ac ON ac.tenant_id = a.tenant_id AND ac.id = a.ai_credential_id
    LEFT JOIN ai_provider_catalog pc ON pc.slug = ac.provedor
    JOIN contact_identities ci ON ci.tenant_id = r.tenant_id AND ci.id = r.contact_identity_id
   WHERE r.n = 1
     AND NOT EXISTS (SELECT 1 FROM rascunhos x WHERE x.tenant_id = r.tenant_id AND x.message_event_id = r.id)
     -- Nem rascunho para quem pediu para sair: um texto pronto é convite a
     -- uma pessoa mandar. A pessoa inteira e o endereço, como no despacho.
     AND NOT esta_suprimido(r.tenant_id, r.contact_id, r.canal, ci.valor_norm)
   ORDER BY r.ocorrido_em
   LIMIT least(coalesce(p_limite, 20), 100);
$$;

CREATE FUNCTION public.registrar_rascunho(
  p_message_event_id uuid, p_agent_id uuid, p_situacao text,
  p_texto text DEFAULT NULL, p_motivo text DEFAULT NULL, p_modelo text DEFAULT NULL)
RETURNS void
LANGUAGE sql
SET search_path TO 'public', 'privado'
AS $$
  INSERT INTO rascunhos (tenant_id, message_event_id, contact_id, agent_id, resposta_em,
                         situacao, texto, motivo, modelo)
  SELECT me.tenant_id, me.id, e.contact_id, p_agent_id, me.ocorrido_em,
         p_situacao, p_texto, left(p_motivo, 1000), p_modelo
    FROM message_events me
    JOIN messages m    ON m.tenant_id = me.tenant_id AND m.id = me.message_id
    JOIN enrollments e ON e.tenant_id = m.tenant_id AND e.id = m.enrollment_id
   WHERE me.id = p_message_event_id
  ON CONFLICT (tenant_id, message_event_id) DO NOTHING;
$$;

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.respostas_para_rascunhar(integer)',
    'public.registrar_rascunho(uuid, uuid, text, text, text, text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', alvo);
    END IF;
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON rascunhos FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT SELECT ON rascunhos TO authenticated';
  END IF;
END;
$$;

-- A grade estreita, regenerada a partir do corpo do D64 (D59), com o agente
-- e o rascunho no fim.
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
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;

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
  -- linha e `pronto`, que é a marca de agente do catálogo.
  REVOKE UPDATE ON agents FROM authenticated;
  GRANT UPDATE (nome, papel, descricao, instrucoes, ai_credential_id, escalar_quando,
                limite_trocas, ativo, proibido, tamanho_maximo)
    ON agents TO authenticated;

  -- O rascunho é do worker: a tela lê. Escrito à mão, seria um texto que
  -- parece ter sido composto pelo agente com os freios dele, sem ter sido.
  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;
END;
$function$;

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
