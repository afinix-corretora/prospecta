-- Plataformas vinculadas: credencial de CRM por tenant (D59).
--
-- O que este arquivo sustenta, e por que cada coisa:
--
--   1. a separação segredo/config é feita pelo CATÁLOGO, não pela tela. O teste
--      usa Zoho e Salesforce de propósito, porque são os dois de campos MISTOS
--      (client_id em config, client_secret e refresh_token no Vault). Com um
--      provedor de campo único, uma função que jogasse tudo em `config`
--      passaria — seria a asserção que o cenário não consegue violar (D36);
--   2. o gatilho barra segredo em config mesmo sem passar pela função, porque
--      trava que só existe no caminho felizmente percorrido não é trava;
--   3. reenviar segredo vazio na edição NÃO apaga a credencial: a tela não
--      consegue devolver o que não pode ler, e perder a credencial de uma
--      conexão em uso por causa disso seria o writeback parando em silêncio;
--   4. quem não administra não vincula, e o segredo não é alcançável pela UI.
--
-- **O QUE ESTE ARQUIVO NÃO TESTA, e não é esquecimento.**
--
-- O banco de teste não tem `supabase_vault`, então nenhuma asserção aqui vê um
-- segredo ser gravado e lido de volta. O padrão é o mesmo do `tests/agentes.sql`
-- para `salvar_credencial_ia`: quando há segredo NOVO, a função corre inteira e
-- para na borda do Vault com `feature_not_supported` — e essa parada é a prova
-- de que o destino do segredo é o Vault e não uma coluna. Tudo o que não chama
-- o Vault (separação de config, edição, recusas, permissão, gatilho) roda de
-- verdade. Ler o segredo de volta é conferido no projeto, pelo `get_advisors` e
-- pela tela, não aqui.
--
-- E não testa que vincular escreve no CRM. Não escreve: nenhum adapter existe,
-- `tem_adapter` é falso nas oito linhas, e asserção sobre efeito que não existe
-- é decoração (D31).

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA pl;
CREATE TABLE pl.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION pl.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO pl.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set tenant '\'59000000-0000-0000-0000-0000000000a0\''
\set outro  '\'59000000-0000-0000-0000-0000000000b0\''

INSERT INTO tenants (id, nome, slug) VALUES
  (:tenant, 'Corretora Plataforma', 'corretora-plataforma'),
  (:outro,  'Corretora Vizinha',    'corretora-vizinha');

-- `salvar_credencial_crm` checa `pode_administrar` em código, então ela recusa
-- até o superusuário do teste: quem não está em `tenant_users` não administra
-- nada, e isso está certo. Rodar como gente é o padrão do `tests/agentes.sql`,
-- e é ele que faz a asserção de permissão valer alguma coisa.
--
-- O operador é operador de verdade, não usuário desconhecido: sem esta linha, a
-- asserção lá embaixo passaria provando que ESTRANHO não vincula, que é outra
-- coisa e mais fácil. O cenário tem que criar a situação que ele afirma (D43).
--
-- `set_config(..., true)` vale até o fim da transação, e em psql cada comando é
-- a sua. Por isso o claims é definido DENTRO de cada bloco, e não uma vez aqui:
-- definido fora, valeria para o primeiro comando e para nenhum dos outros, e o
-- sintoma seria metade das asserções recusadas por permissão.
-- dd00 é dono do tenant; dd01 é operador dele; dd02 é dono do tenant vizinho.
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:tenant, '59000000-0000-0000-0000-00000000dd00', 'dono'),
  (:tenant, '59000000-0000-0000-0000-00000000dd01', 'operador'),
  (:outro,  '59000000-0000-0000-0000-00000000dd02', 'dono');

-- ---------------------------------------------------------------------------
-- O catálogo
-- ---------------------------------------------------------------------------

SELECT pl.confere('catálogo de CRM tem as oito plataformas',
  (SELECT count(*) FROM crm_provider_catalog) = 8,
  (SELECT count(*)::text || ': ' || string_agg(slug, ', ' ORDER BY ordem)
     FROM crm_provider_catalog));

-- A afirmação do comentário da migration, cobrada. Vai ficar vermelha no dia em
-- que alguém marcar `tem_adapter` sem escrever o adapter — que é o ponto.
SELECT pl.confere('nenhuma plataforma de CRM declara adapter (nenhum existe)',
  NOT EXISTS (SELECT 1 FROM crm_provider_catalog WHERE tem_adapter),
  (SELECT string_agg(slug, ', ') FROM crm_provider_catalog WHERE tem_adapter));

-- Campo sem `segredo` declarado seria tratado como não-secreto pelo
-- `(c ->> 'segredo')::boolean` da função — e uma chave iria para `config`.
SELECT pl.confere('todo campo do catálogo declara segredo e obrigatorio',
  NOT EXISTS (
    SELECT 1 FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
     WHERE c ->> 'segredo' IS NULL OR c ->> 'obrigatorio' IS NULL
        OR c ->> 'chave' IS NULL OR c ->> 'rotulo' IS NULL),
  (SELECT string_agg(p.slug || '.' || coalesce(c ->> 'chave', '?'), ', ')
     FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
    WHERE c ->> 'segredo' IS NULL OR c ->> 'obrigatorio' IS NULL
       OR c ->> 'chave' IS NULL OR c ->> 'rotulo' IS NULL));

-- Plataforma que não pede nenhum segredo não autentica nada: seria uma linha
-- que a tela desenha e que nunca guarda credencial.
SELECT pl.confere('toda plataforma pede ao menos um campo secreto',
  NOT EXISTS (
    SELECT 1 FROM crm_provider_catalog p
     WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p.campos) c
                        WHERE (c ->> 'segredo')::boolean)),
  (SELECT string_agg(p.slug, ', ') FROM crm_provider_catalog p
    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p.campos) c
                       WHERE (c ->> 'segredo')::boolean)));

-- ---------------------------------------------------------------------------
-- Segredo novo vai para o Vault — e para lá porque o Vault não existe aqui
-- ---------------------------------------------------------------------------

-- Este é o par da separação: quem administra atravessa a função inteira (nome,
-- catálogo, campos, obrigatórios) e só então tenta gravar. Se o segredo fosse
-- para uma coluna, o bloco terminaria sem erro nenhum.
DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  BEGIN
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, 'HubSpot novo', 'hubspot',
      '{"token":"pat-na-mao"}'::jsonb);
    v_erro := 'gravou sem Vault';
  EXCEPTION
    WHEN feature_not_supported THEN v_erro := 'parou no Vault';
    WHEN insufficient_privilege THEN v_erro := 'barrou quem pode';
  END;
  PERFORM pl.confere('segredo novo vai para o Vault, não para uma coluna',
    v_erro = 'parou no Vault', v_erro);
END;
$$;

-- E nada foi gravado: a função é uma transação só, então parar no Vault desfaz
-- a linha. Meia credencial gravada seria pior que nenhuma.
SELECT pl.confere('conexão não fica meio gravada quando o Vault falha',
  NOT EXISTS (SELECT 1 FROM crm_connections WHERE nome = 'HubSpot novo'));

-- ---------------------------------------------------------------------------
-- A separação é do catálogo — exercida sem tocar no Vault
-- ---------------------------------------------------------------------------

-- Conexões que já têm segredo guardado: o `credencial_secret_id` aponta para um
-- uuid que não existe no Vault, e não precisa existir. O que interessa é que
-- `v_antigo IS NOT NULL` libera o caminho de edição, onde o segredo volta vazio
-- da tela e a função não chama o Vault.
INSERT INTO crm_connections (id, tenant_id, nome, provedor, credencial_secret_id, config) VALUES
  ('59000000-0000-0000-0000-0000000000c1', :tenant, 'Zoho da matriz', 'zoho_crm',
   '59000000-0000-0000-0000-0000000077a1', '{}'::jsonb),
  ('59000000-0000-0000-0000-0000000000c2', :tenant, 'Salesforce corp', 'salesforce',
   '59000000-0000-0000-0000-0000000077a2', '{}'::jsonb),
  ('59000000-0000-0000-0000-0000000000c3', :tenant, 'Pipedrive vendas', 'pipedrive',
   '59000000-0000-0000-0000-0000000077a3', '{"dominio_empresa":"afinix"}'::jsonb);

-- Zoho é o caso de campos mistos mais completo: dois segredos e dois de config.
DO $$
DECLARE v_config jsonb; v_secret uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  PERFORM salvar_credencial_crm(
    '59000000-0000-0000-0000-0000000000a0'::uuid, 'Zoho da matriz', 'zoho_crm',
    jsonb_build_object(
      'client_id',     '1000.ABCDEF',
      'client_secret', '',
      'refresh_token', '',
      'data_center',   'com'));

  -- Chamar a função e conferir o efeito dela na MESMA expressão leria o
  -- snapshot do início da instrução e não veria a gravação (D38). Por isso o
  -- SELECT vem depois, em instrução separada.
  SELECT config, credencial_secret_id INTO v_config, v_secret
    FROM crm_connections WHERE id = '59000000-0000-0000-0000-0000000000c1';

  PERFORM pl.confere('config guarda só o que o catálogo NÃO marca como segredo',
    v_config = jsonb_build_object('client_id', '1000.ABCDEF', 'data_center', 'com'),
    v_config::text);

  -- A asserção que pega o erro mais caro, e que consegue falhar: se a função
  -- ignorasse o catálogo e jogasse `p_campos` inteiro em config, as duas chaves
  -- secretas estariam aqui — mesmo vazias.
  PERFORM pl.confere('nenhum campo secreto do Zoho aparece em config',
    NOT (v_config ? 'client_secret') AND NOT (v_config ? 'refresh_token'),
    v_config::text);

  PERFORM pl.confere('editar sem reenviar segredo preserva a credencial do Zoho',
    v_secret = '59000000-0000-0000-0000-0000000077a1', coalesce(v_secret::text, 'nulo'));
END;
$$;

-- Salesforce: o segundo de campos mistos, com um campo de config que é URL.
DO $$
DECLARE v_config jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  PERFORM salvar_credencial_crm(
    '59000000-0000-0000-0000-0000000000a0'::uuid, 'Salesforce corp', 'salesforce',
    jsonb_build_object(
      'client_id',     '3MVG9abc',
      'client_secret', '',
      'dominio',       'https://afinix.my.salesforce.com'));

  SELECT config INTO v_config FROM crm_connections
   WHERE id = '59000000-0000-0000-0000-0000000000c2';

  PERFORM pl.confere('Salesforce: client_id e domínio em config, secret fora',
    v_config = jsonb_build_object(
      'client_id', '3MVG9abc', 'dominio', 'https://afinix.my.salesforce.com'),
    v_config::text);
END;
$$;

-- ---------------------------------------------------------------------------
-- Editar pelo nome não cria conexão nova
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_id uuid; v_config jsonb; v_secret uuid; v_quantas integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  v_id := salvar_credencial_crm(
    '59000000-0000-0000-0000-0000000000a0'::uuid, 'Pipedrive vendas', 'pipedrive',
    jsonb_build_object('api_token', '', 'dominio_empresa', 'afinix-novo'));

  SELECT config, credencial_secret_id INTO v_config, v_secret
    FROM crm_connections WHERE id = '59000000-0000-0000-0000-0000000000c3';
  SELECT count(*) INTO v_quantas FROM crm_connections
   WHERE tenant_id = '59000000-0000-0000-0000-0000000000a0'::uuid
     AND nome = 'Pipedrive vendas';

  PERFORM pl.confere('editar pelo nome devolve a conexão que já existia',
    v_id = '59000000-0000-0000-0000-0000000000c3', v_id::text);
  PERFORM pl.confere('editar não duplica a conexão', v_quantas = 1, v_quantas::text);
  PERFORM pl.confere('o campo de config editado mudou',
    v_config ->> 'dominio_empresa' = 'afinix-novo', v_config::text);
  PERFORM pl.confere('segredo vazio na edição preserva a credencial',
    v_secret = '59000000-0000-0000-0000-0000000077a3', coalesce(v_secret::text, 'nulo'));
END;
$$;

-- ---------------------------------------------------------------------------
-- O que a função recusa
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  BEGIN
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, 'X', 'crm-que-nao-existe',
      '{"token":"t"}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN no_data_found THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('plataforma fora do catálogo é recusada', v_erro = 'recusou', v_erro);
END;
$$;

DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  BEGIN
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, 'Zoho da matriz', 'zoho_crm',
      '{"client_id":"x","data_center":"com","campo_inventado":"y"}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN invalid_parameter_value THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('campo que o catálogo não declara é recusado',
    v_erro = 'recusou', v_erro);
END;
$$;

DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  BEGIN
    -- Pipedrive pede token E domínio. O token em branco passa (a conexão já tem
    -- credencial guardada), o domínio em branco não — ele não é segredo, então
    -- a tela consegue devolvê-lo e branco ali é branco de verdade.
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, 'Pipedrive vendas', 'pipedrive',
      '{"api_token":"","dominio_empresa":"  "}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN invalid_parameter_value THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('campo obrigatório não-secreto em branco é recusado',
    v_erro = 'recusou', v_erro);
END;
$$;

-- E o contrário, que é o que faz a asserção de cima significar algo: segredo
-- obrigatório em branco na CRIAÇÃO é recusado, porque ali não há valor antigo
-- para preservar. Sem este par, "branco é recusado" e "branco é aceito" ficariam
-- indistinguíveis.
DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  BEGIN
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, 'Ploomes primeira vez', 'ploomes',
      '{"user_key":""}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN invalid_parameter_value THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('segredo obrigatório em branco é recusado na criação',
    v_erro = 'recusou', v_erro);
END;
$$;

DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd00"}', true);
  BEGIN
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, '   ', 'hubspot',
      '{"token":"t"}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN invalid_parameter_value THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('conexão sem nome é recusada', v_erro = 'recusou', v_erro);
END;
$$;

-- ---------------------------------------------------------------------------
-- O gatilho, para quem não passa pela função
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    INSERT INTO crm_connections (tenant_id, nome, provedor, config)
    VALUES ('59000000-0000-0000-0000-0000000000a0'::uuid, 'Direto', 'hubspot',
            '{"token":"chave-em-texto-claro"}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN restrict_violation THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('gatilho barra segredo em config no INSERT direto',
    v_erro = 'recusou', v_erro);
END;
$$;

DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    UPDATE crm_connections
       SET config = config || '{"api_token":"vazou"}'::jsonb
     WHERE id = '59000000-0000-0000-0000-0000000000c3';
    v_erro := 'passou';
  EXCEPTION WHEN restrict_violation THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('gatilho barra segredo em config no UPDATE',
    v_erro = 'recusou', v_erro);
END;
$$;

-- ---------------------------------------------------------------------------
-- Quem pode
-- ---------------------------------------------------------------------------

-- Operador não vincula plataforma: credencial de CRM escreve na base de vendas
-- do cliente, e isso é decisão de quem administra.
DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd01"}', true);
  BEGIN
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, 'Do operador', 'hubspot',
      '{"token":"t"}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN insufficient_privilege THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('operador do cliente não vincula plataforma',
    v_erro = 'recusou', v_erro);
END;
$$;

-- Dono de um cliente não vincula no outro. É o furo que o D18 existe para
-- fechar, e a asserção só vale porque dd02 é dono DE VERDADE — do vizinho.
DO $$
DECLARE v_erro text;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"59000000-0000-0000-0000-00000000dd02"}', true);
  BEGIN
    PERFORM salvar_credencial_crm(
      '59000000-0000-0000-0000-0000000000a0'::uuid, 'Do vizinho', 'hubspot',
      '{"token":"t"}'::jsonb);
    v_erro := 'passou';
  EXCEPTION WHEN insufficient_privilege THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('dono de um cliente não vincula plataforma no outro',
    v_erro = 'recusou', v_erro);
END;
$$;

-- `segredo_da_conexao_crm` é do worker. Se a UI pudesse chamá-la, o admin
-- logado leria de volta a credencial — e o D44 existe justamente para que
-- nenhuma função devolva segredo a quem não é o motor.
SELECT pl.confere('nem anon nem authenticated chamam segredo_da_conexao_crm',
  NOT has_function_privilege('anon', 'public.segredo_da_conexao_crm(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.segredo_da_conexao_crm(uuid)', 'EXECUTE'),
  'anon=' || has_function_privilege('anon', 'public.segredo_da_conexao_crm(uuid)', 'EXECUTE')::text
  || ' authenticated=' || has_function_privilege('authenticated', 'public.segredo_da_conexao_crm(uuid)', 'EXECUTE')::text);

SELECT pl.confere('anon não chama salvar_credencial_crm',
  NOT has_function_privilege('anon', 'public.salvar_credencial_crm(uuid, text, text, jsonb)', 'EXECUTE'));

SELECT pl.confere('authenticated chama salvar_credencial_crm',
  has_function_privilege('authenticated', 'public.salvar_credencial_crm(uuid, text, text, jsonb)', 'EXECUTE'));

-- Conexão que não existe é erro, não NULL silencioso: o worker que recebesse
-- NULL chamaria o CRM sem credencial e levaria 401 no lugar de saber o motivo.
DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    PERFORM segredo_da_conexao_crm('59000000-0000-0000-0000-0000000000ff'::uuid);
    v_erro := 'passou';
  EXCEPTION WHEN no_data_found THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('segredo de conexão inexistente é erro, não nulo',
    v_erro = 'recusou', v_erro);
END;
$$;

-- ---------------------------------------------------------------------------
-- Um tenant não atropela o outro
-- ---------------------------------------------------------------------------

-- O mesmo nome de conexão em dois clientes é uso normal: os dois chamam a
-- integração deles de "HubSpot". A unicidade é por tenant, não global — foi o
-- que o D18 corrigiu em `ai_credentials`, e repetir o erro aqui seria o segundo
-- cliente não conseguindo vincular.
INSERT INTO crm_connections (tenant_id, nome, provedor, credencial_secret_id) VALUES
  (:tenant, 'HubSpot', 'hubspot', '59000000-0000-0000-0000-0000000077b1'),
  (:outro,  'HubSpot', 'hubspot', '59000000-0000-0000-0000-0000000077b2');

SELECT pl.confere('mesmo nome de conexão em dois tenants coexiste',
  (SELECT count(*) FROM crm_connections WHERE nome = 'HubSpot') = 2);

DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    INSERT INTO crm_connections (tenant_id, nome, provedor, credencial_secret_id)
    VALUES ('59000000-0000-0000-0000-0000000000a0'::uuid, 'HubSpot', 'hubspot',
            '59000000-0000-0000-0000-0000000077b3');
    v_erro := 'passou';
  EXCEPTION WHEN unique_violation THEN v_erro := 'recusou';
  END;
  PERFORM pl.confere('mesmo nome duas vezes no MESMO tenant é recusado',
    v_erro = 'recusou', v_erro);
END;
$$;

-- ---------------------------------------------------------------------------
-- A varredura final: nada de segredo em nenhuma config, em nenhuma conexão
-- ---------------------------------------------------------------------------

SELECT pl.confere('nenhuma conexão gravada tem campo secreto em config',
  NOT EXISTS (
    SELECT 1 FROM crm_connections x
      JOIN crm_provider_catalog p ON p.slug = x.provedor,
      jsonb_array_elements(p.campos) c
     WHERE (c ->> 'segredo')::boolean AND x.config ? (c ->> 'chave')),
  (SELECT string_agg(x.nome || '.' || (c ->> 'chave'), ', ')
     FROM crm_connections x
     JOIN crm_provider_catalog p ON p.slug = x.provedor,
     jsonb_array_elements(p.campos) c
    WHERE (c ->> 'segredo')::boolean AND x.config ? (c ->> 'chave')));

-- ---------------------------------------------------------------------------

\echo ''
\echo '=== plataformas vinculadas ==='
SELECT CASE WHEN ok THEN 'ok  ' ELSE 'FALHA' END AS r, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM pl.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE NOT ok) AS falhas, count(*) AS total FROM pl.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM pl.resultado WHERE NOT ok;
  IF n > 0 THEN
    RAISE EXCEPTION '% asserção(ões) de plataformas vinculadas falharam', n;
  END IF;
END;
$$;
