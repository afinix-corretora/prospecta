-- Reverte 20260918100000_multi_tenant_rls.sql
--
-- Volta o schema para single-tenant sem RLS. Só faz sentido antes de existir
-- mais de um tenant: com dois, reverter funde os dados de clientes diferentes,
-- então o DROP de `tenants` com CASCADE apagaria tudo junto — por isso a
-- reversão recusa quando há mais de um.

DO $$
BEGIN
  IF (SELECT count(*) FROM tenants) > 1 THEN
    RAISE EXCEPTION 'há % tenants: reverter fundiria dados de clientes diferentes',
      (SELECT count(*) FROM tenants);
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS criar_tenant(text, text, uuid);
DROP FUNCTION IF EXISTS criar_campanha_de_modelo(text, text, canal[]);
DROP FUNCTION IF EXISTS criar_campanha_de_modelo(uuid, text, text, canal[]);
DROP FUNCTION IF EXISTS reivindicar_pendentes(integer, interval);
DROP FUNCTION IF EXISTS proximo_horario_de_pool(uuid, canal, tipo_campanha);
DROP FUNCTION IF EXISTS remetentes_disponiveis(uuid, canal, tipo_campanha);
DROP FUNCTION IF EXISTS inscrever(uuid, uuid, uuid, timestamptz);
DROP FUNCTION IF EXISTS esta_suprimido(uuid, uuid, canal, text) CASCADE;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'contacts','contact_identities','campaigns','flows','flow_versions','flow_steps',
    'enrollments','messages','message_events','sender_accounts','suppression','outbox',
    'agents','ai_credentials','campaign_agents','campaign_templates','tenants','tenant_users',
    'ai_provider_catalog'
  ] LOOP
    EXECUTE format('ALTER TABLE %I DISABLE ROW LEVEL SECURITY', t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY[
    'contacts','contact_identities','campaigns','flows','flow_versions','flow_steps',
    'enrollments','messages','message_events','sender_accounts','suppression','outbox',
    'agents','ai_credentials','campaign_agents','campaign_templates'
  ] LOOP
    EXECUTE format('ALTER TABLE %I DROP COLUMN IF EXISTS tenant_id CASCADE', t);
  END LOOP;
END;
$$;

DROP TABLE IF EXISTS tenant_users;
DROP TABLE IF EXISTS tenants;

DROP FUNCTION IF EXISTS tenant_padrao();
DROP FUNCTION IF EXISTS tenant_atual();
DROP FUNCTION IF EXISTS pode_administrar(uuid);
DROP FUNCTION IF EXISTS pode_operar(uuid);
DROP FUNCTION IF EXISTS tem_papel(uuid, papel_tenant[]);
DROP FUNCTION IF EXISTS pertence_ao_tenant(uuid);
DROP FUNCTION IF EXISTS usuario_atual();

-- O tipo só sai depois das funções que o usam na assinatura.
DROP TYPE IF EXISTS papel_tenant;

-- As funções do motor voltam pelas migrations anteriores ao reaplicar.
