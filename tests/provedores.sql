-- Catálogo de provedores de canal.
--
-- O que importa aqui: conta de contato não existe sem provedor conhecido, o
-- provedor tem que falar o canal da conta, e segredo não tem onde ser gravado
-- errado. Múltiplas contas do mesmo provedor é o caso normal.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA pv;
CREATE TABLE pv.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION pv.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO pv.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

-- ---------------------------------------------------------------------------
-- O catálogo semeado
-- ---------------------------------------------------------------------------

SELECT pv.confere('o catálogo traz os oito provedores',
  (SELECT count(*) = 8 FROM channel_provider_catalog),
  (SELECT count(*)::text FROM channel_provider_catalog));

SELECT pv.confere('WhatsApp tem oficial e não oficial separados',
  (SELECT count(*) FILTER (WHERE oficial) = 2 AND count(*) FILTER (WHERE NOT oficial) = 2
     FROM channel_provider_catalog WHERE canal = 'whatsapp'));

-- D22: UAZAPI é o não-oficial de agora; Evolution fica porque é o que roda no
-- legado e os chips existentes apontam para ele.
SELECT pv.confere('UAZAPI é o não-oficial escolhido e tem adapter',
  (SELECT NOT oficial AND tem_adapter FROM channel_provider_catalog WHERE slug = 'uazapi'));

SELECT pv.confere('Evolution continua no catálogo, atrás da UAZAPI',
  (SELECT u.ordem < e.ordem
     FROM channel_provider_catalog u, channel_provider_catalog e
    WHERE u.slug = 'uazapi' AND e.slug = 'evolution'));

-- Apagar provedor com conta apontando para ele é o que a FK existe para
-- impedir — senão o backfill de chip do legado perderia o vínculo.
DO $$
BEGIN
  INSERT INTO sender_accounts (canal, identificador, provedor, tipo_permitido, quota_diaria)
  VALUES ('whatsapp','5511977770001','uazapi','fria',50);
  DELETE FROM channel_provider_catalog WHERE slug = 'uazapi';
  PERFORM pv.confere('provedor em uso não pode ser apagado', false, 'foi apagado');
EXCEPTION WHEN others THEN
  PERFORM pv.confere('provedor em uso não pode ser apagado (FK, 23503)',
    SQLSTATE = '23503', SQLSTATE || ': ' || SQLERRM);
END;
$$;

SELECT pv.confere('Gupshup é o oficial de WhatsApp e já tem adapter',
  (SELECT oficial AND tem_adapter FROM channel_provider_catalog WHERE slug = 'gupshup'));

SELECT pv.confere('quem não tem adapter está declarado, não escondido',
  (SELECT array_agg(slug ORDER BY slug) = ARRAY['instagram_oficial','smtp']
     FROM channel_provider_catalog WHERE NOT tem_adapter),
  (SELECT string_agg(slug, ', ' ORDER BY slug) FROM channel_provider_catalog WHERE NOT tem_adapter));

-- D30: e-mail passa a ter adapter, e ele é HTTP. SMTP continua listado sem
-- adapter de propósito — sumir com a opção esconderia a decisão.
SELECT pv.confere('e-mail tem provedor com adapter',
  (SELECT count(*) FILTER (WHERE tem_adapter) = 1
     FROM channel_provider_catalog WHERE canal = 'email'));

SELECT pv.confere('SMTP segue no catálogo, declarado sem adapter',
  (SELECT NOT tem_adapter AND ativo FROM channel_provider_catalog WHERE slug = 'smtp'));

-- O adapter lê `assunto_padrao` com `exigir`, e é este campo que faz "passo de
-- e-mail sem assunto" não existir como estado possível.
SELECT pv.confere('Resend exige assunto padrão, e ele não é segredo',
  (SELECT count(*) = 1 FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
    WHERE p.slug = 'resend' AND c ->> 'chave' = 'assunto_padrao'
      AND (c ->> 'obrigatorio')::boolean AND NOT (c ->> 'segredo')::boolean));

-- Sem `responder_para` apontando para um inbound, a resposta de e-mail cai
-- numa caixa que o motor não lê e a invariante 4 não vale no canal.
SELECT pv.confere('Resend declara para onde a resposta volta',
  (SELECT EXISTS (SELECT 1 FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
                   WHERE p.slug = 'resend' AND c ->> 'chave' = 'responder_para')));

-- Conta de e-mail com provedor de WhatsApp é erro de cadastro que só apareceria
-- na hora do disparo; quem recusa é o gatilho, não a tela.
DO $$
BEGIN
  INSERT INTO sender_accounts (canal, identificador, provedor, tipo_permitido, quota_diaria)
  VALUES ('email','frio@exemplo.com.br','uazapi','fria',200);
  PERFORM pv.confere('provedor de outro canal é recusado no remetente de e-mail',
    false, 'aceitou');
EXCEPTION WHEN restrict_violation THEN
  PERFORM pv.confere('provedor de outro canal é recusado no remetente de e-mail', true);
WHEN others THEN
  PERFORM pv.confere('provedor de outro canal é recusado no remetente de e-mail',
    false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  INSERT INTO sender_accounts (canal, identificador, provedor, tipo_permitido, quota_diaria, config)
  VALUES ('email','frio2@exemplo.com.br','resend','fria',200,'{"api_key":"re_123"}'::jsonb);
  PERFORM pv.confere('chave da Resend não pode ir para config', false, 'aceitou');
EXCEPTION WHEN restrict_violation THEN
  PERFORM pv.confere('chave da Resend não pode ir para config', true);
WHEN others THEN
  PERFORM pv.confere('chave da Resend não pode ir para config',
    false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

SELECT pv.confere('todo provedor declara ao menos um campo secreto',
  NOT EXISTS (
    SELECT 1 FROM channel_provider_catalog p
     WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p.campos) c
                        WHERE (c ->> 'segredo')::boolean)),
  (SELECT string_agg(slug, ', ') FROM channel_provider_catalog p
    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p.campos) c
                       WHERE (c ->> 'segredo')::boolean)));

-- ---------------------------------------------------------------------------
-- A conta aponta para o catálogo
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  INSERT INTO sender_accounts (canal, identificador, provedor, tipo_permitido, quota_diaria)
  VALUES ('whatsapp', '+5511900000001', 'provedor-que-nao-existe', 'fria', 10);
  PERFORM pv.confere('provedor fora do catálogo é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM pv.confere('provedor fora do catálogo é recusado (FK, 23503)',
    SQLSTATE = '23503', SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  -- Comtele é de SMS; a conta diz WhatsApp.
  INSERT INTO sender_accounts (canal, identificador, provedor, tipo_permitido, quota_diaria)
  VALUES ('whatsapp', '+5511900000002', 'comtele', 'fria', 10);
  PERFORM pv.confere('provedor de outro canal é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM pv.confere('provedor de outro canal é recusado (23001)',
    SQLSTATE = '23001', SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- Múltiplas contas do mesmo provedor
-- ---------------------------------------------------------------------------

INSERT INTO sender_accounts
  (canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, config) VALUES
  ('whatsapp','5511988880001','Comercial SP','gupshup','morna',1000,
   '{"app_name":"afinix-comercial","source":"5511988880001"}'::jsonb),
  ('whatsapp','5511988880002','Retenção','gupshup','morna',1000,
   '{"app_name":"afinix-retencao","source":"5511988880002"}'::jsonb),
  ('whatsapp','5511988880003','Prospecção fria','gupshup','fria',200,
   '{"app_name":"afinix-fria","source":"5511988880003"}'::jsonb);

SELECT pv.confere('três contas da Gupshup convivem como remetentes distintos',
  (SELECT count(*) = 3 FROM sender_accounts WHERE provedor = 'gupshup'));

SELECT pv.confere('cada conta carrega a sua app, não uma global',
  (SELECT count(DISTINCT config ->> 'app_name') = 3
     FROM sender_accounts WHERE provedor = 'gupshup'));

-- D4 continua valendo por cima do provedor: o pool morno e o frio não se
-- misturam nem usando a mesma Gupshup.
SELECT pv.confere('a mesma Gupshup serve pool morno e frio sem misturar',
  (SELECT count(*) = 2 FROM remetentes_disponiveis(tenant_padrao(), 'whatsapp', 'morna')
     WHERE provedor = 'gupshup')
  AND (SELECT count(*) = 1 FROM remetentes_disponiveis(tenant_padrao(), 'whatsapp', 'fria')
     WHERE provedor = 'gupshup'));

-- ---------------------------------------------------------------------------
-- D31: provedor que não sabe enviar não é opção de envio
-- ---------------------------------------------------------------------------
--
-- `tem_adapter` existia desde o D17 e ninguém em SQL lia. O sintoma não era
-- erro, era passo queimado: o roteador escolhia a conta, a mensagem nascia, a
-- cadência avançava, e a falha só aparecia no despachante — com o health score
-- de uma conta boa caindo por um provedor que nunca soube enviar.

INSERT INTO sender_accounts
  (id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, config) VALUES
  ('ff000000-0000-0000-0000-000000000001','email','resgate@exemplo.com.br','Sem adapter',
   'smtp','morna',300,'{"host":"smtp.exemplo.com.br","porta":"587","usuario":"r"}'::jsonb),
  ('ff000000-0000-0000-0000-000000000002','email','frio@exemplo.com.br','Com adapter',
   'resend','fria',300,'{"assunto_padrao":"Plano de saúde"}'::jsonb);

SELECT pv.confere('conta em provedor sem adapter fica fora do pool',
  NOT EXISTS (SELECT 1 FROM remetentes_disponiveis(tenant_padrao(), 'email', 'morna')),
  (SELECT string_agg(provedor, ', ')
     FROM remetentes_disponiveis(tenant_padrao(), 'email', 'morna')));

SELECT pv.confere('e a conta do provedor que envia continua no pool',
  (SELECT count(*) = 1 FROM remetentes_disponiveis(tenant_padrao(), 'email', 'fria')
    WHERE provedor = 'resend'));

-- Cadastrar continua permitido: os chips do legado apontam para provedores que
-- podem não ter adapter no dia do backfill, e foi por isso que a Evolution
-- ficou no catálogo (D22). Quem filtra é o pool, não a chave estrangeira.
SELECT pv.confere('cadastrar a conta continua permitido, só enviar é que não',
  (SELECT count(*) = 1 FROM sender_accounts WHERE provedor = 'smtp'));

-- Provedor desligado no catálogo depois das contas criadas: o gatilho só olha
-- o INSERT, então sem isto a conta seguia sendo escolhida.
UPDATE channel_provider_catalog SET ativo = false WHERE slug = 'resend';

SELECT pv.confere('provedor desligado no catálogo também sai do pool',
  NOT EXISTS (SELECT 1 FROM remetentes_disponiveis(tenant_padrao(), 'email', 'fria')));

UPDATE channel_provider_catalog SET ativo = true WHERE slug = 'resend';

-- ---------------------------------------------------------------------------
-- Segredo não tem onde ser gravado errado
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  INSERT INTO sender_accounts
    (canal, identificador, provedor, tipo_permitido, quota_diaria, config)
  VALUES ('whatsapp','5511988880009','gupshup','morna',100,
          '{"api_key":"sk-vazou-aqui"}'::jsonb);
  PERFORM pv.confere('API key em config é recusada', false, 'foi aceita');
EXCEPTION WHEN others THEN
  PERFORM pv.confere('API key em config é recusada (23001)',
    SQLSTATE = '23001', SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  UPDATE sender_accounts SET config = config || '{"api_key":"sk-vazou-no-update"}'::jsonb
   WHERE provedor = 'gupshup' AND apelido = 'Retenção';
  PERFORM pv.confere('segredo também é barrado no UPDATE', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM pv.confere('segredo também é barrado no UPDATE (23001)',
    SQLSTATE = '23001', SQLSTATE || ': ' || SQLERRM);
END;
$$;

SELECT pv.confere('não existe coluna para o segredo em sender_accounts',
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'sender_accounts'
       AND column_name IN ('api_key','token','senha','secret','chave')));

SELECT pv.confere('campo não-secreto passa sem problema',
  (SELECT config ->> 'app_name' = 'afinix-comercial'
     FROM sender_accounts WHERE apelido = 'Comercial SP'));

-- ---------------------------------------------------------------------------
-- Superfície: o catálogo é leitura para todos, escrita só por migration
-- ---------------------------------------------------------------------------

SELECT pv.confere('catálogo de provedores tem RLS ligado',
  (SELECT relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'channel_provider_catalog'));

SELECT pv.confere('catálogo não tem política de escrita',
  (SELECT count(*) = 0 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'channel_provider_catalog'
      AND cmd <> 'SELECT'));

SELECT pv.confere('o gatilho do provedor mora em privado, não em public',
  (SELECT count(*) = 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'privado' AND p.proname = 'validar_provedor_do_remetente'));

\echo ''
\echo '============= PROVEDORES DE CANAL ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM pv.resultado ORDER BY id;
\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM pv.resultado;

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM pv.resultado WHERE NOT ok;
  IF v > 0 THEN RAISE EXCEPTION '% asserção(ões) de provedor falharam', v; END IF;
END;
$$;
