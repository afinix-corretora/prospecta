-- Devolve as duas funções a PUBLIC, isto é, a visitante sem login.
-- Está aqui porque toda migration é reversível; reverter reabre o endpoint.

DO $$
DECLARE alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.variaveis_disponiveis(uuid)',
    'public.publicar_versao_de_flow(uuid, uuid, text, jsonb)'
  ] LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC', alvo);
  END LOOP;
END;
$$;
