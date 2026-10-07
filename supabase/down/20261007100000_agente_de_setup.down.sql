-- Desfaz o D72. O segredo `openai_agente_setup` fica no Vault: apagar chave é
-- decisão de quem a guardou, não efeito colateral de reverter uma migration.
DROP FUNCTION IF EXISTS agente_de_setup_disponivel();
DROP FUNCTION IF EXISTS segredo_do_agente_setup();
