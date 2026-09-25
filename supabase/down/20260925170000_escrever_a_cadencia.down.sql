-- Tira a porta de escrever cadência. As versões já publicadas ficam: são
-- imutáveis por gatilho (D9), e apagá-las levaria junto os enrollments.

DROP FUNCTION IF EXISTS publicar_versao_de_flow(uuid, uuid, text, jsonb);
DROP FUNCTION IF EXISTS variaveis_disponiveis(uuid);
