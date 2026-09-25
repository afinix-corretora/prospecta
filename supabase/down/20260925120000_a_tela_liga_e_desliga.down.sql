-- Desfaz a grade por coluna: devolve o UPDATE de tabela inteira.
--
-- Reverter isto reabre o buraco descrito na migration (zerar a janela de
-- quota, escrever next_run_at). Está aqui porque toda migration é reversível,
-- não porque reverter seja uma boa ideia.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
    GRANT UPDATE ON campaigns, enrollments, sender_accounts TO authenticated;
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS privado.estreitar_escrita_do_cliente();
