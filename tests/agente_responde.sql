-- O agente responde sozinho (D69).
--
-- O teste que o §8 de PROPOSTA-CONVERSA.md exigia antes de qualquer linha:
-- uma inscrição encerrada por resposta, uma mensagem de cadência pendente
-- (tem de ser cancelada) e uma do agente (tem de sair), as duas na MESMA
-- passada do despacho. É a distinção que o D40 não fazia. Em volta dele, o
-- que pode dar errado na conversa:
--
--   1. o rascunho vira UMA mensagem, pela conta que conversa, pagando quota;
--   2. agente não autônomo deixa o texto para uma pessoa, como no D66;
--   3. resposta nova aposenta a mensagem que respondia à anterior;
--   4. a janela de 24h, na criação e na saída;
--   5. supressão depois de enfileirar: cancelada, e devolvida com o motivo;
--   6. conta fora do ar SEGURA a mensagem do agente — não troca de chip;
--   7. o chip que recebeu a resposta é o que responde;
--   8. simulado é simulado;
--   9. a mensagem tem passo OU rascunho, e a tela da campanha a mostra;
--  10. a grade: a tela liga e desliga a autonomia, e não enfileira nada.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ar;
CREATE TABLE ar.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA ar TO authenticated;
GRANT INSERT, SELECT ON ar.resultado TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ar TO authenticated;
CREATE FUNCTION ar.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ar.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION ar.confere(text, boolean, text) TO authenticated;
CREATE FUNCTION ar.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE; END; $$;
GRANT EXECUTE ON FUNCTION ar.sqlstate_de(text) TO authenticated;

\set tenant '\'ae000000-0000-0000-0000-0000000000a0\''
\set oper   '\'ae000000-0000-0000-0000-0000000000a2\''
\set camp   '\'ae000000-0000-0000-0000-0000000000c1\''
\set versao '\'ae000000-0000-0000-0000-0000000000f2\''
\set passo1 '\'ae000000-0000-0000-0000-0000000000f3\''
\set passo2 '\'ae000000-0000-0000-0000-0000000000f4\''
\set chipa  '\'ae000000-0000-0000-0000-0000000000e1\''
\set chipb  '\'ae000000-0000-0000-0000-0000000000e2\''
\set agente '\'ae000000-0000-0000-0000-0000000000a9\''

INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Conversa', 'corretora-conversa');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES (:tenant, :oper, 'operador');

INSERT INTO ai_credentials (id, tenant_id, nome, provedor, modelo)
VALUES ('ae000000-0000-0000-0000-0000000000d1', :tenant, 'Claude', 'anthropic', 'claude-sonnet-5');
INSERT INTO agents (id, tenant_id, nome, canal, papel, descricao, instrucoes, ai_credential_id)
VALUES (:agente, :tenant, 'Lia', 'whatsapp', 'SDR', 'Reativa quem cotou.',
        repeat('Seja breve, cordial e pergunte a idade das vidas antes de falar de valor. ', 3),
        'ae000000-0000-0000-0000-0000000000d1');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados)
VALUES (:camp, :tenant, 'Conversa', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id) VALUES (:tenant, :camp, 'whatsapp', :agente);
INSERT INTO flows (id, tenant_id, nome) VALUES ('ae000000-0000-0000-0000-0000000000f1', :tenant, 'F');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao) VALUES (:versao, :tenant, 'ae000000-0000-0000-0000-0000000000f1', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  (:passo1, :tenant, :versao, 1, 'whatsapp', 0, 'Oi'),
  (:passo2, :tenant, :versao, 2, 'whatsapp', 24, 'Ainda por aí?');
UPDATE campaigns SET flow_version_id = :versao WHERE id = :camp;
INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria) VALUES
  (:chipa, :tenant, 'whatsapp', 'uazapi', '5511990004441', 'Chip A', 'morna', 100),
  (:chipb, :tenant, 'whatsapp', 'uazapi', '5511990004442', 'Chip B', 'morna', 100);

-- Uma pessoa por caso. Cria contato, identidade, inscrição, o primeiro toque
-- (enviado pelo chip A), o segundo toque pendente (é a mensagem de cadência que
-- a resposta tem de matar) e a resposta. Devolve o id do evento da resposta.
CREATE FUNCTION ar.pessoa(p_n int, p_ha interval DEFAULT '0'::interval, p_chip uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_c uuid; v_i uuid; v_e uuid; v_m uuid; v_ev uuid;
BEGIN
  v_c := ('ae000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid;
  INSERT INTO contacts (id, tenant_id, nome, origem)
  VALUES (v_c, 'ae000000-0000-0000-0000-0000000000a0', 'Pessoa ' || p_n, 'planilha');
  INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
  VALUES ('ae000000-0000-0000-0000-0000000000a0', v_c, 'whatsapp', '55119800002' || lpad(p_n::text, 2, '0'),
          '55119800002' || lpad(p_n::text, 2, '0'), 'planilha') RETURNING id INTO v_i;
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id, passo_atual)
  VALUES ('ae000000-0000-0000-0000-0000000000a0', v_c, 'ae000000-0000-0000-0000-0000000000c1',
          'ae000000-0000-0000-0000-0000000000f2', 1)
  RETURNING id INTO v_e;
  INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status,
                        conteudo, criado_em)
  VALUES ('ae000000-0000-0000-0000-0000000000a0', v_e, 'ae000000-0000-0000-0000-0000000000f3', v_i,
          'ae000000-0000-0000-0000-0000000000e1', 'whatsapp', 'enviado', 'Oi, ainda pensa no plano?',
          now() - p_ha - interval '2 hours')
  RETURNING id INTO v_m;
  INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status,
                        conteudo, criado_em)
  VALUES ('ae000000-0000-0000-0000-0000000000a0', v_e, 'ae000000-0000-0000-0000-0000000000f4', v_i,
          'ae000000-0000-0000-0000-0000000000e1', 'whatsapp', 'pendente', 'Ainda por aí?',
          now() - p_ha - interval '1 hour');
  INSERT INTO message_events (tenant_id, message_id, tipo, payload, ocorrido_em)
  VALUES ('ae000000-0000-0000-0000-0000000000a0', v_m, 'respondido',
          jsonb_build_object('texto', 'quanto fica para dois?')
            || CASE WHEN p_chip IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('chip', p_chip) END,
          now() - p_ha)
  RETURNING id INTO v_ev;
  RETURN v_ev;
END; $$;

CREATE FUNCTION ar.c(p_n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT ('ae000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid $$;

-- O que o worker faria depois de compor: grava `pronto` e enfileira.
CREATE FUNCTION ar.responde(p_evento uuid, p_texto text, p_modo text DEFAULT 'real') RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM registrar_rascunho(p_evento, 'ae000000-0000-0000-0000-0000000000a9', 'pronto', p_texto, NULL, 'claude-sonnet-5');
  RETURN enfileirar_resposta(p_evento, p_modo);
END; $$;

-- ===========================================================================
-- A fila que o worker lê
-- ===========================================================================

CREATE TABLE ar.ev (n int PRIMARY KEY, evento uuid NOT NULL);
GRANT SELECT ON ar.ev TO authenticated;
INSERT INTO ar.ev VALUES (1, ar.pessoa(1));

SELECT ar.confere('a fila do agente diz que ele é autônomo, e traz o teto do cliente',
  (SELECT autonomo AND teto = 200 AND composicoes_hoje = 0
     FROM respostas_para_o_agente(50) WHERE contact_id = ar.c(1)),
  (SELECT row(autonomo, teto, composicoes_hoje)::text FROM respostas_para_o_agente(50) WHERE contact_id = ar.c(1)));
SELECT ar.confere('a resposta encerrou a inscrição por resposta (invariante 4, intocada)',
  (SELECT status = 'encerrado' AND motivo_encerramento = 'resposta' FROM enrollments WHERE contact_id = ar.c(1)));

-- ===========================================================================
-- 1. O rascunho vira uma mensagem
-- ===========================================================================

CREATE TABLE ar.quota_antes AS SELECT enviados_na_janela AS n FROM sender_accounts WHERE id = :chipa;

SELECT ar.confere('o rascunho pronto de agente autônomo vai para a fila',
  ar.responde((SELECT evento FROM ar.ev WHERE n = 1), 'Que bom! Qual a idade de vocês dois?') = 'fila');

CREATE TABLE ar.msg1 AS
  SELECT m.* FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
   WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 1);

SELECT ar.confere('vira UMA mensagem, sem passo, com o texto do rascunho, pendente',
  (SELECT count(*) = 1 AND bool_and(step_id IS NULL AND status = 'pendente'
          AND conteudo = 'Que bom! Qual a idade de vocês dois?') FROM ar.msg1));
SELECT ar.confere('pela conta que conversa com a pessoa (o chip A)',
  (SELECT sender_account_id = 'ae000000-0000-0000-0000-0000000000e1'::uuid FROM ar.msg1));
SELECT ar.confere('e paga quota, como qualquer mensagem (invariante 3)',
  (SELECT enviados_na_janela FROM sender_accounts WHERE id = :chipa) = (SELECT n + 1 FROM ar.quota_antes));
SELECT ar.confere('o rascunho diz que foi para a fila',
  (SELECT envio = 'fila' AND envio_motivo IS NULL FROM rascunhos
    WHERE message_event_id = (SELECT evento FROM ar.ev WHERE n = 1)));
SELECT ar.confere('enfileirar de novo não cria outra mensagem (invariante 1 da conversa)',
  enfileirar_resposta((SELECT evento FROM ar.ev WHERE n = 1), 'real') = 'fila'
  AND (SELECT count(*) FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
        WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 1)) = 1);

-- O TESTE DO §8: mesma inscrição, mesma passada. A cadência morre, o agente sai.
CREATE TABLE ar.lote1 AS SELECT * FROM reivindicar_pendentes(50);

SELECT ar.confere('NA MESMA PASSADA: a mensagem do agente sai',
  EXISTS (SELECT 1 FROM ar.lote1 WHERE message_id = (SELECT id FROM ar.msg1)),
  (SELECT string_agg(message_id::text, ',') FROM ar.lote1));
SELECT ar.confere('NA MESMA PASSADA: o segundo toque da cadência é cancelado (D40 de hoje)',
  (SELECT m.status = 'cancelado' FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
    WHERE e.contact_id = ar.c(1) AND m.step_id = 'ae000000-0000-0000-0000-0000000000f4'));
SELECT ar.confere('e a do agente sai pela conta que conversa',
  (SELECT sender_id = 'ae000000-0000-0000-0000-0000000000e1'::uuid FROM ar.lote1
    WHERE message_id = (SELECT id FROM ar.msg1)));
SELECT registrar_resultado_envio((SELECT id FROM ar.msg1), true, 'wamid.agente.1', NULL, NULL);

-- ===========================================================================
-- 2. Agente não autônomo: o texto fica com uma pessoa
-- ===========================================================================

INSERT INTO ar.ev VALUES (2, ar.pessoa(2));
UPDATE agents SET autonomo = false WHERE id = :agente;
-- Chamar e conferir em instruções separadas: na mesma, o EXISTS lê o
-- snapshot de antes da chamada (D38).
CREATE TABLE ar.destino (n int PRIMARY KEY, envio text);
GRANT SELECT ON ar.destino TO authenticated;
INSERT INTO ar.destino VALUES (2, ar.responde((SELECT evento FROM ar.ev WHERE n = 2), 'Oi! Me conta a idade de vocês?'));
SELECT ar.confere('desligada a autonomia, o rascunho fica para uma pessoa (D66)',
  (SELECT envio FROM ar.destino WHERE n = 2) = 'pessoa'
  AND NOT EXISTS (SELECT 1 FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
                   WHERE e.contact_id = ar.c(2) AND m.rascunho_id IS NOT NULL)
  AND (SELECT envio = 'pessoa' FROM rascunhos WHERE message_event_id = (SELECT evento FROM ar.ev WHERE n = 2)));
UPDATE agents SET autonomo = true WHERE id = :agente;

-- ===========================================================================
-- 3. A pessoa responde de novo
-- ===========================================================================

INSERT INTO ar.ev VALUES (3, ar.pessoa(3));
SELECT ar.responde((SELECT evento FROM ar.ev WHERE n = 3), 'Qual a idade de vocês?');
-- Antes do despacho, ela manda outra mensagem.
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
SELECT :tenant, m.id, 'respondido', '{"texto":"ah, e meu filho também"}'
  FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
 WHERE e.contact_id = ar.c(3) AND m.step_id = :passo1;

CREATE TABLE ar.lote3 AS SELECT * FROM reivindicar_pendentes(50);
SELECT ar.confere('a mensagem que respondia à resposta antiga NÃO sai',
  NOT EXISTS (SELECT 1 FROM ar.lote3 l JOIN messages m ON m.id = l.message_id
               JOIN enrollments e ON e.id = m.enrollment_id WHERE e.contact_id = ar.c(3)));
SELECT ar.confere('ela é cancelada, e o rascunho volta para uma pessoa com o motivo',
  (SELECT m.status = 'cancelado' AND r.envio = 'devolvido' AND r.envio_motivo LIKE '%respondeu de novo%'
     FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
     JOIN enrollments e ON e.id = m.enrollment_id WHERE e.contact_id = ar.c(3)));
SELECT ar.confere('a resposta nova espera o seu próprio rascunho',
  (SELECT texto = 'ah, e meu filho também' FROM respostas_para_o_agente(50) WHERE contact_id = ar.c(3)));
SELECT ar.confere('chamar de novo não ressuscita a mensagem devolvida',
  (SELECT enfileirar_resposta(me.id, 'real') FROM message_events me
     JOIN messages m ON m.id = me.message_id JOIN enrollments e ON e.id = m.enrollment_id
    WHERE e.contact_id = ar.c(3) AND me.tipo = 'respondido'
    ORDER BY me.ocorrido_em LIMIT 1) = 'devolvido'
  AND (SELECT count(*) FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
        WHERE e.contact_id = ar.c(3) AND m.rascunho_id IS NOT NULL) = 1);

-- E se a segunda resposta chega ANTES de o rascunho da primeira ficar pronto,
-- ele nem vira mensagem.
INSERT INTO ar.ev VALUES (11, ar.pessoa(11));
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
SELECT :tenant, m.id, 'respondido', '{"texto":"esquece, já resolvi"}'
  FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
 WHERE e.contact_id = ar.c(11) AND m.step_id = :passo1;
INSERT INTO ar.destino VALUES (11, ar.responde((SELECT evento FROM ar.ev WHERE n = 11), 'Qual a idade?'));
SELECT ar.confere('rascunho de uma resposta já superada é devolvido logo na criação',
  (SELECT envio FROM ar.destino WHERE n = 11) = 'devolvido'
  AND NOT EXISTS (SELECT 1 FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
                   WHERE e.contact_id = ar.c(11) AND m.rascunho_id IS NOT NULL));

-- ===========================================================================
-- 4. A janela de 24h
-- ===========================================================================

INSERT INTO ar.ev VALUES (4, ar.pessoa(4, '25 hours'::interval));
INSERT INTO ar.destino VALUES (4, ar.responde((SELECT evento FROM ar.ev WHERE n = 4), 'Oi, sumi, desculpa!'));
SELECT ar.confere('resposta de 25h atrás no WhatsApp: devolvida na criação',
  (SELECT envio FROM ar.destino WHERE n = 4) = 'devolvido'
  AND (SELECT envio_motivo LIKE '%24h%' FROM rascunhos WHERE message_event_id = (SELECT evento FROM ar.ev WHERE n = 4)));

INSERT INTO ar.ev VALUES (5, ar.pessoa(5));
SELECT ar.responde((SELECT evento FROM ar.ev WHERE n = 5), 'Qual a idade?');
-- Ela esperou na fila (conta fora do ar, por exemplo) e a janela fechou.
UPDATE rascunhos SET resposta_em = now() - interval '25 hours'
 WHERE message_event_id = (SELECT evento FROM ar.ev WHERE n = 5);
CREATE TABLE ar.lote5 AS SELECT * FROM reivindicar_pendentes(50);
SELECT ar.confere('a janela é conferida de novo na saída: cancelada e devolvida',
  (SELECT m.status = 'cancelado' AND r.envio = 'devolvido' AND r.envio_motivo LIKE '%24h%'
     FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
    WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 5)));

-- ===========================================================================
-- 5. Supressão depois de enfileirar
-- ===========================================================================

INSERT INTO ar.ev VALUES (6, ar.pessoa(6));
SELECT ar.responde((SELECT evento FROM ar.ev WHERE n = 6), 'Qual a idade?');
INSERT INTO suppression (tenant_id, contact_id, motivo) VALUES (:tenant, ar.c(6), 'pediu por telefone');
CREATE TABLE ar.lote6 AS SELECT * FROM reivindicar_pendentes(50);
SELECT ar.confere('suprimida depois de enfileirar: não sai, vira cancelado (D39)',
  (SELECT m.status = 'cancelado' AND r.envio = 'devolvido' AND r.envio_motivo LIKE '%suprimido%'
     FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
    WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 6)));
SELECT ar.confere('e suprimida antes, nem entra na fila do agente',
  NOT EXISTS (SELECT 1 FROM respostas_para_o_agente(50) WHERE contact_id = ar.c(6)));

-- ===========================================================================
-- 6. Conta fora do ar: espera, não troca de chip
-- ===========================================================================

INSERT INTO ar.ev VALUES (7, ar.pessoa(7));
SELECT ar.responde((SELECT evento FROM ar.ev WHERE n = 7), 'Qual a idade?');
UPDATE sender_accounts SET estado = 'desativado' WHERE id = :chipa;
CREATE TABLE ar.lote7 AS SELECT * FROM reivindicar_pendentes(50);
SELECT ar.confere('com o chip A fora, a mensagem do agente fica pendente e NÃO vai para o chip B',
  (SELECT m.status = 'pendente' AND m.sender_account_id = 'ae000000-0000-0000-0000-0000000000e1'::uuid
          AND m.reivindicada_em IS NULL
     FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
    WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 7))
  AND NOT EXISTS (SELECT 1 FROM ar.lote7 l JOIN messages m ON m.id = l.message_id
                   JOIN rascunhos r ON r.id = m.rascunho_id
                  WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 7)));
INSERT INTO ar.ev VALUES (8, ar.pessoa(8));
INSERT INTO ar.destino VALUES (8, ar.responde((SELECT evento FROM ar.ev WHERE n = 8), 'Qual a idade?'));
SELECT ar.confere('e com o chip A fora, o rascunho seguinte é devolvido na criação, com o motivo',
  (SELECT envio FROM ar.destino WHERE n = 8) = 'devolvido'
  AND (SELECT envio_motivo LIKE '%Chip A%fora do pool%' FROM rascunhos WHERE contact_id = ar.c(8)),
  (SELECT envio_motivo FROM rascunhos WHERE contact_id = ar.c(8)));
UPDATE sender_accounts SET estado = 'ativo' WHERE id = :chipa;

-- ===========================================================================
-- 7. O chip que recebeu é o que responde
-- ===========================================================================

INSERT INTO ar.ev VALUES (9, ar.pessoa(9, '0'::interval, 'ae000000-0000-0000-0000-0000000000e2'));
SELECT ar.responde((SELECT evento FROM ar.ev WHERE n = 9), 'Qual a idade?');
SELECT ar.confere('a pessoa escreveu para o chip B: o agente responde pelo chip B',
  (SELECT m.sender_account_id = 'ae000000-0000-0000-0000-0000000000e2'::uuid
     FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
    WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 9)));

-- Os dois caminhos do webhook gravam o chip no evento.
SELECT registrar_resposta_por_numero(:chipb, '5511980000201', now(), '{"texto":"por numero"}');
SELECT ar.confere('a resposta casada pelo número guarda o chip que a recebeu',
  (SELECT payload ->> 'chip' = 'ae000000-0000-0000-0000-0000000000e2' AND payload ->> 'casado_por' = 'numero'
     FROM message_events WHERE payload ->> 'texto' = 'por numero'));
SELECT registrar_evento_provedor(:chipa, 'wamid.agente.1', 'respondido', now(), '{"texto":"pelo id"}');
SELECT ar.confere('e a casada pelo id do provedor também',
  (SELECT payload ->> 'chip' = 'ae000000-0000-0000-0000-0000000000e1'
     FROM message_events WHERE payload ->> 'texto' = 'pelo id'));

-- ===========================================================================
-- 8. Simulado é simulado
-- ===========================================================================

INSERT INTO ar.ev VALUES (10, ar.pessoa(10));
INSERT INTO ar.destino VALUES (10, ar.responde((SELECT evento FROM ar.ev WHERE n = 10), 'Qual a idade?', 'simulado'));
SELECT ar.confere('em simulado, a mensagem do agente nasce simulada',
  (SELECT envio FROM ar.destino WHERE n = 10) = 'fila'
  AND (SELECT m.status = 'simulado' FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id
        WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 10)));
SELECT ar.confere('e o despacho não a pega',
  NOT EXISTS (SELECT 1 FROM reivindicar_pendentes(50) l JOIN messages m ON m.id = l.message_id
               JOIN rascunhos r ON r.id = m.rascunho_id
              WHERE r.message_event_id = (SELECT evento FROM ar.ev WHERE n = 10)));

-- ===========================================================================
-- 9. A forma da mensagem, e a tela da campanha
-- ===========================================================================

SELECT ar.confere('mensagem com passo E rascunho é recusada',
  ar.sqlstate_de(format($q$INSERT INTO messages (tenant_id, enrollment_id, step_id, rascunho_id, contact_identity_id,
       sender_account_id, canal, status, conteudo)
     SELECT tenant_id, enrollment_id, %L, rascunho_id, contact_identity_id, sender_account_id, canal, 'simulado', 'x'
       FROM messages WHERE id = %L$q$, :passo2, (SELECT id FROM ar.msg1))) = '23514');
SELECT ar.confere('mensagem sem passo e sem rascunho é recusada',
  ar.sqlstate_de(format($q$INSERT INTO messages (tenant_id, enrollment_id, contact_identity_id,
       sender_account_id, canal, status, conteudo)
     SELECT tenant_id, enrollment_id, contact_identity_id, sender_account_id, canal, 'simulado', 'x'
       FROM messages WHERE id = %L$q$, (SELECT id FROM ar.msg1))) = '23514');
SELECT ar.confere('a tela da campanha mostra a mensagem do agente, sem passo',
  EXISTS (SELECT 1 FROM mensagens_da_campanha(:tenant, :camp, 200)
           WHERE message_id = (SELECT id FROM ar.msg1) AND passo IS NULL));

-- (d) O teto conta o que chamou o modelo.
SELECT registrar_rascunho((SELECT evento FROM ar.ev WHERE n = 1), :agente, 'recusa', NULL, 'x', NULL);
SELECT ar.confere('o teto conta as composições do cliente nas últimas 24h',
  (SELECT composicoes_hoje FROM respostas_para_o_agente(50) LIMIT 1)
    = (SELECT count(*) FROM rascunhos WHERE tenant_id = :tenant AND situacao IN ('pronto','escalar','bloqueado','erro')),
  (SELECT composicoes_hoje::text FROM respostas_para_o_agente(50) LIMIT 1));
SELECT ar.confere('e o devolvido não conta como troca da conversa',
  (SELECT rascunhos_anteriores = 0 FROM respostas_para_o_agente(50) WHERE contact_id = ar.c(3)));

-- ===========================================================================
-- 10. A grade
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ae000000-0000-0000-0000-0000000000a2"}';
  SELECT ar.confere('o operador liga e desliga a autonomia pela tela',
    ar.sqlstate_de($q$UPDATE agents SET autonomo = false WHERE id = 'ae000000-0000-0000-0000-0000000000a9'$q$) = 'sem erro');
  SELECT ar.confere('a tela não enfileira resposta',
    ar.sqlstate_de(format('SELECT enfileirar_resposta(%L)', (SELECT evento FROM ar.ev WHERE n = 2))) = '42501');
  SELECT ar.confere('nem lê a fila do agente',
    ar.sqlstate_de('SELECT * FROM respostas_para_o_agente(5)') = '42501');
  SELECT ar.confere('nem marca rascunho como enviado',
    ar.sqlstate_de($q$UPDATE rascunhos SET envio = 'fila'$q$) = '42501');
  SELECT ar.confere('nem escreve mensagem com rascunho',
    ar.sqlstate_de($q$UPDATE messages SET rascunho_id = NULL$q$) = '42501');
ROLLBACK;

-- ===========================================================================

\echo ''
\echo '============= O AGENTE RESPONDE ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM ar.resultado ORDER BY id;
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM ar.resultado;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ar.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'agente_responde: % asserções falharam', (SELECT count(*) FROM ar.resultado WHERE NOT ok);
  END IF;
END;
$$;
