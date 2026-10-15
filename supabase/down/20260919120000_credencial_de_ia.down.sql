-- Reverte a credencial de IA pelo painel.

DROP FUNCTION IF EXISTS segredo_da_credencial_ia(uuid);
DROP FUNCTION IF EXISTS salvar_credencial_ia(uuid, text, text, text, jsonb);
