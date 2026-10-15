-- A chave do agente de configuração (D72).
--
-- O que este arquivo sustenta:
--
--   1. quem está logado NÃO alcança o valor — nem anon, nem authenticated;
--      só o service_role (a edge function `agente-setup`);
--   2. quem está logado alcança o FATO (existe ou não), que é o que a tela
--      precisa para dizer se o agente está pronto (D44);
--   3. sem Vault, as duas respondem "não há" em vez de quebrar.
--
-- O banco de teste não tem `supabase_vault`, então nenhuma asserção aqui lê a
-- chave de volta. Que ela existe e tem o formato certo foi conferido no
-- projeto, por fatos (tamanho, prefixo, sem sujeira), e nunca pelo valor.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ag;
CREATE TABLE ag.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION ag.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ag.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

SELECT ag.confere('authenticated não chama a função que devolve a chave',
  NOT has_function_privilege('authenticated', 'segredo_do_agente_setup()', 'EXECUTE'));
SELECT ag.confere('anon não chama a função que devolve a chave',
  NOT has_function_privilege('anon', 'segredo_do_agente_setup()', 'EXECUTE'));
SELECT ag.confere('service_role chama a função que devolve a chave',
  has_function_privilege('service_role', 'segredo_do_agente_setup()', 'EXECUTE'));

SELECT ag.confere('authenticated pergunta se o agente está disponível',
  has_function_privilege('authenticated', 'agente_de_setup_disponivel()', 'EXECUTE'));
SELECT ag.confere('anon nem isso',
  NOT has_function_privilege('anon', 'agente_de_setup_disponivel()', 'EXECUTE'));

-- A pergunta devolve booleano, e não texto: é a forma que impede uma edição
-- futura de "aproveitar" a função para devolver a chave à tela.
SELECT ag.confere('disponível devolve boolean, nunca texto',
  (SELECT prorettype = 'boolean'::regtype FROM pg_proc WHERE proname = 'agente_de_setup_disponivel'));

SELECT ag.confere('sem Vault, disponível responde falso', agente_de_setup_disponivel() = false);
SELECT ag.confere('sem Vault, a chave é nula, não erro', segredo_do_agente_setup() IS NULL);

\echo ''
\echo '=== agente de setup ==='
SELECT CASE WHEN ok THEN 'ok  ' ELSE 'FALHA' END AS r, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM ag.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE NOT ok) AS falhas, count(*) AS total FROM ag.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM ag.resultado WHERE NOT ok;
  IF n > 0 THEN
    RAISE EXCEPTION '% asserção(ões) do agente de setup falharam', n;
  END IF;
END;
$$;
