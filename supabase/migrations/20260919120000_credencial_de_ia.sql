-- Credencial de IA pelo painel do produto — o que faltava do D26.
--
-- `salvar_servidor_provedor` e `salvar_credencial_remetente` fecharam o canal:
-- token de provedor e chave de chip entram pela tela. A IA ficou de fora, e a
-- tela de Provedores de IA era um formulário morto — desenhava os campos que o
-- catálogo declara e não tinha para onde mandá-los. Quem quisesse ligar um
-- agente precisava do painel do Supabase, que é exatamente o que o D26 proíbe.
--
-- A divisão entre segredo e config não é decidida pela tela. A tela manda tudo
-- o que o usuário preencheu, num objeto só, e é aqui que o catálogo separa: o
-- que ele marca como `segredo` vai para o Vault, o resto vai para `config`.
-- Deixar isso na UI seria pedir que ela conhecesse provedor — e é justamente
-- por não conhecer nenhum que ela não quebra quando um provedor novo entra.
-- Pior: a UI errando a separação grava chave em `config`, e aí quem recusa é
-- o gatilho `ai_credentials_sem_segredo`, com erro de banco na cara do usuário.

CREATE FUNCTION salvar_credencial_ia(
  p_tenant   uuid,
  p_nome     text,
  p_provedor text,
  p_modelo   text,
  p_campos   jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE
  v_id      uuid;
  v_antigo  uuid;
  v_segredo uuid;
  v_config  jsonb;
  v_secreto jsonb;
  v_ruim    text;
BEGIN
  -- SECURITY DEFINER pula a RLS de ai_credentials, então a checagem que a
  -- política faria é feita aqui. Mesma razão das duas funções do D26.
  IF NOT privado.pode_administrar(p_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente configura provedor de IA'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM ai_provider_catalog WHERE slug = p_provedor) THEN
    RAISE EXCEPTION 'provedor de IA desconhecido: %', p_provedor
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_modelo IS NULL OR length(trim(p_modelo)) = 0 THEN
    RAISE EXCEPTION 'credencial sem modelo não serve para chamar nada'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- O catálogo manda: campo que o provedor não declara não entra, nem no Vault
  -- nem em config. Sem isto, um erro de digitação na tela viraria uma chave
  -- guardada com nome que ninguém vai ler depois.
  SELECT k INTO v_ruim
    FROM jsonb_object_keys(coalesce(p_campos, '{}'::jsonb)) k
   WHERE NOT EXISTS (
     SELECT 1 FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = p_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe no provedor %', v_ruim, p_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT id, chave_secret_id INTO v_id, v_antigo
    FROM ai_credentials WHERE tenant_id = p_tenant AND nome = p_nome;

  -- Separação pelo catálogo, não pela tela.
  SELECT
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE NOT seg), '{}'::jsonb),
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE seg AND length(trim(v)) > 0), '{}'::jsonb)
    INTO v_config, v_secreto
    FROM (
      SELECT e.key AS k, e.value #>> '{}' AS v,
             (c.campo ->> 'segredo')::boolean AS seg
        FROM jsonb_each(coalesce(p_campos, '{}'::jsonb)) e
        JOIN LATERAL (
          SELECT x AS campo FROM ai_provider_catalog p,
                 jsonb_array_elements(p.campos) x
           WHERE p.slug = p_provedor AND x ->> 'chave' = e.key
        ) c ON true
    ) s;

  -- Campo obrigatório em branco só passa quando já existe valor guardado: na
  -- edição a chave volta vazia da tela, porque segredo não é legível, e
  -- reenviar vazio não pode apagar a credencial de um agente que está rodando.
  SELECT c ->> 'rotulo' INTO v_ruim
    FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(p_campos ->> (c ->> 'chave'), ''))) = 0
     AND NOT ((c ->> 'segredo')::boolean AND v_antigo IS NOT NULL)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo obrigatório em branco: %', v_ruim
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Um segredo só por credencial: o objeto inteiro vai junto, como em
  -- `salvar_credencial_remetente`. Provedor que pede duas chaves não vira duas
  -- linhas no Vault para depois desencontrarem.
  IF v_secreto <> '{}'::jsonb THEN
    v_segredo := privado.guardar_segredo(
      'ia:' || p_provedor || ':' || p_tenant::text || ':' || gen_random_uuid()::text,
      v_secreto::text);
  ELSE
    v_segredo := v_antigo;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO ai_credentials (tenant_id, nome, provedor, modelo, chave_secret_id, config)
    VALUES (p_tenant, p_nome, p_provedor, trim(p_modelo), v_segredo, v_config)
    RETURNING id INTO v_id;
  ELSE
    UPDATE ai_credentials
       SET provedor = p_provedor, modelo = trim(p_modelo),
           chave_secret_id = v_segredo, config = v_config
     WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION salvar_credencial_ia IS
  'Grava credencial de IA a partir da tela: o catálogo separa segredo de
   config, o segredo vai para o Vault. Checa pode_administrar em código
   porque SECURITY DEFINER passa por cima da RLS (D26).';

-- O worker precisa da chave para chamar o modelo, e ninguém mais precisa.
-- Simétrica a `segredo_do_remetente` e `segredo_do_servidor`.
CREATE FUNCTION segredo_da_credencial_ia(p_credencial_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id uuid;
BEGIN
  SELECT chave_secret_id INTO v_id FROM ai_credentials WHERE id = p_credencial_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'credencial de IA inexistente: %', p_credencial_id
      USING ERRCODE = 'no_data_found';
  END IF;
  RETURN privado.ler_segredo(v_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- Superfície
-- ---------------------------------------------------------------------------

-- `salvar_credencial_ia` é API de usuário logado, como as duas do D26.
-- `segredo_da_credencial_ia` não é: devolve chave em texto claro e só o worker
-- chama. Nasce sem EXECUTE para ninguém e recebe só o service_role — conceder
-- é decisão, não default.
DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION salvar_credencial_ia(uuid, text, text, text, jsonb) FROM PUBLIC, anon';
  EXECUTE 'REVOKE ALL ON FUNCTION segredo_da_credencial_ia(uuid) FROM PUBLIC, anon';

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION salvar_credencial_ia(uuid, text, text, text, jsonb) TO authenticated';
    EXECUTE 'REVOKE ALL ON FUNCTION segredo_da_credencial_ia(uuid) FROM authenticated';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION salvar_credencial_ia(uuid, text, text, text, jsonb) TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION segredo_da_credencial_ia(uuid) TO service_role';
  END IF;
END;
$$;
