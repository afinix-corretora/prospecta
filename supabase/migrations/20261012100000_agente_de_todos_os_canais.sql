-- O agente de todos os canais (D76).
--
-- Pedido do usuário em 12/10: criar o agente pela plataforma escolhendo
-- persona e objetivo, ajustar o texto, e "apenas selecioná-lo para o canal
-- desejado, variando apenas a funcionalidade de acordo com cada plataforma".
--
-- O que muda no modelo:
--
--   agents.canal    passa a aceitar NULL: o agente de todos os canais. O que
--                   muda de canal para canal é do PRODUTO e entra na hora de
--                   compor (`adapters/prompt-do-agente.ts`), não no texto do
--                   agente. Os agentes de antes continuam com canal e só
--                   servem a ele — o gatilho de `campaign_agents` já recusa
--                   canal diferente e aceita o nulo, sem precisar ser recriado.
--   persona, objetivo, tom, contexto
--                   a persona e o objetivo do catálogo (constantes no módulo
--                   puro, que a tela e o setup leem) viram CÓPIA no agente:
--                   o catálogo não muda o agente de ninguém. `instrucoes`
--                   segue sendo o "o que faz", e o contexto é o que só o
--                   cliente sabe — sem ele, um agente autônomo responde a um
--                   contato frio sem saber em nome de quem fala.
--   tamanho_maximo  NULL = o do canal. O default 700 fica: só o construtor
--                   grava nulo, e grava de propósito.
--   agentes_por_canal
--                   quem responde em cada canal do cliente. A campanha que
--                   quiser outro grava a EXCEÇÃO em `campaign_agents`, e a
--                   exceção decide sozinha: agente desligado ou "ninguém"
--                   (agent_id nulo) quer dizer ninguém — sem cair para o
--                   agente do canal. Desligar um agente é o freio, e o freio
--                   que entrega a conversa a outro agente não freia (D54).
--   vigente_desde   o agente do canal responde o que chegar DEPOIS de ser
--                   escolhido. Sem isso, marcar um agente no WhatsApp faria
--                   ele responder de uma vez os sete dias de respostas de toda
--                   campanha que não tinha agente — no e-mail, dias depois, a
--                   uma conversa que uma pessoa pode já ter atendido.
--
-- A regra de quem responde mora numa função só, `privado.agente_que_responde`,
-- que a fila e a tela (`quem_responde`) usam: o despachante discordar do
-- agendador sobre o mesmo fato é o D40, e a tela reproduzir a regra em
-- TypeScript é o D55.
--
-- A fila nova tem nome novo porque o tipo de retorno muda (D63: sem DROP).
-- `respostas_para_o_agente` fica sem chamador quando o worker v8 entrar, e até
-- lá devolve 700 onde o tamanho é nulo, para o v7 seguir sendo rollback seguro.
--
-- O que NÃO muda aqui, de propósito: o INSERT de `agents` continua de tabela
-- inteira, porque `atribuir_agente` é INVOKER e a cópia do catálogo grava
-- `canal` e `pronto` — estreitar agora quebraria a tela que está no ar.
--
-- Sem barra invertida (D32). Sem DROP (D63).
-- Reversível: supabase/down/20261012100000_agente_de_todos_os_canais.down.sql

-- ---------------------------------------------------------------------------
-- O agente
-- ---------------------------------------------------------------------------

ALTER TABLE agents
  ALTER COLUMN canal DROP NOT NULL,
  ALTER COLUMN tamanho_maximo DROP NOT NULL,
  ADD COLUMN persona text,
  ADD COLUMN objetivo text,
  ADD COLUMN tom text NOT NULL DEFAULT '',
  ADD COLUMN contexto text NOT NULL DEFAULT '',
  ADD CONSTRAINT agents_persona_slug CHECK (persona IS NULL OR persona ~ '^[a-z_]{1,40}$'),
  ADD CONSTRAINT agents_objetivo_slug CHECK (objetivo IS NULL OR objetivo ~ '^[a-z_]{1,40}$'),
  -- Agente sem canal é o do construtor: o texto dele não traz regra de canal
  -- nenhuma, e é o produto quem as põe. Um agente de antes sem canal
  -- responderia no SMS com as regras do WhatsApp escritas na instrução.
  ADD CONSTRAINT agents_sem_canal_tem_objetivo CHECK (canal IS NOT NULL OR objetivo IS NOT NULL),
  ADD CONSTRAINT agents_contexto_do_agente_novo CHECK (objetivo IS NULL OR length(trim(contexto)) >= 40);

COMMENT ON COLUMN agents.canal IS
  'NULL: o agente de todos os canais (D76), e o que muda por canal é do produto. '
  'Preenchido: agente de antes do D76, que só responde no canal dele.';
COMMENT ON COLUMN agents.persona IS
  'Slug da persona do catálogo (adapters/prompt-do-agente.ts) de que o tom foi copiado. Rótulo, não ligação.';
COMMENT ON COLUMN agents.objetivo IS
  'Slug do objetivo do catálogo de que o roteiro foi copiado. NULL = agente de antes do D76.';
COMMENT ON COLUMN agents.tom IS 'Como o agente fala. Cópia editável da persona.';
COMMENT ON COLUMN agents.contexto IS
  'Sobre a empresa e a oferta: o que só o cliente sabe. Obrigatório no agente novo.';
COMMENT ON COLUMN agents.tamanho_maximo IS
  'O agente pode encurtar o que o canal permite; nunca alongar. NULL = o do canal (D76).';

-- ---------------------------------------------------------------------------
-- Quem responde em cada canal
-- ---------------------------------------------------------------------------

CREATE TABLE agentes_por_canal (
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  canal         canal NOT NULL,
  agent_id      uuid NOT NULL,
  -- O agente responde o que chegou depois de ser escolhido. Renovado quando o
  -- agente muda; a tela não escreve.
  vigente_desde timestamptz NOT NULL DEFAULT now(),
  criado_em     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, canal),
  -- RESTRICT: apagar o agente do canal não pode deixar o canal calado sem
  -- ninguém saber. Remover agente é desligá-lo.
  CONSTRAINT agentes_por_canal_agente_fkey FOREIGN KEY (tenant_id, agent_id)
    REFERENCES agents (tenant_id, id) ON DELETE RESTRICT
);

CREATE INDEX agentes_por_canal_agente_idx ON agentes_por_canal (tenant_id, agent_id);

COMMENT ON TABLE agentes_por_canal IS
  'Quem responde em cada canal do cliente (D76). A campanha que quiser outro grava a exceção em '
  'campaign_agents, que vale sozinha — inclusive para dizer "ninguém".';

ALTER TABLE agentes_por_canal ENABLE ROW LEVEL SECURITY;
ALTER TABLE agentes_por_canal FORCE ROW LEVEL SECURITY;
CREATE POLICY agentes_por_canal_sel ON agentes_por_canal FOR SELECT
  USING (privado.pertence_ao_tenant(tenant_id));
CREATE POLICY agentes_por_canal_ins ON agentes_por_canal FOR INSERT
  WITH CHECK (privado.pode_operar(tenant_id));
CREATE POLICY agentes_por_canal_upd ON agentes_por_canal FOR UPDATE
  USING (privado.pode_operar(tenant_id)) WITH CHECK (privado.pode_operar(tenant_id));
-- Tirar o agente do canal é configuração, não perda de dado: quem escolhe
-- também desfaz.
CREATE POLICY agentes_por_canal_del ON agentes_por_canal FOR DELETE
  USING (privado.pode_operar(tenant_id));

CREATE FUNCTION privado.validar_agente_do_canal() RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
DECLARE a agents%ROWTYPE;
BEGIN
  SELECT * INTO a FROM agents WHERE tenant_id = NEW.tenant_id AND id = NEW.agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agente % não é deste cliente', NEW.agent_id USING ERRCODE = 'restrict_violation';
  END IF;
  IF a.ativo IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'o agente % está desligado', a.nome USING ERRCODE = 'restrict_violation';
  END IF;
  IF a.canal IS NOT NULL AND a.canal IS DISTINCT FROM NEW.canal THEN
    RAISE EXCEPTION 'o agente % só responde em %, não em %', a.nome, a.canal, NEW.canal
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER agentes_por_canal_valida
  BEFORE INSERT OR UPDATE ON agentes_por_canal
  FOR EACH ROW EXECUTE FUNCTION privado.validar_agente_do_canal();

-- ---------------------------------------------------------------------------
-- A exceção da campanha: pode ser "ninguém", e também tem vigência
-- ---------------------------------------------------------------------------

-- `agent_id` nulo = ninguém responde nesta campanha, neste canal. O gatilho
-- de campaign_agents já aceita o nulo (as comparações com a linha vazia não
-- disparam), e a FK composta MATCH SIMPLE não confere nulo; quem confere que
-- o canal está habilitado na campanha continua conferindo.
ALTER TABLE campaign_agents ALTER COLUMN agent_id DROP NOT NULL;

-- As linhas que já existem valem para tudo, como sempre valeram: toda resposta
-- dessas campanhas já ganhou rascunho. As novas valem a partir de agora.
ALTER TABLE campaign_agents ADD COLUMN vigente_desde timestamptz NOT NULL DEFAULT '-infinity';
ALTER TABLE campaign_agents ALTER COLUMN vigente_desde SET DEFAULT now();

COMMENT ON COLUMN campaign_agents.agent_id IS
  'NULL: ninguém responde nesta campanha, neste canal — nem o agente do canal (D76).';

CREATE FUNCTION privado.renovar_vigencia_do_agente() RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.vigente_desde := now();
  ELSIF NEW.agent_id IS DISTINCT FROM OLD.agent_id THEN
    NEW.vigente_desde := now();
  ELSE
    NEW.vigente_desde := OLD.vigente_desde;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER agentes_por_canal_vigencia
  BEFORE INSERT OR UPDATE ON agentes_por_canal
  FOR EACH ROW EXECUTE FUNCTION privado.renovar_vigencia_do_agente();
CREATE TRIGGER campaign_agents_vigencia
  BEFORE INSERT OR UPDATE ON campaign_agents
  FOR EACH ROW EXECUTE FUNCTION privado.renovar_vigencia_do_agente();

-- Voltar ao agente do canal é apagar a exceção, e quem escolhe a exceção é o
-- operador. Com DELETE só para admin, o operador conseguia trocar o agente
-- (UPDATE) e não conseguia desfazer a troca.
ALTER POLICY campaign_agents_del ON campaign_agents USING (privado.pode_operar(tenant_id));

-- ---------------------------------------------------------------------------
-- Quem responde: uma regra, um lugar
-- ---------------------------------------------------------------------------

CREATE FUNCTION privado.agente_que_responde(p_tenant uuid, p_campaign_id uuid, p_canal canal)
RETURNS TABLE (agent_id uuid, origem text, vigente_desde timestamptz)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  -- A exceção da campanha, quando existe, decide sozinha — inclusive o nulo,
  -- que é "ninguém". Sem exceção, o agente do canal. Se o agente escolhido
  -- está desligado, quem lê isto não junta o agente: ninguém responde.
  SELECT CASE WHEN ca.campaign_id IS NOT NULL THEN ca.agent_id ELSE apc.agent_id END,
         -- 'ninguem': a campanha disse "ninguém aqui". 'sem_agente': nem a
         -- campanha nem o canal escolheram. Os dois dão ninguém respondendo; a
         -- tela precisa saber qual, para mostrar a escolha certa.
         CASE WHEN ca.campaign_id IS NOT NULL
                THEN CASE WHEN ca.agent_id IS NULL THEN 'ninguem' ELSE 'campanha' END
              WHEN apc.agent_id IS NOT NULL THEN 'canal'
              ELSE 'sem_agente' END,
         CASE WHEN ca.campaign_id IS NOT NULL THEN ca.vigente_desde ELSE apc.vigente_desde END
    FROM (SELECT 1) AS um
    LEFT JOIN campaign_agents ca
           ON ca.tenant_id = p_tenant AND ca.campaign_id = p_campaign_id AND ca.canal = p_canal
    LEFT JOIN agentes_por_canal apc
           ON apc.tenant_id = p_tenant AND apc.canal = p_canal;
$$;

COMMENT ON FUNCTION privado.agente_que_responde IS
  'A regra de quem responde (D76): a exceção da campanha decide sozinha; sem ela, o agente do canal. '
  'Lida pela fila do worker e pela tela (quem_responde), para as duas nunca discordarem.';

-- A tela pergunta, e a resposta é a mesma da fila.
CREATE FUNCTION public.quem_responde(p_tenant uuid, p_campaign_id uuid)
RETURNS TABLE (canal canal, agent_id uuid, origem text, responde boolean)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  SELECT x.canal, q.agent_id, q.origem,
         coalesce(a.ativo AND (a.canal IS NULL OR a.canal = x.canal), false)
    FROM campaigns c
    CROSS JOIN LATERAL unnest(c.canais_habilitados) AS x(canal)
    CROSS JOIN LATERAL privado.agente_que_responde(c.tenant_id, c.id, x.canal) q
    LEFT JOIN agents a ON a.tenant_id = c.tenant_id AND a.id = q.agent_id
   WHERE c.id = p_campaign_id AND c.tenant_id = p_tenant;
$$;

COMMENT ON FUNCTION public.quem_responde IS
  'Por canal da campanha: o agente que a fila usaria agora, de onde ele vem (campanha, canal, ninguém por '
  'escolha da campanha, ou sem agente nenhum) '
  'e se de fato responde (ligado e do canal). SECURITY INVOKER: o RLS decide o que se vê.';

-- O de sempre, por cima da regra nova. `atribuir_agente` e os testes antigos
-- leem por aqui.
CREATE OR REPLACE FUNCTION public.agente_do_canal(p_campaign_id uuid, p_canal canal)
RETURNS agents
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  SELECT a.* FROM campaigns c
    CROSS JOIN LATERAL privado.agente_que_responde(c.tenant_id, c.id, p_canal) q
    JOIN agents a ON a.tenant_id = c.tenant_id AND a.id = q.agent_id
   WHERE c.id = p_campaign_id AND a.ativo AND (a.canal IS NULL OR a.canal = p_canal);
$$;

-- ---------------------------------------------------------------------------
-- Criar o agente e escolhê-lo, numa transação
-- ---------------------------------------------------------------------------

-- Criar aqui e escolher o canal numa segunda chamada é a campanha órfã do D54
-- pelo outro lado (D55): o agente nasceria sem responder em lugar nenhum se a
-- segunda falhasse. INVOKER: o RLS de agents, agentes_por_canal e
-- campaign_agents decide, como em toda escrita da tela (D73).
CREATE FUNCTION public.criar_agente(
  p_tenant uuid, p_nome text, p_persona text, p_objetivo text,
  p_papel text, p_descricao text, p_tom text, p_instrucoes text, p_contexto text,
  p_escalar_quando text, p_limite_trocas integer, p_proibido text[], p_tamanho_maximo integer,
  p_ai_credential_id uuid, p_autonomo boolean,
  p_canais canal[] DEFAULT '{}', p_campanha uuid DEFAULT NULL, p_canais_da_campanha canal[] DEFAULT '{}'
) RETURNS uuid
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
DECLARE v_id uuid; v_canal canal;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'cliente não informado' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF nullif(trim(coalesce(p_persona, '')), '') IS NULL OR nullif(trim(coalesce(p_objetivo, '')), '') IS NULL THEN
    RAISE EXCEPTION 'escolha a persona e o objetivo do agente' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF nullif(trim(coalesce(p_nome, '')), '') IS NULL THEN
    RAISE EXCEPTION 'dê um nome ao agente' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF EXISTS (SELECT 1 FROM agents WHERE tenant_id = p_tenant AND nome = trim(p_nome)) THEN
    RAISE EXCEPTION 'já existe um agente chamado %', trim(p_nome) USING ERRCODE = 'unique_violation';
  END IF;

  INSERT INTO agents (tenant_id, nome, canal, persona, objetivo, papel, descricao, tom, instrucoes,
                      contexto, escalar_quando, limite_trocas, proibido, tamanho_maximo,
                      ai_credential_id, autonomo, pronto, ativo)
  VALUES (p_tenant, trim(p_nome), NULL, trim(p_persona), trim(p_objetivo), trim(coalesce(p_papel, '')),
          trim(coalesce(p_descricao, '')), coalesce(p_tom, ''), coalesce(p_instrucoes, ''),
          coalesce(p_contexto, ''), coalesce(p_escalar_quando, ''), p_limite_trocas,
          coalesce(p_proibido, '{}'), p_tamanho_maximo, p_ai_credential_id, coalesce(p_autonomo, true),
          true, true)
  RETURNING id INTO v_id;

  FOREACH v_canal IN ARRAY coalesce(p_canais, '{}') LOOP
    INSERT INTO agentes_por_canal (tenant_id, canal, agent_id) VALUES (p_tenant, v_canal, v_id)
    ON CONFLICT (tenant_id, canal) DO UPDATE SET agent_id = EXCLUDED.agent_id;
  END LOOP;

  IF cardinality(coalesce(p_canais_da_campanha, '{}')) > 0 THEN
    IF NOT EXISTS (SELECT 1 FROM campaigns WHERE tenant_id = p_tenant AND id = p_campanha) THEN
      RAISE EXCEPTION 'campanha % não é deste cliente', p_campanha USING ERRCODE = 'restrict_violation';
    END IF;
    FOREACH v_canal IN ARRAY p_canais_da_campanha LOOP
      INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id)
      VALUES (p_tenant, p_campanha, v_canal, v_id)
      ON CONFLICT (campaign_id, canal) DO UPDATE SET agent_id = EXCLUDED.agent_id;
    END LOOP;
  END IF;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- A fila do worker
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.fila_do_agente(p_limite integer DEFAULT 20)
RETURNS TABLE(
  message_event_id uuid, tenant_id uuid, contact_id uuid, resposta_em timestamptz,
  canal canal, texto text, regra text,
  agent_id uuid, agente_nome text, papel text, descricao text,
  tom text, instrucoes text, contexto text, objetivo text,
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
         a.id, a.nome, a.papel, a.descricao,
         a.tom, a.instrucoes, a.contexto, a.objetivo,
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
    -- D76: quem responde é decidido uma vez, pelo cliente da RESPOSTA, e o
    -- agente é juntado uma vez só por esse id. Juntar a exceção e o do canal
    -- coluna a coluna misturaria os dois (o tamanho de um, a conta do outro).
    CROSS JOIN LATERAL privado.agente_que_responde(r.tenant_id, r.campaign_id, r.canal) q
    JOIN agents a     ON a.tenant_id = r.tenant_id AND a.id = q.agent_id AND a.ativo
                     AND (a.canal IS NULL OR a.canal = r.canal)
    -- A conta escolhida na campanha vale sobre a do agente (D68). O cliente
    -- é o da resposta: o worker não tem RLS que segure o resto.
    LEFT JOIN ai_credentials ac ON ac.tenant_id = r.tenant_id
                               AND ac.id = coalesce(camp.ai_credential_id, a.ai_credential_id)
    LEFT JOIN ai_provider_catalog pc ON pc.slug = ac.provedor
    JOIN contact_identities ci ON ci.tenant_id = r.tenant_id AND ci.id = r.contact_identity_id
   WHERE r.n = 1
     -- O agente responde o que chegou depois de ser escolhido (D76).
     AND r.ocorrido_em >= q.vigente_desde
     AND NOT EXISTS (SELECT 1 FROM rascunhos x WHERE x.tenant_id = r.tenant_id AND x.message_event_id = r.id)
     -- Nem rascunho para quem pediu para sair: um texto pronto é convite a
     -- uma pessoa mandar — e agora ao motor. A pessoa inteira e o endereço.
     AND NOT esta_suprimido(r.tenant_id, r.contact_id, r.canal, ci.valor_norm)
   ORDER BY r.ocorrido_em
   LIMIT least(coalesce(p_limite, 20), 100);
$$;

-- ---------------------------------------------------------------------------
-- A fila antiga, até o v8 entrar
-- ---------------------------------------------------------------------------

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
         a.escalar_quando, a.limite_trocas, a.proibido,
         -- D76: nulo é "o do canal", que o v7 não conhece. Esta fila fica sem
         -- chamador com o v8; o 700 é o que o v7 sempre usou, para ele continuar
         -- sendo um rollback seguro.
         coalesce(a.tamanho_maximo, 700),
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

-- ---------------------------------------------------------------------------
-- Superfície
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; alvo text;
BEGIN
  -- O motor: só o worker. E os gatilhos, que não precisam de EXECUTE de quem
  -- escreve na tabela (o privilégio é conferido ao criar o gatilho).
  FOREACH alvo IN ARRAY ARRAY[
    'public.fila_do_agente(integer)',
    'privado.validar_agente_do_canal()',
    'privado.renovar_vigencia_do_agente()'
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

  -- A tela: authenticated, e o RLS decide. `agente_que_responde` entra aqui
  -- porque `quem_responde` é INVOKER e a chama no papel de quem pergunta;
  -- `privado` não é publicado pelo PostgREST, então isto não vira endpoint.
  FOREACH alvo IN ARRAY ARRAY[
    'public.quem_responde(uuid, uuid)',
    'public.criar_agente(uuid, text, text, text, text, text, text, text, text, text, integer, text[], integer, uuid, boolean, canal[], uuid, canal[])',
    'privado.agente_que_responde(uuid, uuid, canal)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    FOREACH papel IN ARRAY ARRAY['authenticated','service_role'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON agentes_por_canal FROM anon;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- A grade
-- ---------------------------------------------------------------------------

-- A grade estreita, regenerada a partir do corpo do D75 (D59). Quatro
-- mudanças: o agente ganha as colunas do D76 no UPDATE e perde o DELETE;
-- campaign_agents e agentes_por_canal ficam por coluna; e os dois catálogos de
-- vocabulário saem da escrita de quem usa a tela.
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
  -- D76: os dois vocabulários de catálogo (D58, D63) estavam fora desta lista
  -- e seguiam com escrita de tabela inteira — a política segurava, o
  -- privilégio não. O do cliente é `blacklist_termos`, que fica como está.
  REVOKE INSERT, UPDATE, DELETE ON opt_out_termos, recusa_termos FROM authenticated;

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
                limite_trocas, ativo, proibido, tamanho_maximo, autonomo,
                tom, contexto, persona, objetivo)
    ON agents TO authenticated;
  -- D76: remover agente é desligá-lo. O DELETE apagava em cascata a exceção
  -- das campanhas (trocando quem responde sem ninguém ver) e deixava o
  -- histórico de rascunhos sem quem o compôs. `canal` fica fora do UPDATE: o
  -- agente de antes continua do canal dele, e o novo nasce de todos.
  REVOKE DELETE ON agents FROM authenticated;

  -- D76: quem responde. A tela escolhe o agente e o canal; a vigência é do
  -- gatilho, e o dono da linha não muda.
  REVOKE INSERT, UPDATE ON campaign_agents, agentes_por_canal FROM authenticated;
  GRANT INSERT (tenant_id, campaign_id, canal, agent_id) ON campaign_agents TO authenticated;
  GRANT UPDATE (agent_id) ON campaign_agents TO authenticated;
  GRANT INSERT (tenant_id, canal, agent_id) ON agentes_por_canal TO authenticated;
  GRANT UPDATE (agent_id) ON agentes_por_canal TO authenticated;

  -- O rascunho é do worker: a tela lê. Escrito à mão, seria um texto que
  -- parece ter sido composto pelo agente com os freios dele, sem ter sido —
  -- e, desde o D69, um `envio = 'fila'` sem mensagem nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;
END;
$function$;

-- Dentro de DO: migration que imprime resultado polui o stdout que o
-- `tests/run.sh` captura para nomear o banco.
DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
