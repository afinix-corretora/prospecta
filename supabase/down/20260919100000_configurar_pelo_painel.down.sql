-- Reverte a configuração de provedor pelo painel.

DROP FUNCTION IF EXISTS salvar_credencial_remetente(uuid, jsonb);
DROP FUNCTION IF EXISTS salvar_servidor_provedor(uuid, text, text, text, text);
