-- Testes do agendador e do roteador.
--
-- Cada ramo de decisão de processar_vencidos() tem asserção: ramo sem teste é
-- ramo que vai errar em produção sem ninguém ver.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA a;

CREATE TABLE a.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);

CREATE FUNCTION a.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO a.resultado (nome, ok, detalhe) VALUES (p_nome, coalesce(p_cond,false), p_detalhe);
END;
$$;

-- Roda uma passada e devolve a ação tomada num enrollment.
CREATE FUNCTION a.acao_de(p_enrollment uuid, p_modo text DEFAULT 'simulado')
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  SELECT acao INTO v FROM processar_vencidos(100, p_modo) WHERE enrollment_id = p_enrollment;
  RETURN coalesce(v, 'nao_processado');
END;
$$;

-- ---------------------------------------------------------------------------
-- Renderização de template
-- ---------------------------------------------------------------------------

SELECT a.confere('render: substitui a variável',
  renderizar('Oi {{nome}}, tudo bem?', '{"nome":"Ana"}'::jsonb) = 'Oi Ana, tudo bem?',
  renderizar('Oi {{nome}}, tudo bem?', '{"nome":"Ana"}'::jsonb));

SELECT a.confere('render: tolera espaço dentro da marcação',
  renderizar('Oi {{ nome }}', '{"nome":"Ana"}'::jsonb) = 'Oi Ana');

SELECT a.confere('render: variável ausente vira vazio, não vaza a marcação',
  renderizar('Oi {{nome}}, da {{cidade}}', '{"nome":"Ana"}'::jsonb) = 'Oi Ana, da ',
  renderizar('Oi {{nome}}, da {{cidade}}', '{"nome":"Ana"}'::jsonb));

SELECT a.confere('render: várias ocorrências da mesma variável',
  renderizar('{{nome}} e {{nome}}', '{"nome":"Ana"}'::jsonb) = 'Ana e Ana');

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

INSERT INTO contacts (id, nome, origem, metadados) VALUES
  ('b1000000-0000-0000-0000-000000000001','Marina','planilha','{"cidade":"Santos"}'),
  ('b1000000-0000-0000-0000-000000000002','Otavio','planilha','{}'),
  ('b1000000-0000-0000-0000-000000000003','Paula', 'planilha','{}'),
  ('b1000000-0000-0000-0000-000000000004','Rui',   'planilha','{}'),
  ('b1000000-0000-0000-0000-000000000005','Sonia', 'planilha','{}'),
  ('b1000000-0000-0000-0000-000000000006','Tulio', 'planilha','{}');

INSERT INTO contact_identities (id, contact_id, canal, valor, valor_norm, origem) VALUES
  ('b2000000-0000-0000-0000-000000000001','b1000000-0000-0000-0000-000000000001','whatsapp','+5513900001','5513900001','planilha'),
  ('b2000000-0000-0000-0000-000000000002','b1000000-0000-0000-0000-000000000001','email','marina@ex.com','marina@ex.com','planilha'),
  ('b2000000-0000-0000-0000-000000000003','b1000000-0000-0000-0000-000000000002','whatsapp','+5513900002','5513900002','planilha'),
  ('b2000000-0000-0000-0000-000000000004','b1000000-0000-0000-0000-000000000003','whatsapp','+5513900003','5513900003','planilha'),
  ('b2000000-0000-0000-0000-000000000005','b1000000-0000-0000-0000-000000000004','whatsapp','+5513900004','5513900004','planilha'),
  ('b2000000-0000-0000-0000-000000000006','b1000000-0000-0000-0000-000000000005','whatsapp','+5513900005','5513900005','planilha'),
  ('b2000000-0000-0000-0000-000000000007','b1000000-0000-0000-0000-000000000006','whatsapp','+5513900006','5513900006','planilha');

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados, ativa) VALUES
  ('b3000000-0000-0000-0000-000000000001','Cadencia dois passos','morna','opt-in','{whatsapp,email}',true),
  ('b3000000-0000-0000-0000-000000000002','So whatsapp','morna','opt-in','{whatsapp}',true),
  ('b3000000-0000-0000-0000-000000000003','Desligada','morna','opt-in','{whatsapp}',false),
  ('b3000000-0000-0000-0000-000000000004','Fria sem remetente','fria','prospeccao','{whatsapp}',true);

INSERT INTO flows (id, nome) VALUES ('b4000000-0000-0000-0000-000000000001','Flow de teste');
INSERT INTO flow_versions (id, flow_id, versao) VALUES
  ('b5000000-0000-0000-0000-000000000001','b4000000-0000-0000-0000-000000000001',1);

-- Passo 1 whatsapp imediato, passo 2 e-mail após 48h.
INSERT INTO flow_steps (id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('b6000000-0000-0000-0000-000000000001','b5000000-0000-0000-0000-000000000001',1,'whatsapp',0,'Oi {{nome}} de {{cidade}}'),
  ('b6000000-0000-0000-0000-000000000002','b5000000-0000-0000-0000-000000000001',2,'email',48,'Assunto para {{nome}}');

INSERT INTO sender_accounts (id, canal, identificador, provedor, tipo_permitido, quota_diaria) VALUES
  ('b7000000-0000-0000-0000-000000000001','whatsapp','5513988801','evolution','morna',100),
  ('b7000000-0000-0000-0000-000000000002','email','morno@ex.com','resend','morna',100);
-- De propósito: nenhum remetente de campanha fria.

-- ---------------------------------------------------------------------------
-- Caminho feliz
-- ---------------------------------------------------------------------------

SELECT inscrever('b1000000-0000-0000-0000-000000000001','b3000000-0000-0000-0000-000000000001',
                 'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');

DO $$
DECLARE v_enr uuid; v_acao text; v_msg messages%ROWTYPE;
BEGIN
  SELECT id INTO v_enr FROM enrollments
   WHERE contact_id = 'b1000000-0000-0000-0000-000000000001';

  v_acao := a.acao_de(v_enr);
  PERFORM a.confere('passo 1: mensagem criada', v_acao = 'mensagem_criada', v_acao);

  SELECT * INTO v_msg FROM messages WHERE enrollment_id = v_enr;
  PERFORM a.confere('passo 1: conteúdo renderizado com nome e metadado',
    v_msg.conteudo = 'Oi Marina de Santos', v_msg.conteudo);
  PERFORM a.confere('passo 1: shadow mode grava simulado',
    v_msg.status = 'simulado', v_msg.status::text);
  PERFORM a.confere('passo 1: usou identidade do canal do passo',
    v_msg.contact_identity_id = 'b2000000-0000-0000-0000-000000000001');
  -- Qual remetente entre os elegíveis é escolha do pool, não do agendador.
  -- O que o agendador garante é canal e tipo de campanha.
  PERFORM a.confere('passo 1: shadow mode registra um remetente elegível',
    (SELECT sa.canal = 'whatsapp' AND sa.tipo_permitido = 'morna'
       FROM sender_accounts sa WHERE sa.id = v_msg.sender_account_id));

  PERFORM a.confere('passo 1: enrollment avançou e foi reagendado para +48h',
    (SELECT passo_atual = 1 AND status = 'ativo'
        AND next_run_at BETWEEN now() + interval '47 hours' AND now() + interval '49 hours'
       FROM enrollments WHERE id = v_enr));

  -- Segunda passada não faz nada: ainda não venceu.
  PERFORM a.confere('não processa enrollment que ainda não venceu',
    a.acao_de(v_enr) = 'nao_processado');

  -- Antecipa o relógio e roda o passo 2, que é e-mail.
  UPDATE enrollments SET next_run_at = now() - interval '1 minute' WHERE id = v_enr;
  v_acao := a.acao_de(v_enr);
  PERFORM a.confere('passo 2: mensagem criada no canal do passo', v_acao = 'mensagem_criada', v_acao);

  PERFORM a.confere('passo 2: trocou de canal conforme o flow',
    (SELECT canal = 'email' FROM messages WHERE enrollment_id = v_enr AND step_id = 'b6000000-0000-0000-0000-000000000002'));
  PERFORM a.confere('passo 2: escolheu remetente do canal do passo, não do passo anterior',
    (SELECT sa.canal = 'email' AND sa.tipo_permitido = 'morna'
       FROM messages m JOIN sender_accounts sa ON sa.id = m.sender_account_id
      WHERE m.enrollment_id = v_enr AND m.step_id = 'b6000000-0000-0000-0000-000000000002'));

  -- Era o último passo: encerra na hora, sem esperar outra passada.
  PERFORM a.confere('fim do flow encerra na mesma passada',
    (SELECT status = 'encerrado' AND motivo_encerramento = 'fim_dos_passos'
       FROM enrollments WHERE id = v_enr));
  PERFORM a.confere('encerrado não fica agendado',
    (SELECT next_run_at IS NULL FROM enrollments WHERE id = v_enr));
END;
$$;

-- ---------------------------------------------------------------------------
-- Supressão no roteador
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_enr uuid; v_acao text;
BEGIN
  v_enr := inscrever('b1000000-0000-0000-0000-000000000002','b3000000-0000-0000-0000-000000000002',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  INSERT INTO suppression (contact_id, motivo) VALUES
    ('b1000000-0000-0000-0000-000000000002','opt-out depois de inscrito');

  v_acao := a.acao_de(v_enr);
  PERFORM a.confere('supressão superveniente encerra o enrollment',
    v_acao = 'encerrado_supressao', v_acao);
  PERFORM a.confere('supressão: motivo registrado',
    (SELECT motivo_encerramento = 'supressao' FROM enrollments WHERE id = v_enr));
  PERFORM a.confere('supressão: nenhuma mensagem foi criada, nem simulada',
    NOT EXISTS (SELECT 1 FROM messages WHERE enrollment_id = v_enr));
END;
$$;

SELECT a.confere('inscrever recusa contato já suprimido',
  inscrever('b1000000-0000-0000-0000-000000000002','b3000000-0000-0000-0000-000000000001',
            'b5000000-0000-0000-0000-000000000001') IS NULL);

-- Identidade suprimida inutiliza o canal, não a pessoa.
DO $$
DECLARE v_enr uuid; v_acao text;
BEGIN
  INSERT INTO suppression (canal, valor_norm, motivo) VALUES
    ('whatsapp','5513900003','numero invalido');
  v_enr := inscrever('b1000000-0000-0000-0000-000000000003','b3000000-0000-0000-0000-000000000002',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');

  v_acao := a.acao_de(v_enr);
  PERFORM a.confere('identidade suprimida pula o passo, não encerra a pessoa',
    v_acao = 'passo_pulado_identidade_suprimida', v_acao);
  PERFORM a.confere('identidade suprimida: enrollment segue ativo',
    (SELECT status = 'ativo' FROM enrollments WHERE id = v_enr));
END;
$$;

-- ---------------------------------------------------------------------------
-- Canal não habilitado e identidade ausente
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_enr uuid; v_acao text;
BEGIN
  -- Campanha só de whatsapp rodando um flow cujo passo 2 é e-mail.
  v_enr := inscrever('b1000000-0000-0000-0000-000000000004','b3000000-0000-0000-0000-000000000002',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  PERFORM a.acao_de(v_enr);                                    -- passo 1, whatsapp
  UPDATE enrollments SET next_run_at = now() - interval '1 minute' WHERE id = v_enr;
  v_acao := a.acao_de(v_enr);                                  -- passo 2, e-mail

  PERFORM a.confere('canal fora dos habilitados da campanha pula o passo',
    v_acao = 'passo_pulado_canal', v_acao);
  PERFORM a.confere('passo pulado por canal não cria mensagem',
    (SELECT count(*) = 1 FROM messages WHERE enrollment_id = v_enr));

  -- Passo pulado é reagendado para já: a próxima passada fecha o flow.
  v_acao := a.acao_de(v_enr);
  PERFORM a.confere('depois do último passo pulado o flow encerra',
    v_acao = 'encerrado_fim', v_acao);
END;
$$;

DO $$
DECLARE v_enr uuid; v_acao text;
BEGIN
  -- Sonia só tem whatsapp; campanha habilita e-mail mas ela não tem endereço.
  v_enr := inscrever('b1000000-0000-0000-0000-000000000005','b3000000-0000-0000-0000-000000000001',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  PERFORM a.acao_de(v_enr);
  UPDATE enrollments SET next_run_at = now() - interval '1 minute' WHERE id = v_enr;
  v_acao := a.acao_de(v_enr);

  PERFORM a.confere('sem identidade no canal do passo, pula o passo',
    v_acao = 'passo_pulado_sem_identidade', v_acao);
END;
$$;

-- ---------------------------------------------------------------------------
-- Campanha desligada e falta de remetente
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_enr uuid; v_acao text; v_antes timestamptz;
BEGIN
  v_enr := inscrever('b1000000-0000-0000-0000-000000000006','b3000000-0000-0000-0000-000000000003',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  v_acao := a.acao_de(v_enr);
  PERFORM a.confere('campanha desligada não processa', v_acao = 'ignorado_campanha_inativa', v_acao);
  PERFORM a.confere('campanha desligada não encerra ninguém',
    (SELECT status = 'ativo' FROM enrollments WHERE id = v_enr));
  PERFORM a.confere('campanha desligada não cria mensagem',
    NOT EXISTS (SELECT 1 FROM messages WHERE enrollment_id = v_enr));

  -- Religa e o mesmo enrollment anda.
  UPDATE campaigns SET ativa = true WHERE id = 'b3000000-0000-0000-0000-000000000003';
  v_acao := a.acao_de(v_enr);
  PERFORM a.confere('religar a campanha retoma a cadência de onde parou',
    v_acao = 'mensagem_criada', v_acao);
END;
$$;

DO $$
DECLARE v_enr uuid; v_acao text;
BEGIN
  -- Campanha fria sem nenhum remetente frio no pool (D4 impede usar o morno).
  INSERT INTO contacts (id, nome, origem) VALUES
    ('b1000000-0000-0000-0000-000000000007','Vera','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem) VALUES
    ('b1000000-0000-0000-0000-000000000007','whatsapp','+5513900007','5513900007','planilha');

  v_enr := inscrever('b1000000-0000-0000-0000-000000000007','b3000000-0000-0000-0000-000000000004',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  v_acao := a.acao_de(v_enr);

  PERFORM a.confere('sem remetente no pool o envio é adiado, não perdido',
    v_acao = 'adiado_sem_remetente', v_acao);
  PERFORM a.confere('adiado não consome o passo',
    (SELECT passo_atual = 0 AND status = 'ativo' FROM enrollments WHERE id = v_enr));
  PERFORM a.confere('adiado é reagendado para daqui a pouco',
    (SELECT next_run_at > now() FROM enrollments WHERE id = v_enr));
  PERFORM a.confere('D4: não caiu no remetente morno por falta de opção',
    NOT EXISTS (SELECT 1 FROM messages WHERE enrollment_id = v_enr));
END;
$$;

-- ---------------------------------------------------------------------------
-- Rate limit freia o agendador
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_contato uuid; v_campanha uuid; v_criadas integer; v_adiadas integer;
BEGIN
  -- Remetente com quota 2 e três contatos vencidos: dois passam, um adia.
  INSERT INTO sender_accounts (id, canal, identificador, provedor, tipo_permitido, quota_diaria)
  VALUES ('b7000000-0000-0000-0000-000000000003','sms','5513977701','comtele','fria',2);

  INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
  VALUES ('b3000000-0000-0000-0000-000000000005','Fria SMS','fria','prospeccao','{sms}');

  INSERT INTO flows (id, nome) VALUES ('b4000000-0000-0000-0000-000000000002','Flow SMS');
  INSERT INTO flow_versions (id, flow_id, versao)
  VALUES ('b5000000-0000-0000-0000-000000000002','b4000000-0000-0000-0000-000000000002',1);
  INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
  VALUES ('b5000000-0000-0000-0000-000000000002',1,'sms',0,'Ola {{nome}}');

  FOR i IN 1..3 LOOP
    v_contato := gen_random_uuid();
    INSERT INTO contacts (id, nome, origem) VALUES (v_contato, 'Quota ' || i, 'planilha');
    INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
    VALUES (v_contato, 'sms', '+55139555' || i, '55139555' || i, 'planilha');
    PERFORM inscrever(v_contato,'b3000000-0000-0000-0000-000000000005',
                      'b5000000-0000-0000-0000-000000000002', now() - interval '1 minute');
  END LOOP;

  SELECT count(*) FILTER (WHERE acao = 'mensagem_criada'),
         count(*) FILTER (WHERE acao = 'adiado_sem_remetente')
    INTO v_criadas, v_adiadas
    FROM processar_vencidos(100, 'simulado') p
    JOIN enrollments e ON e.id = p.enrollment_id
   WHERE e.campaign_id = 'b3000000-0000-0000-0000-000000000005';

  PERFORM a.confere('inv3: quota do remetente limita a passada do agendador',
    v_criadas = 2 AND v_adiadas = 1, format('criadas=%s adiadas=%s', v_criadas, v_adiadas));

  PERFORM a.confere('inv3: contador do remetente bateu na quota, não passou',
    (SELECT enviados_na_janela = quota_diaria FROM sender_accounts
      WHERE id = 'b7000000-0000-0000-0000-000000000003'));
END;
$$;

-- ---------------------------------------------------------------------------
-- Modo real e encerramento por resposta
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_contato uuid; v_enr uuid;
BEGIN
  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato,'Wanda','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'whatsapp','+5513900099','5513900099','planilha');

  v_enr := inscrever(v_contato,'b3000000-0000-0000-0000-000000000002',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');
  PERFORM a.acao_de(v_enr, 'real');

  PERFORM a.confere('modo real grava pendente, para o adapter consumir',
    (SELECT status = 'pendente' FROM messages WHERE enrollment_id = v_enr));

  -- A pessoa responde: invariante 4 encerra tudo, o agendador não volta nela.
  INSERT INTO message_events (message_id, tipo)
  SELECT id, 'respondido' FROM messages WHERE enrollment_id = v_enr;

  PERFORM a.confere('inv4: resposta encerrou o enrollment',
    (SELECT status = 'encerrado' AND motivo_encerramento = 'resposta'
       FROM enrollments WHERE id = v_enr));
  PERFORM a.confere('inv4: agendador não processa mais quem respondeu',
    a.acao_de(v_enr) = 'nao_processado');
END;
$$;

DO $$
BEGIN
  PERFORM * FROM processar_vencidos(1, 'envia_tudo');
  PERFORM a.confere('modo inválido é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM a.confere('modo inválido é recusado', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- Idempotência do agendador
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_contato uuid; v_enr uuid; v_msgs integer;
BEGIN
  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato,'Xenia','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'whatsapp','+5513900098','5513900098','planilha');
  v_enr := inscrever(v_contato,'b3000000-0000-0000-0000-000000000002',
                     'b5000000-0000-0000-0000-000000000001', now() - interval '1 minute');

  PERFORM a.acao_de(v_enr);

  -- Simula reprocessamento do mesmo passo: volta o relógio e o contador.
  UPDATE enrollments SET passo_atual = 0, next_run_at = now() - interval '1 minute'
   WHERE id = v_enr;

  PERFORM a.confere('inv1: reprocessar o mesmo passo não duplica mensagem',
    a.acao_de(v_enr) = 'passo_ja_reivindicado');

  SELECT count(*) INTO v_msgs FROM messages WHERE enrollment_id = v_enr;
  PERFORM a.confere('inv1: continua existindo uma mensagem só', v_msgs = 1, v_msgs::text);
END;
$$;

-- ---------------------------------------------------------------------------
-- Adiamento espera o tempo certo
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_contato uuid; v_enr uuid; v_quando timestamptz;
BEGIN
  -- Quota esgotada: o pool só volta na virada da janela diária.
  PERFORM a.confere('adiamento: quota esgotada espera a virada da janela',
    proximo_horario_de_pool('00000000-0000-0000-0000-0000000000aa','sms','fria')::date = current_date + 1,
    proximo_horario_de_pool('00000000-0000-0000-0000-0000000000aa','sms','fria')::text);

  -- E o agendador usa isso em vez de 15 minutos.
  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato,'Quota cheia','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'sms','+5513955599','5513955599','planilha');
  v_enr := inscrever(v_contato,'b3000000-0000-0000-0000-000000000005',
                     'b5000000-0000-0000-0000-000000000002', now() - interval '1 minute');

  PERFORM a.confere('adiamento: agendador adia até a janela, não 15 minutos',
    a.acao_de(v_enr) = 'adiado_sem_remetente');
  PERFORM a.confere('adiamento: reagendado para depois de hoje',
    (SELECT next_run_at::date >= current_date + 1 FROM enrollments WHERE id = v_enr),
    (SELECT next_run_at::text FROM enrollments WHERE id = v_enr));
END;
$$;

DO $$
DECLARE v_contato uuid; v_enr uuid;
BEGIN
  -- Circuito aberto: espera o circuito fechar, não a virada do dia.
  INSERT INTO sender_accounts (id, canal, identificador, provedor, tipo_permitido, quota_diaria)
  VALUES ('b7000000-0000-0000-0000-000000000009','instagram','@perfil','instagram_oficial','fria',50);
  UPDATE sender_accounts
     SET estado = 'circuito_aberto', circuito_aberto_ate = now() + interval '20 minutes'
   WHERE id = 'b7000000-0000-0000-0000-000000000009';

  PERFORM a.confere('adiamento: circuito aberto espera o circuito fechar',
    proximo_horario_de_pool('00000000-0000-0000-0000-0000000000aa','instagram','fria') BETWEEN now() + interval '19 minutes'
                                                    AND now() + interval '21 minutes',
    proximo_horario_de_pool('00000000-0000-0000-0000-0000000000aa','instagram','fria')::text);
END;
$$;

SELECT a.confere('adiamento: pool vazio tenta de novo em uma hora',
  proximo_horario_de_pool('00000000-0000-0000-0000-0000000000aa','email','fria') BETWEEN now() + interval '59 minutes'
                                              AND now() + interval '61 minutes',
  proximo_horario_de_pool('00000000-0000-0000-0000-0000000000aa','email','fria')::text);

-- ---------------------------------------------------------------------------
-- D31: provedor sem adapter adia o passo, não o queima
-- ---------------------------------------------------------------------------
--
-- O ramo que faltava. Antes disto o roteador escolhia a conta, criava a
-- mensagem e avançava a cadência; a pessoa não recebia nada e o passo estava
-- gasto. Adiar é recuperável: no dia em que o adapter existir, o enrollment
-- parado anda sozinho.

DO $$
DECLARE v_contato uuid; v_enr uuid; v_campanha uuid; v_flow uuid; v_versao uuid;
BEGIN
  INSERT INTO sender_accounts (canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, config)
  VALUES ('email','frio@sem-adapter.com.br','Sem adapter','smtp','fria',300,
          '{"host":"smtp.sem-adapter.com.br","porta":"587","usuario":"r"}'::jsonb);

  INSERT INTO campaigns (nome, tipo, base_legal, canais_habilitados)
  VALUES ('Fria por e-mail','fria','legítimo interesse','{email}') RETURNING id INTO v_campanha;
  INSERT INTO flows (nome) VALUES ('Resgate por e-mail') RETURNING id INTO v_flow;
  INSERT INTO flow_versions (flow_id, versao) VALUES (v_flow, 1) RETURNING id INTO v_versao;
  INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
  VALUES (v_versao, 1, 'email', 0, 'Oi {{nome}}');

  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem) VALUES (v_contato,'Marina','planilha');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'email','marina@exemplo.com','marina@exemplo.com','planilha');
  v_enr := inscrever(v_contato, v_campanha, v_versao, now() - interval '1 minute');

  PERFORM a.confere('sem adapter: o passo é adiado, não prometido',
    a.acao_de(v_enr, 'real') = 'adiado_sem_remetente',
    a.acao_de(v_enr, 'real'));

  PERFORM a.confere('sem adapter: nenhuma mensagem nasce para falhar depois',
    NOT EXISTS (SELECT 1 FROM messages WHERE enrollment_id = v_enr));

  PERFORM a.confere('sem adapter: o enrollment continua vivo e volta depois',
    (SELECT status = 'ativo' AND next_run_at > now() FROM enrollments WHERE id = v_enr));

  PERFORM a.confere('sem adapter: o passo não foi consumido',
    (SELECT passo_atual = 0 FROM enrollments WHERE id = v_enr),
    (SELECT passo_atual::text FROM enrollments WHERE id = v_enr));
END;
$$;

-- ---------------------------------------------------------------------------
-- Relatório
-- ---------------------------------------------------------------------------

\echo ''
\echo '============= AGENDADOR ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM a.resultado ORDER BY id;

\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
FROM a.resultado;

DO $$
DECLARE v_falhas integer;
BEGIN
  SELECT count(*) INTO v_falhas FROM a.resultado WHERE NOT ok;
  IF v_falhas > 0 THEN
    RAISE EXCEPTION '% asserção(ões) do agendador falharam', v_falhas;
  END IF;
END;
$$;
