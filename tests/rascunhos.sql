-- Quem o agente lê, e o que a tela pode mexer (D66).
--
-- Em ordem de custo:
--
--   1. quem está suprimido nunca chega ao agente — nem rascunho para quem
--      pediu para sair, porque texto pronto é convite a uma pessoa mandar;
--   2. uma resposta, um rascunho: o worker que roda duas vezes não paga duas;
--   3. a grade: a tela edita o agente por coluna, nunca escreve rascunho, e
--      nunca chama as funções do worker.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA rs;
CREATE TABLE rs.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA rs TO authenticated;
GRANT INSERT, SELECT ON rs.resultado TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA rs TO authenticated;
CREATE FUNCTION rs.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO rs.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION rs.confere(text, boolean, text) TO authenticated;
CREATE FUNCTION rs.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE; END; $$;
GRANT EXECUTE ON FUNCTION rs.sqlstate_de(text) TO authenticated;

\set tenant '\'ad000000-0000-0000-0000-0000000000a0\''
\set outro  '\'ad000000-0000-0000-0000-0000000000b0\''
\set oper   '\'ad000000-0000-0000-0000-0000000000a2\''
\set ooper  '\'ad000000-0000-0000-0000-0000000000b2\''
\set camp   '\'ad000000-0000-0000-0000-0000000000c1\''
\set semag  '\'ad000000-0000-0000-0000-0000000000c2\''
\set versao '\'ad000000-0000-0000-0000-0000000000f2\''
\set passo  '\'ad000000-0000-0000-0000-0000000000f3\''
\set chip   '\'ad000000-0000-0000-0000-0000000000e1\''
\set agente '\'ad000000-0000-0000-0000-0000000000a9\''

INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Agente', 'corretora-agente'),
                                            (:outro, 'Outra', 'outra-agente');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES (:tenant, :oper, 'operador'), (:outro, :ooper, 'operador');

INSERT INTO ai_credentials (id, tenant_id, nome, provedor, modelo)
VALUES ('ad000000-0000-0000-0000-0000000000d1', :tenant, 'Claude', 'anthropic', 'claude-sonnet-5');
INSERT INTO agents (id, tenant_id, nome, canal, papel, descricao, instrucoes, ai_credential_id)
VALUES (:agente, :tenant, 'Lia', 'whatsapp', 'SDR', 'Reativa quem cotou.',
        repeat('Seja breve, cordial e pergunte a idade das vidas antes de falar de valor. ', 3),
        'ad000000-0000-0000-0000-0000000000d1');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados) VALUES
  (:camp,  :tenant, 'Com agente', 'morna', 'opt-in', '{whatsapp}'),
  (:semag, :tenant, 'Sem agente', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id) VALUES (:tenant, :camp, 'whatsapp', :agente);
INSERT INTO flows (id, tenant_id, nome) VALUES ('ad000000-0000-0000-0000-0000000000f1', :tenant, 'F');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao) VALUES (:versao, :tenant, 'ad000000-0000-0000-0000-0000000000f1', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:passo, :tenant, :versao, 1, 'whatsapp', 0, 'Oi');
INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria)
VALUES (:chip, :tenant, 'whatsapp', 'uazapi', '5511990003333', 'Chip', 'morna', 100);

-- Uma recusa que o cliente escolheu NÃO suprimir (D58/D63).
INSERT INTO blacklist_termos (tenant_id, termo, acao) VALUES (:tenant, 'ja tenho corretor', 'recusa');

-- Cinco pessoas, cada uma um caso. A função cria contato, identidade,
-- enrollment, mensagem enviada e as respostas, nesta ordem.
CREATE FUNCTION rs.pessoa(p_n int, p_campanha uuid, p_desde interval, VARIADIC p_respostas text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_c uuid; v_i uuid; v_e uuid; v_m uuid; r text; k int := 0;
BEGIN
  v_c := ('ad000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid;
  INSERT INTO contacts (id, tenant_id, nome, origem, metadados)
  VALUES (v_c, 'ad000000-0000-0000-0000-0000000000a0', 'Pessoa ' || p_n, 'planilha', '{"plano":"Amil"}');
  INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
  VALUES ('ad000000-0000-0000-0000-0000000000a0', v_c, 'whatsapp', '55119700001' || lpad(p_n::text, 2, '0'),
          '55119700001' || lpad(p_n::text, 2, '0'), 'planilha') RETURNING id INTO v_i;
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id)
  VALUES ('ad000000-0000-0000-0000-0000000000a0', v_c, p_campanha, 'ad000000-0000-0000-0000-0000000000f2')
  RETURNING id INTO v_e;
  INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status,
                        conteudo, criado_em)
  VALUES ('ad000000-0000-0000-0000-0000000000a0', v_e, 'ad000000-0000-0000-0000-0000000000f3', v_i,
          'ad000000-0000-0000-0000-0000000000e1', 'whatsapp', 'enviado', 'Oi, ainda pensa no plano?',
          now() - p_desde - interval '1 hour')
  RETURNING id INTO v_m;
  FOREACH r IN ARRAY p_respostas LOOP
    k := k + 1;
    INSERT INTO message_events (tenant_id, message_id, tipo, payload, ocorrido_em)
    VALUES ('ad000000-0000-0000-0000-0000000000a0', v_m, 'respondido', jsonb_build_object('texto', r),
            now() - p_desde - make_interval(mins => 10 - k));
  END LOOP;
  RETURN v_c;
END; $$;

SELECT rs.pessoa(1, :camp, '0'::interval, 'oi', 'quanto fica para dois?');   -- duas respostas: só a última
SELECT rs.pessoa(2, :camp, '0'::interval, 'me liga amanha');                  -- vai ser suprimida depois
SELECT rs.pessoa(3, :semag, '0'::interval, 'pode mandar');                    -- campanha sem agente
SELECT rs.pessoa(4, :camp, '0'::interval, 'ja tenho corretor, obrigado');     -- recusa, sem supressão

-- Resposta de oito dias atrás não espera rascunho.
SELECT rs.pessoa(5, :camp, '8 days'::interval, 'antiga');

CREATE TABLE rs.fila AS SELECT * FROM respostas_para_rascunhar(50);

SELECT rs.confere('linha de base: entram as pessoas 1, 2 e 4',
  (SELECT array_agg(contact_id ORDER BY contact_id) FROM rs.fila)
    = ARRAY['ad000000-0000-0000-0000-000000000101','ad000000-0000-0000-0000-000000000102',
            'ad000000-0000-0000-0000-000000000104']::uuid[],
  (SELECT string_agg(contact_id::text || ':' || texto, ' | ') FROM rs.fila));
SELECT rs.confere('de quem respondeu duas vezes, só a resposta mais recente',
  (SELECT texto FROM rs.fila WHERE contact_id = 'ad000000-0000-0000-0000-000000000101') = 'quanto fica para dois?');
SELECT rs.confere('com o agente da campanha no canal, e a credencial que compõe',
  (SELECT agente_nome = 'Lia' AND provedor = 'anthropic' AND provedor_compoe AND rascunhos_anteriores = 0
     FROM rs.fila WHERE contact_id = 'ad000000-0000-0000-0000-000000000101'));
SELECT rs.confere('a conversa vem nos dois sentidos, a mais antiga primeiro',
  (SELECT historico -> 0 ->> 'de' = 'nos' AND historico -> 1 ->> 'texto' = 'oi'
          AND historico -> 2 ->> 'texto' = 'quanto fica para dois?' AND jsonb_array_length(historico) = 3
     FROM rs.fila WHERE contact_id = 'ad000000-0000-0000-0000-000000000101'),
  (SELECT historico::text FROM rs.fila WHERE contact_id = 'ad000000-0000-0000-0000-000000000101'));
SELECT rs.confere('a recusa vem marcada como recusa (e não foi suprimida)',
  (SELECT regra = 'recusa' FROM rs.fila WHERE contact_id = 'ad000000-0000-0000-0000-000000000104'));

-- A pessoa 2 pede para sair por outro caminho (a tela de supressão).
INSERT INTO suppression (tenant_id, contact_id, motivo)
VALUES (:tenant, 'ad000000-0000-0000-0000-000000000102', 'pediu por telefone');
SELECT rs.confere('suprimida, ela some da fila do agente',
  NOT EXISTS (SELECT 1 FROM respostas_para_rascunhar(50) WHERE contact_id = 'ad000000-0000-0000-0000-000000000102'));

-- Credencial desligada: a resposta continua na fila, mas diz que não compõe.
UPDATE ai_credentials SET ativo = false WHERE id = 'ad000000-0000-0000-0000-0000000000d1';
SELECT rs.confere('credencial desligada: provedor_compoe falso, e o motivo vai ser dito',
  (SELECT NOT provedor_compoe FROM respostas_para_rascunhar(50) WHERE contact_id = 'ad000000-0000-0000-0000-000000000101'));
UPDATE ai_credentials SET ativo = true WHERE id = 'ad000000-0000-0000-0000-0000000000d1';

-- A campanha escolhe a conta de IA (D68): uma das contas conectadas em
-- Configurações, e ela vale sobre a do agente, que várias campanhas dividem.
INSERT INTO ai_credentials (id, tenant_id, nome, provedor, modelo)
VALUES ('ad000000-0000-0000-0000-0000000000d2', :tenant, 'OpenAI comercial', 'openai', 'gpt-5'),
       ('ad000000-0000-0000-0000-0000000000d3', :outro, 'Alheia', 'anthropic', 'claude-sonnet-5');
UPDATE campaigns SET ai_credential_id = 'ad000000-0000-0000-0000-0000000000d2' WHERE id = :camp;
SELECT rs.confere('a conta escolhida na campanha vale sobre a do agente',
  (SELECT credencial_id = 'ad000000-0000-0000-0000-0000000000d2' AND provedor = 'openai' AND provedor_compoe
     FROM respostas_para_rascunhar(50) WHERE contact_id = 'ad000000-0000-0000-0000-000000000101'));
SELECT rs.confere('a campanha não aponta a conta de outro cliente',
  rs.sqlstate_de($q$UPDATE campaigns SET ai_credential_id = 'ad000000-0000-0000-0000-0000000000d3'
     WHERE id = 'ad000000-0000-0000-0000-0000000000c1'$q$) = '23503');
DELETE FROM ai_credentials WHERE id = 'ad000000-0000-0000-0000-0000000000d2';
SELECT rs.confere('apagar a conta solta a campanha, que continua existindo',
  (SELECT ai_credential_id IS NULL FROM campaigns WHERE id = :camp));
SELECT rs.confere('e sem escolha na campanha, volta a valer a conta do agente',
  (SELECT credencial_id = 'ad000000-0000-0000-0000-0000000000d1'
     FROM respostas_para_rascunhar(50) WHERE contact_id = 'ad000000-0000-0000-0000-000000000101'));

-- Uma resposta, um rascunho.
DO $$
DECLARE v_ev uuid;
BEGIN
  SELECT message_event_id INTO v_ev FROM rs.fila WHERE contact_id = 'ad000000-0000-0000-0000-000000000101';
  PERFORM registrar_rascunho(v_ev, 'ad000000-0000-0000-0000-0000000000a9', 'pronto', 'Qual a idade de vocês?', NULL, 'claude-sonnet-5');
  PERFORM registrar_rascunho(v_ev, 'ad000000-0000-0000-0000-0000000000a9', 'pronto', 'outro texto', NULL, 'claude-sonnet-5');
  PERFORM rs.confere('registrar duas vezes grava uma',
    (SELECT count(*) FROM rascunhos WHERE message_event_id = v_ev) = 1
    AND (SELECT texto FROM rascunhos WHERE message_event_id = v_ev) = 'Qual a idade de vocês?');
  PERFORM rs.confere('o rascunho guarda o instante da resposta (é por ele que a tela casa)',
    (SELECT r.resposta_em = me.ocorrido_em FROM rascunhos r JOIN message_events me ON me.id = r.message_event_id
      WHERE r.message_event_id = v_ev));
  PERFORM rs.confere('rascunhada, a resposta sai da fila',
    NOT EXISTS (SELECT 1 FROM respostas_para_rascunhar(50) WHERE message_event_id = v_ev));
  PERFORM rs.confere('pronto sem texto não existe',
    rs.sqlstate_de(format('SELECT registrar_rascunho(%L, NULL, %L)',
      (SELECT message_event_id FROM rs.fila WHERE contact_id = 'ad000000-0000-0000-0000-000000000104'), 'pronto')) = '23514');
END $$;

-- A pessoa 1 responde de novo: a nova resposta entra, com o rascunho anterior contado.
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
SELECT :tenant, m.id, 'respondido', '{"texto":"tenho 40 e ela 38"}'
  FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
 WHERE e.contact_id = 'ad000000-0000-0000-0000-000000000101';
SELECT rs.confere('a resposta nova entra, contando o rascunho anterior para o limite',
  (SELECT rascunhos_anteriores = 1 AND texto = 'tenho 40 e ela 38'
     FROM respostas_para_rascunhar(50) WHERE contact_id = 'ad000000-0000-0000-0000-000000000101'));

-- ===========================================================================
-- A grade
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ad000000-0000-0000-0000-0000000000a2"}';
  SELECT rs.confere('o operador edita a instrução, o proibido e o tamanho pela tela',
    rs.sqlstate_de($q$UPDATE agents SET proibido = '{garantimos}', tamanho_maximo = 400,
       instrucoes = instrucoes || ' Nunca prometa prazo.' WHERE id = 'ad000000-0000-0000-0000-0000000000a9'$q$) = 'sem erro');
  SELECT rs.confere('mas não muda o dono do agente',
    rs.sqlstate_de($q$UPDATE agents SET tenant_id = 'ad000000-0000-0000-0000-0000000000b0'
       WHERE id = 'ad000000-0000-0000-0000-0000000000a9'$q$) = '42501');
  SELECT rs.confere('nem marca agente como do catálogo',
    rs.sqlstate_de($q$UPDATE agents SET pronto = true WHERE id = 'ad000000-0000-0000-0000-0000000000a9'$q$) = '42501');
  SELECT rs.confere('tamanho fora da faixa é recusado',
    rs.sqlstate_de($q$UPDATE agents SET tamanho_maximo = 10 WHERE id = 'ad000000-0000-0000-0000-0000000000a9'$q$) = '23514');
  SELECT rs.confere('o operador escolhe a conta de IA da campanha pela tela (D68)',
    rs.sqlstate_de($q$UPDATE campaigns SET ai_credential_id = 'ad000000-0000-0000-0000-0000000000d1'
       WHERE id = 'ad000000-0000-0000-0000-0000000000c1'$q$) = 'sem erro');
  SELECT rs.confere('a tela não escreve rascunho',
    rs.sqlstate_de($q$INSERT INTO rascunhos (tenant_id, message_event_id, contact_id, resposta_em, situacao, texto)
       SELECT tenant_id, id, 'ad000000-0000-0000-0000-000000000104', now(), 'pronto', 'x'
         FROM message_events LIMIT 1$q$) = '42501');
  SELECT rs.confere('nem chama a fila do worker',
    rs.sqlstate_de('SELECT * FROM respostas_para_rascunhar(5)') = '42501');
  SELECT rs.confere('e lê o rascunho do próprio cliente',
    (SELECT count(*) FROM rascunhos) = 1);
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ad000000-0000-0000-0000-0000000000b2"}';
  SELECT rs.confere('o operador de outro cliente não vê o rascunho deste', (SELECT count(*) FROM rascunhos) = 0);
COMMIT;

SELECT rs.confere('o catálogo diz quem compõe: seis sim, o Gemini não',
  (SELECT count(*) FROM ai_provider_catalog WHERE tem_adapter) = 6
  AND NOT (SELECT tem_adapter FROM ai_provider_catalog WHERE slug = 'google'));

-- ===========================================================================

\echo ''
\echo '============= RASCUNHOS DO AGENTE ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM rs.resultado ORDER BY id;
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM rs.resultado;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM rs.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'rascunhos: % asserções falharam', (SELECT count(*) FROM rs.resultado WHERE NOT ok);
  END IF;
END;
$$;
