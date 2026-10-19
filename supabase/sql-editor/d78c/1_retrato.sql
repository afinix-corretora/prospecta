-- Retrato das duas filas antigas do agente (D78c), para comparar ANTES e DEPOIS
-- e para comparar o projeto com o repositório.
--
-- Somente leitura: é um SELECT só. Não grava, não cria nada, não muda
-- configuração. Função que não existe sai como "ausente", sem erro.
--
-- Seis linhas: uma por função, uma de contexto (versão do Postgres, quem
-- está rodando, o registro da migration e quantas funções têm esses nomes), o
-- selo, as outras citações e as chamadas (as duas últimas no fim deste
-- cabeçalho).
--
-- As colunas não dependem da versão do Postgres nem do search_path, exceto
-- md5_resultado, que lê o tipo `canal` como "canal" quando `public` está no
-- search_path (está, no SQL Editor) — md5_tipos é a mesma pergunta sem essa
-- dependência — e o selo. A linha das chamadas muda com o tempo: é o que ela
-- existe para medir.
--
-- O selo é o MESMO bloco da coluna selo do 2_backup.sql (o gerador): md5 da
-- definição (pg_get_functiondef), do dono, do comentário e da grade das duas
-- funções. Rodado logo antes do DROP, tem que dar o selo que o gerador devolveu;
-- se não der, algo mudou depois do backup e o backup tem que ser gerado de novo
-- — e a guarda do 3_apagar faz essa mesma conta e recusa sozinha. Como
-- pg_get_functiondef depende do search_path e da versão, o selo só se compara
-- no mesmo banco, com as duas consultas rodadas no SQL Editor — não com o
-- retrato de outro banco.
--
-- "outras citacoes": quem ainda cita as duas filas, ou "nenhuma". Se não
-- disser "nenhuma", PARE: a guarda do 3_apagar faz as mesmas seis perguntas e
-- vai recusar. São elas: argumento de gatilho (é onde o Database Webhook do
-- Supabase guarda a URL do rpc; passo 4 da guarda); função com o MESMO nome e
-- outra assinatura ou noutro schema, e dependência registrada em pg_depend
-- (view materializada, regra, política, função BEGIN ATOMIC) — essas duas no
-- passo 6; e corpo de outra função, definição de view e comando de job do
-- pg_cron (passo 3). Nos textos — argumento, corpo, definição, comando — o
-- nome é procurado letra a letra, cada letra ela mesma ou escrita como %XX de
-- URL, sem diferença de maiúsculas, e o _ vale qualquer caractere, como no LIKE
-- que esta busca substitui: o PostgREST decodifica o caminho, e um /rpc/ com o
-- nome todo em %XX chama a mesma função. Os nomes saem qualificados pelo
-- schema, sem depender do search_path. O cron.job é achado pelo catálogo e
-- lido por texto dinâmico, como o registro da migration no contexto: sem o
-- schema cron não há o que citar, e sem permissão de ler a tabela a linha diz
-- isso em vez de dar erro (e a guarda recusa).
-- O pg_cron tem RLS em cron.job: cada papel vê só os próprios jobs (os do
-- motor são do postgres, que é quem roda isto no SQL Editor).
--
-- "chamadas": quem chamou as duas filas desde o último reset do
-- pg_stat_statements, neste banco. Formato:
--   soma=N; consultas=N; sem_permissao=N; le_outras_contas=sim|nao; desde=<stats_reset>
-- soma é a soma de calls dos textos que CHAMAM uma delas. A busca é a mesma do
-- passo 5 da guarda do 3_apagar: o nome logo depois de FROM, JOIN, LATERAL,
-- SELECT, PERFORM, vírgula ou abre-parêntese, com ou sem "public", com ou sem
-- aspas, seguido de parêntese. Pega a chamada direta e o que o PostgREST manda
-- (no POST com corpo JSON, que é o rpc do worker, o v12 e o v13 escrevem
-- ", LATERAL" antes do nome). consultas é quantos textos distintos;
-- sem_permissao, quantas linhas deste banco o papel que roda não pode ler
-- ("<insufficient privilege>"). le_outras_contas diz se ele lê o texto das
-- consultas de OUTROS papéis: superusuário ou membro de pg_read_all_stats, o
-- critério do próprio pg_stat_statements. O worker chama pelo PostgREST como
-- service_role; com le_outras_contas=nao, a chamada dele fica escondida, a
-- soma não a conta, e o N desta linha NÃO serve para o 3_apagar: ou se concede
-- pg_read_all_stats a quem roda (no Supabase, grant pg_read_all_stats to
-- postgres;) e se roda este retrato de novo, ou o 3_apagar recebe -1, sabendo
-- que as chamadas não serão conferidas.
-- O schema da extensão vem de pg_extension (no Supabase, extensions). A linha
-- começa por "sem" quando não há o que contar: "sem pg_stat_statements" (a
-- extensão não existe), "sem pg_stat_statements carregado" (existe, e a
-- biblioteca não está em shared_preload_libraries), "sem permissao ..." (quem
-- roda não pode ler) e "sem registro de chamadas: ..." (pg_stat_statements.track
-- = none ou compute_query_id = off, nesta sessão ou num ALTER DATABASE / ALTER
-- ROLE ... SET, que vale para a sessão de quem chama e não para esta). Nesses
-- casos o 3_apagar recebe -1 e não confere as chamadas; quando a linha diz
-- soma=N e le_outras_contas=sim, a guarda recusa -1.
-- O que a soma não vê: chamada feita de dentro de outra função (com
-- pg_stat_statements.track = top fica só o comando de fora; se o nome estiver
-- escrito no corpo, "outras citacoes" acusa, mas por EXECUTE com o nome
-- montado em texto ninguém vê), estatística zerada ou descartada depois da
-- leitura (a soma recomeça menor) e chamada que ainda não aconteceu.
-- Este retrato, o 2_backup, a guarda, o DROP e a restauração não casam com a
-- busca: dos dois SELECT o pg_stat_statements guarda os literais como $1,
-- $2...; a guarda, o DROP e a restauração ele guarda como vieram, e neles o nome
-- seguido de parêntese só vem depois de FUNCTION ou dentro de aspas simples.
-- Rodá-los não muda a soma.
WITH alvo(ordem, nome) AS (
  VALUES (1, 'respostas_para_rascunhar'), (2, 'respostas_para_o_agente')
),
f AS (
  SELECT a.ordem, a.nome, p.oid, p.prosrc, p.prolang, p.provolatile, p.prosecdef,
         p.proconfig, p.proowner, p.proacl, p.proisstrict, p.proleakproof,
         p.proparallel, p.procost, p.prorows, p.proretset, p.prokind, p.prosupport,
         p.prorettype, p.proargtypes, p.proallargtypes, p.proargmodes, p.proargnames
    FROM alvo a
    LEFT JOIN pg_catalog.pg_proc p
           ON p.oid = pg_catalog.to_regprocedure('public.' || a.nome || '(integer)')
),
funcoes AS (
  SELECT f.ordem,
         f.nome AS objeto,
         CASE WHEN f.oid IS NULL THEN 'ausente' ELSE 'presente' END AS estado,
         pg_catalog.pg_get_function_identity_arguments(f.oid) AS identidade,
         pg_catalog.pg_get_function_arguments(f.oid) AS argumentos,
         pg_catalog.md5(f.prosrc) AS md5_corpo,
         pg_catalog.md5(pg_catalog.pg_get_function_result(f.oid)) AS md5_resultado,
         -- Tipos de entrada e saída, cada um qualificado pelo schema: não muda
         -- com o search_path nem com a versão.
         (SELECT pg_catalog.md5(
                   pg_catalog.string_agg(
                     coalesce(m.modo, 'i') || ':' || coalesce(nm.nome, '') || ':'
                       || tn.nspname || '.' || t.typname,
                     ',' ORDER BY ti.n)
                   || '->' || rn.nspname || '.' || rt.typname
                   || CASE WHEN f.proretset THEN '[setof]' ELSE '' END)
            FROM unnest(coalesce(f.proallargtypes, f.proargtypes::oid[]))
                   WITH ORDINALITY AS ti(tipo, n)
            LEFT JOIN unnest(f.proargmodes::text[]) WITH ORDINALITY AS m(modo, n2) ON m.n2 = ti.n
            LEFT JOIN unnest(f.proargnames) WITH ORDINALITY AS nm(nome, n3) ON nm.n3 = ti.n
            JOIN pg_catalog.pg_type t       ON t.oid = ti.tipo
            JOIN pg_catalog.pg_namespace tn ON tn.oid = t.typnamespace
            CROSS JOIN pg_catalog.pg_type rt
            JOIN pg_catalog.pg_namespace rn ON rn.oid = rt.typnamespace
           WHERE f.oid IS NOT NULL AND rt.oid = f.prorettype
           GROUP BY rn.nspname, rt.typname
         ) AS md5_tipos,
         (SELECT l.lanname FROM pg_catalog.pg_language l WHERE l.oid = f.prolang) AS linguagem,
         f.provolatile::text AS volatilidade,
         f.prosecdef::text AS security_definer,
         f.proconfig::text AS config,
         pg_catalog.pg_get_userbyid(f.proowner) AS dono,
         -- A grade explodida e ordenada: "quem=privilégio/quem concedeu", com *
         -- para WITH GRANT OPTION e PUBLIC para o papel implícito. A ordem do
         -- array no catálogo não entra, só o conteúdo. ACL nula é a padrão.
         (SELECT pg_catalog.string_agg(g.item, ',' ORDER BY g.item)
            FROM (SELECT CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                              ELSE pg_catalog.pg_get_userbyid(x.grantee) END
                         || '=' || x.privilege_type
                         || CASE WHEN x.is_grantable THEN '*' ELSE '' END
                         || '/' || pg_catalog.pg_get_userbyid(x.grantor) AS item
                    FROM pg_catalog.aclexplode(
                           coalesce(f.proacl, pg_catalog.acldefault('f', f.proowner))) x
                 ) g
           WHERE f.oid IS NOT NULL
         ) AS grade0,
         CASE WHEN f.oid IS NULL THEN NULL
              ELSE coalesce(pg_catalog.md5(pg_catalog.obj_description(f.oid, 'pg_proc')), 'sem comentario')
         END AS comentario,
         CASE WHEN f.oid IS NULL THEN NULL
              ELSE pg_catalog.format('strict=%s leakproof=%s parallel=%s cost=%s rows=%s setof=%s kind=%s support=%s',
                     f.proisstrict, f.proleakproof, f.proparallel, f.procost, f.prorows,
                     f.proretset, f.prokind, f.prosupport::text)
         END AS outros
    FROM f
),
contexto AS (
  SELECT 3 AS ordem,
         'contexto'::text AS objeto,
         pg_catalog.format('PostgreSQL %s; usuario %s (superusuario: %s); registro filas_antigas_sem_chamador: %s; registros em schema_migrations: %s; funcoes com esses nomes: %s',
           pg_catalog.split_part(pg_catalog.current_setting('server_version'), ' ', 1),
           current_user,
           (SELECT r.rolsuper FROM pg_catalog.pg_roles r WHERE r.rolname = current_user),
           CASE WHEN pg_catalog.to_regclass('supabase_migrations.schema_migrations') IS NULL
                THEN 'sem tabela'
                ELSE coalesce((pg_catalog.xpath('/row/v/text()', pg_catalog.query_to_xml(
                       'SELECT pg_catalog.string_agg(version, '','' ORDER BY version) AS v
                          FROM supabase_migrations.schema_migrations
                         WHERE name = ''filas_antigas_sem_chamador''',
                       false, true, '')))[1]::text, 'nao')
           END,
           CASE WHEN pg_catalog.to_regclass('supabase_migrations.schema_migrations') IS NULL
                THEN 'sem tabela'
                ELSE (pg_catalog.xpath('/row/n/text()', pg_catalog.query_to_xml(
                       'SELECT count(*) AS n FROM supabase_migrations.schema_migrations',
                       false, true, '')))[1]::text
           END,
           (SELECT count(*) FROM pg_catalog.pg_proc p
             WHERE p.proname IN ('respostas_para_rascunhar', 'respostas_para_o_agente'))
         ) AS estado
),
-- O selo: o MESMO bloco está no 2_backup.sql (CTE selo) e no passo 2 da guarda
-- do 3_apagar. Mudou um, mudam os três.
selo AS (
  SELECT 4 AS ordem, 'selo'::text AS objeto, s.selo AS estado
    FROM (
      SELECT (SELECT pg_catalog.md5(pg_catalog.string_agg(a.nome || '|' || coalesce((
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
                FROM (VALUES (1, 'respostas_para_rascunhar'), (2, 'respostas_para_o_agente')) AS a(ordem, nome)
             ) AS selo
    ) s
),
-- O nome como ele pode aparecer escrito num texto: cada letra ela mesma ou
-- como %XX de URL, o _ qualquer caractere (como no LIKE de antes, que esta
-- busca contém), e sem diferença de maiúsculas (~*). O MESMO cálculo está no
-- passo 3 da guarda do 3_apagar: mudou um, mudam os dois.
nome_em_texto AS (
  SELECT pg_catalog.string_agg(n.padrao, '|' ORDER BY n.ordem) AS padrao
    FROM (SELECT a.ordem,
                 (SELECT pg_catalog.string_agg('(' || CASE WHEN l.letra = '_' THEN '.' ELSE l.letra END
                                                 || '|%' || pg_catalog.to_hex(pg_catalog.ascii(l.letra)) || ')',
                                               '' ORDER BY l.i)
                    FROM pg_catalog.regexp_split_to_table(a.nome, '') WITH ORDINALITY AS l(letra, i)) AS padrao
            FROM (VALUES (1, 'respostas_para_rascunhar'), (2, 'respostas_para_o_agente')) AS a(ordem, nome)) n
),
-- Outras citações: as mesmas perguntas dos passos 3, 4 e 6 da guarda do
-- 3_apagar.
citacoes AS (
  SELECT 5 AS ordem, 'outras citacoes'::text AS objeto,
         coalesce(pg_catalog.string_agg(c.quem, '; ' ORDER BY c.tipo, c.quem), 'nenhuma') AS estado
    FROM (
      -- Argumento de gatilho (passo 4).
      SELECT 1 AS tipo,
             pg_catalog.format('gatilho %I.%I / %I (argumento)', tn.nspname, tc.relname, t.tgname) AS quem
        FROM pg_catalog.pg_trigger t
        JOIN pg_catalog.pg_class tc     ON tc.oid = t.tgrelid
        JOIN pg_catalog.pg_namespace tn ON tn.oid = tc.relnamespace
        CROSS JOIN nome_em_texto u
       WHERE pg_catalog.encode(t.tgargs, 'escape') ~* u.padrao
      UNION ALL
      -- Mesmo nome, outra assinatura ou outro schema (passo 6). IS DISTINCT
      -- FROM, e não NOT IN: com uma das duas ausente, to_regprocedure dá NULL, e
      -- NOT IN com NULL na lista não devolveria linha nenhuma.
      SELECT 2,
             pg_catalog.format('funcao de mesmo nome: %I.%I(%s)', n.nspname, p.proname,
                               pg_catalog.oidvectortypes(p.proargtypes))
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
       WHERE p.proname IN ('respostas_para_rascunhar', 'respostas_para_o_agente')
         AND p.oid IS DISTINCT FROM pg_catalog.to_regprocedure('public.respostas_para_rascunhar(integer)')
         AND p.oid IS DISTINCT FROM pg_catalog.to_regprocedure('public.respostas_para_o_agente(integer)')
      UNION ALL
      -- Dependência registrada (passo 6): quem o DROP sem CASCADE recusaria.
      SELECT 3, 'depende (pg_depend): ' || o.type || ' ' || o.identity
        FROM pg_catalog.pg_depend d
        CROSS JOIN LATERAL pg_catalog.pg_identify_object(d.classid, d.objid, d.objsubid) o
       WHERE d.refclassid = 'pg_catalog.pg_proc'::pg_catalog.regclass
         AND d.refobjid IN (pg_catalog.to_regprocedure('public.respostas_para_rascunhar(integer)'),
                            pg_catalog.to_regprocedure('public.respostas_para_o_agente(integer)'))
      UNION ALL
      -- Daqui para baixo, o passo 3 da guarda: corpo de outra função...
      SELECT 4,
             pg_catalog.format('funcao %I.%I(%s) (corpo)', n.nspname, p.proname,
                               pg_catalog.oidvectortypes(p.proargtypes))
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        CROSS JOIN nome_em_texto u
       WHERE p.proname NOT IN ('respostas_para_rascunhar', 'respostas_para_o_agente')
         AND n.nspname NOT IN ('pg_catalog', 'information_schema')
         AND p.prosrc ~* u.padrao
      UNION ALL
      -- ... definição de view...
      SELECT 5, pg_catalog.format('view %I.%I', v.schemaname, v.viewname)
        FROM pg_catalog.pg_views v
        CROSS JOIN nome_em_texto u
       WHERE v.schemaname NOT IN ('pg_catalog', 'information_schema')
         AND v.definition ~* u.padrao
      UNION ALL
      -- ... e comando de job do pg_cron, por texto dinâmico. A tabela é achada
      -- pelo catálogo (to_regclass daria erro sem USAGE no schema) e a
      -- permissão é perguntada antes de ler. Os nomes dos jobs voltam em base64,
      -- para nenhum caractere de XML mudar no caminho.
      SELECT 6, j.quem
        FROM (SELECT CASE
                       WHEN NOT pg_catalog.has_schema_privilege(cn.oid, 'USAGE')
                         OR NOT pg_catalog.has_table_privilege(cc.oid, 'SELECT')
                       THEN 'cron.job sem permissao de leitura: jobs nao conferidos'
                       ELSE pg_catalog.convert_from(pg_catalog.decode(
                              (pg_catalog.xpath('/row/v/text()', pg_catalog.query_to_xml(
                                 'SELECT pg_catalog.encode(pg_catalog.convert_to(pg_catalog.string_agg(
                                           ''job '' || coalesce(jobname, jobid::text), ''; '' ORDER BY jobid),
                                           ''UTF8''), ''base64'') AS v
                                    FROM cron.job
                                   WHERE command ~* ' || pg_catalog.quote_literal(u.padrao),
                                 false, true, '')))[1]::text, 'base64'), 'UTF8')
                     END AS quem
                FROM pg_catalog.pg_class cc
                JOIN pg_catalog.pg_namespace cn ON cn.oid = cc.relnamespace
                CROSS JOIN nome_em_texto u
               WHERE cn.nspname = 'cron' AND cc.relname = 'job') j
       WHERE j.quem IS NOT NULL
    ) c
),
-- A extensão pg_stat_statements, se existir: o schema (pg_extension), se a
-- biblioteca está carregada (ela só define as variáveis dela quando entra por
-- shared_preload_libraries; sem isso, ler a view dá erro), se quem roda pode
-- ler a view e a função por trás dela, se lê o texto das consultas de outros
-- papéis e o que a impede de registrar. Tudo por oid e por catálogo: nada aqui
-- dá erro. O MESMO conjunto de perguntas está no passo 5 da guarda do 3_apagar.
pgss AS (
  SELECT n.nspname,
         pg_catalog.current_setting('pg_stat_statements.max', true) IS NOT NULL AS carregada,
         pg_catalog.has_schema_privilege(n.oid, 'USAGE')
           AND EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                        WHERE c.relnamespace = n.oid AND c.relname = 'pg_stat_statements'
                          AND pg_catalog.has_table_privilege(c.oid, 'SELECT'))
           AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                            WHERE p.pronamespace = n.oid AND p.proname = 'pg_stat_statements'
                              AND NOT pg_catalog.has_function_privilege(p.oid, 'EXECUTE'))
           AS pode_ler,
         pg_catalog.has_schema_privilege(n.oid, 'USAGE')
           AND EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                        WHERE c.relnamespace = n.oid AND c.relname = 'pg_stat_statements_info'
                          AND pg_catalog.has_table_privilege(c.oid, 'SELECT'))
           AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                            WHERE p.pronamespace = n.oid AND p.proname = 'pg_stat_statements_info'
                              AND NOT pg_catalog.has_function_privilege(p.oid, 'EXECUTE'))
           AS le_desde,
         -- Superusuário ou membro de pg_read_all_stats: é o critério com que o
         -- pg_stat_statements mostra o texto da consulta de OUTRO papel.
         pg_catalog.pg_has_role(current_user, 'pg_read_all_stats', 'USAGE') AS le_outras,
         -- O que faz o pg_stat_statements não registrar: track = none ou
         -- compute_query_id = off, nesta sessão ou guardado por ALTER DATABASE /
         -- ALTER ROLE ... SET (que vale para a sessão de quem chama, e não para
         -- esta). NULL quando nada impede.
         (SELECT pg_catalog.string_agg(m.motivo, ', ' ORDER BY m.motivo)
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
                 ) m) AS sem_registro
    FROM pg_catalog.pg_extension e
    JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'pg_stat_statements'
),
-- As chamadas, por texto dinâmico (o schema só se sabe agora). A busca é a
-- MESMA do passo 5 da guarda do 3_apagar: mudou uma, muda a outra.
chamadas AS (
  SELECT 6 AS ordem, 'chamadas'::text AS objeto,
         CASE
           WHEN x.nspname IS NULL THEN 'sem pg_stat_statements'
           WHEN NOT x.carregada THEN pg_catalog.format(
             'sem pg_stat_statements carregado: a extensao esta em %s, mas a biblioteca nao esta em shared_preload_libraries',
             x.nspname)
           WHEN NOT x.pode_ler THEN pg_catalog.format(
             'sem permissao de leitura em %s.pg_stat_statements para %s', x.nspname, current_user)
           WHEN x.sem_registro IS NOT NULL THEN pg_catalog.format(
             'sem registro de chamadas: %s', x.sem_registro)
           ELSE (pg_catalog.xpath('/row/v/text()', pg_catalog.query_to_xml(
                  'SELECT pg_catalog.format(''soma=%s; consultas=%s; sem_permissao=%s; le_outras_contas=%s; desde=%s'',
                            coalesce(pg_catalog.sum(s.calls) FILTER (WHERE s.chama), 0),
                            pg_catalog.count(DISTINCT s.query) FILTER (WHERE s.chama),
                            pg_catalog.count(*) FILTER (WHERE s.query = ''<insufficient privilege>''),
                            ' || CASE WHEN x.le_outras THEN '''sim''' ELSE '''nao''' END || ',
                            ' || CASE WHEN x.le_desde
                                      THEN '(SELECT i.stats_reset::text FROM '
                                           || pg_catalog.quote_ident(x.nspname) || '.pg_stat_statements_info i)'
                                      ELSE '''desconhecido''' END || ') AS v
                     FROM (SELECT s.calls, s.query,
                                  s.query ~* '
                    || pg_catalog.quote_literal('(from|select|,|\(|lateral|join|perform)\s*("?public"?\s*\.\s*)?"?respostas_para_(rascunhar|o_agente)"?\s*\(')
                    || ' AS chama
                             FROM ' || pg_catalog.quote_ident(x.nspname) || '.pg_stat_statements s
                            WHERE s.dbid = (SELECT d.oid FROM pg_catalog.pg_database d
                                             WHERE d.datname = pg_catalog.current_database())) s',
                  false, true, '')))[1]::text
         END AS estado
    FROM (SELECT 1) um
    LEFT JOIN pgss x ON true
)
SELECT objeto, estado, identidade, argumentos, md5_corpo, md5_resultado, md5_tipos,
       linguagem, volatilidade, security_definer, config, dono, grade, comentario, outros
  FROM (SELECT ordem, objeto, estado, identidade, argumentos, md5_corpo, md5_resultado,
               md5_tipos, linguagem, volatilidade, security_definer, config, dono,
               CASE WHEN estado = 'presente' THEN coalesce(grade0, '(vazia)') END AS grade,
               comentario, outros
          FROM funcoes
        UNION ALL
        SELECT ordem, objeto, estado, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL
          FROM contexto
        UNION ALL
        SELECT ordem, objeto, estado, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL
          FROM selo
        UNION ALL
        SELECT ordem, objeto, estado, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL
          FROM citacoes
        UNION ALL
        SELECT ordem, objeto, estado, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
               NULL, NULL, NULL, NULL, NULL
          FROM chamadas) r
 ORDER BY ordem;
