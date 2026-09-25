-- Ler o que responderam (D56).
--
-- O texto da resposta é gravado desde o D48 e nenhuma tela o lia. O que este
-- arquivo sustenta:
--
--   1. o texto chega, com a mensagem que o provocou ao lado — "sim, pode ser"
--      solto não quer dizer nada;
--   2. a resposta que suprimiu a pessoa vem marcada, porque quem olha a caixa
--      pode estar prestes a ligar de volta (D48, D49);
--   3. payload que não é string não vira texto: objeto viraria
--      "[object Object]" e número viraria "0" (a trava do D48);
--   4. só `respondido` entra — entregue, lido e clique não são resposta (D7).

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA rp;
CREATE TABLE rp.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION rp.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO rp.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set tenant '\'42000000-0000-0000-0000-0000000000a0\''

INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Resposta', 'corretora-resposta');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados) VALUES
  ('42000000-0000-0000-0000-0000000000c1', :tenant, 'Resgate Q4', 'morna', 'opt-in', '{whatsapp}'),
  ('42000000-0000-0000-0000-0000000000c2', :tenant, 'Outra campanha', 'morna', 'opt-in', '{whatsapp}');

INSERT INTO flows (id, tenant_id, nome) VALUES ('42000000-0000-0000-0000-0000000000f1', :tenant, 'F');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
VALUES ('42000000-0000-0000-0000-0000000000f2', :tenant, '42000000-0000-0000-0000-0000000000f1', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('42000000-0000-0000-0000-0000000000f3', :tenant, '42000000-0000-0000-0000-0000000000f2',
   1, 'whatsapp', 0, 'Oi, aqui é da Afinix. Você chegou a olhar o plano?'),
  ('42000000-0000-0000-0000-0000000000f4', :tenant, '42000000-0000-0000-0000-0000000000f2',
   2, 'whatsapp', 24, 'Segundo toque');

INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria)
VALUES ('42000000-0000-0000-0000-0000000000e1', :tenant, 'whatsapp', 'uazapi',
        '5511990001111', 'Chip 1', 'morna', 100);

-- Três pessoas: uma que respondeu interessada, uma que pediu para sair, uma
-- que só recebeu e não disse nada.
INSERT INTO contacts (id, tenant_id, nome, origem) VALUES
  ('42000000-0000-0000-0000-0000000000d1', :tenant, 'Marina Souza', 'planilha'),
  ('42000000-0000-0000-0000-0000000000d2', :tenant, 'Joao Lima', 'planilha'),
  ('42000000-0000-0000-0000-0000000000d3', :tenant, 'Ana Muda', 'planilha');
INSERT INTO contact_identities (id, tenant_id, contact_id, canal, valor, valor_norm, origem) VALUES
  ('42000000-0000-0000-0000-00000000a001', :tenant, '42000000-0000-0000-0000-0000000000d1',
   'whatsapp', '+55 11 97000-0001', '5511970000001', 'planilha'),
  ('42000000-0000-0000-0000-00000000a002', :tenant, '42000000-0000-0000-0000-0000000000d2',
   'whatsapp', '+55 11 97000-0002', '5511970000002', 'planilha'),
  ('42000000-0000-0000-0000-00000000a003', :tenant, '42000000-0000-0000-0000-0000000000d3',
   'whatsapp', '+55 11 97000-0003', '5511970000003', 'planilha');

INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id) VALUES
  ('42000000-0000-0000-0000-0000000000b1', :tenant, '42000000-0000-0000-0000-0000000000d1',
   '42000000-0000-0000-0000-0000000000c1', '42000000-0000-0000-0000-0000000000f2'),
  ('42000000-0000-0000-0000-0000000000b2', :tenant, '42000000-0000-0000-0000-0000000000d2',
   '42000000-0000-0000-0000-0000000000c1', '42000000-0000-0000-0000-0000000000f2'),
  ('42000000-0000-0000-0000-0000000000b3', :tenant, '42000000-0000-0000-0000-0000000000d3',
   '42000000-0000-0000-0000-0000000000c2', '42000000-0000-0000-0000-0000000000f2');

INSERT INTO messages (id, tenant_id, enrollment_id, step_id, contact_identity_id,
                      sender_account_id, canal, status, conteudo) VALUES
  ('42000000-0000-0000-0000-00000000aa01', :tenant, '42000000-0000-0000-0000-0000000000b1',
   '42000000-0000-0000-0000-0000000000f3', '42000000-0000-0000-0000-00000000a001',
   '42000000-0000-0000-0000-0000000000e1', 'whatsapp', 'enviado',
   'Oi, aqui é da Afinix. Você chegou a olhar o plano?'),
  ('42000000-0000-0000-0000-00000000aa02', :tenant, '42000000-0000-0000-0000-0000000000b2',
   '42000000-0000-0000-0000-0000000000f3', '42000000-0000-0000-0000-00000000a002',
   '42000000-0000-0000-0000-0000000000e1', 'whatsapp', 'enviado', 'Oi, aqui é da Afinix.'),
  ('42000000-0000-0000-0000-00000000aa03', :tenant, '42000000-0000-0000-0000-0000000000b3',
   '42000000-0000-0000-0000-0000000000f3', '42000000-0000-0000-0000-00000000a003',
   '42000000-0000-0000-0000-0000000000e1', 'whatsapp', 'enviado', 'Oi da outra campanha');

-- Marina responde interessada. Joao pede para sair — e o gatilho do D48
-- suprime. Ana só teve o evento de entrega, que não é resposta.
INSERT INTO message_events (tenant_id, message_id, tipo, payload) VALUES
  (:tenant, '42000000-0000-0000-0000-00000000aa01', 'respondido',
   '{"texto":"Oi! Cheguei sim, quero entender a diferenca de preco"}'::jsonb),
  (:tenant, '42000000-0000-0000-0000-00000000aa02', 'respondido',
   '{"texto":"nao quero mais receber, pare"}'::jsonb),
  (:tenant, '42000000-0000-0000-0000-00000000aa03', 'entregue', '{}'::jsonb);

-- Cenário que consegue falhar (D36): sem resposta nenhuma, tudo abaixo
-- passaria com a função devolvendo lista vazia.
SELECT rp.confere('o cenário tem resposta para ler',
  (SELECT count(*) = 2 FROM respostas_recebidas(:tenant)),
  (SELECT count(*)::text FROM respostas_recebidas(:tenant)));

SELECT rp.confere('o texto da resposta chega inteiro',
  (SELECT texto = 'Oi! Cheguei sim, quero entender a diferenca de preco'
     FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d1'));

-- Sem a pergunta, "sim, pode ser" não quer dizer nada.
SELECT rp.confere('a mensagem que provocou a resposta vem junto',
  (SELECT em_resposta_a = 'Oi, aqui é da Afinix. Você chegou a olhar o plano?'
     FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d1'));

SELECT rp.confere('o passo da cadência vem junto',
  (SELECT passo = 1 FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d1'));

SELECT rp.confere('quem respondeu, por onde e em qual campanha',
  (SELECT contato = 'Marina Souza' AND canal = 'whatsapp'
      AND destino = '+55 11 97000-0001' AND campanha = 'Resgate Q4'
     FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d1'));

-- O que separa um lead de um processo: quem pediu para sair vem marcado.
SELECT rp.confere('quem pediu para sair aparece suprimido',
  (SELECT suprimido FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d2'));

SELECT rp.confere('e com o motivo, não só o sinal',
  (SELECT motivo_supressao IS NOT NULL FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d2'),
  (SELECT coalesce(motivo_supressao, '(nulo)') FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d2'));

SELECT rp.confere('quem respondeu interessado NÃO aparece suprimido',
  (SELECT NOT suprimido FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d1'));

-- Clique e entrega não são resposta (D7).
SELECT rp.confere('evento que não é resposta não entra',
  NOT EXISTS (SELECT 1 FROM respostas_recebidas(:tenant)
               WHERE contact_id = '42000000-0000-0000-0000-0000000000d3'));

-- Escopo por campanha, para a tela da campanha.
SELECT rp.confere('filtrar por campanha devolve só as dela',
  (SELECT count(*) = 2 FROM respostas_recebidas(:tenant, '42000000-0000-0000-0000-0000000000c1')));
SELECT rp.confere('campanha sem resposta devolve vazio',
  (SELECT count(*) = 0 FROM respostas_recebidas(:tenant, '42000000-0000-0000-0000-0000000000c2')));

-- Payload que não é string: a trava do D48, aqui.
INSERT INTO messages (id, tenant_id, enrollment_id, step_id, contact_identity_id,
                      sender_account_id, canal, status, conteudo)
VALUES ('42000000-0000-0000-0000-00000000aa04', :tenant, '42000000-0000-0000-0000-0000000000b3',
        '42000000-0000-0000-0000-0000000000f4', '42000000-0000-0000-0000-00000000a003',
        '42000000-0000-0000-0000-0000000000e1', 'whatsapp', 'enviado', 'Segundo toque');
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
VALUES (:tenant, '42000000-0000-0000-0000-00000000aa04', 'respondido',
        '{"texto":{"body":"veio como objeto"}}'::jsonb);

SELECT rp.confere('a resposta com payload estranho aparece na lista',
  EXISTS (SELECT 1 FROM respostas_recebidas(:tenant)
           WHERE contact_id = '42000000-0000-0000-0000-0000000000d3'));

-- Aparecer sem texto é honesto; aparecer com "[object Object]" seria inventar
-- que a pessoa escreveu isso.
SELECT rp.confere('mas o texto vem nulo, não "[object Object]"',
  (SELECT texto IS NULL FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d3'),
  (SELECT coalesce(texto, '(nulo — correto)') FROM respostas_recebidas(:tenant)
    WHERE contact_id = '42000000-0000-0000-0000-0000000000d3'));

-- Mais recente primeiro: quem abre a caixa quer o que acabou de chegar.
SELECT rp.confere('mais recente primeiro',
  (SELECT array_agg(ocorrido_em ORDER BY ocorrido_em DESC)
        = array_agg(ocorrido_em) FROM respostas_recebidas(:tenant)));

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM rp.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM rp.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM rp.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'respostas: % asserção(ões) falharam', n; END IF;
END;
$$;
