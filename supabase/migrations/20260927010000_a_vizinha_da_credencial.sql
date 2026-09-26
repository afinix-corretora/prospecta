-- A credencial nova nasceu com a porta aberta, e as vizinhas também (D59).
--
-- Aplicar o D59 no projeto e conferir a grade mostrou o que o suite não
-- enxerga: `crm_connections` e `crm_provider_catalog` nasceram com INSERT,
-- UPDATE e DELETE de tabela inteira para o papel `authenticated`. O D19 tirou
-- o *default privilege* nominal, mas tabela nova continua recebendo a grade
-- larga do Supabase — e **tabela criada hoje não herda a estreitada de ontem**,
-- porque a estreitada é nominal, tabela por tabela.
--
-- O RLS de `crm_connections` segura a LINHA (`pode_administrar`), e é por isso
-- que isto não é vazamento entre clientes. É o D54 na outra metade: política
-- decide quais linhas, `GRANT UPDATE` de tabela inteira decide quais COLUNAS —
-- e com a grade larga, um admin do próprio tenant escrevia
-- `credencial_secret_id` por uma chamada de PostgREST. O efeito não é ler o
-- segredo (`segredo_da_conexao_crm` não é de `authenticated`, D44): é o worker
-- chamando o CRM com a credencial de outra conexão, que é a pior forma de
-- errar, porque parece funcionar.
--
-- A única coluna que a tela escreve é `ativo` (`alternarConexaoCRM`). Vincular
-- é `salvar_credencial_crm`, que é SECURITY DEFINER e não usa privilégio do
-- cliente para nada.
--
-- **E as vizinhas, que é o que o D54 manda olhar.** `ai_credentials` é a irmã
-- exata desta tabela — ponteiro de Vault, tela de uma coluna (`ativo`), escrita
-- por função DEFINER — e estava com a mesma grade larga desde o D17. Fechar a
-- porta nova e deixar a dela aberta é trocar de porta, não fechar. Junto vão
-- `provider_servers`, que nenhuma tela escreve (`salvar_servidor_provedor` é
-- DEFINER), e os três catálogos de produto, que são do produto e não do
-- cliente.
--
-- O que fica de fora, de propósito, para o comentário não afirmar mais do que
-- o código faz (D47):
--
--   * `suppression` continua com INSERT do cliente. É a tela do D41, e a
--     política já é a autorização;
--   * `campaign_templates` continua como está. Ela TEM política de INSERT,
--     UPDATE e DELETE por tenant desde o D18 — o desenho prevê modelo do
--     cliente, e revogar o privilégio mataria uma tela que a política espera;
--   * `recusa_termos` fica de fora: é catálogo com RLS só de SELECT, e a lista
--     de quem o D58 mexeu não é onde esta migration precisa entrar.
--
-- ATENÇÃO, QUEM FOR MEXER NESTA FUNÇÃO DE NOVO: o corpo abaixo é o do **D57**
-- mais as linhas novas, não o do D54. Escrevê-lo a partir de uma cópia antiga
-- apaga em silêncio tudo o que entrou depois dela — foi exatamente o que a
-- primeira versão desta migration fez, derrubando as revogações de `deals` e
-- `deal_activities` (o "porta única" do D57) e o `SET search_path` da corretiva
-- do D54. `CREATE OR REPLACE` de função substitui o corpo INTEIRO: não há
-- merge, e quem percebeu foi `tests/funil.sql` com uma asserção sobre um
-- assunto que esta migration não menciona.
--
-- Reversível: supabase/down/20260927010000_a_vizinha_da_credencial.down.sql

CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
RETURNS void
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  -- D54: por coluna onde a tela escreve.
  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id) ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;

  -- D54: as três do motor, leitura sim, escrita nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;

  -- D57: o funil. Renomear e reordenar estágio é da tela; mover card é de
  -- `mover_deal`, e sem esta revogação "porta única" seria convenção.
  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;

  -- D59, daqui para baixo.
  --
  -- As duas tabelas de credencial: a tela liga e desliga, e nada mais. Quem
  -- grava é a função DEFINER, que não usa privilégio do cliente.
  --
  -- O INSERT vai embora junto do UPDATE largo, e não é zelo a mais: com ele,
  -- dava para criar a linha com `credencial_secret_id` escolhido à mão,
  -- apontando para um segredo do Vault que não é desta conexão. Passar pela
  -- função é o que garante que o ponteiro nasce de `guardar_segredo`.
  REVOKE INSERT, UPDATE, DELETE ON ai_credentials, crm_connections FROM authenticated;
  GRANT UPDATE (ativo) ON ai_credentials TO authenticated;
  GRANT UPDATE (ativo) ON crm_connections TO authenticated;

  -- Servidor de provedor: nenhuma tela escreve. `salvar_servidor_provedor` é
  -- DEFINER, e `admin_secret_id` é ponteiro de Vault pelo mesmo motivo acima.
  REVOKE INSERT, UPDATE, DELETE ON provider_servers FROM authenticated;

  -- Catálogo é do produto, não do cliente. Nos três o RLS já recusa por falta
  -- de política de DML, e é justamente por isso que a revogação entra: confiar
  -- que "não tem política" é o mesmo que "não tem privilégio" é o D54 pela
  -- terceira vez. Quem lê continua lendo — `tem_adapter` e `campos` são o que
  -- a tela desenha.
  REVOKE INSERT, UPDATE, DELETE
      ON channel_provider_catalog, ai_provider_catalog, crm_provider_catalog
    FROM authenticated;
END;
$$;

COMMENT ON FUNCTION privado.estreitar_escrita_do_cliente() IS
  'A grade de escrita do papel authenticated: por coluna onde a tela escreve, '
  'nenhuma nas tabelas do motor, no funil, nas de credencial e nos catálogos. '
  'Idempotente de propósito — tests/run.sh a chama depois de imitar o GRANT ALL '
  'do Supabase (D54), e tabela nova não herda a estreitada de ontem (D59). '
  'Quem for substituir o corpo: parta do corpo ATUAL, não de uma migration '
  'antiga — CREATE OR REPLACE troca o corpo inteiro e não faz merge.';

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
