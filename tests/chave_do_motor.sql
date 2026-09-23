-- A conferência da chave do motor (D44).
--
-- O que este arquivo sustenta: a conferência acerta o diagnóstico em cada
-- forma de chave errada, e — a asserção que mais importa — **nunca devolve a
-- chave**. Uma função que lê um segredo e escreve texto é uma função a uma
-- edição de distância de vazá-lo; aqui isso falha o suite.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ch;
CREATE TABLE ch.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION ch.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ch.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

-- ---------------------------------------------------------------------------
-- Um Vault de mentira
--
-- O banco de teste não tem a extensão do Supabase. O que a conferência usa
-- dela é uma coisa só: `vault.decrypted_secrets(name, decrypted_secret)`.
-- Então o teste cria esse formato e troca o conteúdo a cada caso.
--
-- Nenhum valor daqui é segredo de ninguém: os JWTs são montados na hora, com
-- assinatura literalmente escrita como `assinatura-falsa`. A conferência lê o
-- corpo e não verifica assinatura — é diagnóstico, não autenticação.
-- ---------------------------------------------------------------------------

CREATE SCHEMA vault;
CREATE TABLE vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text NOT NULL);

-- `encode(..., 'base64')` quebra linha a cada 76 caracteres, e a quebra
-- despedaça o token. A primeira versão deste helper não tirava, e as nove
-- asserções de JWT falharam todas de uma vez — por defeito do teste, não da
-- função. Vale a lembrança: um helper de teste errado reprova código certo.
CREATE FUNCTION ch.jwt(p_payload jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT translate(replace(encode('{"alg":"HS256","typ":"JWT"}'::bytea, 'base64'),
                           chr(10), ''), '+/=', '-_')
      || '.'
      || translate(replace(encode(p_payload::text::bytea, 'base64'),
                           chr(10), ''), '+/=', '-_')
      || '.assinatura-falsa';
$$;

CREATE FUNCTION ch.por(p_chave text) RETURNS void LANGUAGE sql AS $$
  DELETE FROM vault.decrypted_secrets WHERE name = 'chave_do_motor';
  INSERT INTO vault.decrypted_secrets VALUES ('chave_do_motor', p_chave);
$$;

CREATE FUNCTION ch.linha(p_item text, p_url text DEFAULT NULL)
RETURNS ch.resultado LANGUAGE sql AS $$
  SELECT NULL::integer, c.item, c.ok, c.detalhe
    FROM privado.conferir_chave_do_motor(p_url) c WHERE c.item = p_item;
$$;

\set ok_jwt   '{"iss":"supabase","ref":"projetoabcdefghijkl","role":"service_role","exp":4102444800}'
\set anon_jwt '{"iss":"supabase","ref":"projetoabcdefghijkl","role":"anon","exp":4102444800}'

DO $$
DECLARE r record;
BEGIN
  -- Sem segredo nenhum.
  DELETE FROM vault.decrypted_secrets;
  SELECT * INTO r FROM ch.linha('segredo');
  PERFORM ch.confere('segredo ausente é apontado, e o diagnóstico para ali',
    r.ok IS false AND r.detalhe LIKE '%nome é exato%', coalesce(r.detalhe,'(nada)'));
  PERFORM ch.confere('sem segredo, nenhuma linha fala de papel',
    NOT EXISTS (SELECT 1 FROM privado.conferir_chave_do_motor() c WHERE c.item = 'papel'));
END;
$$;

DO $$
DECLARE r record;
BEGIN
  -- A chave certa.
  PERFORM ch.por(ch.jwt('{"iss":"supabase","ref":"projetoabcdefghijkl","role":"service_role","exp":4102444800}'::jsonb));
  SELECT * INTO r FROM ch.linha('papel');
  PERFORM ch.confere('service_role é aprovada', r.ok, coalesce(r.detalhe,'(nada)'));
  SELECT * INTO r FROM ch.linha('validade');
  PERFORM ch.confere('chave no prazo passa na validade', r.ok, coalesce(r.detalhe,'(nada)'));
  PERFORM ch.confere('com a chave certa, tudo passa',
    NOT EXISTS (SELECT 1 FROM privado.conferir_chave_do_motor() c WHERE NOT c.ok));
END;
$$;

DO $$
DECLARE r record;
BEGIN
  -- O erro que motivou a função: a anon no lugar da service_role.
  PERFORM ch.por(ch.jwt('{"iss":"supabase","ref":"projetoabcdefghijkl","role":"anon","exp":4102444800}'::jsonb));
  SELECT * INTO r FROM ch.linha('papel');
  PERFORM ch.confere('a chave anônima é reprovada', r.ok IS false, coalesce(r.detalhe,'(nada)'));
  PERFORM ch.confere('e o diagnóstico diz onde ela fica na tela, não só que está errada',
    r.detalhe LIKE '%logo acima%', coalesce(r.detalhe,'(nada)'));
  PERFORM ch.confere('e diz como o erro se manifesta, que é o que ninguém liga aos pontos',
    r.detalhe LIKE '%401%' AND r.detalhe LIKE '%vencidos%', coalesce(r.detalhe,'(nada)'));
END;
$$;

DO $$
DECLARE r record;
BEGIN
  -- Chave certa, projeto errado.
  PERFORM ch.por(ch.jwt('{"iss":"supabase","ref":"outroprojetoabcdefg","role":"service_role","exp":4102444800}'::jsonb));
  SELECT * INTO r FROM ch.linha('projeto', 'https://projetoabcdefghijkl.supabase.co/functions/v1/motor-worker');
  PERFORM ch.confere('chave de outro projeto é reprovada quando a URL é dada',
    r.ok IS false, coalesce(r.detalhe,'(nada)'));

  PERFORM ch.por(ch.jwt('{"iss":"supabase","ref":"projetoabcdefghijkl","role":"service_role","exp":4102444800}'::jsonb));
  SELECT * INTO r FROM ch.linha('projeto', 'https://projetoabcdefghijkl.supabase.co/functions/v1/motor-worker');
  PERFORM ch.confere('e aprovada quando bate', r.ok, coalesce(r.detalhe,'(nada)'));
END;
$$;

DO $$
DECLARE r record;
BEGIN
  -- Expirada.
  PERFORM ch.por(ch.jwt('{"iss":"supabase","ref":"projetoabcdefghijkl","role":"service_role","exp":1600000000}'::jsonb));
  SELECT * INTO r FROM ch.linha('validade');
  PERFORM ch.confere('chave expirada é reprovada', r.ok IS false, coalesce(r.detalhe,'(nada)'));
END;
$$;

DO $$
DECLARE r record;
BEGIN
  -- Formato novo: publicável e secreta.
  PERFORM ch.por('sb_publishable_naoehsegredo000000000');
  SELECT * INTO r FROM ch.linha('formato');
  PERFORM ch.confere('a chave publicável é reprovada pelo formato',
    r.ok IS false AND r.detalhe LIKE '%PUBLIC%', coalesce(r.detalhe,'(nada)'));

  PERFORM ch.por('sb_secret_naoehsegredo00000000000');
  SELECT * INTO r FROM ch.linha('papel');
  PERFORM ch.confere('a chave secreta nova é aceita sem tentar decodificar',
    r.ok, coalesce(r.detalhe,'(nada)'));

  -- Cópia suja: o caso de quem arrasta o mouse e leva aspas junto.
  PERFORM ch.por('nao-e-jwt-nenhum');
  SELECT * INTO r FROM ch.linha('formato');
  PERFORM ch.confere('texto que não é chave nenhuma é reprovado pelo formato',
    r.ok IS false AND r.detalhe LIKE '%espaço%', coalesce(r.detalhe,'(nada)'));
END;
$$;

DO $$
DECLARE r record;
BEGIN
  -- Quebra de linha na cópia. Não aparece em campo de senha, viaja no
  -- cabeçalho, e o 401 fica idêntico ao de chave errada.
  PERFORM ch.por(ch.jwt('{"iss":"supabase","ref":"projetoabcdefghijkl","role":"service_role","exp":4102444800}'::jsonb) || chr(10));
  SELECT * INTO r FROM ch.linha('limpeza');
  PERFORM ch.confere('quebra de linha nas pontas é apontada',
    r.ok IS false AND r.detalhe LIKE '%Authorization%', coalesce(r.detalhe,'(nada)'));
  -- E o diagnóstico continua: apontar a sujeira e parar deixaria a pessoa
  -- corrigir o espaço para descobrir depois que a chave também é a errada.
  SELECT * INTO r FROM ch.linha('papel');
  PERFORM ch.confere('e o resto do diagnóstico continua mesmo assim',
    r.ok, coalesce(r.detalhe,'(nada)'));
END;
$$;

-- ---------------------------------------------------------------------------
-- A asserção que esta função existe para não falhar
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_chave text;
  v_vazou integer;
BEGIN
  v_chave := ch.jwt('{"iss":"supabase","ref":"projetoabcdefghijkl","role":"service_role","exp":4102444800}'::jsonb);
  PERFORM ch.por(v_chave);

  -- Nenhuma saída pode conter a chave, nem inteira nem em pedaço grande o
  -- suficiente para ser útil. O corpo do JWT é o pedaço que carrega o valor.
  SELECT count(*) INTO v_vazou FROM privado.conferir_chave_do_motor(
    'https://projetoabcdefghijkl.supabase.co/functions/v1/motor-worker') c
   WHERE c.detalhe LIKE '%' || v_chave || '%'
      OR c.detalhe LIKE '%' || split_part(v_chave, '.', 2) || '%';
  PERFORM ch.confere('a conferência NUNCA devolve a chave', v_vazou = 0,
    v_vazou::text || ' linha(s) com o valor');

  -- E o tamanho é um fato sobre ela, não ela: conferir que a linha do segredo
  -- traz só o número.
  PERFORM ch.confere('a linha do segredo traz o tamanho, não o conteúdo',
    EXISTS (SELECT 1 FROM privado.conferir_chave_do_motor() c
             WHERE c.item = 'segredo'
               AND c.detalhe LIKE '%' || length(v_chave)::text || ' caracteres%'
               AND c.detalhe NOT LIKE '%' || left(v_chave, 20) || '%'));
END;
$$;

-- ---------------------------------------------------------------------------
-- Superfície (D29): não é API
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  PERFORM ch.confere('authenticated não alcança a conferência',
    NOT has_function_privilege('authenticated',
      'privado.conferir_chave_do_motor(text)', 'EXECUTE'));
  PERFORM ch.confere('anon não alcança a conferência',
    NOT has_function_privilege('anon',
      'privado.conferir_chave_do_motor(text)', 'EXECUTE'));
  PERFORM ch.confere('service_role alcança',
    has_function_privilege('service_role',
      'privado.conferir_chave_do_motor(text)', 'EXECUTE'));
END;
$$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM ch.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM ch.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM ch.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'chave_do_motor: % asserção(ões) falharam', n; END IF;
END;
$$;
