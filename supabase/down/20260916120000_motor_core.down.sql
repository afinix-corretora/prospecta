-- Reverte 20260916120000_motor_core.sql
-- Ordem inversa: dependentes antes dos dependidos.

DROP FUNCTION IF EXISTS proximos_vencidos(integer);
DROP FUNCTION IF EXISTS remetentes_disponiveis(canal, tipo_campanha);
DROP FUNCTION IF EXISTS registrar_sucesso_remetente(uuid);
DROP FUNCTION IF EXISTS registrar_falha_remetente(uuid, integer, interval);
DROP FUNCTION IF EXISTS reservar_envio(uuid);

DROP TABLE IF EXISTS outbox;
DROP TABLE IF EXISTS message_events;
DROP TABLE IF EXISTS messages;
DROP TABLE IF EXISTS enrollments;
DROP TABLE IF EXISTS suppression;
DROP TABLE IF EXISTS sender_accounts;
DROP TABLE IF EXISTS flow_steps;
DROP TABLE IF EXISTS flow_versions;
DROP TABLE IF EXISTS flows;
DROP TABLE IF EXISTS campaigns;
DROP TABLE IF EXISTS contact_identities;
DROP TABLE IF EXISTS contacts;

-- Funções de trigger, depois que as tabelas que as usam já se foram.
DROP FUNCTION IF EXISTS tocar_atualizado_em();
DROP FUNCTION IF EXISTS encerrar_por_resposta();
DROP FUNCTION IF EXISTS barrar_remetente_incompativel();
DROP FUNCTION IF EXISTS barrar_mensagem_suprimida();
DROP FUNCTION IF EXISTS esta_suprimido(uuid, canal, text);
DROP FUNCTION IF EXISTS recusar_escrita();

DROP TYPE IF EXISTS status_outbox;
DROP TYPE IF EXISTS fato_writeback;
DROP TYPE IF EXISTS estado_remetente;
DROP TYPE IF EXISTS tipo_evento;
DROP TYPE IF EXISTS status_message;
DROP TYPE IF EXISTS motivo_encerramento;
DROP TYPE IF EXISTS status_enrollment;
DROP TYPE IF EXISTS tipo_campanha;
DROP TYPE IF EXISTS canal;
