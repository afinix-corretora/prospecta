-- Os classificadores globais saem (D63).
--
-- `privado.pedido_de_saida` (D48) e `privado.eh_recusa` (D58) liam as listas do
-- PRODUTO. Desde a migration anterior ninguém os chama: os gatilhos de resposta
-- perguntam a `privado.regra_da_resposta`, que lê a blacklist do CLIENTE. Função
-- sem chamador parece garantia e é decoração — o `tem_adapter` do D31.
--
-- As listas globais (`opt_out_termos`, `recusa_termos`) ficam: são o padrão que
-- `semear_blacklist` copia para todo cliente novo, e têm leitor.
--
-- Separada da anterior porque, no projeto, DROP espera a confirmação de uma
-- pessoa; até ela vir, as duas funções existem sem efeito nenhum.
--
-- Reversível: supabase/down/20261002110100_blacklist_aposenta_classificadores.down.sql

DROP FUNCTION privado.pedido_de_saida(text);
DROP FUNCTION privado.eh_recusa(text);
