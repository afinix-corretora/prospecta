-- Desfaz o D74: o segredo volta a ser nomeado pelo número. Os segredos já
-- guardados com o nome novo ficam onde estão — a conta aponta para eles pelo
-- id, e o nome nunca é lido de volta.
CREATE OR REPLACE FUNCTION public.criar_remetente_provisionado(
  p_server_id      uuid,
  p_apelido        text,
  p_identificador  text,
  p_tipo_permitido tipo_campanha,
  p_quota_diaria   integer,
  p_credenciais    jsonb,
  p_webhook_token  uuid,
  p_config         jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (sender_id uuid, webhook_token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE s provider_servers%ROWTYPE; v_canal canal; v_segredo uuid; v_id uuid; v_token uuid;
BEGIN
  SELECT * INTO s FROM provider_servers WHERE id = p_server_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'servidor inexistente: %', p_server_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT canal INTO v_canal FROM channel_provider_catalog WHERE slug = s.provedor;

  v_segredo := privado.guardar_segredo(
    'remetente:' || s.provedor || ':' || p_identificador, p_credenciais::text);

  INSERT INTO sender_accounts (
    tenant_id, canal, identificador, apelido, provedor, provider_server_id,
    tipo_permitido, quota_diaria, credenciais_secret_id, config, webhook_token)
  VALUES (
    s.tenant_id, v_canal, p_identificador, p_apelido, s.provedor, s.id,
    p_tipo_permitido, p_quota_diaria, v_segredo, p_config,
    coalesce(p_webhook_token, gen_random_uuid()))
  RETURNING id, sender_accounts.webhook_token INTO v_id, v_token;

  sender_id := v_id; webhook_token := v_token;
  RETURN NEXT;
END;
$$;
