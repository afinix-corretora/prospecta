-- O CRM recebe o fato (D64).
--
-- O que este arquivo sustenta, em ordem de quanto custaria errar:
--
--   1. sem plataforma que saiba receber, o fato ESPERA — não é reivindicado,
--      não gasta tentativa, não morre em `falha`;
--   2. o plano escreve no card DESTA pessoa, no pipe dele, e nunca adivinha
--      card: sem vínculo, a resposta é "nada" com o motivo dito;
--   3. mover vem antes de preencher, seja qual for a ordem digitada;
--   4. card vira contato, vínculo e inscrição de uma vez, e a inscrição passa
--      pela prévia: quem não tem canal NÃO é inscrito em silêncio (D35);
--   5. a grade: a tela escreve ação e fonte, nunca vínculo, estrutura nem o
--      resultado da execução.
--
-- Cada asserção que pergunta "não aconteceu" tem ao lado a linha de base em
-- que acontece (D36).

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA cp;
CREATE TABLE cp.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA cp TO authenticated;
GRANT INSERT, SELECT ON cp.resultado TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA cp TO authenticated;

CREATE FUNCTION cp.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO cp.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION cp.confere(text, boolean, text) TO authenticated;

CREATE FUNCTION cp.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE;
END; $$;
GRANT EXECUTE ON FUNCTION cp.sqlstate_de(text) TO authenticated;

CREATE FUNCTION cp.recusa(p_nome text, p_sqlstate text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := cp.sqlstate_de(p_sql);
  PERFORM cp.confere(p_nome, v = p_sqlstate, 'SQLSTATE ' || v);
END; $$;
GRANT EXECUTE ON FUNCTION cp.recusa(text, text, text) TO authenticated;

CREATE FUNCTION cp.aceita(p_nome text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := cp.sqlstate_de(p_sql);
  PERFORM cp.confere(p_nome, v = 'sem erro', v);
END; $$;
GRANT EXECUTE ON FUNCTION cp.aceita(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Um cliente com Pipefy, outro sem plataforma nenhuma
-- ---------------------------------------------------------------------------

\set tenant '\'cb000000-0000-0000-0000-0000000000a0\''
\set admin  '\'cb000000-0000-0000-0000-0000000000a1\''
\set oper   '\'cb000000-0000-0000-0000-0000000000a2\''
\set outro  '\'cb000000-0000-0000-0000-0000000000b0\''
\set oadmin '\'cb000000-0000-0000-0000-0000000000b1\''
\set conx   '\'cb000000-0000-0000-0000-0000000000c0\''
\set camp   '\'cb000000-0000-0000-0000-0000000000c1\''
\set semflow '\'cb000000-0000-0000-0000-0000000000c2\''
\set versao '\'cb000000-0000-0000-0000-0000000000f2\''
\set passo  '\'cb000000-0000-0000-0000-0000000000f3\''
\set chip   '\'cb000000-0000-0000-0000-0000000000e1\''
\set marina '\'cb000000-0000-0000-0000-0000000000d1\''
\set semcard '\'cb000000-0000-0000-0000-0000000000d2\''
\set fonte  '\'cb000000-0000-0000-0000-0000000000f0\''

INSERT INTO tenants (id, nome, slug) VALUES
  (:tenant, 'Corretora Pipe', 'corretora-pipe'),
  (:outro,  'Corretora Sem CRM', 'corretora-sem-crm');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:tenant, :admin,  'admin'),
  (:tenant, :oper,   'operador'),
  (:outro,  :oadmin, 'admin');

INSERT INTO crm_connections (id, tenant_id, nome, provedor, config)
VALUES (:conx, :tenant, 'Pipefy', 'pipefy', '{"client_id":"abc"}');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados) VALUES
  (:camp,    :tenant, 'Resgate', 'morna', 'opt-in', '{whatsapp}'),
  (:semflow, :tenant, 'Sem cadência', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO flows (id, tenant_id, nome) VALUES ('cb000000-0000-0000-0000-0000000000f1', :tenant, 'F');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
VALUES (:versao, :tenant, 'cb000000-0000-0000-0000-0000000000f1', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:passo, :tenant, :versao, 1, 'whatsapp', 0, 'Oi {{nome}}');
UPDATE campaigns SET flow_version_id = :versao WHERE id = :camp;

INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria)
VALUES (:chip, :tenant, 'whatsapp', 'uazapi', '5511990002222', 'Chip', 'morna', 100);

INSERT INTO contacts (id, tenant_id, nome, origem, metadados) VALUES
  (:marina,  :tenant, 'Marina Souza', 'crm:pipefy', '{"plano":"Bradesco"}'),
  (:semcard, :tenant, 'Sem Card',     'planilha',   '{}');
INSERT INTO contact_identities (id, tenant_id, contact_id, canal, valor, valor_norm, origem) VALUES
  ('cb000000-0000-0000-0000-00000000a001', :tenant, :marina,
   'whatsapp', '+55 11 97000-0101', '5511970000101', 'crm:pipefy'),
  ('cb000000-0000-0000-0000-00000000a002', :tenant, :semcard,
   'whatsapp', '+55 11 97000-0102', '5511970000102', 'planilha');

-- O card da Marina é o 900 no pipe P1.
INSERT INTO crm_vinculos (tenant_id, conexao_id, contact_id, pipe_id, ref_externa)
VALUES (:tenant, :conx, :marina, 'P1', '900');

-- ===========================================================================
-- 1. Sem destino que saiba receber, o fato espera
-- ===========================================================================

-- O fato nasce pelo caminho de verdade: Marina responde, a invariante 4
-- encerra, o gatilho do D45 enfileira `respondido`.
INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id) VALUES
  ('cb000000-0000-0000-0000-0000000000b1', :tenant, :marina,  :camp, :versao),
  ('cb000000-0000-0000-0000-0000000000b2', :tenant, :semcard, :camp, :versao);
INSERT INTO messages (id, tenant_id, enrollment_id, step_id, contact_identity_id,
                      sender_account_id, canal, status, conteudo) VALUES
  ('cb000000-0000-0000-0000-00000000aa01', :tenant, 'cb000000-0000-0000-0000-0000000000b1',
   :passo, 'cb000000-0000-0000-0000-00000000a001', :chip, 'whatsapp', 'enviado', 'Oi Marina'),
  ('cb000000-0000-0000-0000-00000000aa02', :tenant, 'cb000000-0000-0000-0000-0000000000b2',
   :passo, 'cb000000-0000-0000-0000-00000000a002', :chip, 'whatsapp', 'enviado', 'Oi');
INSERT INTO message_events (tenant_id, message_id, tipo, payload) VALUES
  (:tenant, 'cb000000-0000-0000-0000-00000000aa01', 'respondido',
   '{"texto":"Quero sim, me liga amanha"}'::jsonb),
  (:tenant, 'cb000000-0000-0000-0000-00000000aa02', 'respondido',
   '{"texto":"pode mandar a tabela"}'::jsonb);

-- O outro cliente também tem um fato, e nenhuma plataforma.
INSERT INTO contacts (id, tenant_id, nome, origem)
VALUES ('cb000000-0000-0000-0000-0000000000d9', :outro, 'Do Outro', 'planilha');
INSERT INTO outbox (tenant_id, contact_id, destino, fato)
VALUES (:outro, 'cb000000-0000-0000-0000-0000000000d9', 'crm', 'respondido');

SELECT cp.confere('o cenário tem os fatos: dois do cliente com Pipefy, um do outro',
  (SELECT count(*) FROM outbox WHERE tenant_id = :tenant AND fato = 'respondido') = 2
  AND (SELECT count(*) FROM outbox WHERE tenant_id = :outro) = 1,
  (SELECT count(*)::text FROM outbox));

-- Pipefy no catálogo sem adapter (o estado entre a migration das tabelas e a
-- que liga o adapter, D31): ninguém sai, nem de quem tem conexão.
UPDATE crm_provider_catalog SET tem_adapter = false WHERE slug = 'pipefy';
CREATE TABLE cp.lote AS SELECT * FROM reivindicar_writebacks(50);
SELECT cp.confere('provedor sem adapter: nenhum fato é reivindicado',
  (SELECT count(*) FROM cp.lote) = 0, (SELECT count(*)::text FROM cp.lote));
UPDATE outbox SET reivindicada_em = NULL;

-- Com adapter: sai quem tem conexão, e só quem tem.
UPDATE crm_provider_catalog SET tem_adapter = true WHERE slug = 'pipefy';
DROP TABLE cp.lote;
CREATE TABLE cp.lote AS SELECT * FROM reivindicar_writebacks(50);
SELECT cp.confere('linha de base: com adapter, os fatos do cliente com Pipefy saem',
  (SELECT count(*) FROM cp.lote WHERE tenant_id = :tenant) = 2,
  (SELECT count(*)::text FROM cp.lote WHERE tenant_id = :tenant));
SELECT cp.confere('o fato de quem não tem plataforma fica onde está',
  NOT EXISTS (SELECT 1 FROM cp.lote WHERE tenant_id = :outro));
SELECT cp.confere('e sem gastar tentativa nem lease',
  (SELECT tentativas = 0 AND reivindicada_em IS NULL AND status = 'pendente'
     FROM outbox WHERE tenant_id = :outro));
UPDATE outbox SET reivindicada_em = NULL;

-- Conexão desligada pela tela: volta a esperar.
UPDATE crm_connections SET ativo = false WHERE id = :conx;
DROP TABLE cp.lote;
CREATE TABLE cp.lote AS SELECT * FROM reivindicar_writebacks(50);
SELECT cp.confere('conexão desligada: o fato espera de novo',
  (SELECT count(*) FROM cp.lote) = 0, (SELECT count(*)::text FROM cp.lote));
UPDATE crm_connections SET ativo = true WHERE id = :conx;
UPDATE outbox SET reivindicada_em = NULL;

-- ===========================================================================
-- 2. O plano
-- ===========================================================================

-- Sem ação nenhuma configurada: "nada", com o motivo.
CREATE TABLE cp.plano AS
  SELECT p.* FROM outbox o, plano_de_writeback(o.id) p
   WHERE o.tenant_id = :tenant AND o.contact_id = :marina;
SELECT cp.confere('card vinculado sem ação: uma linha "nada" que diz por quê',
  (SELECT count(*) = 1 AND bool_and(tipo = 'nada' AND motivo LIKE 'nenhuma ação configurada%')
     FROM cp.plano),
  (SELECT string_agg(tipo || ':' || coalesce(motivo,''), ' | ') FROM cp.plano));

-- As ações, digitadas na ordem ERRADA: o preenchimento com ordem menor que a
-- mudança de fase. Outra ação de outro pipe e uma desligada, para a asserção
-- poder ver o que não deveria entrar.
INSERT INTO crm_acoes (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id, valor, ordem, ativo) VALUES
  (:tenant, :conx, 'P1', 'respondido', 'preencher_campo', 'status_sdr',
   'Respondeu em {{data}}: {{resposta}} ({{nome}}, {{plano}})', 1, true),
  (:tenant, :conx, 'P1', 'respondido', 'mover_fase', 'F_CONVERSA', NULL, 5, true),
  (:tenant, :conx, 'P1', 'respondido', 'preencher_campo', 'campo_desligado', 'x', 2, false),
  (:tenant, :conx, 'P2', 'respondido', 'mover_fase', 'F_DE_OUTRO_PIPE', NULL, 0, true),
  (:tenant, :conx, 'P1', 'opt_out', 'mover_fase', 'F_PERDIDO', NULL, 0, true);

DROP TABLE cp.plano;
CREATE TABLE cp.plano AS
  SELECT row_number() OVER () AS n, p.* FROM outbox o, plano_de_writeback(o.id) p
   WHERE o.tenant_id = :tenant AND o.contact_id = :marina;

SELECT cp.confere('o plano tem as duas ações do pipe e do fato, e só elas',
  (SELECT count(*) FROM cp.plano) = 2,
  (SELECT string_agg(tipo || ':' || alvo_id, ' | ' ORDER BY n) FROM cp.plano));
SELECT cp.confere('mover vem primeiro, mesmo digitado com ordem maior',
  (SELECT tipo = 'mover_fase' AND alvo_id = 'F_CONVERSA' FROM cp.plano WHERE n = 1));
SELECT cp.confere('no card desta pessoa',
  (SELECT bool_and(ref_externa = '900' AND conexao_id = :conx::uuid AND provedor = 'pipefy') FROM cp.plano));
SELECT cp.confere('o valor sai renderizado: resposta, nome e metadado da fonte',
  (SELECT valor LIKE 'Respondeu em __/__/____ __:__: Quero sim, me liga amanha (Marina Souza, Bradesco)'
     FROM cp.plano WHERE n = 2),
  (SELECT valor FROM cp.plano WHERE n = 2));

-- Quem não tem card não ganha card adivinhado.
DROP TABLE cp.plano;
CREATE TABLE cp.plano AS
  SELECT p.* FROM outbox o, plano_de_writeback(o.id) p
   WHERE o.tenant_id = :tenant AND o.contact_id = :semcard;
SELECT cp.confere('sem vínculo: "nada", e o motivo é a falta de card',
  (SELECT count(*) = 1 AND bool_and(tipo = 'nada' AND motivo = 'contato sem card vinculado nesta plataforma')
     FROM cp.plano),
  (SELECT string_agg(tipo || ':' || coalesce(motivo,''), ' | ') FROM cp.plano));

-- O resultado fica anotado ao lado do status.
DO $$
DECLARE v uuid;
BEGIN
  SELECT id INTO v FROM outbox WHERE contact_id = 'cb000000-0000-0000-0000-0000000000d2';
  PERFORM anotar_resultado_writeback(v, 'contato sem card vinculado nesta plataforma');
  PERFORM registrar_resultado_writeback(v, true, NULL);
  PERFORM cp.confere('o que o dreno fez fica escrito em resultado',
    (SELECT status = 'enviado' AND resultado = 'contato sem card vinculado nesta plataforma'
       FROM outbox WHERE id = v));
END $$;

-- ===========================================================================
-- 3. Card vira contato, vínculo e inscrição
-- ===========================================================================

INSERT INTO crm_fontes (id, tenant_id, conexao_id, nome, pipe_id, fases, mapa, campaign_id)
VALUES (:fonte, :tenant, :conx, 'Leads do pipe', 'P1', '{F_NOVO}',
        '{"titulo":"nome","telefone":"telefone","email":"email"}', :camp);

-- Card novo com celular: entra, liga e inscreve.
CREATE TABLE cp.ing AS SELECT * FROM ingerir_do_crm(:fonte, '1001',
  '[{"canal":"whatsapp","valor":"11 97000-0201","valor_norm":"5511970000201"}]', 'Paulo Card', '{"plano":"Amil"}');
SELECT cp.confere('card novo vira contato criado e inscrito',
  (SELECT acao = 'criado' AND inscricao = 'inscrito' FROM cp.ing),
  (SELECT acao || '/' || inscricao FROM cp.ing));
SELECT cp.confere('com vínculo no pipe da fonte',
  EXISTS (SELECT 1 FROM crm_vinculos v JOIN cp.ing i ON i.contact_id = v.contact_id
           WHERE v.ref_externa = '1001' AND v.pipe_id = 'P1'));
SELECT cp.confere('e enrollment ativo na campanha da fonte',
  EXISTS (SELECT 1 FROM enrollments e JOIN cp.ing i ON i.contact_id = e.contact_id
           WHERE e.campaign_id = :camp::uuid AND e.status = 'ativo'));
SELECT cp.confere('a origem diz de que plataforma veio',
  (SELECT c.origem = 'crm:pipefy' AND c.origem_ref = '1001' FROM contacts c JOIN cp.ing i ON i.contact_id = c.id));

-- O mesmo card de novo: não duplica nada.
DROP TABLE cp.ing;
CREATE TABLE cp.ing AS SELECT * FROM ingerir_do_crm(:fonte, '1001',
  '[{"canal":"whatsapp","valor":"11 97000-0201","valor_norm":"5511970000201"}]', 'Paulo Card', '{}');
SELECT cp.confere('o mesmo card de novo: atualizado e já inscrito, nada em dobro',
  (SELECT acao = 'atualizado' AND inscricao = 'ja_inscrito' FROM cp.ing)
  AND (SELECT count(*) FROM crm_vinculos WHERE ref_externa = '1001') = 1,
  (SELECT acao || '/' || inscricao FROM cp.ing));

-- Card só com e-mail numa campanha de WhatsApp: entra, liga, e NÃO inscreve.
-- Linha de base é o Paulo acima, inscrito pela mesma fonte.
DROP TABLE cp.ing;
CREATE TABLE cp.ing AS SELECT * FROM ingerir_do_crm(:fonte, '1002',
  '[{"canal":"email","valor":"so@email.com","valor_norm":"so@email.com"}]', 'So Email', '{}');
SELECT cp.confere('sem canal da cadência: a inscrição é recusada e dita (D35)',
  (SELECT acao = 'criado' AND inscricao = 'sem_canal' FROM cp.ing),
  (SELECT acao || '/' || inscricao FROM cp.ing));
SELECT cp.confere('e nenhum enrollment nasceu para quem encerraria vazio',
  NOT EXISTS (SELECT 1 FROM enrollments e JOIN cp.ing i ON i.contact_id = e.contact_id));
SELECT cp.confere('mas o vínculo existe: o fato dele ainda tem para onde voltar',
  EXISTS (SELECT 1 FROM crm_vinculos WHERE ref_externa = '1002'));

-- Card de quem pediu para sair: entra, e não é inscrito.
INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
VALUES (:tenant, 'whatsapp', '5511970000301', 'pediu para sair');
DROP TABLE cp.ing;
CREATE TABLE cp.ing AS SELECT * FROM ingerir_do_crm(:fonte, '1003',
  '[{"canal":"whatsapp","valor":"11 97000-0301","valor_norm":"5511970000301"}]', 'Saiu', '{}');
-- A supressão aqui é do NÚMERO, não da pessoa: a prévia vê um contato cujo
-- único canal está suprimido, e responde `sem_canal`. É a resposta certa — e
-- é a mesma que impede o enrollment vazio.
SELECT cp.confere('número suprimido: sem canal alcançável, não é inscrito',
  (SELECT inscricao FROM cp.ing) = 'sem_canal',
  (SELECT inscricao FROM cp.ing));
SELECT cp.confere('e nenhum enrollment para ele',
  NOT EXISTS (SELECT 1 FROM enrollments e JOIN cp.ing i ON i.contact_id = e.contact_id));

-- Card ligado a outra pessoa: as identidades no CRM mudaram e casaram com
-- outro contato. Recusa alta, sem religar.
SELECT cp.recusa('card já ligado a outro contato é recusado, não religado', '23001',
  $q$SELECT * FROM ingerir_do_crm('cb000000-0000-0000-0000-0000000000f0', '900',
     '[{"canal":"whatsapp","valor":"11 97000-0201","valor_norm":"5511970000201"}]')$q$);
SELECT cp.confere('o card 900 continua da Marina',
  (SELECT contact_id FROM crm_vinculos WHERE ref_externa = '900') = :marina::uuid);

-- Fonte apontando campanha sem cadência: importa, e diz que não inscreveu.
UPDATE crm_fontes SET campaign_id = :semflow WHERE id = :fonte;
DROP TABLE cp.ing;
CREATE TABLE cp.ing AS SELECT * FROM ingerir_do_crm(:fonte, '1004',
  '[{"canal":"whatsapp","valor":"11 97000-0401","valor_norm":"5511970000401"}]', 'Sem Cad', '{}');
SELECT cp.confere('campanha sem cadência: importa e diz que não inscreveu',
  (SELECT acao = 'criado' AND inscricao = 'campanha_sem_cadencia' FROM cp.ing),
  (SELECT acao || '/' || inscricao FROM cp.ing));
UPDATE crm_fontes SET campaign_id = NULL WHERE id = :fonte;
DROP TABLE cp.ing;
CREATE TABLE cp.ing AS SELECT * FROM ingerir_do_crm(:fonte, '1005',
  '[{"canal":"whatsapp","valor":"11 97000-0501","valor_norm":"5511970000501"}]', 'Sem Camp', '{}');
SELECT cp.confere('fonte sem campanha: só importa',
  (SELECT inscricao FROM cp.ing) = 'sem_campanha', (SELECT inscricao FROM cp.ing));

-- O worker pula o que já conhece.
SELECT cp.confere('refs_vinculadas lista os cards já ligados da conexão',
  (SELECT array_agg(r ORDER BY r) FROM refs_vinculadas(:conx) r)
    = ARRAY['1001','1002','1003','1004','1005','900'],
  (SELECT array_agg(r ORDER BY r)::text FROM refs_vinculadas(:conx) r));

-- ===========================================================================
-- 4. A fonte tem cadência própria, e a descoberta falha sem apagar
-- ===========================================================================

SELECT cp.confere('fonte nunca lida está vencida',
  EXISTS (SELECT 1 FROM fontes_crm_vencidas() WHERE fonte_id = :fonte));
SELECT registrar_execucao_fonte(:fonte, '{"lidos":5}');
SELECT cp.confere('lida agora, sai da lista até o intervalo passar',
  NOT EXISTS (SELECT 1 FROM fontes_crm_vencidas() WHERE fonte_id = :fonte));
UPDATE crm_fontes SET ultima_execucao = now() - interval '16 minutes' WHERE id = :fonte;
SELECT cp.confere('passado o intervalo, volta',
  EXISTS (SELECT 1 FROM fontes_crm_vencidas() WHERE fonte_id = :fonte));
UPDATE crm_provider_catalog SET tem_adapter = false WHERE slug = 'pipefy';
SELECT cp.confere('provedor sem adapter: nenhuma fonte é lida',
  NOT EXISTS (SELECT 1 FROM fontes_crm_vencidas()));
UPDATE crm_provider_catalog SET tem_adapter = true WHERE slug = 'pipefy';

SELECT registrar_estrutura_crm(:conx, '{"pipes":[{"id":"P1","nome":"Vendas"}]}', NULL);
SELECT registrar_estrutura_crm(:conx, NULL, 'credencial recusada');
SELECT cp.confere('descoberta que falha guarda o erro e mantém a estrutura de antes',
  (SELECT erro = 'credencial recusada' AND estrutura -> 'pipes' -> 0 ->> 'id' = 'P1'
     FROM crm_estruturas WHERE conexao_id = :conx));

-- ===========================================================================
-- 5. A grade
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"cb000000-0000-0000-0000-0000000000a1"}';

  SELECT cp.aceita('o admin configura ação pela tela',
    $q$INSERT INTO crm_acoes (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id, valor)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'P1', 'campanha_concluida', 'preencher_campo', 'obs', 'Cadência concluída')$q$);
  SELECT cp.recusa('duas fases de destino para o mesmo fato e pipe', '23505',
    $q$INSERT INTO crm_acoes (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'P1', 'respondido', 'mover_fase', 'F_OUTRA')$q$);
  SELECT cp.recusa('preencher sem valor não existe', '23514',
    $q$INSERT INTO crm_acoes (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'P1', 'opt_out', 'preencher_campo', 'obs')$q$);
  SELECT cp.aceita('o admin cria fonte pela tela',
    $q$INSERT INTO crm_fontes (tenant_id, conexao_id, nome, pipe_id, fases, mapa)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'Outra', 'P1', '{F1}', '{"cel":"whatsapp"}')$q$);
  SELECT cp.recusa('papel que a leitura não conhece é recusado', '23514',
    $q$INSERT INTO crm_fontes (tenant_id, conexao_id, nome, pipe_id, fases, mapa)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'Ruim', 'P1', '{F1}', '{"cel":"whatsapp","x":"cpf"}')$q$);
  SELECT cp.recusa('fonte sem campo de identidade é recusada', '23514',
    $q$INSERT INTO crm_fontes (tenant_id, conexao_id, nome, pipe_id, fases, mapa)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'Sem id', 'P1', '{F1}', '{"titulo":"nome"}')$q$);
  SELECT cp.recusa('a tela não escreve o resultado da execução', '42501',
    $q$UPDATE crm_fontes SET ultimo_resultado = '{"lidos":999}'$q$);
  SELECT cp.recusa('a tela não escreve vínculo à mão', '42501',
    $q$INSERT INTO crm_vinculos (tenant_id, conexao_id, contact_id, pipe_id, ref_externa)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'cb000000-0000-0000-0000-0000000000d2', 'P1', '777')$q$);
  SELECT cp.recusa('a tela não escreve estrutura à mão', '42501',
    $q$UPDATE crm_estruturas SET estrutura = '{}'$q$);
  SELECT cp.recusa('o plano é do worker, não da tela', '42501',
    $q$SELECT * FROM plano_de_writeback(gen_random_uuid())$q$);
  SELECT cp.recusa('ingerir pela fonte também', '42501',
    $q$SELECT * FROM ingerir_do_crm(gen_random_uuid(), 'x', '[]')$q$);
  SELECT cp.confere('o admin lê os vínculos do cliente dele',
    (SELECT count(*) FROM crm_vinculos) >= 6);
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"cb000000-0000-0000-0000-0000000000a2"}';
  SELECT cp.recusa('o operador não configura o CRM', '42501',
    $q$INSERT INTO crm_acoes (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'P9', 'respondido', 'mover_fase', 'F')$q$);
  SELECT cp.confere('o operador lê vínculos (é dado do contato), não as ações',
    (SELECT count(*) FROM crm_vinculos) >= 6 AND (SELECT count(*) FROM crm_acoes) = 0);
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"cb000000-0000-0000-0000-0000000000b1"}';
  SELECT cp.confere('o admin de outro cliente não vê nada deste',
    (SELECT count(*) FROM crm_vinculos) = 0 AND (SELECT count(*) FROM crm_acoes) = 0
    AND (SELECT count(*) FROM crm_fontes) = 0 AND (SELECT count(*) FROM crm_estruturas) = 0);
  SELECT cp.recusa('nem escreve ação na conexão dele', '42501',
    $q$INSERT INTO crm_acoes (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id)
       VALUES ('cb000000-0000-0000-0000-0000000000a0', 'cb000000-0000-0000-0000-0000000000c0',
               'P9', 'respondido', 'mover_fase', 'F')$q$);
COMMIT;

-- A migration revoga de anon; o suite devolve SELECT de tudo a anon depois
-- das migrations (é o default privilege do Supabase, que lá vem ANTES). Então
-- aqui quem tem de segurar é o RLS: anon lê, e lê zero.
BEGIN;
  SET LOCAL role anon;
  SELECT (SELECT count(*) FROM crm_vinculos) + (SELECT count(*) FROM crm_acoes)
       + (SELECT count(*) FROM crm_fontes) + (SELECT count(*) FROM crm_estruturas) AS anon_ve
  \gset
COMMIT;
SELECT cp.confere('anon não vê nada das quatro', :anon_ve = 0, :anon_ve::text);

-- ===========================================================================

\echo ''
\echo '============= CRM: PIPEFY ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM cp.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM cp.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cp.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'crm pipefy: % asserções falharam',
      (SELECT count(*) FROM cp.resultado WHERE NOT ok);
  END IF;
END;
$$;
