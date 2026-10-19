-- Motor de Prospecção Multicanal — schema central
--
-- Primeira migration. Cria as 12 tabelas centrais e as garantias de banco das
-- quatro invariantes do CLAUDE.md.
--
-- Princípio: o que é invariante não depende de disciplina de código. Onde o
-- Postgres pode recusar a escrita errada, ele recusa. As invariantes 1 a 4 têm
-- teste automatizado em tests/invariantes.sql.
--
-- Reversível: supabase/down/20260916120000_motor_core.down.sql

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------

CREATE TYPE canal AS ENUM ('email', 'whatsapp', 'sms', 'instagram');

-- Morna = base própria com opt-in. Fria = lista sem relação prévia.
-- D4: não é rótulo. Carrega base legal e restringe o pool de remetentes.
CREATE TYPE tipo_campanha AS ENUM ('morna', 'fria');

CREATE TYPE status_enrollment AS ENUM ('ativo', 'pausado', 'encerrado');

-- D7: clique NÃO encerra. Não existe motivo 'clique' aqui, de propósito.
CREATE TYPE motivo_encerramento AS ENUM (
  'resposta',
  'mudanca_etapa_crm',
  'fim_dos_passos',
  'supressao',
  'falha_permanente'
);

-- 'simulado' é caminho de primeira classe (shadow mode), não estado de teste.
CREATE TYPE status_message AS ENUM ('pendente', 'simulado', 'enviado', 'falha');

-- Append-only. 'clique' é engajamento; 'respondido' é resposta (D7).
CREATE TYPE tipo_evento AS ENUM (
  'enfileirado', 'enviado', 'entregue', 'lido',
  'respondido', 'clique', 'falha', 'rejeitado'
);

CREATE TYPE estado_remetente AS ENUM ('ativo', 'circuito_aberto', 'desativado');

-- D3: contrato de escrita no CRM é estreito e fechado. Não há 'outro'.
CREATE TYPE fato_writeback AS ENUM (
  'opt_out', 'identidade_invalida', 'respondido', 'campanha_concluida'
);

CREATE TYPE status_outbox AS ENUM ('pendente', 'enviado', 'falha');

-- ---------------------------------------------------------------------------
-- Pessoas e endereços
-- ---------------------------------------------------------------------------

-- D1: o motor tem contatos próprios. Não há join com a base do CRM.
CREATE TABLE contacts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome          text,
  origem        text NOT NULL,
  origem_ref    text,
  metadados     jsonb NOT NULL DEFAULT '{}'::jsonb,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE contacts IS
  'Pessoa. Uma linha por indivíduo, nunca por canal (anti-regra de modelagem).';

-- Canal é adapter, pessoa é contact, endereço é contact_identity.
CREATE TABLE contact_identities (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id  uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  canal       canal NOT NULL,
  valor       text NOT NULL,
  -- Normalizado pela ingestão (D2: dedup acontece na ingestão, não no envio).
  valor_norm  text NOT NULL,
  origem      text NOT NULL,
  origem_ref  text,
  valida      boolean NOT NULL DEFAULT true,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contact_identities_valor_norm_nao_vazio CHECK (length(valor_norm) > 0)
);

-- Dedup: o mesmo endereço não existe duas vezes, nem em contatos diferentes.
CREATE UNIQUE INDEX contact_identities_canal_valor_uk
  ON contact_identities (canal, valor_norm);
CREATE INDEX contact_identities_contact_idx
  ON contact_identities (contact_id);

-- ---------------------------------------------------------------------------
-- Campanhas e flows
-- ---------------------------------------------------------------------------

CREATE TABLE campaigns (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome              text NOT NULL,
  tipo              tipo_campanha NOT NULL,
  base_legal        text NOT NULL,
  canais_habilitados canal[] NOT NULL,
  ativa             boolean NOT NULL DEFAULT true,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaigns_canais_nao_vazio CHECK (cardinality(canais_habilitados) > 0)
);

COMMENT ON COLUMN campaigns.tipo IS
  'D4: estrutural. Restringe pool de remetentes via trigger em messages.';

CREATE TABLE flows (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome      text NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now()
);

-- D9: imutável. Editar um flow cria versão nova; quem já está inscrito
-- termina na versão antiga. Garantido por trigger, não por convenção.
CREATE TABLE flow_versions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flow_id      uuid NOT NULL REFERENCES flows(id) ON DELETE CASCADE,
  versao       integer NOT NULL,
  publicado_em timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT flow_versions_versao_positiva CHECK (versao > 0),
  CONSTRAINT flow_versions_flow_versao_uk UNIQUE (flow_id, versao)
);

CREATE TABLE flow_steps (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  flow_version_id  uuid NOT NULL REFERENCES flow_versions(id) ON DELETE CASCADE,
  ordem            integer NOT NULL,
  canal            canal NOT NULL,
  atraso_horas     integer NOT NULL DEFAULT 24,
  template         text NOT NULL,
  -- D8: cadência é linear na v1. A coluna nasce agora, vazia, para evitar
  -- migração grande quando a ramificação entrar.
  condicoes        jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT flow_steps_ordem_positiva CHECK (ordem > 0),
  CONSTRAINT flow_steps_atraso_nao_negativo CHECK (atraso_horas >= 0),
  CONSTRAINT flow_steps_versao_ordem_uk UNIQUE (flow_version_id, ordem)
);

-- ---------------------------------------------------------------------------
-- Remetentes
-- ---------------------------------------------------------------------------

CREATE TABLE sender_accounts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canal                 canal NOT NULL,
  identificador         text NOT NULL,
  -- D4/D11: um remetente serve a um tipo de campanha, não aos dois. É isto que
  -- impede campanha fria de queimar o domínio ou o número institucional.
  tipo_permitido        tipo_campanha NOT NULL,
  quota_diaria          integer NOT NULL,
  janela                date NOT NULL DEFAULT current_date,
  enviados_na_janela    integer NOT NULL DEFAULT 0,
  health_score          numeric(5,2) NOT NULL DEFAULT 100.00,
  estado                estado_remetente NOT NULL DEFAULT 'ativo',
  falhas_consecutivas   integer NOT NULL DEFAULT 0,
  circuito_aberto_ate   timestamptz,
  criado_em             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sender_accounts_identificador_uk UNIQUE (canal, identificador),
  CONSTRAINT sender_accounts_quota_positiva CHECK (quota_diaria > 0),
  CONSTRAINT sender_accounts_health_faixa CHECK (health_score BETWEEN 0 AND 100),
  -- Invariante 3, no nível do banco: estourar a quota é impossível, não
  -- apenas desaconselhado.
  CONSTRAINT sender_accounts_quota_respeitada
    CHECK (enviados_na_janela >= 0 AND enviados_na_janela <= quota_diaria)
);

-- ---------------------------------------------------------------------------
-- Supressão — invariante 2
-- ---------------------------------------------------------------------------

-- Lista global e imutável. Acima de qualquer regra de campanha.
-- Suprime a pessoa (contact_id) ou o endereço (canal + valor_norm).
CREATE TABLE suppression (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id  uuid REFERENCES contacts(id) ON DELETE CASCADE,
  canal       canal,
  valor_norm  text,
  motivo      text NOT NULL,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT suppression_alvo_presente
    CHECK (contact_id IS NOT NULL OR (canal IS NOT NULL AND valor_norm IS NOT NULL))
);

CREATE UNIQUE INDEX suppression_contato_uk
  ON suppression (contact_id) WHERE contact_id IS NOT NULL AND canal IS NULL;
CREATE UNIQUE INDEX suppression_identidade_uk
  ON suppression (canal, valor_norm) WHERE valor_norm IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Enrollments — o coração
-- ---------------------------------------------------------------------------

CREATE TABLE enrollments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id          uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  campaign_id         uuid NOT NULL REFERENCES campaigns(id),
  -- D9: aponta para a VERSÃO, nunca para o flow.
  flow_version_id     uuid NOT NULL REFERENCES flow_versions(id),
  status              status_enrollment NOT NULL DEFAULT 'ativo',
  passo_atual         integer NOT NULL DEFAULT 0,
  next_run_at         timestamptz,
  encerrado_em        timestamptz,
  motivo_encerramento motivo_encerramento,
  criado_em           timestamptz NOT NULL DEFAULT now(),
  atualizado_em       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT enrollments_passo_nao_negativo CHECK (passo_atual >= 0),
  -- Encerrado tem motivo e data; ativo não tem nenhum dos dois.
  CONSTRAINT enrollments_encerramento_coerente CHECK (
    (status = 'encerrado' AND encerrado_em IS NOT NULL AND motivo_encerramento IS NOT NULL)
    OR (status <> 'encerrado' AND encerrado_em IS NULL AND motivo_encerramento IS NULL)
  )
);

-- Um contato não fica inscrito duas vezes na mesma campanha ao mesmo tempo.
CREATE UNIQUE INDEX enrollments_contato_campanha_ativo_uk
  ON enrollments (contact_id, campaign_id) WHERE status <> 'encerrado';

-- O índice que o agendador usa. Parcial: só o que está ativo importa.
CREATE INDEX enrollments_next_run_idx
  ON enrollments (next_run_at) WHERE status = 'ativo';

-- ---------------------------------------------------------------------------
-- Mensagens e eventos
-- ---------------------------------------------------------------------------

CREATE TABLE messages (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id       uuid NOT NULL REFERENCES enrollments(id) ON DELETE CASCADE,
  step_id             uuid NOT NULL REFERENCES flow_steps(id),
  contact_identity_id uuid NOT NULL REFERENCES contact_identities(id),
  sender_account_id   uuid REFERENCES sender_accounts(id),
  canal               canal NOT NULL,
  status              status_message NOT NULL DEFAULT 'pendente',
  conteudo            text NOT NULL,
  provider_message_id text,
  criado_em           timestamptz NOT NULL DEFAULT now(),
  -- Shadow mode não precisa de remetente; envio real precisa.
  CONSTRAINT messages_remetente_quando_envia CHECK (
    status = 'simulado' OR status = 'pendente' OR sender_account_id IS NOT NULL
  )
);

-- INVARIANTE 1 — idempotência. Reprocessar nunca duplica disparo.
-- O agendador reivindica o passo inserindo aqui ANTES de enviar; a colisão
-- nesta chave é o que faz dois runners concorrentes não dispararem dobrado.
CREATE UNIQUE INDEX messages_enrollment_step_uk
  ON messages (enrollment_id, step_id);

CREATE INDEX messages_enrollment_idx ON messages (enrollment_id);

-- Append-only. Status nunca é sobrescrito, é derivado daqui.
CREATE TABLE message_events (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  tipo       tipo_evento NOT NULL,
  payload    jsonb NOT NULL DEFAULT '{}'::jsonb,
  ocorrido_em timestamptz NOT NULL DEFAULT now(),
  criado_em  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX message_events_message_idx ON message_events (message_id, ocorrido_em);

-- ---------------------------------------------------------------------------
-- Outbox — writeback assíncrono (D3)
-- ---------------------------------------------------------------------------

CREATE TABLE outbox (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id          uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  destino             text NOT NULL,
  fato                fato_writeback NOT NULL,
  payload             jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Marca de autoria: o webhook de volta descarta o próprio eco por este campo.
  autoria             text NOT NULL DEFAULT 'motor-prospeccao',
  status              status_outbox NOT NULL DEFAULT 'pendente',
  tentativas          integer NOT NULL DEFAULT 0,
  proxima_tentativa_em timestamptz NOT NULL DEFAULT now(),
  ultimo_erro         text,
  criado_em           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT outbox_tentativas_nao_negativas CHECK (tentativas >= 0)
);

CREATE INDEX outbox_pendente_idx
  ON outbox (proxima_tentativa_em) WHERE status = 'pendente';

-- ===========================================================================
-- Garantias
-- ===========================================================================

-- --- Imutabilidade -------------------------------------------------------

CREATE FUNCTION recusar_escrita() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% é imutável: % recusado', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;

-- D9: flow_version publicada não muda. Editar flow cria versão nova.
CREATE TRIGGER flow_versions_imutavel
  BEFORE UPDATE OR DELETE ON flow_versions
  FOR EACH ROW EXECUTE FUNCTION recusar_escrita();

CREATE TRIGGER flow_steps_imutavel
  BEFORE UPDATE OR DELETE ON flow_steps
  FOR EACH ROW EXECUTE FUNCTION recusar_escrita();

-- message_events é append-only: status é derivado, nunca sobrescrito.
CREATE TRIGGER message_events_append_only
  BEFORE UPDATE OR DELETE ON message_events
  FOR EACH ROW EXECUTE FUNCTION recusar_escrita();

-- Supressão é imutável: entrar na lista é definitivo.
CREATE TRIGGER suppression_imutavel
  BEFORE UPDATE OR DELETE ON suppression
  FOR EACH ROW EXECUTE FUNCTION recusar_escrita();

-- --- INVARIANTE 2 — supressão -------------------------------------------

CREATE FUNCTION esta_suprimido(p_contact_id uuid, p_canal canal, p_valor_norm text)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM suppression s
    WHERE (s.contact_id = p_contact_id AND s.canal IS NULL)
       OR (s.contact_id = p_contact_id AND s.canal = p_canal)
       OR (s.canal = p_canal AND s.valor_norm = p_valor_norm)
  );
$$;

COMMENT ON FUNCTION esta_suprimido IS
  'Gate de supressão. O roteador chama antes do adapter; o trigger em messages
   garante que nenhum caminho de código escape, inclusive em shadow mode.';

-- O roteador checa antes de enviar. Este trigger existe para que a invariante
-- não dependa de o roteador ter sido chamado: nenhum INSERT em messages passa
-- se o destino está suprimido, por nenhum caminho de código.
CREATE FUNCTION barrar_mensagem_suprimida() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_contact_id uuid;
  v_valor_norm text;
  v_canal      canal;
BEGIN
  SELECT ci.contact_id, ci.valor_norm, ci.canal
    INTO v_contact_id, v_valor_norm, v_canal
  FROM contact_identities ci
  WHERE ci.id = NEW.contact_identity_id;

  IF esta_suprimido(v_contact_id, v_canal, v_valor_norm) THEN
    RAISE EXCEPTION 'destino suprimido: contato % no canal %', v_contact_id, v_canal
      USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER messages_respeita_supressao
  BEFORE INSERT ON messages
  FOR EACH ROW EXECUTE FUNCTION barrar_mensagem_suprimida();

-- --- D4 — isolamento de raio de explosão --------------------------------

-- Campanha fria nunca usa remetente da operação morna, e vice-versa.
-- Schema, não disciplina operacional.
CREATE FUNCTION barrar_remetente_incompativel() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_tipo_campanha tipo_campanha;
  v_tipo_permitido tipo_campanha;
  v_canal_remetente canal;
BEGIN
  IF NEW.sender_account_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT c.tipo INTO v_tipo_campanha
  FROM enrollments e JOIN campaigns c ON c.id = e.campaign_id
  WHERE e.id = NEW.enrollment_id;

  SELECT sa.tipo_permitido, sa.canal INTO v_tipo_permitido, v_canal_remetente
  FROM sender_accounts sa WHERE sa.id = NEW.sender_account_id;

  IF v_tipo_permitido <> v_tipo_campanha THEN
    RAISE EXCEPTION 'remetente de campanha % usado em campanha %',
      v_tipo_permitido, v_tipo_campanha
      USING ERRCODE = 'restrict_violation';
  END IF;

  IF v_canal_remetente <> NEW.canal THEN
    RAISE EXCEPTION 'remetente do canal % usado para mensagem de canal %',
      v_canal_remetente, NEW.canal
      USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER messages_respeita_pool
  BEFORE INSERT ON messages
  FOR EACH ROW EXECUTE FUNCTION barrar_remetente_incompativel();

-- --- INVARIANTE 3 — rate limit por remetente ----------------------------

-- Reserva uma vaga de envio. Retorna false se o remetente está sem quota,
-- com circuito aberto ou desativado. Atômico: o UPDATE condicional é a trava.
CREATE FUNCTION reservar_envio(p_sender_id uuid) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
  v_ok boolean;
BEGIN
  -- Vira a janela antes de avaliar a quota.
  UPDATE sender_accounts
     SET janela = current_date, enviados_na_janela = 0
   WHERE id = p_sender_id AND janela < current_date;

  -- Fecha o circuito quando o prazo passou.
  UPDATE sender_accounts
     SET estado = 'ativo', falhas_consecutivas = 0, circuito_aberto_ate = NULL
   WHERE id = p_sender_id
     AND estado = 'circuito_aberto'
     AND circuito_aberto_ate IS NOT NULL
     AND circuito_aberto_ate <= now();

  UPDATE sender_accounts
     SET enviados_na_janela = enviados_na_janela + 1
   WHERE id = p_sender_id
     AND estado = 'ativo'
     AND enviados_na_janela < quota_diaria
  RETURNING true INTO v_ok;

  RETURN coalesce(v_ok, false);
END;
$$;

-- Conta com erro sai do pool sozinha; os pendentes rebalanceiam porque
-- remetentes_disponiveis deixa de retorná-la.
CREATE FUNCTION registrar_falha_remetente(
  p_sender_id uuid,
  p_limite integer DEFAULT 5,
  p_janela interval DEFAULT interval '30 minutes'
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE sender_accounts
     SET falhas_consecutivas = falhas_consecutivas + 1,
         health_score = greatest(0, health_score - 10),
         estado = CASE WHEN falhas_consecutivas + 1 >= p_limite
                       THEN 'circuito_aberto'::estado_remetente ELSE estado END,
         circuito_aberto_ate = CASE WHEN falhas_consecutivas + 1 >= p_limite
                       THEN now() + p_janela ELSE circuito_aberto_ate END
   WHERE id = p_sender_id;
END;
$$;

CREATE FUNCTION registrar_sucesso_remetente(p_sender_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE sender_accounts
     SET falhas_consecutivas = 0,
         health_score = least(100, health_score + 1)
   WHERE id = p_sender_id;
END;
$$;

-- O pool que o roteador enxerga.
CREATE FUNCTION remetentes_disponiveis(p_canal canal, p_tipo tipo_campanha)
RETURNS SETOF sender_accounts
LANGUAGE sql STABLE AS $$
  SELECT * FROM sender_accounts
   WHERE canal = p_canal
     AND tipo_permitido = p_tipo
     AND estado = 'ativo'
     AND (janela < current_date OR enviados_na_janela < quota_diaria)
   ORDER BY health_score DESC, enviados_na_janela ASC;
$$;

-- --- INVARIANTE 4 — encerramento global ---------------------------------

-- Resposta em QUALQUER canal encerra o enrollment inteiro, não só o passo.
-- D7: clique é engajamento e não encerra — por isso o trigger só olha
-- 'respondido'.
CREATE FUNCTION encerrar_por_resposta() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_contact_id uuid;
BEGIN
  IF NEW.tipo <> 'respondido' THEN
    RETURN NEW;
  END IF;

  SELECT e.contact_id INTO v_contact_id
  FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
  WHERE m.id = NEW.message_id;

  -- Todos os enrollments do contato, em qualquer campanha e canal.
  UPDATE enrollments
     SET status = 'encerrado',
         encerrado_em = now(),
         motivo_encerramento = 'resposta',
         next_run_at = NULL,
         atualizado_em = now()
   WHERE contact_id = v_contact_id
     AND status <> 'encerrado';

  RETURN NEW;
END;
$$;

CREATE TRIGGER message_events_encerra_enrollment
  AFTER INSERT ON message_events
  FOR EACH ROW EXECUTE FUNCTION encerrar_por_resposta();

-- --- Agendador -----------------------------------------------------------

-- O batch do agendador. SKIP LOCKED: dois workers concorrentes pegam lotes
-- disjuntos em vez de brigar pela mesma linha.
CREATE FUNCTION proximos_vencidos(p_limite integer DEFAULT 100)
RETURNS SETOF enrollments
LANGUAGE sql AS $$
  SELECT * FROM enrollments
   WHERE status = 'ativo' AND next_run_at IS NOT NULL AND next_run_at <= now()
   ORDER BY next_run_at
   LIMIT p_limite
   FOR UPDATE SKIP LOCKED;
$$;

-- --- atualizado_em -------------------------------------------------------

CREATE FUNCTION tocar_atualizado_em() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.atualizado_em = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER contacts_atualizado_em
  BEFORE UPDATE ON contacts
  FOR EACH ROW EXECUTE FUNCTION tocar_atualizado_em();

CREATE TRIGGER enrollments_atualizado_em
  BEFORE UPDATE ON enrollments
  FOR EACH ROW EXECUTE FUNCTION tocar_atualizado_em();
