-- O Pipefy passa a ter adapter (D64).
--
-- Separada da migration das tabelas de propósito, e aplicada no projeto só
-- DEPOIS que `motor-worker` e `crm-descobrir` estiverem publicados e
-- conferidos byte a byte. Esta linha é o que faz `reivindicar_writebacks`
-- entregar fato ao worker; com ela verdadeira e o worker velho no ar, o fato
-- seria reivindicado por quem não sabe escrevê-lo — o D31.
--
-- Reversível: supabase/down/20261003100100_pipefy_tem_adapter.down.sql

UPDATE crm_provider_catalog SET tem_adapter = true WHERE slug = 'pipefy';
