-- As três tabelas do motor deixam de aceitar escrita do cliente (D54).
--
-- A migration anterior estreitou a grade de `campaigns`, `enrollments` e
-- `sender_accounts` porque a tela precisava de UMA coluna de cada. Conferir o
-- resultado no projeto mostrou o vizinho: `messages`, `message_events` e
-- `outbox` continuavam com INSERT, UPDATE e DELETE de tabela inteira para o
-- papel `authenticated`, e nenhuma tela jamais escreveu em nenhuma das três.
--
-- O que isso deixava fazer, de um cliente autenticado do próprio tenant, por
-- uma chamada de PostgREST e sem passar por adapter nenhum:
--
--   * `UPDATE messages SET status = 'enviado'` numa mensagem `pendente` —
--     a mensagem nunca sai e o painel diz que saiu. O oposto também: uma
--     `enviado` volta para `pendente` e é despachada de novo, que é a
--     invariante 1 furada por fora do motor;
--   * `UPDATE messages SET conteudo = ...` numa mensagem que ainda está na
--     fila — o texto que o shadow mode mostrou não é o que vai sair;
--   * `INSERT INTO message_events (tipo_evento = 'respondido')` — o gatilho
--     `encerrar_por_resposta` encerra a cadência inteira de um contato que
--     não respondeu nada. A invariante 4 disparada por quem quiser;
--   * `INSERT INTO outbox` — escrever no CRM do cliente um fato inventado,
--     pela porta que o D3 abriu justamente para ser estreita.
--
-- Nada disso é acessível pelo produto: o app escreve em `suppression` e em
-- `ai_credentials`, e tudo o mais passa por função. Quem escreve estas três é
-- o worker, com service key, por funções que `authenticated` não pode
-- executar (`processar_vencidos`, `reivindicar_pendentes`,
-- `registrar_resultado_envio`, `registrar_evento_provedor`,
-- `reivindicar_writebacks`, `registrar_resultado_writeback`) — conferido uma
-- a uma antes de revogar.
--
-- O `SELECT` fica: a tela da campanha lê mensagem e evento, e é dela que sai
-- a leitura do texto composto (D42) e a linha do tempo (D36).
--
-- Por que isto não é escopo esticado: a grade da migration anterior só é uma
-- garantia se a mesma pergunta for feita das tabelas vizinhas. Fechar a porta
-- de `enrollments.next_run_at` e deixar aberta a de `messages.status` é
-- trocar de porta, não fechar.
--
-- Reversível: supabase/down/20260925140000_o_que_e_do_motor_e_do_motor.down.sql

CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;

  -- Campanha: nome e objetivo são rótulo; `ativa` é o freio; `flow_version_id`
  -- é o que `definir_flow_da_campanha` escreve (ela é SECURITY INVOKER, então
  -- precisa do privilégio de quem a chama).
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id) ON campaigns TO authenticated;

  -- Enrollment: só `status`. Pausar e retomar, nada mais. `next_run_at` fica
  -- onde estava — pausa não perde o relógio, retomar volta para o horário que
  -- já era devido.
  GRANT UPDATE (status) ON enrollments TO authenticated;

  -- Remetente: apelido, quota e `estado`. Tirar do pool à mão é `desativado`;
  -- `circuito_aberto` quem escreve é o breaker.
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;

  -- E as três do motor: leitura sim, escrita nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;
END;
$$;

COMMENT ON FUNCTION privado.estreitar_escrita_do_cliente() IS
  'A grade de escrita do papel authenticated: por coluna onde a tela escreve, '
  'nenhuma nas tabelas do motor. Idempotente de propósito — tests/run.sh a '
  'chama depois de imitar o GRANT ALL do Supabase (D54).';

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
