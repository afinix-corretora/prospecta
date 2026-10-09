-- A campanha passa a apontar o seu flow (D47).
--
-- Até aqui, `campaigns` e `flow_versions` só se encontravam dentro de
-- `enrollments`. A consequência aparecia na tela: para inscrever alguem, o
-- operador escolhia a versao de flow numa lista de TODAS as versoes do
-- cliente, e a tela mostrava os canais dos dois lados para ele mesmo reparar
-- se cruzavam. Isso e contorno, nao solucao — e o erro que ele evita e
-- silencioso, que e o pior tipo: flow de e-mail numa campanha so de WhatsApp
-- nao da erro nenhum, o motor pula passo a passo e encerra como concluido
-- sem mandar nada (D35).
--
-- A pergunta "qual flow esta campanha roda" e da CAMPANHA, nao de cada
-- inscricao. Perguntar a cada inscricao e perguntar N vezes uma coisa que
-- muda uma vez — e cada repeticao e uma chance de responder diferente.
--
-- Tres decisoes embutidas aqui:
--
-- 1. A coluna e NULL-avel. Campanha existe antes do flow estar escrito, e
--    `criar_campanha_de_modelo` cria a campanha e o flow em sequencia. Exigir
--    a ligacao no INSERT inverteria essa ordem sem ganho.
--
-- 2. Apontar e um ATO, com funcao propria, porque e ali que a conferencia
--    cabe. Cruzar os canais uma vez, quando se liga, vale mais do que cruzar
--    a cada inscricao: e a mesma resposta, e no momento em que quem configura
--    ainda esta olhando para a tela de configuracao.
--
-- 3. Repontar a campanha NAO move quem ja esta inscrito. `enrollments` carrega
--    o seu proprio `flow_version_id` desde a primeira migration, e e ele que
--    o agendador le. Publicar versao nova segue sendo o que o D9 diz: quem
--    esta em curso termina na versao em que entrou.
--
-- Sem barra invertida (D32).

ALTER TABLE campaigns ADD COLUMN flow_version_id uuid;

-- Composta, como toda FK entre tabelas de dominio (D18): sem o tenant no par,
-- uma campanha poderia apontar o flow de outro cliente.
--
-- Sem ON DELETE: `flow_versions` e imutavel por gatilho (D9), entao apagar uma
-- versao ja falha antes de a FK opinar, e qualquer clausula aqui seria codigo
-- inalcancavel. RESTRICT, que e o padrao, e o unico que diz a verdade se a
-- imutabilidade um dia cair; `SET NULL` desapontaria a campanha em silencio,
-- que e a resposta errada para uma pergunta que nao deveria existir.
ALTER TABLE campaigns
  ADD CONSTRAINT campaigns_flow_version_tenant_fkey
  FOREIGN KEY (tenant_id, flow_version_id)
  REFERENCES flow_versions (tenant_id, id);

COMMENT ON COLUMN campaigns.flow_version_id IS
  'A versao de flow que esta campanha roda hoje. NULL = ainda nao ligada.
   Repontar nao move enrollments em curso: eles carregam a propria versao (D47).';

-- ---------------------------------------------------------------------------
-- Ligar a campanha ao flow
-- ---------------------------------------------------------------------------

CREATE FUNCTION definir_flow_da_campanha(
  p_campaign_id     uuid,
  p_flow_version_id uuid
) RETURNS void
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE
  v_canais_campanha canal[];
  v_canais_flow     canal[];
  v_cruzam          canal[];
BEGIN
  SELECT canais_habilitados INTO v_canais_campanha
    FROM campaigns WHERE id = p_campaign_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'campanha inexistente: %', p_campaign_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Desligar e legitimo: campanha pode voltar a nao ter flow.
  IF p_flow_version_id IS NULL THEN
    UPDATE campaigns SET flow_version_id = NULL WHERE id = p_campaign_id;
    RETURN;
  END IF;

  SELECT coalesce(array_agg(DISTINCT fs.canal), '{}'::canal[]) INTO v_canais_flow
    FROM flow_steps fs WHERE fs.flow_version_id = p_flow_version_id;

  -- Flow sem passo nenhum e uma campanha que nunca mandaria nada. Recusar
  -- aqui e barato; descobrir depois custa uma campanha inteira "concluida"
  -- sem uma mensagem sequer.
  IF cardinality(v_canais_flow) = 0 THEN
    RAISE EXCEPTION 'versao de flow % nao tem passo nenhum', p_flow_version_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT coalesce(array_agg(c), '{}'::canal[]) INTO v_cruzam
    FROM unnest(v_canais_flow) c WHERE c = ANY (v_canais_campanha);

  -- O silencio do D35, pego na configuracao em vez de na inscricao. Cruzar
  -- PARCIALMENTE e permitido de proposito: o D4 ja manda pular o passo cujo
  -- canal a campanha nao habilita, e um flow multicanal numa campanha de um
  -- canal so e uso legitimo. O que nao pode e a intersecao VAZIA, porque ai
  -- todo passo seria pulado e o enrollment encerraria sem tocar ninguem.
  IF cardinality(v_cruzam) = 0 THEN
    RAISE EXCEPTION
      'nenhum canal em comum: o flow usa % e a campanha habilita %',
      v_canais_flow, v_canais_campanha
      USING ERRCODE = 'invalid_parameter_value',
            HINT = 'habilite o canal na campanha ou escolha outra versao de flow';
  END IF;

  -- A FK composta e quem garante que a versao e do mesmo cliente.
  UPDATE campaigns SET flow_version_id = p_flow_version_id
   WHERE id = p_campaign_id;
END;
$$;

COMMENT ON FUNCTION definir_flow_da_campanha IS
  'Liga a campanha a uma versao de flow, recusando o par que nao cruza canal
   nenhum — que e o D35 pego na configuracao e nao na inscricao (D47).';

-- ---------------------------------------------------------------------------
-- Inscrever sem escolher versao
-- ---------------------------------------------------------------------------

-- Nome proprio, e nao sobrecarga de `inscrever`: com `inscrever(uuid, uuid,
-- uuid, timestamptz DEFAULT)` ja existindo, uma forma de tres argumentos
-- resolveria por tipo, e `inscrever(a, b, NULL)` ficaria ambiguo. A forma
-- explicita continua existindo para quem precisa fixar a versao — backfill e
-- reinscricao numa versao antiga.
CREATE FUNCTION inscrever_pela_campanha(
  p_contact_id  uuid,
  p_campaign_id uuid,
  p_quando      timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE v_versao uuid; v_achou boolean;
BEGIN
  SELECT flow_version_id, true INTO v_versao, v_achou
    FROM campaigns WHERE id = p_campaign_id;

  IF NOT coalesce(v_achou, false) THEN
    RAISE EXCEPTION 'campanha inexistente: %', p_campaign_id
      USING ERRCODE = 'no_data_found';
  END IF;

  -- Nao e esta checagem que impede o estrago: `enrollments.flow_version_id` e
  -- NOT NULL, entao sem ela a insercao ja falharia. O que ela acrescenta e a
  -- recusa LEGIVEL — sem ela o operador recebe um `not_null_violation` citando
  -- uma coluna interna, que nao diz o que fazer. A diferenca entre um erro que
  -- ensina e um que so interrompe e o produto inteiro.
  IF v_versao IS NULL THEN
    RAISE EXCEPTION 'campanha % nao tem versao de flow definida', p_campaign_id
      USING ERRCODE = 'invalid_parameter_value',
            HINT = 'chame definir_flow_da_campanha antes de inscrever';
  END IF;

  RETURN inscrever(p_contact_id, p_campaign_id, v_versao, p_quando);
END;
$$;

COMMENT ON FUNCTION inscrever_pela_campanha IS
  'Inscreve usando a versao de flow da propria campanha. Recusa alto quando a
   campanha nao tem flow, em vez de criar enrollment que encerra vazio (D47).';

-- ---------------------------------------------------------------------------
-- Prever, pelo mesmo caminho
-- ---------------------------------------------------------------------------

CREATE FUNCTION prever_inscricao_pela_campanha(
  p_tenant      uuid,
  p_campaign_id uuid,
  p_contatos    uuid[]
)
RETURNS TABLE (
  contact_id         uuid,
  nome               text,
  acao               text,
  canais_alcancaveis canal[],
  problema           text
)
LANGUAGE plpgsql STABLE SET search_path = public, privado AS $$
DECLARE v_versao uuid;
BEGIN
  SELECT c.flow_version_id INTO v_versao
    FROM campaigns c WHERE c.tenant_id = p_tenant AND c.id = p_campaign_id;

  -- Campanha sem flow nao devolve lista vazia: devolve uma linha por contato
  -- dizendo por que nao daria. Lista vazia numa previa se le como "nada a
  -- objetar", que e o oposto do que esta acontecendo.
  IF v_versao IS NULL THEN
    RETURN QUERY
    SELECT ct.id, ct.nome, 'nao_inscrever'::text, '{}'::canal[],
           'a campanha ainda nao tem versao de flow definida'::text
      FROM contacts ct
     WHERE ct.tenant_id = p_tenant
       AND ct.id = ANY (coalesce(p_contatos, '{}'::uuid[]));
    RETURN;
  END IF;

  RETURN QUERY
  SELECT * FROM prever_inscricao(p_tenant, p_campaign_id, v_versao, p_contatos);
END;
$$;

COMMENT ON FUNCTION prever_inscricao_pela_campanha IS
  'Previa usando a versao de flow da campanha. Sem flow, devolve uma linha por
   contato explicando — previa vazia se le como "nada a objetar" (D47).';

-- ---------------------------------------------------------------------------
-- Superficie (D19)
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.definir_flow_da_campanha(uuid, uuid)',
    'public.inscrever_pela_campanha(uuid, uuid, timestamptz)',
    'public.prever_inscricao_pela_campanha(uuid, uuid, uuid[])'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    FOREACH papel IN ARRAY ARRAY['service_role','postgres','authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
