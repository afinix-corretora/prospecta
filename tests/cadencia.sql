-- Escrever a cadência (D55).
--
-- O que este arquivo sustenta, em ordem de importância:
--
--   1. publicar é INSERIR versão nova, nunca editar a que existe (D9) — e a
--      prova não é o comentário, é o enrollment em curso continuar na versão
--      antiga depois de a seguinte ser publicada;
--   2. valor ruim vindo do cliente recusa o PASSO, com o índice, em vez de
--      abortar com mensagem de Postgres (D34);
--   3. cadência sem passo nenhum é recusada na publicação, que é o D47 uma
--      etapa mais cedo;
--   4. o atraso do primeiro passo é gravado como 0, porque o motor nunca o
--      lê — guardar o número digitado seria guardar o que não tem efeito.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA cd;
CREATE TABLE cd.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION cd.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO cd.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

-- Recusa com MOTIVO: "deu erro" é também o que um typo no nome da coluna dá.
--
-- `p_trecho` nunca é vazio, e isso não é zelo: a primeira versão deste arquivo
-- tinha um caso com trecho vazio, que casa com QUALQUER coisa — inclusive com
-- "(aceitou)". Ele passou verde sobre uma publicação que foi aceita, e quem
-- reclamou foi a asserção seguinte, que achou o flow "Recusada" no banco. É o
-- D36 outra vez: asserção que o cenário não consegue violar não prova nada.
CREATE FUNCTION cd.recusa(p_nome text, p_passos jsonb, p_trecho text,
                          p_nome_do_flow text DEFAULT 'Recusada')
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  IF coalesce(btrim(p_trecho), '') = '' THEN
    RAISE EXCEPTION 'cd.recusa: trecho vazio casa com tudo, inclusive com aceitar';
  END IF;
  BEGIN
    PERFORM * FROM publicar_versao_de_flow(
      '00000000-0000-0000-0000-0000000000aa', NULL, p_nome_do_flow, p_passos);
    v := '(aceitou)';
  EXCEPTION WHEN invalid_parameter_value THEN v := SQLERRM;
  END;
  PERFORM cd.confere(p_nome, v LIKE '%' || p_trecho || '%', v);
END; $$;

-- ===========================================================================
-- 1. Publicar do zero
-- ===========================================================================

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM publicar_versao_de_flow(
    '00000000-0000-0000-0000-0000000000aa', NULL, 'Resgate escrito à mão',
    '[{"canal":"whatsapp","atraso_horas":72,"template":"Oi {{nome}}, aqui é da Afinix."},
      {"canal":"whatsapp","atraso_horas":48,"template":"{{nome}}, ainda faz sentido?"},
      {"canal":"email","atraso_horas":96,"template":"Resumo da proposta"}]'::jsonb);

  PERFORM cd.confere('cadência nova nasce na versão 1', r.versao = 1, r.versao::text);
  PERFORM cd.confere('os três passos foram gravados', r.passos_criados = 3, r.passos_criados::text);

  PERFORM cd.confere('a ordem é contígua a partir de 1',
    (SELECT array_agg(ordem ORDER BY ordem) = ARRAY[1,2,3]
       FROM flow_steps WHERE flow_version_id = r.flow_version_id));

  -- O agendador usa o atraso do passo SEGUINTE; o do primeiro nunca é lido.
  PERFORM cd.confere('o atraso digitado no primeiro passo vira 0, não 72',
    (SELECT atraso_horas = 0 FROM flow_steps
      WHERE flow_version_id = r.flow_version_id AND ordem = 1),
    (SELECT atraso_horas::text FROM flow_steps
      WHERE flow_version_id = r.flow_version_id AND ordem = 1));

  PERFORM cd.confere('os atrasos seguintes são os que foram escritos',
    (SELECT array_agg(atraso_horas ORDER BY ordem) = ARRAY[0,48,96]
       FROM flow_steps WHERE flow_version_id = r.flow_version_id));

  PERFORM cd.confere('o canal de cada passo é o que foi escrito',
    (SELECT array_agg(canal::text ORDER BY ordem) = ARRAY['whatsapp','whatsapp','email']
       FROM flow_steps WHERE flow_version_id = r.flow_version_id));

  PERFORM cd.confere('o texto vai sem espaço nas pontas',
    (SELECT template = 'Resumo da proposta' FROM flow_steps
      WHERE flow_version_id = r.flow_version_id AND ordem = 3));
END;
$$;

-- ===========================================================================
-- 2. Publicar a seguinte NÃO move quem está inscrito (D9)
-- ===========================================================================

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES ('cd000000-0000-0000-0000-0000000000c1','Cadência','morna','opt-in','{whatsapp,email}');
INSERT INTO contacts (id, nome, origem)
VALUES ('cd000000-0000-0000-0000-0000000000d1','Contato da cadência','planilha');
INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
VALUES ('cd000000-0000-0000-0000-0000000000d1','whatsapp','+55 11 97000-5001','5511970005001','planilha');

DO $$
DECLARE v_flow uuid; v_v1 uuid; r record; v_insc uuid;
BEGIN
  SELECT f.id, fv.id INTO v_flow, v_v1
    FROM flows f JOIN flow_versions fv ON fv.flow_id = f.id
   WHERE f.nome = 'Resgate escrito à mão';

  PERFORM definir_flow_da_campanha('cd000000-0000-0000-0000-0000000000c1', v_v1);
  v_insc := inscrever_pela_campanha('cd000000-0000-0000-0000-0000000000d1',
                                    'cd000000-0000-0000-0000-0000000000c1');

  -- Editar a cadência: publica a versão 2 no MESMO flow.
  SELECT * INTO r FROM publicar_versao_de_flow(
    '00000000-0000-0000-0000-0000000000aa', v_flow, NULL,
    '[{"canal":"whatsapp","atraso_horas":0,"template":"Texto novo"}]'::jsonb);

  PERFORM cd.confere('publicar de novo no mesmo flow dá a versão 2',
    r.versao = 2 AND r.flow_id = v_flow, r.versao::text);

  PERFORM cd.confere('a versão 1 continua intacta: 3 passos',
    (SELECT count(*) = 3 FROM flow_steps WHERE flow_version_id = v_v1));

  -- A prova do D9 que interessa: não é a coluna, é o enrollment.
  PERFORM cd.confere('quem já estava inscrito continua na versão em que entrou',
    (SELECT flow_version_id = v_v1 FROM enrollments WHERE id = v_insc));

  -- E a campanha também não se move sozinha: repontar é ato à parte, onde a
  -- conferência de canais do D47 acontece.
  PERFORM cd.confere('a campanha continua apontando a versão anterior',
    (SELECT flow_version_id = v_v1 FROM campaigns
      WHERE id = 'cd000000-0000-0000-0000-0000000000c1'));

  PERFORM definir_flow_da_campanha('cd000000-0000-0000-0000-0000000000c1', r.flow_version_id);
  PERFORM cd.confere('repontar é o ato que move a campanha',
    (SELECT flow_version_id = r.flow_version_id FROM campaigns
      WHERE id = 'cd000000-0000-0000-0000-0000000000c1'));

  PERFORM cd.confere('e ainda assim não move o enrollment em curso',
    (SELECT flow_version_id = v_v1 FROM enrollments WHERE id = v_insc));
END;
$$;

-- A imutabilidade por gatilho continua de pé: publicar não é uma porta lateral.
DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    UPDATE flow_steps SET template = 'trocado'
     WHERE template = 'Resumo da proposta';
    v_erro := '(editou)';
  EXCEPTION WHEN restrict_violation THEN v_erro := 'recusou';
  END;
  PERFORM cd.confere('editar passo publicado continua recusado pelo gatilho (D9)',
    v_erro = 'recusou', v_erro);
END;
$$;

-- ===========================================================================
-- 3. Valor ruim recusa o passo, com o índice
-- ===========================================================================

SELECT cd.recusa('lista vazia é recusada na publicação',
  '[]'::jsonb, 'nunca manda nada');

SELECT cd.recusa('canal desconhecido nomeia o passo, não estoura o cast',
  '[{"canal":"whatsapp","template":"ok"},{"canal":"telegram","template":"x"}]'::jsonb,
  'passo 2: canal desconhecido');

SELECT cd.recusa('passo sem canal também nomeia o passo',
  '[{"template":"x"}]'::jsonb, 'passo 1: canal desconhecido');

SELECT cd.recusa('texto vazio é recusado',
  '[{"canal":"whatsapp","template":"   "}]'::jsonb, 'passo 1: falta o texto');

SELECT cd.recusa('atraso que não é número é recusado antes de virar número',
  '[{"canal":"whatsapp","template":"a"},{"canal":"whatsapp","atraso_horas":"amanhã","template":"b"}]'::jsonb,
  'passo 2: atraso em horas');

SELECT cd.recusa('atraso negativo é recusado',
  '[{"canal":"whatsapp","template":"a"},{"canal":"whatsapp","atraso_horas":"-3","template":"b"}]'::jsonb,
  'passo 2: atraso em horas');

-- Aqui o passo é BOM de propósito: o que se testa é a falta do nome, e um
-- passo ruim junto faria a recusa vir pelo outro motivo.
SELECT cd.recusa('cadência nova sem nome é recusada',
  '[{"canal":"whatsapp","template":"a"}]'::jsonb, 'precisa de nome', NULL);
SELECT cd.recusa('nome só de espaço também é recusado',
  '[{"canal":"whatsapp","template":"a"}]'::jsonb, 'precisa de nome', '   ');

-- A recusa é da CHAMADA inteira, não da linha: um passo ruim no meio não
-- deixa meia cadência publicada (é a trava do D34, aqui).
SELECT cd.confere('passo ruim no meio não deixa versão pela metade',
  NOT EXISTS (SELECT 1 FROM flows WHERE nome = 'Recusada'));

-- ===========================================================================
-- 4. As variáveis que os templates podem usar
-- ===========================================================================

UPDATE contacts SET metadados = '{"plano_atual":"Amil","corretor":"Ana"}'::jsonb
 WHERE id = 'cd000000-0000-0000-0000-0000000000d1';
INSERT INTO contacts (id, nome, origem, metadados)
VALUES ('cd000000-0000-0000-0000-0000000000d2', NULL, 'planilha',
        '{"plano_atual":"Unimed"}'::jsonb);

SELECT cd.confere('as chaves de metadados aparecem com a contagem certa',
  (SELECT contatos = 2 FROM variaveis_disponiveis('00000000-0000-0000-0000-0000000000aa')
    WHERE chave = 'plano_atual'));

SELECT cd.confere('chave que só um contato tem aparece com 1',
  (SELECT contatos = 1 FROM variaveis_disponiveis('00000000-0000-0000-0000-0000000000aa')
    WHERE chave = 'corretor'));

-- `nome` não mora em metadados, e conta só quem o tem: template com {{nome}}
-- numa base sem nome vira "Olá ," (D42).
SELECT cd.confere('nome entra na lista, contando só quem o tem preenchido',
  (SELECT contatos = 1 FROM variaveis_disponiveis('00000000-0000-0000-0000-0000000000aa')
    WHERE chave = 'nome'));

SELECT cd.confere('nenhuma chave inventada aparece',
  NOT EXISTS (SELECT 1 FROM variaveis_disponiveis('00000000-0000-0000-0000-0000000000aa')
               WHERE chave NOT IN ('plano_atual','corretor','nome')));

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM cd.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM cd.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM cd.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'cadência: % asserção(ões) falharam', n; END IF;
END;
$$;
