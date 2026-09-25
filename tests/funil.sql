-- O funil (D57).
--
-- Metade deste arquivo existe por causa de armadilhas que a base de
-- conhecimento da casa catalogou de SETE projetos anteriores. Elas estão
-- nomeadas nas asserções, porque é assim que elas param de voltar:
--
--   1. estágio referenciado por NOME quebrou quando o cliente renomeou;
--   2. automação moveu para "Perdeu" uma conversa que tinha agendado reunião;
--   3. guarda de reativação por contato impediu novo ciclo de campanha;
--   4. "gerenciado por IA" só na UI prometeu o que o backend não fazia.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA fu;
CREATE TABLE fu.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
GRANT USAGE ON SCHEMA fu TO authenticated;
GRANT INSERT, SELECT ON fu.resultado TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA fu TO authenticated;

CREATE FUNCTION fu.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO fu.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;
GRANT EXECUTE ON FUNCTION fu.confere(text, boolean, text) TO authenticated;

-- Em qual estágio está o card desta pessoa.
CREATE FUNCTION fu.estagio(p_contato uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT s.slug FROM deals d JOIN pipeline_stages s ON s.id = d.stage_id
   WHERE d.contact_id = p_contato;
$$;
GRANT EXECUTE ON FUNCTION fu.estagio(uuid) TO authenticated;

\set tenant '\'f0000000-0000-0000-0000-0000000000a0\''
\set oper   '\'f0000000-0000-0000-0000-0000000000a2\''

INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Funil', 'corretora-funil');
INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES (:tenant, :oper, 'operador');

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados)
VALUES ('f0000000-0000-0000-0000-0000000000c1', :tenant, 'Funil', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO flows (id, tenant_id, nome) VALUES ('f0000000-0000-0000-0000-0000000000e0', :tenant, 'F');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
VALUES ('f0000000-0000-0000-0000-0000000000e1', :tenant, 'f0000000-0000-0000-0000-0000000000e0', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
VALUES ('f0000000-0000-0000-0000-0000000000e2', :tenant, 'f0000000-0000-0000-0000-0000000000e1',
        1, 'whatsapp', 0, 'oi');

INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, tipo_permitido, quota_diaria)
VALUES ('f0000000-0000-0000-0000-00000000005a', :tenant, 'whatsapp', 'uazapi',
        '5511990009999', 'morna', 100);

-- Cinco pessoas, uma por destino possível do funil.
INSERT INTO contacts (id, tenant_id, nome, origem) VALUES
  ('f0000000-0000-0000-0000-0000000000d1', :tenant, 'Ana Prospeccao', 'planilha'),
  ('f0000000-0000-0000-0000-0000000000d2', :tenant, 'Bruno Contatado', 'planilha'),
  ('f0000000-0000-0000-0000-0000000000d3', :tenant, 'Carla Respondeu', 'planilha'),
  ('f0000000-0000-0000-0000-0000000000d4', :tenant, 'Davi SemResposta', 'planilha'),
  ('f0000000-0000-0000-0000-0000000000d5', :tenant, 'Elisa OptOut', 'planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
SELECT :tenant, id, 'whatsapp', '+55 11 96000-000' || right(id::text, 1),
       '551196000000' || right(id::text, 1), 'planilha'
  FROM contacts WHERE tenant_id = :tenant;

-- ===========================================================================
-- 1. O funil nasce sozinho, e a semeadura é idempotente
-- ===========================================================================

SELECT fu.confere('antes de qualquer inscrição não há funil',
  NOT EXISTS (SELECT 1 FROM pipelines WHERE tenant_id = :tenant));

INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id) VALUES
  ('f0000000-0000-0000-0000-0000000000b1', :tenant, 'f0000000-0000-0000-0000-0000000000d1',
   'f0000000-0000-0000-0000-0000000000c1', 'f0000000-0000-0000-0000-0000000000e1');

SELECT fu.confere('inscrever semeia o funil sem ninguém ter configurado nada',
  (SELECT count(*) = 1 FROM pipelines WHERE tenant_id = :tenant AND padrao));

SELECT fu.confere('o funil padrão tem os seis estágios',
  (SELECT count(*) = 6 FROM pipeline_stages s JOIN pipelines p ON p.id = s.pipeline_id
    WHERE p.tenant_id = :tenant),
  (SELECT count(*)::text FROM pipeline_stages s JOIN pipelines p ON p.id = s.pipeline_id
    WHERE p.tenant_id = :tenant));

SELECT fu.confere('inscrever põe a pessoa em prospecção',
  fu.estagio('f0000000-0000-0000-0000-0000000000d1') = 'em_prospeccao',
  coalesce(fu.estagio('f0000000-0000-0000-0000-0000000000d1'), '(sem card)'));

-- Semear de novo não duplica: a nota da casa registra seed duplicado e seed
-- nunca chamado como armadilhas irmãs.
DO $$
DECLARE a uuid; b uuid;
BEGIN
  a := privado.semear_funil_padrao('f0000000-0000-0000-0000-0000000000a0');
  b := privado.semear_funil_padrao('f0000000-0000-0000-0000-0000000000a0');
  PERFORM fu.confere('semear duas vezes devolve o mesmo funil', a = b);
  PERFORM fu.confere('e não cria estágio repetido',
    (SELECT count(*) = 6 FROM pipeline_stages WHERE pipeline_id = a));
END;
$$;

-- ===========================================================================
-- 2. Cada fato do motor move o card
-- ===========================================================================

INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id) VALUES
  ('f0000000-0000-0000-0000-0000000000b2', :tenant, 'f0000000-0000-0000-0000-0000000000d2',
   'f0000000-0000-0000-0000-0000000000c1', 'f0000000-0000-0000-0000-0000000000e1'),
  ('f0000000-0000-0000-0000-0000000000b3', :tenant, 'f0000000-0000-0000-0000-0000000000d3',
   'f0000000-0000-0000-0000-0000000000c1', 'f0000000-0000-0000-0000-0000000000e1'),
  ('f0000000-0000-0000-0000-0000000000b4', :tenant, 'f0000000-0000-0000-0000-0000000000d4',
   'f0000000-0000-0000-0000-0000000000c1', 'f0000000-0000-0000-0000-0000000000e1'),
  ('f0000000-0000-0000-0000-0000000000b5', :tenant, 'f0000000-0000-0000-0000-0000000000d5',
   'f0000000-0000-0000-0000-0000000000c1', 'f0000000-0000-0000-0000-0000000000e1');

INSERT INTO messages (id, tenant_id, enrollment_id, step_id, contact_identity_id,
                      sender_account_id, canal, status, conteudo)
SELECT ('f0000000-0000-0000-0000-00000000aa0' || right(e.contact_id::text, 1))::uuid,
       :tenant, e.id, 'f0000000-0000-0000-0000-0000000000e2', ci.id,
       'f0000000-0000-0000-0000-00000000005a', 'whatsapp', 'pendente', 'oi'
  FROM enrollments e JOIN contact_identities ci ON ci.contact_id = e.contact_id
 WHERE e.tenant_id = :tenant AND e.contact_id <> 'f0000000-0000-0000-0000-0000000000d1';

-- Shadow mode não contata ninguém.
UPDATE messages SET status = 'simulado'
 WHERE id = 'f0000000-0000-0000-0000-00000000aa05';
SELECT fu.confere('mensagem em shadow mode NÃO marca como contatado',
  fu.estagio('f0000000-0000-0000-0000-0000000000d5') = 'em_prospeccao',
  fu.estagio('f0000000-0000-0000-0000-0000000000d5'));

UPDATE messages SET status = 'enviado'
 WHERE id IN ('f0000000-0000-0000-0000-00000000aa02','f0000000-0000-0000-0000-00000000aa03',
              'f0000000-0000-0000-0000-00000000aa04');

SELECT fu.confere('mensagem enviada de verdade marca como contatado',
  fu.estagio('f0000000-0000-0000-0000-0000000000d2') = 'contatado',
  fu.estagio('f0000000-0000-0000-0000-0000000000d2'));

-- Respondeu.
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
VALUES (:tenant, 'f0000000-0000-0000-0000-00000000aa03', 'respondido',
        '{"texto":"tenho interesse"}'::jsonb);

SELECT fu.confere('responder move para respondeu',
  fu.estagio('f0000000-0000-0000-0000-0000000000d3') = 'respondeu',
  fu.estagio('f0000000-0000-0000-0000-0000000000d3'));

-- Cadência acabou sem resposta.
SELECT privado.encerrar_enrollment('f0000000-0000-0000-0000-0000000000b4', 'fim_dos_passos');
SELECT fu.confere('fim dos passos sem resposta move para sem_resposta',
  fu.estagio('f0000000-0000-0000-0000-0000000000d4') = 'sem_resposta',
  fu.estagio('f0000000-0000-0000-0000-0000000000d4'));

-- E quem respondeu não volta atrás quando a cadência dele encerra.
SELECT fu.confere('quem respondeu continua em respondeu depois do encerramento',
  fu.estagio('f0000000-0000-0000-0000-0000000000d3') = 'respondeu',
  fu.estagio('f0000000-0000-0000-0000-0000000000d3'));

-- Pediu para sair.
INSERT INTO suppression (tenant_id, contact_id, motivo)
VALUES (:tenant, 'f0000000-0000-0000-0000-0000000000d5', 'opt_out por texto');
SELECT fu.confere('supressão move para opt_out',
  fu.estagio('f0000000-0000-0000-0000-0000000000d5') = 'opt_out',
  fu.estagio('f0000000-0000-0000-0000-0000000000d5'));

-- ===========================================================================
-- 3. Armadilha nº 3 da casa: novo ciclo precisa poder reabrir
-- ===========================================================================

INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados)
VALUES ('f0000000-0000-0000-0000-0000000000c2', :tenant, 'Segunda', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id)
VALUES (:tenant, 'f0000000-0000-0000-0000-0000000000d4',
        'f0000000-0000-0000-0000-0000000000c2', 'f0000000-0000-0000-0000-0000000000e1');

SELECT fu.confere('campanha nova reabre quem estava em sem_resposta',
  fu.estagio('f0000000-0000-0000-0000-0000000000d4') = 'em_prospeccao',
  fu.estagio('f0000000-0000-0000-0000-0000000000d4'));

-- Mas não reabre quem pediu para sair.
INSERT INTO enrollments (tenant_id, contact_id, campaign_id, flow_version_id)
VALUES (:tenant, 'f0000000-0000-0000-0000-0000000000d5',
        'f0000000-0000-0000-0000-0000000000c2', 'f0000000-0000-0000-0000-0000000000e1');
SELECT fu.confere('e NÃO reabre quem pediu para sair',
  fu.estagio('f0000000-0000-0000-0000-0000000000d5') = 'opt_out',
  fu.estagio('f0000000-0000-0000-0000-0000000000d5'));

-- ===========================================================================
-- 4. Armadilha nº 2 da casa: automação não desfaz ganho
-- ===========================================================================

-- Na pele do operador de verdade: `mover_deal` é SECURITY DEFINER e confere
-- `pode_operar` na mão, porque o RLS deixou de conferir por ela. Chamar como
-- 'pessoa' sem JWT é recusado — e foi o que a primeira versão deste teste
-- fez, provando a checagem por acidente.
BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"f0000000-0000-0000-0000-0000000000a2"}';

DO $$
DECLARE v_deal uuid; v_moveu boolean;
BEGIN
  SELECT id INTO v_deal FROM deals WHERE contact_id = 'f0000000-0000-0000-0000-0000000000d3';

  -- Uma pessoa marca como oportunidade.
  PERFORM fu.confere('pessoa marca oportunidade',
    mover_deal(v_deal, 'oportunidade', 'pessoa', 'quer proposta'));

  -- Agora o motor tenta empurrar para outro lugar — exatamente o caso real
  -- catalogado: o sentimento moveu para "Perdeu" uma conversa que tinha
  -- agendado reunião.
  v_moveu := mover_deal(v_deal, 'sem_resposta', 'motor', 'cadencia acabou');
  PERFORM fu.confere('automação NÃO tira o card de ganho', NOT v_moveu);
  PERFORM fu.confere('e o card continua em oportunidade',
    fu.estagio('f0000000-0000-0000-0000-0000000000d3') = 'oportunidade',
    fu.estagio('f0000000-0000-0000-0000-0000000000d3'));

  v_moveu := mover_deal(v_deal, 'opt_out', 'ia', 'classificador achou negativo');
  PERFORM fu.confere('nem a IA tira o card de ganho', NOT v_moveu);

  -- Pessoa desfaz, porque pessoa pode.
  PERFORM fu.confere('pessoa tira o card de ganho',
    mover_deal(v_deal, 'respondeu', 'pessoa', 'era engano'));
END;
$$;
COMMIT;

-- E quem não é do cliente não move card nenhum.
DO $$
DECLARE v_deal uuid; v_erro text;
BEGIN
  SELECT id INTO v_deal FROM deals WHERE contact_id = 'f0000000-0000-0000-0000-0000000000d3';
  BEGIN
    PERFORM mover_deal(v_deal, 'oportunidade', 'pessoa', 'sem JWT');
    v_erro := '(aceitou)';
  EXCEPTION WHEN insufficient_privilege THEN v_erro := 'recusou';
  END;
  PERFORM fu.confere('sem papel no cliente, mover como pessoa é recusado',
    v_erro = 'recusou', v_erro);
END;
$$;

-- ===========================================================================
-- 5. Armadilha nº 1 da casa: renomear o estágio não pode quebrar nada
-- ===========================================================================

UPDATE pipeline_stages SET nome = 'Lead Quente 🔥'
 WHERE slug = 'respondeu'
   AND pipeline_id = (SELECT id FROM pipelines WHERE tenant_id = :tenant AND padrao);

INSERT INTO contacts (id, tenant_id, nome, origem)
VALUES ('f0000000-0000-0000-0000-0000000000d6', :tenant, 'Fabio Renomeado', 'planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
VALUES (:tenant, 'f0000000-0000-0000-0000-0000000000d6', 'whatsapp',
        '+55 11 96000-0006', '5511960000006', 'planilha');
INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id)
VALUES ('f0000000-0000-0000-0000-0000000000b6', :tenant, 'f0000000-0000-0000-0000-0000000000d6',
        'f0000000-0000-0000-0000-0000000000c1', 'f0000000-0000-0000-0000-0000000000e1');
INSERT INTO messages (id, tenant_id, enrollment_id, step_id, contact_identity_id,
                      sender_account_id, canal, status, conteudo)
VALUES ('f0000000-0000-0000-0000-00000000aa06', :tenant, 'f0000000-0000-0000-0000-0000000000b6',
        'f0000000-0000-0000-0000-0000000000e2',
        (SELECT id FROM contact_identities WHERE contact_id = 'f0000000-0000-0000-0000-0000000000d6'),
        'f0000000-0000-0000-0000-00000000005a', 'whatsapp', 'pendente', 'oi');
UPDATE messages SET status = 'enviado' WHERE id = 'f0000000-0000-0000-0000-00000000aa06';
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
VALUES (:tenant, 'f0000000-0000-0000-0000-00000000aa06', 'respondido', '{"texto":"oi"}'::jsonb);

SELECT fu.confere('com o estágio renomeado, o motor continua achando pelo slug',
  fu.estagio('f0000000-0000-0000-0000-0000000000d6') = 'respondeu',
  fu.estagio('f0000000-0000-0000-0000-0000000000d6'));

-- ===========================================================================
-- 6. A porta única e a linha do tempo
-- ===========================================================================

SELECT fu.confere('cada movimento deixou atividade',
  (SELECT count(*) > 0 FROM deal_activities WHERE tenant_id = :tenant),
  (SELECT count(*)::text FROM deal_activities WHERE tenant_id = :tenant));

DO $$
DECLARE v_deal uuid; v_antes integer; v_moveu boolean;
BEGIN
  SELECT id INTO v_deal FROM deals WHERE contact_id = 'f0000000-0000-0000-0000-0000000000d2';
  SELECT count(*) INTO v_antes FROM deal_activities WHERE deal_id = v_deal;

  -- Mover para onde já está não é movimento: senão o gatilho de mensagem
  -- encheria a linha do tempo a cada toque da cadência.
  v_moveu := mover_deal(v_deal, 'contatado', 'motor', 'de novo');
  PERFORM fu.confere('mover para o mesmo estágio é no-op', NOT v_moveu);
  PERFORM fu.confere('e não grava atividade de ruído',
    (SELECT count(*) = v_antes FROM deal_activities WHERE deal_id = v_deal));
END;
$$;

DO $$
DECLARE v_erro text;
BEGIN
  BEGIN
    -- Como 'motor': a checagem de permissão de 'pessoa' roda ANTES da busca
    -- do estágio, e estouraria por outro motivo — o teste ficaria verde pela
    -- razão errada.
    PERFORM mover_deal((SELECT id FROM deals WHERE contact_id = 'f0000000-0000-0000-0000-0000000000d2'),
                       'estagio_que_nao_existe', 'motor', NULL);
    v_erro := '(aceitou)';
  EXCEPTION WHEN no_data_found THEN v_erro := 'recusou';
  END;
  PERFORM fu.confere('estágio inexistente é recusado', v_erro = 'recusou', v_erro);

  BEGIN
    UPDATE deal_activities SET motivo = 'reescrito' WHERE tenant_id = 'f0000000-0000-0000-0000-0000000000a0';
    v_erro := '(editou)';
  EXCEPTION WHEN restrict_violation THEN v_erro := 'recusou';
  END;
  PERFORM fu.confere('a linha do tempo do card é append-only', v_erro = 'recusou', v_erro);
END;
$$;

-- ===========================================================================
-- 7. A porta é única de verdade: o cliente não tem UPDATE em deals
-- ===========================================================================

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"f0000000-0000-0000-0000-0000000000a2"}';

  SELECT fu.confere('operador vê os cards do cliente',
    (SELECT count(*) > 0 FROM deals));
COMMIT;

BEGIN;
  SET LOCAL role authenticated;
  SET LOCAL request.jwt.claims = '{"sub":"f0000000-0000-0000-0000-0000000000a2"}';
DO $$
DECLARE v_estado text;
BEGIN
  -- Se isto passasse, "porta única" seria convenção — e convenção é o que o
  -- D54 inteiro existe para não ser.
  BEGIN
    UPDATE deals SET stage_id = stage_id;
    v_estado := 'sem erro';
  EXCEPTION WHEN insufficient_privilege THEN v_estado := '42501';
            WHEN others THEN v_estado := SQLSTATE;
  END;
  PERFORM fu.confere('UPDATE direto em deals é recusado por privilégio',
    v_estado = '42501', v_estado);
END;
$$;
COMMIT;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM fu.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM fu.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM fu.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'funil: % asserção(ões) falharam', n; END IF;
END;
$$;
