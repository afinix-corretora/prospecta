-- Desfaz o D77. As funções novas saem primeiro, os corpos voltam exatos ao
-- que eram no D76 (copiados do banco, não reescritos), o catálogo perde a
-- marca de destino e a grade volta à do Supabase — e só então sai o
-- `mesmo_destino`, quando nenhum corpo o chama mais.
--
-- O down vai pelo SQL Editor, não pelo MCP: ele tem DROP (D63). E o app que
-- chama `conectar_conta` e `buscar_contatos` volta antes dele.

DROP FUNCTION public.buscar_contatos(uuid, text, integer);
DROP FUNCTION public.conectar_conta(uuid, canal, text, text, text, tipo_campanha, integer, jsonb);

CREATE OR REPLACE FUNCTION public.prever_inscricao(p_tenant uuid, p_campaign_id uuid, p_flow_version_id uuid, p_contatos uuid[])
 RETURNS TABLE(contact_id uuid, nome text, acao text, canais_alcancaveis canal[], problema text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
  WITH camp AS (
    SELECT c.canais_habilitados, c.ativa
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
           WHEN NOT (SELECT ativa FROM camp) THEN
             'campanha inativa: o agendador ignora enquanto ela estiver assim'
         END
    FROM alvo a
    JOIN alcance al ON al.id = a.id
    LEFT JOIN contacts c ON c.tenant_id = p_tenant AND c.id = a.id
   ORDER BY c.nome NULLS LAST, a.id;
$function$;

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

  SELECT id, credencial_secret_id INTO v_id, v_antigo
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

  -- Campo obrigatório em branco só passa quando já existe valor guardado: na
  -- edição o segredo volta vazio da tela, porque segredo não é legível, e
  -- reenviar vazio não pode apagar a credencial de uma conexão em uso.
  SELECT c ->> 'rotulo' INTO v_ruim
    FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(p_campos ->> (c ->> 'chave'), ''))) = 0
     AND NOT ((c ->> 'segredo')::boolean AND v_antigo IS NOT NULL)
   LIMIT 1;

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
  ELSE
    v_segredo := v_antigo;
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

  -- O blob final: o que veio da tela, com o segredo antigo preservado quando a
  -- tela mandou branco. Percorre o catálogo, e não as chaves recebidas, porque
  -- o valor guardado de um campo que a tela nem enviou também precisa entrar.
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) INTO v_final
    FROM (
      SELECT c ->> 'chave' AS k,
             CASE WHEN (c ->> 'segredo')::boolean
                   AND length(trim(coalesce(p_credenciais ->> (c ->> 'chave'), ''))) = 0
                  THEN v_antigo ->> (c ->> 'chave')
                  ELSE nullif(trim(coalesce(p_credenciais ->> (c ->> 'chave'), '')), '')
             END AS v
        FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
       WHERE p.slug = v_provedor
    ) s
   WHERE v IS NOT NULL;

  SELECT c ->> 'rotulo' INTO v_proibida
    FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = v_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(v_final ->> (c ->> 'chave'), ''))) = 0
   LIMIT 1;

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

  FOR e IN
    SELECT * FROM enrollments
     WHERE status = 'ativo' AND next_run_at IS NOT NULL AND next_run_at <= now()
     ORDER BY next_run_at LIMIT p_limite FOR UPDATE SKIP LOCKED
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

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['ai_provider_catalog','crm_provider_catalog','channel_provider_catalog'] LOOP
    EXECUTE format(
      'UPDATE %I SET campos = (SELECT jsonb_agg(x - ''destino'' ORDER BY o)
                                 FROM jsonb_array_elements(campos) WITH ORDINALITY t(x, o))
        WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(campos) y WHERE y ? ''destino'')', t);
  END LOOP;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE UPDATE (nome) ON pipelines FROM authenticated;
    REVOKE UPDATE (nome, cor, posicao) ON pipeline_stages FROM authenticated;
    GRANT INSERT, UPDATE, DELETE ON pipelines, pipeline_stages TO authenticated;
    GRANT TRUNCATE ON ALL TABLES IN SCHEMA public TO authenticated;
  END IF;
  PERFORM privado.estreitar_escrita_do_cliente();
END $$;

DROP FUNCTION privado.mesmo_destino(text, text);
