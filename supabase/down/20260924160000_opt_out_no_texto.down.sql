DROP TRIGGER IF EXISTS message_events_opt_out_no_texto ON message_events;
DROP FUNCTION IF EXISTS privado.opt_out_no_texto();
DROP FUNCTION IF EXISTS privado.pedido_de_saida(text);
DROP FUNCTION IF EXISTS privado.normalizar_resposta(text);
DROP TABLE IF EXISTS opt_out_termos;
