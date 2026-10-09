-- Os fatos do contrato chegam à outbox (D45).
--
-- O que este arquivo sustenta: os quatro fatos do D3 são produzidos quando
-- devem, e — as asserções que mais importam — **não** são produzidos quando
-- não devem. Três dos quatro nunca tinham nascido; o risco agora é o oposto,
-- contar ao CRM coisa que não aconteceu.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA wb;
CREATE TABLE wb.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION wb.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO wb.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t 'aa000000-0000-0000-0000-0000000000aa'

-- Cenário: uma campanha de dois passos, com remetente que funciona.
INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('fb000000-0000-0000-0000-000000000001'::uuid,'Resgate','morna','opt-in','{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('fb000000-0000-0000-0000-000000000002'::uuid,'F');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES ('fb000000-0000-0000-0000-000000000003'::uuid,'fb000000-0000-0000-0000-000000000002'::uuid,1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES ('fb000000-0000-0000-0000-000000000003'::uuid,1,'whatsapp',0,'oi'),
       ('fb000000-0000-0000-0000-000000000003'::uuid,2,'whatsapp',48,'e aí');

INSERT INTO sender_accounts (id, canal, identificador, apelido, provedor,
                             tipo_permitido, quota_diaria, config)
VALUES ('fb000000-0000-0000-0000-0000000000a1'::uuid,'whatsapp','+5511900000001','Chip',
        'gupshup','morna',500,'{"app_name":"a","source":"1"}'::jsonb);

CREATE TABLE wb.quem (rotulo text PRIMARY KEY, contato uuid, enrollment uuid);

CREATE FUNCTION wb.criar(p_rotulo text, p_numero text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_c uuid; v_e uuid;
BEGIN
  INSERT INTO contacts (nome, origem) VALUES (p_rotulo, 'teste') RETURNING id INTO v_c;
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_c, 'whatsapp', p_numero, p_numero, 'planilha');
  v_e := inscrever(v_c, 'fb000000-0000-0000-0000-000000000001'::uuid,
                       'fb000000-0000-0000-0000-000000000003'::uuid, now());
  INSERT INTO wb.quem VALUES (p_rotulo, v_c, v_e);
  RETURN v_e;
END;
$$;

CREATE FUNCTION wb.fatos(p_rotulo text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce(string_agg(o.fato::text, ',' ORDER BY o.fato::text), '(nenhum)')
    FROM outbox o JOIN wb.quem q ON q.contato = o.contact_id
   WHERE q.rotulo = p_rotulo;
$$;

-- ---------------------------------------------------------------------------
-- 1. Shadow mode não conta nada ao CRM
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_e uuid;
BEGIN
  v_e := wb.criar('Sombra', '5511900001111');
  -- Duas passadas em simulado levam o enrollment até o fim dos passos.
  PERFORM processar_vencidos(50, 'simulado');
  UPDATE enrollments SET next_run_at = now() - interval '1 minute' WHERE id = v_e;
  PERFORM processar_vencidos(50, 'simulado');

  PERFORM wb.confere('shadow: o enrollment chega mesmo ao fim dos passos',
    (SELECT motivo_encerramento FROM enrollments WHERE id = v_e) = 'fim_dos_passos',
    coalesce((SELECT motivo_encerramento::text FROM enrollments WHERE id = v_e), '(ativo)'));

  PERFORM wb.confere('shadow: e mesmo assim NADA vai para o CRM',
    wb.fatos('Sombra') = '(nenhum)', wb.fatos('Sombra'));
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Fim dos passos de verdade -> campanha_concluida
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_e uuid; r record;
BEGIN
  v_e := wb.criar('Concluida', '5511900002222');
  PERFORM processar_vencidos(50, 'real');
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    PERFORM registrar_resultado_envio(r.message_id, true, 'PROV-1', NULL);
  END LOOP;
  UPDATE enrollments SET next_run_at = now() - interval '1 minute' WHERE id = v_e;
  PERFORM processar_vencidos(50, 'real');
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    PERFORM registrar_resultado_envio(r.message_id, true, 'PROV-2', NULL);
  END LOOP;

  PERFORM wb.confere('fim dos passos vira campanha_concluida',
    wb.fatos('Concluida') = 'campanha_concluida', wb.fatos('Concluida'));

  PERFORM wb.confere('e o payload carrega a campanha, para o CRM saber qual',
    EXISTS (SELECT 1 FROM outbox o JOIN wb.quem q ON q.contato = o.contact_id
             WHERE q.rotulo = 'Concluida'
               AND o.payload ->> 'campaign_id' = 'fb000000-0000-0000-0000-000000000001'));

  PERFORM wb.confere('e nasce com a autoria que o webhook de volta descarta',
    EXISTS (SELECT 1 FROM outbox o JOIN wb.quem q ON q.contato = o.contact_id
             WHERE q.rotulo = 'Concluida' AND o.autoria = 'motor-prospeccao'));
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Enrollment que nunca alcançou ninguém não "concluiu" coisa nenhuma (D35)
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_c uuid; v_e uuid; i integer;
BEGIN
  -- Contato sem identidade no canal dos passos: o motor pula tudo e encerra.
  INSERT INTO contacts (nome, origem) VALUES ('SemCanal', 'teste') RETURNING id INTO v_c;
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_c, 'email', 'sem@exemplo.com', 'sem@exemplo.com', 'planilha');
  v_e := inscrever(v_c, 'fb000000-0000-0000-0000-000000000001'::uuid,
                       'fb000000-0000-0000-0000-000000000003'::uuid, now());
  INSERT INTO wb.quem VALUES ('SemCanal', v_c, v_e);

  -- Até encerrar, com teto. O passo pulado avança o enrollment, mas o
  -- encerramento só vem na passada seguinte à última — foram três, não duas,
  -- e a primeira versão deste teste parou em duas. O enrollment ficava ativo,
  -- nenhum fato nascia, e a asserção de baixo passava sem provar nada: é o
  -- D36 outra vez, asserção que o cenário não consegue violar.
  FOR i IN 1..6 LOOP
    EXIT WHEN (SELECT status FROM enrollments WHERE id = v_e) = 'encerrado';
    UPDATE enrollments SET next_run_at = now() - interval '1 minute'
     WHERE id = v_e AND status = 'ativo';
    PERFORM processar_vencidos(50, 'real');
  END LOOP;

  PERFORM wb.confere('sem identidade, o enrollment encerra como fim dos passos',
    (SELECT motivo_encerramento FROM enrollments WHERE id = v_e) = 'fim_dos_passos',
    coalesce((SELECT motivo_encerramento::text FROM enrollments WHERE id = v_e), '(ativo)'));

  PERFORM wb.confere('e não mandou mensagem nenhuma — é isso que o gate lê',
    NOT EXISTS (SELECT 1 FROM messages WHERE enrollment_id = v_e),
    (SELECT count(*)::text FROM messages WHERE enrollment_id = v_e) || ' mensagem(ns)');

  PERFORM wb.confere('mas o CRM NÃO ouve "campanha concluída" de quem nunca foi contatado',
    wb.fatos('SemCanal') = '(nenhum)', wb.fatos('SemCanal'));
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. Resposta -> respondido, uma vez só, mesmo com várias campanhas
-- ---------------------------------------------------------------------------

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('fb000000-0000-0000-0000-000000000009'::uuid,'Outra','morna','opt-in','{whatsapp}');

DO $$
DECLARE v_c uuid; v_e1 uuid; v_e2 uuid; v_msg uuid; r record; v_n integer;
BEGIN
  INSERT INTO contacts (nome, origem) VALUES ('Respondeu', 'teste') RETURNING id INTO v_c;
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_c, 'whatsapp', '5511900003333', '5511900003333', 'planilha');
  v_e1 := inscrever(v_c, 'fb000000-0000-0000-0000-000000000001'::uuid,
                        'fb000000-0000-0000-0000-000000000003'::uuid, now());
  v_e2 := inscrever(v_c, 'fb000000-0000-0000-0000-000000000009'::uuid,
                        'fb000000-0000-0000-0000-000000000003'::uuid, now());
  INSERT INTO wb.quem VALUES ('Respondeu', v_c, v_e1);

  PERFORM processar_vencidos(50, 'real');
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    PERFORM registrar_resultado_envio(r.message_id, true, 'PROV-R-' || left(r.message_id::text,4), NULL);
  END LOOP;

  SELECT m.id INTO v_msg FROM messages m
   WHERE m.enrollment_id = v_e1 AND m.provider_message_id IS NOT NULL LIMIT 1;
  INSERT INTO message_events (tenant_id, message_id, tipo, payload)
  VALUES (current_setting('app.tenant')::uuid, v_msg, 'respondido', '{"texto":"oi"}'::jsonb);

  PERFORM wb.confere('os DOIS enrollments encerram por resposta (invariante 4)',
    (SELECT count(*) FROM enrollments
      WHERE contact_id = v_c AND motivo_encerramento = 'resposta') = 2,
    (SELECT count(*)::text FROM enrollments
      WHERE contact_id = v_c AND motivo_encerramento = 'resposta'));

  SELECT count(*) INTO v_n FROM outbox
   WHERE contact_id = v_c AND fato = 'respondido';
  PERFORM wb.confere('e o CRM ouve "respondeu" UMA vez, não duas',
    v_n = 1, v_n::text || ' linha(s)');
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Supressão -> opt_out
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_c uuid; v_n integer;
BEGIN
  INSERT INTO contacts (nome, origem) VALUES ('Saiu', 'teste') RETURNING id INTO v_c;
  INSERT INTO wb.quem VALUES ('Saiu', v_c, NULL);
  INSERT INTO suppression (contact_id, motivo) VALUES (v_c, 'pediu para sair');

  PERFORM wb.confere('entrar na supressão vira opt_out no CRM',
    wb.fatos('Saiu') = 'opt_out', wb.fatos('Saiu'));

  PERFORM wb.confere('e o motivo vai junto, para o CRM não inventar o porquê',
    EXISTS (SELECT 1 FROM outbox WHERE contact_id = v_c
              AND payload ->> 'motivo' = 'pediu para sair'));

  -- Supressão por identidade não tem pessoa para citar.
  SELECT count(*) INTO v_n FROM outbox;
  INSERT INTO suppression (canal, valor_norm, motivo)
  VALUES ('whatsapp', '5511999998888', 'número na blocklist');
  PERFORM wb.confere('supressão sem contato não gera fato — não há pessoa a citar',
    (SELECT count(*) FROM outbox) = v_n);
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. O que NÃO vira fato
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_c uuid; v_e uuid; r record; v_n integer;
BEGIN
  -- Encerramento vindo do CRM não volta para o CRM: seria o eco do D3.
  INSERT INTO contacts (nome, origem) VALUES ('VeioDoCrm', 'teste') RETURNING id INTO v_c;
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_c, 'whatsapp', '5511900004444', '5511900004444', 'planilha');
  v_e := inscrever(v_c, 'fb000000-0000-0000-0000-000000000001'::uuid,
                       'fb000000-0000-0000-0000-000000000003'::uuid, now());
  INSERT INTO wb.quem VALUES ('VeioDoCrm', v_c, v_e);

  PERFORM processar_vencidos(50, 'real');
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    PERFORM registrar_resultado_envio(r.message_id, true, 'PROV-C', NULL);
  END LOOP;

  SELECT count(*) INTO v_n FROM outbox WHERE contact_id = v_c;
  PERFORM encerrar_enrollment(v_e, 'mudanca_etapa_crm');
  PERFORM wb.confere('encerramento vindo do CRM não volta ao CRM (eco do D3)',
    (SELECT count(*) FROM outbox WHERE contact_id = v_c) = v_n,
    wb.fatos('VeioDoCrm'));
END;
$$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM wb.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM wb.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM wb.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'writeback: % asserção(ões) falharam', n; END IF;
END;
$$;
