-- Reverte a ingestão de contato.

DROP FUNCTION IF EXISTS ingerir_contato(uuid, text, jsonb, text, text, jsonb);
DROP FUNCTION IF EXISTS privado.normalizada(canal, text);
