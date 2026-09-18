-- Reverte o agendamento do motor.

-- Primeiro o job: dropar a função deixando o job de pé faria cada batida do
-- cron falhar de hora em hora, com o erro só no log da extensão.
DO $$
BEGIN
  IF to_regprocedure('privado.desagendar_motor()') IS NOT NULL THEN
    PERFORM privado.desagendar_motor();
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS privado.ultimas_passadas(integer);
DROP FUNCTION IF EXISTS privado.agendar_motor(text, text, integer);
DROP FUNCTION IF EXISTS privado.desagendar_motor();
DROP FUNCTION IF EXISTS privado.acordar_motor(text, integer);
DROP FUNCTION IF EXISTS privado.chave_do_motor();

-- `pg_cron` e `pg_net` não são revertidas de propósito. São extensões do
-- projeto, não deste schema: outra coisa pode ter passado a depender delas, e
-- derrubar a extensão de todo mundo é pior do que deixar duas extensões
-- ociosas. Recriar custa um CREATE EXTENSION.
