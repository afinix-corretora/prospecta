-- O e-mail de cada campanha (D62).
--
-- O que este arquivo sustenta, em ordem de quanto custaria errar:
--
--   1. a campanha que escolheu um provedor de e-mail SÓ manda por ele — no
--      agendador E no despacho. Escolher num e rebalancear para outro no
--      outro é o D40: os dois discordando sobre o mesmo fato;
--   2. a escolha que o motor não consegue cumprir é recusada na hora de
--      escolher, com motivo, e não vira passo adiado para sempre;
--   3. remover conta arquiva: a história e o webhook ficam, o pool esquece;
--   4. a grade: o cliente não apaga conta nem nasce conta com ponteiro de
--      Vault escolhido à mão.
--
-- Cada asserção do roteador tem linha de base: a conta escolhida é a de
-- MENOR health, para que "foi pela escolhida" nunca coincida com "foi pela
-- que o rodízio escolheria de qualquer jeito" (D36).

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ec;
CREATE TABLE ec.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA ec TO authenticated;
GRANT INSERT, SELECT ON ec.resultado TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ec TO authenticated;

CREATE FUNCTION ec.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ec.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION ec.confere(text, boolean, text) TO authenticated;

-- Roda UMA vez e guarda o SQLSTATE: recusa por privilégio (42501), por CHECK
-- (23514) e pelo gatilho (23001) são coisas diferentes, e "deu erro" também é
-- o que um nome de coluna errado dá.
CREATE FUNCTION ec.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE;
END; $$;
GRANT EXECUTE ON FUNCTION ec.sqlstate_de(text) TO authenticated;

CREATE FUNCTION ec.recusa(p_nome text, p_sqlstate text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := ec.sqlstate_de(p_sql);
  PERFORM ec.confere(p_nome, v = p_sqlstate, 'SQLSTATE ' || v);
END; $$;
GRANT EXECUTE ON FUNCTION ec.recusa(text, text, text) TO authenticated;

CREATE FUNCTION ec.aceita(p_nome text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := ec.sqlstate_de(p_sql);
  PERFORM ec.confere(p_nome, v = 'sem erro', v);
END; $$;
GRANT EXECUTE ON FUNCTION ec.aceita(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Um cliente, duas contas de e-mail, uma de WhatsApp e uma fria
-- ---------------------------------------------------------------------------

\set tenant '\'ec000000-0000-0000-0000-0000000000a0\''
\set admin  '\'ec000000-0000-0000-0000-0000000000a1\''
\set oper   '\'ec000000-0000-0000-0000-0000000000a2\''
\set camp   '\'ec000000-0000-0000-0000-0000000000c1\''
\set zap    '\'ec000000-0000-0000-0000-0000000000c2\''
\set versao '\'ec000000-0000-0000-0000-0000000000f2\''
\set E1     '\'ec000000-0000-0000-0000-0000000000e1\''
\set E2     '\'ec000000-0000-0000-0000-0000000000e2\''
\set FRIA   '\'ec000000-0000-0000-0000-0000000000e3\''
\set CHIP   '\'ec000000-0000-0000-0000-0000000000e4\''

INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Correio', 'corretora-correio');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:tenant, :admin, 'admin'),
  (:tenant, :oper,  'operador');

-- E1 tem health maior: é quem o rodízio escolheria. A campanha vai escolher E2.
INSERT INTO sender_accounts
  (id, tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria, health_score, config)
VALUES
  (:E1,   :tenant, 'email',    'resend',  'resgate@corretora.com.br', 'Resend',   'morna', 50, 100, '{}'),
  (:E2,   :tenant, 'email',    'locaweb', 'contato@corretora.com.br', 'Locaweb',  'morna',  2,  60,
   '{"responder_para":"in@corretora.com.br","assunto_padrao":"Oi"}'),
  (:FRIA, :tenant, 'email',    'resend',  'frio@outra.com.br',        'Fria',     'fria',  50, 100, '{}'),
  (:CHIP, :tenant, 'whatsapp', 'uazapi',  '5511990000001',            'Chip',     'morna', 50, 100, '{}');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados)
VALUES (:camp, :tenant, 'Correio', 'morna', 'opt-in', '{email}'),
       (:zap,  :tenant, 'Só zap',  'morna', 'opt-in', '{whatsapp}');

INSERT INTO flows (id, tenant_id, nome)
VALUES ('ec000000-0000-0000-0000-0000000000f1', :tenant, 'Correio');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
VALUES (:versao, :tenant, 'ec000000-0000-0000-0000-0000000000f1', 1);
INSERT INTO flow_steps (tenant_id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  (:tenant, :versao, 1, 'email', 0, 'Assunto: Oi\n\nprimeiro'),
  -- O segundo passo fica longe: cada pessoa tem UMA mensagem neste arquivo, e
  -- a asserção que pergunta "por onde ela saiu" não pode achar duas.
  (:tenant, :versao, 2, 'email', 72, 'segundo');

-- Uma pessoa por cenário, cada uma com o seu e-mail.
CREATE FUNCTION ec.inscrever(p_n int) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_contato uuid; v_insc uuid;
BEGIN
  v_contato := ('ec000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid;
  INSERT INTO contacts (id, tenant_id, nome, origem)
  VALUES (v_contato, 'ec000000-0000-0000-0000-0000000000a0', 'Pessoa ' || p_n, 'planilha');
  INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
  VALUES ('ec000000-0000-0000-0000-0000000000a0', v_contato, 'email',
          'p' || p_n || '@cliente.com.br', 'p' || p_n || '@cliente.com.br', 'planilha');
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id, next_run_at)
  VALUES ('ec000000-0000-0000-0000-0000000000a0', v_contato,
          'ec000000-0000-0000-0000-0000000000c1', 'ec000000-0000-0000-0000-0000000000f2',
          now() - interval '1 minute')
  RETURNING id INTO v_insc;
  RETURN v_insc;
END; $$;

-- A ação do agendador para um enrollment, numa passada só.
CREATE TABLE ec.passada (enrollment_id uuid, acao text, detalhe text);
CREATE FUNCTION ec.passar() RETURNS void
LANGUAGE sql AS $$
  DELETE FROM ec.passada;
  INSERT INTO ec.passada SELECT * FROM processar_vencidos(100, 'real');
$$;

-- ===========================================================================
-- 1. Linha de base: sem escolha, o rodízio de sempre (E1, a de maior health)
-- ===========================================================================

CREATE TEMP TABLE insc (n int PRIMARY KEY, id uuid);
INSERT INTO insc VALUES (1, ec.inscrever(1));
SELECT ec.passar();

SELECT ec.confere('linha de base: sem escolha, o e-mail sai pela conta de maior health (E1)',
  (SELECT m.sender_account_id FROM messages m JOIN insc i ON i.id = m.enrollment_id WHERE i.n = 1)
    = :E1::uuid);

-- ===========================================================================
-- 2. A campanha escolhe E2, e o agendador obedece
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a2"}';
  SELECT ec.aceita('o OPERADOR escolhe o e-mail da campanha pela tela (sem função nova)',
    'UPDATE campaigns SET remetente_email_id = ''ec000000-0000-0000-0000-0000000000e2''
      WHERE id = ''ec000000-0000-0000-0000-0000000000c1''');
COMMIT;

INSERT INTO insc VALUES (2, ec.inscrever(2));
SELECT ec.passar();

SELECT ec.confere('com escolha, o e-mail sai pela escolhida (E2), não pela de maior health',
  (SELECT m.sender_account_id FROM messages m JOIN insc i ON i.id = m.enrollment_id WHERE i.n = 2)
    = :E2::uuid);

-- E2 tem quota 2 e acabou de gastar 1. Mais uma pessoa a esgota.
INSERT INTO insc VALUES (3, ec.inscrever(3));
SELECT ec.passar();
SELECT ec.confere('a segunda mensagem da escolhida também sai por ela',
  (SELECT m.sender_account_id FROM messages m JOIN insc i ON i.id = m.enrollment_id WHERE i.n = 3)
    = :E2::uuid);

-- Esgotada a escolhida, o passo ADIA — E1 tem quota sobrando e não é usada.
INSERT INTO insc VALUES (4, ec.inscrever(4));
SELECT ec.passar();

SELECT ec.confere('escolhida esgotada: o passo adia em vez de sair por outra conta',
  (SELECT acao FROM ec.passada p JOIN insc i ON i.id = p.enrollment_id WHERE i.n = 4)
    = 'adiado_sem_remetente',
  coalesce((SELECT acao FROM ec.passada p JOIN insc i ON i.id = p.enrollment_id WHERE i.n = 4), '(nada)'));
SELECT ec.confere('e nenhuma mensagem nasceu pela E1 para essa pessoa',
  NOT EXISTS (SELECT 1 FROM messages m JOIN insc i ON i.id = m.enrollment_id WHERE i.n = 4));
SELECT ec.confere('o adiamento é até a quota da ESCOLHIDA voltar (amanhã), não a de outra conta',
  (SELECT next_run_at FROM enrollments e JOIN insc i ON i.id = e.id WHERE i.n = 4)
    >= (current_date + 1)::timestamptz);

-- Quando acordar de novo: pela quota da escolhida, não pelo circuito de
-- outra. E1 com circuito fechando em 30 min diria "volta em 30 min" ao pool
-- inteiro; para esta campanha a resposta é amanhã. Linha de base ao lado:
-- a função antiga, que não sabe da escolha, responde os 30 min.
UPDATE sender_accounts SET estado = 'circuito_aberto', circuito_aberto_ate = now() + interval '30 minutes'
 WHERE id = :E1;
SELECT ec.confere('linha de base: o pool inteiro volta em 30 min (circuito de E1)',
  privado.proximo_horario_de_pool(:tenant, 'email', 'morna') < now() + interval '1 hour');
SELECT ec.confere('a campanha que escolheu E2 só volta quando a quota de E2 voltar',
  privado.proximo_horario_da_campanha(:tenant, :camp, 'email') >= (current_date + 1)::timestamptz);
UPDATE sender_accounts SET estado = 'ativo', circuito_aberto_ate = NULL WHERE id = :E1;

-- ===========================================================================
-- 3. O despacho concorda: trocar o provedor vale para a fila
-- ===========================================================================

-- A mensagem da pessoa 1 nasceu por E1, antes da escolha, e ainda está
-- pendente. A campanha agora manda por E2 — mas E2 está esgotada. Libera uma
-- vaga em E2, como faria a virada do dia.
UPDATE sender_accounts SET enviados_na_janela = 1 WHERE id = :E2;

CREATE TEMP TABLE lote AS SELECT * FROM reivindicar_pendentes(50);

SELECT ec.confere('a pendente nascida por E1 sai pela escolhida, não pela antiga',
  (SELECT l.sender_id FROM lote l JOIN messages m ON m.id = l.message_id
     JOIN insc i ON i.id = m.enrollment_id WHERE i.n = 1) = :E2::uuid);
SELECT ec.confere('e a linha da mensagem passou a apontar para a escolhida',
  (SELECT m.sender_account_id FROM messages m JOIN insc i ON i.id = m.enrollment_id WHERE i.n = 1)
    = :E2::uuid);

-- Linha de base do despacho: campanha sem escolha não sofre nada disso.
UPDATE campaigns SET remetente_email_id = NULL WHERE id = :camp;
UPDATE messages SET status = 'pendente', reivindicada_em = NULL, sender_account_id = :E1
 WHERE enrollment_id = (SELECT id FROM insc WHERE n = 1);
CREATE TEMP TABLE lote2 AS SELECT * FROM reivindicar_pendentes(50);
SELECT ec.confere('linha de base do despacho: sem escolha, a pendente sai pela própria conta',
  (SELECT l.sender_id FROM lote2 l JOIN messages m ON m.id = l.message_id
     JOIN insc i ON i.id = m.enrollment_id WHERE i.n = 1) = :E1::uuid);

-- A escolhida adoece com mensagem dela na fila: a mensagem ESPERA, não foge
-- para E1. Rebalancear entre contas escolhidas é o D37; para fora delas, não.
UPDATE campaigns SET remetente_email_id = :E2 WHERE id = :camp;
UPDATE messages SET status = 'pendente', reivindicada_em = NULL
 WHERE enrollment_id IN (SELECT id FROM insc WHERE n IN (2, 3));
UPDATE sender_accounts SET estado = 'circuito_aberto', circuito_aberto_ate = now() + interval '1 hour'
 WHERE id = :E2;
CREATE TEMP TABLE lote3 AS SELECT * FROM reivindicar_pendentes(50);

SELECT ec.confere('escolhida com circuito aberto: a fila dela não sai por outra conta',
  NOT EXISTS (SELECT 1 FROM lote3 l JOIN messages m ON m.id = l.message_id
                JOIN insc i ON i.id = m.enrollment_id WHERE i.n IN (2, 3)));
SELECT ec.confere('e as mensagens continuam pendentes e apontando para a escolhida',
  (SELECT bool_and(m.status = 'pendente' AND m.sender_account_id = :E2::uuid)
     FROM messages m JOIN insc i ON i.id = m.enrollment_id WHERE i.n IN (2, 3)));

UPDATE sender_accounts SET estado = 'ativo', circuito_aberto_ate = NULL WHERE id = :E2;

-- ===========================================================================
-- 4. A escolha que o motor não consegue cumprir é recusada na hora
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a2"}';
  SELECT ec.recusa('escolher uma conta de WhatsApp como e-mail é recusado', '23001',
    'UPDATE campaigns SET remetente_email_id = ''ec000000-0000-0000-0000-0000000000e4''
      WHERE id = ''ec000000-0000-0000-0000-0000000000c1''');
  SELECT ec.recusa('escolher conta fria numa campanha morna é recusado (D4)', '23001',
    'UPDATE campaigns SET remetente_email_id = ''ec000000-0000-0000-0000-0000000000e3''
      WHERE id = ''ec000000-0000-0000-0000-0000000000c1''');
  SELECT ec.recusa('escolher e-mail numa campanha que não manda e-mail é recusado (D55)', '23001',
    'UPDATE campaigns SET remetente_email_id = ''ec000000-0000-0000-0000-0000000000e1''
      WHERE id = ''ec000000-0000-0000-0000-0000000000c2''');
COMMIT;

SELECT ec.confere('as recusas não mexeram na escolha que valia',
  (SELECT remetente_email_id FROM campaigns WHERE id = :camp) = :E2::uuid);

-- ===========================================================================
-- 5. Remover é arquivar
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a2"}';
  SELECT ec.recusa('operador não remove conta', '42501',
    'SELECT public.remover_remetente(''ec000000-0000-0000-0000-0000000000e1'')');
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a1"}';
  SELECT ec.recusa('a conta escolhida por uma campanha não se remove (seria passo adiado para sempre)',
    '23001', 'SELECT public.remover_remetente(''ec000000-0000-0000-0000-0000000000e2'')');
  SELECT ec.aceita('admin remove uma conta que ninguém escolheu',
    'SELECT public.remover_remetente(''ec000000-0000-0000-0000-0000000000e1'')');
COMMIT;

SELECT ec.confere('removida: fora do pool, arquivada, e a história ficou',
  (SELECT estado = 'desativado' AND removido_em IS NOT NULL FROM sender_accounts WHERE id = :E1)
  AND NOT EXISTS (SELECT 1 FROM privado.remetentes_disponiveis(:tenant, 'email', 'morna') WHERE id = :E1::uuid)
  AND EXISTS (SELECT 1 FROM messages WHERE sender_account_id = :E1::uuid));

SELECT ec.confere('o webhook da removida ainda resolve (bounce de e-mail já enviado continua chegando)',
  EXISTS (SELECT 1 FROM resolver_webhook((SELECT webhook_token FROM sender_accounts WHERE id = :E1))));

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a1"}';
  SELECT ec.recusa('devolver ao pool uma conta removida é recusado pelo CHECK', '23514',
    'UPDATE sender_accounts SET estado = ''ativo'' WHERE id = ''ec000000-0000-0000-0000-0000000000e1''');
  SELECT ec.aceita('remover de novo é inofensivo',
    'SELECT public.remover_remetente(''ec000000-0000-0000-0000-0000000000e1'')');
  SELECT ec.aceita('o mesmo endereço volta a poder ser cadastrado depois de removido',
    'INSERT INTO sender_accounts (tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria)
     VALUES (''ec000000-0000-0000-0000-0000000000a0'', ''email'', ''resend'', ''resgate@corretora.com.br'',
             ''Resend de novo'', ''morna'', 50)');
  SELECT ec.recusa('mas não duas vezes ao mesmo tempo', '23505',
    'INSERT INTO sender_accounts (tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria)
     VALUES (''ec000000-0000-0000-0000-0000000000a0'', ''email'', ''resend'', ''resgate@corretora.com.br'',
             ''Resend de novo 2'', ''morna'', 50)');
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a1"}';
  SELECT ec.recusa('escolher uma conta removida é recusado', '23001',
    'UPDATE campaigns SET remetente_email_id = ''ec000000-0000-0000-0000-0000000000e1''
      WHERE id = ''ec000000-0000-0000-0000-0000000000c1''');
COMMIT;

-- ===========================================================================
-- 6. O que o operador lê, e quem grava a verificação
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a2"}';
  CREATE TEMP TABLE contas_vistas ON COMMIT DROP AS
    SELECT * FROM public.contas_de_email('ec000000-0000-0000-0000-0000000000a0');
  SELECT ec.confere('o operador lista as contas de e-mail (sem enxergar sender_accounts)',
    (SELECT count(*) FROM contas_vistas) = 3
    AND (SELECT count(*) FROM sender_accounts) = 0);
  SELECT ec.confere('a removida não aparece na lista',
    NOT EXISTS (SELECT 1 FROM contas_vistas WHERE id = 'ec000000-0000-0000-0000-0000000000e1'));
  SELECT ec.confere('e conta de outro canal também não',
    NOT EXISTS (SELECT 1 FROM contas_vistas WHERE id = 'ec000000-0000-0000-0000-0000000000e4'));
  SELECT ec.recusa('quem não opera o cliente não lista', '42501',
    'SELECT * FROM public.contas_de_email(''00000000-0000-0000-0000-0000000000aa'')');
COMMIT;

SELECT ec.confere('a tela não grava verificação: só quem perguntou ao provedor',
  NOT has_function_privilege('authenticated',
    'public.registrar_verificacao_remetente(uuid, boolean, text)', 'EXECUTE')
  AND NOT has_function_privilege('anon',
    'public.registrar_verificacao_remetente(uuid, boolean, text)', 'EXECUTE'));

SELECT registrar_verificacao_remetente(:E2, false, 'HTTP 401');
SELECT ec.confere('a verificação fica gravada na conta',
  (SELECT verificacao_ok = false AND verificacao_detalhe = 'HTTP 401' AND verificado_em IS NOT NULL
     FROM sender_accounts WHERE id = :E2));
-- O estado, e não a presença no pool: a esta altura E2 já gastou a quota do
-- dia, e "fora do pool" aqui seria verdade pelo motivo errado.
SELECT ec.confere('e não tira a conta do pool: quem faz isso é o circuito',
  (SELECT estado = 'ativo' AND circuito_aberto_ate IS NULL AND falhas_consecutivas = 0
     FROM sender_accounts WHERE id = :E2));

SELECT ec.confere('remover e listar não são chamáveis por anon',
  NOT has_function_privilege('anon', 'public.remover_remetente(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.contas_de_email(uuid)', 'EXECUTE'));

-- ===========================================================================
-- 7. A grade da conta: nascer só com o que a tela preenche, e não morrer
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"ec000000-0000-0000-0000-0000000000a1"}';
  SELECT ec.recusa('apagar conta é recusado por privilégio (levava a história junto)', '42501',
    'DELETE FROM sender_accounts WHERE id = ''ec000000-0000-0000-0000-0000000000e3''');
  SELECT ec.recusa('nascer com ponteiro de Vault escolhido à mão é recusado (D59)', '42501',
    'INSERT INTO sender_accounts (tenant_id, canal, provedor, identificador, tipo_permitido, quota_diaria, credenciais_secret_id)
     VALUES (''ec000000-0000-0000-0000-0000000000a0'', ''email'', ''resend'', ''x@corretora.com.br'',
             ''morna'', 50, gen_random_uuid())');
  SELECT ec.recusa('nascer com a quota já gasta ao contrário é recusado', '42501',
    'INSERT INTO sender_accounts (tenant_id, canal, provedor, identificador, tipo_permitido, quota_diaria, estado)
     VALUES (''ec000000-0000-0000-0000-0000000000a0'', ''email'', ''resend'', ''y@corretora.com.br'',
             ''morna'', 50, ''circuito_aberto'')');
  SELECT ec.recusa('arquivar à mão, sem a função, é recusado', '42501',
    'UPDATE sender_accounts SET removido_em = now() WHERE id = ''ec000000-0000-0000-0000-0000000000e3''');
COMMIT;

SELECT ec.confere('a conta fria continua lá',
  EXISTS (SELECT 1 FROM sender_accounts WHERE id = :FRIA AND removido_em IS NULL));

-- ===========================================================================

\echo ''
\echo '============= E-MAIL POR CAMPANHA ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM ec.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM ec.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ec.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'e-mail por campanha: % asserções falharam',
      (SELECT count(*) FROM ec.resultado WHERE NOT ok);
  END IF;
END;
$$;
