-- Testes da superfície de despacho: reivindicação com lease, registro de
-- resultado e eventos vindos do provedor.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA d;

CREATE TABLE d.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);

CREATE FUNCTION d.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO d.resultado (nome, ok, detalhe) VALUES (p_nome, coalesce(p_cond,false), p_detalhe);
END;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures: dois contatos prontos para envio real
-- ---------------------------------------------------------------------------

INSERT INTO contacts (id, nome, origem) VALUES
  ('d1000000-0000-0000-0000-000000000001','Alice','planilha'),
  ('d1000000-0000-0000-0000-000000000002','Breno','planilha');

INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem) VALUES
  ('d1000000-0000-0000-0000-000000000001','whatsapp','+5514900001','5514900001','planilha'),
  ('d1000000-0000-0000-0000-000000000002','whatsapp','+5514900002','5514900002','planilha');

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados) VALUES
  ('d3000000-0000-0000-0000-000000000001','Despacho','morna','opt-in','{whatsapp}');

INSERT INTO flows (id, nome) VALUES ('d4000000-0000-0000-0000-000000000001','Flow despacho');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES ('d5000000-0000-0000-0000-000000000001','d4000000-0000-0000-0000-000000000001',1);
-- Dois passos de propósito: com um só, o enrollment encerraria por
-- fim_dos_passos no mesmo instante do disparo, e a resposta do provedor
-- chegaria a um enrollment já fechado — sem exercitar a invariante 4.
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('d5000000-0000-0000-0000-000000000001',1,'whatsapp',0,'Oi {{nome}}'),
  ('d5000000-0000-0000-0000-000000000001',2,'whatsapp',48,'Retomando, {{nome}}');

INSERT INTO sender_accounts (id, canal, identificador, provedor, tipo_permitido, quota_diaria)
VALUES ('d7000000-0000-0000-0000-000000000001','whatsapp','instancia-a','evolution','morna',100);

SELECT inscrever('d1000000-0000-0000-0000-000000000001','d3000000-0000-0000-0000-000000000001',
                 'd5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
SELECT inscrever('d1000000-0000-0000-0000-000000000002','d3000000-0000-0000-0000-000000000001',
                 'd5000000-0000-0000-0000-000000000001', now() - interval '1 minute');

-- Modo real: gera duas mensagens pendentes.
SELECT count(*) FROM processar_vencidos(100, 'real');

-- ---------------------------------------------------------------------------
-- Reivindicação
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_linhas integer; v_r record;
BEGIN
  SELECT count(*) INTO v_linhas FROM messages
   WHERE status = 'pendente' AND enrollment_id IN (
     SELECT id FROM enrollments WHERE campaign_id = 'd3000000-0000-0000-0000-000000000001');
  PERFORM d.confere('despacho: modo real deixou duas pendentes', v_linhas = 2, v_linhas::text);

  SELECT * INTO v_r FROM reivindicar_pendentes(1);
  PERFORM d.confere('reivindica entrega tudo que o adapter precisa',
    v_r.message_id IS NOT NULL AND v_r.canal = 'whatsapp'
    AND v_r.destino LIKE '+55%' AND v_r.conteudo LIKE 'Oi %'
    AND v_r.sender_ident = 'instancia-a' AND v_r.campanha_tipo = 'morna',
    format('%s %s %s', v_r.destino, v_r.conteudo, v_r.sender_ident));

  PERFORM d.confere('reivindicada carrega o carimbo do lease',
    (SELECT reivindicada_em IS NOT NULL FROM messages WHERE id = v_r.message_id));

  -- Segunda chamada não devolve a mesma: o lease está válido.
  PERFORM d.confere('lease válido impede reivindicação dupla',
    NOT EXISTS (SELECT 1 FROM reivindicar_pendentes(10) WHERE message_id = v_r.message_id));

  -- Worker que morreu: lease vencido devolve a mensagem ao pool.
  UPDATE messages SET reivindicada_em = now() - interval '10 minutes' WHERE id = v_r.message_id;
  PERFORM d.confere('lease vencido devolve a mensagem ao pool',
    EXISTS (SELECT 1 FROM reivindicar_pendentes(10, interval '5 minutes')
             WHERE message_id = v_r.message_id));
END;
$$;

DO $$
DECLARE v uuid;
BEGIN
  v := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v,'Dora','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v,'whatsapp','+5514900009','5514900009','planilha');
  PERFORM inscrever(v,'d3000000-0000-0000-0000-000000000001',
                    'd5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  PERFORM processar_vencidos(100,'simulado');
  PERFORM d.confere('shadow mode deixou mensagem simulada no banco',
    EXISTS (SELECT 1 FROM messages WHERE status = 'simulado'));
END;
$$;

SELECT d.confere('reivindica não devolve mensagem simulada',
  NOT EXISTS (
    SELECT 1 FROM reivindicar_pendentes(100) r
    JOIN messages m ON m.id = r.message_id WHERE m.status = 'simulado'));

-- ---------------------------------------------------------------------------
-- Resultado do envio
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_msg uuid; v_saude numeric;
BEGIN
  SELECT m.id INTO v_msg FROM messages m
    JOIN enrollments e ON e.id = m.enrollment_id
   WHERE e.contact_id = 'd1000000-0000-0000-0000-000000000001' AND m.status = 'pendente';

  PERFORM registrar_resultado_envio(v_msg, true, 'EVO-ABC');

  PERFORM d.confere('sucesso: status vira enviado e guarda o id do provedor',
    (SELECT status = 'enviado' AND provider_message_id = 'EVO-ABC'
       FROM messages WHERE id = v_msg));
  PERFORM d.confere('sucesso: lease é liberado',
    (SELECT reivindicada_em IS NULL FROM messages WHERE id = v_msg));
  PERFORM d.confere('sucesso: gerou evento enviado (append-only)',
    EXISTS (SELECT 1 FROM message_events WHERE message_id = v_msg AND tipo = 'enviado'));
  PERFORM d.confere('sucesso: mensagem já enviada não é reivindicada de novo',
    NOT EXISTS (SELECT 1 FROM reivindicar_pendentes(100) WHERE message_id = v_msg));
END;
$$;

DO $$
DECLARE v_msg uuid; v_falhas_antes integer; v_falhas_depois integer; v_saude_antes numeric;
BEGIN
  SELECT falhas_consecutivas, health_score INTO v_falhas_antes, v_saude_antes
    FROM sender_accounts WHERE id = 'd7000000-0000-0000-0000-000000000001';

  SELECT m.id INTO v_msg FROM messages m
    JOIN enrollments e ON e.id = m.enrollment_id
   WHERE e.contact_id = 'd1000000-0000-0000-0000-000000000002' AND m.status = 'pendente';

  PERFORM registrar_resultado_envio(v_msg, false, NULL, 'unauthorized');

  PERFORM d.confere('falha: status vira falha',
    (SELECT status = 'falha' FROM messages WHERE id = v_msg));
  PERFORM d.confere('falha: evento guarda o erro',
    (SELECT payload ->> 'erro' = 'unauthorized' FROM message_events
      WHERE message_id = v_msg AND tipo = 'falha'));

  SELECT falhas_consecutivas INTO v_falhas_depois
    FROM sender_accounts WHERE id = 'd7000000-0000-0000-0000-000000000001';
  PERFORM d.confere('inv3: falha de envio conta contra o remetente',
    v_falhas_depois = v_falhas_antes + 1,
    format('antes=%s depois=%s', v_falhas_antes, v_falhas_depois));
  PERFORM d.confere('inv3: health score do remetente caiu',
    (SELECT health_score < v_saude_antes FROM sender_accounts
      WHERE id = 'd7000000-0000-0000-0000-000000000001'));
END;
$$;

DO $$
BEGIN
  PERFORM registrar_resultado_envio('00000000-0000-0000-0000-000000000000', true, 'x');
  PERFORM d.confere('resultado de mensagem inexistente falha alto', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM d.confere('resultado de mensagem inexistente falha alto', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- Eventos do provedor
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_msg uuid;
BEGIN
  SELECT id INTO v_msg FROM messages WHERE provider_message_id = 'EVO-ABC';

  PERFORM d.confere('evento do provedor casa pelo id e é gravado',
    registrar_evento_provedor('EVO-ABC', 'entregue') = true);
  PERFORM d.confere('evento entregue existe',
    EXISTS (SELECT 1 FROM message_events WHERE message_id = v_msg AND tipo = 'entregue'));

  PERFORM d.confere('evento com id desconhecido é descartado',
    registrar_evento_provedor('NAO-EXISTE', 'entregue') = false);

  -- Prevenção de loop de eco: o que o próprio motor escreveu volta marcado.
  PERFORM d.confere('eco do próprio motor é descartado',
    registrar_evento_provedor('EVO-ABC', 'respondido', now(),
      '{"autoria":"motor-prospeccao"}'::jsonb) = false);
  PERFORM d.confere('eco descartado não virou evento',
    NOT EXISTS (SELECT 1 FROM message_events
                 WHERE message_id = v_msg AND tipo = 'respondido'));

  -- Resposta de verdade: invariante 4 encerra o enrollment inteiro.
  PERFORM d.confere('resposta do provedor é aceita',
    registrar_evento_provedor('EVO-ABC', 'respondido', now(),
      '{"de":"5514900001"}'::jsonb) = true);
  PERFORM d.confere('inv4: resposta vinda do provedor encerra o enrollment',
    (SELECT e.status = 'encerrado' AND e.motivo_encerramento = 'resposta'
       FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
      WHERE m.id = v_msg));
END;
$$;

-- Clique continua não encerrando, mesmo vindo do provedor (D7).
DO $$
DECLARE v_contato uuid; v_enr uuid; v_msg uuid;
BEGIN
  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato,'Cleo','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'whatsapp','+5514900003','5514900003','planilha');
  v_enr := inscrever(v_contato,'d3000000-0000-0000-0000-000000000001',
                     'd5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  PERFORM processar_vencidos(100,'real');

  SELECT id INTO v_msg FROM messages WHERE enrollment_id = v_enr;
  PERFORM registrar_resultado_envio(v_msg, true, 'EVO-CLIQUE');
  PERFORM registrar_evento_provedor('EVO-CLIQUE', 'clique');

  PERFORM d.confere('D7: clique vindo do provedor não encerra',
    (SELECT status = 'encerrado' FROM enrollments WHERE id = v_enr) = false);
END;
$$;

-- ---------------------------------------------------------------------------
-- Culpa do destino não penaliza o remetente
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  v_contato uuid; v_enr uuid; v_msg uuid; v_ident uuid;
  v_falhas_antes integer; v_falhas_depois integer;
BEGIN
  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato,'Elis','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'whatsapp','+5514900050','5514900050','planilha')
  RETURNING id INTO v_ident;

  v_enr := inscrever(v_contato,'d3000000-0000-0000-0000-000000000001',
                     'd5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  PERFORM processar_vencidos(100,'real');
  SELECT id INTO v_msg FROM messages WHERE enrollment_id = v_enr;

  SELECT falhas_consecutivas INTO v_falhas_antes
    FROM sender_accounts WHERE id = 'd7000000-0000-0000-0000-000000000001';

  PERFORM registrar_resultado_envio(v_msg, false, NULL, 'not a WhatsApp user', 'destino');

  SELECT falhas_consecutivas INTO v_falhas_depois
    FROM sender_accounts WHERE id = 'd7000000-0000-0000-0000-000000000001';

  PERFORM d.confere('culpa do destino NÃO penaliza o remetente',
    v_falhas_depois = v_falhas_antes,
    format('antes=%s depois=%s', v_falhas_antes, v_falhas_depois));

  PERFORM d.confere('culpa do destino invalida a identidade',
    (SELECT valida = false FROM contact_identities WHERE id = v_ident));

  PERFORM d.confere('D3: identidade inválida vira fato na outbox',
    EXISTS (SELECT 1 FROM outbox
             WHERE contact_id = v_contato AND fato = 'identidade_invalida'));

  PERFORM d.confere('culpa do destino gera evento rejeitado, não falha genérica',
    EXISTS (SELECT 1 FROM message_events
             WHERE message_id = v_msg AND tipo = 'rejeitado'
               AND payload ->> 'culpa' = 'destino'));

  PERFORM d.confere('D3: fato da outbox carrega autoria',
    (SELECT autoria = 'motor-prospeccao' FROM outbox
      WHERE contact_id = v_contato AND fato = 'identidade_invalida'));
END;
$$;

DO $$
DECLARE v_contato uuid; v_enr uuid; v_msg uuid; v_falhas_antes integer;
BEGIN
  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato,'Fabio','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'whatsapp','+5514900051','5514900051','planilha');
  v_enr := inscrever(v_contato,'d3000000-0000-0000-0000-000000000001',
                     'd5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  PERFORM processar_vencidos(100,'real');
  SELECT id INTO v_msg FROM messages WHERE enrollment_id = v_enr;

  SELECT falhas_consecutivas INTO v_falhas_antes
    FROM sender_accounts WHERE id = 'd7000000-0000-0000-0000-000000000001';
  PERFORM registrar_resultado_envio(v_msg, false, NULL, 'timeout', 'transitorio');

  PERFORM d.confere('culpa transitória penaliza o remetente (provedor fora do ar conta)',
    (SELECT falhas_consecutivas = v_falhas_antes + 1 FROM sender_accounts
      WHERE id = 'd7000000-0000-0000-0000-000000000001'));
  PERFORM d.confere('culpa transitória não invalida a identidade',
    (SELECT ci.valida FROM messages m
       JOIN contact_identities ci ON ci.id = m.contact_identity_id
      WHERE m.id = v_msg));
END;
$$;

DO $$
DECLARE v_msg uuid;
BEGIN
  SELECT id INTO v_msg FROM messages LIMIT 1;
  PERFORM registrar_resultado_envio(v_msg, false, NULL, 'x', 'culpa_inventada');
  PERFORM d.confere('culpa fora do vocabulário é recusada', false, 'foi aceita');
EXCEPTION WHEN others THEN
  PERFORM d.confere('culpa fora do vocabulário é recusada', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- Relatório
-- ---------------------------------------------------------------------------

\echo ''
\echo '============= DESPACHO ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM d.resultado ORDER BY id;

\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
FROM d.resultado;

DO $$
DECLARE v_falhas integer;
BEGIN
  SELECT count(*) INTO v_falhas FROM d.resultado WHERE NOT ok;
  IF v_falhas > 0 THEN
    RAISE EXCEPTION '% asserção(ões) de despacho falharam', v_falhas;
  END IF;
END;
$$;
