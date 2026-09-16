-- Acrescenta 'cancelado_operacional' a motivo_encerramento.
--
-- Por quê: `cancelled` (nos três pipelines antigos) e o `discarded` manual do
-- blast não são resposta, nem mudança de etapa, nem fim dos passos, nem
-- supressão, nem falha. Forçá-los em `falha_permanente` faria o relatório
-- contar decisão humana como falha do motor.
--
-- Aditivo e feito ANTES do backfill de propósito: depois que houver linha
-- gravada com o motivo errado, corrigir custa caro.
--
-- Ver D13 em DECISOES.md e MAPA-STATUS.md.

ALTER TYPE motivo_encerramento ADD VALUE IF NOT EXISTS 'cancelado_operacional';
