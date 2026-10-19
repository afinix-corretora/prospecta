-- O despachante concorda com o agendador (D40).
--
-- O que este arquivo sustenta: as quatro situações em que o estado muda
-- enquanto a mensagem espera na fila. Três param o envio; a quarta — o
-- encerramento normal por `fim_dos_passos` — **precisa** deixar sair, e é a
-- que torna errada a regra óbvia de "só despacha enrollment ativo".

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA dc;
CREATE TABLE dc.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION dc.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO dc.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t    '00000000-0000-0000-0000-0000000000aa'
\set camp 'ac000000-0000-0000-0000-000000000001'
\set fv   'ac000000-0000-0000-0000-000000000003'

-- Dois passos: assim o enrollment segue ativo depois da primeira mensagem, e
-- dá para mexer no estado dele com a mensagem ainda pendente.
INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES (:'camp','Resgate','morna','opt-in','{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('ac000000-0000-0000-0000-000000000002','F');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES (:'fv','ac000000-0000-0000-0000-000000000002',1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:'fv',1,'whatsapp',0,'oi'), (:'fv',2,'whatsapp',48,'e aí');

INSERT INTO sender_accounts (id, canal, identificador, apelido, provedor,
                             tipo_permitido, quota_diaria, config)
VALUES ('ac000000-0000-0000-0000-0000000000a1','whatsapp','+5511900000001','Chip',
        'gupshup','morna',200,'{"app_name":"a","source":"1"}'::jsonb);

CREATE TABLE dc.quem (rotulo text PRIMARY KEY, contato uuid, enrollment uuid, mensagem uuid);

DO $$
DECLARE v uuid; v_enr uuid; r text; i int := 0;
BEGIN
  FOREACH r IN ARRAY ARRAY['respondeu','pausado','campanha_off','normal'] LOOP
    i := i + 1;
    SELECT contact_id INTO v FROM ingerir_contato(
      '00000000-0000-0000-0000-0000000000aa','planilha',
      format('[{"canal":"whatsapp","valor":"1599222000%s","valor_norm":"551599222000%s"}]', i, i)::jsonb,
      r);
    SELECT inscrever(v, 'ac000000-0000-0000-0000-000000000001',
                     'ac000000-0000-0000-0000-000000000003', now() - interval '1 minute')
      INTO v_enr;
    INSERT INTO dc.quem VALUES (r, v, v_enr, NULL);
  END LOOP;
END;
$$;

SELECT count(*) FROM processar_vencidos(10, 'real');

UPDATE dc.quem q SET mensagem = m.id FROM messages m WHERE m.enrollment_id = q.enrollment;

SELECT dc.confere('as quatro mensagens nasceram pendentes',
  (SELECT count(*) FROM messages m JOIN dc.quem q ON q.mensagem = m.id
    WHERE m.status = 'pendente') = 4,
  (SELECT count(*)::text FROM messages WHERE status = 'pendente'));

-- ---------------------------------------------------------------------------
-- O estado muda enquanto a mensagem espera
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  -- 1. A pessoa responde por outro canal: invariante 4 encerra o enrollment.
  PERFORM encerrar_enrollment((SELECT enrollment FROM dc.quem WHERE rotulo = 'respondeu'),
                              'resposta');
  -- 2. O operador pausa.
  UPDATE enrollments SET status = 'pausado'
   WHERE id = (SELECT enrollment FROM dc.quem WHERE rotulo = 'pausado');
END;
$$;

-- 3. A campanha é desligada. Como é a mesma campanha dos quatro, este caso é
-- medido depois, sozinho.

CREATE TEMP TABLE lote1 AS SELECT * FROM reivindicar_pendentes(10);

SELECT dc.confere('quem respondeu não leva mais um toque (invariante 4 na borda)',
  NOT EXISTS (SELECT 1 FROM lote1 l JOIN dc.quem q ON q.mensagem = l.message_id
               WHERE q.rotulo = 'respondeu'));

SELECT dc.confere('e a mensagem de quem respondeu fica cancelada',
  (SELECT m.status::text FROM messages m JOIN dc.quem q ON q.mensagem = m.id
    WHERE q.rotulo = 'respondeu') = 'cancelado',
  (SELECT m.status::text FROM messages m JOIN dc.quem q ON q.mensagem = m.id
    WHERE q.rotulo = 'respondeu'));

SELECT dc.confere('enrollment pausado não despacha',
  NOT EXISTS (SELECT 1 FROM lote1 l JOIN dc.quem q ON q.mensagem = l.message_id
               WHERE q.rotulo = 'pausado'));

-- Pausa é temporária: cancelar perderia o passo para sempre, porque a chave
-- única (enrollment_id, step_id) impede recriá-lo.
SELECT dc.confere('pausado SEGURA a mensagem, não cancela',
  (SELECT m.status::text FROM messages m JOIN dc.quem q ON q.mensagem = m.id
    WHERE q.rotulo = 'pausado') = 'pendente',
  (SELECT m.status::text FROM messages m JOIN dc.quem q ON q.mensagem = m.id
    WHERE q.rotulo = 'pausado'));

SELECT dc.confere('e quem está normal sai',
  EXISTS (SELECT 1 FROM lote1 l JOIN dc.quem q ON q.mensagem = l.message_id
           WHERE q.rotulo = 'normal'));

-- Despausar devolve a mensagem à fila, sem perder o passo.
UPDATE enrollments SET status = 'ativo'
 WHERE id = (SELECT enrollment FROM dc.quem WHERE rotulo = 'pausado');
UPDATE messages SET reivindicada_em = NULL;

CREATE TEMP TABLE lote2 AS SELECT * FROM reivindicar_pendentes(10);

SELECT dc.confere('despausar devolve a mensagem segurada, com o passo intacto',
  EXISTS (SELECT 1 FROM lote2 l JOIN dc.quem q ON q.mensagem = l.message_id
           WHERE q.rotulo = 'pausado'));

-- ---------------------------------------------------------------------------
-- Campanha desligada
-- ---------------------------------------------------------------------------

UPDATE campaigns SET ativa = false WHERE id = :'camp';
UPDATE messages SET reivindicada_em = NULL;

CREATE TEMP TABLE lote3 AS SELECT * FROM reivindicar_pendentes(10);

SELECT dc.confere('campanha desligada não despacha nada',
  (SELECT count(*) FROM lote3) = 0,
  (SELECT count(*)::text FROM lote3));

SELECT dc.confere('e segura em vez de cancelar — religar a campanha é normal',
  (SELECT count(*) FROM messages m JOIN dc.quem q ON q.mensagem = m.id
    WHERE m.status = 'pendente' AND q.rotulo IN ('pausado','campanha_off','normal')) = 3,
  (SELECT string_agg(q.rotulo || '=' || m.status::text, ' ')
     FROM messages m JOIN dc.quem q ON q.mensagem = m.id));

UPDATE campaigns SET ativa = true WHERE id = :'camp';

-- ---------------------------------------------------------------------------
-- O caso que torna errada a regra óbvia
-- ---------------------------------------------------------------------------

-- No último passo de toda cadência o agendador cria a mensagem e encerra o
-- enrollment com `fim_dos_passos` na MESMA passada. Um filtro de
-- "enrollment ativo" mataria a última mensagem de todas as campanhas.
DO $$
DECLARE v uuid; v_enr uuid; v_fv uuid := gen_random_uuid(); v_flow uuid := gen_random_uuid();
        v_msg uuid; v_status text; v_saiu boolean;
BEGIN
  INSERT INTO flows (id, nome) VALUES (v_flow, 'Um passo só');
  INSERT INTO flow_versions (id, flow_id, versao) VALUES (v_fv, v_flow, 1);
  INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
  VALUES (v_fv, 1, 'whatsapp', 0, 'toque único');

  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15993330000","valor_norm":"5515993330000"}]'::jsonb,'Último');
  SELECT inscrever(v,'ac000000-0000-0000-0000-000000000001', v_fv, now() - interval '1 minute')
    INTO v_enr;
  PERFORM processar_vencidos(10, 'real');

  SELECT id INTO v_msg FROM messages WHERE enrollment_id = v_enr;
  SELECT status::text INTO v_status FROM enrollments WHERE id = v_enr;

  PERFORM dc.confere('o último passo encerra o enrollment na mesma passada que cria a mensagem',
    v_status = 'encerrado'
    AND (SELECT motivo_encerramento FROM enrollments WHERE id = v_enr) = 'fim_dos_passos',
    v_status);

  UPDATE messages SET reivindicada_em = NULL WHERE id = v_msg;
  SELECT EXISTS (SELECT 1 FROM reivindicar_pendentes(10) r WHERE r.message_id = v_msg)
    INTO v_saiu;
  PERFORM dc.confere('e a última mensagem SAI, apesar do enrollment encerrado',
    v_saiu, 'se isto falha, toda campanha perde o último toque');
END;
$$;

-- ---------------------------------------------------------------------------
-- A fila não trava (D77b)
-- ---------------------------------------------------------------------------
--
-- O D77 tirou do lote do agendador a campanha desligada: cem vencidos dela
-- ocupavam o LIMIT de toda batida. O despachante tinha a mesma fila — escolhia
-- as pendentes mais antigas e só depois segurava as da campanha desligada, que
-- voltavam à cabeça. Os dois cenários põem MAIS retidas que o limite antes da
-- mensagem que pode sair; com o limite acima delas, passariam sem a correção.

-- 1. Campanha desligada: doze mensagens, mais antigas que a da campanha ligada.
INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('ac000000-0000-0000-0000-0000000000c2','Desligada','morna','opt-in','{whatsapp}');
DO $$
DECLARE v uuid; i int;
BEGIN
  FOR i IN 1..12 LOOP
    SELECT contact_id INTO v FROM ingerir_contato('00000000-0000-0000-0000-0000000000aa','planilha',
      format('[{"canal":"whatsapp","valor":"159944%s","valor_norm":"55159944%s"}]', lpad(i::text, 4, '0'), lpad(i::text, 4, '0'))::jsonb,
      'Desligada ' || i);
    PERFORM inscrever(v, 'ac000000-0000-0000-0000-0000000000c2', 'ac000000-0000-0000-0000-000000000003',
                      now() - interval '1 minute');
  END LOOP;
END;
$$;
SELECT count(*) FROM processar_vencidos(50, 'real');
UPDATE campaigns SET ativa = false WHERE id = 'ac000000-0000-0000-0000-0000000000c2';
UPDATE messages m SET criado_em = now() - interval '1 hour', reivindicada_em = NULL
  FROM enrollments e WHERE e.id = m.enrollment_id AND e.campaign_id = 'ac000000-0000-0000-0000-0000000000c2';

DO $$
DECLARE v uuid; v_enr uuid;
BEGIN
  SELECT contact_id INTO v FROM ingerir_contato('00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15995550001","valor_norm":"5515995550001"}]'::jsonb, 'Pode sair');
  SELECT inscrever(v, 'ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000003',
                   now() - interval '1 minute') INTO v_enr;
  INSERT INTO dc.quem VALUES ('pode_sair', v, v_enr, NULL);
END;
$$;
SELECT count(*) FROM processar_vencidos(50, 'real');
UPDATE dc.quem q SET mensagem = m.id FROM messages m WHERE m.enrollment_id = q.enrollment AND q.rotulo = 'pode_sair';

CREATE TEMP TABLE lote5 AS SELECT * FROM reivindicar_pendentes(10);
SELECT dc.confere('doze retidas de campanha desligada não seguram a que pode sair (limite 10)',
  EXISTS (SELECT 1 FROM lote5 l JOIN dc.quem q ON q.mensagem = l.message_id WHERE q.rotulo = 'pode_sair'),
  (SELECT count(*)::text || ' no lote' FROM lote5));
SELECT dc.confere('e as da campanha desligada seguem pendentes, sem serem tocadas',
  (SELECT count(*) FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
    WHERE e.campaign_id = 'ac000000-0000-0000-0000-0000000000c2'
      AND m.status = 'pendente' AND m.reivindicada_em IS NULL) = 12);

-- 1b. Parada definitiva com a campanha desligada: quem pediu para sair tem a
-- mensagem cancelada já, como sempre (D39) — o filtro do lote tira só o que
-- seria SEGURADO.
INSERT INTO suppression (tenant_id, contact_id, motivo)
SELECT '00000000-0000-0000-0000-0000000000aa', c.id, 'opt_out' FROM contacts c WHERE c.nome = 'Desligada 1';
CREATE TEMP TABLE lote5b AS SELECT * FROM reivindicar_pendentes(50);
SELECT dc.confere('campanha desligada: a mensagem de quem foi suprimido é cancelada, não fica pendente',
  (SELECT m.status::text FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
     JOIN contacts c ON c.id = e.contact_id WHERE c.nome = 'Desligada 1') = 'cancelado',
  (SELECT m.status::text FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
     JOIN contacts c ON c.id = e.contact_id WHERE c.nome = 'Desligada 1'));
SELECT dc.confere('e as outras onze da campanha desligada seguem pendentes e intocadas',
  (SELECT count(*) FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
    WHERE e.campaign_id = 'ac000000-0000-0000-0000-0000000000c2'
      AND m.status = 'pendente' AND m.reivindicada_em IS NULL) = 11);

-- 2. Sem conta no pool: doze mensagens de uma campanha fria cujo único chip
-- caiu. Elas esperam (D37, D69) — mas atrás das que nunca foram olhadas.
INSERT INTO sender_accounts (id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, config)
VALUES ('ac000000-0000-0000-0000-0000000000f1','whatsapp','+5511900000099','Frio','gupshup','fria',200,
        '{"app_name":"b","source":"2"}'::jsonb);
INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('ac000000-0000-0000-0000-0000000000c3','Fria','fria','prospeccao','{whatsapp}');
DO $$
DECLARE v uuid; i int;
BEGIN
  FOR i IN 1..12 LOOP
    SELECT contact_id INTO v FROM ingerir_contato('00000000-0000-0000-0000-0000000000aa','planilha',
      format('[{"canal":"whatsapp","valor":"159966%s","valor_norm":"55159966%s"}]', lpad(i::text, 4, '0'), lpad(i::text, 4, '0'))::jsonb,
      'Fria ' || i);
    PERFORM inscrever(v, 'ac000000-0000-0000-0000-0000000000c3', 'ac000000-0000-0000-0000-000000000003',
                      now() - interval '1 minute');
  END LOOP;
END;
$$;
SELECT count(*) FROM processar_vencidos(50, 'real');
UPDATE sender_accounts SET estado = 'desativado' WHERE id = 'ac000000-0000-0000-0000-0000000000f1';
UPDATE messages m SET criado_em = now() - interval '1 hour', reivindicada_em = NULL
  FROM enrollments e WHERE e.id = m.enrollment_id AND e.campaign_id = 'ac000000-0000-0000-0000-0000000000c3';

DO $$
DECLARE v uuid; v_enr uuid;
BEGIN
  SELECT contact_id INTO v FROM ingerir_contato('00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15995550002","valor_norm":"5515995550002"}]'::jsonb, 'Pode sair 2');
  SELECT inscrever(v, 'ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000003',
                   now() - interval '1 minute') INTO v_enr;
  INSERT INTO dc.quem VALUES ('pode_sair_2', v, v_enr, NULL);
END;
$$;
SELECT count(*) FROM processar_vencidos(50, 'real');
UPDATE dc.quem q SET mensagem = m.id FROM messages m WHERE m.enrollment_id = q.enrollment AND q.rotulo = 'pode_sair_2';

CREATE TEMP TABLE lote6 AS SELECT * FROM reivindicar_pendentes(10);
CREATE TEMP TABLE lote7 AS SELECT * FROM reivindicar_pendentes(10);
SELECT dc.confere('doze retidas sem conta no pool não seguram a que pode sair: sai em duas batidas',
  EXISTS (SELECT 1 FROM (SELECT * FROM lote6 UNION ALL SELECT * FROM lote7) l
            JOIN dc.quem q ON q.mensagem = l.message_id WHERE q.rotulo = 'pode_sair_2'),
  (SELECT count(*)::text FROM lote6) || ' + ' || (SELECT count(*)::text FROM lote7));
SELECT dc.confere('e as retidas seguem pendentes, no chip delas (a fria não vai para o chip morno)',
  (SELECT count(*) FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
    WHERE e.campaign_id = 'ac000000-0000-0000-0000-0000000000c3' AND m.status = 'pendente'
      AND m.sender_account_id = 'ac000000-0000-0000-0000-0000000000f1') = 12);

-- 3. E a retida não morre de fome: o chip volta, e o agendador enche o lote de
-- mensagens novas a cada batida. A retida espera na vez de quando foi olhada —
-- antes de quem nasceu depois. Pôr as nunca olhadas na frente de todas
-- deixava a retida sem sair enquanto houvesse volume novo.
UPDATE sender_accounts SET estado = 'ativo' WHERE id = 'ac000000-0000-0000-0000-0000000000f1';
DO $$
DECLARE v uuid; i int;
BEGIN
  FOR i IN 1..15 LOOP
    SELECT contact_id INTO v FROM ingerir_contato('00000000-0000-0000-0000-0000000000aa','planilha',
      format('[{"canal":"whatsapp","valor":"159977%s","valor_norm":"55159977%s"}]', lpad(i::text, 4, '0'), lpad(i::text, 4, '0'))::jsonb,
      'Volume ' || i);
    PERFORM inscrever(v, 'ac000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000003',
                      now() - interval '1 minute');
  END LOOP;
END;
$$;
SELECT count(*) FROM processar_vencidos(50, 'real');
CREATE TEMP TABLE lote8 AS SELECT * FROM reivindicar_pendentes(10);
SELECT dc.confere('com o chip de volta e quinze novas na fila, as retidas saem antes das novas',
  (SELECT count(*) FROM lote8 l JOIN messages m ON m.id = l.message_id JOIN enrollments e ON e.id = m.enrollment_id
    WHERE e.campaign_id = 'ac000000-0000-0000-0000-0000000000c3') = 10,
  (SELECT count(*)::text FROM lote8 l JOIN messages m ON m.id = l.message_id JOIN enrollments e ON e.id = m.enrollment_id
    WHERE e.campaign_id = 'ac000000-0000-0000-0000-0000000000c3') || ' das retidas no lote de 10');

-- ---------------------------------------------------------------------------

\echo ''
\echo '============= DESPACHO CONCORDA COM O AGENDADOR ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM dc.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM dc.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM dc.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'despacho: % asserções falharam',
      (SELECT count(*) FROM dc.resultado WHERE NOT ok);
  END IF;
END;
$$;
