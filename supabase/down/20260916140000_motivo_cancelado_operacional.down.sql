-- Reverte 20260916140000_motivo_cancelado_operacional.sql
--
-- Postgres não remove valor de enum (não existe ALTER TYPE ... DROP VALUE).
-- A reversão recria o tipo sem o valor e reconverte a coluna.
--
-- Falha de propósito se alguma linha já usa 'cancelado_operacional': reverter
-- nesse caso apagaria o motivo real de encerramentos existentes. Quem quiser
-- reverter mesmo assim decide antes para onde esses enrollments vão.

ALTER TABLE enrollments
  DROP CONSTRAINT enrollments_encerramento_coerente;

ALTER TABLE enrollments
  ALTER COLUMN motivo_encerramento TYPE text;

DROP TYPE motivo_encerramento;

CREATE TYPE motivo_encerramento AS ENUM (
  'resposta',
  'mudanca_etapa_crm',
  'fim_dos_passos',
  'supressao',
  'falha_permanente'
);

ALTER TABLE enrollments
  ALTER COLUMN motivo_encerramento TYPE motivo_encerramento
  USING motivo_encerramento::motivo_encerramento;

ALTER TABLE enrollments
  ADD CONSTRAINT enrollments_encerramento_coerente CHECK (
    (status = 'encerrado' AND encerrado_em IS NOT NULL AND motivo_encerramento IS NOT NULL)
    OR (status <> 'encerrado' AND encerrado_em IS NULL AND motivo_encerramento IS NULL)
  );
