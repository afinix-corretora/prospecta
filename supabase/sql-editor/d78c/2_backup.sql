-- Gera, a partir do banco VIVO, o script que devolve as duas filas antigas do
-- agente (D78c) exatamente como estão agora: definição, dono, comentário e a
-- grade de privilégios — e apaga o registro que o script do DROP grava em
-- supabase_migrations.schema_migrations.
--
-- O que isto guarda é o que o DROP do D78c muda, e só isso: as duas funções
-- (que só leem) e a linha de registro. O DROP não toca em dado nenhum. Não é
-- backup do banco inteiro — e o Restore do painel NÃO serve para desfazer o
-- DROP: ele volta o banco INTEIRO para a hora do backup e apaga tudo o que foi
-- gravado depois. Quem desfaz o DROP é o script que este SELECT devolve.
--
-- Somente leitura: é um SELECT só. Não grava, não cria nada, não muda
-- configuração. Se as duas funções não existirem, diz isso e não gera script.
--
-- Uma linha, seis colunas:
--   situacao       o que foi guardado (ou por que nada foi)
--   script         o script de restauração, inteiro, numa célula só.
--                  No SQL Editor: botão direito na célula ▸ "Copy cell content"
--                  (copia o texto exato; "View cell content" também mostra).
--   md5_script     md5 do texto da coluna script, para conferir a cópia
--   bytes          tamanho do script em bytes (UTF-8)
--   script_base64  o MESMO script em base64, numa linha só, sem aspas nem
--                  vírgulas: sobrevive a qualquer forma de cópia (CSV, JSON,
--                  Markdown). `base64 -d` devolve o texto, e o md5 confere.
--   selo           md5 da definição, do dono, do comentário e da grade das duas
--                  funções AGORA. O 1_retrato.sql devolve o mesmo selo (linha
--                  "selo"): rodado logo antes do DROP, ele tem que dar este
--                  valor. Se não der, algo mudou depois do backup, e o backup
--                  tem que ser gerado de novo. Usa pg_get_functiondef, que
--                  depende do search_path e da versão: só se compara no mesmo
--                  banco, as duas consultas rodadas no SQL Editor.
WITH alvo(ordem, nome) AS (
  VALUES (1, 'respostas_para_rascunhar'), (2, 'respostas_para_o_agente')
),
f AS (
  SELECT a.ordem, a.nome, p.oid, p.proowner, p.proacl, p.prosrc,
         CASE WHEN p.oid IS NOT NULL
              THEN pg_catalog.format('%I.%I(%s)', n.nspname, p.proname,
                                     pg_catalog.oidvectortypes(p.proargtypes))
         END AS assinatura
    FROM alvo a
    LEFT JOIN pg_catalog.pg_proc p
           ON p.oid = pg_catalog.to_regprocedure('public.' || a.nome || '(integer)')
    LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
),
-- A grade como está, explodida na ordem do catálogo. ACL nula é a padrão
-- (EXECUTE para PUBLIC e para o dono), e é isso que ela significa.
g AS (
  SELECT f.ordem, x.n, x.grantor, x.grantee, x.privilege_type, x.is_grantable,
         CASE WHEN x.grantee = 0 THEN 'PUBLIC'
              ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(x.grantee)) END AS para,
         CASE WHEN x.grantee = 0 THEN 'PUBLIC'
              ELSE pg_catalog.pg_get_userbyid(x.grantee) END
           || '=' || x.privilege_type
           || CASE WHEN x.is_grantable THEN '*' ELSE '' END
           || '/' || pg_catalog.pg_get_userbyid(x.grantor) AS item
    FROM f
    CROSS JOIN LATERAL pg_catalog.aclexplode(
                 coalesce(f.proacl, pg_catalog.acldefault('f', f.proowner)))
               WITH ORDINALITY AS x(grantor, grantee, privilege_type, is_grantable, n)
   WHERE f.oid IS NOT NULL
),
fn AS (
  SELECT f.ordem, f.nome, f.oid, f.assinatura,
         pg_catalog.pg_get_userbyid(f.proowner) AS dono,
         pg_catalog.pg_get_functiondef(f.oid) AS definicao,
         pg_catalog.md5(f.prosrc) AS md5_corpo,
         pg_catalog.md5(pg_catalog.pg_get_functiondef(f.oid)) AS md5_def,
         pg_catalog.obj_description(f.oid, 'pg_proc') AS comentario,
         pg_catalog.md5(pg_catalog.obj_description(f.oid, 'pg_proc')) AS md5_comentario,
         (SELECT pg_catalog.string_agg(g.item, ',' ORDER BY g.item)
            FROM g WHERE g.ordem = f.ordem) AS grade,
         -- A grade que a restauração consegue devolver: os GRANT do passo 3 saem
         -- de quem restaura (o dono), então cada item volta concedido pelo dono,
         -- e duas concessões ao mesmo papel viram uma (com a opção, se uma tinha).
         -- Sem concessão alheia, é igual à grade.
         (SELECT pg_catalog.string_agg(r.item, ',' ORDER BY r.item)
            FROM (SELECT CASE WHEN g.grantee = 0 THEN 'PUBLIC'
                              ELSE pg_catalog.pg_get_userbyid(g.grantee) END
                         || '=' || g.privilege_type
                         || CASE WHEN pg_catalog.bool_or(g.is_grantable) THEN '*' ELSE '' END
                         || '/' || pg_catalog.pg_get_userbyid(f.proowner) AS item
                    FROM g WHERE g.ordem = f.ordem
                   GROUP BY g.grantee, g.privilege_type) r) AS grade_restaurada,
         (SELECT pg_catalog.string_agg(
                   pg_catalog.format('GRANT %s ON FUNCTION %s TO %s%s;',
                     g.privilege_type, f.assinatura, g.para,
                     CASE WHEN g.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END),
                   E'\n' ORDER BY g.n)
            FROM g WHERE g.ordem = f.ordem) AS concessoes,
         EXISTS (SELECT 1 FROM g WHERE g.ordem = f.ordem AND g.grantor <> f.proowner)
           AS concessor_alheio
    FROM f
   WHERE f.oid IS NOT NULL
),
-- O registro: o que já tinha o nome da migration ANTES do DROP fica; o que o
-- script do DROP gravar depois, sai. Lido por texto dinâmico (query_to_xml)
-- para não dar erro onde a tabela não existe.
reg AS (
  SELECT t.tem_tabela,
         CASE WHEN t.tem_tabela THEN
           (pg_catalog.xpath('/row/v/text()', pg_catalog.query_to_xml(
              'SELECT pg_catalog.string_agg(pg_catalog.quote_literal(version), '', '' ORDER BY version) AS v
                 FROM supabase_migrations.schema_migrations
                WHERE name = ''filas_antigas_sem_chamador'' AND version ~ ''^[0-9]+$''',
              false, true, '')))[1]::text
         END AS versoes_antes,
         CASE WHEN t.tem_tabela THEN
           (pg_catalog.xpath('/row/n/text()', pg_catalog.query_to_xml(
              'SELECT count(*) AS n FROM supabase_migrations.schema_migrations
                WHERE name = ''filas_antigas_sem_chamador''',
              false, true, '')))[1]::text::integer
         ELSE 0 END AS quantos_antes,
         CASE WHEN t.tem_tabela THEN
           (pg_catalog.xpath('/row/n/text()', pg_catalog.query_to_xml(
              'SELECT count(*) AS n FROM supabase_migrations.schema_migrations
                WHERE name = ''filas_antigas_sem_chamador'' AND version !~ ''^[0-9]+$''',
              false, true, '')))[1]::text::integer
         ELSE 0 END AS versoes_estranhas
    FROM (SELECT pg_catalog.to_regclass('supabase_migrations.schema_migrations') IS NOT NULL
                 AS tem_tabela) t
),
-- O selo: o MESMO bloco está no 1_retrato.sql (linha "selo") e no passo 2 da
-- guarda do 3_apagar. Mudou um, mudam os três.
selo AS (
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
),
partes AS (
  SELECT reg.*, selo.selo,
         (SELECT count(*) FROM fn) AS guardadas,
         (SELECT pg_catalog.string_agg(f.nome, ', ' ORDER BY f.ordem) FROM f WHERE f.oid IS NULL)
           AS ausentes,
         coalesce((SELECT bool_or(fn.concessor_alheio) FROM fn), false) AS concessor_alheio,
         (SELECT pg_catalog.string_agg(fn.assinatura, ', ' ORDER BY fn.ordem) FROM fn)
           AS assinaturas,
         (SELECT pg_catalog.string_agg(pg_catalog.quote_literal(fn.assinatura), ', ' ORDER BY fn.ordem) FROM fn)
           AS assinaturas_lit,
         -- Uma por linha no cabeçalho: as duas numa linha só, separadas por
         -- vírgula, passariam por chamada na busca da linha chamadas do
         -- 1_retrato.sql e do passo 5 do 3_apagar.
         (SELECT pg_catalog.string_agg('--   ' || fn.assinatura, E'\n' ORDER BY fn.ordem) FROM fn)
           AS assinaturas_linhas,
         (SELECT pg_catalog.string_agg(fn.definicao || E';\n', E'\n' ORDER BY fn.ordem) FROM fn)
           AS definicoes,
         (SELECT pg_catalog.string_agg(
                   pg_catalog.format(E'ALTER FUNCTION %s OWNER TO %I;\nCOMMENT ON FUNCTION %s IS %s;\n',
                     fn.assinatura, fn.dono, fn.assinatura,
                     coalesce(pg_catalog.quote_literal(fn.comentario), 'NULL')),
                   '' ORDER BY fn.ordem) FROM fn)
           AS donos,
         (SELECT pg_catalog.string_agg(fn.concessoes || E'\n', '' ORDER BY fn.ordem) FROM fn)
           AS concessoes,
         (SELECT pg_catalog.string_agg(
                   pg_catalog.format('          (%L, %L, %L, %L, %L, %s, %L)',
                     fn.nome, fn.assinatura, fn.md5_corpo, fn.md5_def, fn.dono,
                     coalesce(pg_catalog.quote_literal(fn.comentario), 'NULL::text'), fn.grade),
                   E',\n' ORDER BY fn.ordem) FROM fn)
           AS valores,
         -- Para o passo 5, que mora dentro de um bloco $...$: só md5 (hexadecimal),
         -- base64 e as assinaturas, que não têm "$". Nome de papel, comentário e
         -- search_path vão em base64, para nenhum texto fechar o bloco.
         (SELECT pg_catalog.string_agg(
                   pg_catalog.format('      (%L, %L, %L, %L, %s::text, %s::text)',
                     fn.assinatura, fn.md5_corpo, fn.md5_def,
                     pg_catalog.translate(pg_catalog.encode(pg_catalog.convert_to(fn.dono, 'UTF8'), 'base64'), E'\n', ''),
                     coalesce(pg_catalog.quote_literal(fn.md5_comentario), 'NULL'),
                     coalesce(pg_catalog.quote_literal(pg_catalog.translate(pg_catalog.encode(
                       pg_catalog.convert_to(fn.grade_restaurada, 'UTF8'), 'base64'), E'\n', '')), 'NULL')),
                   E',\n' ORDER BY fn.ordem) FROM fn)
           AS guarda_valores,
         pg_catalog.translate(pg_catalog.encode(pg_catalog.convert_to(
           pg_catalog.current_setting('search_path'), 'UTF8'), 'base64'), E'\n', '') AS caminho_b64
    FROM reg, selo
),
s AS (
  SELECT p.*,
         CASE WHEN p.guardadas = 0 THEN NULL ELSE pg_catalog.array_to_string(ARRAY[
-- ------------------------------------------------------------- cabeçalho
pg_catalog.format($t$-- Restauração das filas antigas do agente (D78c), gerada do banco vivo.
-- Gerada em %s UTC no banco %s (PostgreSQL %s) por %s.
-- Guarda:
%s
-- Selo do que foi guardado: %s
$t$,
  pg_catalog.to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
  pg_catalog.quote_ident(current_database()),
  pg_catalog.split_part(pg_catalog.current_setting('server_version'), ' ', 1),
  pg_catalog.quote_ident(current_user),
  p.assinaturas_linhas, p.selo),
CASE WHEN p.ausentes IS NOT NULL
     THEN pg_catalog.format(E'-- NÃO guarda (já estava ausente quando foi gerado): %s.\n', p.ausentes)
END,
$t$--
-- O QUE ISTO É: a cópia exata do que o DROP do D78c apaga — as duas funções,
-- com definição, dono, comentário e grade — e a remoção da linha que ele grava
-- em supabase_migrations.schema_migrations. O DROP não toca em dado nenhum, e
-- isto também não. NUNCA desfaça o DROP pelo Restore do painel (Database ▸
-- Backups): ele volta o banco INTEIRO para a hora do backup e apaga tudo o que
-- foi gravado depois (mensagens, eventos, respostas).
--
-- ANTES DE COLAR: o md5 desta cópia tem que ser o md5_script que o gerador
-- devolveu. Se ela chegar alterada mesmo assim, o passo 5 confere corpo,
-- definição, dono, comentário, grade e registro ANTES do COMMIT e desfaz tudo.
--
-- A FUNÇÃO VOLTA COMO ERA, mesmo que não rode mais no schema de hoje: o corpo
-- não é conferido ao recriar (check_function_bodies desligado, como no
-- pg_dump). Os corpos citam tabelas, colunas e funções que o pg_depend não liga
-- a eles: uma migration depois do DROP que mexa numa delas passa sem erro, e a
-- função restaurada falha quando for chamada. A coluna roda_hoje da conferência
-- diz se ela roda; se não rodar, quem decide é uma pessoa. Na prática: se for
-- preciso desfazer, desfaça antes da próxima migration que mexer no que os
-- corpos citam.
--
-- VOLTAR O WORKER: o motor-worker v7 (D69) chama respostas_para_o_agente.
-- Depois do DROP, voltar a ele exige rodar este script ANTES de publicar: sem
-- ele, cada passada responde 500 e o agente para.
--
-- Roda inteiro numa transação: se qualquer passo falhar, nada muda.
-- Pode rodar de novo sem estrago: recria igual e acerta a grade de novo.
-- A última consulta mostra cada item contra o que foi guardado.

BEGIN;

-- Os tipos do RETURNS TABLE (o `canal`) se resolvem em public.
SET LOCAL search_path TO pg_catalog, public;

-- Recria como era, sem conferir o corpo contra o schema de agora (o passo 2b
-- confere e só informa).
SET LOCAL check_function_bodies = off;

-- 0. Só importa se a função AINDA existe (o script rodando de novo): o
-- CREATE OR REPLACE passa pelo validador, que exige EXECUTE de quem roda
-- mesmo com check_function_bodies desligado. Se a grade guardada tirou isso do
-- dono, concede aqui; o passo 3 refaz a grade inteira depois.
$t$,
pg_catalog.format($t$DO $libera_validador$
DECLARE
  v_funcao text;
BEGIN
  FOREACH v_funcao IN ARRAY ARRAY[%s] LOOP
    IF pg_catalog.to_regprocedure(v_funcao) IS NOT NULL
       AND NOT pg_catalog.has_function_privilege(v_funcao, 'EXECUTE') THEN
      EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION %%s TO %%I', v_funcao, current_user);
    END IF;
  END LOOP;
END
$libera_validador$;

-- 1. As definições, como pg_get_functiondef as devolveu.

$t$, p.assinaturas_lit),
p.definicoes,
$t$
-- 2. Dono e comentário.
$t$,
p.donos,
-- ------------------------------------------------------------- roda hoje?
pg_catalog.format($t$
-- 2b. O corpo roda no schema de hoje? Chama o validador da linguagem com
-- check_function_bodies ligado e com o SET da própria função, como o CREATE
-- faria, e guarda a resposta para a coluna roda_hoje da conferência. Só
-- informa: não muda nada e não impede o COMMIT.
DO $roda_hoje$
DECLARE
  v_funcao    text;
  v_oid       oid;
  v_nome      text;
  v_validador text;
  v_config    text[];
  v_item      text;
  v_resultado text;
BEGIN
  FOREACH v_funcao IN ARRAY ARRAY[%s] LOOP
    v_oid := pg_catalog.to_regprocedure(v_funcao);
    SELECT p.proname, p.proconfig, pg_catalog.format('%%I.%%I', vn.nspname, v.proname)
      INTO v_nome, v_config, v_validador
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_language l ON l.oid = p.prolang
      LEFT JOIN pg_catalog.pg_proc v ON v.oid = l.lanvalidator
      LEFT JOIN pg_catalog.pg_namespace vn ON vn.oid = v.pronamespace
     WHERE p.oid = v_oid;
    -- O validador exige EXECUTE de quem chama; o passo 3 refaz a grade depois.
    IF NOT pg_catalog.has_function_privilege(v_oid, 'EXECUTE') THEN
      EXECUTE pg_catalog.format('GRANT EXECUTE ON FUNCTION %%s TO %%I', v_funcao, current_user);
    END IF;
    BEGIN
      PERFORM pg_catalog.set_config('check_function_bodies', 'on', true);
      FOREACH v_item IN ARRAY coalesce(v_config, ARRAY[]::text[]) LOOP
        PERFORM pg_catalog.set_config(pg_catalog.split_part(v_item, '=', 1),
                                      pg_catalog.substr(v_item, pg_catalog.strpos(v_item, '=') + 1), true);
      END LOOP;
      IF v_validador IS NOT NULL THEN
        EXECUTE pg_catalog.format('SELECT %%s($1)', v_validador) USING v_oid;
      END IF;
      -- Erro de propósito: desfaz os SET acima junto com o bloco.
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'roda_hoje: ok';
    EXCEPTION WHEN OTHERS THEN
      v_resultado := CASE
        WHEN SQLSTATE = 'P0001' AND SQLERRM = 'roda_hoje: ok' AND v_validador IS NULL
          THEN 'não conferido: a linguagem não tem validador'
        WHEN SQLSTATE = 'P0001' AND SQLERRM = 'roda_hoje: ok' THEN 'confere'
        WHEN SQLSTATE = '42501' THEN 'não conferido: ' || SQLERRM
        ELSE 'NÃO RODA no schema de hoje: ' || SQLERRM END;
    END;
    PERFORM pg_catalog.set_config('restauracao_d78c.roda_' || v_nome, v_resultado, false);
  END LOOP;
END
$roda_hoje$;
$t$, p.assinaturas_lit),
-- ------------------------------------------------------------- grade
pg_catalog.format($t$
-- 3. A grade. Função criada agora nasce com EXECUTE para PUBLIC e com o que os
-- default privileges de quem cria concederem (no Supabase: anon, authenticated,
-- service_role). Em vez de adivinhar quais, tira TUDO o que a função tem neste
-- momento — de PUBLIC, de cada papel e do próprio dono — e concede de volta
-- exatamente a grade guardada, na ordem guardada.
DO $restaura_grade$
DECLARE
  v_funcao text;
  v_papel  oid;
BEGIN
  FOREACH v_funcao IN ARRAY ARRAY[%s] LOOP
    FOR v_papel IN
      SELECT DISTINCT x.grantee
        FROM pg_catalog.pg_proc p,
             pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
       WHERE p.oid = v_funcao::regprocedure
    LOOP
      EXECUTE pg_catalog.format('REVOKE ALL ON FUNCTION %%s FROM %%s CASCADE', v_funcao,
        CASE WHEN v_papel = 0 THEN 'PUBLIC'
             ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(v_papel)) END);
    END LOOP;
  END LOOP;
END
$restaura_grade$;

$t$, p.assinaturas_lit),
p.concessoes,
CASE WHEN p.concessor_alheio THEN
$t$-- ATENÇÃO: a grade guardada tem concessão feita por quem não é o dono. Aqui
-- ela é concedida pelo dono; a conferência no fim vai dizer DIFERE.
$t$
END,
-- ------------------------------------------------------------- registro
$t$
-- 4. O registro que o script do DROP gravou.
$t$,
CASE
  WHEN NOT p.tem_tabela THEN
    E'-- (supabase_migrations.schema_migrations não existia quando isto foi gerado.)\n'
  WHEN p.versoes_antes IS NULL THEN
$t$DELETE FROM supabase_migrations.schema_migrations
 WHERE name = 'filas_antigas_sem_chamador';
$t$
  ELSE pg_catalog.format($t$-- Estas versões já tinham esse nome ANTES do DROP, e ficam.
DELETE FROM supabase_migrations.schema_migrations
 WHERE name = 'filas_antigas_sem_chamador'
   AND version NOT IN (%s);
$t$, p.versoes_antes)
END,
-- ------------------------------------------------------------- confere antes do COMMIT
pg_catalog.format($t$
-- 5. Confere ANTES do COMMIT: corpo, definição (no search_path de quem gerou),
-- dono, comentário, a grade que a restauração consegue devolver e o registro.
-- Qualquer diferença desfaz a transação inteira — uma cópia alterada no
-- caminho não chega a ser gravada.
DO $confere_antes_do_commit$
DECLARE
  o        record;
  v_oid    oid;
  v_achado text;
  v_espera text;
  v_erros  text[] := ARRAY[]::text[];
  v_n      bigint;
  v_nome   text;
BEGIN
  FOR o IN SELECT * FROM (VALUES
%s
       ) AS t(assinatura, md5_corpo, md5_def, dono_b64, md5_comentario, grade_b64)
  LOOP
    v_oid := pg_catalog.to_regprocedure(o.assinatura);
    IF v_oid IS NULL THEN
      v_erros := v_erros || (o.assinatura || ': ausente');
      CONTINUE;
    END IF;
    SELECT pg_catalog.md5(p.prosrc), p.proname INTO v_achado, v_nome FROM pg_catalog.pg_proc p WHERE p.oid = v_oid;
    IF v_achado IS DISTINCT FROM o.md5_corpo THEN
      v_erros := v_erros || pg_catalog.format('%%s: corpo (md5 %%s, guardado %%s)', o.assinatura, v_achado, o.md5_corpo);
    END IF;
    PERFORM pg_catalog.set_config('search_path',
      pg_catalog.convert_from(pg_catalog.decode(%L, 'base64'), 'UTF8'), true);
    v_achado := pg_catalog.md5(pg_catalog.pg_get_functiondef(v_oid));
    PERFORM pg_catalog.set_config('search_path', 'pg_catalog, public', true);
    -- A conferência depois do COMMIT mostra este md5, e não um recalculado no
    -- search_path de quem restaura, que pode qualificar os tipos de outro jeito.
    PERFORM pg_catalog.set_config('restauracao_d78c.def_' || v_nome, v_achado, false);
    IF v_achado IS DISTINCT FROM o.md5_def THEN
      v_erros := v_erros || pg_catalog.format('%%s: definição (md5 %%s, guardado %%s)', o.assinatura, v_achado, o.md5_def);
    END IF;
    SELECT pg_catalog.pg_get_userbyid(p.proowner) INTO v_achado FROM pg_catalog.pg_proc p WHERE p.oid = v_oid;
    v_espera := pg_catalog.convert_from(pg_catalog.decode(o.dono_b64, 'base64'), 'UTF8');
    IF v_achado IS DISTINCT FROM v_espera THEN
      v_erros := v_erros || pg_catalog.format('%%s: dono (%%s, guardado %%s)', o.assinatura, v_achado, v_espera);
    END IF;
    v_achado := pg_catalog.md5(pg_catalog.obj_description(v_oid, 'pg_proc'));
    IF v_achado IS DISTINCT FROM o.md5_comentario THEN
      v_erros := v_erros || pg_catalog.format('%%s: comentário', o.assinatura);
    END IF;
    SELECT pg_catalog.string_agg(i.item, ',' ORDER BY i.item) INTO v_achado
      FROM (SELECT CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                        ELSE pg_catalog.pg_get_userbyid(x.grantee) END
                   || '=' || x.privilege_type
                   || CASE WHEN x.is_grantable THEN '*' ELSE '' END
                   || '/' || pg_catalog.pg_get_userbyid(x.grantor) AS item
              FROM pg_catalog.pg_proc p,
                   pg_catalog.aclexplode(coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
             WHERE p.oid = v_oid) i;
    v_espera := pg_catalog.convert_from(pg_catalog.decode(o.grade_b64, 'base64'), 'UTF8');
    IF v_achado IS DISTINCT FROM v_espera THEN
      v_erros := v_erros || pg_catalog.format('%%s: grade (%%s, esperada %%s)', o.assinatura,
                                              coalesce(v_achado, '(vazia)'), coalesce(v_espera, '(vazia)'));
    END IF;
  END LOOP;
$t$, p.guarda_valores, p.caminho_b64),
CASE WHEN p.tem_tabela THEN pg_catalog.format($t$  SELECT pg_catalog.count(*) INTO v_n
    FROM supabase_migrations.schema_migrations
   WHERE name = 'filas_antigas_sem_chamador';
  IF v_n <> %1$s THEN
    v_erros := v_erros || pg_catalog.format('registro filas_antigas_sem_chamador: %%s linha(s), esperado %%s', v_n, %1$s);
  END IF;
$t$, p.quantos_antes)
END,
$t$  IF pg_catalog.cardinality(v_erros) > 0 THEN
    RAISE EXCEPTION 'a restauração não confere com o que foi guardado, e NADA foi gravado: %',
      pg_catalog.array_to_string(v_erros, '; ');
  END IF;
END
$confere_antes_do_commit$;
$t$,
-- ------------------------------------------------------------- conferência
$t$
COMMIT;

-- Conferência: cada coluna deve dizer "confere". A definição é a do passo 5
-- (md5 de pg_get_functiondef no search_path de quem gerou); roda_hoje diz se o
-- corpo passa no validador contra o schema de hoje (passo 2b).
SELECT o.funcao,
       CASE WHEN p.oid IS NULL THEN 'AUSENTE' ELSE 'presente' END AS estado,
       CASE WHEN pg_catalog.md5(p.prosrc) = o.md5_corpo THEN 'confere' ELSE 'DIFERE' END AS corpo,
       CASE WHEN pg_catalog.current_setting('restauracao_d78c.def_' || o.funcao, true) = o.md5_def
            THEN 'confere' ELSE 'DIFERE' END AS definicao,
       CASE WHEN pg_catalog.pg_get_userbyid(p.proowner) = o.dono THEN 'confere' ELSE 'DIFERE' END AS dono,
       CASE WHEN pg_catalog.obj_description(p.oid, 'pg_proc') IS NOT DISTINCT FROM o.comentario
            THEN 'confere' ELSE 'DIFERE' END AS comentario,
       CASE WHEN g.grade IS NOT DISTINCT FROM o.grade THEN 'confere'
            ELSE 'DIFERE: ' || coalesce(g.grade, '(vazia)') END AS grade,
       coalesce(pg_catalog.current_setting('restauracao_d78c.roda_' || o.funcao, true),
                'não conferido') AS roda_hoje
  FROM (VALUES
$t$,
p.valores,
$t$
       ) AS o(funcao, assinatura, md5_corpo, md5_def, dono, comentario, grade)
  LEFT JOIN pg_catalog.pg_proc p ON p.oid = pg_catalog.to_regprocedure(o.assinatura)
  LEFT JOIN LATERAL (
       SELECT pg_catalog.string_agg(i.item, ',' ORDER BY i.item) AS grade
         FROM (SELECT CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                           ELSE pg_catalog.pg_get_userbyid(x.grantee) END
                      || '=' || x.privilege_type
                      || CASE WHEN x.is_grantable THEN '*' ELSE '' END
                      || '/' || pg_catalog.pg_get_userbyid(x.grantor) AS item
                 FROM pg_catalog.aclexplode(
                        coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))) x
              ) i
       ) g ON true
$t$,
CASE WHEN p.tem_tabela THEN pg_catalog.format($t$UNION ALL
SELECT 'registro filas_antigas_sem_chamador',
       pg_catalog.count(*)::text || ' linha(s)',
       CASE WHEN pg_catalog.count(*) = %1$s THEN 'confere' ELSE 'DIFERE: esperado %1$s' END,
       NULL, NULL, NULL, NULL, NULL
  FROM supabase_migrations.schema_migrations
 WHERE name = 'filas_antigas_sem_chamador'
$t$, p.quantos_antes)
END,
E';\n'
         ], '') END AS script
    FROM partes p
)
SELECT CASE
         WHEN s.guardadas = 0 THEN
           'nada a guardar: as duas funções já estão ausentes (respostas_para_rascunhar e respostas_para_o_agente); nenhum script foi gerado'
         ELSE pg_catalog.concat(
           'guardadas ', s.guardadas, ' de 2: ', s.assinaturas,
           CASE WHEN s.ausentes IS NOT NULL THEN '; AUSENTE e não guardada: ' || s.ausentes END,
           CASE WHEN s.concessor_alheio THEN '; ATENÇÃO: há concessão feita por quem não é o dono' END,
           CASE WHEN s.versoes_estranhas > 0
                THEN '; ATENÇÃO: registro com versão não numérica, o DELETE gerado também o apaga' END)
       END AS situacao,
       s.script,
       pg_catalog.md5(s.script) AS md5_script,
       pg_catalog.octet_length(s.script) AS bytes,
       pg_catalog.translate(pg_catalog.encode(pg_catalog.convert_to(s.script, 'UTF8'), 'base64'), E'\n', '')
         AS script_base64,
       s.selo
  FROM s;
