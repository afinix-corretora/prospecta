-- Quem move o card, e por quê (D57).
--
-- A nota `Padrão - Kanban e Pipeline` da base da casa é explícita sobre a
-- porta única: `move_deal(deal, stage, source, reason)` grava a atividade,
-- carimba a entrada no estágio e aplica a precedência. Aqui ela é levada a
-- sério de verdade — `mover_deal` é `SECURITY DEFINER` e o D54 tira o UPDATE
-- de `deals` do papel `authenticated`. Não é convenção: **não existe** outro
-- caminho.
--
-- Por que DEFINER, sendo que o D41 manda não repetir o que o RLS já diz: ela
-- não repete a política — ela impõe o que a política não sabe expressar (a
-- atividade gravada e a regra de ganho/perdido). E, por ser DEFINER, confere
-- `pode_operar` na mão, porque o RLS deixa de conferir por ela.
--
-- A regra de precedência veio de um caso real catalogado: num projeto
-- anterior, a análise de sentimento moveu para "Perdeu" uma conversa que
-- tinha acabado de agendar reunião. Então: **pessoa move de onde quiser;
-- automação nunca tira de `ganho` nem de `perdido`.**
--
-- Os estágios do funil de prospecção saem do que o motor já sabe, e cada um
-- corresponde a um fato que ele produz:
--
--   em_prospeccao  inscrito, nada saiu ainda
--   contatado      pelo menos uma mensagem saiu de verdade (não `simulado`)
--   respondeu      chegou resposta (invariante 4 encerrou a cadência)
--   sem_resposta   a cadência acabou nos passos e ninguém respondeu
--   oportunidade   GANHO — resposta positiva. Nenhuma automação escreve isto
--                  ainda: quem escreve é o classificador, que vem depois
--   opt_out        PERDIDO — pediu para sair
--
-- `oportunidade` nasce sem produtor de propósito, e isso está escrito aqui
-- para não virar o `tem_adapter` do D31: a tela vai mostrar a coluna vazia e
-- dizer que só pessoa a preenche, até o classificador existir.
--
-- `sem_resposta` é `aberto`, não `perdido`, e a escolha é deliberada: a nota
-- da casa registra "guarda de reativação por contato impede novo ciclo" como
-- armadilha conhecida. Sendo aberto, inscrever a pessoa numa campanha nova a
-- traz de volta para `em_prospeccao` sem exceção nenhuma na regra.
--
-- Sem barra invertida (D32).
-- Reversível: supabase/down/20260925220000_mover_o_card.down.sql

-- ---------------------------------------------------------------------------
-- O funil padrão, semeado uma vez por cliente
-- ---------------------------------------------------------------------------

CREATE FUNCTION privado.semear_funil_padrao(p_tenant uuid)
RETURNS uuid
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog AS $$
DECLARE v_pipeline uuid;
BEGIN
  SELECT id INTO v_pipeline FROM pipelines
   WHERE tenant_id = p_tenant AND slug = 'prospeccao';
  IF FOUND THEN RETURN v_pipeline; END IF;

  INSERT INTO pipelines (tenant_id, nome, slug, padrao)
  VALUES (p_tenant, 'Prospecção', 'prospeccao', true)
  RETURNING id INTO v_pipeline;

  INSERT INTO pipeline_stages (tenant_id, pipeline_id, nome, slug, posicao, cor, tipo) VALUES
    (p_tenant, v_pipeline, 'Em prospecção', 'em_prospeccao', 1, '#6B7DE8', 'aberto'),
    (p_tenant, v_pipeline, 'Contatado',     'contatado',     2, '#4FA3D1', 'aberto'),
    (p_tenant, v_pipeline, 'Respondeu',     'respondeu',     3, '#E0B458', 'aberto'),
    (p_tenant, v_pipeline, 'Sem resposta',  'sem_resposta',  4, '#8A8F98', 'aberto'),
    (p_tenant, v_pipeline, 'Oportunidade',  'oportunidade',  5, '#0E9C64', 'ganho'),
    (p_tenant, v_pipeline, 'Pediu para sair', 'opt_out',     6, '#B43A2C', 'perdido');

  RETURN v_pipeline;
END;
$$;

COMMENT ON FUNCTION privado.semear_funil_padrao(uuid) IS
  'Cria o funil de prospecção do cliente, uma vez. Idempotente por slug — a
   nota da casa registra "seed definido e nunca chamado" como armadilha (D57).';

-- ---------------------------------------------------------------------------
-- A porta única
-- ---------------------------------------------------------------------------

CREATE FUNCTION mover_deal(
  p_deal_id    uuid,
  p_stage_slug text,
  p_origem     origem_movimento DEFAULT 'pessoa',
  p_motivo     text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado, pg_catalog AS $$
DECLARE
  d        deals%ROWTYPE;
  v_tipo   tipo_estagio;
  v_destino uuid;
BEGIN
  SELECT * INTO d FROM deals WHERE id = p_deal_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'card inexistente: %', p_deal_id USING ERRCODE = 'no_data_found';
  END IF;

  -- DEFINER não passa pelo RLS, então a autorização é conferida aqui. Pessoa
  -- precisa de `pode_operar`; o motor e a IA chamam por dentro, sem JWT.
  IF p_origem = 'pessoa' AND NOT privado.pode_operar(d.tenant_id) THEN
    RAISE EXCEPTION 'sem permissão para mover card deste cliente'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT id INTO v_destino FROM pipeline_stages
   WHERE pipeline_id = d.pipeline_id AND slug = p_stage_slug;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'estágio % não existe neste funil', p_stage_slug
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Mover para onde já está não é movimento: não grava atividade, para a
  -- linha do tempo não encher de ruído do gatilho que roda a cada mensagem.
  IF v_destino = d.stage_id THEN RETURN false; END IF;

  SELECT tipo INTO v_tipo FROM pipeline_stages WHERE id = d.stage_id;

  -- A regra que vem do caso real: automação nunca tira de ganho nem de
  -- perdido. Só pessoa desfaz um "oportunidade" ou um "pediu para sair".
  IF p_origem <> 'pessoa' AND v_tipo IN ('ganho', 'perdido') THEN
    RETURN false;
  END IF;

  UPDATE deals
     SET stage_id = v_destino,
         entrou_no_estagio_em = now(),
         movido_por = p_origem,
         motivo = p_motivo
   WHERE id = d.id;

  INSERT INTO deal_activities (tenant_id, deal_id, de_stage_id, para_stage_id, origem, motivo)
  VALUES (d.tenant_id, d.id, d.stage_id, v_destino, p_origem, p_motivo);

  RETURN true;
END;
$$;

COMMENT ON FUNCTION mover_deal(uuid, text, origem_movimento, text) IS
  'A única porta para mover um card. Grava a atividade e recusa que automação
   tire de ganho ou perdido — pessoa move de onde quiser (D57).';

-- ---------------------------------------------------------------------------
-- O que o motor escreve
-- ---------------------------------------------------------------------------

-- Garante o card da pessoa e devolve o id. Cria no primeiro estágio `aberto`
-- do funil padrão. Se o cliente não tem funil ainda, semeia — assim o Kanban
-- não depende de alguém ter clicado em nada antes.
CREATE FUNCTION privado.garantir_deal(
  p_tenant uuid, p_contact_id uuid, p_campaign_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog AS $$
DECLARE v_pipeline uuid; v_stage uuid; v_deal uuid;
BEGIN
  SELECT id INTO v_pipeline FROM pipelines WHERE tenant_id = p_tenant AND padrao;
  IF NOT FOUND THEN v_pipeline := privado.semear_funil_padrao(p_tenant); END IF;

  SELECT id INTO v_deal FROM deals
   WHERE tenant_id = p_tenant AND contact_id = p_contact_id AND pipeline_id = v_pipeline;
  IF FOUND THEN RETURN v_deal; END IF;

  SELECT id INTO v_stage FROM pipeline_stages
   WHERE pipeline_id = v_pipeline AND tipo = 'aberto'
   ORDER BY posicao LIMIT 1;
  -- Funil sem estágio aberto é configuração quebrada, e não é hora de
  -- estourar: a nota da casa registra o trigger que só avisa em vez de
  -- derrubar o INSERT do contato.
  IF NOT FOUND THEN
    RAISE NOTICE 'funil do cliente % nao tem estagio aberto; card nao criado', p_tenant;
    RETURN NULL;
  END IF;

  INSERT INTO deals (tenant_id, contact_id, pipeline_id, stage_id, campaign_id, movido_por)
  VALUES (p_tenant, p_contact_id, v_pipeline, v_stage, p_campaign_id, 'motor')
  ON CONFLICT (tenant_id, contact_id, pipeline_id) DO NOTHING
  RETURNING id INTO v_deal;

  IF v_deal IS NULL THEN
    SELECT id INTO v_deal FROM deals
     WHERE tenant_id = p_tenant AND contact_id = p_contact_id AND pipeline_id = v_pipeline;
  END IF;

  RETURN v_deal;
END;
$$;

-- Move o card da pessoa, mas só se ele estiver num dos estágios que o fato
-- reconhece. É o que torna cada gatilho idempotente e o que impede que a
-- mensagem número 40 de uma cadência puxe o card de volta para `contatado`.
CREATE FUNCTION privado.avancar_deal(
  p_tenant     uuid,
  p_contact_id uuid,
  p_slug       text,
  p_motivo     text,
  p_de_slugs   text[]
) RETURNS void
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog AS $$
DECLARE v_deal uuid; v_atual text;
BEGIN
  SELECT d.id, s.slug INTO v_deal, v_atual
    FROM deals d JOIN pipeline_stages s ON s.id = d.stage_id
   WHERE d.tenant_id = p_tenant AND d.contact_id = p_contact_id
     AND d.pipeline_id = (SELECT id FROM pipelines WHERE tenant_id = p_tenant AND padrao);
  IF NOT FOUND THEN RETURN; END IF;

  IF NOT (v_atual = ANY (p_de_slugs)) THEN RETURN; END IF;

  PERFORM mover_deal(v_deal, p_slug, 'motor', p_motivo);
END;
$$;

-- --- Inscreveu: entra no funil ---------------------------------------------

CREATE FUNCTION privado.funil_na_inscricao() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado, pg_catalog AS $$
BEGIN
  PERFORM privado.garantir_deal(NEW.tenant_id, NEW.contact_id, NEW.campaign_id);
  -- Quem já tinha card e estava em `sem_resposta` volta para prospecção: é
  -- uma campanha nova, não o mesmo ciclo. `ganho` e `perdido` ficam onde
  -- estão, porque `mover_deal` recusa automação em cima deles.
  PERFORM privado.avancar_deal(NEW.tenant_id, NEW.contact_id, 'em_prospeccao',
                               'inscrito em campanha', ARRAY['sem_resposta']);
  RETURN NEW;
END;
$$;

CREATE TRIGGER enrollments_funil
  AFTER INSERT ON enrollments
  FOR EACH ROW EXECUTE FUNCTION privado.funil_na_inscricao();

-- --- Saiu mensagem de verdade: contatado ------------------------------------

CREATE FUNCTION privado.funil_no_envio() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado, pg_catalog AS $$
DECLARE v_contact uuid;
BEGIN
  -- `simulado` não conta: em shadow mode ninguém foi contatado. É a mesma
  -- distinção que a tela da campanha faz desde o D36.
  IF NEW.status <> 'enviado' OR OLD.status = 'enviado' THEN RETURN NEW; END IF;

  SELECT contact_id INTO v_contact FROM enrollments WHERE id = NEW.enrollment_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  PERFORM privado.avancar_deal(NEW.tenant_id, v_contact, 'contatado',
                               'mensagem enviada', ARRAY['em_prospeccao']);
  RETURN NEW;
END;
$$;

CREATE TRIGGER messages_funil
  AFTER UPDATE OF status ON messages
  FOR EACH ROW EXECUTE FUNCTION privado.funil_no_envio();

-- --- Respondeu --------------------------------------------------------------

CREATE FUNCTION privado.funil_na_resposta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado, pg_catalog AS $$
DECLARE v_contact uuid;
BEGIN
  IF NEW.tipo <> 'respondido' THEN RETURN NEW; END IF;

  SELECT e.contact_id INTO v_contact
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = NEW.message_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  -- De `sem_resposta` também: a pessoa pode responder depois de a cadência
  -- ter acabado, e aí ela respondeu.
  PERFORM privado.avancar_deal(NEW.tenant_id, v_contact, 'respondeu',
                               'respondeu',
                               ARRAY['em_prospeccao','contatado','sem_resposta']);
  RETURN NEW;
END;
$$;

CREATE TRIGGER message_events_funil
  AFTER INSERT ON message_events
  FOR EACH ROW EXECUTE FUNCTION privado.funil_na_resposta();

-- --- A cadência acabou sem resposta ------------------------------------------

CREATE FUNCTION privado.funil_no_encerramento() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado, pg_catalog AS $$
BEGIN
  IF NEW.status <> 'encerrado' OR OLD.status = 'encerrado' THEN RETURN NEW; END IF;
  IF NEW.motivo_encerramento <> 'fim_dos_passos' THEN RETURN NEW; END IF;

  -- Só quem ainda não respondeu. Quem encerrou por `fim_dos_passos` estando
  -- em `respondeu` continua em `respondeu` — o fim dos passos não desfaz o
  -- que a pessoa disse.
  PERFORM privado.avancar_deal(NEW.tenant_id, NEW.contact_id, 'sem_resposta',
                               'cadência terminou sem resposta',
                               ARRAY['em_prospeccao','contatado']);
  RETURN NEW;
END;
$$;

CREATE TRIGGER enrollments_funil_encerramento
  AFTER UPDATE OF status ON enrollments
  FOR EACH ROW EXECUTE FUNCTION privado.funil_no_encerramento();

-- --- Pediu para sair ---------------------------------------------------------

CREATE FUNCTION privado.funil_na_supressao() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado, pg_catalog AS $$
DECLARE v_deal uuid;
BEGIN
  -- Supressão de identidade sem contato não diz quem é a pessoa.
  IF NEW.contact_id IS NULL THEN RETURN NEW; END IF;

  SELECT d.id INTO v_deal FROM deals d
   WHERE d.tenant_id = NEW.tenant_id AND d.contact_id = NEW.contact_id
     AND d.pipeline_id = (SELECT id FROM pipelines WHERE tenant_id = NEW.tenant_id AND padrao);
  IF NOT FOUND THEN RETURN NEW; END IF;

  -- Sem lista de origem: pedir para sair vale de qualquer estágio aberto. E
  -- `mover_deal` continua recusando tirar de `ganho` — quem virou
  -- oportunidade e depois pediu para sair é decisão de gente, não de gatilho.
  PERFORM mover_deal(v_deal, 'opt_out', 'motor', NEW.motivo);
  RETURN NEW;
END;
$$;

CREATE TRIGGER suppression_funil
  AFTER INSERT ON suppression
  FOR EACH ROW EXECUTE FUNCTION privado.funil_na_supressao();

-- ---------------------------------------------------------------------------
-- Superfície (D19) e a grade de escrita (D54)
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; alvo text := 'public.mover_deal(uuid, text, origem_movimento, text)';
BEGIN
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
  FOREACH papel IN ARRAY ARRAY['service_role','postgres','authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
    END IF;
  END LOOP;
END;
$$;

-- `deals` deixa de aceitar UPDATE direto: a porta é `mover_deal`. Sem isto,
-- "porta única" seria convenção, e convenção é o que o D54 inteiro existe
-- para não ser.
CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
RETURNS void
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id) ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;

  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;

  -- O funil: renomear e reordenar estágio é da tela; mover card é da função.
  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;
END;
$$;

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
