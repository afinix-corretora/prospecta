DROP FUNCTION IF EXISTS prever_inscricao_pela_campanha(uuid, uuid, uuid[]);
DROP FUNCTION IF EXISTS inscrever_pela_campanha(uuid, uuid, timestamptz);
DROP FUNCTION IF EXISTS definir_flow_da_campanha(uuid, uuid);
ALTER TABLE campaigns DROP CONSTRAINT IF EXISTS campaigns_flow_version_tenant_fkey;
ALTER TABLE campaigns DROP COLUMN IF EXISTS flow_version_id;
