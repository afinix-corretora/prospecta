-- Volta a função ao corpo do D57: ela perde as tabelas de credencial, o
-- servidor de provedor e os catálogos.
--
-- O corpo abaixo é o do D57 literalmente — inclusive as revogações do funil e o
-- `SET search_path`. Escrever um down a partir de uma cópia mais antiga apaga o
-- que entrou no meio, e foi assim que a primeira versão desta migration
-- derrubou o `deals` do D57 sem que nada na migration falasse de funil.
--
-- O down NÃO devolve o privilégio largo às tabelas. Reverter uma revogação de
-- segurança reabrindo a porta seria o único down do repositório que piora o
-- estado que encontrou.
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

  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;
END;
$$;
