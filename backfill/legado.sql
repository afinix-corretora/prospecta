-- Onde o dado do legado pousa antes do backfill (Fase 2).
--
-- Ferramenta, não schema de runtime — como `mapa_status.sql`. Vive fora de
-- `supabase/migrations/` porque é carregada para a migração de dados e
-- apagada depois, junto com tudo o que ela recebeu.
--
-- As onze tabelas abaixo têm as colunas e os tipos REAIS do projeto legado
-- `gtivnngoeccqbvfjiyne`, lidos do banco reconstruído a partir das 97
-- migrations do repositório dele (`sdr-resgate-evolution`), e não escritos à
-- mão: o backfill que adivinha coluna é o que quebra no dia, com o dado de
-- verdade na mão. Sem FK e sem CHECK de propósito: o dado chega como veio, e
-- quem decide o que é aceitável é `backfill.previa`, que conta e diz.
--
-- Como chegam: `pg_dump --data-only --table=public.<tabela>` no legado,
-- restaurado com o schema trocado para `legado`, ou o `copy` do psql, tabela a tabela.
-- Quem tem acesso ao legado faz isso; o motor nunca lê o legado direto.
--
-- `legado` não entra em "Exposed schemas" (é o mesmo motivo de `privado`):
-- é dado pessoal em trânsito, e não é API.

CREATE SCHEMA IF NOT EXISTS legado;
REVOKE ALL ON SCHEMA legado FROM PUBLIC;

CREATE TABLE legado.blast_campaigns (
  id uuid PRIMARY KEY,
  user_id uuid,
  name text,
  status text,
  messaging_provider text,
  official_api_config_id uuid,
  instance_id uuid,
  template_id text,
  template_name text,
  template_variables_mapping jsonb,
  use_first_name boolean,
  pipefy_pipe_id text,
  pipefy_target_phase_id text,
  pipefy_target_phase_name text,
  pipefy_field_map jsonb,
  origin_field_id text,
  origin_field_value text,
  positive_reply text,
  send_hours_start integer,
  send_hours_end integer,
  send_weekdays integer[],
  delay_min_seconds integer,
  delay_max_seconds integer,
  total_leads integer,
  sent_count integer,
  positive_count integer,
  discarded_count integer,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  channel text,
  comtele_credential_id uuid,
  sms_text text,
  sms_variations jsonb,
  ai_summarize_model text
);

CREATE TABLE legado.blast_leads (
  id uuid PRIMARY KEY,
  campaign_id uuid,
  contact_id uuid,
  name text,
  phone_number text,
  city text,
  variables jsonb,
  status text,
  sent_at timestamp with time zone,
  responded_at timestamp with time zone,
  source text,
  source_metadata jsonb,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  wa_status text,
  sms_status text
);

CREATE TABLE legado.blast_message_logs (
  id uuid PRIMARY KEY,
  campaign_id uuid,
  lead_id uuid,
  direction text,
  content text,
  created_at timestamp with time zone
);

CREATE TABLE legado.broadcast_campaigns (
  id uuid PRIMARY KEY,
  user_id uuid,
  name text,
  message_template text,
  message_type text,
  media_url text,
  instance_id uuid,
  delay_min_ms integer,
  delay_max_ms integer,
  column_mapping jsonb,
  custom_fields text[],
  status text,
  total_recipients integer,
  sent_count integer,
  failed_count integer,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  batch_size integer,
  delay_between_batches integer,
  next_batch_at timestamp with time zone
);

CREATE TABLE legado.broadcast_recipients (
  id uuid PRIMARY KEY,
  campaign_id uuid,
  phone_number text,
  variables jsonb,
  status text,
  error_message text,
  sent_at timestamp with time zone,
  created_at timestamp with time zone
);

CREATE TABLE legado.contact_blacklist (
  id uuid PRIMARY KEY,
  user_id uuid,
  phone_number text,
  contact_id uuid,
  reason text,
  detected_keyword text,
  triggering_message text,
  source text,
  blocked_by uuid,
  notes text,
  created_at timestamp with time zone
);

CREATE TABLE legado.contacts (
  id uuid PRIMARY KEY,
  phone_number text,
  whatsapp_id text,
  name text,
  call_name text,
  email text,
  profile_picture_url text,
  is_business boolean,
  is_blocked boolean,
  blocked_at timestamp with time zone,
  blocked_reason text,
  tags text[],
  notes text,
  client_memory jsonb,
  first_contact_date timestamp with time zone,
  last_activity timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  user_id uuid,
  instance_id uuid
);

CREATE TABLE legado.rescue_campaigns (
  id uuid PRIMARY KEY,
  user_id uuid,
  name text,
  description text,
  status text,
  instance_id uuid,
  followup_count integer,
  followup_intervals_hours integer[],
  cycle_enabled boolean,
  cycle_interval_days integer,
  cycle_max_restarts integer,
  delay_min_seconds integer,
  delay_max_seconds integer,
  send_hours_start time without time zone,
  send_hours_end time without time zone,
  send_weekdays integer[],
  total_leads integer,
  sent_count integer,
  responded_count integer,
  blacklisted_count integer,
  qualified_count integer,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  messaging_provider text,
  official_api_config_id uuid,
  sdr_handover_enabled boolean,
  pipefy_pipe_id text,
  pipefy_trigger_phase_ids text[],
  pipefy_ingest_mode text,
  pipefy_field_map jsonb,
  pipefy_loss_field_id text,
  pipefy_loss_field_label text,
  pipefy_trigger_loss_values text[],
  layer2_enabled boolean,
  layer2_inactivity_hours integer,
  layer2_levels_count integer,
  layer2_intervals_hours integer[],
  layer2_on_exhaust text,
  reactivation_mode text,
  reactivation_phase_id text,
  reactivation_phase_name text,
  origin_field_id text,
  origin_field_value text,
  preserve_assignee boolean,
  pipefy_responsible_field_id text,
  reactivation_summary_field_id text,
  reactivation_summary_enabled boolean
);

CREATE TABLE legado.rescue_leads (
  id uuid PRIMARY KEY,
  campaign_id uuid,
  contact_id uuid,
  name text,
  phone_number text,
  city text,
  variables jsonb,
  current_step integer,
  status text,
  cycle_count integer,
  next_scheduled_at timestamp with time zone,
  source text,
  source_metadata jsonb,
  first_sent_at timestamp with time zone,
  last_sent_at timestamp with time zone,
  responded_at timestamp with time zone,
  blacklisted_at timestamp with time zone,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  layer2_step integer,
  last_client_message_at timestamp with time zone,
  layer2_last_sent_at timestamp with time zone,
  resume_context jsonb,
  disqualified_at timestamp with time zone,
  disqualified_reason text
);

CREATE TABLE legado.rescue_message_logs (
  id uuid PRIMARY KEY,
  lead_id uuid,
  campaign_id uuid,
  sequence_order integer,
  tone text,
  content text,
  status text,
  error_message text,
  whatsapp_message_id text,
  sent_at timestamp with time zone
);

CREATE TABLE legado.rescue_messages (
  id uuid PRIMARY KEY,
  campaign_id uuid,
  sequence_order integer,
  tone text,
  message_template text,
  message_type text,
  media_url text,
  label text,
  created_at timestamp with time zone,
  updated_at timestamp with time zone,
  template_id uuid,
  template_variables_mapping jsonb,
  ai_takeover_enabled boolean,
  layer integer
);

-- ---------------------------------------------------------------------------
-- O que o TypeScript devolve: a normalização, feita num lugar só (D32)
-- ---------------------------------------------------------------------------
--
-- `backfill/normalizar.ts` lê os valores brutos (`legado.brutos`) e escreve
-- aqui o que `adapters/telefone.ts` e `adapters/email.ts` dizem deles. O SQL
-- do backfill só LÊ estas tabelas; normalizar de novo aqui seria a segunda
-- normalização, e a divergência aparece como supressão furada.

CREATE TABLE legado.telefones (
  bruto      text PRIMARY KEY,
  valor_norm text,
  valido     boolean NOT NULL,
  celular    boolean NOT NULL
);

CREATE TABLE legado.emails (
  bruto      text PRIMARY KEY,
  valor_norm text,
  valido     boolean NOT NULL
);

-- Os valores que precisam passar pelo TypeScript, sem repetição.
CREATE VIEW legado.brutos AS
  SELECT 'telefone' AS tipo, v AS bruto FROM (
    SELECT phone_number FROM legado.contacts
    UNION SELECT phone_number FROM legado.contact_blacklist
    UNION SELECT phone_number FROM legado.rescue_leads
    UNION SELECT phone_number FROM legado.blast_leads
    UNION SELECT phone_number FROM legado.broadcast_recipients
  ) t(v) WHERE v IS NOT NULL AND v NOT IN (SELECT bruto FROM legado.telefones)
  UNION ALL
  SELECT 'email', email FROM legado.contacts
   WHERE email IS NOT NULL AND trim(email) <> ''
     AND email NOT IN (SELECT bruto FROM legado.emails);
