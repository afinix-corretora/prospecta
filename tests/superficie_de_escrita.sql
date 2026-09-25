-- A tela liga e desliga — e só isso (D54).
--
-- Duas perguntas, e as duas precisam de resposta no mesmo arquivo:
--
--   1. o freio EXISTE para quem usa o produto? Um operador desliga a
--      campanha e pausa a inscrição, um admin tira o remetente do pool —
--      pelo papel real, com RLS ligado, sem função nova em `public` (D41);
--   2. o freio é a ÚNICA coisa que ele escreve? `UPDATE` de tabela inteira
--      com RLS por linha deixava o mesmo cliente zerar `enviados_na_janela`
--      e mandar o dobro da quota. A invariante 3 não seria furada pelo
--      motor: seria furada por fora dele.
--
-- E, o que é mais fácil de esquecer: o freio puxado precisa PARAR o motor.
-- Cada bloco roda `processar_vencidos` depois de escrever — asserção que só
-- relê a coluna prova que o UPDATE gravou, não que o agendador obedece.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA se;
CREATE TABLE se.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA se TO authenticated;
GRANT INSERT, SELECT ON se.resultado TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA se TO authenticated;

CREATE FUNCTION se.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO se.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION se.confere(text, boolean, text) TO authenticated;

-- Recusa com MOTIVO. "deu erro" também é o que um typo no nome da coluna dá:
-- 42501 é privilégio negado e 23514 é o CHECK, e são coisas diferentes. Roda
-- UMA vez e guarda o SQLSTATE, para o detalhe do relatório não ser uma
-- segunda execução com resultado possivelmente outro.
CREATE FUNCTION se.sqlstate_de(p_sql text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'sem erro';
EXCEPTION WHEN others THEN RETURN SQLSTATE;
END; $$;
GRANT EXECUTE ON FUNCTION se.sqlstate_de(text) TO authenticated;

CREATE FUNCTION se.recusa(p_nome text, p_sqlstate text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := se.sqlstate_de(p_sql);
  PERFORM se.confere(p_nome, v = p_sqlstate, 'SQLSTATE ' || v);
END; $$;
GRANT EXECUTE ON FUNCTION se.recusa(text, text, text) TO authenticated;

CREATE FUNCTION se.aceita(p_nome text, p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := se.sqlstate_de(p_sql);
  PERFORM se.confere(p_nome, v = 'sem erro', v);
END; $$;
GRANT EXECUTE ON FUNCTION se.aceita(text, text) TO authenticated;

-- O que o agendador fez com ESTE enrollment nesta passada. NULL = não pegou.
CREATE FUNCTION se.passada() RETURNS text
LANGUAGE sql AS $$
  SELECT acao FROM processar_vencidos(100, 'simulado')
   WHERE enrollment_id = '5e000000-0000-0000-0000-0000000000b1';
$$;

-- Uma passada, UMA vez, e o relatório com o que ela devolveu. Chamar
-- `se.passada()` duas vezes na mesma asserção (uma na condição, outra no
-- detalhe) rodaria o agendador duas vezes e andaria um passo a mais sem que
-- ninguém pedisse.
CREATE FUNCTION se.confere_passada(p_nome text, p_esperado text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := se.passada();
  PERFORM se.confere(p_nome, v IS NOT DISTINCT FROM p_esperado,
                     coalesce(v, '(não pegou o enrollment)'));
END; $$;

-- Vencer de novo, para a próxima passada ter o que pegar. É escrita de motor
-- (next_run_at), então roda como o dono do banco, nunca como `authenticated`
-- — é exatamente o privilégio que a migration tira da tela.
CREATE FUNCTION se.vencer() RETURNS void
LANGUAGE sql AS $$
  UPDATE enrollments SET next_run_at = now() - interval '1 minute'
   WHERE id = '5e000000-0000-0000-0000-0000000000b1';
$$;

-- ---------------------------------------------------------------------------
-- Um cliente, três papéis, uma cadência de verdade
-- ---------------------------------------------------------------------------

\set tenant  '\'5e000000-0000-0000-0000-0000000000a0\''
\set admin   '\'5e000000-0000-0000-0000-0000000000a1\''
\set oper    '\'5e000000-0000-0000-0000-0000000000a2\''
\set camp    '\'5e000000-0000-0000-0000-0000000000c1\''
\set versao  '\'5e000000-0000-0000-0000-0000000000f2\''
\set remet   '\'5e000000-0000-0000-0000-0000000000e1\''
\set insc    '\'5e000000-0000-0000-0000-0000000000b1\''

INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Freio', 'corretora-freio');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES
  (:tenant, :admin, 'admin'),
  (:tenant, :oper,  'operador');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados)
VALUES (:camp, :tenant, 'Freio', 'morna', 'opt-in', '{whatsapp}');

INSERT INTO flows (id, tenant_id, nome)
VALUES ('5e000000-0000-0000-0000-0000000000f1', :tenant, 'Freio');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
VALUES (:versao, :tenant, '5e000000-0000-0000-0000-0000000000f1', 1);
-- Seis passos: sobra cadência depois de cada sabotagem, então "não andou"
-- nunca se confunde com "acabou".
INSERT INTO flow_steps (tenant_id, flow_version_id, ordem, canal, atraso_horas, template) VALUES
  (:tenant, :versao, 1, 'whatsapp', 0, 'oi'),
  (:tenant, :versao, 2, 'whatsapp', 0, 'e ai'),
  (:tenant, :versao, 3, 'whatsapp', 0, 'ainda aqui'),
  (:tenant, :versao, 4, 'whatsapp', 0, 'quarto toque'),
  (:tenant, :versao, 5, 'whatsapp', 0, 'quinto toque'),
  (:tenant, :versao, 6, 'whatsapp', 0, 'ultimo');

INSERT INTO sender_accounts
  (id, tenant_id, canal, provedor, identificador, apelido, tipo_permitido, quota_diaria)
VALUES (:remet, :tenant, 'whatsapp', 'uazapi', '5511990000000', 'Chip do teste', 'morna', 50);

INSERT INTO contacts (id, tenant_id, nome, origem)
VALUES ('5e000000-0000-0000-0000-0000000000d1', :tenant, 'Contato do Freio', 'planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
VALUES (:tenant, '5e000000-0000-0000-0000-0000000000d1', 'whatsapp',
        '+55 11 97000-9001', '5511970009001', 'planilha');

-- Id fixo para o enrollment: as funções auxiliares acima o citam, e uuid
-- sorteado obrigaria a passá-lo por variável de sessão em cada bloco.
INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id, next_run_at)
VALUES (:insc, :tenant, '5e000000-0000-0000-0000-0000000000d1', :camp, :versao,
        now() - interval '1 minute');

-- Linha de base: sem freio nenhum, o agendador anda. Sem ela, tudo abaixo
-- passaria com o motor desligado — cenário que não consegue violar a
-- asserção não prova nada (D36).
SELECT se.confere_passada('linha de base: o agendador anda quando nada está freado',
                          'mensagem_criada');

-- ===========================================================================
-- 1. Campanha: o operador desliga, e o motor para
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"5e000000-0000-0000-0000-0000000000a2"}';
  SELECT se.aceita('operador desliga a campanha pela tela (sem função nova)',
    'UPDATE campaigns SET ativa = false WHERE id = ''5e000000-0000-0000-0000-0000000000c1''');
COMMIT;

SELECT se.confere('a campanha ficou desligada de fato',
  NOT (SELECT ativa FROM campaigns WHERE id = :camp));

SELECT se.vencer();
SELECT se.confere_passada('campanha desligada: o agendador ignora o enrollment',
                          'ignorado_campanha_inativa');

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"5e000000-0000-0000-0000-0000000000a2"}';
  SELECT se.aceita('e o operador liga de volta',
    'UPDATE campaigns SET ativa = true WHERE id = ''5e000000-0000-0000-0000-0000000000c1''');
COMMIT;

SELECT se.vencer();
SELECT se.confere_passada('religada: o passo seguinte anda', 'mensagem_criada');

-- ===========================================================================
-- 2. Enrollment: pausar e retomar
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"5e000000-0000-0000-0000-0000000000a2"}';
  SELECT se.aceita('operador pausa a inscrição',
    'UPDATE enrollments SET status = ''pausado'' WHERE id = ''5e000000-0000-0000-0000-0000000000b1''');
COMMIT;

SELECT se.vencer();
-- Diferente do caso da campanha: o lote do agendador já filtra por `ativo`,
-- então o enrollment pausado não aparece nem para ser ignorado.
SELECT se.confere_passada('pausado: o agendador nem olha para o enrollment', NULL);

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"5e000000-0000-0000-0000-0000000000a2"}';
  SELECT se.aceita('operador retoma a inscrição',
    'UPDATE enrollments SET status = ''ativo'' WHERE id = ''5e000000-0000-0000-0000-0000000000b1''');
COMMIT;

-- Sem `se.vencer()` de propósito: pausar não apaga o relógio, então retomar
-- volta para um horário que já era devido.
SELECT se.confere_passada('retomado: o relógio não se perdeu, a cadência continua',
                          'mensagem_criada');

-- ===========================================================================
-- 3. Remetente: quem tira do pool é o admin, e o pool obedece
-- ===========================================================================

SELECT se.confere('antes: o remetente está no pool',
  EXISTS (SELECT 1 FROM privado.remetentes_disponiveis(:tenant, 'whatsapp', 'morna')));

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"5e000000-0000-0000-0000-0000000000a2"}';
  -- Operador não administra remetente. Aqui não há erro: a política de RLS
  -- (pode_administrar) simplesmente não deixa a linha ser alcançada, e o
  -- UPDATE muda zero linhas. Por isso a asserção olha o EFEITO, não o erro.
  UPDATE sender_accounts SET estado = 'desativado'
   WHERE id = '5e000000-0000-0000-0000-0000000000e1';
COMMIT;

SELECT se.confere('o remetente do operador continua ativo',
  (SELECT estado FROM sender_accounts WHERE id = :remet) = 'ativo');

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"5e000000-0000-0000-0000-0000000000a1"}';
  SELECT se.aceita('admin tira o remetente do pool',
    'UPDATE sender_accounts SET estado = ''desativado'' WHERE id = ''5e000000-0000-0000-0000-0000000000e1''');
COMMIT;

SELECT se.confere('desativado: o pool deixa de oferecer a conta',
  NOT EXISTS (SELECT 1 FROM privado.remetentes_disponiveis(:tenant, 'whatsapp', 'morna')));

UPDATE sender_accounts SET estado = 'ativo' WHERE id = :remet;

-- ===========================================================================
-- 4. E nada além disso. Cada linha aqui é um buraco que existia.
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"5e000000-0000-0000-0000-0000000000a1"}';

  -- O buraco que mais importa: zerar a janela de quota é mandar o dobro.
  SELECT se.recusa('zerar enviados_na_janela é recusado por privilégio', '42501',
    'UPDATE sender_accounts SET enviados_na_janela = 0');
  SELECT se.recusa('mexer em health_score é recusado', '42501',
    'UPDATE sender_accounts SET health_score = 100');
  SELECT se.recusa('abrir ou fechar o circuito à mão é recusado', '42501',
    'UPDATE sender_accounts SET circuito_aberto_ate = NULL');
  SELECT se.recusa('adiantar a janela de quota é recusado', '42501',
    'UPDATE sender_accounts SET janela = current_date + 1');

  -- Escrever o relógio do agendador é escolher quando e o que disparar.
  SELECT se.recusa('escrever next_run_at é recusado', '42501',
    'UPDATE enrollments SET next_run_at = now()');
  SELECT se.recusa('escrever passo_atual é recusado', '42501',
    'UPDATE enrollments SET passo_atual = 0');

  -- D4: o tipo define o pool permitido. Trocá-lo é mudar o pool sem tocar em
  -- remetente nenhum — campanha fria passando a usar o chip institucional.
  SELECT se.recusa('trocar o tipo da campanha é recusado', '42501',
    'UPDATE campaigns SET tipo = ''fria''');
  SELECT se.recusa('trocar os canais habilitados é recusado', '42501',
    'UPDATE campaigns SET canais_habilitados = ''{email}''');

  -- Encerrar não é privilégio negado: é o CHECK de coerência. Sem poder
  -- escrever encerrado_em e motivo_encerramento, 'encerrado' é inalcançável
  -- pela tela — encerramento é fato do motor.
  SELECT se.recusa('encerrar à mão bate no CHECK de coerência', '23514',
    'UPDATE enrollments SET status = ''encerrado'' WHERE id = ''5e000000-0000-0000-0000-0000000000b1''');

  -- As três tabelas do motor: leitura sim, escrita nenhuma. Cada uma destas
  -- linhas era uma invariante alcançável por fora do motor.
  SELECT se.recusa('marcar mensagem como enviada é recusado', '42501',
    'UPDATE messages SET status = ''enviado''');
  SELECT se.recusa('reescrever o texto de uma mensagem na fila é recusado', '42501',
    'UPDATE messages SET conteudo = ''outra coisa''');
  SELECT se.recusa('apagar mensagem é recusado', '42501',
    'DELETE FROM messages');
  -- O gatilho `encerrar_por_resposta` lê este INSERT: sem a revogação, dava
  -- para encerrar a cadência de quem nunca respondeu (invariante 4).
  SELECT se.recusa('inventar um evento de resposta é recusado', '42501',
    'INSERT INTO message_events (tenant_id, message_id, tipo, payload) '
    || 'SELECT tenant_id, id, ''respondido'', ''{}''::jsonb FROM messages LIMIT 1');
  SELECT se.recusa('escrever no CRM por fora da outbox é recusado', '42501',
    'INSERT INTO outbox (tenant_id, contact_id, destino, fato, payload) VALUES ('
    || '''5e000000-0000-0000-0000-0000000000a0'', '
    || '''5e000000-0000-0000-0000-0000000000d1'', ''pipefy'', ''opt_out'', ''{}''::jsonb)');

  -- E o SELECT fica: a tela da campanha lê mensagem e evento, e é dela que
  -- sai a leitura do texto composto (D42) e a linha do tempo (D36).
  SELECT se.confere('mas a tela continua lendo as mensagens da campanha',
    (SELECT count(*) FROM messages) > 0);
COMMIT;

-- E o que o motor escreve continua sendo escrito pelo motor: a grade estreita
-- não quebrou o worker.
SELECT se.vencer();
SELECT se.confere_passada('a grade estreita não atrapalha o motor', 'mensagem_criada');

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM se.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM se.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM se.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'superfície de escrita: % asserção(ões) falharam', n; END IF;
END;
$$;
