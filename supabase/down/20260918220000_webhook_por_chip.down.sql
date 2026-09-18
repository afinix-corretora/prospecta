-- Reverte o webhook por chip, o Vault próprio e o provisionamento.

DROP FUNCTION IF EXISTS criar_remetente_provisionado(uuid, text, text, tipo_campanha, integer, jsonb, uuid, jsonb);
DROP FUNCTION IF EXISTS segredo_do_servidor(uuid);
DROP FUNCTION IF EXISTS registrar_resposta_por_numero(uuid, text, timestamptz, jsonb);
DROP FUNCTION IF EXISTS resolver_webhook(uuid);
DROP FUNCTION IF EXISTS segredo_do_remetente(uuid);
DROP FUNCTION IF EXISTS privado.ler_segredo(uuid);
DROP FUNCTION IF EXISTS privado.guardar_segredo(text, text);

ALTER TABLE sender_accounts DROP CONSTRAINT IF EXISTS sender_accounts_webhook_token_uk;
ALTER TABLE sender_accounts DROP COLUMN IF EXISTS webhook_token;
ALTER TABLE sender_accounts DROP CONSTRAINT IF EXISTS sender_accounts_server_tenant_fkey;
ALTER TABLE sender_accounts DROP COLUMN IF EXISTS provider_server_id;

DROP TABLE IF EXISTS provider_servers CASCADE;
