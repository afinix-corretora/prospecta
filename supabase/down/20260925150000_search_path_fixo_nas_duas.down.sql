-- Devolve as duas funções ao search_path do chamador.

ALTER FUNCTION privado.estreitar_escrita_do_cliente() RESET search_path;
ALTER FUNCTION criar_campanha_de_modelo(uuid, text, text, canal[]) RESET search_path;
