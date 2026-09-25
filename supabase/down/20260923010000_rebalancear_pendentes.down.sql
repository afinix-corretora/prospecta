-- Reverte o rebalanceamento: volta a versão que só fazia JOIN no remetente
-- gravado. Nota: é uma volta para o comportamento do D37, não um conserto.

CREATE OR REPLACE FUNCTION reivindicar_pendentes(
  p_limite integer DEFAULT 50, p_lease interval DEFAULT interval '5 minutes'
)
RETURNS TABLE (
  message_id uuid, tenant_id uuid, canal canal, destino text, conteudo text,
  sender_id uuid, sender_ident text, campanha_tipo tipo_campanha
)
-- `SET search_path` no corpo, e não herdado: `CREATE OR REPLACE` descarta o
-- que o ALTER em massa do D19 aplicou, e o meta-teste de superfície do
-- tests/tenants.sql reprova a função sem ele. Foi ele que pegou isto aqui.
LANGUAGE sql SET search_path = public, privado AS $$
  WITH alvo AS (
    SELECT m.id FROM messages m
     WHERE m.status = 'pendente'
       AND (m.reivindicada_em IS NULL OR m.reivindicada_em < now() - p_lease)
     ORDER BY m.criado_em LIMIT p_limite FOR UPDATE SKIP LOCKED
  ), marcada AS (
    UPDATE messages m SET reivindicada_em = now() FROM alvo WHERE m.id = alvo.id
    RETURNING m.*
  )
  SELECT m.id, m.tenant_id, m.canal, ci.valor, m.conteudo,
         sa.id, sa.identificador, c.tipo
    FROM marcada m
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
    JOIN sender_accounts   sa ON sa.id = m.sender_account_id
    JOIN enrollments        e ON e.id = m.enrollment_id
    JOIN campaigns          c ON c.id = e.campaign_id;
$$;

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION reivindicar_pendentes(integer, interval) FROM PUBLIC, anon, authenticated';
  FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION reivindicar_pendentes(integer, interval) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
