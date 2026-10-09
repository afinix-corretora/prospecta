-- Tira a leitura das respostas. O texto continua gravado em message_events;
-- volta a ser ilegível pelo produto, que é o estado que esta migration corrige.

DROP FUNCTION IF EXISTS respostas_recebidas(uuid, uuid, integer);
