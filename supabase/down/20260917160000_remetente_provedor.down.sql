-- Reverte 20260917160000_remetente_provedor.sql

DROP INDEX IF EXISTS sender_accounts_provedor_idx;

ALTER TABLE sender_accounts
  DROP COLUMN IF EXISTS credenciais_secret_id,
  DROP COLUMN IF EXISTS provedor;
