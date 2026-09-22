-- Reverte para a assinatura sem chip. Nota: é a versão que casa evento entre
-- clientes (D38); o down existe para a suite provar reversibilidade, não
-- porque valha a pena voltar.

DROP FUNCTION IF EXISTS registrar_evento_provedor(uuid, text, tipo_evento, timestamptz, jsonb);

CREATE FUNCTION registrar_evento_provedor(
  p_provider_id text, p_tipo tipo_evento,
  p_ocorrido_em timestamptz DEFAULT now(), p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS boolean
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE v_message uuid; v_tenant uuid;
BEGIN
  IF p_payload ->> 'autoria' = 'motor-prospeccao' THEN RETURN false; END IF;

  SELECT id, tenant_id INTO v_message, v_tenant FROM messages
   WHERE provider_message_id = p_provider_id ORDER BY criado_em DESC LIMIT 1;

  IF v_message IS NULL THEN RETURN false; END IF;

  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em, payload)
  VALUES (v_tenant, v_message, p_tipo, p_ocorrido_em, p_payload);
  RETURN true;
END;
$$;

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION registrar_evento_provedor(text, tipo_evento, timestamptz, jsonb) FROM PUBLIC, anon, authenticated';
  FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION registrar_evento_provedor(text, tipo_evento, timestamptz, jsonb) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
