-- O agendamento do motor: pg_cron acorda a edge function, sem chave no SQL.
--
-- Até aqui o motor era um endpoint que alguém tinha que chamar. Isso não é o
-- modelo: o estado vive no contato, e a execução é um worker que acorda e
-- pergunta "quem está vencido agora?". Sem cron, a pergunta nunca é feita.
--
-- O jeito que a internet ensina é colar a service key dentro do comando do
-- job. Aqui não: a chave vai para o Vault e a função a lê na hora. Comando de
-- job fica em `cron.job`, uma tabela como outra qualquer — chave ali dentro é
-- segredo em texto claro, com backup, réplica e `pg_dump` junto.
--
-- Tudo em EXECUTE dinâmico pela mesma razão do Vault: `cron` e `net` só
-- existem no Supabase, e o Postgres do teste precisa aplicar a migration. Sem
-- isso a suíte inteira pararia de rodar por causa de duas extensões.

-- ---------------------------------------------------------------------------
-- Extensões
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_net') THEN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- A chave
-- ---------------------------------------------------------------------------

-- Nome fixo: o operador guarda o segredo uma vez, com este nome, e nada mais
-- precisa saber dele. Trocar a chave é trocar o segredo — nenhum job muda.
CREATE FUNCTION privado.chave_do_motor() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v text;
BEGIN
  IF to_regnamespace('vault') IS NULL THEN RETURN NULL; END IF;
  EXECUTE 'SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = $1'
    INTO v USING 'chave_do_motor';
  RETURN v;
END;
$$;

COMMENT ON FUNCTION privado.chave_do_motor IS
  'Lê a service key do Vault pelo nome fixo `chave_do_motor`. Existe para que
   a chave não apareça no comando do job, que mora numa tabela comum.';

-- ---------------------------------------------------------------------------
-- A batida
-- ---------------------------------------------------------------------------

-- Uma passada do motor. `pg_net` enfileira e devolve na hora: o job termina em
-- milissegundos e a resposta aparece depois em `net._http_response`. Job que
-- espera worker é job que se acumula quando o worker demora.
CREATE FUNCTION privado.acordar_motor(p_url text, p_limite integer DEFAULT 50)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_chave text; v_req bigint;
BEGIN
  v_chave := privado.chave_do_motor();
  IF v_chave IS NULL THEN
    RAISE EXCEPTION 'segredo `chave_do_motor` não está no Vault'
      USING ERRCODE = 'no_data_found',
            HINT = 'Project Settings ▸ Vault ▸ novo segredo com esse nome.';
  END IF;

  IF to_regnamespace('net') IS NULL THEN
    RAISE EXCEPTION 'pg_net indisponível: não há como chamar o worker'
      USING ERRCODE = 'feature_not_supported';
  END IF;

  -- Sem `modo` no corpo. O worker trata a ausência como `simulado`, e é assim
  -- que fica até a comparação com o Disparador fechar (Fase 3). Ligar o envio
  -- de verdade é editar o agendamento, não mexer em código.
  EXECUTE $q$
    SELECT net.http_post(
      url     := $1,
      body    := jsonb_build_object('limite', $2),
      headers := jsonb_build_object(
                   'content-type',  'application/json',
                   'Authorization', 'Bearer ' || $3),
      timeout_milliseconds := 20000)
  $q$ INTO v_req USING p_url, p_limite, v_chave;

  RETURN v_req;
END;
$$;

COMMENT ON FUNCTION privado.acordar_motor IS
  'Uma passada do motor, em modo simulado. Enfileira por pg_net e volta na
   hora — job que espera worker se acumula quando o worker demora.';

-- ---------------------------------------------------------------------------
-- O agendamento
-- ---------------------------------------------------------------------------

-- Idempotente de propósito: reagendar com outra expressão é a operação comum
-- (subir a frequência, baixar no fim de semana), e duas cópias do mesmo job
-- dobrariam a carga sem ninguém notar até o rate limit reclamar.
CREATE FUNCTION privado.agendar_motor(
  p_url       text,
  p_expressao text DEFAULT '*/5 * * * *',
  p_limite    integer DEFAULT 50
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id bigint;
BEGIN
  IF to_regnamespace('cron') IS NULL THEN
    RAISE EXCEPTION 'pg_cron indisponível: habilite a extensão antes'
      USING ERRCODE = 'feature_not_supported';
  END IF;

  PERFORM privado.desagendar_motor();

  EXECUTE 'SELECT cron.schedule($1, $2, $3)' INTO v_id
    USING 'motor-worker', p_expressao,
          format('SELECT privado.acordar_motor(%L, %s)', p_url, p_limite::text);

  RETURN v_id;
END;
$$;

CREATE FUNCTION privado.desagendar_motor() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_existe boolean;
BEGIN
  IF to_regnamespace('cron') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM cron.job WHERE jobname = $1)'
    INTO v_existe USING 'motor-worker';
  IF v_existe THEN EXECUTE 'SELECT cron.unschedule($1)' USING 'motor-worker'; END IF;
  RETURN v_existe;
END;
$$;

-- ---------------------------------------------------------------------------
-- Enxergar o que aconteceu
-- ---------------------------------------------------------------------------

-- Em shadow mode ninguém recebe mensagem, então "está rodando?" não tem
-- sintoma externo nenhum. Sem isto, a única evidência seria olhar `messages` e
-- torcer — e um 401 no worker pareceria exatamente com "não havia vencidos".
CREATE FUNCTION privado.ultimas_passadas(p_quantas integer DEFAULT 10)
RETURNS TABLE (quando timestamptz, status integer, corpo text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
BEGIN
  IF to_regnamespace('net') IS NULL THEN RETURN; END IF;
  RETURN QUERY EXECUTE $q$
    SELECT created, status_code, left(content, 400)
      FROM net._http_response ORDER BY created DESC LIMIT $1
  $q$ USING p_quantas;
END;
$$;

COMMENT ON FUNCTION privado.ultimas_passadas IS
  'Em shadow mode não há sintoma externo de que o motor roda. Um 401 no worker
   pareceria igual a "não havia vencidos" — esta é a diferença.';

-- ---------------------------------------------------------------------------
-- Superfície
-- ---------------------------------------------------------------------------

-- Nenhuma delas é API. Agendar o motor é operação da plataforma, não do
-- cliente: quem chama é o operador por psql ou o `service_role`. `privado` já
-- não é publicada pelo PostgREST (D19); o REVOKE é o cinto além do suspensório.
DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'privado.chave_do_motor()',
    'privado.acordar_motor(text, integer)',
    'privado.agendar_motor(text, text, integer)',
    'privado.desagendar_motor()',
    'privado.ultimas_passadas(integer)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END IF;
  END LOOP;
END;
$$;
