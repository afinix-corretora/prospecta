-- A campanha aponta o seu flow (D47).
--
-- O que este arquivo sustenta, em ordem de importância:
--
--   1. o par que não cruza canal nenhum é RECUSADO na configuração — é o
--      silêncio do D35 pego cedo;
--   2. o cruzamento PARCIAL continua aceito, senão a trava seria estreita
--      demais e proibiria flow multicanal em campanha de um canal só;
--   3. repontar a campanha não move quem já está inscrito (D9);
--   4. campanha sem flow recusa alto na inscrição e explica na prévia, em vez
--      de criar enrollment que encerra vazio.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA fc;
CREATE TABLE fc.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION fc.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO fc.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

-- Cenário: duas campanhas (uma só de WhatsApp, uma de WhatsApp+e-mail) e
-- quatro versões de flow (só WhatsApp, só e-mail, multicanal, e uma vazia).
INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados) VALUES
  ('fc000000-0000-0000-0000-0000000000c1','So WhatsApp','morna','opt-in','{whatsapp}'),
  ('fc000000-0000-0000-0000-0000000000c2','Wpp e email','morna','opt-in','{whatsapp,email}');

INSERT INTO flows (id, nome) VALUES ('fc000000-0000-0000-0000-0000000000f0','F');

INSERT INTO flow_versions (id, flow_id, versao) VALUES
  ('fc000000-0000-0000-0000-0000000000a1','fc000000-0000-0000-0000-0000000000f0',1),
  ('fc000000-0000-0000-0000-0000000000a2','fc000000-0000-0000-0000-0000000000f0',2),
  ('fc000000-0000-0000-0000-0000000000a3','fc000000-0000-0000-0000-0000000000f0',3),
  ('fc000000-0000-0000-0000-0000000000a4','fc000000-0000-0000-0000-0000000000f0',4);

-- a1: só whatsapp. a2: só e-mail. a3: multicanal. a4: sem passo nenhum.
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template) VALUES
  ('fc000000-0000-0000-0000-0000000000a1',1,'whatsapp',0,'oi'),
  ('fc000000-0000-0000-0000-0000000000a1',2,'whatsapp',48,'e ai'),
  ('fc000000-0000-0000-0000-0000000000a2',1,'email',0,'oi por email'),
  ('fc000000-0000-0000-0000-0000000000a3',1,'whatsapp',0,'oi'),
  ('fc000000-0000-0000-0000-0000000000a3',2,'email',24,'oi por email');

INSERT INTO contacts (id, nome, origem) VALUES
  ('fc000000-0000-0000-0000-0000000000d1','Ana Flow','planilha'),
  ('fc000000-0000-0000-0000-0000000000d2','Bruno Flow','planilha');
INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem) VALUES
  ('fc000000-0000-0000-0000-0000000000d1','whatsapp','+55 11 97000-0001','5511970000001','planilha'),
  ('fc000000-0000-0000-0000-0000000000d2','whatsapp','+55 11 97000-0002','5511970000002','planilha');

-- ===========================================================================
-- 1. Ligar, recusando o par que não cruza
-- ===========================================================================

DO $$
DECLARE v_erro text; v_estado uuid;
BEGIN
  -- Campanha só de WhatsApp + flow só de e-mail: nenhum passo sairia. É
  -- exatamente a campanha "concluída" sem mensagem que o D35 descreve.
  BEGIN
    PERFORM definir_flow_da_campanha('fc000000-0000-0000-0000-0000000000c1',
                                     'fc000000-0000-0000-0000-0000000000a2');
    v_erro := '(não recusou)';
  EXCEPTION WHEN invalid_parameter_value THEN v_erro := 'recusou';
  END;
  PERFORM fc.confere('par sem canal em comum é recusado ao ligar',
    v_erro = 'recusou', v_erro);

  SELECT flow_version_id INTO v_estado FROM campaigns
   WHERE id = 'fc000000-0000-0000-0000-0000000000c1';
  PERFORM fc.confere('e a campanha continua sem flow depois da recusa',
    v_estado IS NULL, coalesce(v_estado::text,'(nulo)'));

  -- Flow sem passo nenhum também não serve.
  BEGIN
    PERFORM definir_flow_da_campanha('fc000000-0000-0000-0000-0000000000c1',
                                     'fc000000-0000-0000-0000-0000000000a4');
    v_erro := '(não recusou)';
  EXCEPTION WHEN invalid_parameter_value THEN v_erro := 'recusou';
  END;
  PERFORM fc.confere('flow sem passo nenhum é recusado ao ligar',
    v_erro = 'recusou', v_erro);

  -- O par certo passa.
  PERFORM definir_flow_da_campanha('fc000000-0000-0000-0000-0000000000c1',
                                   'fc000000-0000-0000-0000-0000000000a1');
  SELECT flow_version_id INTO v_estado FROM campaigns
   WHERE id = 'fc000000-0000-0000-0000-0000000000c1';
  PERFORM fc.confere('o par que cruza é aceito',
    v_estado = 'fc000000-0000-0000-0000-0000000000a1', coalesce(v_estado::text,'(nulo)'));

  -- Cruzamento PARCIAL: flow multicanal numa campanha de um canal só. Tem de
  -- passar — o D4 já manda pular o passo do canal não habilitado, e proibir
  -- isto tornaria a trava estreita demais para uso legítimo.
  PERFORM definir_flow_da_campanha('fc000000-0000-0000-0000-0000000000c1',
                                   'fc000000-0000-0000-0000-0000000000a3');
  SELECT flow_version_id INTO v_estado FROM campaigns
   WHERE id = 'fc000000-0000-0000-0000-0000000000c1';
  PERFORM fc.confere('cruzamento parcial é aceito (flow multicanal, campanha de um canal)',
    v_estado = 'fc000000-0000-0000-0000-0000000000a3', coalesce(v_estado::text,'(nulo)'));

  -- Desligar é legítimo.
  PERFORM definir_flow_da_campanha('fc000000-0000-0000-0000-0000000000c1', NULL);
  SELECT flow_version_id INTO v_estado FROM campaigns
   WHERE id = 'fc000000-0000-0000-0000-0000000000c1';
  PERFORM fc.confere('desligar o flow da campanha é permitido',
    v_estado IS NULL, coalesce(v_estado::text,'(nulo)'));

  -- E volta a ligar, para o resto do arquivo.
  PERFORM definir_flow_da_campanha('fc000000-0000-0000-0000-0000000000c1',
                                   'fc000000-0000-0000-0000-0000000000a1');
END;
$$;

-- ===========================================================================
-- 2. Inscrever pela campanha
-- ===========================================================================

DO $$
DECLARE v_enr uuid; v_erro text; v_versao uuid; v_n integer;
BEGIN
  -- A campanha c2 ainda não tem flow: recusa alto, e não cria enrollment.
  SELECT count(*) INTO v_n FROM enrollments
   WHERE campaign_id = 'fc000000-0000-0000-0000-0000000000c2';
  -- O `others` não é zelo: sem ele esta asserção não sabe falhar. Quem barra
  -- a inscrição sem flow, no fim, é o NOT NULL de `enrollments.flow_version_id`
  -- — com um `not_null_violation` que cita uma coluna interna e não diz o que
  -- fazer. O que esta função acrescenta é a recusa LEGÍVEL, antes disso. Se a
  -- asserção só aceitasse um SQLSTATE, tirar a checagem faria o arquivo
  -- abortar em vez de acusar, e teste que aborta encolhe sem avisar (D38).
  BEGIN
    PERFORM inscrever_pela_campanha('fc000000-0000-0000-0000-0000000000d1',
                                    'fc000000-0000-0000-0000-0000000000c2');
    v_erro := '(não recusou)';
  EXCEPTION
    WHEN invalid_parameter_value THEN v_erro := 'recusou claramente';
    WHEN others THEN v_erro := 'estourou cru, SQLSTATE ' || SQLSTATE;
  END;
  PERFORM fc.confere(
    'campanha sem flow recusa com erro claro, não com not-null lá de dentro',
    v_erro = 'recusou claramente', v_erro);
  PERFORM fc.confere('e não deixa enrollment para trás',
    (SELECT count(*) FROM enrollments
      WHERE campaign_id = 'fc000000-0000-0000-0000-0000000000c2') = v_n);

  -- Com flow, inscreve na versão da campanha — sem ninguém escolher nada.
  v_enr := inscrever_pela_campanha('fc000000-0000-0000-0000-0000000000d1',
                                   'fc000000-0000-0000-0000-0000000000c1');
  SELECT flow_version_id INTO v_versao FROM enrollments WHERE id = v_enr;
  PERFORM fc.confere('inscrição usa a versão da campanha',
    v_versao = 'fc000000-0000-0000-0000-0000000000a1', coalesce(v_versao::text,'(nulo)'));

  -- D9/D47: repontar a campanha NÃO move quem já está inscrito.
  PERFORM definir_flow_da_campanha('fc000000-0000-0000-0000-0000000000c1',
                                   'fc000000-0000-0000-0000-0000000000a3');
  SELECT flow_version_id INTO v_versao FROM enrollments WHERE id = v_enr;
  PERFORM fc.confere('repontar a campanha não move quem já está inscrito',
    v_versao = 'fc000000-0000-0000-0000-0000000000a1', coalesce(v_versao::text,'(nulo)'));

  -- ...mas a inscrição seguinte já entra na nova.
  v_enr := inscrever_pela_campanha('fc000000-0000-0000-0000-0000000000d2',
                                   'fc000000-0000-0000-0000-0000000000c1');
  SELECT flow_version_id INTO v_versao FROM enrollments WHERE id = v_enr;
  PERFORM fc.confere('a inscrição seguinte entra na versão nova',
    v_versao = 'fc000000-0000-0000-0000-0000000000a3', coalesce(v_versao::text,'(nulo)'));
END;
$$;

-- ===========================================================================
-- 3. A prévia pelo mesmo caminho
-- ===========================================================================

DO $$
DECLARE v_n integer; v_problema text; v_iguais boolean;
BEGIN
  -- Sem flow: uma linha por contato com o motivo, e NÃO lista vazia. Prévia
  -- vazia se lê como "nada a objetar", que é o oposto do que acontece.
  SELECT count(*) INTO v_n
    FROM prever_inscricao_pela_campanha(privado.tenant_padrao(),
           'fc000000-0000-0000-0000-0000000000c2',
           ARRAY['fc000000-0000-0000-0000-0000000000d1',
                 'fc000000-0000-0000-0000-0000000000d2']::uuid[]);
  PERFORM fc.confere('campanha sem flow: a prévia fala, não fica vazia', v_n = 2, v_n::text);

  SELECT problema INTO v_problema
    FROM prever_inscricao_pela_campanha(privado.tenant_padrao(),
           'fc000000-0000-0000-0000-0000000000c2',
           ARRAY['fc000000-0000-0000-0000-0000000000d1']::uuid[]) LIMIT 1;
  PERFORM fc.confere('e diz que o que falta é a versão de flow',
    v_problema LIKE '%versao de flow%' OR v_problema LIKE '%versão de flow%',
    coalesce(v_problema,'(nulo)'));

  -- Com flow: tem de dar exatamente o mesmo que a prévia explícita. Se
  -- divergisse, seriam duas respostas para a mesma pergunta (D32).
  SELECT bool_and(a.acao = b.acao) INTO v_iguais
    FROM prever_inscricao_pela_campanha(privado.tenant_padrao(),
           'fc000000-0000-0000-0000-0000000000c1',
           ARRAY['fc000000-0000-0000-0000-0000000000d1',
                 'fc000000-0000-0000-0000-0000000000d2']::uuid[]) a
    JOIN prever_inscricao(privado.tenant_padrao(),
           'fc000000-0000-0000-0000-0000000000c1',
           'fc000000-0000-0000-0000-0000000000a3',
           ARRAY['fc000000-0000-0000-0000-0000000000d1',
                 'fc000000-0000-0000-0000-0000000000d2']::uuid[]) b
      ON a.contact_id = b.contact_id;
  PERFORM fc.confere('com flow, a prévia pela campanha concorda com a explícita',
    coalesce(v_iguais,false));
END;
$$;

-- ===========================================================================
-- 4. As duas garantias de schema
-- ===========================================================================

DO $$
DECLARE v_erro text;
BEGIN
  -- A FK é composta: a campanha não alcança o flow de outro cliente. Sem o
  -- tenant no par, este INSERT passaria.
  INSERT INTO tenants (id, nome, slug)
  VALUES ('fc000000-0000-0000-0000-0000000000bb','Outro','outro-fc');
  INSERT INTO flows (id, tenant_id, nome)
  VALUES ('fc000000-0000-0000-0000-0000000000fb','fc000000-0000-0000-0000-0000000000bb','Do outro');
  INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
  VALUES ('fc000000-0000-0000-0000-0000000000ab','fc000000-0000-0000-0000-0000000000bb',
          'fc000000-0000-0000-0000-0000000000fb',1);

  BEGIN
    UPDATE campaigns SET flow_version_id = 'fc000000-0000-0000-0000-0000000000ab'
     WHERE id = 'fc000000-0000-0000-0000-0000000000c1';
    v_erro := '(aceitou)';
  EXCEPTION WHEN foreign_key_violation THEN v_erro := 'recusou';
  END;
  PERFORM fc.confere('a FK composta impede apontar o flow de outro cliente',
    v_erro = 'recusou', v_erro);

  -- A premissa por trás de não haver ON DELETE: versão de flow não se apaga.
  BEGIN
    DELETE FROM flow_versions WHERE id = 'fc000000-0000-0000-0000-0000000000a1';
    v_erro := '(apagou)';
  EXCEPTION WHEN restrict_violation THEN v_erro := 'recusou';
  END;
  PERFORM fc.confere('versão de flow não se apaga — por isso a FK não tem ON DELETE',
    v_erro = 'recusou', v_erro);
END;
$$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM fc.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM fc.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM fc.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'flow da campanha: % asserção(ões) falharam', n; END IF;
END;
$$;
