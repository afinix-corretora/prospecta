-- A tela liga e desliga — e só isso (D54).
--
-- O motor sempre soube parar. `processar_vencidos` pula campanha com
-- `ativa = false` e enrollment `pausado`; `remetentes_disponiveis` pula
-- remetente fora do estado `ativo`. Os três freios existem desde a primeira
-- migration e nenhuma tela jamais os puxou: dava para começar uma cadência
-- pelo produto e não dava para pará-la sem abrir o painel do Supabase.
--
-- O RLS já autoriza essas escritas — `pode_operar` para campanha e
-- enrollment, `pode_administrar` para remetente. Pelo D41, então, a tela
-- escreve direto e não ganha função nova: criar `pausar_campanha()` em
-- `public` seria repetir em PL/pgSQL o que a política já diz.
--
-- O que NÃO estava certo é o privilégio por baixo da política. A grade que o
-- Supabase instala por padrão dá `UPDATE` de TABELA INTEIRA ao papel
-- `authenticated`, e RLS decide QUAIS LINHAS, nunca QUAIS COLUNAS. Um cliente
-- autenticado do próprio tenant podia, com uma chamada de PostgREST:
--
--   * zerar `sender_accounts.enviados_na_janela` e mandar o dobro da quota —
--     a invariante 3 não é furada por bug do motor, é furada por fora;
--   * escrever `enrollments.next_run_at` e `passo_atual`, isto é, mandar o
--     agendador disparar quando e o que quisesse;
--   * trocar `campaigns.tipo` de fria para morna e com isso mudar o pool de
--     remetentes permitido (D4) sem tocar em remetente nenhum.
--
-- Nada disto nasceu com a tela de ligar/desligar; a tela só é a primeira vez
-- que alguém precisa de UM desses privilégios, e é a hora de deixar de dar os
-- outros vinte junto. A grade passa a ser por coluna: o que a tela escreve,
-- e nada mais.
--
-- As colunas de ESTADO DO MOTOR ficam de fora de propósito:
-- `enviados_na_janela`, `janela`, `health_score`, `falhas_consecutivas`,
-- `circuito_aberto_ate`, `passo_atual`, `next_run_at`, `encerrado_em`,
-- `motivo_encerramento`. Quem escreve essas é o worker, com service key.
--
-- Encerrar um enrollment à mão continua impossível, e não por grant: o CHECK
-- `enrollments_encerramento_coerente` exige que `encerrado` venha com
-- `encerrado_em` e `motivo_encerramento`. Sem privilégio nessas duas colunas,
-- o UPDATE que tentar `status = 'encerrado'` bate no CHECK. Pela mesma porta,
-- ressuscitar um encerrado também é recusado. Encerramento é fato do motor.
--
-- Reversível: supabase/down/20260925120000_a_tela_liga_e_desliga.down.sql

-- ---------------------------------------------------------------------------
-- A grade, como função: a suite precisa reaplicá-la
-- ---------------------------------------------------------------------------
--
-- No Supabase o `GRANT ALL` vem do default privilege e acontece no CREATE
-- TABLE, então um REVOKE numa migration posterior fica de pé. No Postgres
-- local não há esse default privilege: `tests/run.sh` imita a grade de
-- produção com um `GRANT ALL ON ALL TABLES` DEPOIS de aplicar as migrations,
-- que desfaria este arquivo e faria o teste conferir uma superfície mais
-- larga que a real — a falha silenciosa de sempre.
--
-- Por isso a grade mora numa função idempotente, em `privado`, que a suite
-- chama pelo NOME depois do seu GRANT. Nome é contrato; número de migration
-- na linha de um script envelhece sem avisar.
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
END;
$$;

COMMENT ON FUNCTION privado.estreitar_escrita_do_cliente() IS
  'A grade de UPDATE por coluna do papel authenticated. Idempotente de '
  'propósito: tests/run.sh a chama depois de imitar o GRANT ALL do Supabase.';

-- Num bloco anônimo, e não `SELECT`: as migrations são aplicadas por um psql
-- cuja saída o `tests/run.sh` captura para descobrir o nome do banco. Uma
-- linha de resultado aqui vira nome de banco e o suite inteiro não roda.
DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
