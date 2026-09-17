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
DECLARE r record; v_ana uuid; v_caio uuid; v_bia uuid; v_edu uuid;
BEGIN
  SELECT id INTO v_ana  FROM agents WHERE nome LIKE 'Ana%';
  SELECT id INTO v_caio FROM agents WHERE nome LIKE 'Caio%';
  SELECT id INTO v_bia  FROM agents WHERE nome LIKE 'Bia%';
  SELECT id INTO v_edu  FROM agents WHERE nome LIKE 'Edu%';

  SELECT * INTO r FROM criar_campanha_de_modelo('resgate-multicanal','Com agentes','{whatsapp,email}');

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

  -- Agente desligado.
  UPDATE agents SET ativo = false WHERE id = v_edu;
  BEGIN
    PERFORM atribuir_agente(r.campaign_id, v_edu);
    PERFORM ag.confere('agente inativo é recusado', false, 'foi aceito');
  EXCEPTION WHEN others THEN
    PERFORM ag.confere('agente inativo é recusado', true);
  END;
  PERFORM ag.confere('agente inativo some do canal',
    (agente_do_canal(r.campaign_id,'email')).id IS NULL);
  UPDATE agents SET ativo = true WHERE id = v_edu;
END;
$$;

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM criar_campanha_de_modelo('resgate-whatsapp','Sem agente ainda');
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
