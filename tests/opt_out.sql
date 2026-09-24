-- Quem pede para sair, sai (D48).
--
-- Duas metades, e a segunda é a que custa dinheiro:
--
--   1. o pedido de saída é reconhecido, suprime a pessoa inteira e chega ao
--      CRM como opt_out (pelo gatilho do D45);
--   2. o lead VIVO não é suprimido por engano. Supressão é imutável: um falso
--      positivo aqui apaga um cliente para sempre, e as frases perigosas são
--      justamente as que parecem opt-out e são intenção de compra.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA oo;
CREATE TABLE oo.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION oo.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO oo.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

-- ===========================================================================
-- 1. O classificador, nas duas direções
-- ===========================================================================

-- Frases que TÊM de suprimir.
DO $$
DECLARE f text; v_escapou text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'PARE',
    'pare de me mandar mensagem',
    'para de me mandar mensagem',
    'parem de me enviar mensagens',
    'me tira dessa lista',
    'me tire do cadastro',
    'nao quero mais receber nada',
    'quero sair da lista',
    'pode descartar',
    'descartar meu cadastro',
    'nao tenho interesse',
    'sem interesse',
    'isso e spam',
    'me descadastre',
    'nao perturbe',
    'REMOVER DA LISTA AGORA'
  ] LOOP
    IF privado.pedido_de_saida(f) IS NULL THEN
      v_escapou := v_escapou || f || ' | ';
    END IF;
  END LOOP;
  PERFORM oo.confere('todo pedido de saída é reconhecido', v_escapou = '', v_escapou);
END;
$$;

-- Frases que NÃO podem suprimir. Cada uma é um lead vivo, e três delas contêm
-- literalmente um termo da lista — é por isso que o contexto existe.
DO $$
DECLARE f text; v_pego text := '';
BEGIN
  FOREACH f IN ARRAY ARRAY[
    -- contém "sair": intenção de trocar de operadora é o melhor lead que há
    'quero sair do meu plano da Amil',
    -- contém "nao quero": é resposta de compra
    'nao quero individual, quero empresarial',
    -- contém "descartar": quem compara está engajado
    'vou comparar e descartar as opcoes ruins',
    -- contém "tira": pergunta é engajamento
    'me tira uma duvida sobre carencia',
    -- contém "parar de": quem quer parar de pagar caro quer comprar
    'quero parar de pagar tao caro, tem opcao melhor?',
    -- "pare" dentro de outra palavra não pode casar
    'me manda mais detalhes do preparo',
    -- "para de" como preposição
    'liga para de manha',
    'esse valor e para de quantas vidas?',
    'quanto custa? quero saber mais',
    ''
  ] LOOP
    IF privado.pedido_de_saida(f) IS NOT NULL THEN
      v_pego := v_pego || f || ' -> ' || privado.pedido_de_saida(f) || ' | ';
    END IF;
  END LOOP;
  PERFORM oo.confere('nenhum lead vivo é suprimido por engano', v_pego = '', v_pego);
END;
$$;

-- ===========================================================================
-- 2. Do texto à supressão, e da supressão ao CRM
-- ===========================================================================

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('00000000-0000-0000-0000-0000000000e1','Opt out','morna','opt-in','{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('00000000-0000-0000-0000-0000000000e2','F');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES ('00000000-0000-0000-0000-0000000000e3','00000000-0000-0000-0000-0000000000e2',1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('00000000-0000-0000-0000-0000000000e3',1,'whatsapp',0,'oi'),
  ('00000000-0000-0000-0000-0000000000e3',2,'whatsapp',48,'e ai');
INSERT INTO sender_accounts (id, canal, identificador, apelido, provedor,
                             tipo_permitido, quota_diaria, config)
VALUES ('00000000-0000-0000-0000-0000000000e4','whatsapp','+5511960000000','Chip OO',
        'gupshup','morna',500,'{"app_name":"a","source":"1"}'::jsonb);

CREATE FUNCTION oo.cenario(p_rotulo text, p_numero text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_c uuid; v_e uuid; v_m uuid; r record;
BEGIN
  v_c := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_c, p_rotulo, 'planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_c, 'whatsapp', p_numero, p_numero, 'planilha');
  v_e := inscrever(v_c, '00000000-0000-0000-0000-0000000000e1',
                   '00000000-0000-0000-0000-0000000000e3', now() - interval '1 minute');
  PERFORM processar_vencidos(50, 'real');
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    PERFORM registrar_resultado_envio(r.message_id, true, 'PROV-' || p_rotulo, NULL);
  END LOOP;
  SELECT id INTO v_m FROM messages WHERE enrollment_id = v_e ORDER BY criado_em LIMIT 1;
  RETURN v_m;
END;
$$;

DO $$
DECLARE v_msg uuid; v_contato uuid; v_n integer; v_motivo text;
BEGIN
  v_msg := oo.cenario('Quer Sair', '5511960000101');
  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;

  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'respondido', '{"texto":"pode parar de me mandar mensagem"}'::jsonb);

  SELECT count(*), max(motivo) INTO v_n, v_motivo
    FROM suppression WHERE contact_id = v_contato AND canal IS NULL;
  PERFORM oo.confere('resposta com pedido de saída suprime o contato inteiro',
    v_n = 1, v_n::text);
  -- A asserção pergunta o que importa — o motivo carrega UM TERMO REAL da
  -- lista — e não qual termo ganhou. Fixar o termo esperado seria frágil: a
  -- frase de teste casa tanto "parar" (com contexto "mandar") quanto "para
  -- de", e as duas leituras estão certas.
  PERFORM oo.confere('e o motivo guarda o termo que casou, para auditoria',
    v_motivo LIKE '%termo: %'
    AND EXISTS (SELECT 1 FROM opt_out_termos o
                 WHERE o.termo = rtrim(split_part(v_motivo, 'termo: ', 2), ')')),
    coalesce(v_motivo,'(nulo)'));

  PERFORM oo.confere('a cadência dele encerrou',
    (SELECT bool_and(status = 'encerrado') FROM enrollments WHERE contact_id = v_contato));

  -- E o CRM fica sabendo, pelo gatilho do D45 — sem esta migration mandar nada.
  SELECT count(*) INTO v_n FROM outbox
   WHERE contact_id = v_contato AND fato = 'opt_out';
  PERFORM oo.confere('o CRM ouve opt_out, pelo caminho do D45', v_n = 1, v_n::text);

  -- Segunda resposta igual não duplica a supressão.
  v_msg := oo.cenario('Quer Sair 2', '5511960000102');
  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'respondido', '{"texto":"PARE"}'::jsonb);
  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'respondido', '{"texto":"pare mesmo"}'::jsonb);
  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;
  SELECT count(*) INTO v_n FROM suppression
   WHERE contact_id = v_contato AND canal IS NULL;
  PERFORM oo.confere('duas respostas de saída não viram duas supressões', v_n = 1, v_n::text);
END;
$$;

-- ===========================================================================
-- 3. O que NÃO pode acontecer
-- ===========================================================================

DO $$
DECLARE v_msg uuid; v_contato uuid; v_n integer;
BEGIN
  -- Lead vivo responde. Encerra a cadência (invariante 4) e NÃO suprime.
  v_msg := oo.cenario('Lead Vivo', '5511960000201');
  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;

  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'respondido',
          '{"texto":"quero sair do meu plano atual, me manda uma proposta"}'::jsonb);

  PERFORM oo.confere('lead vivo: a cadência encerra (invariante 4)',
    (SELECT bool_and(status = 'encerrado') FROM enrollments WHERE contact_id = v_contato));

  SELECT count(*) INTO v_n FROM suppression WHERE contact_id = v_contato;
  PERFORM oo.confere('lead vivo NÃO é suprimido', v_n = 0, v_n::text);

  SELECT count(*) INTO v_n FROM outbox WHERE contact_id = v_contato AND fato = 'opt_out';
  PERFORM oo.confere('e o CRM não ouve opt_out dele', v_n = 0, v_n::text);

  -- Resposta sem texto nenhum — é o caso do SMS, que não tem webhook de
  -- entrada, e de provedor que só manda metadado. Não pode explodir nem
  -- suprimir.
  v_msg := oo.cenario('Sem Texto', '5511960000202');
  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;
  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'respondido', '{"de":"5511960000202"}'::jsonb);
  SELECT count(*) INTO v_n FROM suppression WHERE contact_id = v_contato;
  PERFORM oo.confere('resposta sem texto não suprime e não quebra', v_n = 0, v_n::text);

  -- Clique não é resposta e não olha texto nenhum (D7).
  v_msg := oo.cenario('Clicou', '5511960000203');
  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id WHERE m.id = v_msg;
  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (v_msg, 'clique', '{"texto":"PARE"}'::jsonb);
  SELECT count(*) INTO v_n FROM suppression WHERE contact_id = v_contato;
  PERFORM oo.confere('clique não suprime, mesmo com texto de saída no payload',
    v_n = 0, v_n::text);
END;
$$;

-- ===========================================================================
-- 4. A lista é editável sem tocar em lógica
-- ===========================================================================

DO $$
DECLARE v_antes text; v_depois text;
BEGIN
  v_antes := coalesce(privado.pedido_de_saida('chega disso tudo'), '(nenhum)');
  INSERT INTO opt_out_termos (termo, exige_uma_de, nota)
  VALUES ('chega disso', NULL, 'termo de teste');
  v_depois := coalesce(privado.pedido_de_saida('chega disso tudo'), '(nenhum)');
  PERFORM oo.confere('acrescentar um termo à tabela muda o resultado, sem tocar em código',
    v_antes = '(nenhum)' AND v_depois = 'chega disso', v_antes || ' -> ' || v_depois);
  DELETE FROM opt_out_termos WHERE termo = 'chega disso';
END;
$$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM oo.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM oo.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM oo.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'opt out: % asserção(ões) falharam', n; END IF;
END;
$$;
