-- Reverte 20260917100000_despacho.sql

DROP FUNCTION IF EXISTS registrar_evento_provedor(text, tipo_evento, timestamptz, jsonb);
DROP FUNCTION IF EXISTS registrar_resultado_envio(uuid, boolean, text, text);
DROP FUNCTION IF EXISTS reivindicar_pendentes(integer, interval);

DROP INDEX IF EXISTS messages_pendentes_idx;

ALTER TABLE messages DROP COLUMN IF EXISTS reivindicada_em;
