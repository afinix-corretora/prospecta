-- Reverte o catálogo de provedores de canal.

DROP TRIGGER IF EXISTS sender_accounts_valida_provedor ON sender_accounts;
DROP FUNCTION IF EXISTS privado.validar_provedor_do_remetente() CASCADE;

ALTER TABLE sender_accounts DROP CONSTRAINT IF EXISTS sender_accounts_provedor_fkey;
ALTER TABLE sender_accounts DROP COLUMN IF EXISTS config;
ALTER TABLE sender_accounts DROP COLUMN IF EXISTS apelido;

DROP TABLE IF EXISTS channel_provider_catalog CASCADE;
