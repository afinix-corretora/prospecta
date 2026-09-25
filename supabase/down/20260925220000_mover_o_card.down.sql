-- Tira a porta única e os gatilhos do funil. Os cards ficam onde estão.

DROP TRIGGER IF EXISTS suppression_funil ON suppression;
DROP TRIGGER IF EXISTS enrollments_funil_encerramento ON enrollments;
DROP TRIGGER IF EXISTS message_events_funil ON message_events;
DROP TRIGGER IF EXISTS messages_funil ON messages;
DROP TRIGGER IF EXISTS enrollments_funil ON enrollments;

DROP FUNCTION IF EXISTS privado.funil_na_supressao();
DROP FUNCTION IF EXISTS privado.funil_no_encerramento();
DROP FUNCTION IF EXISTS privado.funil_na_resposta();
DROP FUNCTION IF EXISTS privado.funil_no_envio();
DROP FUNCTION IF EXISTS privado.funil_na_inscricao();
DROP FUNCTION IF EXISTS privado.avancar_deal(uuid, uuid, text, text, text[]);
DROP FUNCTION IF EXISTS privado.garantir_deal(uuid, uuid, uuid);
DROP FUNCTION IF EXISTS mover_deal(uuid, text, origem_movimento, text);
DROP FUNCTION IF EXISTS privado.semear_funil_padrao(uuid);

-- A grade volta ao que era antes do funil.
CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
RETURNS void
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;
  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id) ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;
  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;
END;
$$;
