-- Testes dos agentes de canal e do catálogo de provedores de IA.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ag;
CREATE TABLE ag.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION ag.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ag.resultado (nome, ok, detalhe) VALUES (p_nome, coalesce(p_cond,false), p_detalhe); END; $$;

-- ---------------------------------------------------------------------------
-- Catálogo de provedores
-- ---------------------------------------------------------------------------

SELECT ag.confere('catálogo tem os provedores pedidos',
  (SELECT count(*) = 7 FROM ai_provider_catalog), (SELECT count(*)::text FROM ai_provider_catalog));

SELECT ag.confere('todo provedor declara ao menos um campo obrigatório',
  NOT EXISTS (SELECT 1 FROM ai_provider_catalog p
    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p.campos) c
                       WHERE (c ->> 'obrigatorio')::boolean)));

SELECT ag.confere('todo provedor tem exatamente um campo de segredo',
  NOT EXISTS (SELECT 1 FROM (
    SELECT p.slug, count(*) FILTER (WHERE (c ->> 'segredo')::boolean) AS n
      FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c GROUP BY p.slug) x
   WHERE x.n <> 1));

SELECT ag.confere('campo de segredo é sempre do tipo senha',
  NOT EXISTS (SELECT 1 FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
               WHERE (c ->> 'segredo')::boolean AND c ->> 'tipo' <> 'senha'));

-- ---------------------------------------------------------------------------
-- Anti-regra: segredo nunca fora do Vault
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  INSERT INTO ai_credentials (nome, provedor, modelo, config)
  VALUES ('Vazando', 'openai', 'gpt-x', '{"api_key":"sk-vazou-aqui"}'::jsonb);
  PERFORM ag.confere('chave de API em config é recusada pelo banco', false, 'foi aceita');
EXCEPTION WHEN others THEN
  PERFORM ag.confere('chave de API em config é recusada pelo banco', true);
END;
$$;

DO $$
BEGIN
  INSERT INTO ai_credentials (nome, provedor, modelo, chave_secret_id, config)
  VALUES ('OpenAI produção', 'openai', 'gpt-x', gen_random_uuid(),
          '{"organizacao":"org-123"}'::jsonb);
  PERFORM ag.confere('campo não-secreto em config é aceito', true);
EXCEPTION WHEN others THEN
  PERFORM ag.confere('campo não-secreto em config é aceito', false, SQLERRM);
END;
$$;

DO $$
BEGIN
  UPDATE ai_credentials SET config = config || '{"api_key":"sk-tarde-demais"}'::jsonb
   WHERE nome = 'OpenAI produção';
  PERFORM ag.confere('vazar segredo por UPDATE também é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM ag.confere('vazar segredo por UPDATE também é recusado', true);
END;
$$;

SELECT ag.confere('não existe coluna para guardar a chave',
  NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_name = 'ai_credentials'
      AND column_name IN ('api_key','chave','secret','token')));

SELECT ag.confere('credencial Anthropic sugere modelos reais',
  (SELECT modelos_sugeridos ? 'claude-opus-5' AND modelos_sugeridos ? 'claude-sonnet-5'
     FROM ai_provider_catalog WHERE slug = 'anthropic'));

-- ---------------------------------------------------------------------------
-- Agentes prontos
-- ---------------------------------------------------------------------------

SELECT ag.confere('há agente pronto para cada canal com adapter',
  (SELECT count(DISTINCT canal) >= 4 FROM agents WHERE pronto AND ativo));

SELECT ag.confere('todo agente pronto tem instrução detalhada, não uma frase',
  NOT EXISTS (SELECT 1 FROM agents WHERE pronto AND length(instrucoes) < 400));

SELECT ag.confere('todo agente diz quando passar para uma pessoa',
  NOT EXISTS (SELECT 1 FROM agents WHERE length(trim(escalar_quando)) < 20));

SELECT ag.confere('todo agente tem teto de trocas',
  NOT EXISTS (SELECT 1 FROM agents WHERE limite_trocas IS NULL OR limite_trocas > 100));

SELECT ag.confere('agente de SMS tem teto menor que o de e-mail',
  (SELECT a.limite_trocas FROM agents a WHERE a.canal = 'sms' AND a.pronto LIMIT 1) <
  (SELECT a.limite_trocas FROM agents a WHERE a.canal = 'email' AND a.pronto LIMIT 1));

DO $$
BEGIN
  INSERT INTO agents (nome, canal, papel, descricao, instrucoes)
  VALUES ('Raso','whatsapp','x','y','Responda bem.');
  PERFORM ag.confere('agente com instrução vazia é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM ag.confere('agente com instrução vazia é recusado', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- Um agente por canal dentro da campanha
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_ana uuid; v_caio uuid; v_bia uuid; v_edu uuid; v_copia uuid;
BEGIN
  SELECT id INTO v_ana  FROM agents WHERE nome LIKE 'Ana%'  AND tenant_id IS NULL;
  SELECT id INTO v_caio FROM agents WHERE nome LIKE 'Caio%' AND tenant_id IS NULL;
  SELECT id INTO v_bia  FROM agents WHERE nome LIKE 'Bia%'  AND tenant_id IS NULL;
  SELECT id INTO v_edu  FROM agents WHERE nome LIKE 'Edu%'  AND tenant_id IS NULL;

  SELECT * INTO r FROM criar_campanha_de_modelo('00000000-0000-0000-0000-0000000000aa','resgate-multicanal','Com agentes','{whatsapp,email}');

  PERFORM atribuir_agente(r.campaign_id, v_ana);
  PERFORM atribuir_agente(r.campaign_id, v_edu);

  PERFORM ag.confere('campanha tem um agente por canal',
    (SELECT count(*) = 2 FROM campaign_agents WHERE campaign_id = r.campaign_id));

  PERFORM ag.confere('agente do canal é encontrado pelo canal',
    (SELECT (agente_do_canal(r.campaign_id,'whatsapp')).nome LIKE 'Ana%'));
  PERFORM ag.confere('cada canal devolve o seu agente',
    (SELECT (agente_do_canal(r.campaign_id,'email')).nome LIKE 'Edu%'));

  -- Trocar a persona do canal substitui, não duplica.
  PERFORM atribuir_agente(r.campaign_id, v_caio);
  PERFORM ag.confere('trocar o agente do canal substitui em vez de duplicar',
    (SELECT count(*) = 2 FROM campaign_agents WHERE campaign_id = r.campaign_id));
  PERFORM ag.confere('a troca valeu',
    (SELECT (agente_do_canal(r.campaign_id,'whatsapp')).nome LIKE 'Caio%'));

  -- Agente de Instagram numa campanha sem Instagram.
  BEGIN
    PERFORM atribuir_agente(r.campaign_id, v_bia);
    PERFORM ag.confere('agente de canal não habilitado é recusado', false, 'foi aceito');
  EXCEPTION WHEN others THEN
    PERFORM ag.confere('agente de canal não habilitado é recusado', true);
  END;

  -- Canal trocado na marra.
  BEGIN
    INSERT INTO campaign_agents (campaign_id, canal, agent_id)
    VALUES (r.campaign_id, 'sms', v_ana);
    PERFORM ag.confere('agente não atende canal que não é o dele', false, 'foi aceito');
  EXCEPTION WHEN others THEN
    PERFORM ag.confere('agente não atende canal que não é o dele', true);
  END;

  -- Agente do catálogo é copiado para o tenant no primeiro uso: o cliente pode
  -- ajustar a persona dele sem mexer no catálogo, e o catálogo não muda a
  -- persona de ninguém. Mesma regra dos modelos de campanha.
  PERFORM ag.confere('agente do catálogo é copiado para o tenant',
    (SELECT a.tenant_id IS NOT NULL FROM campaign_agents ca JOIN agents a ON a.id = ca.agent_id
      WHERE ca.campaign_id = r.campaign_id AND ca.canal = 'email'));
  PERFORM ag.confere('a cópia mantém as instruções do catálogo',
    (SELECT c.instrucoes = o.instrucoes
       FROM campaign_agents ca JOIN agents c ON c.id = ca.agent_id
       JOIN agents o ON o.id = v_edu
      WHERE ca.campaign_id = r.campaign_id AND ca.canal = 'email'));
  PERFORM ag.confere('o catálogo continua sem tenant',
    (SELECT tenant_id IS NULL FROM agents WHERE id = v_edu));
  PERFORM ag.confere('usar o mesmo agente de novo não cria outra cópia',
    (SELECT count(*) = 1 FROM agents
      WHERE tenant_id IS NOT NULL AND nome = (SELECT nome FROM agents WHERE id = v_edu)));

  -- Agente do tenant desligado.
  SELECT ca.agent_id INTO v_copia FROM campaign_agents ca
   WHERE ca.campaign_id = r.campaign_id AND ca.canal = 'email';
  UPDATE agents SET ativo = false WHERE id = v_copia;

  BEGIN
    PERFORM atribuir_agente(r.campaign_id, v_edu);
    PERFORM ag.confere('agente inativo é recusado', false, 'foi aceito');
  EXCEPTION WHEN others THEN
    PERFORM ag.confere('agente inativo é recusado', true);
  END;
  PERFORM ag.confere('agente inativo some do canal',
    (agente_do_canal(r.campaign_id,'email')).id IS NULL);
  UPDATE agents SET ativo = true WHERE id = v_copia;
END;
$$;

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM criar_campanha_de_modelo('00000000-0000-0000-0000-0000000000aa','resgate-whatsapp','Sem agente ainda');
  PERFORM ag.confere('campanha funciona sem agente atribuído',
    (agente_do_canal(r.campaign_id,'whatsapp')).id IS NULL);
END;
$$;

DO $$
BEGIN
  PERFORM atribuir_agente(gen_random_uuid(), gen_random_uuid());
  PERFORM ag.confere('agente inexistente é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM ag.confere('agente inexistente é recusado', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- Fronteira: agente não mexe na cadência
-- ---------------------------------------------------------------------------

SELECT ag.confere('nenhuma tabela do motor referencia agente',
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name IN ('enrollments','messages','flow_steps','flow_versions')
       AND column_name LIKE '%agent%'));

-- ---------------------------------------------------------------------------
-- Credencial de IA pelo painel do produto (D26)
-- ---------------------------------------------------------------------------
--
-- A tela de Provedores de IA desenhava os campos e não tinha para onde
-- mandá-los: ligar um agente exigia o painel do Supabase. O que estes testes
-- verificam não é só que a função grava — é que ela decide a separação entre
-- segredo e config pelo catálogo, e não confia na tela para isso.

INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  ('00000000-0000-0000-0000-0000000000aa','11111111-bbbb-0000-0000-00000000000a','dono'),
  ('00000000-0000-0000-0000-0000000000aa','33333333-bbbb-0000-0000-00000000000a','operador');

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"33333333-bbbb-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_ia('00000000-0000-0000-0000-0000000000aa','Do operador',
            'anthropic','claude-opus-5','{"api_key":"sk-ant-x"}'::jsonb);
  PERFORM ag.confere('operador não configura provedor de IA', false, 'configurou');
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM ag.confere('operador não configura provedor de IA (42501)', true);
WHEN others THEN
  PERFORM ag.confere('operador não configura provedor de IA', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-bbbb-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_ia('00000000-0000-0000-0000-0000000000aa','X',
            'inventado','m','{}'::jsonb);
  PERFORM ag.confere('provedor de IA fora do catálogo é recusado', false, 'aceitou');
EXCEPTION WHEN no_data_found THEN
  PERFORM ag.confere('provedor de IA fora do catálogo é recusado', true);
WHEN others THEN
  PERFORM ag.confere('provedor de IA fora do catálogo é recusado', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-bbbb-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_ia('00000000-0000-0000-0000-0000000000aa','X',
            'anthropic','claude-opus-5','{"api_key":"sk-ant-x","inventado":"y"}'::jsonb);
  PERFORM ag.confere('campo que não existe no provedor de IA é recusado', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM ag.confere('campo que não existe no provedor de IA é recusado', true);
WHEN others THEN
  PERFORM ag.confere('campo que não existe no provedor de IA é recusado', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- Credencial sem modelo não serve para chamar nada: o erro vale mais agora que
-- no meio de uma conversa com o contato esperando resposta.
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-bbbb-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_ia('00000000-0000-0000-0000-0000000000aa','X',
            'anthropic','   ','{"api_key":"sk-ant-x"}'::jsonb);
  PERFORM ag.confere('credencial de IA sem modelo é recusada', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM ag.confere('credencial de IA sem modelo é recusada', true);
WHEN others THEN
  PERFORM ag.confere('credencial de IA sem modelo é recusada', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- `compativel` é o único provedor com campo obrigatório que não é segredo.
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-bbbb-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_ia('00000000-0000-0000-0000-0000000000aa','Local',
            'compativel','llama','{"api_key":"sk-x"}'::jsonb);
  PERFORM ag.confere('campo obrigatório em branco é recusado na criação', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM ag.confere('campo obrigatório em branco é recusado na criação', true);
WHEN others THEN
  PERFORM ag.confere('campo obrigatório em branco é recusado na criação', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-bbbb-0000-0000-00000000000a"}', true);
  -- Sem Vault local, quem administra chega até a escrita do segredo e para lá
  -- — um passo depois da checagem de permissão, que é o que interessa aqui.
  PERFORM salvar_credencial_ia('00000000-0000-0000-0000-0000000000aa','Claude',
            'anthropic','claude-opus-5','{"api_key":"sk-ant-x"}'::jsonb);
  PERFORM ag.confere('quem administra passa da checagem de permissão (IA)', false,
    'sem Vault deveria parar');
EXCEPTION WHEN feature_not_supported THEN
  PERFORM ag.confere('quem administra passa da checagem de permissão (IA)', true);
WHEN insufficient_privilege THEN
  PERFORM ag.confere('quem administra passa da checagem de permissão (IA)', false, 'barrou quem pode');
END;
$$;

-- Credencial que já tem chave guardada: editar só o que não é segredo não
-- chama o Vault, e é por isso que este caminho roda inteiro sem ele.
INSERT INTO ai_credentials (id, nome, provedor, modelo, chave_secret_id, config)
VALUES ('aa000000-0000-0000-0000-0000000000c1','Claude de produção','anthropic',
        'claude-sonnet-5','00000000-0000-0000-0000-000000000077','{}'::jsonb);

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-bbbb-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_ia('00000000-0000-0000-0000-0000000000aa','Claude de produção',
            'anthropic','claude-opus-5','{"base_url":"https://gw.interno"}'::jsonb);
END;
$$;

SELECT ag.confere('editar sem reenviar a chave preserva o segredo',
  (SELECT chave_secret_id = '00000000-0000-0000-0000-000000000077' AND modelo = 'claude-opus-5'
     FROM ai_credentials WHERE id = 'aa000000-0000-0000-0000-0000000000c1'));

SELECT ag.confere('campo não-secreto vai para config',
  (SELECT config = '{"base_url":"https://gw.interno"}'::jsonb
     FROM ai_credentials WHERE id = 'aa000000-0000-0000-0000-0000000000c1'));

SELECT ag.confere('editar não duplica a credencial',
  (SELECT count(*) = 1 FROM ai_credentials
    WHERE tenant_id = '00000000-0000-0000-0000-0000000000aa' AND nome = 'Claude de produção'));

-- A separação é do catálogo, não da tela: se a função copiasse o objeto inteiro
-- para config, quem barraria seria o gatilho — com erro de banco na cara do
-- usuário e a chave já tendo passado por onde não devia.
SELECT ag.confere('nenhuma credencial guarda campo de segredo em config',
  NOT EXISTS (SELECT 1 FROM ai_credentials cr
    JOIN ai_provider_catalog p ON p.slug = cr.provedor,
    LATERAL jsonb_array_elements(p.campos) c
   WHERE (c ->> 'segredo')::boolean AND cr.config ? (c ->> 'chave')));

DO $$
BEGIN
  PERFORM segredo_da_credencial_ia('aa000000-0000-0000-0000-0000000000ff');
  PERFORM ag.confere('segredo de credencial inexistente é erro, não NULL', false, 'devolveu');
EXCEPTION WHEN no_data_found THEN
  PERFORM ag.confere('segredo de credencial inexistente é erro, não NULL', true);
WHEN others THEN
  PERFORM ag.confere('segredo de credencial inexistente é erro, não NULL', false,
    SQLSTATE || ': ' || SQLERRM);
END;
$$;

SELECT set_config('request.jwt.claims','', true);

SELECT ag.confere('salvar_credencial_ia é API de usuário logado',
  (SELECT has_function_privilege('authenticated', p.oid, 'EXECUTE')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'salvar_credencial_ia'));

-- Esta devolve a chave em texto claro. Usuário logado não chama.
SELECT ag.confere('segredo_da_credencial_ia não é API de usuário logado',
  (SELECT NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'segredo_da_credencial_ia'));

SELECT ag.confere('e nenhuma das duas para anônimo',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('salvar_credencial_ia','segredo_da_credencial_ia')
       AND has_function_privilege('anon', p.oid, 'EXECUTE')));

\echo ''
\echo '============= AGENTES E IA ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM ag.resultado ORDER BY id;
\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM ag.resultado;

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM ag.resultado WHERE NOT ok;
  IF v > 0 THEN RAISE EXCEPTION '% asserção(ões) de agentes falharam', v; END IF;
END;
$$;
