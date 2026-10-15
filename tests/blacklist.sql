-- A blacklist é do cliente (D63).
--
-- O que este arquivo sustenta, em ordem de quanto custaria errar:
--
--   1. todo cliente NASCE com a lista padrão — cliente sem blacklist deixaria
--      "pare" passar, e isso não dá erro nenhum;
--   2. cada ação faz o que diz e só isso: `suprimir` apaga a pessoa,
--      `identidade_invalida` só o endereço, `recusa` nada;
--   3. domínio bloqueado vale onde a supressão vale — no roteador E no
--      despacho (invariante 2);
--   4. a lista de um cliente não vaza para outro, e a grade só deixa a tela
--      escrever o que é da tela.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA bl;
CREATE TABLE bl.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA bl TO authenticated, anon;
GRANT INSERT, SELECT ON bl.resultado TO authenticated, anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA bl TO authenticated, anon;

CREATE FUNCTION bl.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO bl.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION bl.confere(text, boolean, text) TO authenticated, anon;

-- Roda UMA vez e guarda o SQLSTATE: privilégio (42501), CHECK (23514) e "deu
-- erro por um nome errado" são coisas diferentes.
CREATE FUNCTION bl.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE;
END; $$;
GRANT EXECUTE ON FUNCTION bl.sqlstate_de(text) TO authenticated, anon;

CREATE FUNCTION bl.recusa(p_nome text, p_sqlstate text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := bl.sqlstate_de(p_sql);
  PERFORM bl.confere(p_nome, v = p_sqlstate, 'SQLSTATE ' || v);
END; $$;
GRANT EXECUTE ON FUNCTION bl.recusa(text, text, text) TO authenticated, anon;

CREATE FUNCTION bl.aceita(p_nome text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := bl.sqlstate_de(p_sql);
  PERFORM bl.confere(p_nome, v = 'sem erro', v);
END; $$;
GRANT EXECUTE ON FUNCTION bl.aceita(text, text) TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- Dois clientes: o B1, com admin e operador, e o B2, só para vazar ou não
-- ---------------------------------------------------------------------------

\set t1    '\'b1000000-0000-0000-0000-0000000000a0\''
\set t2    '\'b2000000-0000-0000-0000-0000000000a0\''
\set admin '\'b1000000-0000-0000-0000-0000000000a1\''
\set oper  '\'b1000000-0000-0000-0000-0000000000a2\''
\set admin2 '\'b2000000-0000-0000-0000-0000000000a1\''

INSERT INTO tenants (id, nome, slug) VALUES
  (:t1, 'Corretora Lista', 'corretora-lista'),
  (:t2, 'Corretora Vizinha', 'corretora-vizinha');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:t1, :admin, 'admin'),
  (:t1, :oper,  'operador'),
  (:t2, :admin2, 'admin');

-- ===========================================================================
-- 1. Todo cliente nasce com a lista padrão
-- ===========================================================================

SELECT bl.confere('o cliente novo nasce com a lista padrão inteira',
  (SELECT count(*) FROM blacklist_termos WHERE tenant_id = :t1)
    = (SELECT count(DISTINCT termo) FROM (SELECT termo FROM opt_out_termos
                                          UNION SELECT termo FROM recusa_termos) x) + 3,
  (SELECT count(*)::text FROM blacklist_termos WHERE tenant_id = :t1));

SELECT bl.confere('a recusa entra como suprimir no padrão (D63)',
  (SELECT acao = 'suprimir' FROM blacklist_termos WHERE tenant_id = :t1 AND termo = 'sem interesse'));

SELECT bl.confere('endereço errado entra como identidade_invalida',
  (SELECT acao = 'identidade_invalida' FROM blacklist_termos
    WHERE tenant_id = :t1 AND termo = 'numero errado'));

-- "nao quero" existe nas duas listas do produto, com contextos diferentes.
SELECT bl.confere('"nao quero" vira um termo só, com os contextos das duas listas',
  (SELECT exige_uma_de @> ARRAY['receber','nada'] AND origem = 'padrao'
     FROM blacklist_termos WHERE tenant_id = :t1 AND termo = 'nao quero'),
  (SELECT exige_uma_de::text FROM blacklist_termos WHERE tenant_id = :t1 AND termo = 'nao quero'));

-- Semear de novo não sobrescreve a escolha do cliente.
UPDATE blacklist_termos SET acao = 'recusa' WHERE tenant_id = :t1 AND termo = 'nao preciso';
SELECT bl.confere('semear de novo não acrescenta nada',
  privado.semear_blacklist(:t1) = 0);
SELECT bl.confere('e não desfaz a ação que o cliente escolheu',
  (SELECT acao = 'recusa' FROM blacklist_termos WHERE tenant_id = :t1 AND termo = 'nao preciso'));

-- ===========================================================================
-- 2. Normalização num lugar só
-- ===========================================================================

INSERT INTO blacklist_termos (tenant_id, termo, exige_uma_de, acao)
VALUES (:t1, '  Tô FORA!! ', ARRAY[' Lista', '', 'CADASTRO'], 'suprimir');
SELECT bl.confere('o termo é gravado na forma da resposta normalizada',
  EXISTS (SELECT 1 FROM blacklist_termos WHERE tenant_id = :t1 AND termo = 'to fora'));
SELECT bl.confere('e o contexto também, sem palavra vazia',
  (SELECT exige_uma_de = ARRAY['cadastro','lista'] FROM blacklist_termos
    WHERE tenant_id = :t1 AND termo = 'to fora'),
  (SELECT exige_uma_de::text FROM blacklist_termos WHERE tenant_id = :t1 AND termo = 'to fora'));
SELECT bl.recusa('termo que normaliza para nada é recusado', '23514',
  'INSERT INTO blacklist_termos (tenant_id, termo, acao)
   VALUES (''b1000000-0000-0000-0000-0000000000a0'', ''!!'', ''suprimir'')');

INSERT INTO blacklist_dominios (tenant_id, dominio) VALUES (:t1, '  @Concorrente.COM.br ');
SELECT bl.confere('o domínio é gravado minúsculo e sem a arroba',
  EXISTS (SELECT 1 FROM blacklist_dominios WHERE tenant_id = :t1 AND dominio = 'concorrente.com.br'));
SELECT bl.recusa('domínio sem ponto é recusado', '23514',
  'INSERT INTO blacklist_dominios (tenant_id, dominio)
   VALUES (''b1000000-0000-0000-0000-0000000000a0'', ''localhost'')');

-- ===========================================================================
-- 3. O classificador
-- ===========================================================================

CREATE FUNCTION bl.acao(p_tenant uuid, p_texto text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT acao::text || ':' || termo
                     FROM privado.regra_da_resposta(p_tenant, p_texto)), '(nenhuma)');
$$;

SELECT bl.confere('o termo novo dispara',
  bl.acao(:t1, 'to fora da lista de vcs') = 'suprimir:to fora', bl.acao(:t1, 'to fora da lista de vcs'));
SELECT bl.confere('e respeita o contexto: sem "lista" nas três seguintes, não dispara',
  bl.acao(:t1, 'to fora hoje, amanha falamos') = '(nenhuma)', bl.acao(:t1, 'to fora hoje, amanha falamos'));

SELECT bl.confere('recusa escolhida pelo cliente devolve recusa',
  bl.acao(:t1, 'nao preciso') = 'recusa:nao preciso', bl.acao(:t1, 'nao preciso'));
-- Linha de base acima: sem o "pare", a frase É recusa. Com ele, suprimir ganha.
SELECT bl.confere('pedido de saída ganha de recusa na mesma frase',
  bl.acao(:t1, 'nao preciso, pare') = 'suprimir:pare', bl.acao(:t1, 'nao preciso, pare'));

SELECT bl.confere('linha de base: "isso e spam" suprime',
  bl.acao(:t1, 'isso e spam') = 'suprimir:spam', bl.acao(:t1, 'isso e spam'));
UPDATE blacklist_termos SET ativo = false WHERE tenant_id = :t1 AND termo = 'spam';
SELECT bl.confere('termo desligado não dispara',
  bl.acao(:t1, 'isso e spam') = '(nenhuma)', bl.acao(:t1, 'isso e spam'));

-- A lista de um cliente não é a do outro.
INSERT INTO blacklist_termos (tenant_id, termo, acao) VALUES (:t2, 'abacaxi', 'suprimir');
SELECT bl.confere('o termo do vizinho dispara no vizinho',
  bl.acao(:t2, 'que abacaxi') = 'suprimir:abacaxi');
SELECT bl.confere('e não aqui',
  bl.acao(:t1, 'que abacaxi') = '(nenhuma)', bl.acao(:t1, 'que abacaxi'));
SELECT bl.confere('desligar "spam" aqui não desliga no vizinho',
  bl.acao(:t2, 'isso e spam') = 'suprimir:spam');

-- ===========================================================================
-- 4. Ponta a ponta: cada ação faz o que diz
-- ===========================================================================

INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, tipo_permitido, quota_diaria)
VALUES ('b1000000-0000-0000-0000-00000000005a', :t1, 'whatsapp', 'uazapi', '5511990002020', 'morna', 100),
       ('b1000000-0000-0000-0000-00000000005e', :t1, 'email', 'resend', 'oi@lista.com.br', 'morna', 100);
INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados) VALUES
  ('b1000000-0000-0000-0000-0000000000c1', :t1, 'Zap', 'morna', 'opt-in', '{whatsapp}'),
  ('b1000000-0000-0000-0000-0000000000c2', :t1, 'Correio', 'morna', 'opt-in', '{email}');
INSERT INTO flows (id, tenant_id, nome) VALUES
  ('b1000000-0000-0000-0000-0000000000f0', :t1, 'Zap'),
  ('b1000000-0000-0000-0000-0000000000f8', :t1, 'Correio');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao) VALUES
  ('b1000000-0000-0000-0000-0000000000f1', :t1, 'b1000000-0000-0000-0000-0000000000f0', 1),
  ('b1000000-0000-0000-0000-0000000000f9', :t1, 'b1000000-0000-0000-0000-0000000000f8', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('b1000000-0000-0000-0000-0000000000f2', :t1, 'b1000000-0000-0000-0000-0000000000f1', 1, 'whatsapp', 0, 'oi'),
  ('b1000000-0000-0000-0000-0000000000fa', :t1, 'b1000000-0000-0000-0000-0000000000f9', 1, 'email', 0, 'oi');

-- Uma pessoa com WhatsApp e e-mail, que recebeu o primeiro toque no WhatsApp.
CREATE FUNCTION bl.pessoa(p_n int, p_email text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_c uuid; v_e uuid; v_zap uuid;
BEGIN
  v_c := ('b1000000-0000-0000-0000-0000000001' || lpad(p_n::text, 2, '0'))::uuid;
  INSERT INTO contacts (id, tenant_id, nome, origem)
  VALUES (v_c, 'b1000000-0000-0000-0000-0000000000a0', 'Pessoa ' || p_n, 'planilha');
  INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
  VALUES ('b1000000-0000-0000-0000-0000000000a0', v_c, 'whatsapp',
          '55119700000' || lpad(p_n::text, 2, '0'), '55119700000' || lpad(p_n::text, 2, '0'), 'planilha')
  RETURNING id INTO v_zap;
  INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
  VALUES ('b1000000-0000-0000-0000-0000000000a0', v_c, 'email', p_email, p_email, 'planilha');
  RETURN v_c;
END; $$;

-- Responde à mensagem de WhatsApp que recebeu. Devolve a mensagem.
CREATE FUNCTION bl.toque(p_contato uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_e uuid; v_m uuid;
BEGIN
  INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id)
  VALUES ('b1000000-0000-0000-0000-0000000000a0', p_contato,
          'b1000000-0000-0000-0000-0000000000c1', 'b1000000-0000-0000-0000-0000000000f1')
  RETURNING id INTO v_e;
  INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id,
                        sender_account_id, canal, status, conteudo)
  SELECT 'b1000000-0000-0000-0000-0000000000a0', v_e, 'b1000000-0000-0000-0000-0000000000f2',
         ci.id, 'b1000000-0000-0000-0000-00000000005a', 'whatsapp', 'pendente', 'oi'
    FROM contact_identities ci WHERE ci.contact_id = p_contato AND ci.canal = 'whatsapp'
  RETURNING id INTO v_m;
  UPDATE messages SET status = 'enviado' WHERE id = v_m;
  RETURN v_m;
END; $$;

CREATE TABLE bl.gente (n int PRIMARY KEY, contato uuid, msg uuid);

-- ---- identidade_invalida: "número errado" ----------------------------------
INSERT INTO bl.gente (n, contato) VALUES (1, bl.pessoa(1, 'um@livre.com.br'));
UPDATE bl.gente SET msg = bl.toque(contato) WHERE n = 1;
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
SELECT :t1, msg, 'respondido', '{"texto":"oi, numero errado, nao conheco"}'::jsonb
  FROM bl.gente WHERE n = 1;

SELECT bl.confere('número errado: a identidade do WhatsApp fica inválida',
  (SELECT NOT valida FROM contact_identities ci JOIN bl.gente g ON g.contato = ci.contact_id
    WHERE g.n = 1 AND ci.canal = 'whatsapp'));
SELECT bl.confere('e o ENDEREÇO entra na supressão',
  EXISTS (SELECT 1 FROM suppression s
           WHERE s.tenant_id = :t1 AND s.canal = 'whatsapp' AND s.valor_norm = '5511970000001'
             AND s.contact_id IS NULL));
SELECT bl.confere('mas a PESSOA não é suprimida — não foi vontade dela',
  NOT EXISTS (SELECT 1 FROM suppression s JOIN bl.gente g ON g.contato = s.contact_id
               WHERE g.n = 1));
SELECT bl.confere('o e-mail dela continua recebendo',
  NOT privado.esta_suprimido(:t1, (SELECT contato FROM bl.gente WHERE n = 1),
                             'email', 'um@livre.com.br'));
SELECT bl.confere('o CRM ouve identidade_invalida, e não opt_out',
  (SELECT count(*) FILTER (WHERE fato = 'identidade_invalida') = 1
          AND count(*) FILTER (WHERE fato = 'opt_out') = 0
     FROM outbox o JOIN bl.gente g ON g.contato = o.contact_id WHERE g.n = 1));

-- ---- recusa escolhida pelo cliente ----------------------------------------
INSERT INTO bl.gente (n, contato) VALUES (2, bl.pessoa(2, 'dois@livre.com.br'));
UPDATE bl.gente SET msg = bl.toque(contato) WHERE n = 2;
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
SELECT :t1, msg, 'respondido', '{"texto":"nao preciso"}'::jsonb FROM bl.gente WHERE n = 2;

SELECT bl.confere('recusa: ninguém é suprimido',
  NOT EXISTS (SELECT 1 FROM suppression s JOIN bl.gente g ON g.contato = s.contact_id WHERE g.n = 2));
SELECT bl.confere('recusa: o card fica em respondeu, não vira oportunidade',
  (SELECT s.slug = 'respondeu' FROM deals d JOIN pipeline_stages s ON s.id = d.stage_id
     JOIN bl.gente g ON g.contato = d.contact_id WHERE g.n = 2),
  (SELECT s.slug FROM deals d JOIN pipeline_stages s ON s.id = d.stage_id
     JOIN bl.gente g ON g.contato = d.contact_id WHERE g.n = 2));

-- ---- suprimir: a recusa no padrão (D63) -----------------------------------
INSERT INTO bl.gente (n, contato) VALUES (3, bl.pessoa(3, 'tres@livre.com.br'));
UPDATE bl.gente SET msg = bl.toque(contato) WHERE n = 3;
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
SELECT :t1, msg, 'respondido', '{"texto":"Sem interesse."}'::jsonb FROM bl.gente WHERE n = 3;

SELECT bl.confere('"sem interesse" suprime a pessoa inteira',
  EXISTS (SELECT 1 FROM suppression s JOIN bl.gente g ON g.contato = s.contact_id
           WHERE g.n = 3 AND s.canal IS NULL AND s.motivo LIKE '%termo: sem interesse%'),
  (SELECT string_agg(motivo, ' | ') FROM suppression s JOIN bl.gente g ON g.contato = s.contact_id
    WHERE g.n = 3));
SELECT bl.confere('e o CRM ouve opt_out',
  (SELECT count(*) = 1 FROM outbox o JOIN bl.gente g ON g.contato = o.contact_id
    WHERE g.n = 3 AND o.fato = 'opt_out'));

-- ---- quem não casa nada continua sendo oportunidade -----------------------
INSERT INTO bl.gente (n, contato) VALUES (4, bl.pessoa(4, 'quatro@livre.com.br'));
UPDATE bl.gente SET msg = bl.toque(contato) WHERE n = 4;
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
SELECT :t1, msg, 'respondido', '{"texto":"quero saber os valores"}'::jsonb FROM bl.gente WHERE n = 4;
SELECT bl.confere('quem não casa nada vira oportunidade e não é suprimido',
  (SELECT s.slug = 'oportunidade' FROM deals d JOIN pipeline_stages s ON s.id = d.stage_id
     JOIN bl.gente g ON g.contato = d.contact_id WHERE g.n = 4)
  AND NOT EXISTS (SELECT 1 FROM suppression s JOIN bl.gente g ON g.contato = s.contact_id WHERE g.n = 4));

-- ===========================================================================
-- 5. Domínio bloqueado: na pergunta que todo caminho já faz
-- ===========================================================================

SELECT bl.confere('o domínio bloqueado está suprimido',
  privado.esta_suprimido(:t1, NULL, 'email', 'fulano@concorrente.com.br'));
SELECT bl.confere('o subdomínio também',
  privado.esta_suprimido(:t1, NULL, 'email', 'fulano@mail.concorrente.com.br'));
SELECT bl.confere('mas não um domínio que só termina igual',
  NOT privado.esta_suprimido(:t1, NULL, 'email', 'fulano@naoconcorrente.com.br'));
SELECT bl.confere('nem no cliente vizinho',
  NOT privado.esta_suprimido(:t2, NULL, 'email', 'fulano@concorrente.com.br'));
SELECT bl.confere('nem num canal que não é e-mail',
  NOT privado.esta_suprimido(:t1, NULL, 'whatsapp', 'fulano@concorrente.com.br'));

-- No agendador: duas pessoas na campanha de e-mail, uma de cada domínio. A
-- livre é a linha de base — sem ela, "não criou mensagem" passaria até com o
-- agendador parado.
INSERT INTO bl.gente (n, contato) VALUES
  (5, bl.pessoa(5, 'cinco@concorrente.com.br')),
  (6, bl.pessoa(6, 'seis@livre.com.br'));
INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id, next_run_at)
SELECT :t1, contato, 'b1000000-0000-0000-0000-0000000000c2', 'b1000000-0000-0000-0000-0000000000f9',
       now() - interval '1 minute'
  FROM bl.gente WHERE n IN (5, 6);
CREATE TABLE bl.passada AS SELECT * FROM processar_vencidos(100, 'real');

SELECT bl.confere('linha de base: o e-mail livre virou mensagem',
  EXISTS (SELECT 1 FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
            JOIN bl.gente g ON g.contato = e.contact_id WHERE g.n = 6 AND m.canal = 'email'));
SELECT bl.confere('o e-mail do domínio bloqueado não virou mensagem',
  NOT EXISTS (SELECT 1 FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
                JOIN bl.gente g ON g.contato = e.contact_id WHERE g.n = 5 AND m.canal = 'email'));
SELECT bl.confere('e o agendador disse por quê',
  EXISTS (SELECT 1 FROM bl.passada p JOIN enrollments e ON e.id = p.enrollment_id
            JOIN bl.gente g ON g.contato = e.contact_id
           WHERE g.n = 5 AND p.acao = 'passo_pulado_identidade_suprimida'),
  (SELECT string_agg(p.acao, ', ') FROM bl.passada p JOIN enrollments e ON e.id = p.enrollment_id
     JOIN bl.gente g ON g.contato = e.contact_id WHERE g.n = 5));

-- No despacho: a mensagem de quem estava livre já está na fila; o domínio
-- dela entra na blacklist DEPOIS. A janela do D39, agora pelo domínio.
INSERT INTO blacklist_dominios (tenant_id, dominio) VALUES (:t1, 'livre.com.br');
CREATE TABLE bl.despacho AS SELECT * FROM reivindicar_pendentes(100);
SELECT bl.confere('o domínio bloqueado depois de criada a mensagem também barra o despacho',
  NOT EXISTS (SELECT 1 FROM bl.despacho d JOIN messages m ON m.id = d.message_id
                JOIN enrollments e ON e.id = m.enrollment_id
                JOIN bl.gente g ON g.contato = e.contact_id WHERE g.n = 6));
SELECT bl.confere('e a mensagem vira cancelada, não falha (D39)',
  (SELECT m.status = 'cancelado' FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
     JOIN bl.gente g ON g.contato = e.contact_id WHERE g.n = 6 AND m.canal = 'email'),
  (SELECT m.status::text FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
     JOIN bl.gente g ON g.contato = e.contact_id WHERE g.n = 6 AND m.canal = 'email'));

UPDATE blacklist_dominios SET ativo = false WHERE tenant_id = :t1 AND dominio = 'concorrente.com.br';
SELECT bl.confere('domínio desligado deixa de bloquear',
  NOT privado.esta_suprimido(:t1, NULL, 'email', 'fulano@concorrente.com.br'));

-- ===========================================================================
-- 6. A superfície: quem lê, quem escreve, e o quê
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"b1000000-0000-0000-0000-0000000000a2"}';
  SELECT bl.confere('o operador lê a blacklist do cliente',
    (SELECT count(*) > 20 FROM blacklist_termos));
  SELECT bl.confere('e não enxerga a do vizinho',
    NOT EXISTS (SELECT 1 FROM blacklist_termos WHERE termo = 'abacaxi'));
  SELECT bl.recusa('o operador não escreve na blacklist', '42501',
    'INSERT INTO blacklist_termos (tenant_id, termo, acao)
     VALUES (''b1000000-0000-0000-0000-0000000000a0'', ''nunca mais'', ''suprimir'')');
  SELECT bl.recusa('nem bloqueia domínio', '42501',
    'INSERT INTO blacklist_dominios (tenant_id, dominio)
     VALUES (''b1000000-0000-0000-0000-0000000000a0'', ''x.com.br'')');
  SELECT bl.confere('o operador testa uma frase pelo classificador de verdade',
    (SELECT acao = 'suprimir' AND termo = 'pare'
       FROM testar_blacklist('b1000000-0000-0000-0000-0000000000a0', 'PARE!')));
  SELECT bl.recusa('mas não na lista do vizinho', '42501',
    'SELECT * FROM testar_blacklist(''b2000000-0000-0000-0000-0000000000a0'', ''pare'')');
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"b1000000-0000-0000-0000-0000000000a1"}';
  SELECT bl.aceita('o admin acrescenta um termo pela tela',
    'INSERT INTO blacklist_termos (tenant_id, termo, acao, nota)
     VALUES (''b1000000-0000-0000-0000-0000000000a0'', ''Nunca mais'', ''suprimir'', ''pela tela'')');
  SELECT bl.aceita('troca a ação de um termo',
    'UPDATE blacklist_termos SET acao = ''recusa'' WHERE termo = ''nao obrigado''');
  SELECT bl.recusa('mas não reescreve a origem', '42501',
    'UPDATE blacklist_termos SET origem = ''cliente'' WHERE termo = ''pare''');
  SELECT bl.recusa('nem muda a linha de dono', '42501',
    'UPDATE blacklist_termos SET tenant_id = ''b2000000-0000-0000-0000-0000000000a0'' WHERE termo = ''pare''');
  SELECT bl.recusa('nem grava na lista do vizinho', '42501',
    'INSERT INTO blacklist_termos (tenant_id, termo, acao)
     VALUES (''b2000000-0000-0000-0000-0000000000a0'', ''intruso'', ''suprimir'')');
  SELECT bl.aceita('apaga um termo',
    'DELETE FROM blacklist_termos WHERE termo = ''nunca mais''');
  SELECT bl.aceita('bloqueia um domínio',
    'INSERT INTO blacklist_dominios (tenant_id, dominio)
     VALUES (''b1000000-0000-0000-0000-0000000000a0'', ''@Spam.com.br'')');
  SELECT bl.recusa('mas não reescreve o domínio bloqueado — apaga e cria outro', '42501',
    'UPDATE blacklist_dominios SET dominio = ''outro.com.br'' WHERE dominio = ''spam.com.br''');
COMMIT;

SELECT bl.confere('a escrita do admin chegou ao banco, normalizada',
  EXISTS (SELECT 1 FROM blacklist_dominios WHERE tenant_id = :t1 AND dominio = 'spam.com.br')
  AND (SELECT acao = 'recusa' FROM blacklist_termos WHERE tenant_id = :t1 AND termo = 'nao obrigado'));
SELECT bl.confere('e nada vazou para o vizinho',
  NOT EXISTS (SELECT 1 FROM blacklist_termos WHERE tenant_id = :t2 AND termo = 'intruso'));

BEGIN;
  SET LOCAL role anon;
  SELECT bl.recusa('anon não testa frase nenhuma', '42501',
    'SELECT * FROM testar_blacklist(''b1000000-0000-0000-0000-0000000000a0'', ''pare'')');
  -- O harness concede SELECT de toda tabela a anon, como o Supabase faz por
  -- padrão; quem segura é o RLS, e a pergunta certa é o que ele ENXERGA.
  SELECT bl.confere('nem enxerga linha nenhuma da lista',
    (SELECT count(*) = 0 FROM blacklist_termos) AND (SELECT count(*) = 0 FROM blacklist_dominios));
COMMIT;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM bl.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM bl.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM bl.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'blacklist: % asserção(ões) falharam', n; END IF;
END;
$$;
