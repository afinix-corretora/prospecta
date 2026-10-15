-- Devolve a escrita de messages, message_events e outbox ao cliente.
--
-- Reverter isto reabre as quatro portas descritas na migration, entre elas
-- encerrar a cadência de quem não respondeu. Está aqui porque toda migration
-- é reversível.

CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id) ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;
END;
$$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT INSERT, UPDATE, DELETE ON messages, message_events, outbox TO authenticated;
  END IF;
END;
$$;
