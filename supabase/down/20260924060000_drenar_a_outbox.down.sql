DROP FUNCTION IF EXISTS writebacks_falhados(integer);
DROP FUNCTION IF EXISTS resumo_da_outbox();
DROP FUNCTION IF EXISTS registrar_resultado_writeback(uuid, boolean, text);
DROP FUNCTION IF EXISTS reivindicar_writebacks(integer, interval);
ALTER TABLE outbox DROP COLUMN IF EXISTS reivindicada_em;
