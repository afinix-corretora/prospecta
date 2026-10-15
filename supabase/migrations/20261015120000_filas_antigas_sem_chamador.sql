-- As duas filas antigas do agente saem (D78c).
--
-- `public.respostas_para_rascunhar` (D66, a credencial da campanha no D68) ficou
-- sem chamador quando o worker passou a responder sozinho pela fila do D69; e
-- `public.respostas_para_o_agente` (D69), quando o worker v8 passou a perguntar a
-- `public.fila_do_agente` (D76). O `motor-worker` publicado (v9, lido de volta
-- 27/27) não chama nenhuma das duas, e nenhuma função, view, gatilho ou job do
-- `pg_cron` as cita. Função sem chamador parece garantia e é decoração — o
-- `tem_adapter` do D31.
--
-- Separada e só com os DROP, como a do D63: no projeto o DROP espera a
-- confirmação de uma pessoa, e quem aplica é ela, no SQL Editor. Até lá as duas
-- existem sem efeito nenhum.
--
-- Reversível: supabase/down/20261015120000_filas_antigas_sem_chamador.down.sql

DROP FUNCTION public.respostas_para_rascunhar(integer);
DROP FUNCTION public.respostas_para_o_agente(integer);
