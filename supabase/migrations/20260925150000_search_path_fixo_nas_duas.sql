-- `SET search_path` nas duas funções que o advisor apontou (D54).
--
-- O `get_advisors` do projeto, rodado logo depois de aplicar as duas
-- migrations acima, devolveu `function_search_path_mutable` para:
--
--   * `privado.estreitar_escrita_do_cliente`, que é nova aqui;
--   * `public.criar_campanha_de_modelo`, que nunca teve `SET search_path` —
--     nasceu assim no D18 e o `CREATE OR REPLACE` de agora só a trouxe de
--     volta para debaixo da luz.
--
-- Função sem `search_path` fixo resolve nome pelo caminho de QUEM CHAMA. Numa
-- função SECURITY INVOKER o risco é menor do que numa DEFINER, mas o efeito
-- prático é o de sempre nesta base: `criar_campanha_de_modelo` passa a chamar
-- `definir_flow_da_campanha`, e resolver esse nome pelo caminho do chamador é
-- deixar que o caminho decida qual função roda.
--
-- Corretiva, e por isso em arquivo próprio em vez de edição das anteriores: as
-- duas já estão registradas no projeto, e reescrever um arquivo já aplicado é
-- o que faz o digest do repositório deixar de responder pelo que está no ar
-- (D51, D52).
--
-- Sem barra invertida (D32).

ALTER FUNCTION privado.estreitar_escrita_do_cliente()
  SET search_path = public, privado, pg_catalog;

ALTER FUNCTION criar_campanha_de_modelo(uuid, text, text, canal[])
  SET search_path = public, privado, pg_catalog;
