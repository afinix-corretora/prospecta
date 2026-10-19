-- Reverte o painel da campanha.

DROP FUNCTION IF EXISTS eventos_da_campanha(uuid, uuid, integer);
DROP FUNCTION IF EXISTS resumo_da_campanha(uuid, uuid);
