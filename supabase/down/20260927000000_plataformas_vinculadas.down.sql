-- Reverte as plataformas vinculadas (D59).
--
-- A ordem importa: as funções primeiro, porque `segredo_da_conexao_crm` e
-- `salvar_credencial_crm` leem `crm_connections`; o gatilho cai com a tabela.
-- `crm_provider_catalog` é a última, porque `crm_connections.provedor` a
-- referencia.
--
-- A credencial em si fica no Vault. Apagar a tabela não apaga o segredo, e
-- apagá-lo aqui seria perder a credencial do cliente num rollback de schema —
-- o que o down existe para NÃO fazer.
DROP FUNCTION IF EXISTS segredo_da_conexao_crm(uuid);
DROP FUNCTION IF EXISTS salvar_credencial_crm(uuid, text, text, jsonb);

DROP TABLE IF EXISTS crm_connections;
DROP FUNCTION IF EXISTS privado.barrar_segredo_em_config_crm();

DROP TABLE IF EXISTS crm_provider_catalog;
