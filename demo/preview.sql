-- Preview: uma cadência real rodando ao longo de dias.
--
-- Semeia duas campanhas com situações que valem a pena ver, avança o relógio
-- de evento em evento e registra cada decisão do motor. O provedor é simulado
-- aqui dentro (em produção quem responde é o adapter), mas o agendador, o
-- roteador, o pool e as quatro invariantes são os de verdade.
--
-- Roda com: demo/gerar.sh

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA p;

-- Relógio virtual: o motor usa now(), então "avançar dias" é puxar os
-- next_run_at para trás e anotar quanto tempo passou.
CREATE TABLE p.relogio (decorrido interval NOT NULL DEFAULT interval '0');
INSERT INTO p.relogio VALUES (interval '0');

CREATE TABLE p.linha (
  id serial PRIMARY KEY,
  momento    interval NOT NULL,
  ator       text NOT NULL,     -- motor | provedor | pessoa | operador
  contato    text,
  acao       text NOT NULL,
  detalhe    text NOT NULL DEFAULT '',
  canal      text,
  remetente  text
);

CREATE FUNCTION p.agora() RETURNS interval
LANGUAGE sql AS $$ SELECT decorrido FROM p.relogio $$;

CREATE FUNCTION p.registrar(
  p_ator text, p_contato text, p_acao text,
  p_detalhe text DEFAULT '', p_canal text DEFAULT NULL, p_remetente text DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
  INSERT INTO p.linha (momento, ator, contato, acao, detalhe, canal, remetente)
  VALUES (p.agora(), p_ator, p_contato, p_acao, p_detalhe, p_canal, p_remetente);
$$;

-- ---------------------------------------------------------------------------
-- Cenário
-- ---------------------------------------------------------------------------

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados) VALUES
  ('aa000000-0000-0000-0000-000000000001','Resgate 2024','morna',
   'legitimo interesse - base propria com opt-in','{whatsapp,email}'),
  ('aa000000-0000-0000-0000-000000000002','Lista fria SP','fria',
   'legitimo interesse - prospeccao B2B','{whatsapp}');

INSERT INTO flows (id, nome) VALUES
  ('bb000000-0000-0000-0000-000000000001','Cadência de resgate'),
  ('bb000000-0000-0000-0000-000000000002','Cadência fria');

INSERT INTO flow_versions (id, flow_id, versao) VALUES
  ('cc000000-0000-0000-0000-000000000001','bb000000-0000-0000-0000-000000000001',1),
  ('cc000000-0000-0000-0000-000000000002','bb000000-0000-0000-0000-000000000002',1);

INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('cc000000-0000-0000-0000-000000000001',1,'whatsapp', 0,
   'Oi {{nome}}, aqui é da Afinix. Você chegou a olhar o plano que conversamos?'),
  ('cc000000-0000-0000-0000-000000000001',2,'email',   48,
   '{{nome}}, separei duas opções que cabem no que você falou.'),
  ('cc000000-0000-0000-0000-000000000001',3,'whatsapp',72,
   '{{nome}}, ainda faz sentido retomar? Se não, é só me dizer.'),
  ('cc000000-0000-0000-0000-000000000002',1,'whatsapp', 0,
   'Olá {{nome}}, trabalho com plano de saúde empresarial em {{cidade}}.'),
  ('cc000000-0000-0000-0000-000000000002',2,'whatsapp',96,
   '{{nome}}, consigo fazer uma cotação sem compromisso. Faz sentido?');

-- Pool: morno e frio separados por schema, não por disciplina (D4).
INSERT INTO sender_accounts (id, canal, identificador, provedor, tipo_permitido, quota_diaria) VALUES
  ('dd000000-0000-0000-0000-000000000001','whatsapp','+55 11 99000-0001','meta_cloud','morna',200),
  ('dd000000-0000-0000-0000-000000000002','email','resgate@afinix-relaciona.com.br','smtp','morna',300),
  -- Chip frio com quota baixa de propósito: é o que faz o freio aparecer.
  ('dd000000-0000-0000-0000-000000000003','whatsapp','+55 11 98000-0009','evolution','fria',2);

-- Sete pessoas, cada uma mostrando uma coisa diferente.
INSERT INTO contacts (id, nome, origem, metadados) VALUES
  ('e1000000-0000-0000-0000-000000000001','Marina Alves','planilha','{"cidade":"Santos"}'),
  ('e1000000-0000-0000-0000-000000000002','Otávio Lima','planilha','{"cidade":"São Paulo"}'),
  ('e1000000-0000-0000-0000-000000000003','Paula Ribeiro','planilha','{"cidade":"Campinas"}'),
  ('e1000000-0000-0000-0000-000000000004','Rui Nogueira','pipefy','{"cidade":"Santos"}'),
  ('e1000000-0000-0000-0000-000000000005','Sônia Prado','planilha','{"cidade":"São Paulo"}'),
  ('e1000000-0000-0000-0000-000000000006','Tulio Barros','planilha','{"cidade":"Guarulhos"}'),
  ('e1000000-0000-0000-0000-000000000007','Vera Castro','planilha','{"cidade":"Osasco"}');

INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem) VALUES
  ('e1000000-0000-0000-0000-000000000001','whatsapp','+5511990001001','5511990001001','planilha'),
  ('e1000000-0000-0000-0000-000000000001','email','marina@exemplo.com','marina@exemplo.com','planilha'),
  ('e1000000-0000-0000-0000-000000000002','whatsapp','+5511990001002','5511990001002','planilha'),
  ('e1000000-0000-0000-0000-000000000002','email','otavio@exemplo.com','otavio@exemplo.com','planilha'),
  -- Paula não tem e-mail: o passo 2 dela não tem por onde sair.
  ('e1000000-0000-0000-0000-000000000003','whatsapp','+5511990001003','5511990001003','planilha'),
  ('e1000000-0000-0000-0000-000000000004','whatsapp','+5511990001004','5511990001004','pipefy'),
  ('e1000000-0000-0000-0000-000000000004','email','rui@exemplo.com','rui@exemplo.com','pipefy'),
  ('e1000000-0000-0000-0000-000000000005','whatsapp','+5511990001005','5511990001005','planilha'),
  ('e1000000-0000-0000-0000-000000000006','whatsapp','+5511990001006','5511990001006','planilha'),
  ('e1000000-0000-0000-0000-000000000007','whatsapp','+5511990001007','5511990001007','planilha');

-- Tulio já tinha pedido para sair antes de a campanha começar.
INSERT INTO suppression (contact_id, motivo)
VALUES ('e1000000-0000-0000-0000-000000000006','opt-out registrado na campanha anterior');

-- ---------------------------------------------------------------------------
-- Ingestão
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_id uuid;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('e1000000-0000-0000-0000-000000000001'::uuid,'Marina Alves','aa000000-0000-0000-0000-000000000001'::uuid,'cc000000-0000-0000-0000-000000000001'::uuid),
      ('e1000000-0000-0000-0000-000000000002','Otávio Lima','aa000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001'),
      ('e1000000-0000-0000-0000-000000000003','Paula Ribeiro','aa000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001'),
      ('e1000000-0000-0000-0000-000000000004','Rui Nogueira','aa000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001'),
      ('e1000000-0000-0000-0000-000000000006','Tulio Barros','aa000000-0000-0000-0000-000000000001','cc000000-0000-0000-0000-000000000001'),
      ('e1000000-0000-0000-0000-000000000005','Sônia Prado','aa000000-0000-0000-0000-000000000002','cc000000-0000-0000-0000-000000000002'),
      ('e1000000-0000-0000-0000-000000000007','Vera Castro','aa000000-0000-0000-0000-000000000002','cc000000-0000-0000-0000-000000000002')
    ) AS v(contato, nome, campanha, versao)
  LOOP
    v_id := inscrever(r.contato, r.campanha, r.versao, now());
    IF v_id IS NULL THEN
      PERFORM p.registrar('motor', r.nome, 'inscricao_recusada',
        'já estava na supressão — nem chega a criar estado');
    ELSE
      PERFORM p.registrar('motor', r.nome, 'inscrito',
        (SELECT nome FROM campaigns WHERE id = r.campanha));
    END IF;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- O laço: avança para o próximo evento agendado e roda uma passada
-- ---------------------------------------------------------------------------

CREATE FUNCTION p.avancar_relogio() RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_proximo timestamptz; v_delta interval;
BEGIN
  SELECT min(next_run_at) INTO v_proximo FROM enrollments
   WHERE status = 'ativo' AND next_run_at IS NOT NULL;
  IF v_proximo IS NULL THEN RETURN false; END IF;

  v_delta := greatest(v_proximo - now(), interval '0');
  UPDATE enrollments SET next_run_at = next_run_at - v_delta
   WHERE status = 'ativo' AND next_run_at IS NOT NULL;
  UPDATE p.relogio SET decorrido = decorrido + v_delta;
  RETURN true;
END;
$$;

CREATE FUNCTION p.nome_de(p_enrollment uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT c.nome FROM enrollments e JOIN contacts c ON c.id = e.contact_id WHERE e.id = p_enrollment;
$$;

-- Provedor simulado: em produção é o adapter que faz o HTTP e devolve isto.
CREATE FUNCTION p.responder_provedor() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r record; v_nome text; v_id text;
BEGIN
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    v_nome := (SELECT c.nome FROM messages m
                 JOIN enrollments e ON e.id = m.enrollment_id
                 JOIN contacts c ON c.id = e.contact_id
                WHERE m.id = r.message_id);
    v_id := 'PROV-' || substr(r.message_id::text, 1, 8);

    -- O número da Vera não existe no WhatsApp: culpa do destino.
    IF v_nome = 'Vera Castro' THEN
      PERFORM registrar_resultado_envio(r.message_id, false, NULL,
        'not a WhatsApp user', 'destino');
      PERFORM p.registrar('provedor', v_nome, 'rejeitado',
        'número não existe no WhatsApp', r.canal::text, r.sender_ident);
    ELSE
      PERFORM registrar_resultado_envio(r.message_id, true, v_id, NULL);
      PERFORM p.registrar('provedor', v_nome, 'entregue_ao_provedor',
        v_id, r.canal::text, r.sender_ident);
    END IF;
  END LOOP;
END;
$$;

DO $$
DECLARE
  r record; v_passada integer := 0; v_nome text;
  v_msg uuid; v_prov text;
BEGIN
  WHILE v_passada < 40 LOOP
    v_passada := v_passada + 1;
    EXIT WHEN NOT p.avancar_relogio();

    FOR r IN SELECT * FROM processar_vencidos(100, 'real') LOOP
      v_nome := p.nome_de(r.enrollment_id);
      PERFORM p.registrar('motor', v_nome, r.acao, r.detalhe,
        (SELECT m.canal::text FROM messages m
          WHERE m.enrollment_id = r.enrollment_id ORDER BY m.criado_em DESC LIMIT 1),
        (SELECT sa.identificador FROM messages m
           JOIN sender_accounts sa ON sa.id = m.sender_account_id
          WHERE m.enrollment_id = r.enrollment_id ORDER BY m.criado_em DESC LIMIT 1));
    END LOOP;

    PERFORM p.responder_provedor();

    -- Otávio responde depois do primeiro contato.
    IF p.agora() >= interval '3 hours' AND NOT EXISTS (
      SELECT 1 FROM p.linha WHERE contato = 'Otávio Lima' AND acao = 'respondeu')
    THEN
      SELECT m.id, m.provider_message_id INTO v_msg, v_prov FROM messages m
        JOIN enrollments e ON e.id = m.enrollment_id
       WHERE e.contact_id = 'e1000000-0000-0000-0000-000000000002'
         AND m.provider_message_id IS NOT NULL
       ORDER BY m.criado_em DESC LIMIT 1;
      IF v_prov IS NOT NULL THEN
        PERFORM registrar_evento_provedor(v_prov, 'respondido', now(),
          '{"texto":"oi, pode me mandar os valores?"}'::jsonb);
        PERFORM p.registrar('pessoa','Otávio Lima','respondeu',
          'oi, pode me mandar os valores?','whatsapp');
      END IF;
    END IF;

    -- Marina clica no link do e-mail, mas não responde (D7).
    IF p.agora() >= interval '50 hours' AND NOT EXISTS (
      SELECT 1 FROM p.linha WHERE contato = 'Marina Alves' AND acao = 'clicou')
    THEN
      SELECT m.provider_message_id INTO v_prov FROM messages m
        JOIN enrollments e ON e.id = m.enrollment_id
       WHERE e.contact_id = 'e1000000-0000-0000-0000-000000000001'
         AND m.canal = 'email' AND m.provider_message_id IS NOT NULL
       ORDER BY m.criado_em DESC LIMIT 1;
      IF v_prov IS NOT NULL THEN
        PERFORM registrar_evento_provedor(v_prov, 'clique', now(), '{}'::jsonb);
        PERFORM p.registrar('pessoa','Marina Alves','clicou',
          'abriu o link do e-mail — engajamento, não resposta','email');
      END IF;
    END IF;

    -- No dia 2, alguém pede para sair por outro canal.
    IF p.agora() >= interval '30 hours' AND NOT EXISTS (
      SELECT 1 FROM suppression WHERE contact_id = 'e1000000-0000-0000-0000-000000000003')
    THEN
      INSERT INTO suppression (contact_id, motivo)
      VALUES ('e1000000-0000-0000-0000-000000000003','pediu remoção por telefone');
      PERFORM p.registrar('operador','Paula Ribeiro','suprimida',
        'pediu remoção por telefone; entra na lista global');
    END IF;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Saída
-- ---------------------------------------------------------------------------

\pset format unaligned
\pset tuples_only on

SELECT jsonb_pretty(jsonb_build_object(
  'linha', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'momento', (extract(epoch from momento) / 3600)::int,
      'ator', ator, 'contato', contato, 'acao', acao,
      'detalhe', detalhe, 'canal', canal, 'remetente', remetente
    ) ORDER BY id), '[]'::jsonb) FROM p.linha),

  'enrollments', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', c.nome, 'campanha', ca.nome, 'status', e.status,
      'passo', e.passo_atual, 'motivo', e.motivo_encerramento
    ) ORDER BY c.nome), '[]'::jsonb)
    FROM enrollments e JOIN contacts c ON c.id = e.contact_id
    JOIN campaigns ca ON ca.id = e.campaign_id),

  'mensagens', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', c.nome, 'canal', m.canal, 'status', m.status,
      'conteudo', m.conteudo,
      'remetente', sa.identificador
    ) ORDER BY m.criado_em), '[]'::jsonb)
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
    JOIN contacts c ON c.id = e.contact_id
    LEFT JOIN sender_accounts sa ON sa.id = m.sender_account_id),

  'remetentes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'identificador', identificador, 'canal', canal, 'tipo', tipo_permitido,
      'usado', enviados_na_janela, 'quota', quota_diaria,
      'saude', health_score, 'estado', estado
    ) ORDER BY identificador), '[]'::jsonb) FROM sender_accounts),

  'supressao', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', coalesce(c.nome, s.valor_norm), 'motivo', s.motivo
    )), '[]'::jsonb) FROM suppression s LEFT JOIN contacts c ON c.id = s.contact_id),

  'outbox', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', c.nome, 'fato', o.fato, 'autoria', o.autoria
    )), '[]'::jsonb) FROM outbox o JOIN contacts c ON c.id = o.contact_id),

  'horas_simuladas', (SELECT (extract(epoch from decorrido)/3600)::int FROM p.relogio)
));
