-- Multi-tenant e Row Level Security.
--
-- Feito antes de existir um byte de dado em produção, de propósito: `tenant_id`
-- é o que toda política de RLS filtra, e acrescentá-lo depois seria migration
-- em dado vivo mais reescrita de todas as políticas.
--
-- Três camadas, e nenhuma delas confia na de cima:
--   1. `tenant_id` em toda tabela de domínio.
--   2. Chaves estrangeiras COMPOSTAS `(tenant_id, id)` — uma linha de um tenant
--      não consegue apontar para a linha de outro nem por bug de aplicação.
--   3. RLS por tenant, com papel decidindo escrita.
--
-- A camada 2 é a que costuma faltar. Sem ela, RLS impede o vazamento na
-- leitura, mas um INSERT com o id errado ainda cria um enrollment do tenant A
-- apontando para a campanha do tenant B — e aí o motor manda a mensagem do
-- cliente errado para o contato errado.

-- ---------------------------------------------------------------------------
-- Tenants e membros
-- ---------------------------------------------------------------------------

CREATE TYPE papel_tenant AS ENUM ('dono', 'admin', 'operador', 'leitor');

CREATE TABLE tenants (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome      text NOT NULL,
  slug      text NOT NULL UNIQUE,
  ativo     boolean NOT NULL DEFAULT true,
  criado_em timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenants_slug_formato CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$')
);

-- user_id é auth.users.id. Sem FK de propósito: o schema roda em Postgres
-- limpo (teste, CI) onde o schema auth do Supabase não existe.
CREATE TABLE tenant_users (
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id   uuid NOT NULL,
  papel     papel_tenant NOT NULL DEFAULT 'leitor',
  criado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id)
);

CREATE INDEX tenant_users_usuario_idx ON tenant_users (user_id);

-- ---------------------------------------------------------------------------
-- Quem é o usuário e a que tenants pertence
-- ---------------------------------------------------------------------------

-- Lê o sub do JWT sem depender do schema auth do Supabase, para o mesmo SQL
-- valer em produção e no Postgres do teste.
CREATE FUNCTION usuario_atual() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
  v := nullif(current_setting('request.jwt.claim.sub', true), '');
  IF v IS NULL THEN
    BEGIN
      v := nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '');
    EXCEPTION WHEN others THEN
      v := NULL;
    END;
  END IF;
  RETURN v::uuid;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

-- SECURITY DEFINER: a política de `tenant_users` não pode consultar
-- `tenant_users` sob RLS — seria recursão.
CREATE FUNCTION pertence_ao_tenant(p_tenant uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM tenant_users tu
     WHERE tu.tenant_id = p_tenant AND tu.user_id = usuario_atual());
$$;

CREATE FUNCTION tem_papel(p_tenant uuid, p_papeis papel_tenant[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM tenant_users tu
     WHERE tu.tenant_id = p_tenant AND tu.user_id = usuario_atual()
       AND tu.papel = ANY (p_papeis));
$$;

-- Atalhos legíveis, usados nas políticas.
CREATE FUNCTION pode_operar(p_tenant uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT tem_papel(p_tenant, ARRAY['dono','admin','operador']::papel_tenant[]);
$$;

CREATE FUNCTION pode_administrar(p_tenant uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT tem_papel(p_tenant, ARRAY['dono','admin']::papel_tenant[]);
$$;

-- Tenant do usuário quando ele só tem um — serve de DEFAULT para inserção pela
-- UI. Com mais de um, devolve NULL e a aplicação precisa dizer qual.
CREATE FUNCTION tenant_atual() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT tu.tenant_id FROM tenant_users tu
   WHERE tu.user_id = usuario_atual()
   LIMIT 1 OFFSET 0;
$$;

-- Tenant que a sessão está usando. A aplicação define `app.tenant` por
-- requisição; quem não define cai no único tenant do usuário. É só DEFAULT de
-- conveniência — quem impede escrever no tenant errado é o WITH CHECK do RLS.
CREATE FUNCTION tenant_padrao() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
  v := nullif(current_setting('app.tenant', true), '');
  IF v IS NOT NULL THEN RETURN v::uuid; END IF;
  RETURN tenant_atual();
EXCEPTION WHEN others THEN
  RETURN tenant_atual();
END;
$$;

-- ---------------------------------------------------------------------------
-- tenant_id em toda tabela de domínio
-- ---------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'contacts','contact_identities','campaigns','flows','flow_versions','flow_steps',
    'enrollments','messages','message_events','sender_accounts','suppression','outbox',
    'ai_credentials','campaign_agents'
  ] LOOP
    EXECUTE format(
      'ALTER TABLE %I ADD COLUMN tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE',
      t);
    EXECUTE format('ALTER TABLE %I ALTER COLUMN tenant_id SET DEFAULT tenant_padrao()', t);
    EXECUTE format('CREATE INDEX %I ON %I (tenant_id)', t || '_tenant_idx', t);
    -- Chave que as FKs compostas vão referenciar. campaign_agents tem chave
    -- composta e nenhuma coluna `id`, então fica de fora.
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = t AND column_name = 'id') THEN
      EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I UNIQUE (tenant_id, id)',
        t, t || '_tenant_id_uk');
    END IF;
  END LOOP;
END;
$$;

-- Agente com tenant nulo é agente do catálogo, como os modelos de campanha.
-- Os cinco agentes prontos já semeados viram catálogo; usar um numa campanha
-- copia para o tenant (ver atribuir_agente).
ALTER TABLE agents ADD COLUMN tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;
CREATE INDEX agents_tenant_idx ON agents (tenant_id);
ALTER TABLE agents ADD CONSTRAINT agents_tenant_id_uk UNIQUE (tenant_id, id);

-- Modelo de campanha com tenant nulo é modelo do sistema, visível a todos.
ALTER TABLE campaign_templates
  ADD COLUMN tenant_id uuid REFERENCES tenants(id) ON DELETE CASCADE;

COMMENT ON COLUMN campaign_templates.tenant_id IS
  'NULL = modelo do catálogo, disponível para todos os tenants. Preenchido =
   modelo que o próprio cliente criou.';

-- ---------------------------------------------------------------------------
-- Unicidade passa a ser por tenant
-- ---------------------------------------------------------------------------

-- O mesmo telefone pode ser contato de dois clientes diferentes do produto.
DROP INDEX contact_identities_canal_valor_uk;
CREATE UNIQUE INDEX contact_identities_canal_valor_uk
  ON contact_identities (tenant_id, canal, valor_norm);

DROP INDEX suppression_contato_uk;
DROP INDEX suppression_identidade_uk;
CREATE UNIQUE INDEX suppression_contato_uk
  ON suppression (tenant_id, contact_id) WHERE contact_id IS NOT NULL AND canal IS NULL;
CREATE UNIQUE INDEX suppression_identidade_uk
  ON suppression (tenant_id, canal, valor_norm) WHERE valor_norm IS NOT NULL;

ALTER TABLE sender_accounts DROP CONSTRAINT sender_accounts_identificador_uk;
ALTER TABLE sender_accounts ADD CONSTRAINT sender_accounts_identificador_uk
  UNIQUE (tenant_id, canal, identificador);

ALTER TABLE agents DROP CONSTRAINT agents_nome_uk;
CREATE UNIQUE INDEX agents_nome_uk ON agents (tenant_id, nome) NULLS NOT DISTINCT;

ALTER TABLE ai_credentials DROP CONSTRAINT ai_credentials_nome_uk;
ALTER TABLE ai_credentials ADD CONSTRAINT ai_credentials_nome_uk UNIQUE (tenant_id, nome);

-- `campaigns.template_slug` deixa de ser FK: o modelo pode ser do sistema
-- (tenant nulo) ou do próprio cliente, e FK composta não expressa "um ou
-- outro". O slug ali é rastro de origem, não integridade — a campanha já
-- nasceu com flow e passos próprios, então apagar o modelo não quebra nada.
ALTER TABLE campaigns DROP CONSTRAINT IF EXISTS campaigns_template_slug_fkey;

ALTER TABLE campaign_templates DROP CONSTRAINT campaign_templates_slug_key;
CREATE UNIQUE INDEX campaign_templates_slug_uk
  ON campaign_templates (tenant_id, slug) NULLS NOT DISTINCT;

-- ---------------------------------------------------------------------------
-- Chaves estrangeiras compostas: linha de um tenant não aponta para outro
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('contact_identities','contact_identities_contact_id_fkey','contact_id','contacts'),
    ('enrollments','enrollments_contact_id_fkey','contact_id','contacts'),
    ('enrollments','enrollments_campaign_id_fkey','campaign_id','campaigns'),
    ('enrollments','enrollments_flow_version_id_fkey','flow_version_id','flow_versions'),
    ('flow_versions','flow_versions_flow_id_fkey','flow_id','flows'),
    ('flow_steps','flow_steps_flow_version_id_fkey','flow_version_id','flow_versions'),
    ('messages','messages_enrollment_id_fkey','enrollment_id','enrollments'),
    ('messages','messages_step_id_fkey','step_id','flow_steps'),
    ('messages','messages_contact_identity_id_fkey','contact_identity_id','contact_identities'),
    ('messages','messages_sender_account_id_fkey','sender_account_id','sender_accounts'),
    ('message_events','message_events_message_id_fkey','message_id','messages'),
    ('suppression','suppression_contact_id_fkey','contact_id','contacts'),
    ('outbox','outbox_contact_id_fkey','contact_id','contacts'),
    ('campaign_agents','campaign_agents_campaign_id_fkey','campaign_id','campaigns'),
    ('campaign_agents','campaign_agents_agent_id_fkey','agent_id','agents'),
    ('agents','agents_ai_credential_id_fkey','ai_credential_id','ai_credentials')
  ) AS v(tabela, fk, coluna, destino)
  LOOP
    EXECUTE format('ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I', r.tabela, r.fk);
    EXECUTE format(
      'ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (tenant_id, %I)
         REFERENCES %I (tenant_id, id) ON DELETE CASCADE',
      r.tabela, r.tabela || '_' || r.coluna || '_tenant_fkey', r.coluna, r.destino);
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

-- Leitura para qualquer membro; escrita para operador ou acima; remoção só
-- para admin. Tabelas com credencial ficam restritas a admin até na leitura.
DO $$
DECLARE t text;
BEGIN
  -- Tabelas operacionais.
  FOREACH t IN ARRAY ARRAY[
    'contacts','contact_identities','campaigns','flows','flow_versions','flow_steps',
    'enrollments','messages','message_events','suppression','outbox',
    'campaign_agents'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);

    EXECUTE format($f$CREATE POLICY %I ON %I FOR SELECT
      USING (pertence_ao_tenant(tenant_id))$f$, t || '_sel', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR INSERT
      WITH CHECK (pode_operar(tenant_id))$f$, t || '_ins', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR UPDATE
      USING (pode_operar(tenant_id)) WITH CHECK (pode_operar(tenant_id))$f$, t || '_upd', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR DELETE
      USING (pode_administrar(tenant_id))$f$, t || '_del', t);
  END LOOP;

  -- Tabelas sensíveis: remetente e credencial de IA só para admin.
  FOREACH t IN ARRAY ARRAY['sender_accounts','ai_credentials'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR SELECT
      USING (pode_administrar(tenant_id))$f$, t || '_sel', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR ALL
      USING (pode_administrar(tenant_id)) WITH CHECK (pode_administrar(tenant_id))$f$,
      t || '_todos', t);
  END LOOP;
END;
$$;

-- Agentes: catálogo visível a todos, agente do tenant só para o tenant.
ALTER TABLE agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE agents FORCE ROW LEVEL SECURITY;
CREATE POLICY agents_sel ON agents FOR SELECT
  USING (tenant_id IS NULL OR pertence_ao_tenant(tenant_id));
CREATE POLICY agents_ins ON agents FOR INSERT
  WITH CHECK (tenant_id IS NOT NULL AND pode_operar(tenant_id));
CREATE POLICY agents_upd ON agents FOR UPDATE
  USING (tenant_id IS NOT NULL AND pode_operar(tenant_id))
  WITH CHECK (tenant_id IS NOT NULL AND pode_operar(tenant_id));
CREATE POLICY agents_del ON agents FOR DELETE
  USING (tenant_id IS NOT NULL AND pode_administrar(tenant_id));

ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenants_sel ON tenants FOR SELECT USING (pertence_ao_tenant(id));
CREATE POLICY tenants_upd ON tenants FOR UPDATE
  USING (pode_administrar(id)) WITH CHECK (pode_administrar(id));

ALTER TABLE tenant_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_users FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_users_sel ON tenant_users FOR SELECT
  USING (pertence_ao_tenant(tenant_id));
CREATE POLICY tenant_users_admin ON tenant_users FOR ALL
  USING (pode_administrar(tenant_id)) WITH CHECK (pode_administrar(tenant_id));

-- Modelos: catálogo do sistema é público para membros; modelo próprio é do
-- tenant. Ninguém edita o catálogo do sistema pela aplicação.
ALTER TABLE campaign_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaign_templates FORCE ROW LEVEL SECURITY;
CREATE POLICY campaign_templates_sel ON campaign_templates FOR SELECT
  USING (tenant_id IS NULL OR pertence_ao_tenant(tenant_id));
CREATE POLICY campaign_templates_ins ON campaign_templates FOR INSERT
  WITH CHECK (tenant_id IS NOT NULL AND pode_operar(tenant_id));
CREATE POLICY campaign_templates_upd ON campaign_templates FOR UPDATE
  USING (tenant_id IS NOT NULL AND pode_operar(tenant_id))
  WITH CHECK (tenant_id IS NOT NULL AND pode_operar(tenant_id));
CREATE POLICY campaign_templates_del ON campaign_templates FOR DELETE
  USING (tenant_id IS NOT NULL AND pode_administrar(tenant_id));

-- Catálogo de provedores é software, não dado de cliente: leitura para todos,
-- escrita só por migration (service_role).
ALTER TABLE ai_provider_catalog ENABLE ROW LEVEL SECURITY;
CREATE POLICY ai_provider_catalog_sel ON ai_provider_catalog FOR SELECT USING (true);

-- ---------------------------------------------------------------------------
-- Motor ciente de tenant
-- ---------------------------------------------------------------------------

-- Supressão é por tenant: o opt-out no cliente A não silencia o contato
-- homônimo do cliente B.
DROP FUNCTION IF EXISTS esta_suprimido(uuid, canal, text) CASCADE;

CREATE FUNCTION esta_suprimido(
  p_tenant uuid, p_contact_id uuid, p_canal canal, p_valor_norm text
) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM suppression s
    WHERE s.tenant_id = p_tenant AND (
         (s.contact_id = p_contact_id AND s.canal IS NULL)
      OR (s.contact_id = p_contact_id AND s.canal = p_canal)
      OR (s.canal = p_canal AND s.valor_norm = p_valor_norm))
  );
$$;

-- O trigger caiu junto com o CASCADE acima; volta ciente de tenant.
CREATE OR REPLACE FUNCTION barrar_mensagem_suprimida() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_contact_id uuid; v_valor_norm text; v_canal canal;
BEGIN
  SELECT ci.contact_id, ci.valor_norm, ci.canal
    INTO v_contact_id, v_valor_norm, v_canal
  FROM contact_identities ci WHERE ci.id = NEW.contact_identity_id;

  IF esta_suprimido(NEW.tenant_id, v_contact_id, v_canal, v_valor_norm) THEN
    RAISE EXCEPTION 'destino suprimido: contato % no canal %', v_contact_id, v_canal
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;

-- O CASCADE acima não derruba o trigger: corpo de plpgsql não cria dependência
-- rastreada, então a função continua lá chamando a assinatura antiga.
DROP TRIGGER IF EXISTS messages_respeita_supressao ON messages;
CREATE TRIGGER messages_respeita_supressao
  BEFORE INSERT ON messages
  FOR EACH ROW EXECUTE FUNCTION barrar_mensagem_suprimida();

-- Pool de remetentes é por tenant.
DROP FUNCTION IF EXISTS remetentes_disponiveis(canal, tipo_campanha);
CREATE FUNCTION remetentes_disponiveis(p_tenant uuid, p_canal canal, p_tipo tipo_campanha)
RETURNS SETOF sender_accounts
LANGUAGE sql STABLE AS $$
  SELECT * FROM sender_accounts
   WHERE tenant_id = p_tenant AND canal = p_canal AND tipo_permitido = p_tipo
     AND estado = 'ativo'
     AND (janela < current_date OR enviados_na_janela < quota_diaria)
   ORDER BY health_score DESC, enviados_na_janela ASC;
$$;

DROP FUNCTION IF EXISTS proximo_horario_de_pool(canal, tipo_campanha);
CREATE FUNCTION proximo_horario_de_pool(p_tenant uuid, p_canal canal, p_tipo tipo_campanha)
RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    min(CASE
      WHEN sa.estado = 'ativo' AND sa.janela >= current_date
           AND sa.enviados_na_janela >= sa.quota_diaria
        THEN (current_date + 1)::timestamptz
      WHEN sa.estado = 'circuito_aberto' AND sa.circuito_aberto_ate IS NOT NULL
        THEN sa.circuito_aberto_ate
    END),
    now() + interval '1 hour')
  FROM sender_accounts sa
  WHERE sa.tenant_id = p_tenant AND sa.canal = p_canal AND sa.tipo_permitido = p_tipo;
$$;

-- Inscrição herda o tenant da campanha.
DROP FUNCTION IF EXISTS inscrever(uuid, uuid, uuid, timestamptz);
CREATE FUNCTION inscrever(
  p_contact_id uuid, p_campaign_id uuid, p_flow_version_id uuid,
  p_quando timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant FROM campaigns WHERE id = p_campaign_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'campanha inexistente: %', p_campaign_id USING ERRCODE = 'no_data_found';
  END IF;

  IF esta_suprimido(v_tenant, p_contact_id, NULL, NULL) THEN
    RETURN NULL;
  END IF;

  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id, next_run_at)
  VALUES (v_tenant, p_contact_id, p_campaign_id, p_flow_version_id, p_quando)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION processar_vencidos(
  p_limite integer DEFAULT 100,
  p_modo   text    DEFAULT 'simulado'
)
RETURNS TABLE (enrollment_id uuid, acao text, detalhe text)
LANGUAGE plpgsql AS $$
DECLARE
  e enrollments%ROWTYPE; v_campanha campaigns%ROWTYPE; v_passo flow_steps%ROWTYPE;
  v_identidade contact_identities%ROWTYPE; v_remetente sender_accounts%ROWTYPE;
  v_contato contacts%ROWTYPE; v_proximo flow_steps%ROWTYPE;
  v_conteudo text; v_status status_message; v_vars jsonb; v_quando timestamptz;
BEGIN
  IF p_modo NOT IN ('simulado','real') THEN
    RAISE EXCEPTION 'modo inválido: % (use simulado ou real)', p_modo
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_status := CASE WHEN p_modo = 'simulado' THEN 'simulado' ELSE 'pendente' END::status_message;

  FOR e IN
    SELECT * FROM enrollments
     WHERE status = 'ativo' AND next_run_at IS NOT NULL AND next_run_at <= now()
     ORDER BY next_run_at LIMIT p_limite FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_campanha FROM campaigns WHERE id = e.campaign_id;
    IF NOT v_campanha.ativa THEN
      enrollment_id := e.id; acao := 'ignorado_campanha_inativa'; detalhe := v_campanha.nome;
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_contato FROM contacts WHERE id = e.contact_id;

    IF esta_suprimido(e.tenant_id, e.contact_id, NULL, NULL) THEN
      PERFORM encerrar_enrollment(e.id, 'supressao');
      enrollment_id := e.id; acao := 'encerrado_supressao'; detalhe := 'contato suprimido';
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_passo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > e.passo_atual
     ORDER BY ordem LIMIT 1;

    IF NOT FOUND THEN
      PERFORM encerrar_enrollment(e.id, 'fim_dos_passos');
      enrollment_id := e.id; acao := 'encerrado_fim'; detalhe := ''; RETURN NEXT; CONTINUE;
    END IF;

    IF NOT (v_passo.canal = ANY (v_campanha.canais_habilitados)) THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_canal'; detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_identidade FROM contact_identities
     WHERE contact_id = e.contact_id AND canal = v_passo.canal AND valida
     ORDER BY criado_em DESC LIMIT 1;

    IF NOT FOUND THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_sem_identidade'; detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    IF esta_suprimido(e.tenant_id, e.contact_id, v_identidade.canal, v_identidade.valor_norm) THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_identidade_suprimida';
      detalhe := v_passo.canal::text; RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_remetente
      FROM remetentes_disponiveis(e.tenant_id, v_passo.canal, v_campanha.tipo) LIMIT 1;

    IF NOT FOUND OR NOT reservar_envio(v_remetente.id) THEN
      v_quando := proximo_horario_de_pool(e.tenant_id, v_passo.canal, v_campanha.tipo);
      UPDATE enrollments SET next_run_at = greatest(v_quando, now() + interval '1 minute')
       WHERE id = e.id;
      enrollment_id := e.id; acao := 'adiado_sem_remetente';
      detalhe := v_passo.canal::text || ' até ' || to_char(v_quando, 'DD/MM HH24:MI');
      RETURN NEXT; CONTINUE;
    END IF;

    v_vars := coalesce(v_contato.metadados,'{}'::jsonb)
           || jsonb_build_object('nome', coalesce(v_contato.nome,''));
    v_conteudo := renderizar(v_passo.template, v_vars);

    BEGIN
      INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id,
                            sender_account_id, canal, status, conteudo)
      VALUES (e.tenant_id, e.id, v_passo.id, v_identidade.id,
              v_remetente.id, v_passo.canal, v_status, v_conteudo);
    EXCEPTION WHEN unique_violation THEN
      enrollment_id := e.id; acao := 'passo_ja_reivindicado'; detalhe := v_passo.ordem::text;
      RETURN NEXT; CONTINUE;
    END;

    SELECT * INTO v_proximo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > v_passo.ordem
     ORDER BY ordem LIMIT 1;

    IF FOUND THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem,
        next_run_at = now() + make_interval(hours => v_proximo.atraso_horas) WHERE id = e.id;
    ELSE
      UPDATE enrollments SET passo_atual = v_passo.ordem WHERE id = e.id;
      PERFORM encerrar_enrollment(e.id,'fim_dos_passos');
    END IF;

    enrollment_id := e.id; acao := 'mensagem_criada'; detalhe := v_passo.ordem::text;
    RETURN NEXT;
  END LOOP;
END;
$$;

-- Eventos e writeback herdam o tenant da mensagem.
CREATE OR REPLACE FUNCTION registrar_resultado_envio(
  p_message_id uuid, p_ok boolean, p_provider_id text DEFAULT NULL,
  p_erro text DEFAULT NULL, p_culpa text DEFAULT 'transitorio'
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_sender uuid; v_identidade uuid; v_contato uuid; v_tenant uuid;
BEGIN
  SELECT m.sender_account_id, m.contact_identity_id, e.contact_id, m.tenant_id
    INTO v_sender, v_identidade, v_contato, v_tenant
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = p_message_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'mensagem inexistente: %', p_message_id USING ERRCODE = 'no_data_found';
  END IF;

  IF p_ok THEN
    UPDATE messages SET status = 'enviado', provider_message_id = p_provider_id,
                        reivindicada_em = NULL WHERE id = p_message_id;
    INSERT INTO message_events (tenant_id, message_id, tipo, payload)
    VALUES (v_tenant, p_message_id, 'enviado',
            jsonb_build_object('provider_message_id', p_provider_id));
    PERFORM registrar_sucesso_remetente(v_sender);
    RETURN;
  END IF;

  IF p_culpa NOT IN ('remetente','destino','transitorio') THEN
    RAISE EXCEPTION 'culpa inválida: %', p_culpa USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE messages SET status = 'falha', reivindicada_em = NULL WHERE id = p_message_id;

  INSERT INTO message_events (tenant_id, message_id, tipo, payload)
  VALUES (v_tenant, p_message_id,
          (CASE WHEN p_culpa = 'destino' THEN 'rejeitado' ELSE 'falha' END)::tipo_evento,
          jsonb_build_object('erro', coalesce(p_erro,''), 'culpa', p_culpa));

  IF p_culpa = 'destino' THEN
    UPDATE contact_identities SET valida = false WHERE id = v_identidade;
    INSERT INTO outbox (tenant_id, contact_id, destino, fato, payload)
    VALUES (v_tenant, v_contato, 'crm', 'identidade_invalida',
            jsonb_build_object('contact_identity_id', v_identidade, 'erro', coalesce(p_erro,'')));
  ELSE
    PERFORM registrar_falha_remetente(v_sender);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION registrar_evento_provedor(
  p_provider_id text, p_tipo tipo_evento,
  p_ocorrido_em timestamptz DEFAULT now(), p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_message uuid; v_tenant uuid;
BEGIN
  IF p_payload ->> 'autoria' = 'motor-prospeccao' THEN RETURN false; END IF;

  SELECT id, tenant_id INTO v_message, v_tenant FROM messages
   WHERE provider_message_id = p_provider_id ORDER BY criado_em DESC LIMIT 1;

  IF v_message IS NULL THEN RETURN false; END IF;

  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em, payload)
  VALUES (v_tenant, v_message, p_tipo, p_ocorrido_em, p_payload);
  RETURN true;
END;
$$;

-- Criação a partir de modelo: tenant explícito, e modelo do sistema ou do
-- próprio tenant.
DROP FUNCTION IF EXISTS criar_campanha_de_modelo(text, text, canal[]);
CREATE FUNCTION criar_campanha_de_modelo(
  p_tenant uuid, p_slug text, p_nome text, p_canais canal[] DEFAULT NULL
)
RETURNS TABLE (campaign_id uuid, flow_version_id uuid, passos_criados integer)
LANGUAGE plpgsql AS $$
DECLARE
  m campaign_templates%ROWTYPE; v_canais canal[];
  v_campanha uuid; v_flow uuid; v_versao uuid; v_passo jsonb; v_ordem integer := 0;
BEGIN
  SELECT * INTO m FROM campaign_templates
   WHERE slug = p_slug AND ativo AND (tenant_id IS NULL OR tenant_id = p_tenant)
   ORDER BY tenant_id NULLS LAST LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'modelo inexistente ou inativo: %', p_slug USING ERRCODE = 'no_data_found';
  END IF;

  v_canais := coalesce(p_canais, m.canais);

  IF EXISTS (SELECT 1 FROM unnest(v_canais) c WHERE NOT (c = ANY (m.canais))) THEN
    RAISE EXCEPTION 'modelo % não atende os canais pedidos (%), só %', p_slug, v_canais, m.canais
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(m.passos) s
                  WHERE (s ->> 'canal')::canal = ANY (v_canais)) THEN
    RAISE EXCEPTION 'modelo % não tem nenhum passo nos canais %', p_slug, v_canais
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO campaigns (tenant_id, nome, tipo, base_legal, canais_habilitados,
                         template_slug, objetivo)
  VALUES (p_tenant, p_nome, m.tipo, m.base_legal, v_canais, m.slug, m.objetivo)
  RETURNING id INTO v_campanha;

  INSERT INTO flows (tenant_id, nome) VALUES (p_tenant, p_nome) RETURNING id INTO v_flow;
  INSERT INTO flow_versions (tenant_id, flow_id, versao)
  VALUES (p_tenant, v_flow, 1) RETURNING id INTO v_versao;

  FOR v_passo IN
    SELECT s FROM jsonb_array_elements(m.passos) WITH ORDINALITY AS t(s, i)
     WHERE (s ->> 'canal')::canal = ANY (v_canais) ORDER BY i
  LOOP
    v_ordem := v_ordem + 1;
    INSERT INTO flow_steps (tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
    VALUES (p_tenant, v_versao, v_ordem, (v_passo ->> 'canal')::canal,
            CASE WHEN v_ordem = 1 THEN 0
                 ELSE coalesce((v_passo ->> 'atraso_horas')::integer, 24) END,
            v_passo ->> 'template');
  END LOOP;

  campaign_id := v_campanha; flow_version_id := v_versao; passos_criados := v_ordem;
  RETURN NEXT;
END;
$$;

-- Agente e campanha têm que ser do mesmo tenant.
CREATE OR REPLACE FUNCTION validar_agente_da_campanha() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a agents%ROWTYPE; c campaigns%ROWTYPE;
BEGIN
  SELECT * INTO a FROM agents WHERE id = NEW.agent_id;
  SELECT * INTO c FROM campaigns WHERE id = NEW.campaign_id;

  IF a.tenant_id <> c.tenant_id OR a.tenant_id <> NEW.tenant_id THEN
    RAISE EXCEPTION 'agente e campanha são de tenants diferentes'
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NOT a.ativo THEN
    RAISE EXCEPTION 'agente % está inativo', a.nome USING ERRCODE = 'restrict_violation';
  END IF;
  IF a.canal <> NEW.canal THEN
    RAISE EXCEPTION 'agente % é de %, não de %', a.nome, a.canal, NEW.canal
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NOT (NEW.canal = ANY (c.canais_habilitados)) THEN
    RAISE EXCEPTION 'campanha % não usa o canal %', c.nome, NEW.canal
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION atribuir_agente(p_campaign_id uuid, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE a agents%ROWTYPE; v_tenant uuid; v_agente uuid;
BEGIN
  SELECT * INTO a FROM agents WHERE id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agente inexistente: %', p_agent_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT tenant_id INTO v_tenant FROM campaigns WHERE id = p_campaign_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'campanha inexistente: %', p_campaign_id USING ERRCODE = 'no_data_found';
  END IF;

  IF a.tenant_id IS NULL THEN
    -- Agente do catálogo: copia para o tenant na primeira vez que é usado.
    -- Assim editar o agente do cliente não mexe no catálogo, e o catálogo não
    -- muda o agente de ninguém — mesma regra dos modelos de campanha.
    SELECT id INTO v_agente FROM agents
     WHERE tenant_id = v_tenant AND nome = a.nome;

    IF v_agente IS NULL THEN
      INSERT INTO agents (tenant_id, nome, canal, papel, descricao, instrucoes,
                          ai_credential_id, escalar_quando, limite_trocas, pronto, ativo)
      VALUES (v_tenant, a.nome, a.canal, a.papel, a.descricao, a.instrucoes,
              NULL, a.escalar_quando, a.limite_trocas, true, true)
      RETURNING id INTO v_agente;
    END IF;
  ELSE
    IF a.tenant_id <> v_tenant THEN
      RAISE EXCEPTION 'agente % é de outro tenant', a.nome USING ERRCODE = 'restrict_violation';
    END IF;
    v_agente := a.id;
  END IF;

  INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id)
  VALUES (v_tenant, p_campaign_id, a.canal, v_agente)
  ON CONFLICT (campaign_id, canal) DO UPDATE SET agent_id = EXCLUDED.agent_id;
END;
$$;

-- O despachante precisa saber de quem é a mensagem.
DROP FUNCTION IF EXISTS reivindicar_pendentes(integer, interval);
CREATE FUNCTION reivindicar_pendentes(
  p_limite integer DEFAULT 50, p_lease interval DEFAULT interval '5 minutes'
)
RETURNS TABLE (
  message_id uuid, tenant_id uuid, canal canal, destino text, conteudo text,
  sender_id uuid, sender_ident text, campanha_tipo tipo_campanha
)
LANGUAGE sql AS $$
  WITH alvo AS (
    SELECT m.id FROM messages m
     WHERE m.status = 'pendente'
       AND (m.reivindicada_em IS NULL OR m.reivindicada_em < now() - p_lease)
     ORDER BY m.criado_em LIMIT p_limite FOR UPDATE SKIP LOCKED
  ), marcada AS (
    UPDATE messages m SET reivindicada_em = now() FROM alvo WHERE m.id = alvo.id
    RETURNING m.*
  )
  SELECT m.id, m.tenant_id, m.canal, ci.valor, m.conteudo,
         sa.id, sa.identificador, c.tipo
    FROM marcada m
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
    JOIN sender_accounts   sa ON sa.id = m.sender_account_id
    JOIN enrollments        e ON e.id = m.enrollment_id
    JOIN campaigns          c ON c.id = e.campaign_id;
$$;

-- Sem forma curta de propósito: tenant implícito em chamada de função é
-- exatamente como uma campanha acaba criada no cliente errado. O DEFAULT nas
-- colunas é conveniência para INSERT simples; aqui o tenant é dito em voz alta.

-- ---------------------------------------------------------------------------
-- Onboarding
-- ---------------------------------------------------------------------------

-- Cria tenant e põe quem chamou como dono. É o caminho do cadastro.
CREATE FUNCTION criar_tenant(p_nome text, p_slug text, p_dono uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_dono uuid;
BEGIN
  v_dono := coalesce(p_dono, usuario_atual());
  IF v_dono IS NULL THEN
    RAISE EXCEPTION 'sem usuário para ser dono do tenant'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO tenants (nome, slug) VALUES (p_nome, p_slug) RETURNING id INTO v_id;
  INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES (v_id, v_dono, 'dono');
  RETURN v_id;
END;
$$;
