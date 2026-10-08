-- D74: o segredo de um chip criado pela plataforma é da CONTA, não do número.
--
-- `criar_remetente_provisionado` guardava a credencial no Vault com o nome
-- `remetente:<provedor>:<número>`. Nome de segredo é único no projeto inteiro,
-- e arquivar uma conta (D62) não apaga o segredo dela — de propósito: a
-- história e o webhook ficam. Resultado: um número que já tinha sido chip
-- nunca mais virava chip pela plataforma. O D62 tinha tirado as arquivadas da
-- unicidade de `sender_accounts` justamente para "removi e quero cadastrar de
-- novo" funcionar, e o Vault desfazia isso uma camada abaixo, depois de a
-- instância já existir no provedor — que é como nasceram as 56 órfãs do D73.
--
-- O cadastro manual (`salvar_credencial_remetente`, D26) já nomeava pela conta
-- e por um sorteio. Agora as duas portas fazem igual: o id da conta é sorteado
-- antes, o segredo leva esse id no nome, e a linha nasce com ele.
--
-- O corpo abaixo parte do que está no projeto (pg_get_functiondef em 08/10),
-- que é igual ao da migration do D24 — só o nome do segredo e o id mudam. A
-- grade de privilégio não muda: CREATE OR REPLACE a preserva.

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

  v_id := gen_random_uuid();
  v_segredo := privado.guardar_segredo(
    'remetente:' || s.provedor || ':' || v_id::text || ':' || gen_random_uuid()::text,
    p_credenciais::text);

  INSERT INTO sender_accounts (
    id, tenant_id, canal, identificador, apelido, provedor, provider_server_id,
    tipo_permitido, quota_diaria, credenciais_secret_id, config, webhook_token)
  VALUES (
    v_id, s.tenant_id, v_canal, p_identificador, p_apelido, s.provedor, s.id,
    p_tipo_permitido, p_quota_diaria, v_segredo, p_config,
    coalesce(p_webhook_token, gen_random_uuid()))
  RETURNING id, sender_accounts.webhook_token INTO v_id, v_token;

  sender_id := v_id; webhook_token := v_token;
  RETURN NEXT;
END;
$$;
