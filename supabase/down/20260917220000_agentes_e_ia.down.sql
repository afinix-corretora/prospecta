-- Reverte 20260917220000_agentes_e_ia.sql

DROP FUNCTION IF EXISTS agente_do_canal(uuid, canal);
DROP FUNCTION IF EXISTS atribuir_agente(uuid, uuid);
DROP TABLE IF EXISTS campaign_agents;
DROP FUNCTION IF EXISTS validar_agente_da_campanha();
DROP TABLE IF EXISTS agents;
DROP TABLE IF EXISTS ai_credentials;
DROP FUNCTION IF EXISTS barrar_segredo_em_config();
DROP TABLE IF EXISTS ai_provider_catalog;
