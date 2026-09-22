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
-- D38: o evento casado por id do provedor também não atravessa clientes
-- ---------------------------------------------------------------------------

-- `provider_message_id` é do provedor, não nosso, e nada garante que dois
-- clientes não recebam o mesmo. Antes do D38 a busca era
-- `WHERE provider_message_id = ?` em todos os tenants, pegando a mais nova —
-- e `respondido` encerra a cadência de quem não respondeu. Mesmo dano do D24,
-- na outra via de casamento.

-- O cliente B ganha uma cadência sua, para a colisão ser de verdade.
INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados)
VALUES ('ee000000-0000-0000-0000-0000000000c2','bbbbbbbb-0000-0000-0000-00000000000b',
        'Fria da B','fria','legítimo interesse','{whatsapp}');
INSERT INTO flows (id, tenant_id, nome)
VALUES ('ee000000-0000-0000-0000-0000000000f3','bbbbbbbb-0000-0000-0000-00000000000b','Fria da B');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
VALUES ('ee000000-0000-0000-0000-0000000000f4','bbbbbbbb-0000-0000-0000-00000000000b',
        'ee000000-0000-0000-0000-0000000000f3',1);
INSERT INTO flow_steps (tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
VALUES ('bbbbbbbb-0000-0000-0000-00000000000b','ee000000-0000-0000-0000-0000000000f4',
        1,'whatsapp',0,'Olá da B');
INSERT INTO contacts (id, tenant_id, nome, origem) VALUES
  ('ee000000-0000-0000-0000-0000000000a2','bbbbbbbb-0000-0000-0000-00000000000b',
   'Cliente da B','planilha'),
  ('ee000000-0000-0000-0000-0000000000a3','00000000-0000-0000-0000-0000000000aa',
   'Outro da A','planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem) VALUES
  ('bbbbbbbb-0000-0000-0000-00000000000b','ee000000-0000-0000-0000-0000000000a2',
   'whatsapp','+5511970000002','5511970000002','planilha'),
  ('00000000-0000-0000-0000-0000000000aa','ee000000-0000-0000-0000-0000000000a3',
   'whatsapp','+5511970000003','5511970000003','planilha');

DO $$
DECLARE
  v_enr_a uuid; v_enr_b uuid; v_msg_a uuid; v_msg_b uuid; v_ok boolean;
  v_chip_a uuid := 'ee000000-0000-0000-0000-000000000001';
  v_chip_b uuid := 'ee000000-0000-0000-0000-0000000000b1';
BEGIN
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id, next_run_at)
  VALUES ('bbbbbbbb-0000-0000-0000-00000000000b','ee000000-0000-0000-0000-0000000000a2',
          'ee000000-0000-0000-0000-0000000000c2','ee000000-0000-0000-0000-0000000000f4',
          now() - interval '1 minute')
  RETURNING id INTO v_enr_b;

  INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id,
                        sender_account_id, canal, status, conteudo, provider_message_id)
  SELECT 'bbbbbbbb-0000-0000-0000-00000000000b', v_enr_b, fs.id, ci.id, v_chip_b,
         'whatsapp', 'enviado', 'Olá da B', 'PROV-COLISAO'
    FROM flow_steps fs, contact_identities ci
   WHERE fs.flow_version_id = 'ee000000-0000-0000-0000-0000000000f4'
     AND ci.contact_id = 'ee000000-0000-0000-0000-0000000000a2'
  RETURNING id INTO v_msg_b;

  -- O cliente A ganha uma mensagem própria para esta colisão, em vez de
  -- reaproveitar a do cenário de cima: aquela já foi respondida e encerrada
  -- pelos testes do D24, e um teste que depende do estado deixado por outro
  -- falha por motivo que não é o dele.
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id, next_run_at)
  VALUES ('00000000-0000-0000-0000-0000000000aa','ee000000-0000-0000-0000-0000000000a3',
          'ee000000-0000-0000-0000-0000000000c1','ee000000-0000-0000-0000-0000000000f2',
          now() - interval '1 minute')
  RETURNING id INTO v_enr_a;

  INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id,
                        sender_account_id, canal, status, conteudo, provider_message_id)
  SELECT '00000000-0000-0000-0000-0000000000aa', v_enr_a, fs.id, ci.id, v_chip_a,
         'whatsapp', 'enviado', 'Olá da A', 'PROV-COLISAO'
    FROM flow_steps fs, contact_identities ci
   WHERE fs.flow_version_id = 'ee000000-0000-0000-0000-0000000000f2' AND fs.ordem = 1
     AND ci.contact_id = 'ee000000-0000-0000-0000-0000000000a3'
  RETURNING id INTO v_msg_a;

  -- Chamar a função e conferir o efeito dela têm que ser instruções
  -- separadas. Numa expressão só, o `EXISTS` ao lado enxerga o snapshot do
  -- início da instrução e não vê a linha que a função acabou de gravar — o
  -- teste falhava com a função certa.
  v_ok := registrar_evento_provedor(v_chip_a, 'PROV-COLISAO', 'entregue');
  PERFORM wh.confere('D38: o chip de A casa com a mensagem de A, não com a de B',
    v_ok
    AND EXISTS (SELECT 1 FROM message_events WHERE message_id = v_msg_a AND tipo = 'entregue')
    AND NOT EXISTS (SELECT 1 FROM message_events WHERE message_id = v_msg_b));

  v_ok := registrar_evento_provedor(v_chip_b, 'PROV-COLISAO', 'entregue');
  PERFORM wh.confere('D38: o chip de B casa com a mensagem de B',
    v_ok
    AND EXISTS (SELECT 1 FROM message_events WHERE message_id = v_msg_b AND tipo = 'entregue'));

  -- A negativa que importa: id que só existe no outro cliente não é alcançável.
  UPDATE messages SET provider_message_id = 'SO-DO-A' WHERE id = v_msg_a;
  PERFORM wh.confere('D38: chip de B não alcança id que só existe em A',
    registrar_evento_provedor(v_chip_b, 'SO-DO-A', 'respondido') = false);

  PERFORM wh.confere('D38: e a cadência de A segue de pé',
    (SELECT e.status FROM enrollments e
      JOIN messages m ON m.enrollment_id = e.id WHERE m.id = v_msg_a) <> 'encerrado');

END;
$$;

-- Em bloco próprio, de propósito: um EXCEPTION envolvendo o bloco inteiro
-- desfaz tudo o que ele já tinha feito, e as asserções anteriores somem sem
-- avisar. Foi o que aconteceu na primeira versão deste teste — quatro
-- `wh.confere` registrados viraram um.
DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    PERFORM registrar_evento_provedor(
      '00000000-0000-0000-0000-0000000000ff', 'SO-DO-A', 'entregue');
    v_erro := '(não levantou)';
  EXCEPTION WHEN no_data_found THEN v_erro := 'no_data_found';
  END;
  PERFORM wh.confere('D38: chip inexistente levanta em vez de adivinhar tenant',
    v_erro = 'no_data_found', v_erro);
END;
$$;

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

-- ---------------------------------------------------------------------------
-- Configurar pelo painel do produto (D26)
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER passa por cima da RLS. Então quem passa por cima tem que
-- perguntar, em código, o que a política perguntaria — e é isto que estes
-- testes verificam, porque é o tipo de coisa que some numa refatoração.

-- Os usuários: um administra, outro só opera.
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  ('00000000-0000-0000-0000-0000000000aa','11111111-aaaa-0000-0000-00000000000a','dono'),
  ('00000000-0000-0000-0000-0000000000aa','33333333-aaaa-0000-0000-00000000000a','operador');

DO $$
DECLARE v_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"33333333-aaaa-0000-0000-00000000000a"}', true);
  v_id := salvar_servidor_provedor('00000000-0000-0000-0000-0000000000aa','uazapi',
            'Servidor do operador','https://x.uazapi.com','tok');
  PERFORM wh.confere('operador não configura provedor', false, 'configurou');
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM wh.confere('operador não configura provedor (42501)', true);
WHEN others THEN
  PERFORM wh.confere('operador não configura provedor', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
DECLARE v_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-aaaa-0000-0000-00000000000a"}', true);
  -- Sem Vault local, quem administra chega até a escrita do segredo e para
  -- lá — que é exatamente um passo depois da checagem de permissão.
  v_id := salvar_servidor_provedor('00000000-0000-0000-0000-0000000000aa','uazapi',
            'Servidor do dono','https://y.uazapi.com','tok');
  PERFORM wh.confere('quem administra passa da checagem de permissão', false, 'sem Vault deveria parar');
EXCEPTION WHEN feature_not_supported THEN
  PERFORM wh.confere('quem administra passa da checagem de permissão', true);
WHEN insufficient_privilege THEN
  PERFORM wh.confere('quem administra passa da checagem de permissão', false, 'barrou quem pode');
END;
$$;

DO $$
DECLARE v_id uuid;
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-aaaa-0000-0000-00000000000a"}', true);
  v_id := salvar_servidor_provedor('00000000-0000-0000-0000-0000000000aa','inventado',
            'S','https://z.com','tok');
  PERFORM wh.confere('provedor fora do catálogo é recusado', false, 'aceitou');
EXCEPTION WHEN no_data_found THEN
  PERFORM wh.confere('provedor fora do catálogo é recusado', true);
WHEN others THEN
  PERFORM wh.confere('provedor fora do catálogo é recusado', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- Sem token, um servidor já existente não perde o que tem: o campo volta vazio
-- na tela porque segredo não é legível, e reenviar vazio não pode apagar a
-- credencial de um servidor que está funcionando.
UPDATE provider_servers SET admin_secret_id = '00000000-0000-0000-0000-000000000099'
 WHERE id = 'ee000000-0000-0000-0000-0000000000d1';

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-aaaa-0000-0000-00000000000a"}', true);
  PERFORM salvar_servidor_provedor('00000000-0000-0000-0000-0000000000aa','uazapi',
            'UAZAPI Afinix','https://novo.uazapi.com', NULL);
END;
$$;

SELECT wh.confere('editar sem reenviar token preserva o segredo',
  (SELECT admin_secret_id = '00000000-0000-0000-0000-000000000099'
      AND base_url = 'https://novo.uazapi.com'
     FROM provider_servers WHERE id = 'ee000000-0000-0000-0000-0000000000d1'));

SELECT wh.confere('editar não duplica servidor',
  (SELECT count(*) = 1 FROM provider_servers
    WHERE tenant_id = '00000000-0000-0000-0000-0000000000aa' AND nome = 'UAZAPI Afinix'));

-- Credencial de remetente: o catálogo decide o que é campo do provedor.
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-aaaa-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_remetente('ee000000-0000-0000-0000-000000000001',
    '{"token":"t","inventado":"x"}'::jsonb);
  PERFORM wh.confere('campo que não existe no provedor é recusado', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM wh.confere('campo que não existe no provedor é recusado', true);
WHEN others THEN
  PERFORM wh.confere('campo que não existe no provedor é recusado', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"33333333-aaaa-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_remetente('ee000000-0000-0000-0000-000000000001', '{"token":"t"}'::jsonb);
  PERFORM wh.confere('operador não troca credencial de remetente', false, 'trocou');
EXCEPTION WHEN insufficient_privilege THEN
  PERFORM wh.confere('operador não troca credencial de remetente', true);
WHEN others THEN
  PERFORM wh.confere('operador não troca credencial de remetente', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- Obrigatório é obrigatório no banco, não só na tela (D28/D30). `base_url` é
-- campo obrigatório da UAZAPI, e sem esta checagem o chip nascia com uma
-- credencial pela metade que só falharia no primeiro disparo.
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-aaaa-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_remetente('ee000000-0000-0000-0000-000000000001',
    '{"token":"t"}'::jsonb);
  PERFORM wh.confere('campo obrigatório em branco é recusado', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM wh.confere('campo obrigatório em branco é recusado', true);
WHEN others THEN
  PERFORM wh.confere('campo obrigatório em branco é recusado', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- E o segredo também: conta sem token guardado não passa mandando token vazio.
DO $$
BEGIN
  PERFORM set_config('request.jwt.claims','{"sub":"11111111-aaaa-0000-0000-00000000000a"}', true);
  PERFORM salvar_credencial_remetente('ee000000-0000-0000-0000-000000000001',
    '{"token":"","base_url":"https://uaz.exemplo.com"}'::jsonb);
  PERFORM wh.confere('segredo obrigatório em branco sem valor guardado é recusado', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM wh.confere('segredo obrigatório em branco sem valor guardado é recusado', true);
WHEN others THEN
  PERFORM wh.confere('segredo obrigatório em branco sem valor guardado é recusado',
                     false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

SELECT set_config('request.jwt.claims','', true);

SELECT wh.confere('as duas funções de configuração são API de usuário logado',
  (SELECT count(*) = 2 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('salvar_servidor_provedor','salvar_credencial_remetente')
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')));

SELECT wh.confere('e continuam fechadas para anônimo',
  NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('salvar_servidor_provedor','salvar_credencial_remetente')
       AND has_function_privilege('anon', p.oid, 'EXECUTE')));

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
