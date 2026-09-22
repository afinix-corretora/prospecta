-- Testes das quatro invariantes do CLAUDE.md, mais as decisões que o schema
-- precisa sustentar (D4, D7, D9, append-only, shadow mode).
--
-- Roda com: tests/run.sh
-- Falha o processo se qualquer asserção falhar.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA t;

CREATE TABLE t.resultado (
  id      serial PRIMARY KEY,
  nome    text NOT NULL,
  ok      boolean NOT NULL,
  detalhe text NOT NULL DEFAULT ''
);

-- Registra uma condição que deve ser verdadeira.
CREATE FUNCTION t.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO t.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond, false), p_detalhe);
END;
$$;

-- Registra um comando que DEVE ser recusado pelo banco.
CREATE FUNCTION t.recusa(p_nome text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  INSERT INTO t.resultado (nome, ok, detalhe)
  VALUES (p_nome, false, 'comando foi aceito, deveria ter sido recusado');
EXCEPTION WHEN others THEN
  INSERT INTO t.resultado (nome, ok, detalhe)
  VALUES (p_nome, true, 'recusado: ' || SQLERRM);
END;
$$;

-- Registra um comando que deve ser aceito.
CREATE FUNCTION t.aceita(p_nome text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  INSERT INTO t.resultado (nome, ok, detalhe) VALUES (p_nome, true, '');
EXCEPTION WHEN others THEN
  INSERT INTO t.resultado (nome, ok, detalhe)
  VALUES (p_nome, false, 'recusado indevidamente: ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

INSERT INTO contacts (id, nome, origem) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Ana',  'planilha'),
  ('22222222-2222-2222-2222-222222222222', 'Bruno','planilha'),
  ('33333333-3333-3333-3333-333333333333', 'Caio', 'planilha'),
  ('44444444-4444-4444-4444-444444444444', 'Duda', 'planilha');

INSERT INTO contact_identities (id, contact_id, canal, valor, valor_norm, origem) VALUES
  ('a1000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','whatsapp','+55 11 90000-0001','5511900000001','planilha'),
  ('a1000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','email','Ana@Exemplo.com','ana@exemplo.com','planilha'),
  ('a2000000-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','whatsapp','+55 11 90000-0002','5511900000002','planilha'),
  ('a3000000-0000-0000-0000-000000000001','33333333-3333-3333-3333-333333333333','whatsapp','+55 11 90000-0003','5511900000003','planilha'),
  ('a4000000-0000-0000-0000-000000000001','44444444-4444-4444-4444-444444444444','whatsapp','+55 11 90000-0004','5511900000004','planilha');

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados) VALUES
  ('c1000000-0000-0000-0000-000000000001','Resgate 2024','morna','legitimo interesse - base propria com opt-in','{whatsapp,email}'),
  ('c1000000-0000-0000-0000-000000000002','Resgate 2023','morna','legitimo interesse - base propria com opt-in','{whatsapp}'),
  ('c2000000-0000-0000-0000-000000000001','Lista fria SP','fria','legitimo interesse - prospeccao B2B','{whatsapp}');

INSERT INTO flows (id, nome) VALUES
  ('f0000000-0000-0000-0000-000000000001','Cadencia resgate');

INSERT INTO flow_versions (id, flow_id, versao) VALUES
  ('fb000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-000000000001',1);

INSERT INTO flow_steps (id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('fc000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-000000000001',1,'whatsapp',0,'Oi {{nome}}'),
  ('fc000000-0000-0000-0000-000000000002','fb000000-0000-0000-0000-000000000001',2,'email',48,'Assunto: retomando');

INSERT INTO sender_accounts (id, canal, identificador, provedor, tipo_permitido, quota_diaria) VALUES
  ('5a000000-0000-0000-0000-000000000001','whatsapp','5511988880001','evolution','morna',100),
  ('5a000000-0000-0000-0000-000000000002','whatsapp','5511988880002','evolution','fria',3),
  ('5a000000-0000-0000-0000-000000000003','email','prospec@dominio-frio.com','smtp','fria',50),
  ('5a000000-0000-0000-0000-000000000004','whatsapp','5511988880004','evolution','morna',1),
  ('5a000000-0000-0000-0000-000000000005','email','resgate@dominio-morno.com','smtp','morna',50);

INSERT INTO enrollments (id, contact_id, campaign_id, flow_version_id, next_run_at) VALUES
  ('e0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','c1000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-000000000001', now() - interval '1 minute'),
  ('e0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','c1000000-0000-0000-0000-000000000002','fb000000-0000-0000-0000-000000000001', now() + interval '2 days'),
  ('e0000000-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222','c1000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-000000000001', now() - interval '1 minute'),
  ('e0000000-0000-0000-0000-000000000004','33333333-3333-3333-3333-333333333333','c1000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-000000000001', now() - interval '1 minute'),
  ('e0000000-0000-0000-0000-000000000005','44444444-4444-4444-4444-444444444444','c2000000-0000-0000-0000-000000000001','fb000000-0000-0000-0000-000000000001', now() - interval '1 minute');

-- ===========================================================================
-- INVARIANTE 1 — idempotência
-- ===========================================================================

SELECT t.aceita(
  'inv1: primeiro disparo do passo é aceito',
  $$INSERT INTO messages (id, enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
    VALUES ('11000000-0000-0000-0000-000000000001','e0000000-0000-0000-0000-000000000001','fc000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-000000000001','whatsapp','enviado','Oi Ana')$$);

SELECT t.recusa(
  'inv1: reprocessar o mesmo passo não duplica disparo',
  $$INSERT INTO messages (enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
    VALUES ('e0000000-0000-0000-0000-000000000001','fc000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-000000000001','whatsapp','enviado','Oi Ana de novo')$$);

SELECT t.aceita(
  'inv1: passo diferente do mesmo enrollment é aceito',
  $$INSERT INTO messages (enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
    VALUES ('e0000000-0000-0000-0000-000000000001','fc000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000002','5a000000-0000-0000-0000-000000000005','email','enviado','retomando')$$);

-- ===========================================================================
-- INVARIANTE 2 — supressão
-- ===========================================================================

-- Bruno opta por sair: supressão da pessoa, todos os canais.
INSERT INTO suppression (contact_id, motivo) VALUES
  ('22222222-2222-2222-2222-222222222222','opt-out solicitado');

SELECT t.confere(
  'inv2: esta_suprimido reconhece contato suprimido',
  esta_suprimido('00000000-0000-0000-0000-0000000000aa','22222222-2222-2222-2222-222222222222','whatsapp','5511900000002'));

SELECT t.recusa(
  'inv2: contato suprimido não recebe nada, por nenhum caminho',
  $$INSERT INTO messages (enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
    VALUES ('e0000000-0000-0000-0000-000000000003','fc000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-000000000001','whatsapp','enviado','nao deveria sair')$$);

-- Shadow mode não é exceção: simulado também respeita a supressão.
SELECT t.recusa(
  'inv2: supressão vale também em shadow mode (simulado)',
  $$INSERT INTO messages (enrollment_id, step_id, contact_identity_id, canal, status, conteudo)
    VALUES ('e0000000-0000-0000-0000-000000000003','fc000000-0000-0000-0000-000000000002','a2000000-0000-0000-0000-000000000001','whatsapp','simulado','nem simulado')$$);

-- Supressão por endereço, sem suprimir a pessoa inteira.
INSERT INTO suppression (canal, valor_norm, motivo) VALUES
  ('whatsapp','5511900000004','numero invalido reportado pelo provedor');

SELECT t.recusa(
  'inv2: identidade suprimida bloqueia o envio naquele canal',
  $$INSERT INTO messages (enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
    VALUES ('e0000000-0000-0000-0000-000000000005','fc000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-000000000002','whatsapp','enviado','bloqueado')$$);

SELECT t.recusa(
  'inv2: supressão é imutável (UPDATE recusado)',
  $$UPDATE suppression SET motivo = 'mudei de ideia'$$);

SELECT t.recusa(
  'inv2: supressão é imutável (DELETE recusado)',
  $$DELETE FROM suppression$$);

-- D39: a supressão vale depois da mensagem criada, não só antes.
--
-- O gatilho guarda o INSERT em `messages`, que é quando o roteador cria a
-- mensagem. Entre criar e despachar existe uma janela — e desde o D37 ela é
-- ilimitada, porque sem remetente disponível a mensagem fica pendente. Se a
-- pessoa pede para sair nesse meio, a mensagem saía assim mesmo.
DO $$
DECLARE
  v_contato uuid; v_ident uuid; v_enr uuid; v_msg uuid; v_chip uuid;
  v_status text; v_no_lote boolean;
BEGIN
  -- Cenário próprio, inclusive o remetente: `processar_vencidos` varre o
  -- banco inteiro e colidiria com as mensagens que a invariante 1 inseriu à
  -- mão. Aqui a mensagem entra como o roteador a criaria — e o gatilho de
  -- supressão roda neste INSERT, com o contato ainda livre, que é justamente
  -- o ponto: a guarda da criação passa, e é o despacho que precisa de portão.
  v_chip := gen_random_uuid();
  INSERT INTO sender_accounts (id, canal, identificador, apelido, provedor,
                               tipo_permitido, quota_diaria, config)
  VALUES (v_chip, 'whatsapp', '+5514900999', 'Chip D39', 'gupshup', 'morna', 50,
          '{"app_name":"d39","source":"5514900999"}'::jsonb);

  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato, 'Desistente', 'planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato, 'whatsapp', '+5514900777', '5514900777', 'planilha')
  RETURNING id INTO v_ident;

  v_enr := inscrever(v_contato, 'c1000000-0000-0000-0000-000000000001',
                     'fb000000-0000-0000-0000-000000000001', now() + interval '1 day');

  INSERT INTO messages (enrollment_id, step_id, contact_identity_id, sender_account_id,
                        canal, status, conteudo)
  VALUES (v_enr, 'fc000000-0000-0000-0000-000000000001', v_ident, v_chip,
          'whatsapp', 'pendente', 'Oi')
  RETURNING id INTO v_msg;

  PERFORM t.confere('D39: a mensagem nasceu pendente, com o contato ainda livre',
    (SELECT status FROM messages WHERE id = v_msg) = 'pendente',
    coalesce((SELECT status::text FROM messages WHERE id = v_msg), '(sem mensagem)'));

  -- A janela: a pessoa pede para sair depois de a mensagem existir.
  INSERT INTO suppression (contact_id, motivo)
  VALUES (v_contato, 'pediu para sair por telefone');

  -- Chamar e conferir em instruções separadas (D38): numa expressão só, o
  -- efeito da função não é visível para o teste ao lado.
  SELECT EXISTS (SELECT 1 FROM reivindicar_pendentes(100) r WHERE r.message_id = v_msg)
    INTO v_no_lote;
  PERFORM t.confere('D39: mensagem de quem pediu para sair não vai ao despachante',
    NOT v_no_lote);

  SELECT status::text INTO v_status FROM messages WHERE id = v_msg;
  PERFORM t.confere('D39: ela fica cancelada, não falha — opt-out não é defeito do motor',
    v_status = 'cancelado', v_status);

  SELECT EXISTS (SELECT 1 FROM reivindicar_pendentes(100) r WHERE r.message_id = v_msg)
    INTO v_no_lote;
  PERFORM t.confere('D39: e cancelada não volta à fila na batida seguinte', NOT v_no_lote);
END;
$$;

-- ===========================================================================
-- INVARIANTE 3 — rate limit por remetente
-- ===========================================================================

-- Remetente 5a...04 tem quota 1.
SELECT t.confere('inv3: primeira reserva dentro da quota é concedida',
  reservar_envio('5a000000-0000-0000-0000-000000000004') = true);

SELECT t.confere('inv3: reserva além da quota é negada',
  reservar_envio('5a000000-0000-0000-0000-000000000004') = false);

SELECT t.confere('inv3: contador não passou da quota',
  (SELECT enviados_na_janela <= quota_diaria FROM sender_accounts
    WHERE id = '5a000000-0000-0000-0000-000000000004'));

SELECT t.recusa(
  'inv3: estourar a quota por UPDATE direto é recusado pelo banco',
  $$UPDATE sender_accounts SET enviados_na_janela = quota_diaria + 1
     WHERE id = '5a000000-0000-0000-0000-000000000004'$$);

-- Circuit breaker: 5 falhas consecutivas abrem o circuito.
DO $$
BEGIN
  FOR i IN 1..5 LOOP
    PERFORM registrar_falha_remetente('5a000000-0000-0000-0000-000000000002');
  END LOOP;
END;
$$;

SELECT t.confere('inv3: conta com erro sai do pool sozinha (circuito aberto)',
  (SELECT estado = 'circuito_aberto' FROM sender_accounts
    WHERE id = '5a000000-0000-0000-0000-000000000002'));

SELECT t.confere('inv3: remetente com circuito aberto não aparece no pool',
  NOT EXISTS (SELECT 1 FROM remetentes_disponiveis('00000000-0000-0000-0000-0000000000aa','whatsapp','fria')
               WHERE id = '5a000000-0000-0000-0000-000000000002'));

SELECT t.confere('inv3: remetente com circuito aberto não reserva envio',
  reservar_envio('5a000000-0000-0000-0000-000000000002') = false);

SELECT t.confere('inv3: health score caiu com as falhas',
  (SELECT health_score < 100 FROM sender_accounts
    WHERE id = '5a000000-0000-0000-0000-000000000002'));

-- ===========================================================================
-- INVARIANTE 4 — encerramento global
-- ===========================================================================

-- Ana tem dois enrollments ativos, em campanhas diferentes.
SELECT t.confere('inv4: Ana começa com 2 enrollments ativos',
  (SELECT count(*) = 2 FROM enrollments
    WHERE contact_id = '11111111-1111-1111-1111-111111111111' AND status = 'ativo'));

-- Resposta chega no canal whatsapp (passo 1).
INSERT INTO message_events (message_id, tipo)
VALUES ('11000000-0000-0000-0000-000000000001','respondido');

SELECT t.confere('inv4: resposta encerra TODOS os enrollments do contato',
  (SELECT count(*) = 0 FROM enrollments
    WHERE contact_id = '11111111-1111-1111-1111-111111111111' AND status <> 'encerrado'));

SELECT t.confere('inv4: motivo do encerramento é resposta',
  (SELECT bool_and(motivo_encerramento = 'resposta') FROM enrollments
    WHERE contact_id = '11111111-1111-1111-1111-111111111111'));

SELECT t.confere('inv4: enrollment encerrado não é mais agendado',
  (SELECT bool_and(next_run_at IS NULL) FROM enrollments
    WHERE contact_id = '11111111-1111-1111-1111-111111111111'));

-- D7: clique é engajamento, não resposta. Não encerra.
INSERT INTO messages (id, enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
VALUES ('11000000-0000-0000-0000-000000000009','e0000000-0000-0000-0000-000000000004','fc000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-000000000001','whatsapp','enviado','Oi Caio');

INSERT INTO message_events (message_id, tipo)
VALUES ('11000000-0000-0000-0000-000000000009','clique');

SELECT t.confere('D7: clique NÃO encerra o enrollment',
  (SELECT status = 'ativo' FROM enrollments
    WHERE id = 'e0000000-0000-0000-0000-000000000004'));

SELECT t.confere('D7: clique fica registrado como evento de engajamento',
  EXISTS (SELECT 1 FROM message_events
           WHERE message_id = '11000000-0000-0000-0000-000000000009' AND tipo = 'clique'));

-- ===========================================================================
-- Eventos append-only
-- ===========================================================================

SELECT t.recusa('eventos: UPDATE em message_events é recusado',
  $$UPDATE message_events SET tipo = 'entregue'$$);

SELECT t.recusa('eventos: DELETE em message_events é recusado',
  $$DELETE FROM message_events$$);

-- ===========================================================================
-- D9 — flow_versions imutáveis
-- ===========================================================================

SELECT t.recusa('D9: editar flow_version é recusado',
  $$UPDATE flow_versions SET versao = 2$$);

SELECT t.recusa('D9: editar flow_step é recusado',
  $$UPDATE flow_steps SET template = 'outro texto'$$);

SELECT t.recusa('D9: apagar flow_step é recusado',
  $$DELETE FROM flow_steps WHERE ordem = 2$$);

SELECT t.aceita('D9: criar uma versão nova do mesmo flow é aceito',
  $$INSERT INTO flow_versions (flow_id, versao)
    VALUES ('f0000000-0000-0000-0000-000000000001', 2)$$);

SELECT t.confere('D9: enrollment em curso continua apontando para a versão antiga',
  (SELECT bool_and(flow_version_id = 'fb000000-0000-0000-0000-000000000001')
     FROM enrollments));

-- ===========================================================================
-- D4 — isolamento entre campanha morna e fria
-- ===========================================================================

SELECT t.recusa(
  'D4: campanha fria não usa remetente da operação morna',
  $$INSERT INTO messages (enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
    VALUES ('e0000000-0000-0000-0000-000000000005','fc000000-0000-0000-0000-000000000002','a4000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-000000000001','whatsapp','enviado','x')$$);

SELECT t.confere('D4: pool de campanha fria não devolve remetente morno',
  NOT EXISTS (SELECT 1 FROM remetentes_disponiveis('00000000-0000-0000-0000-0000000000aa','whatsapp','fria')
               WHERE tipo_permitido = 'morna'));

SELECT t.confere('D4: pool de campanha morna não devolve remetente frio',
  NOT EXISTS (SELECT 1 FROM remetentes_disponiveis('00000000-0000-0000-0000-0000000000aa','whatsapp','morna')
               WHERE tipo_permitido = 'fria'));

SELECT t.recusa(
  'canal: remetente de e-mail não envia mensagem de whatsapp',
  $$INSERT INTO messages (enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status, conteudo)
    VALUES ('e0000000-0000-0000-0000-000000000004','fc000000-0000-0000-0000-000000000002','a3000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-000000000003','whatsapp','enviado','x')$$);

-- ===========================================================================
-- Ingestão — dedup de identidade (D2)
-- ===========================================================================

SELECT t.recusa(
  'D2: mesma identidade não entra duas vezes, nem em contato diferente',
  $$INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
    VALUES ('33333333-3333-3333-3333-333333333333','whatsapp','+55 11 90000-0001','5511900000001','crm')$$);

SELECT t.aceita(
  'D2: mesmo valor em canal diferente é identidade distinta',
  $$INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
    VALUES ('33333333-3333-3333-3333-333333333333','sms','+55 11 90000-0003','5511900000003','crm')$$);

-- ===========================================================================
-- Agendador
-- ===========================================================================

SELECT t.confere('agendador: só devolve enrollment ativo e vencido',
  (SELECT bool_and(status = 'ativo' AND next_run_at <= now())
     FROM proximos_vencidos(100)));

SELECT t.confere('agendador: não devolve enrollment encerrado',
  NOT EXISTS (SELECT 1 FROM proximos_vencidos(100) p
               JOIN enrollments e ON e.id = p.id WHERE e.status = 'encerrado'));

SELECT t.confere('agendador: índice parcial de next_run_at existe',
  EXISTS (SELECT 1 FROM pg_indexes
           WHERE tablename = 'enrollments'
             AND indexdef ILIKE '%next_run_at%'
             AND indexdef ILIKE '%status%ativo%'));

-- ===========================================================================
-- Contrato de writeback (D3)
-- ===========================================================================

SELECT t.aceita('D3: fato do contrato estreito é aceito na outbox',
  $$INSERT INTO outbox (contact_id, destino, fato)
    VALUES ('11111111-1111-1111-1111-111111111111','pipefy','respondido')$$);

SELECT t.recusa('D3: fato fora do contrato estreito é recusado',
  $$INSERT INTO outbox (contact_id, destino, fato)
    VALUES ('11111111-1111-1111-1111-111111111111','pipefy','nome_do_lead')$$);

SELECT t.confere('D3: toda escrita externa carrega marca de autoria',
  (SELECT bool_and(autoria IS NOT NULL AND length(autoria) > 0) FROM outbox));

-- ===========================================================================
-- Relatório
-- ===========================================================================

\echo ''
\echo '================= RESULTADO ================='
SELECT
  CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status,
  nome,
  CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM t.resultado ORDER BY id;

\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
FROM t.resultado;

-- Falha o processo se algo falhou.
DO $$
DECLARE v_falhas integer;
BEGIN
  SELECT count(*) INTO v_falhas FROM t.resultado WHERE NOT ok;
  IF v_falhas > 0 THEN
    RAISE EXCEPTION '% asserção(ões) falharam', v_falhas;
  END IF;
END;
$$;
