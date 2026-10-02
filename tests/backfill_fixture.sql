-- O legado em miniatura, com os casos que o dado real traz (D65).
--
-- Roda ANTES de `backfill/normalizar.ts`, e é por isso que a primeira
-- asserção mora aqui: gravar sem normalizar tem de ser recusado, e só dá para
-- provar isso enquanto a normalização ainda não aconteceu.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA bf;
CREATE TABLE bf.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION bf.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO bf.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
CREATE FUNCTION bf.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE; END; $$;

\set tenant '\'bf000000-0000-0000-0000-0000000000a0\''
INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Legada', 'corretora-legada');

-- O cliente já tem duas pessoas antes do backfill: Bruno, que o legado também
-- conhece (vai ser ATUALIZADO, não duplicado), e Nina partida em dois
-- contatos — o telefone num, o e-mail noutro. Juntar os dois seria fusão.
INSERT INTO contacts (id, tenant_id, nome, origem) VALUES
  ('bf000000-0000-0000-0000-0000000000c1', :tenant, 'Bruno do CRM', 'planilha'),
  ('bf000000-0000-0000-0000-0000000000c2', :tenant, NULL, 'planilha'),
  ('bf000000-0000-0000-0000-0000000000c3', :tenant, NULL, 'planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem) VALUES
  (:tenant, 'bf000000-0000-0000-0000-0000000000c1', 'whatsapp', '5511912345678', '5511912345678', 'planilha'),
  (:tenant, 'bf000000-0000-0000-0000-0000000000c2', 'whatsapp', '5511988880009', '5511988880009', 'planilha'),
  (:tenant, 'bf000000-0000-0000-0000-0000000000c3', 'email', 'nina@x.com', 'nina@x.com', 'planilha');

INSERT INTO legado.contacts (id, phone_number, name, call_name, email, is_blocked, blocked_reason,
                             first_contact_date, last_activity, created_at, updated_at) VALUES
  -- Ana: celular com nono dígito e e-mail próprio.
  ('bf000000-0000-0000-0000-000000000101', '(11) 98765-4321', 'Ana Lima', NULL, 'Ana@X.com', false, NULL, now(), now(), now(), now()),
  -- Davi: o número da Ana SEM o nono dígito, como o WhatsApp antigo guardava.
  ('bf000000-0000-0000-0000-000000000102', '551187654321', NULL, 'Davi', NULL, false, NULL, now(), now(), now(), now()),
  -- Bruno: já existe no cliente. Divide o e-mail com a Júlia.
  ('bf000000-0000-0000-0000-000000000103', '11 91234-5678', 'Bruno Legado', NULL, 'compartilhado@x.com', false, NULL, now(), now(), now(), now()),
  ('bf000000-0000-0000-0000-000000000104', '11 93333-0005', 'Júlia', NULL, 'compartilhado@x.com', false, NULL, now(), now(), now(), now()),
  -- Carla: fixo. Entra como WhatsApp (o legado afirma), sem SMS.
  ('bf000000-0000-0000-0000-000000000105', '1133334444', 'Carla Fixo', NULL, NULL, false, NULL, now(), now(), now(), now()),
  -- Eva: bloqueada pelo operador no legado.
  ('bf000000-0000-0000-0000-000000000106', '11 97777-0001', 'Eva', NULL, NULL, true, 'xingou', now(), now(), now(), now()),
  -- Telefone que não é telefone.
  ('bf000000-0000-0000-0000-000000000107', '123', 'Ninguém', NULL, 'nao-e-email', false, NULL, now(), now(), now(), now()),
  -- Nina: o telefone é de um contato do cliente e o e-mail é de outro.
  ('bf000000-0000-0000-0000-000000000108', '11 98888-0009', 'Nina', NULL, 'nina@x.com', false, NULL, now(), now(), now(), now());

INSERT INTO legado.contact_blacklist (id, phone_number, reason, source, created_at) VALUES
  ('bf000000-0000-0000-0000-000000000201', '11 96666-0002', 'pediu para sair', 'auto', now()),   -- Fábio, só aqui
  ('bf000000-0000-0000-0000-000000000202', 'abc', 'número quebrado', 'manual', now()),           -- sem telefone discável
  ('bf000000-0000-0000-0000-000000000203', '11 98888-0009', 'pare', 'auto', now());              -- Nina

INSERT INTO legado.rescue_campaigns (id, name, status, followup_count, followup_intervals_hours, cycle_enabled,
                                     delay_min_seconds, delay_max_seconds, total_leads, sent_count, responded_count,
                                     blacklisted_count, qualified_count, created_at, updated_at, messaging_provider,
                                     sdr_handover_enabled, pipefy_trigger_phase_ids, pipefy_ingest_mode, pipefy_field_map,
                                     pipefy_trigger_loss_values, layer2_enabled, layer2_inactivity_hours,
                                     layer2_levels_count, layer2_intervals_hours, layer2_on_exhaust, reactivation_mode,
                                     origin_field_value, preserve_assignee, reactivation_summary_enabled)
VALUES ('bf000000-0000-0000-0000-000000000301', 'Resgate Outubro', 'active', 3, '{24,48,72}', false,
        10, 30, 4, 0, 0, 0, 0, now(), now(), 'evolution', false, '{}', 'off', '{}', '{}', false, 24, 1, '{24}',
        'complete', 'update_origin_only', '', false, false);

INSERT INTO legado.rescue_leads (id, campaign_id, name, phone_number, city, variables, current_step, status,
                                 cycle_count, source, created_at, updated_at, layer2_step, resume_context) VALUES
  ('bf000000-0000-0000-0000-000000000401', 'bf000000-0000-0000-0000-000000000301', 'Ana L.', '11987654321', 'Sorocaba',
   '{"plano":"Amil","idade":42,"extra":{"x":1}}', 1, 'in_progress', 0, 'csv', now(), now(), 0, '{}'),
  ('bf000000-0000-0000-0000-000000000402', 'bf000000-0000-0000-0000-000000000301', 'Gil', '11 95555-0003', NULL,
   '{}', 2, 'blacklisted', 0, 'csv', now(), now(), 0, '{}'),
  ('bf000000-0000-0000-0000-000000000403', 'bf000000-0000-0000-0000-000000000301', 'Hugo', '11 94444-0004', NULL,
   '{}', 2, 'engaged', 0, 'csv', now(), now(), 0, '{}');

INSERT INTO legado.blast_campaigns (id, name, status, messaging_provider, template_variables_mapping, use_first_name,
                                    pipefy_field_map, positive_reply, created_at, updated_at, channel, sms_variations)
VALUES ('bf000000-0000-0000-0000-000000000501', 'Disparo Setembro', 'completed', 'official', '{}', true, '{}', 'sim',
        now(), now(), 'hybrid', '[]');

INSERT INTO legado.blast_leads (id, campaign_id, name, phone_number, variables, status, source, source_metadata,
                                created_at, updated_at) VALUES
  -- Descartada sem motivo: vai para o lado seguro, suprime (D13.4).
  ('bf000000-0000-0000-0000-000000000601', 'bf000000-0000-0000-0000-000000000501', 'Kátia', '11 92222-0006', '{}',
   'discarded', 'csv', '{}', now(), now()),
  -- Descartada à mão, com motivo: não suprime.
  ('bf000000-0000-0000-0000-000000000602', 'bf000000-0000-0000-0000-000000000501', 'Lia', '11 92222-0007', '{}',
   'discarded', 'csv', '{"discarded_reason":"manual"}', now(), now()),
  ('bf000000-0000-0000-0000-000000000603', 'bf000000-0000-0000-0000-000000000501', 'Bruno B.', '(11) 91234-5678', '{}',
   'sent', 'csv', '{}', now(), now());

INSERT INTO legado.broadcast_recipients (id, campaign_id, phone_number, variables, status, created_at) VALUES
  ('bf000000-0000-0000-0000-000000000701', 'bf000000-0000-0000-0000-000000000801', '11 91111-0008',
   '{"nome":"Mário"}', 'sent', now());

-- Antes de normalizar: gravar recusa, e diz por quê.
SELECT bf.confere('sem normalizar, gravar é recusado (pré-requisito)',
  bf.sqlstate_de('SELECT * FROM backfill.gravar(''bf000000-0000-0000-0000-0000000000a0'')') = '55000',
  bf.sqlstate_de('SELECT * FROM backfill.gravar(''bf000000-0000-0000-0000-0000000000a0'')'));
SELECT bf.confere('e a prévia conta o que falta normalizar',
  (SELECT quantidade > 0 FROM backfill.previa('bf000000-0000-0000-0000-0000000000a0') WHERE ordem = 0));
