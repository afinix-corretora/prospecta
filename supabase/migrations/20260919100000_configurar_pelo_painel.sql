-- Configurar provedor pelo painel do produto, não pelo painel do Supabase.
--
-- Até aqui o token de administração da UAZAPI e as credenciais de cada chip só
-- entravam no Vault por fora — alguém abrindo o dashboard do Supabase e
-- colando. Isso não é produto: é o dono do produto tendo acesso de operador do
-- banco, e um cliente do SaaS nunca vai ter isso.
--
-- O que falta não é uma tela, é a porta de escrita. `provider_servers` tem
-- `admin_secret_id` e nenhuma forma de preenchê-lo de dentro da aplicação,
-- porque escrever no Vault é SECURITY DEFINER e nada com SECURITY DEFINER está
-- exposto ao usuário logado (D19).
--
-- Estas duas funções são a exceção justificada, e por isso checam permissão
-- explicitamente. SECURITY DEFINER pula RLS — então quem pula RLS tem que
-- perguntar, em código, o que a RLS perguntaria.

-- ---------------------------------------------------------------------------
-- Servidor do provedor
-- ---------------------------------------------------------------------------

CREATE FUNCTION salvar_servidor_provedor(
  p_tenant      uuid,
  p_provedor    text,
  p_nome        text,
  p_base_url    text,
  p_admin_token text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id uuid; v_segredo uuid; v_antigo uuid;
BEGIN
  -- SECURITY DEFINER pula a RLS de provider_servers, então a checagem que a
  -- política faria é feita aqui. Sem isto, qualquer membro do tenant trocaria
  -- o token de administração do provedor.
  IF NOT privado.pode_administrar(p_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente configura provedor'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM channel_provider_catalog WHERE slug = p_provedor AND ativo) THEN
    RAISE EXCEPTION 'provedor desconhecido: %', p_provedor USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id, admin_secret_id INTO v_id, v_antigo
    FROM provider_servers WHERE tenant_id = p_tenant AND nome = p_nome;

  -- Token em branco na edição significa "não mexe no que já está guardado" —
  -- o campo volta vazio na tela porque o segredo não é legível, e reenviar
  -- vazio não pode apagar a credencial de um servidor que está funcionando.
  IF p_admin_token IS NOT NULL AND length(trim(p_admin_token)) > 0 THEN
    v_segredo := privado.guardar_segredo(
      'servidor:' || p_provedor || ':' || p_nome || ':' || gen_random_uuid()::text,
      trim(p_admin_token));
  ELSE
    v_segredo := v_antigo;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO provider_servers (tenant_id, provedor, nome, base_url, admin_secret_id)
    VALUES (p_tenant, p_provedor, p_nome, p_base_url, v_segredo)
    RETURNING id INTO v_id;
  ELSE
    UPDATE provider_servers
       SET base_url = p_base_url, admin_secret_id = v_segredo, provedor = p_provedor
     WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION salvar_servidor_provedor IS
  'Grava servidor e manda o token de administração para o Vault, a partir da
   tela do produto. Checa pode_administrar em código porque SECURITY DEFINER
   passa por cima da RLS.';

-- ---------------------------------------------------------------------------
-- Credencial de um remetente cadastrado à mão
-- ---------------------------------------------------------------------------

-- Gupshup, Meta e SMTP não criam conta por API: o número já existe e a pessoa
-- traz a chave. Sem esta função, conectar uma conta oficial continuaria
-- dependendo de alguém com acesso ao banco.
CREATE FUNCTION salvar_credencial_remetente(
  p_sender_id   uuid,
  p_credenciais jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_tenant uuid; v_provedor text; v_segredo uuid; v_proibida text;
BEGIN
  SELECT tenant_id, provedor INTO v_tenant, v_provedor
    FROM sender_accounts WHERE id = p_sender_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remetente inexistente: %', p_sender_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT privado.pode_administrar(v_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente configura remetente'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- O catálogo manda: campo que não é do provedor não entra no Vault como se
  -- fosse credencial dele.
  SELECT k INTO v_proibida
    FROM jsonb_object_keys(p_credenciais) k
   WHERE NOT EXISTS (
     SELECT 1 FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = v_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe no provedor %', v_proibida, v_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_segredo := privado.guardar_segredo(
    'remetente:' || v_provedor || ':' || p_sender_id::text || ':' || gen_random_uuid()::text,
    p_credenciais::text);

  UPDATE sender_accounts SET credenciais_secret_id = v_segredo WHERE id = p_sender_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Superfície: estas duas SÃO API, ao contrário das outras SECURITY DEFINER
-- ---------------------------------------------------------------------------

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'salvar_servidor_provedor(uuid, text, text, text, text)',
    'salvar_credencial_remetente(uuid, jsonb)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END IF;
  END LOOP;
END;
$$;
