-- Webhook por chip, casamento por número e provisionamento.
--
-- O que este arquivo sustenta: a invariante 4 passa a valer no canal não
-- oficial, onde a resposta não cita a nossa mensagem (D23). Antes disso a
-- pessoa respondia, o motor não ficava sabendo e a cadência seguia tocando.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA wh;
CREATE TABLE wh.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION wh.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO wh.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

-- ---------------------------------------------------------------------------
-- Cenário: uma campanha fria de dois toques, num chip UAZAPI
-- ---------------------------------------------------------------------------

INSERT INTO sender_accounts
  (id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria) VALUES
  ('ee000000-0000-0000-0000-000000000001','whatsapp','5511988880001','Chip A','uazapi','fria',100),
  ('ee000000-0000-0000-0000-000000000002','whatsapp','5511988880002','Chip B','uazapi','fria',100);

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('ee000000-0000-0000-0000-0000000000c1','Fria','fria','legítimo interesse','{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('ee000000-0000-0000-0000-0000000000f1','Fria');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES ('ee000000-0000-0000-0000-0000000000f2','ee000000-0000-0000-0000-0000000000f1',1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('ee000000-0000-0000-0000-0000000000f2',1,'whatsapp',0,'Olá {{nome}}'),
  ('ee000000-0000-0000-0000-0000000000f2',2,'whatsapp',96,'{{nome}}, ainda faz sentido?');

INSERT INTO contacts (id, nome, origem)
VALUES ('ee000000-0000-0000-0000-0000000000a1','Vera Castro','planilha');
INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
VALUES ('ee000000-0000-0000-0000-0000000000a1','whatsapp','+5511970000001','5511970000001','planilha');

SELECT inscrever('ee000000-0000-0000-0000-0000000000a1',
                 'ee000000-0000-0000-0000-0000000000c1',
                 'ee000000-0000-0000-0000-0000000000f2') AS e \gset
SELECT count(*) FROM processar_vencidos(10, 'real') \gset passadas_

SELECT wh.confere('o primeiro toque saiu',
  (SELECT count(*) = 1 FROM messages WHERE enrollment_id = :'e'));

-- ---------------------------------------------------------------------------
-- Cada chip tem o seu endpoint
-- ---------------------------------------------------------------------------

SELECT wh.confere('cada conta nasce com um token de webhook próprio',
  (SELECT count(DISTINCT webhook_token) = count(*) FROM sender_accounts)
  AND NOT EXISTS (SELECT 1 FROM sender_accounts WHERE webhook_token IS NULL));

SELECT wh.confere('o token resolve chip, tenant e provedor',
  (SELECT r.sender_id = 'ee000000-0000-0000-0000-000000000001'
      AND r.provedor = 'uazapi' AND r.canal = 'whatsapp'
     FROM sender_accounts sa, resolver_webhook(sa.webhook_token) r
    WHERE sa.id = 'ee000000-0000-0000-0000-000000000001'));

SELECT wh.confere('token desconhecido não resolve nada',
  (SELECT count(*) = 0 FROM resolver_webhook('99999999-9999-9999-9999-999999999999')));

DO $$
BEGIN
  UPDATE sender_accounts SET webhook_token =
    (SELECT webhook_token FROM sender_accounts WHERE id = 'ee000000-0000-0000-0000-000000000002')
   WHERE id = 'ee000000-0000-0000-0000-000000000001';
  PERFORM wh.confere('dois chips não compartilham endpoint', false, 'aceitou token repetido');
EXCEPTION WHEN others THEN
  PERFORM wh.confere('dois chips não compartilham endpoint (23505)',
    SQLSTATE = '23505', SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- Resposta sem citação encerra a cadência — o buraco do D23
-- ---------------------------------------------------------------------------

SELECT wh.confere('antes da resposta o enrollment está ativo',
  (SELECT status = 'ativo' FROM enrollments WHERE id = :'e'));

SELECT wh.confere('resposta pelo número é aceita',
  registrar_resposta_por_numero('ee000000-0000-0000-0000-000000000001',
                                '5511970000001', now(), '{}'::jsonb));

SELECT wh.confere('INVARIANTE 4 vale no canal não oficial: a resposta encerrou',
  (SELECT status = 'encerrado' AND motivo_encerramento = 'resposta'
     FROM enrollments WHERE id = :'e'),
  (SELECT status || '/' || coalesce(motivo_encerramento::text,'-')
     FROM enrollments WHERE id = :'e'));

SELECT wh.confere('o encerramento saiu do gatilho, não de um caminho paralelo',
  (SELECT count(*) = 1 FROM message_events
    WHERE tipo = 'respondido' AND payload ->> 'casado_por' = 'numero'));

-- Um chip pode receber a resposta de mensagem que outro chip mandou: o pool
-- roda entre um toque e outro, e quem responde responde para a pessoa.
SELECT wh.confere('chip B também resolve resposta de contato do mesmo tenant',
  registrar_resposta_por_numero('ee000000-0000-0000-0000-000000000002',
                                '5511970000001', now(), '{}'::jsonb));

SELECT wh.confere('número que nunca recebeu nada não é resposta a nada',
  NOT registrar_resposta_por_numero('ee000000-0000-0000-0000-000000000001',
                                    '5511999999999', now(), '{}'::jsonb));

SELECT wh.confere('o próprio eco é descartado pela autoria',
  NOT registrar_resposta_por_numero('ee000000-0000-0000-0000-000000000001',
        '5511970000001', now(), '{"autoria":"motor-prospeccao"}'::jsonb));

-- ---------------------------------------------------------------------------
-- Isolamento entre clientes continua valendo
-- ---------------------------------------------------------------------------

INSERT INTO tenants (id, nome, slug)
VALUES ('bbbbbbbb-0000-0000-0000-00000000000b','Corretora B','corretora-b');
INSERT INTO sender_accounts
  (id, tenant_id, canal, identificador, provedor, tipo_permitido, quota_diaria)
VALUES ('ee000000-0000-0000-0000-0000000000b1','bbbbbbbb-0000-0000-0000-00000000000b',
        'whatsapp','5511988889999','uazapi','fria',100);

-- Mesmo telefone, outro cliente, que nunca mandou nada para ele.
SELECT wh.confere('chip de outro cliente não encerra enrollment alheio',
  NOT registrar_resposta_por_numero('ee000000-0000-0000-0000-0000000000b1',
                                    '5511970000001', now(), '{}'::jsonb));

-- ---------------------------------------------------------------------------
-- Superfície
-- ---------------------------------------------------------------------------

SELECT wh.confere('nada disto é chamável por usuário logado ou anônimo',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('resolver_webhook','registrar_resposta_por_numero',
                         'segredo_do_remetente','segredo_do_servidor',
                         'criar_remetente_provisionado')
       AND (has_function_privilege('anon', p.oid, 'EXECUTE')
         OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
  (SELECT string_agg(p.proname, ', ') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('resolver_webhook','registrar_resposta_por_numero',
      'segredo_do_remetente','segredo_do_servidor','criar_remetente_provisionado')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')));

SELECT wh.confere('não existe coluna de texto para o token de admin do servidor',
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_name = 'provider_servers'
       AND column_name IN ('admin_token','token','senha','admintoken')));

SELECT wh.confere('servidor só é visível para quem administra',
  (SELECT count(*) = 2 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'provider_servers'
      AND qual LIKE '%pode_administrar%'));

-- ---------------------------------------------------------------------------
-- Provisionamento
-- ---------------------------------------------------------------------------

INSERT INTO provider_servers (id, provedor, nome, base_url)
VALUES ('ee000000-0000-0000-0000-0000000000d1','uazapi','UAZAPI Afinix',
        'https://afinix.uazapi.com');

DO $$
BEGIN
  INSERT INTO provider_servers (provedor, nome, base_url)
  VALUES ('uazapi','Sem protocolo','afinix.uazapi.com');
  PERFORM wh.confere('URL sem protocolo é recusada', false, 'aceitou');
EXCEPTION WHEN others THEN
  PERFORM wh.confere('URL sem protocolo é recusada (23514)',
    SQLSTATE = '23514', SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- Sem Vault local a criação recusa — e recusar é o certo: o segredo não tem
-- onde ser guardado, e gravar a conta sem ele deixaria chip que não envia.
DO $$
DECLARE v record;
BEGIN
  SELECT * INTO v FROM criar_remetente_provisionado(
    'ee000000-0000-0000-0000-0000000000d1','Chip novo','5511988880003','fria',50,
    '{"token":"t","base_url":"https://afinix.uazapi.com"}'::jsonb, gen_random_uuid());
  PERFORM wh.confere('sem Vault, provisionar recusa em vez de gravar conta sem segredo',
    false, 'gravou');
EXCEPTION WHEN feature_not_supported THEN
  PERFORM wh.confere('sem Vault, provisionar recusa em vez de gravar conta sem segredo', true);
END;
$$;

SELECT wh.confere('a recusa não deixou conta pela metade',
  NOT EXISTS (SELECT 1 FROM sender_accounts WHERE identificador = '5511988880003'));

SELECT wh.confere('servidor de provedor que não hospeda instância é erro de cadastro, não de envio',
  (SELECT NOT EXISTS (SELECT 1 FROM provider_servers ps
     JOIN channel_provider_catalog c ON c.slug = ps.provedor
    WHERE c.slug IN ('gupshup','meta_cloud'))));

\echo ''
\echo '============= WEBHOOK POR CHIP ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM wh.resultado ORDER BY id;
\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM wh.resultado;

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM wh.resultado WHERE NOT ok;
  IF v > 0 THEN RAISE EXCEPTION '% asserção(ões) de webhook falharam', v; END IF;
END;
$$;
