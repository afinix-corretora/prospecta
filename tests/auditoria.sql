-- O que a auditoria achou (D77).
--
-- O que este arquivo existe para pegar:
--
--   1. a chave guardada vale para UM destino: trocar o provedor, o endereço, o
--      domínio ou o data center e mandar a chave em branco é recusado — nas
--      credenciais de IA e de CRM, no servidor de instância e no chip — e
--      trocar uma das chaves pede as outras junto. O endereço igual, escrito
--      com barra no fim ou outra caixa, continua sendo o mesmo;
--   2. editar sem reenviar os campos que não são segredo não os apaga;
--   3. `conectar_conta` é uma transação só: credencial recusada não deixa
--      conta para trás, ativa e sem segredo, no pool;
--   4. a busca de contatos acha por nome, por endereço e pelo número do jeito
--      que se digita, trata `%` e `_` como texto e não sai do cliente;
--   5. TRUNCATE não é de ninguém da tela.
--
-- Sem Vault no Postgres de teste (D59): o caminho que GRAVA chave nova para na
-- borda com `feature_not_supported`, e é essa parada que distingue "a função
-- recusou" (22023, antes do Vault) de "a função aceitou e foi guardar" (0A000).
-- Para o chip, que guarda o objeto inteiro no Vault e LÊ o anterior, um Vault
-- de mentira entra no fim, com o que importa do de verdade.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA au;
CREATE TABLE au.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA au TO authenticated, anon;
GRANT INSERT, SELECT ON au.resultado TO authenticated, anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA au TO authenticated, anon;
CREATE FUNCTION au.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO au.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION au.confere(text, boolean, text) TO authenticated, anon;

-- Roda o SQL como quem administra o cliente A e devolve "ok" ou SQLSTATE: mensagem.
CREATE FUNCTION au.como_dono(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"a7000000-0000-0000-0000-0000000000d0"}', true);
  EXECUTE p_sql;
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN 'ok';
EXCEPTION WHEN others THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN SQLSTATE || ': ' || SQLERRM;
END; $$;

\set ta   '\'a7000000-0000-0000-0000-0000000000a0\''
\set tb   '\'a7000000-0000-0000-0000-0000000000b0\''
\set dono '\'a7000000-0000-0000-0000-0000000000d0\''
\set oper '\'a7000000-0000-0000-0000-0000000000d1\''
\set donob '\'a7000000-0000-0000-0000-0000000000d2\''

INSERT INTO tenants (id, nome, slug) VALUES
  (:ta, 'Corretora Auditoria A', 'corretora-auditoria-a'),
  (:tb, 'Corretora Auditoria B', 'corretora-auditoria-b');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:ta, :dono, 'dono'), (:ta, :oper, 'operador'), (:tb, :donob, 'dono');

-- As credenciais que já existem: o ponteiro de Vault aponta para um uuid que
-- não existe, e não precisa existir — o caminho de reaproveitar não chama o
-- Vault, e é ele que se testa.
INSERT INTO ai_credentials (id, tenant_id, nome, provedor, modelo, chave_secret_id, config) VALUES
  ('a7000000-0000-0000-0000-0000000000c1', :ta, 'OpenAI da matriz', 'openai', 'gpt-4o',
   'a7000000-0000-0000-0000-0000000077c1', '{"organizacao":"org-matriz"}'),
  ('a7000000-0000-0000-0000-0000000000c2', :ta, 'Claude de produção', 'anthropic', 'claude-sonnet-4-5',
   'a7000000-0000-0000-0000-0000000077c2', '{"base_url":"https://proxy.exemplo.com"}');
INSERT INTO crm_connections (id, tenant_id, nome, provedor, credencial_secret_id, config) VALUES
  ('a7000000-0000-0000-0000-0000000000e1', :ta, 'Zoho da matriz', 'zoho_crm',
   'a7000000-0000-0000-0000-0000000077e1', '{"client_id":"1000.ABC","data_center":"com"}'),
  ('a7000000-0000-0000-0000-0000000000e2', :ta, 'Pipedrive vendas', 'pipedrive',
   'a7000000-0000-0000-0000-0000000077e2', '{"dominio_empresa":"afinix"}');
INSERT INTO provider_servers (id, tenant_id, provedor, nome, base_url, admin_secret_id) VALUES
  ('a7000000-0000-0000-0000-0000000000f1', :ta, 'uazapi', 'UAZAPI Matriz',
   'https://matriz.uazapi.com', 'a7000000-0000-0000-0000-0000000077f1');

-- ===========================================================================
-- 1. A chave guardada vale para um destino só
-- ===========================================================================

-- IA: trocar só o modelo continua sem pedir a chave, e sem apagar a organização.
SELECT au.confere('IA: editar só o modelo reaproveita a chave',
  au.como_dono($$SELECT salvar_credencial_ia('a7000000-0000-0000-0000-0000000000a0', 'OpenAI da matriz',
                                              'openai', 'gpt-4o-mini', '{}'::jsonb)$$) = 'ok');
SELECT au.confere('IA: e não apaga o campo que a tela não mandou (organização)',
  (SELECT config = '{"organizacao":"org-matriz"}'::jsonb AND chave_secret_id = 'a7000000-0000-0000-0000-0000000077c1'
          AND modelo = 'gpt-4o-mini'
     FROM ai_credentials WHERE id = 'a7000000-0000-0000-0000-0000000000c1'),
  (SELECT config::text || ' / ' || coalesce(chave_secret_id::text, 'sem chave')
     FROM ai_credentials WHERE id = 'a7000000-0000-0000-0000-0000000000c1'));

-- IA: trocar o provedor com a chave em branco mandaria a chave da Anthropic
-- para a OpenAI. Recusa ANTES do Vault (22023, não 0A000).
CREATE TABLE au.r (caso text PRIMARY KEY, saida text);
INSERT INTO au.r VALUES ('ia_provedor', au.como_dono(
  $$SELECT salvar_credencial_ia('a7000000-0000-0000-0000-0000000000a0', 'Claude de produção',
                                'openai', 'gpt-4o', '{"api_key":""}'::jsonb)$$));
SELECT au.confere('IA: trocar o provedor com a chave em branco é recusado',
  (SELECT saida LIKE '22023: trocar o provedor pede a chave nova%' FROM au.r WHERE caso = 'ia_provedor'),
  (SELECT saida FROM au.r WHERE caso = 'ia_provedor'));
SELECT au.confere('IA: e a credencial continua como estava (provedor e chave)',
  (SELECT provedor = 'anthropic' AND chave_secret_id = 'a7000000-0000-0000-0000-0000000077c2'
     FROM ai_credentials WHERE id = 'a7000000-0000-0000-0000-0000000000c2'));

-- IA: o endereço é destino. Mudar o base_url com a chave em branco mandaria a
-- chave para o endereço recém-digitado.
INSERT INTO au.r VALUES ('ia_endereco', au.como_dono(
  $$SELECT salvar_credencial_ia('a7000000-0000-0000-0000-0000000000a0', 'Claude de produção',
                                'anthropic', 'claude-sonnet-4-5', '{"base_url":"https://outro.exemplo.com"}'::jsonb)$$));
SELECT au.confere('IA: mudar o endereço com a chave em branco é recusado',
  (SELECT saida LIKE '22023: mudar o endereço pede a chave de novo%' FROM au.r WHERE caso = 'ia_endereco'),
  (SELECT saida FROM au.r WHERE caso = 'ia_endereco'));
SELECT au.confere('IA: e o endereço guardado não mudou',
  (SELECT config ->> 'base_url' = 'https://proxy.exemplo.com'
     FROM ai_credentials WHERE id = 'a7000000-0000-0000-0000-0000000000c2'));

-- IA: o MESMO endereço, com outra caixa e barra no fim, não é destino novo.
SELECT au.confere('IA: o mesmo endereço escrito diferente continua reaproveitando a chave',
  au.como_dono($$SELECT salvar_credencial_ia('a7000000-0000-0000-0000-0000000000a0', 'Claude de produção',
                                              'anthropic', 'claude-sonnet-4-5',
                                              '{"base_url":"HTTPS://Proxy.Exemplo.com/"}'::jsonb)$$) = 'ok');

-- IA: com a chave nova, trocar o provedor segue para o Vault (e para lá na
-- borda, porque aqui não há Vault). É o par da recusa acima: a regra não trava
-- quem manda a chave.
INSERT INTO au.r VALUES ('ia_provedor_com_chave', au.como_dono(
  $$SELECT salvar_credencial_ia('a7000000-0000-0000-0000-0000000000a0', 'Claude de produção',
                                'openai', 'gpt-4o', '{"api_key":"chave-nova"}'::jsonb)$$));
SELECT au.confere('IA: trocar o provedor COM a chave nova passa da regra e vai ao Vault',
  (SELECT saida LIKE '0A000:%' FROM au.r WHERE caso = 'ia_provedor_com_chave'),
  (SELECT saida FROM au.r WHERE caso = 'ia_provedor_com_chave'));

-- CRM: o Zoho guarda DUAS chaves num objeto só. Mandar uma e deixar a outra em
-- branco perderia a segunda.
INSERT INTO au.r VALUES ('crm_uma_chave', au.como_dono(
  $$SELECT salvar_credencial_crm('a7000000-0000-0000-0000-0000000000a0', 'Zoho da matriz', 'zoho_crm',
                                 '{"refresh_token":"novo-refresh","client_secret":""}'::jsonb)$$));
SELECT au.confere('CRM: trocar uma das chaves pede as outras junto',
  (SELECT saida LIKE '22023: trocar uma das chaves pede as outras junto%' FROM au.r WHERE caso = 'crm_uma_chave'),
  (SELECT saida FROM au.r WHERE caso = 'crm_uma_chave'));

-- CRM: o domínio do Pipedrive é destino.
INSERT INTO au.r VALUES ('crm_dominio', au.como_dono(
  $$SELECT salvar_credencial_crm('a7000000-0000-0000-0000-0000000000a0', 'Pipedrive vendas', 'pipedrive',
                                 '{"dominio_empresa":"outra-empresa"}'::jsonb)$$));
SELECT au.confere('CRM: mudar o domínio com o token em branco é recusado',
  (SELECT saida LIKE '22023: mudar o endereço pede a chave de novo%' FROM au.r WHERE caso = 'crm_dominio'),
  (SELECT saida FROM au.r WHERE caso = 'crm_dominio'));

-- CRM: trocar de plataforma mantendo o nome.
INSERT INTO au.r VALUES ('crm_provedor', au.como_dono(
  $$SELECT salvar_credencial_crm('a7000000-0000-0000-0000-0000000000a0', 'Pipedrive vendas', 'hubspot',
                                 '{"token":""}'::jsonb)$$));
SELECT au.confere('CRM: trocar a plataforma com o token em branco é recusado',
  (SELECT saida LIKE '22023: trocar o provedor pede a chave nova%' FROM au.r WHERE caso = 'crm_provedor'),
  (SELECT saida FROM au.r WHERE caso = 'crm_provedor'));

-- CRM: reenviar sem campo nenhum mantém domínio e token.
SELECT au.confere('CRM: salvar de novo sem campos reaproveita o token',
  au.como_dono($$SELECT salvar_credencial_crm('a7000000-0000-0000-0000-0000000000a0', 'Pipedrive vendas',
                                               'pipedrive', '{}'::jsonb)$$) = 'ok');
SELECT au.confere('CRM: e não apaga o domínio que a tela não mandou',
  (SELECT config = '{"dominio_empresa":"afinix"}'::jsonb AND credencial_secret_id = 'a7000000-0000-0000-0000-0000000077e2'
     FROM crm_connections WHERE id = 'a7000000-0000-0000-0000-0000000000e2'),
  (SELECT config::text FROM crm_connections WHERE id = 'a7000000-0000-0000-0000-0000000000e2'));

-- Servidor de instância: o token de ADMINISTRAÇÃO, que cria chip.
SELECT au.confere('servidor: a mesma URL com barra no fim reaproveita o token',
  au.como_dono($$SELECT salvar_servidor_provedor('a7000000-0000-0000-0000-0000000000a0', 'uazapi',
                                                  'UAZAPI Matriz', 'https://matriz.uazapi.com/', NULL)$$) = 'ok');
INSERT INTO au.r VALUES ('srv_url', au.como_dono(
  $$SELECT salvar_servidor_provedor('a7000000-0000-0000-0000-0000000000a0', 'uazapi',
                                    'UAZAPI Matriz', 'https://outro-servidor.exemplo.com', NULL)$$));
SELECT au.confere('servidor: outra URL com o token em branco é recusada',
  (SELECT saida LIKE '22023: mudar a URL ou o provedor do servidor pede o token%' FROM au.r WHERE caso = 'srv_url'),
  (SELECT saida FROM au.r WHERE caso = 'srv_url'));
INSERT INTO au.r VALUES ('srv_provedor', au.como_dono(
  $$SELECT salvar_servidor_provedor('a7000000-0000-0000-0000-0000000000a0', 'evolution',
                                    'UAZAPI Matriz', 'https://matriz.uazapi.com', NULL)$$));
SELECT au.confere('servidor: outro provedor com o token em branco é recusado',
  (SELECT saida LIKE '22023:%' FROM au.r WHERE caso = 'srv_provedor'),
  (SELECT saida FROM au.r WHERE caso = 'srv_provedor'));
SELECT au.confere('servidor: e ele continua apontando para onde estava, com o token de antes',
  (SELECT provedor = 'uazapi' AND admin_secret_id = 'a7000000-0000-0000-0000-0000000077f1'
          AND privado.mesmo_destino(base_url, 'https://matriz.uazapi.com')
     FROM provider_servers WHERE id = 'a7000000-0000-0000-0000-0000000000f1'));

-- ===========================================================================
-- 2. Conectar conta é uma transação só
-- ===========================================================================

-- Credencial recusada pelo catálogo (a UAZAPI pede o token): antes, a conta
-- ficava criada, ativa e no pool, sem segredo — e o despacho queimava o passo.
INSERT INTO au.r VALUES ('conecta_recusada', au.como_dono(
  $$SELECT conectar_conta('a7000000-0000-0000-0000-0000000000a0', 'whatsapp', 'uazapi', '5515990001111',
                          'Chip recusado', 'morna', 50, '{"base_url":"https://matriz.uazapi.com"}'::jsonb)$$));
SELECT au.confere('conectar: credencial recusada é recusada',
  (SELECT saida LIKE '22023: campo obrigatório em branco%' FROM au.r WHERE caso = 'conecta_recusada'),
  (SELECT saida FROM au.r WHERE caso = 'conecta_recusada'));
SELECT au.confere('conectar: e nenhuma conta fica para trás',
  NOT EXISTS (SELECT 1 FROM sender_accounts WHERE identificador = '5515990001111'));

-- Sem Vault: a credencial passa pelo catálogo e para na borda — e a conta
-- também não fica.
INSERT INTO au.r VALUES ('conecta_sem_vault', au.como_dono(
  $$SELECT conectar_conta('a7000000-0000-0000-0000-0000000000a0', 'whatsapp', 'uazapi', '5515990002222',
                          'Chip sem cofre', 'morna', 50,
                          '{"base_url":"https://matriz.uazapi.com","token":"tok-instancia"}'::jsonb)$$));
SELECT au.confere('conectar: quando o Vault falha, a conta não fica meio criada',
  (SELECT saida LIKE '0A000:%' FROM au.r WHERE caso = 'conecta_sem_vault')
  AND NOT EXISTS (SELECT 1 FROM sender_accounts WHERE identificador = '5515990002222'),
  (SELECT saida FROM au.r WHERE caso = 'conecta_sem_vault'));

DO $$
DECLARE v text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"a7000000-0000-0000-0000-0000000000d1"}', true);
  BEGIN
    PERFORM conectar_conta('a7000000-0000-0000-0000-0000000000a0', 'whatsapp', 'uazapi', '5515990003333',
                           'Chip do operador', 'morna', 50, '{}'::jsonb);
    v := 'conectou';
  EXCEPTION WHEN others THEN v := SQLSTATE;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM au.confere('conectar: operador não conecta conta', v = '42501', v);
END;
$$;

SELECT au.confere('conectar e buscar: da tela, não de quem não entrou',
  has_function_privilege('authenticated', 'conectar_conta(uuid, canal, text, text, text, tipo_campanha, integer, jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'conectar_conta(uuid, canal, text, text, text, tipo_campanha, integer, jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'buscar_contatos(uuid, text, integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'buscar_contatos(uuid, text, integer)', 'EXECUTE'));

-- ===========================================================================
-- 3. A busca de contatos
-- ===========================================================================

INSERT INTO contacts (id, tenant_id, nome, origem) VALUES
  ('a7000000-0000-0000-0000-000000000a01', :ta, 'Maria Souza', 'planilha'),
  ('a7000000-0000-0000-0000-000000000a02', :ta, 'João 50% Off', 'planilha'),
  ('a7000000-0000-0000-0000-000000000a03', :ta, 'Ana Lima', 'planilha'),
  ('a7000000-0000-0000-0000-000000000b01', :tb, 'Maria do Outro Cliente', 'planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem) VALUES
  (:ta, 'a7000000-0000-0000-0000-000000000a01', 'whatsapp', '+55 15 99123-4567', '5515991234567', 'planilha'),
  (:ta, 'a7000000-0000-0000-0000-000000000a03', 'email', 'ana@exemplo.com', 'ana@exemplo.com', 'planilha'),
  (:tb, 'a7000000-0000-0000-0000-000000000b01', 'whatsapp', '+55 15 99123-4567', '5515991234567', 'planilha');

CREATE FUNCTION au.achou(p_tenant uuid, p_termo text) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(c.nome, ', ' ORDER BY c.nome), '(nada)')
    FROM buscar_contatos(p_tenant, p_termo) b JOIN contacts c ON c.id = b.contact_id
$$;
GRANT EXECUTE ON FUNCTION au.achou(uuid, text) TO authenticated;

SELECT au.confere('busca: pelo nome, sem caixa', au.achou(:ta, 'maria') = 'Maria Souza', au.achou(:ta, 'maria'));
SELECT au.confere('busca: pelo número como se digita, "(15) 99123-4567"',
  au.achou(:ta, '(15) 99123-4567') = 'Maria Souza', au.achou(:ta, '(15) 99123-4567'));
SELECT au.confere('busca: pelo endereço', au.achou(:ta, 'exemplo.com') = 'Ana Lima', au.achou(:ta, 'exemplo.com'));
SELECT au.confere('busca: "%" é texto, não curinga', au.achou(:ta, '50%') = 'João 50% Off', au.achou(:ta, '50%'));
SELECT au.confere('busca: "_" é texto, não curinga', au.achou(:ta, '_') = '(nada)', au.achou(:ta, '_'));
SELECT au.confere('busca: termo vazio não devolve a base inteira', au.achou(:ta, '   ') = '(nada)', au.achou(:ta, '   '));

-- No papel de quem usa o produto: o RLS decide, e pedir o cliente do outro
-- não abre nada.
BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-0000000000d1"}';
  SELECT au.confere('busca: o operador acha no próprio cliente', au.achou('a7000000-0000-0000-0000-0000000000a0', 'maria') = 'Maria Souza',
    au.achou('a7000000-0000-0000-0000-0000000000a0', 'maria'));
  SELECT au.confere('busca: e não acha no cliente do outro, nem pedindo por ele',
    au.achou('a7000000-0000-0000-0000-0000000000b0', 'maria') = '(nada)',
    au.achou('a7000000-0000-0000-0000-0000000000b0', 'maria'));
COMMIT;

-- ===========================================================================
-- 4. TRUNCATE não passa pelo RLS, e não é de ninguém da tela
-- ===========================================================================

SELECT au.confere('nenhuma tabela de public aceita TRUNCATE de authenticated ou anon',
  NOT EXISTS (SELECT 1 FROM pg_tables t
               WHERE t.schemaname = 'public'
                 AND (has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'TRUNCATE')
                      OR has_table_privilege('anon', format('%I.%I', t.schemaname, t.tablename), 'TRUNCATE'))),
  (SELECT string_agg(t.tablename, ', ') FROM pg_tables t
    WHERE t.schemaname = 'public'
      AND has_table_privilege('authenticated', format('%I.%I', t.schemaname, t.tablename), 'TRUNCATE')));

-- ===========================================================================
-- 5. Com um Vault de mentira: o chip
-- ===========================================================================
--
-- O chip guarda o objeto inteiro no Vault e LÊ o anterior para reaproveitar o
-- segredo em branco. Sem Vault não há anterior para ler, e a regra do destino
-- não teria o que comparar — o cenário não conseguiria falhar (D36). Este
-- Vault tem o que importa do de verdade: grava, devolve pelo id e recusa nome
-- repetido. Sai antes do relatório.

CREATE SCHEMA vault;
CREATE TABLE vault.secrets (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text UNIQUE, secret text);
CREATE FUNCTION vault.create_secret(new_secret text, new_name text) RETURNS uuid
LANGUAGE sql AS $$ INSERT INTO vault.secrets (name, secret) VALUES (new_name, new_secret) RETURNING id $$;
CREATE VIEW vault.decrypted_secrets AS SELECT id, name, secret AS decrypted_secret FROM vault.secrets;

INSERT INTO au.r VALUES ('conecta_ok', au.como_dono(
  $$SELECT conectar_conta('a7000000-0000-0000-0000-0000000000a0', 'whatsapp', 'uazapi', '5515990004444',
                          'Chip conectado', 'morna', 50,
                          '{"base_url":"https://matriz.uazapi.com","token":"tok-original"}'::jsonb)$$));
SELECT au.confere('conectar: com o Vault, a conta nasce com o segredo na mesma transação',
  (SELECT saida = 'ok' FROM au.r WHERE caso = 'conecta_ok')
  AND (SELECT s.config = '{"base_url":"https://matriz.uazapi.com"}'::jsonb
              AND (v.secret::jsonb ->> 'token') = 'tok-original'
         FROM sender_accounts s JOIN vault.secrets v ON v.id = s.credenciais_secret_id
        WHERE s.identificador = '5515990004444'),
  (SELECT saida FROM au.r WHERE caso = 'conecta_ok'));

-- O chip muda de servidor e a pessoa não cola o token: ele iria para o servidor novo.
INSERT INTO au.r VALUES ('chip_endereco', au.como_dono(format(
  $$SELECT salvar_credencial_remetente(%L, '{"base_url":"https://servidor-novo.exemplo.com","token":""}'::jsonb)$$,
  (SELECT id FROM sender_accounts WHERE identificador = '5515990004444'))));
SELECT au.confere('chip: mudar o endereço com o token em branco é recusado',
  (SELECT saida LIKE '22023: mudar o endereço pede a chave de novo%' FROM au.r WHERE caso = 'chip_endereco'),
  (SELECT saida FROM au.r WHERE caso = 'chip_endereco'));

-- O mesmo endereço, token em branco: reaproveita o token de antes.
INSERT INTO au.r VALUES ('chip_mesmo', au.como_dono(format(
  $$SELECT salvar_credencial_remetente(%L, '{"base_url":"https://matriz.uazapi.com/","token":""}'::jsonb)$$,
  (SELECT id FROM sender_accounts WHERE identificador = '5515990004444'))));
SELECT au.confere('chip: o mesmo endereço reaproveita o token guardado',
  (SELECT saida = 'ok' FROM au.r WHERE caso = 'chip_mesmo')
  AND (SELECT (v.secret::jsonb ->> 'token') = 'tok-original'
         FROM sender_accounts s JOIN vault.secrets v ON v.id = s.credenciais_secret_id
        WHERE s.identificador = '5515990004444'),
  (SELECT saida FROM au.r WHERE caso = 'chip_mesmo'));

DROP SCHEMA vault CASCADE;

-- ===========================================================================

\echo ''
\echo '============= O QUE A AUDITORIA ACHOU (D77) ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM au.resultado ORDER BY id;
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM au.resultado;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM au.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'auditoria: % asserções falharam', (SELECT count(*) FROM au.resultado WHERE NOT ok);
  END IF;
END;
$$;
