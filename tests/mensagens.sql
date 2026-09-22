-- Ler o que o motor compôs (D42).
--
-- O que este arquivo sustenta: o texto renderizado chega à tela, e o rastro
-- que uma variável vazia deixa é marcado em vez de escondido.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA mc;
CREATE TABLE mc.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION mc.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO mc.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t    '00000000-0000-0000-0000-0000000000aa'
\set camp 'ad000000-0000-0000-0000-000000000001'
\set fv   'ad000000-0000-0000-0000-000000000003'

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES (:'camp','Resgate','morna','opt-in','{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('ad000000-0000-0000-0000-000000000002','F');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES (:'fv','ad000000-0000-0000-0000-000000000002',1);
-- Template com duas variáveis: é o formato real dos modelos do catálogo.
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:'fv',1,'whatsapp',0,'Olá {{nome}}, vi que você é de {{cidade}}.');

INSERT INTO sender_accounts (id, canal, identificador, apelido, provedor,
                             tipo_permitido, quota_diaria, config)
VALUES ('ad000000-0000-0000-0000-0000000000a1','whatsapp','+5511900000001','Chip',
        'gupshup','morna',200,'{"app_name":"a","source":"1"}'::jsonb);

-- Duas pessoas: uma completa, uma como a planilha fria entrega — sem nome e
-- sem metadados.
DO $$
DECLARE v uuid;
BEGIN
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15994440001","valor_norm":"5515994440001"}]'::jsonb,
    'Marina', NULL, '{"cidade":"Santos"}'::jsonb);
  PERFORM inscrever(v,'ad000000-0000-0000-0000-000000000001',
                    'ad000000-0000-0000-0000-000000000003', now() - interval '1 minute');

  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15994440002","valor_norm":"5515994440002"}]'::jsonb);
  PERFORM inscrever(v,'ad000000-0000-0000-0000-000000000001',
                    'ad000000-0000-0000-0000-000000000003', now() - interval '1 minute');
END;
$$;

SELECT count(*) FROM processar_vencidos(10, 'simulado');

SELECT mc.confere('as duas mensagens foram compostas',
  (SELECT count(*) FROM mensagens_da_campanha(:'t', :'camp')) = 2,
  (SELECT count(*)::text FROM mensagens_da_campanha(:'t', :'camp')));

SELECT mc.confere('o texto renderizado chega inteiro, com as variáveis trocadas',
  (SELECT conteudo FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina')
    = 'Olá Marina, vi que você é de Santos.',
  (SELECT conteudo FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina'));

-- O achado que motivou a função: sem nome e sem cidade, o template deixa
-- pontuação órfã. `renderizar` está certo em não mandar `{{nome}}` cru — mas
-- ninguém escreve "Olá ," à mão.
SELECT mc.confere('contato sem nome produz pontuação órfã, e o texto mostra isso',
  (SELECT conteudo FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = '(sem nome)')
    = 'Olá , vi que você é de .',
  (SELECT conteudo FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = '(sem nome)'));

SELECT mc.confere('e a suspeita é marcada em quem tem buraco',
  (SELECT buraco FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = '(sem nome)'));

SELECT mc.confere('e NÃO é marcada em quem está completo',
  NOT (SELECT buraco FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina'),
  (SELECT conteudo FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina'));

SELECT mc.confere('a mensagem carrega canal, destino, passo, status e remetente',
  (SELECT canal FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina') = 'whatsapp'
  AND (SELECT destino FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina') = '15994440001'
  AND (SELECT passo FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina') = 1
  AND (SELECT status FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina') = 'simulado'
  AND (SELECT remetente FROM mensagens_da_campanha(:'t', :'camp') WHERE contato = 'Marina') = 'Chip');

-- ---------------------------------------------------------------------------
-- Isolamento e superfície
-- ---------------------------------------------------------------------------

INSERT INTO tenants (id, nome, slug)
VALUES ('bbbbbbbb-0000-0000-0000-00000000000b','Corretora B','corretora-b');

SELECT mc.confere('outro cliente não vê as mensagens desta campanha',
  (SELECT count(*) FROM mensagens_da_campanha(
     'bbbbbbbb-0000-0000-0000-00000000000b', :'camp')) = 0);

SELECT mc.confere('o teto de 200 existe',
  (SELECT prosrc LIKE '%least(coalesce(p_limite, 50), 200)%' FROM pg_proc
    WHERE proname = 'mensagens_da_campanha'));

SELECT mc.confere('o limite pedido é respeitado',
  (SELECT count(*) FROM mensagens_da_campanha(:'t', :'camp', 1)) = 1);

SELECT mc.confere('anon não lê mensagem de ninguém',
  NOT has_function_privilege('anon', 'mensagens_da_campanha(uuid, uuid, integer)', 'EXECUTE'));

SELECT mc.confere('authenticated lê',
  has_function_privilege('authenticated', 'mensagens_da_campanha(uuid, uuid, integer)', 'EXECUTE'));

SELECT mc.confere('é STABLE e com search_path fixo',
  (SELECT provolatile FROM pg_proc WHERE proname = 'mensagens_da_campanha') = 's'
  AND (SELECT proconfig FROM pg_proc WHERE proname = 'mensagens_da_campanha')
      @> ARRAY['search_path=public, privado']);

\echo ''
\echo '============= MENSAGENS COMPOSTAS ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM mc.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM mc.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM mc.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'mensagens: % asserções falharam',
      (SELECT count(*) FROM mc.resultado WHERE NOT ok);
  END IF;
END;
$$;
