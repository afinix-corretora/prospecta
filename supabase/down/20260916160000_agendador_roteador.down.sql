-- Reverte 20260916160000_agendador_roteador.sql

DROP FUNCTION IF EXISTS inscrever(uuid, uuid, uuid, timestamptz);
DROP FUNCTION IF EXISTS processar_vencidos(integer, text);
DROP FUNCTION IF EXISTS encerrar_enrollment(uuid, motivo_encerramento);
DROP FUNCTION IF EXISTS renderizar(text, jsonb);
