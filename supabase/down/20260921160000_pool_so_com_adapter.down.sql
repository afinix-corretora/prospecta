-- Volta o pool a ignorar o catálogo — a versão do D18, no schema de verdade.

CREATE OR REPLACE FUNCTION privado.remetentes_disponiveis(
  p_tenant uuid, p_canal canal, p_tipo tipo_campanha
)
RETURNS SETOF sender_accounts
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  SELECT * FROM sender_accounts
   WHERE tenant_id = p_tenant AND canal = p_canal AND tipo_permitido = p_tipo
     AND estado = 'ativo'
     AND (janela < current_date OR enviados_na_janela < quota_diaria)
   ORDER BY health_score DESC, enviados_na_janela ASC;
$$;

COMMENT ON FUNCTION privado.remetentes_disponiveis IS NULL;

DO $$
DECLARE papel text;
BEGIN
  FOREACH papel IN ARRAY ARRAY['anon','authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION privado.remetentes_disponiveis(uuid, canal, tipo_campanha) TO %I',
        papel);
    END IF;
  END LOOP;
END;
$$;
