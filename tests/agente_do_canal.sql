-- O agente de todos os canais (D76).
--
-- O que este arquivo existe para pegar:
--
--   1. quem responde: a exceção da campanha decide sozinha — inclusive
--      "ninguém" e o agente desligado, que NÃO caem para o agente do canal
--      (desligar é o freio, e o freio que entrega a conversa a outro não freia);
--   2. vigência: o agente responde só o que chegou depois de passar a
--      responder — escolhido no canal, escolhido na campanha, a campanha de
--      volta ao agente do canal (`herda`) e o agente religado. Sem isso,
--      marcar um canal responderia de uma vez a semana de respostas de toda
--      campanha sem agente, e religar responderia o que chegou com o freio
--      puxado;
--   3. dois clientes, cada um com o seu agente e a sua conta de IA: cada linha
--      da fila sai com os do PRÓPRIO cliente (o worker não tem RLS);
--   4. a fila, a tela (`quem_responde`) e `agente_do_canal` dão a mesma resposta;
--   5. o agente de canal fixo continua só no canal dele; o desligado não é
--      escolhido; o de outro cliente não entra;
--   6. `criar_agente` cria e escolhe numa transação só, e exige o que o agente
--      novo precisa (persona, objetivo, contexto);
--   7. a grade: a tela cria, escolhe, volta a campanha ao agente do canal e
--      edita o texto; não apaga agente nem exceção, não muda canal, não mexe
--      na vigência, não lê a fila — e a cópia do catálogo por
--      `atribuir_agente` continua funcionando, que é a tela que está no ar;
--   8. a fila: supressão, só a última resposta, rascunho que já existe, e a
--      vigência renovada em cada um dos quatro momentos, conferida pela FILA
--      e não só pela coluna.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA adc;
CREATE TABLE adc.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA adc TO authenticated, anon;
GRANT INSERT, SELECT ON adc.resultado TO authenticated, anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA adc TO authenticated, anon;
CREATE FUNCTION adc.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO adc.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION adc.confere(text, boolean, text) TO authenticated, anon;
CREATE FUNCTION adc.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE; END; $$;
GRANT EXECUTE ON FUNCTION adc.sqlstate_de(text) TO authenticated, anon;

\set ta    '\'ad000000-0000-0000-0000-0000000000a0\''
\set tb    '\'ad000000-0000-0000-0000-0000000000b0\''
\set opa   '\'ad000000-0000-0000-0000-0000000000a2\''
\set lea   '\'ad000000-0000-0000-0000-0000000000a3\''
\set opb   '\'ad000000-0000-0000-0000-0000000000b2\''
\set creda '\'ad000000-0000-0000-0000-0000000000d1\''
\set credb '\'ad000000-0000-0000-0000-0000000000d2\''
\set ana   '\'ad000000-0000-0000-0000-0000000000a9\''
\set lia   '\'ad000000-0000-0000-0000-0000000000a8\''
\set edu   '\'ad000000-0000-0000-0000-0000000000a7\''
\set bruno '\'ad000000-0000-0000-0000-0000000000a6\''
\set biab  '\'ad000000-0000-0000-0000-0000000000b9\''
\set c1    '\'ad000000-0000-0000-0000-0000000000c1\''
\set c2    '\'ad000000-0000-0000-0000-0000000000c2\''
\set c3    '\'ad000000-0000-0000-0000-0000000000c3\''
\set c4    '\'ad000000-0000-0000-0000-0000000000c4\''
\set c5    '\'ad000000-0000-0000-0000-0000000000c5\''
\set c6    '\'ad000000-0000-0000-0000-0000000000c6\''
\set c7    '\'ad000000-0000-0000-0000-0000000000c7\''
\set cb1   '\'ad000000-0000-0000-0000-0000000000cb\''

INSERT INTO tenants (id, nome, slug) VALUES
  (:ta, 'Corretora Canal A', 'corretora-canal-a'),
  (:tb, 'Corretora Canal B', 'corretora-canal-b');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:ta, :opa, 'operador'), (:ta, :lea, 'leitor'), (:tb, :opb, 'operador');

INSERT INTO ai_credentials (id, tenant_id, nome, provedor, modelo) VALUES
  (:creda, :ta, 'OpenAI A', 'openai', 'gpt-5.5'),
  (:credb, :tb, 'OpenAI B', 'openai', 'gpt-5.5');

-- O contexto de agente novo precisa de 40 caracteres: o agente que não sabe em
-- nome de quem fala inventa (D76).
INSERT INTO agents (id, tenant_id, nome, canal, persona, objetivo, papel, descricao, tom, instrucoes, contexto,
                    ai_credential_id, tamanho_maximo) VALUES
  (:ana, :ta, 'Ana', NULL, 'consultiva', 'resgate', 'assistente de relacionamento', 'Retoma oportunidade.',
   'Fale como consultora.', repeat('Retome a conversa de onde parou, uma pergunta por vez. ', 3),
   'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', :creda, NULL),
  (:bruno, :ta, 'Bruno', NULL, 'objetiva', 'follow_up', 'assistente de acompanhamento', 'Acompanha.',
   'Fale curto.', repeat('Retome a proposta e pergunte o que falta para decidir. ', 3),
   'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', :creda, NULL),
  (:biab, :tb, 'Bia', NULL, 'proxima', 'resgate', 'assistente de relacionamento', 'Retoma oportunidade.',
   'Fale leve.', repeat('Retome a conversa de onde parou, uma pergunta por vez. ', 3),
   'Falamos em nome da Corretora Canal B, em Campinas. Seguro de vida.', :credb, NULL);
-- Os de antes do D76: um canal cada, a instrução inteira num texto.
INSERT INTO agents (id, tenant_id, nome, canal, papel, descricao, instrucoes) VALUES
  (:lia, :ta, 'Lia', 'whatsapp', 'SDR', 'Reativa.', repeat('Seja breve e cordial no WhatsApp, uma pergunta por vez. ', 3)),
  (:edu, :ta, 'Edu', 'email', 'Atendimento', 'Responde.', repeat('Responda o e-mail com saudação e próximo passo. ', 3));

INSERT INTO flows (id, tenant_id, nome) VALUES
  ('ad000000-0000-0000-0000-0000000000f1', :ta, 'F'), ('ad000000-0000-0000-0000-0000000000e1', :tb, 'F');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao) VALUES
  ('ad000000-0000-0000-0000-0000000000f2', :ta, 'ad000000-0000-0000-0000-0000000000f1', 1),
  ('ad000000-0000-0000-0000-0000000000e2', :tb, 'ad000000-0000-0000-0000-0000000000e1', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('ad000000-0000-0000-0000-0000000000f3', :ta, 'ad000000-0000-0000-0000-0000000000f2', 1, 'whatsapp', 0, 'Oi'),
  ('ad000000-0000-0000-0000-0000000000f4', :ta, 'ad000000-0000-0000-0000-0000000000f2', 2, 'email', 24, 'Oi por e-mail'),
  ('ad000000-0000-0000-0000-0000000000e3', :tb, 'ad000000-0000-0000-0000-0000000000e2', 1, 'whatsapp', 0, 'Oi');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados, flow_version_id) VALUES
  (:c1, :ta, 'Herda do canal', 'morna', 'opt-in', '{whatsapp,email}', 'ad000000-0000-0000-0000-0000000000f2'),
  (:c2, :ta, 'Exceção antiga', 'morna', 'opt-in', '{whatsapp}', 'ad000000-0000-0000-0000-0000000000f2'),
  (:c3, :ta, 'Ninguém aqui', 'morna', 'opt-in', '{whatsapp}', 'ad000000-0000-0000-0000-0000000000f2'),
  (:c4, :ta, 'Exceção desligada', 'morna', 'opt-in', '{whatsapp}', 'ad000000-0000-0000-0000-0000000000f2'),
  (:c5, :ta, 'Exceção nova', 'morna', 'opt-in', '{whatsapp}', 'ad000000-0000-0000-0000-0000000000f2'),
  (:c6, :ta, 'Ninguém, depois agente', 'morna', 'opt-in', '{whatsapp}', 'ad000000-0000-0000-0000-0000000000f2'),
  (:c7, :ta, 'Ninguém, depois o do canal', 'morna', 'opt-in', '{whatsapp}', 'ad000000-0000-0000-0000-0000000000f2'),
  (:cb1, :tb, 'Do B', 'morna', 'opt-in', '{whatsapp}', 'ad000000-0000-0000-0000-0000000000e2');

INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria) VALUES
  ('ad000000-0000-0000-0000-0000000000e5', :ta, 'whatsapp', 'uazapi', '5511990007771', 'Chip A', 'morna', 100),
  ('ad000000-0000-0000-0000-0000000000e6', :ta, 'email', 'resend', 'contato@canal-a.test', 'E-mail A', 'morna', 100),
  ('ad000000-0000-0000-0000-0000000000e7', :tb, 'whatsapp', 'uazapi', '5511990007772', 'Chip B', 'morna', 100);

-- As escolhas, como a tela as faria — e depois RECUADAS no tempo com os
-- gatilhos de vigência desligados, para o cenário ter "antes" e "depois".
INSERT INTO agentes_por_canal (tenant_id, canal, agent_id) VALUES
  (:ta, 'whatsapp', :ana), (:tb, 'whatsapp', :biab);
INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id) VALUES
  (:ta, :c2, 'whatsapp', :lia),
  (:ta, :c3, 'whatsapp', NULL),
  (:ta, :c4, 'whatsapp', :bruno),
  (:ta, :c5, 'whatsapp', :ana),
  (:ta, :c6, 'whatsapp', NULL),
  (:ta, :c7, 'whatsapp', NULL);
ALTER TABLE agentes_por_canal DISABLE TRIGGER agentes_por_canal_vigencia;
ALTER TABLE campaign_agents DISABLE TRIGGER campaign_agents_vigencia;
ALTER TABLE agents DISABLE TRIGGER agents_ativo_desde;
UPDATE agentes_por_canal SET vigente_desde = now() - interval '2 days';
UPDATE campaign_agents SET vigente_desde = now() - interval '2 days'
 WHERE campaign_id IN (:c2, :c3, :c4, :c5, :c6, :c7);
-- Os agentes também foram ligados há dois dias: senão o "ligado agora" do
-- INSERT esconderia o que a vigência da escolha decide.
UPDATE agents SET ativo_desde = now() - interval '2 days' WHERE tenant_id IN (:ta, :tb);
ALTER TABLE agentes_por_canal ENABLE TRIGGER agentes_por_canal_vigencia;
ALTER TABLE campaign_agents ENABLE TRIGGER campaign_agents_vigencia;
ALTER TABLE agents ENABLE TRIGGER agents_ativo_desde;
-- Desligar o agente da exceção depois de escolhido: é o freio.
UPDATE agents SET ativo = false WHERE id = :bruno;
SELECT adc.confere('desligar não mexe em ativo_desde (só religar renova)',
  (SELECT ativo_desde < now() - interval '1 day' FROM agents WHERE id = :bruno));

-- Uma pessoa por caso: contato, identidade, inscrição, o toque e a resposta.
CREATE FUNCTION adc.pessoa(p_tenant uuid, p_n int, p_campanha uuid, p_canal canal, p_ha interval)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_c uuid; v_i uuid; v_e uuid; v_m uuid; v_ev uuid; v_valor text; v_versao uuid; v_passo uuid; v_conta uuid;
BEGIN
  v_c := ('ad000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid;
  v_valor := CASE WHEN p_canal = 'email' THEN 'pessoa' || p_n || '@exemplo.test'
                  ELSE '55119800003' || lpad(p_n::text, 2, '0') END;
  SELECT flow_version_id INTO v_versao FROM campaigns WHERE id = p_campanha;
  SELECT id INTO v_passo FROM flow_steps WHERE flow_version_id = v_versao AND canal = p_canal ORDER BY ordem LIMIT 1;
  SELECT id INTO v_conta FROM sender_accounts WHERE tenant_id = p_tenant AND canal = p_canal LIMIT 1;
  INSERT INTO contacts (id, tenant_id, nome, origem) VALUES (v_c, p_tenant, 'Pessoa ' || p_n, 'planilha');
  INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
  VALUES (p_tenant, v_c, p_canal, v_valor, v_valor, 'planilha') RETURNING id INTO v_i;
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id, passo_atual)
  VALUES (p_tenant, v_c, p_campanha, v_versao, 1) RETURNING id INTO v_e;
  INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id, sender_account_id, canal, status,
                        conteudo, criado_em)
  VALUES (p_tenant, v_e, v_passo, v_i, v_conta, p_canal, 'enviado', 'Oi, ainda pensa no plano?',
          now() - p_ha - interval '2 hours')
  RETURNING id INTO v_m;
  INSERT INTO message_events (tenant_id, message_id, tipo, payload, ocorrido_em)
  VALUES (p_tenant, v_m, 'respondido', jsonb_build_object('texto', 'quanto fica para dois?'), now() - p_ha)
  RETURNING id INTO v_ev;
  RETURN v_ev;
END; $$;

CREATE FUNCTION adc.c(p_n int) RETURNS uuid LANGUAGE sql AS $$
  SELECT ('ad000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid $$;

SELECT adc.pessoa(:ta, 1, :c1, 'whatsapp', interval '1 hour');   -- herda Ana
SELECT adc.pessoa(:ta, 2, :c1, 'whatsapp', interval '3 days');   -- antes de a Ana ser escolhida
SELECT adc.pessoa(:ta, 3, :c2, 'whatsapp', interval '1 hour');   -- exceção Lia
SELECT adc.pessoa(:ta, 4, :c3, 'whatsapp', interval '1 hour');   -- exceção "ninguém"
SELECT adc.pessoa(:ta, 5, :c4, 'whatsapp', interval '1 hour');   -- exceção desligada
SELECT adc.pessoa(:ta, 6, :c1, 'email',    interval '1 hour');   -- e-mail sem agente
SELECT adc.pessoa(:ta, 7, :c5, 'whatsapp', interval '1 hour');   -- exceção com agente novo
SELECT adc.pessoa(:tb, 8, :cb1, 'whatsapp', interval '1 hour');  -- o outro cliente
SELECT adc.pessoa(:ta, 9, :c6, 'whatsapp', interval '1 hour');   -- "ninguém" que vira agente
SELECT adc.pessoa(:ta, 10, :c7, 'whatsapp', interval '1 hour');  -- "ninguém" que volta ao do canal
SELECT adc.pessoa(:ta, 11, :c1, 'whatsapp', interval '1 hour');  -- herda Ana, até o canal trocar

-- A pessoa responde de novo, agora, na mesma conversa.
CREATE FUNCTION adc.responde(p_n int, p_texto text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_m uuid; v_t uuid; v_ev uuid;
BEGIN
  SELECT m.id, m.tenant_id INTO v_m, v_t FROM messages m JOIN enrollments e ON e.tenant_id = m.tenant_id AND e.id = m.enrollment_id
   WHERE e.contact_id = ('ad000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid
   ORDER BY m.criado_em DESC LIMIT 1;
  INSERT INTO message_events (tenant_id, message_id, tipo, payload, ocorrido_em)
  VALUES (v_t, v_m, 'respondido', jsonb_build_object('texto', p_texto), clock_timestamp())
  RETURNING id INTO v_ev;
  RETURN v_ev;
END; $$;

CREATE TABLE adc.fila AS SELECT * FROM fila_do_agente(100);

-- Uma vez de cada cliente: as respostas do cliente A são mais antigas que a do
-- B, e com LIMIT 2 a fila por `ocorrido_em` puro traria duas do A. Respostas
-- presas de um cliente não podem parar o agente dos outros.
SELECT adc.confere('a fila reparte o LIMIT entre os clientes',
  (SELECT count(DISTINCT tenant_id) FROM fila_do_agente(2)) = 2
  AND (SELECT count(*) FROM adc.fila WHERE tenant_id = :ta) >= 2);

-- ===========================================================================
-- 1. Quem responde
-- ===========================================================================

-- Uma linha só, sempre: a regra que devolvesse duas (o agente do canal de
-- OUTRO cliente junto) só seria salva pelo filtro de quem a lê.
SELECT adc.confere('a regra devolve uma resposta só por campanha e canal',
  (SELECT count(*) FROM privado.agente_que_responde(:ta, :c1, 'whatsapp')) = 1
  AND (SELECT count(*) FROM privado.agente_que_responde(:tb, :cb1, 'whatsapp')) = 1);
SELECT adc.confere('sem exceção, quem responde é o agente do canal',
  (SELECT agent_id FROM adc.fila WHERE contact_id = adc.c(1)) = :ana);
SELECT adc.confere('com exceção, a da campanha',
  (SELECT agent_id FROM adc.fila WHERE contact_id = adc.c(3)) = :lia);
SELECT adc.confere('exceção "ninguém" não cai para o agente do canal',
  NOT EXISTS (SELECT 1 FROM adc.fila WHERE contact_id = adc.c(4)));
SELECT adc.confere('exceção com agente desligado não cai para o agente do canal (o freio freia)',
  NOT EXISTS (SELECT 1 FROM adc.fila WHERE contact_id = adc.c(5)));
SELECT adc.confere('canal sem agente nenhum: ninguém responde',
  NOT EXISTS (SELECT 1 FROM adc.fila WHERE contact_id = adc.c(6)));
SELECT adc.confere('e a tela sabe que é falta de agente, não escolha da campanha',
  (SELECT origem FROM quem_responde(:ta, :c1) WHERE canal = 'email') = 'sem_agente');
SELECT adc.confere('exceção com agente de todos os canais responde',
  (SELECT agent_id FROM adc.fila WHERE contact_id = adc.c(7)) = :ana);

-- ===========================================================================
-- 2. Vigência
-- ===========================================================================

SELECT adc.confere('resposta de antes de o agente do canal ser escolhido não entra na fila',
  NOT EXISTS (SELECT 1 FROM adc.fila WHERE contact_id = adc.c(2)));

-- Escolher o agente do e-mail AGORA não faz ele responder o e-mail de uma hora atrás.
INSERT INTO agentes_por_canal (tenant_id, canal, agent_id) VALUES (:ta, 'email', :edu);
SELECT adc.confere('escolher o canal agora não responde o que já tinha chegado',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(6)));
SELECT adc.confere('a vigência nasce no momento da escolha',
  (SELECT vigente_desde > now() - interval '1 minute' FROM agentes_por_canal WHERE tenant_id = :ta AND canal = 'email'));
-- Mudar outra coisa não renova; trocar o agente renova.
UPDATE agentes_por_canal SET agent_id = :ana WHERE tenant_id = :ta AND canal = 'whatsapp';
SELECT adc.confere('a vigência só muda quando o agente muda',
  (SELECT vigente_desde < now() - interval '1 day' FROM agentes_por_canal WHERE tenant_id = :ta AND canal = 'whatsapp'));

-- ===========================================================================
-- 3. Dois clientes
-- ===========================================================================

SELECT adc.confere('cada resposta sai com o agente do PRÓPRIO cliente',
  NOT EXISTS (SELECT 1 FROM adc.fila f JOIN agents a ON a.id = f.agent_id WHERE a.tenant_id <> f.tenant_id)
  AND (SELECT agent_id FROM adc.fila WHERE contact_id = adc.c(8)) = :biab);
SELECT adc.confere('e com a conta de IA do próprio cliente',
  (SELECT credencial_id FROM adc.fila WHERE contact_id = adc.c(8)) = :credb
  AND (SELECT credencial_id FROM adc.fila WHERE contact_id = adc.c(1)) = :creda);

-- O que o prompt lê vem na fila: o agente novo traz persona, objetivo e
-- contexto; o tamanho nulo é "o do canal", e a fila antiga devolve 700 para o
-- v7 seguir sendo rollback seguro.
SELECT adc.confere('a fila traz tom, contexto, objetivo e o tamanho nulo',
  (SELECT objetivo = 'resgate' AND contexto LIKE 'Falamos em nome da Corretora Canal A%' AND tom <> ''
          AND tamanho_maximo IS NULL FROM adc.fila WHERE contact_id = adc.c(1)));
SELECT adc.confere('o agente de antes vem sem objetivo (o título da instrução depende disso)',
  (SELECT objetivo IS NULL AND tamanho_maximo = 700 FROM adc.fila WHERE contact_id = adc.c(3)));
-- O v7 não sabe montar o prompt do agente de todos os canais (sem tom, sem
-- contexto, sem o bloco do canal): com ele, o agente novo não compõe.
SELECT adc.confere('a fila antiga (v7) não compõe com o agente de todos os canais',
  NOT EXISTS (SELECT 1 FROM respostas_para_o_agente(100) WHERE contact_id = adc.c(7))
  AND EXISTS (SELECT 1 FROM respostas_para_o_agente(100) WHERE contact_id = adc.c(3)));
-- O agente de antes também pode ficar com o tamanho nulo ("o do canal") pela
-- tela nova; o v7 só conhece número.
UPDATE agents SET tamanho_maximo = NULL WHERE id = :lia;
SELECT adc.confere('a fila antiga (v7) devolve 700 onde o tamanho é nulo',
  (SELECT tamanho_maximo FROM respostas_para_o_agente(100) WHERE contact_id = adc.c(3)) = 700);
UPDATE agents SET tamanho_maximo = 700 WHERE id = :lia;
-- E a vigência vale também na fila antiga: religar a Lia não faz o v7
-- responder o que chegou com ela desligada.
UPDATE agents SET ativo = false WHERE id = :lia;
UPDATE agents SET ativo = true WHERE id = :lia;
SELECT adc.confere('a fila antiga (v7) também respeita a vigência (religado)',
  NOT EXISTS (SELECT 1 FROM respostas_para_o_agente(100) WHERE contact_id = adc.c(3)));
ALTER TABLE agents DISABLE TRIGGER agents_ativo_desde;
UPDATE agents SET ativo_desde = now() - interval '2 days' WHERE id = :lia;
ALTER TABLE agents ENABLE TRIGGER agents_ativo_desde;
SELECT adc.confere('e a fila antiga não sabe do agente do canal (o v8 é quem sabe)',
  NOT EXISTS (SELECT 1 FROM respostas_para_o_agente(100) WHERE contact_id = adc.c(1)));

-- ===========================================================================
-- 4. A tela e a fila dão a mesma resposta
-- ===========================================================================

SELECT adc.confere('quem_responde concorda com a fila em cada resposta que a fila tem',
  NOT EXISTS (
    SELECT 1 FROM adc.fila f
      JOIN enrollments e ON e.tenant_id = f.tenant_id AND e.contact_id = f.contact_id
      JOIN LATERAL quem_responde(f.tenant_id, e.campaign_id) q ON q.canal = f.canal
     WHERE q.agent_id IS DISTINCT FROM f.agent_id OR NOT q.responde));
SELECT adc.confere('quem_responde diz de onde vem: canal, campanha, ninguém por escolha, ou sem agente',
  (SELECT origem FROM quem_responde(:ta, :c1) WHERE canal = 'whatsapp') = 'canal'
  AND (SELECT origem FROM quem_responde(:ta, :c2) WHERE canal = 'whatsapp') = 'campanha'
  AND (SELECT origem FROM quem_responde(:ta, :c3) WHERE canal = 'whatsapp') = 'ninguem'
  AND (SELECT origem = 'campanha' AND NOT responde FROM quem_responde(:ta, :c4) WHERE canal = 'whatsapp'));
SELECT adc.confere('quem_responde lista cada canal da campanha',
  (SELECT count(*) FROM quem_responde(:ta, :c1)) = 2);
SELECT adc.confere('agente_do_canal segue a mesma regra',
  (agente_do_canal(:c1, 'whatsapp')).id = :ana
  AND (agente_do_canal(:c2, 'whatsapp')).id = :lia
  AND (agente_do_canal(:c3, 'whatsapp')).id IS NULL
  AND (agente_do_canal(:c4, 'whatsapp')).id IS NULL);

-- ===========================================================================
-- 5. O que cada escolha aceita
-- ===========================================================================

SELECT adc.confere('agente de canal fixo não vira agente de outro canal',
  adc.sqlstate_de(format('INSERT INTO agentes_por_canal (tenant_id, canal, agent_id) VALUES (%L, %L, %L)',
    :ta, 'sms', :lia)) = '23001');
SELECT adc.confere('agente desligado não é escolhido para o canal',
  adc.sqlstate_de(format('INSERT INTO agentes_por_canal (tenant_id, canal, agent_id) VALUES (%L, %L, %L)',
    :ta, 'sms', :bruno)) = '23001');
SELECT adc.confere('agente de outro cliente não é escolhido',
  adc.sqlstate_de(format('INSERT INTO agentes_por_canal (tenant_id, canal, agent_id) VALUES (%L, %L, %L)',
    :ta, 'sms', :biab)) IN ('23001', '23503'));
SELECT adc.confere('agente de todos os canais vale como exceção em qualquer canal da campanha',
  adc.sqlstate_de(format('INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id) VALUES (%L, %L, %L, %L)',
    :ta, :c1, 'email', :ana)) = 'sem erro');
SELECT adc.confere('agente de canal fixo continua recusado em outro canal da campanha',
  adc.sqlstate_de(format('UPDATE campaign_agents SET agent_id = %L WHERE campaign_id = %L AND canal = %L',
    :lia, :c1, 'email')) = '23001');
SELECT adc.confere('"ninguém" só vale em canal que a campanha usa',
  adc.sqlstate_de(format('INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id) VALUES (%L, %L, %L, NULL)',
    :ta, :c2, 'sms')) = '23001');
SELECT adc.confere('agente sem canal precisa ser do construtor (com objetivo)',
  adc.sqlstate_de(format($q$INSERT INTO agents (tenant_id, nome, canal, papel, descricao, instrucoes)
    VALUES (%L, 'Sem canal', NULL, 'x', 'y', repeat('instrução longa o bastante para a trava. ', 5))$q$, :ta)) = '23514');
SELECT adc.confere('agente novo sem contexto é recusado (não sabe em nome de quem fala)',
  adc.sqlstate_de(format($q$INSERT INTO agents (tenant_id, nome, canal, objetivo, papel, descricao, instrucoes, contexto)
    VALUES (%L, 'Sem contexto', NULL, 'resgate', 'x', 'y', repeat('instrução longa o bastante para a trava. ', 5), 'Corretora')$q$, :ta)) = '23514');

-- ===========================================================================
-- 6. criar_agente, como a tela chama
-- ===========================================================================

SET role authenticated;
SET request.jwt.claims = '{"sub":"ad000000-0000-0000-0000-0000000000a2"}';
  SELECT adc.confere('o operador cria o agente e o escolhe para o canal, numa chamada',
    adc.sqlstate_de($q$SELECT criar_agente('ad000000-0000-0000-0000-0000000000a0', 'Rafa', 'executiva', 'atendimento',
      'assistente de atendimento', 'Responde.', 'Fale formal.', repeat('Responda o que estiver nas informações. ', 4),
      'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', 'Reclamação.', 8, '{}', NULL,
      'ad000000-0000-0000-0000-0000000000d1', true, '{sms}')$q$) = 'sem erro');
  SELECT adc.confere('o agente criado é de todos os canais e já responde no canal escolhido',
    (SELECT a.canal IS NULL AND a.pronto AND a.ativo AND a.tamanho_maximo IS NULL
       FROM agents a JOIN agentes_por_canal p ON p.agent_id = a.id AND p.canal = 'sms'
      WHERE a.nome = 'Rafa' AND a.tenant_id = 'ad000000-0000-0000-0000-0000000000a0'));
  SELECT adc.confere('nome repetido no cliente: recusado com a mensagem certa',
    adc.sqlstate_de($q$SELECT criar_agente('ad000000-0000-0000-0000-0000000000a0', 'Rafa', 'executiva', 'atendimento',
      'p', 'd', 't', repeat('Responda o que estiver nas informações. ', 4),
      'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', 'x', 8, '{}', NULL, NULL, true)$q$) = '23505');
  SELECT adc.confere('sem persona ou objetivo: recusado',
    adc.sqlstate_de($q$SELECT criar_agente('ad000000-0000-0000-0000-0000000000a0', 'Sem obj', 'executiva', '',
      'p', 'd', 't', repeat('Responda o que estiver nas informações. ', 4),
      'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', 'x', 8, '{}', NULL, NULL, true)$q$) = '22023');
  -- A exceção numa campanha de OUTRO cliente: a função recusa, e o agente
  -- que ela já tinha inserido volta junto — é uma transação.
  SELECT adc.confere('exceção em campanha de outro cliente: recusada',
    adc.sqlstate_de($q$SELECT criar_agente('ad000000-0000-0000-0000-0000000000a0', 'Tentativa', 'executiva', 'atendimento',
      'p', 'd', 't', repeat('Responda o que estiver nas informações. ', 4),
      'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', 'x', 8, '{}', NULL, NULL, true,
      '{}', 'ad000000-0000-0000-0000-0000000000cb', '{whatsapp}')$q$) = '23001');
  SELECT adc.confere('e o agente da tentativa não ficou',
    NOT EXISTS (SELECT 1 FROM agents WHERE nome = 'Tentativa'));
  SELECT adc.confere('a exceção da própria campanha, na mesma chamada',
    adc.sqlstate_de($q$SELECT criar_agente('ad000000-0000-0000-0000-0000000000a0', 'Gil', 'objetiva', 'agendamento',
      'p', 'd', 't', repeat('Leve a conversa até um especialista. ', 4),
      'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', 'x', 6, '{}', NULL, NULL, false,
      '{}', 'ad000000-0000-0000-0000-0000000000c3', '{whatsapp}')$q$) = 'sem erro');
  -- Em instrução separada: o efeito não é visível na mesma expressão (D38).
  SELECT adc.confere('e a exceção ficou gravada com o agente novo',
    (SELECT a.nome FROM campaign_agents ca JOIN agents a ON a.id = ca.agent_id
      WHERE ca.campaign_id = 'ad000000-0000-0000-0000-0000000000c3' AND ca.canal = 'whatsapp') = 'Gil');
  SELECT adc.confere('em nome de outro cliente: o RLS recusa',
    adc.sqlstate_de($q$SELECT criar_agente('ad000000-0000-0000-0000-0000000000b0', 'Intruso', 'executiva', 'atendimento',
      'p', 'd', 't', repeat('Responda o que estiver nas informações. ', 4),
      'Falamos em nome da Corretora Canal B, em Campinas. Seguro de vida.', 'x', 8, '{}', NULL, NULL, true)$q$) = '42501');
RESET role;
RESET request.jwt.claims;

SET role authenticated;
SET request.jwt.claims = '{"sub":"ad000000-0000-0000-0000-0000000000a3"}';
  SELECT adc.confere('o leitor não cria agente',
    adc.sqlstate_de($q$SELECT criar_agente('ad000000-0000-0000-0000-0000000000a0', 'Leitor', 'executiva', 'atendimento',
      'p', 'd', 't', repeat('Responda o que estiver nas informações. ', 4),
      'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde.', 'x', 8, '{}', NULL, NULL, true)$q$) = '42501');
  SELECT adc.confere('nem escolhe o agente do canal',
    adc.sqlstate_de($q$UPDATE agentes_por_canal SET agent_id = 'ad000000-0000-0000-0000-0000000000a9'
      WHERE tenant_id = 'ad000000-0000-0000-0000-0000000000a0' AND canal = 'email'$q$) IN ('42501', 'sem erro')
    AND (SELECT agent_id FROM agentes_por_canal WHERE tenant_id = 'ad000000-0000-0000-0000-0000000000a0' AND canal = 'email')
        = 'ad000000-0000-0000-0000-0000000000a7');
RESET role;
RESET request.jwt.claims;

-- ===========================================================================
-- 7. A grade
-- ===========================================================================

SET role authenticated;
SET request.jwt.claims = '{"sub":"ad000000-0000-0000-0000-0000000000a2"}';
  SELECT adc.confere('a tela edita o texto do agente (tom, contexto, persona, objetivo)',
    adc.sqlstate_de($q$UPDATE agents SET tom = 'Fale calmo.', persona = 'acolhedora', objetivo = 'follow_up',
      contexto = 'Falamos em nome da Corretora Canal A, em Rio Preto. Planos de saúde e odonto.'
      WHERE id = 'ad000000-0000-0000-0000-0000000000a9'$q$) = 'sem erro');
  SELECT adc.confere('não muda o canal do agente',
    adc.sqlstate_de($q$UPDATE agents SET canal = 'sms' WHERE id = 'ad000000-0000-0000-0000-0000000000a8'$q$) = '42501');
  SELECT adc.confere('não apaga agente: remover é desligar',
    adc.sqlstate_de($q$DELETE FROM agents WHERE id = 'ad000000-0000-0000-0000-0000000000a6'$q$) = '42501');
  SELECT adc.confere('troca o agente do canal',
    adc.sqlstate_de($q$UPDATE agentes_por_canal SET agent_id = 'ad000000-0000-0000-0000-0000000000a9'
      WHERE tenant_id = 'ad000000-0000-0000-0000-0000000000a0' AND canal = 'email'$q$) = 'sem erro');
  SELECT adc.confere('não mexe na vigência (o agente responderia o passado)',
    adc.sqlstate_de($q$UPDATE agentes_por_canal SET vigente_desde = now() - interval '30 days'$q$) = '42501'
    AND adc.sqlstate_de($q$UPDATE campaign_agents SET vigente_desde = now() - interval '30 days'$q$) = '42501');
  SELECT adc.confere('não move a escolha para outro cliente',
    adc.sqlstate_de($q$UPDATE agentes_por_canal SET tenant_id = 'ad000000-0000-0000-0000-0000000000b0'$q$) = '42501');
  -- Apagar a exceção faria valer a data antiga do agente do canal: ele
  -- responderia sozinho o que chegou enquanto a campanha tinha outro (ou
  -- ninguém). Voltar ao do canal é uma linha, com data.
  SELECT adc.confere('o operador não apaga a exceção',
    adc.sqlstate_de($q$DELETE FROM campaign_agents WHERE campaign_id = 'ad000000-0000-0000-0000-0000000000c3'$q$) = '42501');
  SELECT adc.confere('volta a campanha ao agente do canal (herda)',
    adc.sqlstate_de($q$UPDATE campaign_agents SET agent_id = NULL, herda = true
      WHERE campaign_id = 'ad000000-0000-0000-0000-0000000000c3' AND canal = 'whatsapp'$q$) = 'sem erro');
  SELECT adc.confere('e quem responde passa a ser o do canal',
    (SELECT origem = 'canal' AND agent_id = 'ad000000-0000-0000-0000-0000000000a9' AND responde
       FROM quem_responde('ad000000-0000-0000-0000-0000000000a0', 'ad000000-0000-0000-0000-0000000000c3')
      WHERE canal = 'whatsapp'));
  SELECT adc.confere('e marca "ninguém" na campanha',
    adc.sqlstate_de($q$UPDATE campaign_agents SET herda = false
      WHERE campaign_id = 'ad000000-0000-0000-0000-0000000000c3' AND canal = 'whatsapp'$q$) = 'sem erro');
  SELECT adc.confere('e quem responde é ninguém, por escolha da campanha',
    (SELECT origem FROM quem_responde('ad000000-0000-0000-0000-0000000000a0', 'ad000000-0000-0000-0000-0000000000c3')
      WHERE canal = 'whatsapp') = 'ninguem');
  SELECT adc.confere('a tela pergunta quem responde',
    (SELECT count(*) FROM quem_responde('ad000000-0000-0000-0000-0000000000a0', 'ad000000-0000-0000-0000-0000000000c1')) = 2);
  SELECT adc.confere('e não enxerga a resposta de outro cliente',
    (SELECT count(*) FROM quem_responde('ad000000-0000-0000-0000-0000000000b0', 'ad000000-0000-0000-0000-0000000000cb')) = 0);
  SELECT adc.confere('a tela não lê a fila do worker',
    adc.sqlstate_de('SELECT * FROM fila_do_agente(5)') = '42501');
  SELECT adc.confere('nem escreve no vocabulário do catálogo',
    adc.sqlstate_de('INSERT INTO opt_out_termos DEFAULT VALUES') = '42501'
    AND adc.sqlstate_de('INSERT INTO recusa_termos DEFAULT VALUES') = '42501');
  -- A tela que está no ar escolhe agente do catálogo por `atribuir_agente`,
  -- que é INVOKER e copia `canal` e `pronto`. Estreitar o INSERT de agents
  -- quebraria isto entre a migration e o app novo — por isso não se estreitou.
  SELECT adc.confere('a cópia do catálogo por atribuir_agente continua funcionando para o operador',
    adc.sqlstate_de(format('SELECT atribuir_agente(%L, %L)', 'ad000000-0000-0000-0000-0000000000c5',
      (SELECT id FROM agents WHERE tenant_id IS NULL AND canal = 'whatsapp' ORDER BY nome LIMIT 1))) = 'sem erro');
RESET role;
RESET request.jwt.claims;

-- ===========================================================================
-- 8. A fila
-- ===========================================================================

-- (a) A campanha volta ao agente do canal: a volta tem data. O "ninguém" dela
-- valia havia dois dias, e o agente do canal também; sem renovar, a pessoa 10
-- (uma hora atrás) seria respondida sozinha pelo agente do canal.
UPDATE campaign_agents SET herda = true WHERE campaign_id = :c7 AND canal = 'whatsapp';
SELECT adc.confere('herdar: quem responde é o do canal',
  (SELECT origem = 'canal' AND agent_id = :ana FROM quem_responde(:ta, :c7) WHERE canal = 'whatsapp'));
SELECT adc.confere('e o que chegou antes da volta não entra na fila',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(10)));
SELECT adc.responde(10, 'e agora, como fica?');
SELECT adc.confere('e o que chega depois entra, com o agente do canal',
  (SELECT agent_id FROM fila_do_agente(100) WHERE contact_id = adc.c(10)) = :ana);

-- (b) "Ninguém" que vira agente: escolher é passar a responder.
UPDATE campaign_agents SET agent_id = :ana WHERE campaign_id = :c6 AND canal = 'whatsapp';
SELECT adc.confere('escolher o agente da campanha não responde o que chegou antes',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(9)));

-- (c) Religar o agente: o que chegou com o freio puxado ficou com uma pessoa.
UPDATE agents SET ativo = true WHERE id = :bruno;
SELECT adc.confere('religado, o agente volta a responder na exceção',
  (SELECT origem = 'campanha' AND responde FROM quem_responde(:ta, :c4) WHERE canal = 'whatsapp'));
SELECT adc.confere('mas não o que chegou enquanto estava desligado',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(5)));
SELECT adc.responde(5, 'oi, ainda estão aí?');
SELECT adc.confere('e o que chega depois de religado entra',
  (SELECT agent_id FROM fila_do_agente(100) WHERE contact_id = adc.c(5)) = :bruno);

-- (d) O agente do canal trocado: o novo responde só dali em diante.
SELECT adc.confere('antes da troca, a pessoa 11 está na fila com o agente do canal',
  (SELECT agent_id FROM fila_do_agente(100) WHERE contact_id = adc.c(11)) = :ana);
UPDATE agentes_por_canal SET agent_id = :lia WHERE tenant_id = :ta AND canal = 'whatsapp';
SELECT adc.confere('trocar o agente do canal não responde o que chegou antes',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(11)));

-- (e) Só a última resposta da pessoa: duas linhas seriam dois textos.
SELECT adc.responde(3, 'e para três pessoas?');
SELECT adc.confere('uma linha por pessoa, com a resposta mais recente',
  (SELECT count(*) FROM fila_do_agente(100) WHERE contact_id = adc.c(3)) = 1
  AND (SELECT texto FROM fila_do_agente(100) WHERE contact_id = adc.c(3)) = 'e para três pessoas?');

-- (f) A resposta que já tem rascunho não volta à fila.
INSERT INTO rascunhos (tenant_id, message_event_id, contact_id, agent_id, resposta_em, situacao, motivo)
SELECT tenant_id, message_event_id, contact_id, agent_id, resposta_em, 'escalar', 'teste'
  FROM fila_do_agente(100) WHERE contact_id = adc.c(3);
SELECT adc.confere('resposta com rascunho não volta à fila',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(3)));

-- (g) Supressão: a pessoa inteira, e só o endereço.
SELECT adc.confere('antes da supressão, as duas estão na fila',
  EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(5))
  AND EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(8)));
INSERT INTO suppression (tenant_id, contact_id, motivo) VALUES (:ta, adc.c(5), 'pediu para sair');
INSERT INTO suppression (tenant_id, canal, valor_norm, motivo) VALUES (:tb, 'whatsapp', '5511980000308', 'pediu para sair');
SELECT adc.confere('pessoa suprimida não entra na fila',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(5)));
SELECT adc.confere('endereço suprimido também não',
  NOT EXISTS (SELECT 1 FROM fila_do_agente(100) WHERE contact_id = adc.c(8)));

-- (h) A tela que está no ar escolhe por `atribuir_agente`, que não conhece
-- `herda`: gravar um agente por cima de uma linha que herdava deixa de herdar,
-- em vez de o CHECK recusar.
UPDATE campaign_agents SET agent_id = NULL, herda = true WHERE campaign_id = :c6 AND canal = 'whatsapp';
SET role authenticated;
SET request.jwt.claims = '{"sub":"ad000000-0000-0000-0000-0000000000a2"}';
  SELECT adc.confere('atribuir_agente por cima de uma linha que herdava',
    adc.sqlstate_de($q$SELECT atribuir_agente('ad000000-0000-0000-0000-0000000000c6', 'ad000000-0000-0000-0000-0000000000a8')$q$) = 'sem erro');
RESET role;
RESET request.jwt.claims;
SELECT adc.confere('e a linha deixa de herdar',
  (SELECT agent_id = :lia AND NOT herda FROM campaign_agents WHERE campaign_id = :c6 AND canal = 'whatsapp'));

-- (i) Quem responde não mudou, a data também não. O canal é da Lia desde
-- (d); a pessoa 11 responde agora; escolher a Lia como exceção da campanha —
-- ou voltar dela ao canal, que é a Lia — não pode tirar essa resposta da fila.
SELECT adc.responde(11, 'e como funciona a portabilidade?');
SELECT adc.confere('antes, a resposta nova está na fila com a Lia',
  (SELECT agent_id FROM fila_do_agente(100) WHERE contact_id = adc.c(11)) = :lia);
INSERT INTO campaign_agents (tenant_id, campaign_id, canal, agent_id) VALUES (:ta, :c1, 'whatsapp', :lia);
SELECT adc.confere('exceção com o MESMO agente do canal não renova a vigência',
  (SELECT agent_id FROM fila_do_agente(100) WHERE contact_id = adc.c(11)) = :lia);
UPDATE campaign_agents SET agent_id = NULL, herda = true WHERE campaign_id = :c1 AND canal = 'whatsapp';
SELECT adc.confere('nem voltar ao canal quando ele é o mesmo agente',
  (SELECT agent_id FROM fila_do_agente(100) WHERE contact_id = adc.c(11)) = :lia);

-- (j) O texto já composto: quem responde é perguntado de novo na hora de
-- mandar. A pessoa 9 (c6, Lia) e a 12 (cliente B, Bia) têm rascunho pronto e
-- vão para a fila; a 11 tem rascunho, e a campanha dela passa a "ninguém"
-- antes de enfileirar.
SELECT adc.pessoa(:tb, 12, :cb1, 'whatsapp', interval '1 hour');
SELECT adc.responde(9, 'pode me explicar melhor?');
SELECT registrar_rascunho(f.message_event_id, f.agent_id, 'pronto', 'Oi! Posso te explicar por aqui.', NULL, 'teste')
  FROM fila_do_agente(100) f WHERE f.contact_id IN (adc.c(9), adc.c(11), adc.c(12));
SELECT adc.confere('os três rascunhos existem',
  (SELECT count(*) FROM rascunhos WHERE contact_id IN (adc.c(9), adc.c(11), adc.c(12)) AND situacao = 'pronto') = 3);
UPDATE campaign_agents SET herda = false WHERE campaign_id = :c1 AND canal = 'whatsapp';
CREATE TABLE adc.enf AS
SELECT r.contact_id, enfileirar_resposta(r.message_event_id, 'real') AS destino
  FROM rascunhos r WHERE r.contact_id IN (adc.c(9), adc.c(11), adc.c(12));
SELECT adc.confere('enfileirar: o agente que ainda responde vai para a fila',
  (SELECT destino FROM adc.enf WHERE contact_id = adc.c(9)) = 'fila'
  AND (SELECT destino FROM adc.enf WHERE contact_id = adc.c(12)) = 'fila');
SELECT adc.confere('enfileirar: a campanha que passou a "ninguém" devolve o texto a uma pessoa',
  (SELECT destino FROM adc.enf WHERE contact_id = adc.c(11)) = 'devolvido'
  AND (SELECT envio_motivo FROM rascunhos WHERE contact_id = adc.c(11)) LIKE '%não responde mais nesta campanha%');

-- E a mensagem que já estava na fila: a Lia é desligada antes do despacho.
UPDATE agents SET ativo = false WHERE id = :lia;
CREATE TABLE adc.lote AS SELECT * FROM reivindicar_pendentes(50);
SELECT adc.confere('despacho: a mensagem do agente que ainda responde sai',
  EXISTS (SELECT 1 FROM adc.lote l JOIN messages m ON m.id = l.message_id
            JOIN rascunhos r ON r.id = m.rascunho_id WHERE r.contact_id = adc.c(12)));
SELECT adc.confere('despacho: a do agente desligado não sai — é cancelada e volta a uma pessoa',
  NOT EXISTS (SELECT 1 FROM adc.lote l JOIN messages m ON m.id = l.message_id
                JOIN rascunhos r ON r.id = m.rascunho_id WHERE r.contact_id = adc.c(9))
  AND (SELECT m.status FROM messages m JOIN rascunhos r ON r.id = m.rascunho_id WHERE r.contact_id = adc.c(9)) = 'cancelado'
  AND (SELECT envio FROM rascunhos WHERE contact_id = adc.c(9)) = 'devolvido');

-- (k) A frase que a tela do "Testar" sugere como pedido de saída
-- (`PEDIDO_DE_SAIDA_DO_TESTE` em app/src/agentes.ts) é uma que a blacklist
-- padrão NÃO pega: é o [SAIR] do agente que ela existe para exercitar.
SELECT adc.confere('a sugestão de pedido de saída da tela não é pega pela blacklist padrão',
  NOT EXISTS (SELECT 1 FROM privado.regra_da_resposta(:ta, 'não me procure mais'))
  AND EXISTS (SELECT 1 FROM blacklist_termos WHERE tenant_id = :ta));

SET role anon;
  -- No Supabase o anon tem SELECT de tabela por default privilege, e quem nega
  -- é o RLS (o run.sh imita isso). Sem linha nenhuma é a prova.
  SELECT adc.confere('anon não vê quem responde em canal nenhum',
    adc.sqlstate_de('SELECT * FROM agentes_por_canal') = '42501'
    OR NOT EXISTS (SELECT 1 FROM agentes_por_canal));
  SELECT adc.confere('nem chama as funções novas',
    adc.sqlstate_de($q$SELECT * FROM quem_responde('ad000000-0000-0000-0000-0000000000a0', 'ad000000-0000-0000-0000-0000000000c1')$q$) = '42501');
RESET role;
RESET request.jwt.claims;

SELECT adc.confere('superfície: a fila é do worker; a tela chama quem_responde e criar_agente',
  NOT has_function_privilege('authenticated', 'fila_do_agente(integer)', 'EXECUTE')
  AND has_function_privilege('service_role', 'fila_do_agente(integer)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'quem_responde(uuid, uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'criar_agente(uuid, text, text, text, text, text, text, text, text, text, integer, text[], integer, uuid, boolean, canal[], uuid, canal[])', 'EXECUTE'));

-- ===========================================================================

\echo ''
\echo '============= O AGENTE DE TODOS OS CANAIS ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM adc.resultado ORDER BY id;
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM adc.resultado;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM adc.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'agente_do_canal: % asserções falharam', (SELECT count(*) FROM adc.resultado WHERE NOT ok);
  END IF;
END;
$$;
