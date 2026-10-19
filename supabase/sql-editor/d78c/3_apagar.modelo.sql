-- D78c: apaga as duas filas antigas do agente, sem chamador desde o D69 e o D76.
--
-- ESTE É O MODELO, e ele não apaga nada como está: tem dois marcadores no
-- DECLARE da guarda, e enquanto qualquer um estiver lá a guarda recusa antes de
-- tudo. A versão para rodar é este mesmo texto com os dois marcadores trocados
-- pelo que o 1_retrato.sql e o 2_backup.sql devolveram no MESMO banco, no SQL
-- Editor, logo antes:
--   v_selo_backup       a coluna selo do 2_backup.sql. A linha "selo" do
--                       1_retrato.sql tem que dar o mesmo valor.
--   v_chamadas_retrato  o N de "soma=N" na linha "chamadas" do 1_retrato.sql,
--                       e só quando essa linha disser le_outras_contas=sim.
--                       Se ela começar por "sem" (sem pg_stat_statements, sem
--                       permissao, sem registro...), o valor é -1, e -1 quer
--                       dizer "não conferir as chamadas". Se ela disser
--                       le_outras_contas=nao, quem roda não vê as chamadas que
--                       o worker faz pelo PostgREST (service_role): ou se
--                       concede pg_read_all_stats a ele (no Supabase, grant
--                       pg_read_all_stats to postgres;) e se roda o
--                       1_retrato.sql de novo, ou se usa -1, sabendo que as
--                       chamadas não serão conferidas.
-- Cada marcador aparece uma vez só no arquivo, entre aspas, no DECLARE: troca-se
-- o texto e as aspas ficam.
--
-- A ordem é: 1_retrato.sql — e PARE se a linha "outras citacoes" não disser
-- "nenhuma": alguém ainda cita as filas, e a guarda vai recusar; 2_backup.sql
-- (o script de restauração é guardado e o md5_script conferido ANTES de
-- seguir); preencher este modelo; rodar a versão preenchida inteira, numa
-- execução só. O selo usa pg_get_functiondef, que depende do search_path: o
-- backup e o DROP rodam no mesmo SQL Editor, com o mesmo papel.
--
-- Antes de apagar, a guarda confere sete coisas; se qualquer uma falhar, NADA é
-- apagado e nada é gravado:
--   0. os dois marcadores foram trocados por valores com a forma certa;
--   1. o corpo no projeto é o mesmo do repositório (md5);
--   2. o selo de agora é o do backup: definição, dono, comentário e grade não
--      mudaram desde o 2_backup.sql — um GRANT no meio do caminho, e o script
--      de restauração já não devolveria o que o DROP apaga;
--   3. nenhuma outra função, view ou job do pg_cron as cita. O nome é
--      procurado letra a letra, cada letra ela mesma ou como %XX de URL, sem
--      diferença de maiúsculas e com o _ valendo qualquer caractere, como no
--      LIKE de antes (o PostgREST decodifica o caminho do /rpc/).
--      Sem o schema cron não há job a conferir; com ele e sem permissão de ler
--      cron.job, a guarda recusa;
--   4. nenhum gatilho as cita no argumento (é onde o Database Webhook do
--      Supabase guarda a URL do rpc), com a mesma busca do passo 3;
--   5. ninguém as chamou depois do retrato: a soma de chamadas no
--      pg_stat_statements não passou da que o retrato leu. Com -1, não
--      confere — e -1 só é aceito quando quem roda NÃO conseguiria conferir:
--      sem a extensão, sem a biblioteca carregada, sem permissão de ler, sem
--      registro (track = none ou compute_query_id = off) ou sem ler as
--      consultas de outros papéis. Com 0 ou mais, tudo isso tem que valer
--      agora; se não vale, a guarda recusa, porque não dá para saber;
--   6. nada depende delas (pg_depend: view materializada, regra, política,
--      função BEGIN ATOMIC) e não há outra função com o mesmo nome. Sem este
--      passo, o DROP recusaria a dependência sozinho, mas em inglês e
--      sugerindo DROP ... CASCADE, que apagaria os dependentes junto: NÃO use.
-- O que o passo 5 não vê: chamada feita de dentro de outra função quando o
-- nome não está escrito no corpo (com pg_stat_statements.track = top fica só o
-- comando de fora; por EXECUTE com o nome montado em texto, nem o passo 3 nem o
-- 5 a veem, e a função que chamava quebra depois do DROP), estatística zerada
-- ou descartada entre o retrato e o DROP (a soma recomeça menor) e chamada que
-- ainda não aconteceu.
BEGIN;

DO $guarda$
DECLARE
  -- Os dois valores a preencher (ver o cabeçalho).
  v_selo_backup      text := '__SELO_DO_BACKUP__';
  v_chamadas_retrato text := '__CHAMADAS_NO_RETRATO__';
  v_faltam    text[] := ARRAY[]::text[];
  v_rascunhar text;
  v_agente    text;
  v_citam     text;
  v_selo      text;
  v_padrao    text;
  v_cron      oid;
  v_cron_nsp  oid;
  v_jobs      text;
  v_gatilhos  text;
  v_limite    bigint;
  v_pgss      name;
  v_pgss_oid  oid;
  v_carregada boolean;
  v_pode_ler  boolean;
  v_sem_registro text;
  v_le_outras boolean;
  v_soma      numeric;
  v_mesmo_nome text;
  v_dependem  text;
BEGIN
  -- 0. O modelo foi preenchido. Marcador que sobrou aparece na mensagem pelo
  --    próprio nome; valor fora da forma, entre aspas, para espaço aparecer.
  IF v_selo_backup !~ '^[0-9a-f]{32}$' THEN
    v_faltam := v_faltam || CASE
      WHEN v_selo_backup ~ '^__[A-Z_]+__$' THEN pg_catalog.format(
        'o modelo ainda tem %s: troque pela coluna selo do 2_backup.sql', v_selo_backup)
      ELSE pg_catalog.format(
        'v_selo_backup está como %L e precisa ser só a coluna selo do 2_backup.sql: 32 caracteres de 0-9 e a-f minúsculos, sem espaço',
        v_selo_backup) END;
  END IF;
  IF v_chamadas_retrato !~ '^(-1|0|[1-9][0-9]{0,17})$' THEN
    v_faltam := v_faltam || CASE
      WHEN v_chamadas_retrato ~ '^__[A-Z_]+__$' THEN pg_catalog.format(
        'o modelo ainda tem %s: troque pelo N de "soma=N" na linha chamadas do 1_retrato.sql, ou por -1 (ver o cabeçalho)',
        v_chamadas_retrato)
      ELSE pg_catalog.format(
        'v_chamadas_retrato está como %L e precisa ser só o número N de "soma=N" na linha chamadas do 1_retrato.sql, ou -1 (ver o cabeçalho)',
        v_chamadas_retrato) END;
  END IF;
  IF pg_catalog.cardinality(v_faltam) > 0 THEN
    RAISE EXCEPTION '%; nada foi apagado', pg_catalog.array_to_string(v_faltam, '; ');
  END IF;

  -- 1. O corpo no projeto é o mesmo do repositório.
  SELECT md5(prosrc) INTO v_rascunhar FROM pg_proc
   WHERE oid = to_regprocedure('public.respostas_para_rascunhar(integer)');
  SELECT md5(prosrc) INTO v_agente FROM pg_proc
   WHERE oid = to_regprocedure('public.respostas_para_o_agente(integer)');

  IF v_rascunhar IS DISTINCT FROM '6f364e60bcef3ed0a3a69f785bfb4662'
     OR v_agente IS DISTINCT FROM 'fd02a6d07872cb87c9fbb776a4323e19' THEN
    RAISE EXCEPTION 'o corpo no projeto difere do repositório: nada foi apagado (rascunhar=%, agente=%)',
      coalesce(v_rascunhar, 'ausente'), coalesce(v_agente, 'ausente');
  END IF;

  -- 2. Nada mudou depois do backup: definição, dono, comentário e grade das
  --    duas funções são os que o 2_backup.sql guardou (coluna selo). O cálculo
  --    é o mesmo bloco da CTE selo do 2_backup.sql e da linha selo do
  --    1_retrato.sql: mudou um, mudam os três.
  v_selo := (SELECT pg_catalog.md5(pg_catalog.string_agg(a.nome || '|' || coalesce((
            SELECT pg_catalog.concat_ws('|',
                     pg_catalog.md5(pg_catalog.pg_get_functiondef(p.oid)),
                     pg_catalog.pg_get_userbyid(p.proowner),
                     coalesce(pg_catalog.md5(pg_catalog.obj_description(p.oid, 'pg_proc')), 'sem comentario'),
                     coalesce((SELECT pg_catalog.string_agg(i.item, ',' ORDER BY i.item)
                                 FROM (SELECT CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                                                   ELSE pg_catalog.pg_get_userbyid(x.grantee) END
                                              || '=' || x.privilege_type
                                              || CASE WHEN x.is_grantable THEN '*' ELSE '' END
                                              || '/' || pg_catalog.pg_get_userbyid(x.grantor) AS item
                                         FROM pg_catalog.aclexplode(coalesce(p.proacl,
                                                pg_catalog.acldefault('f', p.proowner))) x) i),
                              '(vazia)'))
              FROM pg_catalog.pg_proc p
             WHERE p.oid = pg_catalog.to_regprocedure('public.' || a.nome || '(integer)')),
            'ausente'), E'\n' ORDER BY a.ordem))
     FROM (VALUES (1, 'respostas_para_rascunhar'), (2, 'respostas_para_o_agente')) AS a(ordem, nome));
  IF v_selo IS DISTINCT FROM v_selo_backup THEN
    RAISE EXCEPTION 'as funções mudaram depois do backup (selo agora %, no backup %): gere o backup de novo; nada foi apagado',
      v_selo, v_selo_backup;
  END IF;

  -- 3. Nenhuma outra função, view ou job do pg_cron as cita. O nome como ele
  --    pode aparecer escrito num texto: cada letra ela mesma ou como %XX de
  --    URL, o _ qualquer caractere (como no LIKE de antes, que esta busca
  --    contém), sem diferença de maiúsculas (~*). É o MESMO cálculo da CTE
  --    nome_em_texto do 1_retrato.sql: mudou um, mudam os dois.
  v_padrao := (SELECT pg_catalog.string_agg(n.padrao, '|' ORDER BY n.ordem)
    FROM (SELECT a.ordem,
                 (SELECT pg_catalog.string_agg('(' || CASE WHEN l.letra = '_' THEN '.' ELSE l.letra END
                                                 || '|%' || pg_catalog.to_hex(pg_catalog.ascii(l.letra)) || ')',
                                               '' ORDER BY l.i)
                    FROM pg_catalog.regexp_split_to_table(a.nome, '') WITH ORDINALITY AS l(letra, i)) AS padrao
            FROM (VALUES (1, 'respostas_para_rascunhar'), (2, 'respostas_para_o_agente')) AS a(ordem, nome)) n);

  SELECT pg_catalog.string_agg(quem, ', ' ORDER BY quem) INTO v_citam FROM (
    SELECT 'função ' || n.nspname || '.' || p.proname AS quem
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE p.proname NOT IN ('respostas_para_rascunhar', 'respostas_para_o_agente')
       AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND p.prosrc ~* v_padrao
    UNION ALL
    SELECT 'view ' || v.schemaname || '.' || v.viewname
      FROM pg_catalog.pg_views v
     WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema')
       AND v.definition ~* v_padrao
  ) t;

  -- O cron.job é achado pelo catálogo e lido por texto dinâmico: sem o schema
  -- cron não há job a conferir, e sem permissão de lê-lo não dá para saber.
  SELECT c.oid, c.relnamespace INTO v_cron, v_cron_nsp
    FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'cron' AND c.relname = 'job';
  IF v_cron IS NOT NULL THEN
    IF NOT (pg_catalog.has_schema_privilege(v_cron_nsp, 'USAGE')
            AND pg_catalog.has_table_privilege(v_cron, 'SELECT')) THEN
      RAISE EXCEPTION 'cron.job existe e % não pode lê-la: não dá para saber se algum job do pg_cron chama as filas; nada foi apagado',
        current_user;
    END IF;
    EXECUTE 'SELECT pg_catalog.string_agg(''job '' || coalesce(jobname, jobid::text), '', '' ORDER BY jobid)'
            || ' FROM cron.job WHERE command ~* $1'
       INTO v_jobs USING v_padrao;
    v_citam := nullif(pg_catalog.concat_ws(', ', v_citam, v_jobs), '');
  END IF;

  IF v_citam IS NOT NULL THEN
    RAISE EXCEPTION 'ainda citadas por: % — nada foi apagado', v_citam;
  END IF;

  -- 4. Nenhum gatilho as cita no argumento. O Database Webhook do Supabase é um
  --    gatilho cujo argumento é a URL: um que chame o rpc de uma delas não
  --    aparece no passo 3, porque o corpo do gatilho é genérico. Mesma busca do
  --    passo 3.
  SELECT pg_catalog.string_agg(pg_catalog.format('%I.%I / %I', tn.nspname, tc.relname, t.tgname), ', '
                               ORDER BY tn.nspname, tc.relname, t.tgname)
    INTO v_gatilhos
    FROM pg_catalog.pg_trigger t
    JOIN pg_catalog.pg_class tc     ON tc.oid = t.tgrelid
    JOIN pg_catalog.pg_namespace tn ON tn.oid = tc.relnamespace
   WHERE pg_catalog.encode(t.tgargs, 'escape') ~* v_padrao;

  IF v_gatilhos IS NOT NULL THEN
    RAISE EXCEPTION 'gatilho com argumento que cita as filas: % — nada foi apagado', v_gatilhos;
  END IF;

  -- 5. Ninguém as chamou depois do retrato. As perguntas antes de ler e a busca
  --    são as MESMAS da linha chamadas do 1_retrato.sql (mudou uma, muda a
  --    outra), neste banco só: a extensão existe, a biblioteca está carregada,
  --    quem roda pode ler, ela registra, e quem roda lê as consultas de outros
  --    papéis. -1 é "não conferir", e só vale quando alguma delas falha; com 0
  --    ou mais, qualquer uma que falhe agora recusa.
  v_limite := v_chamadas_retrato::bigint;
  SELECT n.oid, n.nspname INTO v_pgss_oid, v_pgss
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'pg_stat_statements';
  v_carregada := pg_catalog.current_setting('pg_stat_statements.max', true) IS NOT NULL;
  v_pode_ler := coalesce(v_pgss_oid IS NOT NULL
            AND pg_catalog.has_schema_privilege(v_pgss_oid, 'USAGE')
            AND EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                         WHERE c.relnamespace = v_pgss_oid AND c.relname = 'pg_stat_statements'
                           AND pg_catalog.has_table_privilege(c.oid, 'SELECT'))
            AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                             WHERE p.pronamespace = v_pgss_oid AND p.proname = 'pg_stat_statements'
                               AND NOT pg_catalog.has_function_privilege(p.oid, 'EXECUTE')), false);
  v_le_outras := pg_catalog.pg_has_role(current_user, 'pg_read_all_stats', 'USAGE');
  v_sem_registro := (SELECT pg_catalog.string_agg(m.motivo, ', ' ORDER BY m.motivo)
            FROM (SELECT 'pg_stat_statements.track=none nesta sessao' AS motivo
                   WHERE pg_catalog.lower(coalesce(pg_catalog.current_setting('pg_stat_statements.track', true), '')) = 'none'
                  UNION ALL
                  SELECT 'compute_query_id=' || pg_catalog.current_setting('compute_query_id', true) || ' nesta sessao'
                   WHERE pg_catalog.lower(coalesce(pg_catalog.current_setting('compute_query_id', true), ''))
                         IN ('off', 'false', 'no', '0')
                  UNION ALL
                  SELECT pg_catalog.format('%s em ALTER %s', c.item,
                           CASE WHEN s.setrole = 0 AND s.setdatabase = 0 THEN 'ROLE ALL'
                                WHEN s.setrole = 0 THEN 'DATABASE ' || pg_catalog.current_database()
                                WHEN s.setdatabase = 0 THEN 'ROLE ' || pg_catalog.pg_get_userbyid(s.setrole)
                                ELSE 'ROLE ' || pg_catalog.pg_get_userbyid(s.setrole)
                                     || ' IN DATABASE ' || pg_catalog.current_database() END)
                    FROM pg_catalog.pg_db_role_setting s
                    CROSS JOIN LATERAL pg_catalog.unnest(s.setconfig) AS c(item)
                   WHERE s.setdatabase IN (0, (SELECT d.oid FROM pg_catalog.pg_database d
                                                WHERE d.datname = pg_catalog.current_database()))
                     AND pg_catalog.lower(c.item)
                         ~ '^(pg_stat_statements\.track=''?none''?|compute_query_id=''?(off|false|no|0)''?)$'
                 ) m);
  IF v_limite = -1 THEN
    IF v_pgss IS NOT NULL AND v_carregada AND v_pode_ler AND v_sem_registro IS NULL AND v_le_outras THEN
      RAISE EXCEPTION 'o modelo diz -1, mas % consegue conferir as chamadas: rode o 1_retrato.sql de novo e use o N de soma=N; nada foi apagado',
        current_user;
    END IF;
  ELSE
    IF v_pgss IS NULL THEN
      RAISE EXCEPTION 'o retrato leu as chamadas no pg_stat_statements (soma %) e agora a extensão não existe: não dá para saber se alguém chamou as filas depois; nada foi apagado',
        v_limite;
    END IF;
    IF NOT v_carregada THEN
      RAISE EXCEPTION 'o retrato leu as chamadas no pg_stat_statements (soma %) e agora a biblioteca não está carregada (shared_preload_libraries): não dá para saber se alguém chamou as filas depois; nada foi apagado',
        v_limite;
    END IF;
    IF NOT v_pode_ler THEN
      RAISE EXCEPTION 'o retrato leu as chamadas no pg_stat_statements (soma %) e agora % não pode ler %.pg_stat_statements: não dá para saber se alguém chamou as filas depois; nada foi apagado',
        v_limite, current_user, v_pgss;
    END IF;
    IF v_sem_registro IS NOT NULL THEN
      RAISE EXCEPTION 'o pg_stat_statements não registra chamadas (%): não dá para saber se alguém chamou as filas depois do retrato (soma %); nada foi apagado',
        v_sem_registro, v_limite;
    END IF;
    IF NOT v_le_outras THEN
      RAISE EXCEPTION '% não lê o texto das consultas de outros papéis — as do worker pelo PostgREST são de anon, authenticated e service_role —, e a soma não as conta: conceda pg_read_all_stats a % (no Supabase, grant pg_read_all_stats to postgres;) e rode o 1_retrato.sql de novo, ou preencha -1 sabendo que as chamadas não serão conferidas; nada foi apagado',
        current_user, current_user;
    END IF;
    EXECUTE 'SELECT coalesce(pg_catalog.sum(s.calls), 0) FROM '
            || pg_catalog.quote_ident(v_pgss) || '.pg_stat_statements s'
            || ' WHERE s.dbid = (SELECT d.oid FROM pg_catalog.pg_database d'
            || ' WHERE d.datname = pg_catalog.current_database()) AND s.query ~* $1'
       INTO v_soma
      USING '(from|select|,|\(|lateral|join|perform)\s*("?public"?\s*\.\s*)?"?respostas_para_(rascunhar|o_agente)"?\s*\(';
    IF v_soma > v_limite THEN
      RAISE EXCEPTION 'as filas foram chamadas depois do retrato (soma de chamadas agora %, no retrato %): alguém ainda as usa; nada foi apagado',
        v_soma, v_limite;
    END IF;
  END IF;

  -- 6. Nada depende delas e não há outra função com o mesmo nome — as duas
  --    perguntas da linha "outras citacoes" do 1_retrato.sql que os passos 3 e
  --    4 não fazem. Sem este passo, a dependência faria o DROP recusar em
  --    inglês, sugerindo CASCADE.
  SELECT pg_catalog.string_agg(pg_catalog.format('%I.%I(%s)', n.nspname, p.proname,
                                                 pg_catalog.oidvectortypes(p.proargtypes)), ', '
                               ORDER BY n.nspname, p.proname, p.oid)
    INTO v_mesmo_nome
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
   WHERE p.proname IN ('respostas_para_rascunhar', 'respostas_para_o_agente')
     AND p.oid IS DISTINCT FROM pg_catalog.to_regprocedure('public.respostas_para_rascunhar(integer)')
     AND p.oid IS DISTINCT FROM pg_catalog.to_regprocedure('public.respostas_para_o_agente(integer)');
  IF v_mesmo_nome IS NOT NULL THEN
    RAISE EXCEPTION 'há outra função com o mesmo nome: % — confira quem chama qual antes de apagar; nada foi apagado',
      v_mesmo_nome;
  END IF;

  SELECT pg_catalog.string_agg(o.type || ' ' || o.identity, ', ' ORDER BY o.type, o.identity)
    INTO v_dependem
    FROM pg_catalog.pg_depend d
    CROSS JOIN LATERAL pg_catalog.pg_identify_object(d.classid, d.objid, d.objsubid) o
   WHERE d.refclassid = 'pg_catalog.pg_proc'::pg_catalog.regclass
     AND d.refobjid IN (pg_catalog.to_regprocedure('public.respostas_para_rascunhar(integer)'),
                        pg_catalog.to_regprocedure('public.respostas_para_o_agente(integer)'));
  IF v_dependem IS NOT NULL THEN
    RAISE EXCEPTION 'dependem delas: % — NÃO use DROP ... CASCADE, que apagaria esses objetos junto: decida o que fazer com eles antes; nada foi apagado',
      v_dependem;
  END IF;
END
$guarda$;

DROP FUNCTION public.respostas_para_rascunhar(integer);
DROP FUNCTION public.respostas_para_o_agente(integer);

INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
VALUES (
  to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDDHH24MISS'),
  'filas_antigas_sem_chamador',
  ARRAY[
    'DROP FUNCTION public.respostas_para_rascunhar(integer);',
    'DROP FUNCTION public.respostas_para_o_agente(integer);'
  ]
);

COMMIT;

-- Resultado: "funções restantes" deve dizer 0, e a linha de baixo traz o registro.
SELECT 'funções restantes' AS item,
       count(*)::text      AS valor
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('respostas_para_rascunhar', 'respostas_para_o_agente')
UNION ALL
SELECT 'registro ' || name, version
  FROM supabase_migrations.schema_migrations
 WHERE name = 'filas_antigas_sem_chamador';
