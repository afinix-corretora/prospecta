-- O que a auditoria achou (D77).
--
-- A auditoria pedida em 12/10 ("verifique cada tela, migração, o setup e os
-- prompts") levantou achados com verificação adversarial; o D76 corrigiu os do
-- agente, e esta migration corrige os do banco que não podiam esperar:
--
--   destino da chave   a chave guardada foi dada a UM destino. As quatro
--                      funções de credencial a reaproveitavam em branco depois
--                      de trocar o provedor ou o endereço: a chave da Anthropic
--                      ia para a OpenAI, o token do chip para o servidor novo.
--                      O catálogo passa a marcar quais campos são destino
--                      (`"destino": true`), e trocar qualquer um pede a chave
--                      de novo. De carona, campo não secreto que a tela não
--                      mandou fica como estava — editar só o modelo apagava a
--                      organização da OpenAI e o base_url do proxy.
--   conta órfã         conectar conta era INSERT pela tela e o segredo numa
--                      segunda chamada. Credencial recusada deixava a conta
--                      ativa, no pool e sem segredo: o agendador a escolhia e
--                      o despacho queimava o passo do lead. `conectar_conta`
--                      faz as duas na mesma transação — o D55 ("criar num
--                      lugar e completar no outro") pela terceira vez.
--   funil              renomear o slug de um estágio (um operador podia) fazia
--                      `mover_deal` lançar dentro do gatilho da resposta: a
--                      resposta não era gravada, a cadência seguia e o "pare"
--                      não suprimia. O motor não move mais para estágio que não
--                      existe, e a grade deixa a tela só renomear, pintar e
--                      reordenar.
--   agendador          campanha desligada entrava no lote e voltava à cabeça
--                      da fila: 100 vencidos dela ocupavam o LIMIT de todas as
--                      batidas, e nenhuma outra campanha criava mensagem.
--   busca de contatos  o filtro `or` citava coluna de tabela embutida, que a
--                      gramática do PostgREST recusa: a busca nunca funcionou.
--                      Vira função, com o termo escapado e o cliente explícito.
--   TRUNCATE           não passa pelo RLS, e o Supabase o dá a authenticated.
--
-- Os corpos substituídos partiram do que está no projeto, conferido por md5
-- antes de aplicar (D59), e o down os devolve exatos.

-- ---------------------------------------------------------------------------
-- 1. O catálogo diz para onde a chave vai
-- ---------------------------------------------------------------------------

-- O mesmo endereço, escrito com ou sem barra no fim, em maiúscula ou não.
-- Errar para o lado de "mudou" só pede a chave de novo; errar para o outro
-- manda a chave para outro lugar.
CREATE FUNCTION privado.mesmo_destino(a text, b text)
RETURNS boolean LANGUAGE sql IMMUTABLE
SET search_path TO 'pg_catalog'
AS $$
  SELECT lower(rtrim(btrim(coalesce(a, '')), '/')) = lower(rtrim(btrim(coalesce(b, '')), '/'))
$$;
REVOKE ALL ON FUNCTION privado.mesmo_destino(text, text) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION privado.mesmo_destino(text, text) FROM anon;
  END IF;
END $$;

-- Os campos que decidem o servidor que recebe a chave. A ordem do array não
-- muda: a tela desenha os campos nela.
DO $$
DECLARE r record; n integer;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('ai_provider_catalog',      'anthropic',     'base_url'),
      ('ai_provider_catalog',      'compativel',    'base_url'),
      ('ai_provider_catalog',      'deepseek',      'base_url'),
      ('ai_provider_catalog',      'openai',        'base_url'),
      ('crm_provider_catalog',     'profitcare',    'base_url'),
      ('crm_provider_catalog',     'pipedrive',     'dominio_empresa'),
      ('crm_provider_catalog',     'salesforce',    'dominio'),
      ('crm_provider_catalog',     'zoho_crm',      'data_center'),
      ('channel_provider_catalog', 'evolution',     'base_url'),
      ('channel_provider_catalog', 'gupshup',       'base_url'),
      ('channel_provider_catalog', 'uazapi',        'base_url'),
      ('channel_provider_catalog', 'smtp',          'host')
    ) v(tabela, slug, chave)
  LOOP
    EXECUTE format(
      'UPDATE %I SET campos = (SELECT jsonb_agg(CASE WHEN x ->> ''chave'' = $2
                                                       THEN x || ''{"destino": true}''::jsonb ELSE x END
                                                  ORDER BY o)
                                 FROM jsonb_array_elements(campos) WITH ORDINALITY t(x, o))
        WHERE slug = $1', r.tabela)
      USING r.slug, r.chave;
    -- EXECUTE não mexe em FOUND: quem diz quantas linhas mudou é o diagnóstico.
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> 1 THEN
      RAISE EXCEPTION 'catálogo % sem o provedor %', r.tabela, r.slug;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. As funções que guardam chave, o funil, o agendador e a grade
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.salvar_credencial_ia(p_tenant uuid, p_nome text, p_provedor text, p_modelo text, p_campos jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  v_id      uuid;
  v_antigo  uuid;
  v_segredo uuid;
  v_config  jsonb;
  v_secreto jsonb;
  v_ruim    text;
  -- D77
  v_prov_antigo text;
  v_cfg_antigo  jsonb;
  v_reusa       boolean;
  v_e_segredo   boolean;
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

  SELECT id, chave_secret_id, provedor, config
    INTO v_id, v_antigo, v_prov_antigo, v_cfg_antigo
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

  -- D77: campo não secreto que a tela não mandou fica como estava. O
  -- formulário abre vazio, e editar só o modelo apagava em silêncio a
  -- organização da OpenAI, o base_url do proxy e a organização do Pipefy.
  -- Mandar o campo vazio continua limpando. Trocar de provedor não herda
  -- nada: a configuração de um não serve ao outro.
  IF v_id IS NOT NULL AND v_prov_antigo = p_provedor THEN
    v_config := coalesce(v_cfg_antigo, '{}'::jsonb) || v_config;
  END IF;

  -- D77: a chave guardada foi dada a UM destino — o provedor e os campos que
  -- o catálogo marca como `destino` (o endereço, o domínio, o data center).
  -- Reaproveitá-la em branco depois de trocar qualquer um deles mandava a
  -- chave da Anthropic para a OpenAI, ou para o endereço recém-digitado, com
  -- "Credencial atualizada." na tela. E trocar uma das chaves pede as
  -- outras junto: o segredo é um objeto só, e a que não veio sumiria dele.
  v_reusa := v_antigo IS NOT NULL
        AND v_prov_antigo = p_provedor
        AND v_secreto = '{}'::jsonb
        AND NOT EXISTS (
              SELECT 1 FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
               WHERE p.slug = p_provedor AND coalesce((c ->> 'destino')::boolean, false)
                 AND NOT privado.mesmo_destino(v_config ->> (c ->> 'chave'),
                                               v_cfg_antigo ->> (c ->> 'chave')));

  -- Campo obrigatório em branco só passa quando já existe valor guardado: na
  -- edição a chave volta vazia da tela, porque segredo não é legível, e
  -- reenviar vazio não pode apagar a credencial de um agente que está rodando.
  SELECT c ->> 'rotulo', coalesce((c ->> 'segredo')::boolean, false)
    INTO v_ruim, v_e_segredo
    FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(CASE WHEN (c ->> 'segredo')::boolean
                                   THEN v_secreto ->> (c ->> 'chave')
                                   ELSE v_config ->> (c ->> 'chave') END, ''))) = 0
     AND NOT ((c ->> 'segredo')::boolean AND v_reusa)
   LIMIT 1;

  -- D77: a recusa diz POR QUE a chave guardada não vale mais.
  IF v_ruim IS NOT NULL AND v_e_segredo AND v_antigo IS NOT NULL THEN
    RAISE EXCEPTION '%', CASE
        WHEN v_secreto <> '{}'::jsonb
          THEN 'trocar uma das chaves pede as outras junto: ' || v_ruim
        WHEN v_prov_antigo IS DISTINCT FROM p_provedor
          THEN 'trocar o provedor pede a chave nova — a guardada é do ' || v_prov_antigo || ': ' || v_ruim
        ELSE 'mudar o endereço pede a chave de novo — a guardada foi dada para o anterior: ' || v_ruim
      END USING ERRCODE = 'invalid_parameter_value';
  END IF;

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
  ELSIF v_reusa THEN
    v_segredo := v_antigo;
  ELSE
    v_segredo := NULL;
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
$function$;

CREATE OR REPLACE FUNCTION public.salvar_credencial_crm(p_tenant uuid, p_nome text, p_provedor text, p_campos jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  v_id      uuid;
  v_antigo  uuid;
  v_segredo uuid;
  v_config  jsonb;
  v_secreto jsonb;
  v_ruim    text;
  -- D77
  v_prov_antigo text;
  v_cfg_antigo  jsonb;
  v_reusa       boolean;
  v_e_segredo   boolean;
BEGIN
  -- SECURITY DEFINER pula a RLS de crm_connections, então a checagem que a
  -- política faria é feita aqui. Mesma razão das outras três funções de
  -- credencial.
  IF NOT privado.pode_administrar(p_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente vincula plataforma'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM crm_provider_catalog WHERE slug = p_provedor) THEN
    RAISE EXCEPTION 'plataforma desconhecida: %', p_provedor
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_nome IS NULL OR length(trim(p_nome)) = 0 THEN
    RAISE EXCEPTION 'conexão sem nome não dá para escolher depois'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Campo que o provedor não declara não entra, nem no Vault nem em config.
  SELECT k INTO v_ruim
    FROM jsonb_object_keys(coalesce(p_campos, '{}'::jsonb)) k
   WHERE NOT EXISTS (
     SELECT 1 FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = p_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe na plataforma %', v_ruim, p_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT id, credencial_secret_id, provedor, config
    INTO v_id, v_antigo, v_prov_antigo, v_cfg_antigo
    FROM crm_connections WHERE tenant_id = p_tenant AND nome = trim(p_nome);

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
          SELECT x AS campo FROM crm_provider_catalog p,
                 jsonb_array_elements(p.campos) x
           WHERE p.slug = p_provedor AND x ->> 'chave' = e.key
        ) c ON true
    ) s;

  -- D77: campo não secreto que a tela não mandou fica como estava. O
  -- formulário abre vazio, e editar só o modelo apagava em silêncio a
  -- organização da OpenAI, o base_url do proxy e a organização do Pipefy.
  -- Mandar o campo vazio continua limpando. Trocar de provedor não herda
  -- nada: a configuração de um não serve ao outro.
  IF v_id IS NOT NULL AND v_prov_antigo = p_provedor THEN
    v_config := coalesce(v_cfg_antigo, '{}'::jsonb) || v_config;
  END IF;

  -- D77: a chave guardada foi dada a UM destino — o provedor e os campos que
  -- o catálogo marca como `destino` (o endereço, o domínio, o data center).
  -- Reaproveitá-la em branco depois de trocar qualquer um deles mandava a
  -- chave da Anthropic para a OpenAI, ou para o endereço recém-digitado, com
  -- "Credencial atualizada." na tela. E trocar uma das chaves pede as
  -- outras junto: o segredo é um objeto só, e a que não veio sumiria dele.
  v_reusa := v_antigo IS NOT NULL
        AND v_prov_antigo = p_provedor
        AND v_secreto = '{}'::jsonb
        AND NOT EXISTS (
              SELECT 1 FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
               WHERE p.slug = p_provedor AND coalesce((c ->> 'destino')::boolean, false)
                 AND NOT privado.mesmo_destino(v_config ->> (c ->> 'chave'),
                                               v_cfg_antigo ->> (c ->> 'chave')));

  -- Campo obrigatório em branco só passa quando já existe valor guardado: na
  -- edição o segredo volta vazio da tela, porque segredo não é legível, e
  -- reenviar vazio não pode apagar a credencial de uma conexão em uso.
  SELECT c ->> 'rotulo', coalesce((c ->> 'segredo')::boolean, false)
    INTO v_ruim, v_e_segredo
    FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(CASE WHEN (c ->> 'segredo')::boolean
                                   THEN v_secreto ->> (c ->> 'chave')
                                   ELSE v_config ->> (c ->> 'chave') END, ''))) = 0
     AND NOT ((c ->> 'segredo')::boolean AND v_reusa)
   LIMIT 1;

  -- D77: a recusa diz POR QUE a chave guardada não vale mais.
  IF v_ruim IS NOT NULL AND v_e_segredo AND v_antigo IS NOT NULL THEN
    RAISE EXCEPTION '%', CASE
        WHEN v_secreto <> '{}'::jsonb
          THEN 'trocar uma das chaves pede as outras junto: ' || v_ruim
        WHEN v_prov_antigo IS DISTINCT FROM p_provedor
          THEN 'trocar o provedor pede a chave nova — a guardada é do ' || v_prov_antigo || ': ' || v_ruim
        ELSE 'mudar o endereço pede a chave de novo — a guardada foi dada para o anterior: ' || v_ruim
      END USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo obrigatório em branco: %', v_ruim
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Um segredo só por conexão, com o objeto inteiro junto. Salesforce e Zoho
  -- pedem duas chaves cada; duas linhas no Vault desencontram na primeira
  -- rotação de credencial.
  IF v_secreto <> '{}'::jsonb THEN
    v_segredo := privado.guardar_segredo(
      'crm:' || p_provedor || ':' || p_tenant::text || ':' || gen_random_uuid()::text,
      v_secreto::text);
  ELSIF v_reusa THEN
    v_segredo := v_antigo;
  ELSE
    v_segredo := NULL;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO crm_connections (tenant_id, nome, provedor, credencial_secret_id, config)
    VALUES (p_tenant, trim(p_nome), p_provedor, v_segredo, v_config)
    RETURNING id INTO v_id;
  ELSE
    UPDATE crm_connections
       SET provedor = p_provedor, credencial_secret_id = v_segredo, config = v_config
     WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.salvar_credencial_remetente(p_sender_id uuid, p_credenciais jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  v_tenant uuid; v_provedor text; v_segredo uuid; v_proibida text;
  v_id_antigo uuid; v_antigo jsonb; v_final jsonb;
  v_mudou_destino boolean; v_e_segredo boolean;
BEGIN
  SELECT tenant_id, provedor, credenciais_secret_id
    INTO v_tenant, v_provedor, v_id_antigo
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
    FROM jsonb_object_keys(coalesce(p_credenciais, '{}'::jsonb)) k
   WHERE NOT EXISTS (
     SELECT 1 FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = v_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe no provedor %', v_proibida, v_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_antigo := coalesce(nullif(privado.ler_segredo(v_id_antigo), ''), '{}')::jsonb;

  -- D77: o segredo guardado foi dado a um destino. Mudar o endereço (o
  -- `base_url` da UAZAPI, da Evolution e da Gupshup, o `host` do SMTP) e
  -- reaproveitar a chave em branco mandava a chave para o servidor novo.
  v_mudou_destino := EXISTS (
    SELECT 1 FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
     WHERE p.slug = v_provedor AND coalesce((c ->> 'destino')::boolean, false)
       AND NOT privado.mesmo_destino(nullif(trim(coalesce(p_credenciais ->> (c ->> 'chave'), '')), ''),
                                     v_antigo ->> (c ->> 'chave')));

  -- O blob final: o que veio da tela, com o segredo antigo preservado quando a
  -- tela mandou branco. Percorre o catálogo, e não as chaves recebidas, porque
  -- o valor guardado de um campo que a tela nem enviou também precisa entrar.
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) INTO v_final
    FROM (
      SELECT c ->> 'chave' AS k,
             CASE WHEN (c ->> 'segredo')::boolean AND NOT v_mudou_destino
                   AND length(trim(coalesce(p_credenciais ->> (c ->> 'chave'), ''))) = 0
                  THEN v_antigo ->> (c ->> 'chave')
                  ELSE nullif(trim(coalesce(p_credenciais ->> (c ->> 'chave'), '')), '')
             END AS v
        FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
       WHERE p.slug = v_provedor
    ) s
   WHERE v IS NOT NULL;

  SELECT c ->> 'rotulo', coalesce((c ->> 'segredo')::boolean, false) INTO v_proibida, v_e_segredo
    FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = v_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(v_final ->> (c ->> 'chave'), ''))) = 0
   LIMIT 1;

  IF v_proibida IS NOT NULL AND v_e_segredo AND v_mudou_destino AND v_antigo <> '{}'::jsonb THEN
    RAISE EXCEPTION 'mudar o endereço pede a chave de novo — a guardada foi dada para o anterior: %', v_proibida
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION 'campo obrigatório em branco: %', v_proibida
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_segredo := privado.guardar_segredo(
    'remetente:' || v_provedor || ':' || p_sender_id::text || ':' || gen_random_uuid()::text,
    v_final::text);

  UPDATE sender_accounts SET credenciais_secret_id = v_segredo WHERE id = p_sender_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.salvar_servidor_provedor(p_tenant uuid, p_provedor text, p_nome text, p_base_url text, p_admin_token text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE v_id uuid; v_segredo uuid; v_antigo uuid; v_prov_antigo text; v_url_antiga text;
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

  SELECT id, admin_secret_id, provedor, base_url INTO v_id, v_antigo, v_prov_antigo, v_url_antiga
    FROM provider_servers WHERE tenant_id = p_tenant AND nome = p_nome;

  -- Token em branco na edição significa "não mexe no que já está guardado" —
  -- o campo volta vazio na tela porque o segredo não é legível, e reenviar
  -- vazio não pode apagar a credencial de um servidor que está funcionando.
  IF p_admin_token IS NOT NULL AND length(trim(p_admin_token)) > 0 THEN
    v_segredo := privado.guardar_segredo(
      'servidor:' || p_provedor || ':' || p_nome || ':' || gen_random_uuid()::text,
      trim(p_admin_token));
  ELSIF v_antigo IS NOT NULL
    AND (v_prov_antigo IS DISTINCT FROM p_provedor OR NOT privado.mesmo_destino(p_base_url, v_url_antiga)) THEN
    -- D77: o token de administração foi dado para UM servidor. Trocar a URL
    -- ou o provedor e mantê-lo mandava o token de admin para o endereço novo.
    RAISE EXCEPTION 'mudar a URL ou o provedor do servidor pede o token de administração de novo — o guardado foi dado para %',
      coalesce(v_url_antiga, v_prov_antigo) USING ERRCODE = 'invalid_parameter_value';
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
$function$;

CREATE OR REPLACE FUNCTION public.mover_deal(p_deal_id uuid, p_stage_slug text, p_origem origem_movimento DEFAULT 'pessoa'::origem_movimento, p_motivo text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
DECLARE
  d        deals%ROWTYPE;
  v_tipo   tipo_estagio;
  v_destino uuid;
BEGIN
  SELECT * INTO d FROM deals WHERE id = p_deal_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'card inexistente: %', p_deal_id USING ERRCODE = 'no_data_found';
  END IF;

  -- DEFINER não passa pelo RLS, então a autorização é conferida aqui. Pessoa
  -- precisa de `pode_operar`; o motor e a IA chamam por dentro, sem JWT.
  IF p_origem = 'pessoa' AND NOT privado.pode_operar(d.tenant_id) THEN
    RAISE EXCEPTION 'sem permissão para mover card deste cliente'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id INTO v_destino FROM pipeline_stages
   WHERE pipeline_id = d.pipeline_id AND slug = p_stage_slug;
  IF NOT FOUND THEN
    -- D77: quem chama com origem motor ou ia é gatilho de resposta, de envio
    -- e de supressão. Um estágio que sumiu (renomeado, apagado) abortava a
    -- transação inteira: a resposta não era gravada, a cadência seguia e o
    -- "pare" não suprimia — as invariantes 2 e 4 furadas por um rótulo de
    -- tela. O funil é consequência do fato, e não pode derrubá-lo.
    IF p_origem <> 'pessoa' THEN
      RAISE WARNING 'funil: o estágio % não existe no funil do card %; o fato segue sem mover o card',
        p_stage_slug, p_deal_id;
      RETURN false;
    END IF;
    RAISE EXCEPTION 'estágio % não existe neste funil', p_stage_slug
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Mover para onde já está não é movimento: não grava atividade, para a
  -- linha do tempo não encher de ruído do gatilho que roda a cada mensagem.
  IF v_destino = d.stage_id THEN RETURN false; END IF;

  SELECT tipo INTO v_tipo FROM pipeline_stages WHERE id = d.stage_id;

  -- A regra que vem do caso real: automação nunca tira de ganho nem de
  -- perdido. Só pessoa desfaz um "oportunidade" ou um "pediu para sair".
  IF p_origem <> 'pessoa' AND v_tipo IN ('ganho', 'perdido') THEN
    RETURN false;
  END IF;

  UPDATE deals
     SET stage_id = v_destino,
         entrou_no_estagio_em = now(),
         movido_por = p_origem,
         motivo = p_motivo
   WHERE id = d.id;

  INSERT INTO deal_activities (tenant_id, deal_id, de_stage_id, para_stage_id, origem, motivo)
  VALUES (d.tenant_id, d.id, d.stage_id, v_destino, p_origem, p_motivo);

  RETURN true;
END;
$function$;

CREATE OR REPLACE FUNCTION public.processar_vencidos(p_limite integer DEFAULT 100, p_modo text DEFAULT 'simulado'::text)
 RETURNS TABLE(enrollment_id uuid, acao text, detalhe text)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  e enrollments%ROWTYPE; v_campanha campaigns%ROWTYPE; v_passo flow_steps%ROWTYPE;
  v_identidade contact_identities%ROWTYPE; v_remetente sender_accounts%ROWTYPE;
  v_contato contacts%ROWTYPE; v_proximo flow_steps%ROWTYPE;
  v_conteudo text; v_status status_message; v_vars jsonb; v_quando timestamptz;
BEGIN
  IF p_modo NOT IN ('simulado','real') THEN
    RAISE EXCEPTION 'modo inválido: % (use simulado ou real)', p_modo
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_status := CASE WHEN p_modo = 'simulado' THEN 'simulado' ELSE 'pendente' END::status_message;

  -- D77: campanha desligada fica fora do lote. Antes ela entrava, ganhava
  -- `ignorado_campanha_inativa` e voltava à cabeça da fila sem mexer em
  -- next_run_at: com 100 vencidos dela, o LIMIT inteiro era dela a cada
  -- batida, e nenhuma outra campanha, de nenhum cliente, criava mensagem.
  FOR e IN
    SELECT en.* FROM enrollments en
     WHERE en.status = 'ativo' AND en.next_run_at IS NOT NULL AND en.next_run_at <= now()
       AND EXISTS (SELECT 1 FROM campaigns c WHERE c.id = en.campaign_id AND c.ativa)
     ORDER BY en.next_run_at LIMIT p_limite FOR UPDATE OF en SKIP LOCKED
  LOOP
    SELECT * INTO v_campanha FROM campaigns WHERE id = e.campaign_id;
    IF NOT v_campanha.ativa THEN
      enrollment_id := e.id; acao := 'ignorado_campanha_inativa'; detalhe := v_campanha.nome;
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_contato FROM contacts WHERE id = e.contact_id;

    IF esta_suprimido(e.tenant_id, e.contact_id, NULL, NULL) THEN
      PERFORM encerrar_enrollment(e.id, 'supressao');
      enrollment_id := e.id; acao := 'encerrado_supressao'; detalhe := 'contato suprimido';
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_passo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > e.passo_atual
     ORDER BY ordem LIMIT 1;

    IF NOT FOUND THEN
      PERFORM encerrar_enrollment(e.id, 'fim_dos_passos');
      enrollment_id := e.id; acao := 'encerrado_fim'; detalhe := ''; RETURN NEXT; CONTINUE;
    END IF;

    IF NOT (v_passo.canal = ANY (v_campanha.canais_habilitados)) THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_canal'; detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_identidade FROM contact_identities
     WHERE contact_id = e.contact_id AND canal = v_passo.canal AND valida
     ORDER BY criado_em DESC LIMIT 1;

    IF NOT FOUND THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_sem_identidade'; detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    IF esta_suprimido(e.tenant_id, e.contact_id, v_identidade.canal, v_identidade.valor_norm) THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_identidade_suprimida';
      detalhe := v_passo.canal::text; RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_remetente
      FROM remetentes_da_campanha(e.tenant_id, v_campanha.id, v_passo.canal) LIMIT 1;

    IF NOT FOUND OR NOT reservar_envio(v_remetente.id) THEN
      v_quando := proximo_horario_da_campanha(e.tenant_id, v_campanha.id, v_passo.canal);
      UPDATE enrollments SET next_run_at = greatest(v_quando, now() + interval '1 minute')
       WHERE id = e.id;
      enrollment_id := e.id; acao := 'adiado_sem_remetente';
      detalhe := v_passo.canal::text || ' até ' || to_char(v_quando, 'DD/MM HH24:MI');
      RETURN NEXT; CONTINUE;
    END IF;

    v_vars := coalesce(v_contato.metadados,'{}'::jsonb)
           || jsonb_build_object('nome', coalesce(v_contato.nome,''));
    v_conteudo := renderizar(v_passo.template, v_vars);

    BEGIN
      INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id,
                            sender_account_id, canal, status, conteudo)
      VALUES (e.tenant_id, e.id, v_passo.id, v_identidade.id,
              v_remetente.id, v_passo.canal, v_status, v_conteudo);
    EXCEPTION WHEN unique_violation THEN
      enrollment_id := e.id; acao := 'passo_ja_reivindicado'; detalhe := v_passo.ordem::text;
      RETURN NEXT; CONTINUE;
    END;

    SELECT * INTO v_proximo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > v_passo.ordem
     ORDER BY ordem LIMIT 1;

    IF FOUND THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem,
        next_run_at = now() + make_interval(hours => v_proximo.atraso_horas) WHERE id = e.id;
    ELSE
      UPDATE enrollments SET passo_atual = v_passo.ordem WHERE id = e.id;
      PERFORM encerrar_enrollment(e.id,'fim_dos_passos');
    END IF;

    enrollment_id := e.id; acao := 'mensagem_criada'; detalhe := v_passo.ordem::text;
    RETURN NEXT;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  -- D54: por coluna onde a tela escreve.
  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id, ai_credential_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  -- D75: `rampa_dias` e `rampa_inicial` entram; o andamento da rampa, não.
  GRANT UPDATE (apelido, quota_diaria, estado, rampa_dias, rampa_inicial)
    ON sender_accounts TO authenticated;

  -- D62: a conta nasce pela tela com o que a tela preenche, e só. Com INSERT
  -- de tabela inteira dava para nascer com `credenciais_secret_id` apontando
  -- para o segredo de OUTRO cliente — o worker mandaria pela conta dele, o
  -- D59 na quarta tabela de credencial. E DELETE apagava em cascata as
  -- mensagens e os eventos da conta: história que é append-only (D62).
  REVOKE INSERT, DELETE ON sender_accounts FROM authenticated;
  GRANT INSERT (tenant_id, canal, provedor, identificador, apelido,
                tipo_permitido, quota_diaria, config)
    ON sender_accounts TO authenticated;

  -- D63: a blacklist é da tela, menos o dono da linha e a origem dela.
  REVOKE UPDATE ON blacklist_termos, blacklist_dominios FROM authenticated;
  GRANT UPDATE (termo, exige_uma_de, acao, nota, ativo) ON blacklist_termos TO authenticated;
  GRANT UPDATE (nota, ativo) ON blacklist_dominios TO authenticated;

  -- D54: as três do motor, leitura sim, escrita nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;

  -- D57: o funil. Renomear e reordenar estágio é da tela; mover card é de
  -- `mover_deal`, e sem esta revogação "porta única" seria convenção.
  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;

  -- D59, daqui para baixo.
  --
  -- As duas tabelas de credencial: a tela liga e desliga, e nada mais. Quem
  -- grava é a função DEFINER, que não usa privilégio do cliente.
  --
  -- O INSERT vai embora junto do UPDATE largo, e não é zelo a mais: com ele,
  -- dava para criar a linha com `credencial_secret_id` escolhido à mão,
  -- apontando para um segredo do Vault que não é desta conexão. Passar pela
  -- função é o que garante que o ponteiro nasce de `guardar_segredo`.
  REVOKE INSERT, UPDATE, DELETE ON ai_credentials, crm_connections FROM authenticated;
  GRANT UPDATE (ativo) ON ai_credentials TO authenticated;
  GRANT UPDATE (ativo) ON crm_connections TO authenticated;

  -- Servidor de provedor: nenhuma tela escreve. `salvar_servidor_provedor` é
  -- DEFINER, e `admin_secret_id` é ponteiro de Vault pelo mesmo motivo acima.
  REVOKE INSERT, UPDATE, DELETE ON provider_servers FROM authenticated;

  -- Catálogo é do produto, não do cliente. Nos três o RLS já recusa por falta
  -- de política de DML, e é justamente por isso que a revogação entra: confiar
  -- que "não tem política" é o mesmo que "não tem privilégio" é o D54 pela
  -- terceira vez. Quem lê continua lendo — `tem_adapter` e `campos` são o que
  -- a tela desenha.
  REVOKE INSERT, UPDATE, DELETE
      ON channel_provider_catalog, ai_provider_catalog, crm_provider_catalog
    FROM authenticated;
  -- D76: os dois vocabulários de catálogo (D58, D63) estavam fora desta lista
  -- e seguiam com escrita de tabela inteira — a política segurava, o
  -- privilégio não. O do cliente é `blacklist_termos`, que fica como está.
  REVOKE INSERT, UPDATE, DELETE ON opt_out_termos, recusa_termos FROM authenticated;

  -- D64. Vínculo e estrutura são do motor: a tela lê. Um vínculo escrito à
  -- mão é o fato de uma pessoa indo para o card de outra; uma estrutura
  -- escrita à mão é a tela oferecendo fase que não existe.
  REVOKE INSERT, UPDATE, DELETE ON crm_vinculos, crm_estruturas FROM authenticated;

  -- Ação e fonte são da tela, por coluna. Fora fica o dono da linha e, na
  -- fonte, o que a execução grava — `ultimo_resultado` escrito pela tela
  -- seria o painel dizendo que a fonte rodou quando não rodou.
  REVOKE INSERT, UPDATE ON crm_acoes, crm_fontes FROM authenticated;
  GRANT INSERT (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id, alvo_rotulo, valor, ordem, ativo)
    ON crm_acoes TO authenticated;
  GRANT UPDATE (alvo_id, alvo_rotulo, valor, ordem, ativo) ON crm_acoes TO authenticated;
  GRANT INSERT (tenant_id, conexao_id, nome, pipe_id, pipe_rotulo, fases, mapa,
                campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  GRANT UPDATE (nome, fases, mapa, campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  -- D66. O agente é da tela, por coluna: o que ele diz, quando passa para
  -- uma pessoa, o que nunca escreve e com que credencial. Fora fica o dono da
  -- linha e `pronto`, que é a marca de agente do catálogo. D69: e se ele
  -- responde sozinho.
  REVOKE UPDATE ON agents FROM authenticated;
  GRANT UPDATE (nome, papel, descricao, instrucoes, ai_credential_id, escalar_quando,
                limite_trocas, ativo, proibido, tamanho_maximo, autonomo,
                tom, contexto, persona, objetivo)
    ON agents TO authenticated;
  -- D76: remover agente é desligá-lo. O DELETE apagava em cascata a exceção
  -- das campanhas (trocando quem responde sem ninguém ver) e deixava o
  -- histórico de rascunhos sem quem o compôs. `canal` fica fora do UPDATE: o
  -- agente de antes continua do canal dele, e o novo nasce de todos.
  REVOKE DELETE ON agents FROM authenticated;

  -- D76: quem responde. A tela escolhe o agente e o canal; a vigência é do
  -- gatilho, e o dono da linha não muda.
  REVOKE INSERT, UPDATE ON campaign_agents, agentes_por_canal FROM authenticated;
  GRANT INSERT (tenant_id, campaign_id, canal, agent_id, herda) ON campaign_agents TO authenticated;
  GRANT UPDATE (agent_id, herda) ON campaign_agents TO authenticated;
  -- Sem DELETE: apagar a exceção faria valer a data antiga do agente do canal.
  -- Voltar ao do canal é `herda`, que tem data.
  REVOKE DELETE ON campaign_agents FROM authenticated;
  GRANT INSERT (tenant_id, canal, agent_id) ON agentes_por_canal TO authenticated;
  GRANT UPDATE (agent_id) ON agentes_por_canal TO authenticated;

  -- O rascunho é do worker: a tela lê. Escrito à mão, seria um texto que
  -- parece ter sido composto pelo agente com os freios dele, sem ter sido —
  -- e, desde o D69, um `envio = 'fila'` sem mensagem nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;

  -- D77: o funil. O código conhece estágio por `slug` e `tipo` (D57), e o
  -- motor move por eles dentro do gatilho da resposta: com o UPDATE de tabela
  -- inteira, um operador renomeava o slug e toda resposta de quem tem card
  -- deixava de ser gravada. A tela renomeia (`nome`), pinta e reordena; criar,
  -- apagar e mudar slug, tipo ou o funil padrão é do produto.
  REVOKE INSERT, UPDATE, DELETE ON pipelines, pipeline_stages FROM authenticated;
  GRANT UPDATE (nome) ON pipelines TO authenticated;
  GRANT UPDATE (nome, cor, posicao) ON pipeline_stages TO authenticated;

  -- D77: TRUNCATE não passa pelo RLS — esvazia a tabela de todos os clientes.
  -- Nenhuma tela trunca, e o Supabase o dá a authenticated junto do ALL.
  REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM authenticated;

  -- D76: anon não escreve em tabela nenhuma. O RLS já recusa (nenhuma
  -- política de escrita aceita quem não entrou), mas o Supabase dá a anon o
  -- mesmo ALL de tabela que dá a authenticated: a política segurava enquanto o
  -- privilégio soltava, que é o D54 — e o suite, que concedia só SELECT a anon,
  -- conferia uma grade mais estreita que a de produção.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon;
  END IF;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Conectar conta numa transação só
-- ---------------------------------------------------------------------------

-- A tela do canal e o setup por chat conectam conta por aqui. A linha nasce e
-- o segredo vai para o Vault na MESMA transação: se o catálogo recusa a
-- credencial (campo obrigatório em branco, campo que o provedor não tem), a
-- conta não fica para trás, ativa e sem segredo, sendo escolhida pelo pool.
-- O que vai para `config` é o que o catálogo diz não ser segredo (D28); o
-- resto vai inteiro para `salvar_credencial_remetente`, que já decide.
CREATE FUNCTION public.conectar_conta(
  p_tenant uuid, p_canal canal, p_provedor text, p_identificador text, p_apelido text,
  p_tipo_permitido tipo_campanha, p_quota_diaria integer, p_campos jsonb DEFAULT '{}'::jsonb)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'privado'
AS $$
DECLARE v_id uuid; v_config jsonb;
BEGIN
  -- DEFINER pula o RLS de sender_accounts: a pergunta da política é feita aqui.
  IF NOT privado.pode_administrar(p_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente conecta conta'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT coalesce(jsonb_object_agg(c ->> 'chave', btrim(p_campos ->> (c ->> 'chave'))), '{}'::jsonb)
    INTO v_config
    FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND NOT coalesce((c ->> 'segredo')::boolean, false)
     AND length(btrim(coalesce(p_campos ->> (c ->> 'chave'), ''))) > 0;

  INSERT INTO sender_accounts (tenant_id, canal, provedor, identificador, apelido,
                               tipo_permitido, quota_diaria, config)
  VALUES (p_tenant, p_canal, p_provedor, p_identificador, nullif(btrim(coalesce(p_apelido, '')), ''),
          p_tipo_permitido, p_quota_diaria, v_config)
  RETURNING id INTO v_id;

  PERFORM salvar_credencial_remetente(v_id, coalesce(p_campos, '{}'::jsonb));
  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Busca de contatos
-- ---------------------------------------------------------------------------

-- Nome, endereço ou número, do jeito que a pessoa digita: "(15) 99123-4567"
-- casa pelos dígitos. O termo é escapado — `%` e `_` são texto, não curinga — e
-- o cliente é dito em voz alta. INVOKER: o RLS de contacts decide as linhas.
CREATE FUNCTION public.buscar_contatos(p_tenant uuid, p_termo text, p_limite integer DEFAULT 200)
RETURNS TABLE(contact_id uuid)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  WITH t AS (
    SELECT replace(replace(replace(btrim(coalesce(p_termo, '')), '\', '\\'), '%', '\%'), '_', '\_') AS termo,
           regexp_replace(coalesce(p_termo, ''), '\D', '', 'g') AS digitos
  )
  SELECT c.id
    FROM contacts c, t
   WHERE c.tenant_id = p_tenant
     AND t.termo <> ''
     AND (c.nome ILIKE '%' || t.termo || '%'
          OR EXISTS (SELECT 1 FROM contact_identities i
                      WHERE i.tenant_id = c.tenant_id AND i.contact_id = c.id
                        AND (i.valor_norm ILIKE '%' || t.termo || '%'
                             OR (length(t.digitos) >= 4 AND i.valor_norm LIKE '%' || t.digitos || '%'))))
   ORDER BY c.criado_em DESC
   LIMIT least(greatest(coalesce(p_limite, 200), 1), 500)
$$;

-- ---------------------------------------------------------------------------
-- 5. A prévia de inscrição olha o pool da campanha
-- ---------------------------------------------------------------------------
--
-- A única campanha de produção é morna e o único chip do cliente é frio: a
-- prévia dizia "inscrever", a inscrição entrava, e o agendador adiava o passo
-- de hora em hora, para sempre, sem erro — o silêncio do D35 pelo outro lado.
-- Continua inscrevendo (conectar a conta depois é uso legítimo, e o passo
-- espera), mas diz. Corpo partindo do que está no projeto (D59).
CREATE OR REPLACE FUNCTION public.prever_inscricao(p_tenant uuid, p_campaign_id uuid, p_flow_version_id uuid, p_contatos uuid[])
 RETURNS TABLE(contact_id uuid, nome text, acao text, canais_alcancaveis canal[], problema text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
  WITH camp AS (
    SELECT c.canais_habilitados, c.ativa, c.tipo
      FROM campaigns c
     WHERE c.tenant_id = p_tenant AND c.id = p_campaign_id
  ),
  -- Os canais que esta versão de flow realmente usa.
  passos AS (
    SELECT DISTINCT fs.canal
      FROM flow_steps fs
     WHERE fs.flow_version_id = p_flow_version_id
  ),
  -- O que sobra depois de cruzar flow com campanha. Vazio aqui é problema de
  -- configuração, não de contato: nenhum passo sairia para ninguém.
  uteis AS (
    SELECT coalesce(array_agg(DISTINCT p.canal), '{}'::canal[]) AS canais
      FROM passos p
      JOIN camp c ON p.canal = ANY (c.canais_habilitados)
  ),
  alvo AS (
    SELECT DISTINCT unnest(coalesce(p_contatos, '{}'::uuid[])) AS id
  ),
  -- Alcançável é identidade válida, num canal que o flow usa, e que não está
  -- suprimida. As três coisas — uma só já enganaria.
  alcance AS (
    SELECT a.id,
           -- O FILTER não é zelo: sem ele a junção externa sem par produz
           -- `{NULL}`, `array_length` devolve 1, e "não tem canal nenhum"
           -- passa por "tem um canal". Era o bug que dizia `inscrever` para
           -- quem o motor encerraria sem mandar nada.
           coalesce(array_agg(DISTINCT ci.canal) FILTER (WHERE ci.canal IS NOT NULL),
                    '{}'::canal[]) AS canais
      FROM alvo a
      -- `uteis` entra por junção, não por subconsulta escalar: dentro de
      -- `= ANY (...)` um sub-SELECT é comparado linha a linha, e a linha aqui
      -- é um array inteiro — daí `operator does not exist: canal = canal[]`.
      CROSS JOIN uteis u
      LEFT JOIN contact_identities ci
        ON ci.tenant_id = p_tenant AND ci.contact_id = a.id AND ci.valida
       AND ci.canal = ANY (u.canais)
       AND NOT esta_suprimido(p_tenant, a.id, ci.canal, ci.valor_norm)
     GROUP BY a.id
  )
  SELECT a.id,
         c.nome,
         CASE
           WHEN c.id IS NULL THEN 'desconhecido'
           WHEN esta_suprimido(p_tenant, a.id, NULL, NULL) THEN 'suprimido'
           WHEN EXISTS (
             SELECT 1 FROM enrollments e
              WHERE e.tenant_id = p_tenant AND e.contact_id = a.id
                AND e.campaign_id = p_campaign_id AND e.status <> 'encerrado'
           ) THEN 'ja_inscrito'
           WHEN coalesce(array_length(al.canais, 1), 0) = 0 THEN 'sem_canal'
           ELSE 'inscrever'
         END,
         al.canais,
         CASE
           WHEN c.id IS NULL THEN
             'contato não existe neste cliente'
           WHEN esta_suprimido(p_tenant, a.id, NULL, NULL) THEN
             'contato suprimido: inscrever devolveria nulo em silêncio'
           WHEN EXISTS (
             SELECT 1 FROM enrollments e
              WHERE e.tenant_id = p_tenant AND e.contact_id = a.id
                AND e.campaign_id = p_campaign_id AND e.status <> 'encerrado'
           ) THEN
             'já inscrito e não encerrado nesta campanha'
           WHEN coalesce(array_length((SELECT canais FROM uteis), 1), 0) = 0 THEN
             'nenhum passo do flow usa um canal habilitado na campanha: '
             || 'ninguém receberia nada'
           WHEN coalesce(array_length(al.canais, 1), 0) = 0 THEN
             'sem identidade válida em ' || array_to_string((SELECT canais FROM uteis), ', ')
             || ': o enrollment percorreria todos os passos e encerraria como concluído'
           -- D77: canal sem conta no pool DESTA campanha. O pool exige o mesmo
           -- tipo (`remetentes_disponiveis`), e sem candidato o passo é adiado,
           -- nunca queimado (D31): inscrever não dá erro e nada sai, de hora em
           -- hora, para sempre. A quota de hoje fica de fora de propósito —
           -- acabar a quota é amanhã; não ter conta é até alguém conectar uma.
           WHEN EXISTS (
             SELECT 1 FROM unnest(al.canais) AS u(canal)
              WHERE NOT EXISTS (
                SELECT 1 FROM sender_accounts sa
                  JOIN channel_provider_catalog p ON p.slug = sa.provedor
                 WHERE sa.tenant_id = p_tenant AND sa.canal = u.canal
                   AND sa.tipo_permitido = (SELECT tipo FROM camp)
                   AND sa.estado = 'ativo' AND p.tem_adapter AND p.ativo)
           ) THEN
             'sem conta ' || (SELECT tipo FROM camp)::text || ' ativa em '
             || (SELECT string_agg(u.canal::text, ', ' ORDER BY u.canal)
                   FROM unnest(al.canais) AS u(canal)
                  WHERE NOT EXISTS (
                    SELECT 1 FROM sender_accounts sa
                      JOIN channel_provider_catalog p ON p.slug = sa.provedor
                     WHERE sa.tenant_id = p_tenant AND sa.canal = u.canal
                       AND sa.tipo_permitido = (SELECT tipo FROM camp)
                       AND sa.estado = 'ativo' AND p.tem_adapter AND p.ativo))
             || ': a inscrição entra, e o agendador adia o passo até uma conta desse pool ser conectada'
           WHEN NOT (SELECT ativa FROM camp) THEN
             'campanha inativa: o agendador ignora enquanto ela estiver assim'
         END
    FROM alvo a
    JOIN alcance al ON al.id = a.id
    LEFT JOIN contacts c ON c.tenant_id = p_tenant AND c.id = a.id
   ORDER BY c.nome NULLS LAST, a.id;
$function$;

-- ---------------------------------------------------------------------------
-- 6. Superfície
-- ---------------------------------------------------------------------------

-- Função nova nasce com EXECUTE para PUBLIC, e anon é membro (D55): revogar
-- antes de conceder. As duas são da tela.
DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.conectar_conta(uuid, canal, text, text, text, tipo_campanha, integer, jsonb)',
    'public.buscar_contatos(uuid, text, integer)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', alvo);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', alvo);
    END IF;
    FOREACH papel IN ARRAY ARRAY['authenticated','service_role'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- Dentro de DO: migration que imprime resultado polui o stdout que o
-- `tests/run.sh` captura para nomear o banco.
DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
