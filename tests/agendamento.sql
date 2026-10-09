-- Testes do agendamento do motor.
--
-- O que dá para provar sem pg_cron e sem pg_net é justamente o que costuma
-- quebrar: que as funções existem fora da superfície publicada, que falham com
-- erro nomeado em vez de silêncio quando falta infraestrutura, e que a chave
-- não aparece em lugar nenhum que não seja o Vault.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ag2;
CREATE TABLE ag2.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION ag2.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ag2.resultado (nome, ok, detalhe) VALUES (p_nome, coalesce(p_cond,false), p_detalhe); END; $$;

-- ---------------------------------------------------------------------------
-- Onde moram
-- ---------------------------------------------------------------------------

SELECT ag2.confere('as cinco funções do agendamento existem',
  (SELECT count(*) = 5 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado'
      AND p.proname IN ('chave_do_motor','acordar_motor','agendar_motor',
                        'desagendar_motor','ultimas_passadas')),
  (SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado'
      AND p.proname IN ('chave_do_motor','acordar_motor','agendar_motor',
                        'desagendar_motor','ultimas_passadas')));

-- Agendar o motor é operação da plataforma, não do cliente. Nenhuma delas pode
-- ter nascido em `public`, que é o que o PostgREST publica (D19).
SELECT ag2.confere('nenhuma nasceu em public',
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('chave_do_motor','acordar_motor','agendar_motor',
                        'desagendar_motor','ultimas_passadas')));

SELECT ag2.confere('nenhuma é alcançável por usuário logado',
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado'
      AND p.proname IN ('chave_do_motor','acordar_motor','agendar_motor',
                        'desagendar_motor','ultimas_passadas')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')));

SELECT ag2.confere('nem por anônimo',
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado'
      AND p.proname IN ('chave_do_motor','acordar_motor','agendar_motor',
                        'desagendar_motor','ultimas_passadas')
      AND has_function_privilege('anon', p.oid, 'EXECUTE')));

-- Toda função do projeto tem search_path fixo. Sem isso, `SECURITY DEFINER`
-- executa o que o chamador puser na frente no caminho de busca.
SELECT ag2.confere('todas têm search_path fixo',
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado'
      AND p.proname IN ('chave_do_motor','acordar_motor','agendar_motor',
                        'desagendar_motor','ultimas_passadas')
      AND (p.proconfig IS NULL
           OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))));

-- ---------------------------------------------------------------------------
-- Falta de infraestrutura é erro nomeado, não silêncio
-- ---------------------------------------------------------------------------

-- Sem Vault local, a chave não está lá — e é este o erro que o operador vai
-- ver no dia em que esquecer de guardar o segredo. Ele precisa dizer o que
-- fazer, não "null value in ...".
DO $$
BEGIN
  PERFORM privado.acordar_motor('https://exemplo.supabase.co/functions/v1/motor-worker', 10);
  PERFORM ag2.confere('sem a chave no Vault, acordar_motor recusa', false, 'chamou assim mesmo');
EXCEPTION WHEN no_data_found THEN
  PERFORM ag2.confere('sem a chave no Vault, acordar_motor recusa', true);
WHEN others THEN
  PERFORM ag2.confere('sem a chave no Vault, acordar_motor recusa', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

SELECT ag2.confere('e a recusa diz onde guardar o segredo',
  (SELECT count(*) = 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado' AND p.proname = 'acordar_motor'
      AND p.prosrc LIKE '%Vault%'));

DO $$
BEGIN
  PERFORM privado.agendar_motor('https://exemplo.supabase.co/functions/v1/motor-worker');
  PERFORM ag2.confere('sem pg_cron, agendar_motor recusa', false, 'agendou sem extensão');
EXCEPTION WHEN feature_not_supported THEN
  PERFORM ag2.confere('sem pg_cron, agendar_motor recusa', true);
WHEN others THEN
  PERFORM ag2.confere('sem pg_cron, agendar_motor recusa', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- Desagendar é o caminho de limpeza e roda no down da migration. Explodir aqui
-- faria a reversão falhar num banco sem a extensão.
SELECT ag2.confere('desagendar_motor sem pg_cron devolve false em vez de explodir',
  privado.desagendar_motor() = false);

SELECT ag2.confere('ultimas_passadas sem pg_net devolve vazio em vez de explodir',
  (SELECT count(*) = 0 FROM privado.ultimas_passadas(5)));

-- ---------------------------------------------------------------------------
-- A chave não mora no comando do job
-- ---------------------------------------------------------------------------

-- O jeito comum de agendar isto é colar a service key dentro do comando. O
-- comando vive em `cron.job`, uma tabela como outra qualquer: vai para backup,
-- réplica e pg_dump. Esta asserção é o que impede alguém "simplificar" depois.
SELECT ag2.confere('o comando agendado não carrega chave, só a URL e o limite',
  (SELECT p.prosrc LIKE '%acordar_motor(%L%' AND p.prosrc NOT LIKE '%chave_do_motor()%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado' AND p.proname = 'agendar_motor'));

SELECT ag2.confere('quem lê a chave é só chave_do_motor',
  (SELECT count(*) = 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado' AND p.prosrc LIKE '%decrypted_secrets%'
      AND p.proname IN ('chave_do_motor','acordar_motor','agendar_motor',
                        'desagendar_motor','ultimas_passadas')));

-- ---------------------------------------------------------------------------
-- Shadow mode continua sendo o padrão
-- ---------------------------------------------------------------------------

-- O worker lê `modo` do corpo e trata a ausência como `simulado`. Se alguém
-- puser 'real' aqui, o motor passa a enviar de verdade sem nenhuma outra
-- mudança — e é o tipo de linha que entra num commit de "ajuste".
SELECT ag2.confere('o corpo enviado não pede modo real',
  (SELECT p.prosrc NOT LIKE '%real%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado' AND p.proname = 'acordar_motor'));

SELECT ag2.confere('a chamada leva Authorization',
  (SELECT p.prosrc LIKE '%Authorization%'
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado' AND p.proname = 'acordar_motor'));

\echo ''
\echo '============= AGENDAMENTO DO MOTOR ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM ag2.resultado ORDER BY id;
\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM ag2.resultado;

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM ag2.resultado WHERE NOT ok;
  IF v > 0 THEN RAISE EXCEPTION '% asserção(ões) de agendamento falharam', v; END IF;
END;
$$;
