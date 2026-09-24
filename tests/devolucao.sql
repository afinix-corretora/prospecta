-- Devolução e denúncia não são a mesma coisa (D49).
--
-- A operação pediu que os dois suprimam. Suprimem — mas de formas diferentes,
-- e a asserção que mais importa aqui é a NEGATIVA: devolução permanente não
-- pode escrever `opt_out` no CRM, porque ninguém manifestou vontade nenhuma.
-- Caixa que não existe é fato sobre o endereço.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA dv;
CREATE TABLE dv.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION dv.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO dv.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('00000000-0000-0000-0000-0000000000b1','Devolucao','morna','opt-in','{email}');
INSERT INTO flows (id, nome) VALUES ('00000000-0000-0000-0000-0000000000b2','F');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES ('00000000-0000-0000-0000-0000000000b3','00000000-0000-0000-0000-0000000000b2',1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('00000000-0000-0000-0000-0000000000b3',1,'email',0,'oi'),
  ('00000000-0000-0000-0000-0000000000b3',2,'email',48,'e ai');
INSERT INTO sender_accounts (id, canal, identificador, apelido, provedor,
                             tipo_permitido, quota_diaria, config)
VALUES ('00000000-0000-0000-0000-0000000000b4','email','envio@afinix.com.br','Caixa',
        'resend','morna',500,'{"nome_remetente":"Afinix","responder_para":"c@a.com","assunto_padrao":"oi"}'::jsonb);

-- Devolve a mensagem criada, e deixa contato e identidade acessíveis.
CREATE FUNCTION dv.cenario(p_rotulo text, p_email text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_c uuid; v_e uuid; v_m uuid; r record;
BEGIN
  v_c := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_c, p_rotulo, 'planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_c, 'email', p_email, p_email, 'planilha');
  v_e := inscrever(v_c, '00000000-0000-0000-0000-0000000000b1',
                   '00000000-0000-0000-0000-0000000000b3', now() - interval '1 minute');
  PERFORM processar_vencidos(50, 'real');
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    PERFORM registrar_resultado_envio(r.message_id, true, 'PROV-' || p_rotulo, NULL);
  END LOOP;
  SELECT id INTO v_m FROM messages WHERE enrollment_id = v_e ORDER BY criado_em LIMIT 1;
  RETURN v_m;
END;
$$;

-- ===========================================================================
-- 1. Denúncia é vontade: suprime a pessoa, e o CRM ouve opt_out
-- ===========================================================================

DO $$
DECLARE v_msg uuid; v_contato uuid; v_n integer;
BEGIN
  v_msg := dv.cenario('Denunciou', 'denunciou@exemplo.com');
  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;

  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'denuncia', '{"evento":"email.complained"}'::jsonb);

  SELECT count(*) INTO v_n FROM suppression
   WHERE contact_id = v_contato AND canal IS NULL;
  PERFORM dv.confere('denúncia suprime a PESSOA, em todo canal', v_n = 1, v_n::text);

  SELECT count(*) INTO v_n FROM outbox WHERE contact_id = v_contato AND fato = 'opt_out';
  PERFORM dv.confere('e o CRM ouve opt_out — houve vontade', v_n = 1, v_n::text);
END;
$$;

-- ===========================================================================
-- 2. Devolução permanente é fato sobre o endereço
-- ===========================================================================

DO $$
DECLARE v_msg uuid; v_contato uuid; v_ident uuid; v_n integer; v_valida boolean;
BEGIN
  v_msg := dv.cenario('Caixa Morta', 'morto@exemplo.com');
  SELECT e.contact_id, m.contact_identity_id INTO v_contato, v_ident
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;

  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'devolvido',
          '{"evento":"email.bounced","permanente":true}'::jsonb);

  SELECT valida INTO v_valida FROM contact_identities WHERE id = v_ident;
  PERFORM dv.confere('devolução permanente invalida a identidade', v_valida = false,
    coalesce(v_valida::text,'(nulo)'));

  SELECT count(*) INTO v_n FROM suppression
   WHERE canal = 'email' AND valor_norm = 'morto@exemplo.com';
  PERFORM dv.confere('e suprime o ENDEREÇO', v_n = 1, v_n::text);

  SELECT count(*) INTO v_n FROM suppression
   WHERE contact_id = v_contato AND canal IS NULL;
  PERFORM dv.confere('mas NÃO suprime a pessoa — o telefone dela continua bom',
    v_n = 0, v_n::text);

  -- A asserção central deste arquivo.
  SELECT count(*) INTO v_n FROM outbox WHERE contact_id = v_contato AND fato = 'opt_out';
  PERFORM dv.confere('e o CRM NÃO ouve opt_out: ninguém manifestou vontade',
    v_n = 0, v_n::text);

  SELECT count(*) INTO v_n FROM outbox
   WHERE contact_id = v_contato AND fato = 'identidade_invalida';
  PERFORM dv.confere('o CRM ouve identidade_invalida, que é o fato certo',
    v_n >= 1, v_n::text);

  -- Por que a supressão por endereço existe, e não só a invalidação.
  --
  -- Minha primeira resposta foi "sobrevive à reimportação", e estava errada:
  -- a identidade é única por (tenant, canal, valor) e a ingestão não a
  -- ressuscita. A razão real é o D37 aplicado a identidades: invalidar decide
  -- o futuro, mas a mensagem JÁ PENDENTE carrega a identidade na linha, e
  -- quem a barra no despacho é `esta_suprimido` — `valida` ele não olha.
  --
  -- O cenário abaixo encena exatamente essa janela.
  PERFORM dv.confere('a identidade não foi ressuscitada por reimportar',
    (SELECT count(*) FROM contact_identities
      WHERE valor_norm = 'morto@exemplo.com') = 1);
END;
$$;

DO $$
DECLARE v_msg uuid; v_contato uuid; v_enr uuid; v_pendente uuid; v_status text; v_n integer;
BEGIN
  v_msg := dv.cenario('Em Voo', 'emvoo@exemplo.com');
  SELECT e.id, e.contact_id INTO v_enr, v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;

  -- O passo 2 nasce ANTES da devolução chegar: é a janela do D37.
  UPDATE enrollments SET next_run_at = now() - interval '1 minute' WHERE id = v_enr;
  PERFORM processar_vencidos(50, 'real');
  SELECT id INTO v_pendente FROM messages
   WHERE enrollment_id = v_enr AND status = 'pendente' ORDER BY criado_em DESC LIMIT 1;
  PERFORM dv.confere('há uma mensagem pendente antes da devolução chegar',
    v_pendente IS NOT NULL);

  -- Agora a devolução permanente do passo 1.
  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'devolvido', '{"permanente":true}'::jsonb);

  -- O despachante tem de cancelá-la. Sem a supressão por endereço ela sairia
  -- para uma caixa morta — e em e-mail devolver de novo derruba a reputação
  -- do domínio, que é o ativo que faz as próximas chegarem.
  PERFORM reivindicar_pendentes(50);
  SELECT status::text INTO v_status FROM messages WHERE id = v_pendente;
  PERFORM dv.confere('a mensagem em voo para o endereço morto é cancelada',
    v_status = 'cancelado', coalesce(v_status,'(nulo)'));

  -- Segunda devolução do mesmo endereço não duplica a supressão.
  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'devolvido', '{"permanente":true}'::jsonb);
  SELECT count(*) INTO v_n FROM suppression
   WHERE canal = 'email' AND valor_norm = 'emvoo@exemplo.com';
  PERFORM dv.confere('duas devoluções não viram duas supressões', v_n = 1, v_n::text);
END;
$$;

-- ===========================================================================
-- 3. Devolução temporária não pode custar um contato bom
-- ===========================================================================

DO $$
DECLARE v_msg uuid; v_contato uuid; v_ident uuid; v_n integer; v_valida boolean;
BEGIN
  v_msg := dv.cenario('Caixa Cheia', 'cheia@exemplo.com');
  SELECT e.contact_id, m.contact_identity_id INTO v_contato, v_ident
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;

  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'devolvido',
          '{"evento":"email.bounced","permanente":false}'::jsonb);

  SELECT count(*) INTO v_n FROM suppression WHERE valor_norm = 'cheia@exemplo.com';
  PERFORM dv.confere('devolução temporária não suprime', v_n = 0, v_n::text);

  SELECT valida INTO v_valida FROM contact_identities WHERE id = v_ident;
  PERFORM dv.confere('nem invalida a identidade', v_valida = true,
    coalesce(v_valida::text,'(nulo)'));

  -- O caso que mais vai acontecer: provedor que não diz. O default é não
  -- suprimir, porque suprimir é irreversível.
  v_msg := dv.cenario('Sem Dizer', 'semdizer@exemplo.com');
  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'devolvido', '{"evento":"email.bounced"}'::jsonb);
  SELECT count(*) INTO v_n FROM suppression WHERE valor_norm = 'semdizer@exemplo.com';
  PERFORM dv.confere('devolução sem dizer se é permanente NÃO suprime', v_n = 0, v_n::text);
END;
$$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM dv.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM dv.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM dv.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'devolucao: % asserção(ões) falharam', n; END IF;
END;
$$;
