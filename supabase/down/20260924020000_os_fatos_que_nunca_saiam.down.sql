DROP TRIGGER IF EXISTS suppression_writeback ON suppression;
DROP TRIGGER IF EXISTS enrollments_writeback ON enrollments;
DROP FUNCTION IF EXISTS privado.writeback_da_supressao();
DROP FUNCTION IF EXISTS privado.writeback_do_encerramento();
DROP INDEX IF EXISTS outbox_fato_da_pessoa_uk;
