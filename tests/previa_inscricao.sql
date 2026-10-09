-- Prévia da inscrição em campanha (D35).
--
-- O que este arquivo sustenta: a prévia enxerga as três formas de a inscrição
-- dar errado — e a pior delas não dá erro nenhum.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA pi;
CREATE TABLE pi.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION pi.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO pi.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t '00000000-0000-0000-0000-0000000000aa'
\set camp 'dd000000-0000-0000-0000-000000000001'
\set flow 'dd000000-0000-0000-0000-000000000002'
\set fv   'dd000000-0000-0000-0000-000000000003'

-- Campanha de WhatsApp, flow com dois passos de WhatsApp.
INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES (:'camp', 'Resgate', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO flows (id, nome) VALUES (:'flow', 'Resgate');
INSERT INTO flow_versions (id, flow_id, versao) VALUES (:'fv', :'flow', 1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:'fv', 1, 'whatsapp', 0, 'oi {{nome}}'), (:'fv', 2, 'whatsapp', 24, 'e aí');

CREATE TEMP TABLE quem (rotulo text, id uuid);

DO $$
DECLARE v uuid;
BEGIN
  -- Alcançável: tem WhatsApp válido.
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"15991110000","valor_norm":"5515991110000"}]'::jsonb, 'Marina');
  INSERT INTO quem VALUES ('alcancavel', v);

  -- Só e-mail. Nenhum passo do flow é de e-mail: seria inscrito sem erro e
  -- percorreria os dois passos sem mandar nada.
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"email","valor":"so@email.com.br","valor_norm":"so@email.com.br"}]'::jsonb, 'Só E-mail');
  INSERT INTO quem VALUES ('so_email', v);

  -- Tem WhatsApp, mas o contato inteiro está suprimido.
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"15992220000","valor_norm":"5515992220000"}]'::jsonb, 'Suprimido');
  INSERT INTO quem VALUES ('suprimido', v);
  INSERT INTO suppression (tenant_id, contact_id, motivo)
  VALUES ('00000000-0000-0000-0000-0000000000aa', v, 'opt_out');

  -- Tem WhatsApp, mas a identidade está suprimida por valor.
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"15993330000","valor_norm":"5515993330000"}]'::jsonb, 'Número Bloqueado');
  INSERT INTO quem VALUES ('numero_suprimido', v);
  INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
  VALUES ('00000000-0000-0000-0000-0000000000aa', 'whatsapp', '5515993330000', 'opt_out');

  -- Tem WhatsApp, mas a identidade foi marcada inválida por bounce.
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"15994440000","valor_norm":"5515994440000"}]'::jsonb, 'Inválido');
  INSERT INTO quem VALUES ('invalido', v);
  UPDATE contact_identities SET valida = false WHERE contact_id = v;

  -- Alcançável e já inscrito.
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"15995550000","valor_norm":"5515995550000"}]'::jsonb, 'Já Inscrito');
  INSERT INTO quem VALUES ('ja_inscrito', v);
  PERFORM inscrever(v, 'dd000000-0000-0000-0000-000000000001',
                    'dd000000-0000-0000-0000-000000000003', now());
END;
$$;

CREATE TEMP TABLE antes AS SELECT count(*) AS enrollments FROM enrollments;

CREATE TEMP TABLE previsto AS
SELECT q.rotulo, p.*
  FROM quem q
  JOIN prever_inscricao(:'t', :'camp', :'fv',
        (SELECT array_agg(id) FROM quem) || ARRAY['dd000000-0000-0000-0000-0000000000ff'::uuid]
       ) p ON p.contact_id = q.id;

-- ---------------------------------------------------------------------------

SELECT pi.confere('quem tem o canal do flow entra',
  (SELECT acao FROM previsto WHERE rotulo = 'alcancavel') = 'inscrever'
  AND (SELECT canais_alcancaveis FROM previsto WHERE rotulo = 'alcancavel') = '{whatsapp}'::canal[],
  (SELECT acao FROM previsto WHERE rotulo = 'alcancavel'));

-- A que importa: inscrever não daria erro, e o motor encerraria como
-- concluído sem ter mandado nada.
SELECT pi.confere('sem identidade no canal do flow é sem_canal, não sucesso',
  (SELECT acao FROM previsto WHERE rotulo = 'so_email') = 'sem_canal'
  AND (SELECT problema FROM previsto WHERE rotulo = 'so_email') LIKE '%encerraria como concluído%',
  (SELECT acao || ' / ' || coalesce(problema,'') FROM previsto WHERE rotulo = 'so_email'));

SELECT pi.confere('contato suprimido aparece como suprimido, não como nulo mudo',
  (SELECT acao FROM previsto WHERE rotulo = 'suprimido') = 'suprimido'
  AND (SELECT problema FROM previsto WHERE rotulo = 'suprimido') LIKE '%silêncio%');

SELECT pi.confere('identidade suprimida por valor não conta como alcance',
  (SELECT acao FROM previsto WHERE rotulo = 'numero_suprimido') = 'sem_canal',
  (SELECT acao FROM previsto WHERE rotulo = 'numero_suprimido'));

SELECT pi.confere('identidade inválida não conta como alcance',
  (SELECT acao FROM previsto WHERE rotulo = 'invalido') = 'sem_canal',
  (SELECT acao FROM previsto WHERE rotulo = 'invalido'));

SELECT pi.confere('quem já está inscrito é ja_inscrito, e não unique_violation',
  (SELECT acao FROM previsto WHERE rotulo = 'ja_inscrito') = 'ja_inscrito');

SELECT pi.confere('contato de fora do cliente é desconhecido, não erro',
  (SELECT acao FROM prever_inscricao(:'t', :'camp', :'fv',
     ARRAY['dd000000-0000-0000-0000-0000000000ff'::uuid])) = 'desconhecido');

SELECT pi.confere('lista vazia não é erro',
  (SELECT count(*) FROM prever_inscricao(:'t', :'camp', :'fv', '{}'::uuid[])) = 0);

-- ---------------------------------------------------------------------------
-- Flow e campanha que não se cruzam: ninguém receberia nada
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_fv uuid := gen_random_uuid(); v_flow uuid := gen_random_uuid();
BEGIN
  INSERT INTO flows (id, nome) VALUES (v_flow, 'Só e-mail');
  INSERT INTO flow_versions (id, flow_id, versao) VALUES (v_fv, v_flow, 1);
  INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
  VALUES (v_fv, 1, 'email', 0, 'Assunto: oi' || chr(10) || chr(10) || 'corpo');

  PERFORM pi.confere(
    'flow que não cruza com os canais da campanha acusa a configuração',
    (SELECT problema FROM prever_inscricao(
        '00000000-0000-0000-0000-0000000000aa',
        'dd000000-0000-0000-0000-000000000001', v_fv,
        (SELECT array_agg(id) FROM quem WHERE rotulo = 'alcancavel'))) LIKE '%nenhum passo do flow%',
    coalesce((SELECT problema FROM prever_inscricao(
        '00000000-0000-0000-0000-0000000000aa',
        'dd000000-0000-0000-0000-000000000001', v_fv,
        (SELECT array_agg(id) FROM quem WHERE rotulo = 'alcancavel'))), '(sem problema)'));
END;
$$;

-- ---------------------------------------------------------------------------
-- O que sustenta o nome
-- ---------------------------------------------------------------------------

SELECT pi.confere('a prévia não inscreveu ninguém',
  (SELECT enrollments FROM antes) = (SELECT count(*) FROM enrollments),
  (SELECT (SELECT enrollments FROM antes)::text || ' -> ' || count(*)::text FROM enrollments));

SELECT pi.confere('prever_inscricao é STABLE, não VOLATILE',
  (SELECT provolatile FROM pg_proc WHERE proname = 'prever_inscricao') = 's');

SELECT pi.confere('anon não chama a prévia de inscrição',
  NOT has_function_privilege('anon', 'prever_inscricao(uuid, uuid, uuid, uuid[])', 'EXECUTE'));

SELECT pi.confere('authenticated chama a prévia de inscrição',
  has_function_privilege('authenticated', 'prever_inscricao(uuid, uuid, uuid, uuid[])', 'EXECUTE'));

SELECT pi.confere('search_path da prévia de inscrição é fixo',
  (SELECT proconfig FROM pg_proc WHERE proname = 'prever_inscricao')
    @> ARRAY['search_path=public, privado']);

-- ---------------------------------------------------------------------------
-- A prévia e a inscrição têm que concordar
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_id uuid; v_erro text;
BEGIN
  -- Quem a prévia disse 'inscrever' entra mesmo.
  SELECT inscrever(id, 'dd000000-0000-0000-0000-000000000001',
                   'dd000000-0000-0000-0000-000000000003', now())
    INTO v_id FROM quem WHERE rotulo = 'alcancavel';
  PERFORM pi.confere('prévia disse inscrever e a inscrição devolveu enrollment',
    v_id IS NOT NULL, coalesce(v_id::text, '(nulo)'));

  -- Quem ela disse 'suprimido' devolve nulo mudo — que é exatamente o motivo
  -- de a prévia existir.
  SELECT inscrever(id, 'dd000000-0000-0000-0000-000000000001',
                   'dd000000-0000-0000-0000-000000000003', now())
    INTO v_id FROM quem WHERE rotulo = 'suprimido';
  PERFORM pi.confere('prévia disse suprimido e a inscrição devolveu nulo',
    v_id IS NULL, coalesce(v_id::text, '(nulo)'));

  -- E quem ela disse 'ja_inscrito' levanta, matando a chamada inteira.
  BEGIN
    PERFORM inscrever(id, 'dd000000-0000-0000-0000-000000000001',
                      'dd000000-0000-0000-0000-000000000003', now())
      FROM quem WHERE rotulo = 'ja_inscrito';
    v_erro := '(não levantou)';
  EXCEPTION WHEN unique_violation THEN v_erro := 'unique_violation';
  END;
  PERFORM pi.confere('prévia disse ja_inscrito e a inscrição levantou unique_violation',
    v_erro = 'unique_violation', v_erro);
END;
$$;

\echo ''
\echo '============= PRÉVIA DA INSCRIÇÃO ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM pi.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM pi.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pi.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'prévia da inscrição: % asserções falharam',
      (SELECT count(*) FROM pi.resultado WHERE NOT ok);
  END IF;
END;
$$;
