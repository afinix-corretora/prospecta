-- Tira o classificador de recusa. Os cards ficam onde estão.

DROP TRIGGER IF EXISTS message_events_qualifica_resposta ON message_events;
DROP FUNCTION IF EXISTS privado.qualifica_resposta();
DROP FUNCTION IF EXISTS privado.eh_recusa(text);
DROP TABLE IF EXISTS recusa_termos;
