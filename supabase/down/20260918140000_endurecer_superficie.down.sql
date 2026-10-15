-- Reverte o endurecimento da superfície.
--
-- Traz as funções de volta para `public`, devolve EXECUTE a PUBLIC e restaura
-- `criar_tenant` na forma única de três argumentos com DEFAULT.

DROP FUNCTION IF EXISTS criar_tenant(text, text);
DROP FUNCTION IF EXISTS criar_tenant(text, text, uuid);

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS assinatura
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'privado'
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET SCHEMA public', r.assinatura);
  END LOOP;
END;
$$;

DROP SCHEMA IF EXISTS privado CASCADE;

CREATE FUNCTION criar_tenant(p_nome text, p_slug text, p_dono uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_dono uuid;
BEGIN
  v_dono := coalesce(p_dono, usuario_atual());
  IF v_dono IS NULL THEN
    RAISE EXCEPTION 'sem usuário para ser dono do tenant'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO tenants (nome, slug) VALUES (p_nome, p_slug) RETURNING id INTO v_id;
  INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES (v_id, v_dono, 'dono');
  RETURN v_id;
END;
$$;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO PUBLIC;
