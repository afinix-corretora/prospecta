-- Prévia da importação (D34).
--
-- O que este arquivo sustenta: a prévia diz o mesmo que a ingestão faria, e
-- não grava nada. A segunda metade é a que importa — uma prévia que escreve
-- não é prévia, e o jeito de provar isso é contar as linhas antes e depois.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA pv;
CREATE TABLE pv.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION pv.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO pv.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t '00000000-0000-0000-0000-0000000000aa'

-- ---------------------------------------------------------------------------
-- Um mundo com uma pessoa dentro, um número suprimido e dois contatos que uma
-- linha tentará fundir.
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_marina uuid; v_joao uuid; v_ana uuid;
BEGIN
  SELECT contact_id INTO v_marina FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"(15) 99123-4567","valor_norm":"5515991234567"}]'::jsonb,
    'Marina Souza');

  -- Duas pessoas distintas hoje. A linha que trouxer as duas identidades
  -- juntas está pedindo fusão, e fusão é recusa.
  SELECT contact_id INTO v_joao FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"email","valor":"joao@exemplo.com.br","valor_norm":"joao@exemplo.com.br"}]'::jsonb,
    'João Lima');
  SELECT contact_id INTO v_ana FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"sms","valor":"15988887777","valor_norm":"5515988887777"}]'::jsonb,
    'Ana Paula');

  -- Um endereço suprimido que ainda não pertence a ninguém: a supressão por
  -- valor vale antes de o contato existir, e a prévia tem que mostrar isso.
  INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
  VALUES ('00000000-0000-0000-0000-0000000000aa','email','bloqueado@exemplo.com.br','opt_out');
END;
$$;

CREATE TEMP TABLE antes AS
SELECT (SELECT count(*) FROM contacts)           AS contatos,
       (SELECT count(*) FROM contact_identities) AS identidades;

-- ---------------------------------------------------------------------------
-- A prévia
-- ---------------------------------------------------------------------------

CREATE TEMP TABLE previsto AS
SELECT * FROM prever_ingestao(:'t', $j$[
  {"linha": 2, "identidades": [
     {"canal":"whatsapp","valor_norm":"5515991234567"},
     {"canal":"email","valor_norm":"marina@exemplo.com.br"}]},
  {"linha": 3, "identidades": [{"canal":"email","valor_norm":"novo@exemplo.com.br"}]},
  {"linha": 4, "identidades": [
     {"canal":"email","valor_norm":"joao@exemplo.com.br"},
     {"canal":"sms","valor_norm":"5515988887777"}]},
  {"linha": 5, "identidades": [{"canal":"email","valor_norm":"MAIUSCULA@exemplo.com.br"}]},
  {"linha": 6, "identidades": []},
  {"linha": 7, "identidades": [{"canal":"email","valor_norm":"bloqueado@exemplo.com.br"}]},
  {"linha": 8, "identidades": [{"canal":"telegrama","valor_norm":"seja-la-o-que-for"}]}
]$j$::jsonb);

SELECT pv.confere('a prévia devolve uma linha por linha pedida',
  (SELECT count(*) FROM previsto) = 7,
  (SELECT count(*)::text FROM previsto));

SELECT pv.confere('linha que casa por identidade existente é atualização',
  (SELECT acao FROM previsto WHERE linha = 2) = 'atualizar'
  AND (SELECT nome_atual FROM previsto WHERE linha = 2) = 'Marina Souza',
  (SELECT acao || ' / ' || coalesce(nome_atual,'(sem nome)') FROM previsto WHERE linha = 2));

SELECT pv.confere('a atualização conta identidade nova e identidade já existente',
  (SELECT identidades_novas FROM previsto WHERE linha = 2) = 1
  AND (SELECT identidades_existentes FROM previsto WHERE linha = 2) = 1);

SELECT pv.confere('linha sem nenhuma identidade conhecida é criação',
  (SELECT acao FROM previsto WHERE linha = 3) = 'criar'
  AND (SELECT contact_id FROM previsto WHERE linha = 3) IS NULL
  AND (SELECT identidades_novas FROM previsto WHERE linha = 3) = 1);

SELECT pv.confere('fusão de dois contatos existentes é recusada na prévia',
  (SELECT acao FROM previsto WHERE linha = 4) = 'recusar'
  AND (SELECT problema FROM previsto WHERE linha = 4) LIKE '%2 contatos diferentes%',
  (SELECT coalesce(problema,'(sem problema)') FROM previsto WHERE linha = 4));

SELECT pv.confere('identidade não normalizada é recusada com o valor no motivo',
  (SELECT acao FROM previsto WHERE linha = 5) = 'recusar'
  AND (SELECT problema FROM previsto WHERE linha = 5) LIKE '%não normalizada%MAIUSCULA%',
  (SELECT coalesce(problema,'(sem problema)') FROM previsto WHERE linha = 5));

SELECT pv.confere('linha sem identidade nenhuma é recusada, não some',
  (SELECT acao FROM previsto WHERE linha = 6) = 'recusar'
  AND (SELECT problema FROM previsto WHERE linha = 6) LIKE '%sem identidade%');

-- A pessoa que importa 500 linhas merece saber que 12 nunca serão tocadas —
-- e saber antes, não depois.
SELECT pv.confere('endereço suprimido é contado mesmo sem contato dono',
  (SELECT identidades_suprimidas FROM previsto WHERE linha = 7) = 1
  AND (SELECT acao FROM previsto WHERE linha = 7) = 'criar',
  (SELECT identidades_suprimidas::text FROM previsto WHERE linha = 7));

-- Canal inválido tem que recusar a linha, não abortar a prévia. Se o cast
-- fosse direto, esta chamada inteira teria morrido antes de chegar aqui.
SELECT pv.confere('canal que não existe recusa a linha sem derrubar a prévia',
  (SELECT acao FROM previsto WHERE linha = 8) = 'recusar'
  AND (SELECT problema FROM previsto WHERE linha = 8) = 'canal desconhecido: telegrama',
  (SELECT coalesce(problema,'(sem problema)') FROM previsto WHERE linha = 8));

SELECT pv.confere('prever com lista vazia não é erro',
  (SELECT count(*) FROM prever_ingestao(:'t', '[]'::jsonb)) = 0);

-- ---------------------------------------------------------------------------
-- E o que sustenta o nome: nada foi gravado
-- ---------------------------------------------------------------------------

SELECT pv.confere('a prévia não criou contato',
  (SELECT contatos FROM antes) = (SELECT count(*) FROM contacts),
  (SELECT (SELECT contatos FROM antes)::text || ' -> ' || count(*)::text FROM contacts));

SELECT pv.confere('a prévia não criou identidade',
  (SELECT identidades FROM antes) = (SELECT count(*) FROM contact_identities),
  (SELECT (SELECT identidades FROM antes)::text || ' -> ' || count(*)::text
     FROM contact_identities));

SELECT pv.confere('prever_ingestao é STABLE, não VOLATILE',
  (SELECT provolatile FROM pg_proc WHERE proname = 'prever_ingestao') = 's',
  'VOLATILE esconderia que a função não escreve');

-- ---------------------------------------------------------------------------
-- Superfície: a prévia é API, a trava não é
-- ---------------------------------------------------------------------------

SELECT pv.confere('anon não chama a prévia',
  NOT has_function_privilege('anon', 'prever_ingestao(uuid, jsonb)', 'EXECUTE'));

SELECT pv.confere('authenticated chama a prévia',
  has_function_privilege('authenticated', 'prever_ingestao(uuid, jsonb)', 'EXECUTE'));

SELECT pv.confere('a prévia mora em public, que é onde o PostgREST publica',
  (SELECT n.nspname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.proname = 'prever_ingestao') = 'public');

SELECT pv.confere('search_path da prévia é fixo',
  (SELECT proconfig FROM pg_proc WHERE proname = 'prever_ingestao')
    @> ARRAY['search_path=public, privado']);

-- ---------------------------------------------------------------------------
-- A prévia e a ingestão têm que concordar
-- ---------------------------------------------------------------------------

-- Prever, depois ingerir de verdade as mesmas linhas, e conferir que a ação
-- prevista foi a ação executada. Duas metades que discordam são piores do que
-- não ter prévia: a pessoa decide com base na errada.
DO $$
DECLARE r record; v_acao text;
BEGIN
  SELECT acao INTO v_acao FROM previsto WHERE linha = 2;
  SELECT * INTO r FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"(15) 99123-4567","valor_norm":"5515991234567"},
      {"canal":"email","valor":"marina@exemplo.com.br","valor_norm":"marina@exemplo.com.br"}]'::jsonb);
  PERFORM pv.confere('linha 2: a prévia disse atualizar e a ingestão atualizou',
    v_acao = 'atualizar' AND r.acao = 'atualizado', v_acao || ' / ' || r.acao);
  PERFORM pv.confere('linha 2: os contadores da prévia bateram com os da ingestão',
    r.identidades_novas = (SELECT identidades_novas FROM previsto WHERE linha = 2)
    AND r.identidades_existentes = (SELECT identidades_existentes FROM previsto WHERE linha = 2),
    r.identidades_novas || '/' || r.identidades_existentes);

  SELECT acao INTO v_acao FROM previsto WHERE linha = 3;
  SELECT * INTO r FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"email","valor":"novo@exemplo.com.br","valor_norm":"novo@exemplo.com.br"}]'::jsonb);
  PERFORM pv.confere('linha 3: a prévia disse criar e a ingestão criou',
    v_acao = 'criar' AND r.acao = 'criado', v_acao || ' / ' || r.acao);
END;
$$;

DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    PERFORM ingerir_contato(
      '00000000-0000-0000-0000-0000000000aa', 'planilha',
      '[{"canal":"email","valor":"joao@exemplo.com.br","valor_norm":"joao@exemplo.com.br"},
        {"canal":"sms","valor":"15988887777","valor_norm":"5515988887777"}]'::jsonb);
    v_erro := '(não levantou)';
  EXCEPTION WHEN restrict_violation THEN v_erro := 'restrict_violation';
  END;
  PERFORM pv.confere('linha 4: a prévia disse recusar e a ingestão recusou',
    v_erro = 'restrict_violation', v_erro);
END;
$$;

\echo ''
\echo '============= PRÉVIA DA IMPORTAÇÃO ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM pv.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM pv.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pv.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'prévia: % asserções falharam',
      (SELECT count(*) FROM pv.resultado WHERE NOT ok);
  END IF;
END;
$$;
