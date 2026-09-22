-- Testes de isolamento entre tenants.
--
-- Este arquivo é o que sustenta a afirmação "pode ser vendido". Ele entra na
-- pele de usuários de dois clientes diferentes e verifica que um não enxerga
-- nem escreve no outro — por RLS, por chave estrangeira composta e por
-- unicidade escopada.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA tn;
CREATE TABLE tn.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA tn TO authenticated, anon;
GRANT INSERT, SELECT ON tn.resultado TO authenticated, anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA tn TO authenticated, anon;

CREATE FUNCTION tn.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO tn.resultado (nome, ok, detalhe) VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION tn.confere(text, boolean, text) TO authenticated, anon;

-- Teste de negação que só olha "deu erro" passa pelo motivo errado — um typo no
-- nome da coluna também levanta exceção. Por isso cada bloco abaixo confere o
-- SQLSTATE: 42501 é o RLS recusando, 23503 é a chave estrangeira composta,
-- 23001 é o gatilho de coerência entre agente e campanha.

-- ---------------------------------------------------------------------------
-- Dois clientes, quatro pessoas
-- ---------------------------------------------------------------------------

\set tenantA '\'aaaaaaaa-0000-0000-0000-00000000000a\''
\set tenantB '\'bbbbbbbb-0000-0000-0000-00000000000b\''
\set donoA   '\'11111111-aaaa-0000-0000-00000000000a\''
\set leitorA '\'22222222-aaaa-0000-0000-00000000000a\''
\set operA   '\'33333333-aaaa-0000-0000-00000000000a\''
\set donoB   '\'44444444-bbbb-0000-0000-00000000000b\''

INSERT INTO tenants (id, nome, slug) VALUES
  (:tenantA, 'Corretora A', 'corretora-a'),
  (:tenantB, 'Corretora B', 'corretora-b');

INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:tenantA, :donoA,   'dono'),
  (:tenantA, :leitorA, 'leitor'),
  (:tenantA, :operA,   'operador'),
  (:tenantB, :donoB,   'dono');

-- Mesmo telefone nos dois clientes: é a mesma pessoa, mas o dado é de cada um.
INSERT INTO contacts (id, tenant_id, nome, origem) VALUES
  ('a0000000-0000-0000-0000-00000000000a', :tenantA, 'Cliente da A', 'planilha'),
  ('b0000000-0000-0000-0000-00000000000b', :tenantB, 'Cliente da B', 'planilha');

INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem) VALUES
  (:tenantA, 'a0000000-0000-0000-0000-00000000000a', 'whatsapp', '+5511999990000', '5511999990000', 'planilha'),
  (:tenantB, 'b0000000-0000-0000-0000-00000000000b', 'whatsapp', '+5511999990000', '5511999990000', 'planilha');

SELECT tn.confere('o mesmo telefone pode existir em dois clientes',
  (SELECT count(*) = 2 FROM contact_identities WHERE valor_norm = '5511999990000'));

INSERT INTO ai_credentials (tenant_id, nome, provedor, modelo, chave_secret_id)
VALUES (:tenantA, 'IA da A', 'anthropic', 'claude-opus-5', gen_random_uuid());

SELECT tn.confere('modelo do catálogo cria campanha na A',
  (SELECT campaign_id IS NOT NULL
     FROM criar_campanha_de_modelo(:tenantA, 'resgate-whatsapp', 'Campanha da A')));
SELECT tn.confere('modelo do catálogo cria campanha na B',
  (SELECT campaign_id IS NOT NULL
     FROM criar_campanha_de_modelo(:tenantB, 'resgate-whatsapp', 'Campanha da B')));

-- ---------------------------------------------------------------------------
-- Leitura: cada um vê o seu
-- ---------------------------------------------------------------------------

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"11111111-aaaa-0000-0000-00000000000a"}';

  SELECT tn.confere('dono da A vê os contatos da A',
    (SELECT count(*) = 1 FROM contacts));
  SELECT tn.confere('dono da A não vê contato da B',
    NOT EXISTS (SELECT 1 FROM contacts WHERE nome = 'Cliente da B'));
  SELECT tn.confere('dono da A vê só a campanha da A',
    (SELECT count(*) = 1 FROM campaigns));
  SELECT tn.confere('dono da A vê a identidade da A, não a da B',
    (SELECT count(*) = 1 FROM contact_identities WHERE valor_norm = '5511999990000'));
  SELECT tn.confere('dono da A enxerga a credencial de IA da A',
    (SELECT count(*) = 1 FROM ai_credentials));
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"44444444-bbbb-0000-0000-00000000000b"}';

  SELECT tn.confere('dono da B não vê nada da A',
    NOT EXISTS (SELECT 1 FROM contacts WHERE nome = 'Cliente da A'));
  SELECT tn.confere('dono da B não vê a campanha da A',
    NOT EXISTS (SELECT 1 FROM campaigns WHERE nome = 'Campanha da A'));
  SELECT tn.confere('dono da B não vê a credencial de IA da A',
    (SELECT count(*) = 0 FROM ai_credentials));
  SELECT tn.confere('dono da B não vê os remetentes da A',
    (SELECT count(*) = 0 FROM sender_accounts));
COMMIT;

BEGIN;
  SET LOCAL role anon;
  SELECT tn.confere('anônimo não vê contato nenhum', (SELECT count(*) = 0 FROM contacts));
  SELECT tn.confere('anônimo não vê campanha nenhuma', (SELECT count(*) = 0 FROM campaigns));
COMMIT;

-- ---------------------------------------------------------------------------
-- Escrita: papel decide
-- ---------------------------------------------------------------------------

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"33333333-aaaa-0000-0000-00000000000a"}';
  SAVEPOINT s;
  INSERT INTO contacts (tenant_id, nome, origem)
  VALUES ('aaaaaaaa-0000-0000-0000-00000000000a', 'Criado pelo operador', 'planilha');
  SELECT tn.confere('operador pode criar contato no tenant dele', true);
  ROLLBACK TO SAVEPOINT s;
COMMIT;

DO $$
BEGIN
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"33333333-aaaa-0000-0000-00000000000a"}', true);
  INSERT INTO contacts (tenant_id, nome, origem)
  VALUES ('bbbbbbbb-0000-0000-0000-00000000000b', 'Invasor', 'planilha');
  RESET role;
  PERFORM tn.confere('operador da A não escreve no tenant da B', false, 'foi aceito');
EXCEPTION WHEN others THEN
  RESET role;
  PERFORM tn.confere('operador da A não escreve no tenant da B (RLS, 42501)',
    SQLSTATE = '42501', SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- E a linha não ficou lá nem por engano.
SELECT tn.confere('nenhuma linha vazou para o tenant da B',
  NOT EXISTS (SELECT 1 FROM contacts WHERE nome = 'Invasor'));

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"22222222-aaaa-0000-0000-00000000000a"}';
  SELECT tn.confere('leitor lê', (SELECT count(*) >= 1 FROM contacts));
COMMIT;

DO $$
BEGIN
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"22222222-aaaa-0000-0000-00000000000a"}', true);
  INSERT INTO contacts (tenant_id, nome, origem)
  VALUES ('aaaaaaaa-0000-0000-0000-00000000000a', 'Leitor escrevendo', 'planilha');
  RESET role;
  PERFORM tn.confere('leitor não escreve', false, 'foi aceito');
EXCEPTION WHEN others THEN
  RESET role;
  PERFORM tn.confere('leitor não escreve (RLS, 42501)',
    SQLSTATE = '42501', SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  SET LOCAL role authenticated;
  PERFORM set_config('request.jwt.claims','{"sub":"33333333-aaaa-0000-0000-00000000000a"}', true);
  PERFORM count(*) FROM ai_credentials;
  IF (SELECT count(*) FROM ai_credentials) > 0 THEN
    RESET role;
    PERFORM tn.confere('operador não vê credencial de IA', false, 'viu');
  ELSE
    RESET role;
    PERFORM tn.confere('operador não vê credencial de IA', true);
  END IF;
EXCEPTION WHEN others THEN
  RESET role;
  PERFORM tn.confere('operador não vê credencial de IA', false,
    'levantou exceção em vez de devolver zero linha: ' || SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- Chave estrangeira composta: a camada que RLS não cobre
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  -- Como superusuário, RLS nem entra em cena. Quem recusa aqui é a FK.
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id)
  VALUES ('aaaaaaaa-0000-0000-0000-00000000000a',
          'a0000000-0000-0000-0000-00000000000a',
          (SELECT id FROM campaigns WHERE nome = 'Campanha da B'),
          (SELECT fv.id FROM flow_versions fv
            WHERE fv.tenant_id = 'aaaaaaaa-0000-0000-0000-00000000000a' LIMIT 1));
  PERFORM tn.confere('enrollment não aponta para campanha de outro tenant', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM tn.confere('enrollment não aponta para campanha de outro tenant (FK, 23503)',
    SQLSTATE = '23503', SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
  VALUES ('aaaaaaaa-0000-0000-0000-00000000000a',
          'b0000000-0000-0000-0000-00000000000b', 'sms', '+5511900000000', '5511900000000', 'x');
  PERFORM tn.confere('identidade não aponta para contato de outro tenant', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM tn.confere('identidade não aponta para contato de outro tenant (FK, 23503)',
    SQLSTATE = '23503', SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
DECLARE v_agente uuid;
BEGIN
  INSERT INTO agents (tenant_id, nome, canal, papel, descricao, instrucoes)
  VALUES ('bbbbbbbb-0000-0000-0000-00000000000b','Agente da B','whatsapp','x','y',
          repeat('instrução detalhada o suficiente para passar no CHECK. ', 5))
  RETURNING id INTO v_agente;

  PERFORM atribuir_agente((SELECT id FROM campaigns WHERE nome = 'Campanha da A'), v_agente);
  PERFORM tn.confere('agente de outro tenant não entra na campanha', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM tn.confere('agente de outro tenant não entra na campanha (23001)',
    SQLSTATE = '23001', SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- Supressão é do cliente, não global
-- ---------------------------------------------------------------------------

INSERT INTO suppression (tenant_id, contact_id, motivo)
VALUES ('aaaaaaaa-0000-0000-0000-00000000000a',
        'a0000000-0000-0000-0000-00000000000a', 'opt-out no cliente A');

SELECT tn.confere('opt-out na A suprime na A',
  esta_suprimido('aaaaaaaa-0000-0000-0000-00000000000a',
                 'a0000000-0000-0000-0000-00000000000a', 'whatsapp', '5511999990000'));

SELECT tn.confere('opt-out na A NÃO suprime o mesmo telefone na B',
  NOT esta_suprimido('bbbbbbbb-0000-0000-0000-00000000000b',
                     'b0000000-0000-0000-0000-00000000000b', 'whatsapp', '5511999990000'));

-- D41: a tela de supressão insere DIRETO na tabela, sem função intermediária.
-- Quem autoriza é a política de RLS, e é ela que este bloco exercita — no
-- papel de quem usa o produto, não com privilégio de manutenção.
DO $$
BEGIN
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"33333333-aaaa-0000-0000-00000000000a"}';
  INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
  VALUES ('aaaaaaaa-0000-0000-0000-00000000000a', 'email',
          'optout@exemplo.com.br', 'pediu por telefone');
  RESET role;
  PERFORM tn.confere('operador suprime um endereço pela tela', true);
EXCEPTION WHEN insufficient_privilege THEN
  RESET role;
  PERFORM tn.confere('operador suprime um endereço pela tela', false, '42501');
END;
$$;

SELECT tn.confere('e o endereço suprimido pela tela vale para quem nem é contato',
  esta_suprimido('aaaaaaaa-0000-0000-0000-00000000000a', NULL,
                 'email', 'optout@exemplo.com.br'));

DO $$
BEGIN
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"22222222-aaaa-0000-0000-00000000000a"}';
  BEGIN
    INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
    VALUES ('aaaaaaaa-0000-0000-0000-00000000000a', 'email',
            'leitor@exemplo.com.br', 'não devia passar');
    RESET role;
    PERFORM tn.confere('leitor não suprime ninguém', false, '(o INSERT passou)');
  EXCEPTION WHEN insufficient_privilege THEN
    RESET role;
    PERFORM tn.confere('leitor não suprime ninguém (42501)', true);
  END;
END;
$$;

DO $$
BEGIN
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"33333333-aaaa-0000-0000-00000000000a"}';
  BEGIN
    INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
    VALUES ('bbbbbbbb-0000-0000-0000-00000000000b', 'email',
            'vizinho@exemplo.com.br', 'no cliente errado');
    RESET role;
    PERFORM tn.confere('operador da A não suprime no cliente B', false, '(o INSERT passou)');
  EXCEPTION WHEN insufficient_privilege THEN
    RESET role;
    PERFORM tn.confere('operador da A não suprime no cliente B (42501)', true);
  END;
END;
$$;

SELECT tn.confere('inscrever na A é recusado depois do opt-out',
  inscrever('a0000000-0000-0000-0000-00000000000a',
            (SELECT id FROM campaigns WHERE nome = 'Campanha da A'),
            (SELECT fv.id FROM flow_versions fv
              WHERE fv.tenant_id = 'aaaaaaaa-0000-0000-0000-00000000000a' LIMIT 1)) IS NULL);

SELECT tn.confere('inscrever na B continua funcionando',
  inscrever('b0000000-0000-0000-0000-00000000000b',
            (SELECT id FROM campaigns WHERE nome = 'Campanha da B'),
            (SELECT fv.id FROM flow_versions fv
              WHERE fv.tenant_id = 'bbbbbbbb-0000-0000-0000-00000000000b' LIMIT 1)) IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Catálogo compartilhado
-- ---------------------------------------------------------------------------

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"44444444-bbbb-0000-0000-00000000000b"}';
  SELECT tn.confere('catálogo de modelos é visível para todo cliente',
    (SELECT count(*) >= 7 FROM campaign_templates WHERE tenant_id IS NULL));
  SELECT tn.confere('catálogo de agentes é visível para todo cliente',
    (SELECT count(*) >= 5 FROM agents WHERE tenant_id IS NULL));
  SELECT tn.confere('catálogo de provedores de IA é visível',
    (SELECT count(*) >= 7 FROM ai_provider_catalog));
COMMIT;

-- ---------------------------------------------------------------------------
-- Toda tabela de domínio tem RLS ligado
-- ---------------------------------------------------------------------------

-- Estes três meta-testes são derivados do schema, não de uma lista escrita à
-- mão. A versão anterior enumerava as tabelas, e a lista já tinha ficado para
-- trás: `provider_servers` entrou com o D24 e nunca foi adicionada — passou a
-- ter RLS por sorte, não por verificação. É o mesmo formato de falha do D31,
-- onde `tem_adapter` existia e ninguém lia.
--
-- A exceção é uma lista curta e explícita, e é isso que faz o teste servir: a
-- tabela nova nasce obrigada, e quem quiser isentá-la tem que vir aqui dizer
-- por quê. `tenants` é o próprio cliente; os dois catálogos são software, não
-- dado de cliente — iguais para todos, como o comentário deles já declara.

CREATE VIEW tn.sem_dono AS SELECT unnest(ARRAY[
  'tenants', 'channel_provider_catalog', 'ai_provider_catalog'
]) AS tabela;

CREATE VIEW tn.dominio AS
  SELECT c.oid, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r'
     AND c.relname NOT IN (SELECT tabela FROM tn.sem_dono);

SELECT tn.confere('nenhuma tabela de domínio ficou sem tenant_id',
  NOT EXISTS (
    SELECT 1 FROM tn.dominio d
     WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = d.oid AND a.attname = 'tenant_id'
                          AND NOT a.attisdropped)),
  (SELECT string_agg(d.relname, ', ') FROM tn.dominio d
    WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                       WHERE a.attrelid = d.oid AND a.attname = 'tenant_id'
                         AND NOT a.attisdropped)));

SELECT tn.confere('nenhuma tabela de public ficou sem RLS',
  NOT EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity),
  (SELECT string_agg(c.relname, ', ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r' AND NOT c.relrowsecurity));

-- A camada 2 do D18, e a única que vale contra o worker: ele roda com service
-- key e o RLS não o alcança, então é a FK composta que impede um enrollment do
-- cliente A apontar para a campanha do cliente B. Era a garantia mais citada do
-- projeto e a única sem asserção nenhuma.
SELECT tn.confere('toda FK entre tabelas de domínio carrega tenant_id',
  NOT EXISTS (
    SELECT 1 FROM pg_constraint con
      JOIN tn.dominio src ON src.oid = con.conrelid
      JOIN tn.dominio alvo ON alvo.oid = con.confrelid
     WHERE con.contype = 'f'
       AND NOT con.conkey @> (SELECT array_agg(a.attnum) FROM pg_attribute a
                               WHERE a.attrelid = con.conrelid AND a.attname = 'tenant_id')),
  (SELECT string_agg(con.conname, ', ') FROM pg_constraint con
     JOIN tn.dominio src ON src.oid = con.conrelid
     JOIN tn.dominio alvo ON alvo.oid = con.confrelid
    WHERE con.contype = 'f'
      AND NOT con.conkey @> (SELECT array_agg(a.attnum) FROM pg_attribute a
                              WHERE a.attrelid = con.conrelid AND a.attname = 'tenant_id')));

SELECT tn.confere('toda tabela com tenant_id tem índice por tenant',
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.column_name = 'tenant_id'
       AND NOT EXISTS (
         SELECT 1 FROM pg_indexes i
          WHERE i.schemaname = 'public' AND i.tablename = c.table_name
            AND i.indexdef LIKE '%tenant_id%')));

-- ---------------------------------------------------------------------------
-- Superfície exposta: o que o PostgREST publica
-- ---------------------------------------------------------------------------
--
-- Toda função em `public` vira `/rest/v1/rpc/<nome>`. As auxiliares de RLS e o
-- motor não são API — e `criar_tenant` chamável por anônimo era escrita no
-- banco sem login.

SELECT tn.confere('auxiliares de RLS não são chamáveis por anon nem authenticated',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('usuario_atual','pertence_ao_tenant','tem_papel',
                         'pode_operar','pode_administrar','tenant_atual','tenant_padrao')
       AND (has_function_privilege('anon', p.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
  (SELECT string_agg(p.proname, ', ') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('usuario_atual','pertence_ao_tenant','tem_papel',
      'pode_operar','pode_administrar','tenant_atual','tenant_padrao')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')));

SELECT tn.confere('o motor não é API: worker só por service_role',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('processar_vencidos','reivindicar_pendentes','proximos_vencidos',
                         'registrar_resultado_envio','registrar_evento_provedor',
                         'reservar_envio','registrar_falha_remetente','encerrar_enrollment')
       AND (has_function_privilege('anon', p.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))));

SELECT tn.confere('anon não chama absolutamente nada em public',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND has_function_privilege('anon', p.oid, 'EXECUTE')),
  (SELECT string_agg(p.proname, ', ') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND has_function_privilege('anon', p.oid, 'EXECUTE')));

SELECT tn.confere('criar_tenant sem dono explícito não existe mais para a API',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'criar_tenant'
       AND p.pronargs = 3
       AND has_function_privilege('authenticated', p.oid, 'EXECUTE')));

SELECT tn.confere('a forma self-service existe e é a única aberta ao usuário logado',
  (SELECT count(*) = 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'criar_tenant'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND p.pronargs = 2));

-- Sem JWT não há dono possível: a forma self-service recusa em vez de
-- inventar um.
DO $$
BEGIN
  PERFORM criar_tenant('Sem Dono', 'sem-dono');
  PERFORM tn.confere('criar_tenant sem autenticação é recusado', false, 'criou');
EXCEPTION WHEN others THEN
  PERFORM tn.confere('criar_tenant sem autenticação é recusado (42501)',
    SQLSTATE = '42501', SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- Com JWT, o tenant nasce do usuário logado e ele já é dono.
DO $$
DECLARE v_id uuid; v_papel papel_tenant;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"55555555-cccc-0000-0000-00000000000c"}', true);
  v_id := criar_tenant('Corretora C', 'corretora-c');
  SELECT papel INTO v_papel FROM tenant_users
   WHERE tenant_id = v_id AND user_id = '55555555-cccc-0000-0000-00000000000c';
  PERFORM tn.confere('quem cria o tenant nasce dono dele', v_papel = 'dono',
    coalesce(v_papel::text, 'sem vínculo'));
END;
$$;

-- O Supabase concede EXECUTE nominalmente a anon/authenticated em toda função
-- nova de `public`. Se o default privilege voltar, a próxima função vira
-- endpoint sozinha — e nenhuma asserção acima pegaria, porque elas olham as
-- funções que existem hoje.
SELECT tn.confere('função nova não nasce como endpoint',
  NOT EXISTS (
    SELECT 1 FROM pg_default_acl d
      JOIN pg_namespace n ON n.oid = d.defaclnamespace,
      unnest(d.defaclacl) AS ace
     WHERE n.nspname = 'public' AND d.defaclobjtype = 'f'
       AND (ace::text LIKE 'anon=%' OR ace::text LIKE 'authenticated=%')),
  (SELECT string_agg(ace::text, ', ') FROM pg_default_acl d
     JOIN pg_namespace n ON n.oid = d.defaclnamespace, unnest(d.defaclacl) AS ace
    WHERE n.nspname='public' AND d.defaclobjtype='f'));

SELECT tn.confere('toda função de public tem search_path fixo',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig,'{}')) c
                        WHERE c LIKE 'search_path=%')),
  (SELECT string_agg(p.proname, ', ') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public'
      AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig,'{}')) c
                       WHERE c LIKE 'search_path=%')));

\echo ''
\echo '============= ISOLAMENTO ENTRE TENANTS ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM tn.resultado ORDER BY id;
\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM tn.resultado;

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM tn.resultado WHERE NOT ok;
  IF v > 0 THEN RAISE EXCEPTION '% asserção(ões) de isolamento falharam', v; END IF;
END;
$$;
