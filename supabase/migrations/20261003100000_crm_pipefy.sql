-- O CRM deixa de ser lugar nenhum (D64).
--
-- Desde o D45 o motor descobre quatro fatos e os enfileira na `outbox`; desde
-- o D46 há quem drene; desde o D59 o cliente vincula a plataforma dele. O que
-- faltava era o meio: o que, NESTE CRM, um fato significa. "Respondeu" no
-- Pipefy de um cliente é mover o card para "Em conversa"; no de outro, é
-- preencher o campo "Status SDR". O motor não sabe e não deve saber — quem
-- sabe é quem configura, e a configuração mora aqui.
--
-- Quatro tabelas, e cada uma responde uma pergunta:
--
--   crm_vinculos    qual card É esta pessoa nesta plataforma. Sem vínculo não
--                   há onde escrever; inventar um (buscar card por telefone)
--                   seria escrever no card de outra pessoa com o mesmo número.
--   crm_estruturas  o que a plataforma TEM — pipes, fases, campos — lido por
--                   descoberta e guardado, para a tela oferecer escolhas em vez
--                   de pedir ids digitados à mão.
--   crm_acoes       o que cada fato FAZ, por pipe: mover de fase e preencher
--                   campo. Comentário e criação de card ficam de fora: os dois
--                   não são idempotentes, e o dreno repete em caso de falha.
--   crm_fontes      de onde vêm contatos: pipe, fases e qual campo é qual
--                   papel (telefone, e-mail, nome). Opcionalmente, em que
--                   campanha quem entra é inscrito.
--
-- E duas mudanças no dreno:
--
--   1. `reivindicar_writebacks` só pega fato de quem tem plataforma ligada que
--      SABE receber (`tem_adapter`). Antes pegava de todos — e sem destino o
--      worker queimaria as oito tentativas e mandaria para `falha` um fato que
--      só estava esperando o cliente vincular o CRM. A tela do D46 já chama
--      isso de "nunca saiu", que é exatamente o estado certo.
--   2. `outbox.resultado` diz o que o dreno FEZ. "Enviado" sozinho não separa
--      "movi o card" de "não havia card": os dois tiram o fato da fila, só um
--      escreveu no CRM.
--
-- `tem_adapter` do Pipefy NÃO muda aqui. Vira verdadeiro numa migration
-- separada, depois que o worker que sabe falar com ele estiver publicado e
-- conferido — antes disso o catálogo prometeria um envio que o worker não
-- faria, que é o D31.
--
-- Sem barra invertida (D32).
-- Reversível: supabase/down/20261003100000_crm_pipefy.down.sql

-- ---------------------------------------------------------------------------
-- Vínculo: a pessoa e o card
-- ---------------------------------------------------------------------------

CREATE TABLE crm_vinculos (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  conexao_id   uuid NOT NULL,
  contact_id   uuid NOT NULL,
  -- O pipe é o escopo das ações: "mover para Em conversa" só existe dentro de
  -- um pipe, e o mesmo contato pode ter card em dois.
  pipe_id      text NOT NULL,
  ref_externa  text NOT NULL,
  criado_em    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crm_vinculos_tenant_id_uk UNIQUE (tenant_id, id),
  -- Um card é de uma pessoa só. O contrário (uma pessoa, dois cards no mesmo
  -- pipe) é o card duplicado que todo CRM tem; o primeiro vínculo vale e o
  -- segundo é recusado em vez de escrever nos dois.
  CONSTRAINT crm_vinculos_ref_uk UNIQUE (tenant_id, conexao_id, ref_externa),
  CONSTRAINT crm_vinculos_pessoa_uk UNIQUE (tenant_id, conexao_id, pipe_id, contact_id),
  CONSTRAINT crm_vinculos_conexao_fkey FOREIGN KEY (tenant_id, conexao_id)
    REFERENCES crm_connections (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT crm_vinculos_contato_fkey FOREIGN KEY (tenant_id, contact_id)
    REFERENCES contacts (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX crm_vinculos_contato_idx ON crm_vinculos (tenant_id, contact_id);

ALTER TABLE crm_vinculos ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_vinculos FORCE ROW LEVEL SECURITY;
CREATE POLICY crm_vinculos_sel ON crm_vinculos FOR SELECT
  USING (privado.pertence_ao_tenant(tenant_id));

-- ---------------------------------------------------------------------------
-- Estrutura descoberta
-- ---------------------------------------------------------------------------

CREATE TABLE crm_estruturas (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  conexao_id     uuid NOT NULL,
  -- O que a plataforma devolveu, já traduzido para a forma de `adapters/`:
  -- {"pipes":[{"id","nome","fases":[{"id","nome","campos":[...]}],"campos_iniciais":[...]}]}
  estrutura      jsonb,
  descoberto_em  timestamptz NOT NULL DEFAULT now(),
  -- Descoberta que falhou também é fato: credencial errada aparece aqui, e
  -- não como tela vazia que parece "o pipe não tem campos".
  erro           text,
  CONSTRAINT crm_estruturas_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT crm_estruturas_conexao_uk UNIQUE (tenant_id, conexao_id),
  CONSTRAINT crm_estruturas_conexao_fkey FOREIGN KEY (tenant_id, conexao_id)
    REFERENCES crm_connections (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT crm_estruturas_algo CHECK (estrutura IS NOT NULL OR erro IS NOT NULL)
);

ALTER TABLE crm_estruturas ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_estruturas FORCE ROW LEVEL SECURITY;
CREATE POLICY crm_estruturas_sel ON crm_estruturas FOR SELECT
  USING (privado.pode_administrar(tenant_id));

-- ---------------------------------------------------------------------------
-- O que cada fato faz
-- ---------------------------------------------------------------------------

CREATE TABLE crm_acoes (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  conexao_id  uuid NOT NULL,
  pipe_id     text NOT NULL,
  fato        fato_writeback NOT NULL,
  tipo        text NOT NULL CHECK (tipo IN ('mover_fase', 'preencher_campo')),
  -- Fase de destino (mover) ou campo (preencher). O id é o que a API pede; o
  -- rótulo é o que a tela mostra, guardado para a lista continuar legível se
  -- a descoberta ficar velha.
  alvo_id     text NOT NULL,
  alvo_rotulo text,
  -- Só para preencher: o texto, com as mesmas chaves da cadência
  -- (`{{nome}}`, `{{resposta}}`, `{{data}}`...).
  valor       text,
  ordem       integer NOT NULL DEFAULT 0,
  ativo       boolean NOT NULL DEFAULT true,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crm_acoes_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT crm_acoes_conexao_fkey FOREIGN KEY (tenant_id, conexao_id)
    REFERENCES crm_connections (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT crm_acoes_valor CHECK (
    (tipo = 'mover_fase' AND valor IS NULL)
    OR (tipo = 'preencher_campo' AND valor IS NOT NULL)),
  CONSTRAINT crm_acoes_alvo_nao_vazio CHECK (length(trim(alvo_id)) > 0)
);
CREATE INDEX crm_acoes_tenant_idx ON crm_acoes (tenant_id, conexao_id, fato);

-- Duas fases de destino para o mesmo fato é a pergunta "onde o card fica?"
-- com duas respostas. A segunda venceria pela ordem e a primeira seria
-- decoração.
CREATE UNIQUE INDEX crm_acoes_um_destino_uk ON crm_acoes (tenant_id, conexao_id, pipe_id, fato)
  WHERE tipo = 'mover_fase' AND ativo;

ALTER TABLE crm_acoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_acoes FORCE ROW LEVEL SECURITY;
CREATE POLICY crm_acoes_sel ON crm_acoes FOR SELECT
  USING (privado.pode_administrar(tenant_id));
CREATE POLICY crm_acoes_todos ON crm_acoes FOR ALL
  USING (privado.pode_administrar(tenant_id))
  WITH CHECK (privado.pode_administrar(tenant_id));

-- ---------------------------------------------------------------------------
-- Fonte: de onde vêm contatos
-- ---------------------------------------------------------------------------

CREATE TABLE crm_fontes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  conexao_id        uuid NOT NULL,
  nome              text NOT NULL,
  pipe_id           text NOT NULL,
  pipe_rotulo       text,
  fases             text[] NOT NULL,
  -- {"<id do campo>": "<papel>"}. Papel é o mesmo vocabulário de
  -- `adapters/leitura.ts`, que é quem decide o que cada valor vira — aqui
  -- só se confere que o papel existe.
  mapa              jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Quem entra é inscrito aqui. NULL = só importa; inscrever fica para a tela
  -- de contatos, com a prévia de sempre.
  campaign_id       uuid,
  intervalo_minutos integer NOT NULL DEFAULT 15 CHECK (intervalo_minutos BETWEEN 5 AND 1440),
  ativa             boolean NOT NULL DEFAULT true,
  ultima_execucao   timestamptz,
  ultimo_resultado  jsonb,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crm_fontes_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT crm_fontes_nome_uk UNIQUE (tenant_id, nome),
  CONSTRAINT crm_fontes_conexao_fkey FOREIGN KEY (tenant_id, conexao_id)
    REFERENCES crm_connections (tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT crm_fontes_campanha_fkey FOREIGN KEY (tenant_id, campaign_id)
    REFERENCES campaigns (tenant_id, id) ON DELETE SET NULL (campaign_id),
  CONSTRAINT crm_fontes_alguma_fase CHECK (cardinality(fases) > 0),
  CONSTRAINT crm_fontes_mapa_objeto CHECK (jsonb_typeof(mapa) = 'object'),
  CONSTRAINT crm_fontes_papeis CHECK (NOT jsonb_path_exists(mapa,
    '$.* ? (!(@ == "nome" || @ == "origem_ref" || @ == "whatsapp" || @ == "sms" || @ == "telefone" || @ == "email" || @ == "instagram" || @ == "variavel"))')),
  -- Fonte sem nenhum campo de identidade não traz ninguém alcançável: toda
  -- linha seria recusada, e a fonte pareceria vazia em vez de mal mapeada.
  CONSTRAINT crm_fontes_tem_identidade CHECK (jsonb_path_exists(mapa,
    '$.* ? (@ == "whatsapp" || @ == "sms" || @ == "telefone" || @ == "email" || @ == "instagram")'))
);
CREATE INDEX crm_fontes_tenant_idx ON crm_fontes (tenant_id, conexao_id);

ALTER TABLE crm_fontes ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_fontes FORCE ROW LEVEL SECURITY;
CREATE POLICY crm_fontes_sel ON crm_fontes FOR SELECT
  USING (privado.pode_administrar(tenant_id));
CREATE POLICY crm_fontes_todos ON crm_fontes FOR ALL
  USING (privado.pode_administrar(tenant_id))
  WITH CHECK (privado.pode_administrar(tenant_id));

-- ---------------------------------------------------------------------------
-- O dreno: o que fez, e de quem pega
-- ---------------------------------------------------------------------------

ALTER TABLE outbox ADD COLUMN resultado text;

-- Mesma assinatura, mesmo retorno; o corpo parte do atual (D59) e acrescenta
-- só a condição de destino.
CREATE OR REPLACE FUNCTION public.reivindicar_writebacks(p_limite integer DEFAULT 50, p_lease interval DEFAULT '00:05:00'::interval)
 RETURNS TABLE(writeback_id uuid, tenant_id uuid, contact_id uuid, destino text, fato fato_writeback, payload jsonb, autoria text, tentativas integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado'
AS $function$
BEGIN
  RETURN QUERY
  WITH lote AS (
    SELECT o.id
      FROM outbox o
     WHERE o.status = 'pendente'
       AND o.proxima_tentativa_em <= now()
       AND (o.reivindicada_em IS NULL OR o.reivindicada_em < now() - p_lease)
       -- D64: só sai quem tem para onde ir. Sem isto o fato de um cliente sem
       -- CRM vinculado gastaria as oito tentativas e morreria em `falha` —
       -- perder um fato porque o destino ainda não existe é o D46 ao contrário.
       AND EXISTS (
         SELECT 1 FROM crm_connections c
           JOIN crm_provider_catalog p ON p.slug = c.provedor
          WHERE c.tenant_id = o.tenant_id AND c.ativo AND p.tem_adapter)
     ORDER BY o.proxima_tentativa_em
     LIMIT p_limite
     FOR UPDATE OF o SKIP LOCKED
  ), pego AS (
    UPDATE outbox o SET reivindicada_em = now()
      FROM lote l WHERE o.id = l.id
     RETURNING o.*
  )
  SELECT p.id, p.tenant_id, p.contact_id, p.destino, p.fato, p.payload,
         p.autoria, p.tentativas
    FROM pego p;
END;
$function$;

CREATE FUNCTION public.anotar_resultado_writeback(p_writeback_id uuid, p_resultado text)
RETURNS void
LANGUAGE sql
SET search_path TO 'public', 'privado'
AS $$
  UPDATE outbox SET resultado = left(p_resultado, 2000) WHERE id = p_writeback_id;
$$;

-- O plano de um writeback: o que fazer, em que card, com que valor.
--
-- Uma linha por ação, e uma linha `nada` com o motivo quando não há o que
-- fazer numa conexão — o worker grava esse motivo em `resultado` em vez de
-- marcar "enviado" sem dizer que nada foi escrito.
--
-- Mover vem antes de preencher. No Pipefy um campo de fase só é editável com
-- o card NA fase dele (FIELD_EDITABLE_ONLY_ON_ITS_ORIGINAL_PHASE), e o campo
-- que um fato preenche é, quase sempre, da fase para onde o fato manda.
CREATE FUNCTION public.plano_de_writeback(p_writeback_id uuid)
RETURNS TABLE(conexao_id uuid, provedor text, ref_externa text, tipo text,
              alvo_id text, valor text, motivo text)
LANGUAGE plpgsql STABLE
SET search_path TO 'public', 'privado'
AS $$
DECLARE
  o      outbox%ROWTYPE;
  v_vars jsonb;
BEGIN
  SELECT * INTO o FROM outbox WHERE id = p_writeback_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'writeback inexistente: %', p_writeback_id USING ERRCODE = 'no_data_found';
  END IF;

  -- As chaves que o valor pode citar. Metadados primeiro, para que `nome`,
  -- `fato` e os outros fixos ganhem de uma coluna da planilha com o mesmo
  -- nome: o fato é do motor, não da fonte.
  SELECT coalesce(c.metadados, '{}'::jsonb) || jsonb_build_object(
           'nome', coalesce(c.nome, ''),
           'fato', o.fato::text,
           'motivo', coalesce(o.payload ->> 'motivo', ''),
           'data', to_char(o.criado_em AT TIME ZONE 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
           'campanha', coalesce((SELECT ca.nome FROM campaigns ca
                                  WHERE ca.tenant_id = o.tenant_id
                                    AND ca.id = (o.payload ->> 'campaign_id')::uuid), ''),
           'resposta', coalesce((
             SELECT me.payload ->> 'texto'
               FROM message_events me JOIN messages m ON m.id = me.message_id
               JOIN enrollments e ON e.id = m.enrollment_id
              WHERE me.tenant_id = o.tenant_id AND e.contact_id = o.contact_id
                AND me.tipo = 'respondido'
                AND jsonb_typeof(me.payload -> 'texto') = 'string'
              ORDER BY me.ocorrido_em DESC LIMIT 1), ''))
    INTO v_vars
    FROM contacts c WHERE c.tenant_id = o.tenant_id AND c.id = o.contact_id;

  RETURN QUERY
  WITH conexoes AS (
    SELECT c.id, c.provedor
      FROM crm_connections c JOIN crm_provider_catalog p ON p.slug = c.provedor
     WHERE c.tenant_id = o.tenant_id AND c.ativo AND p.tem_adapter
  ),
  cards AS (
    SELECT v.conexao_id, v.pipe_id, v.ref_externa
      FROM crm_vinculos v
     WHERE v.tenant_id = o.tenant_id AND v.contact_id = o.contact_id
  ),
  acoes AS (
    SELECT k.id AS conexao_id, k.provedor, cd.ref_externa, a.tipo, a.alvo_id,
           CASE WHEN a.tipo = 'preencher_campo' THEN privado.renderizar(a.valor, v_vars) END AS valor,
           CASE a.tipo WHEN 'mover_fase' THEN 0 ELSE 1 END AS prioridade, a.ordem
      FROM conexoes k
      JOIN cards cd ON cd.conexao_id = k.id
      JOIN crm_acoes a ON a.tenant_id = o.tenant_id AND a.conexao_id = k.id
                      AND a.pipe_id = cd.pipe_id AND a.fato = o.fato AND a.ativo
  )
  SELECT x.conexao_id, x.provedor, x.ref_externa, x.tipo, x.alvo_id, x.valor, x.motivo
    FROM (
      SELECT a.conexao_id, a.provedor, a.ref_externa, a.tipo, a.alvo_id, a.valor,
             NULL::text AS motivo, a.prioridade, a.ordem
        FROM acoes a
      UNION ALL
      SELECT k.id, k.provedor, NULL, 'nada', NULL, NULL,
             CASE WHEN NOT EXISTS (SELECT 1 FROM cards cd WHERE cd.conexao_id = k.id)
                  THEN 'contato sem card vinculado nesta plataforma'
                  ELSE 'nenhuma ação configurada para ' || o.fato::text || ' no pipe deste card'
             END, 9, 0
        FROM conexoes k
       WHERE NOT EXISTS (SELECT 1 FROM acoes a WHERE a.conexao_id = k.id)
    ) x
   ORDER BY x.conexao_id, x.ref_externa NULLS LAST, x.prioridade, x.ordem;
END;
$$;

-- ---------------------------------------------------------------------------
-- Descoberta e fontes: o que o worker e a edge function gravam
-- ---------------------------------------------------------------------------

CREATE FUNCTION public.registrar_estrutura_crm(p_conexao_id uuid, p_estrutura jsonb, p_erro text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
DECLARE v_tenant uuid;
BEGIN
  SELECT tenant_id INTO v_tenant FROM crm_connections WHERE id = p_conexao_id;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'conexão inexistente: %', p_conexao_id USING ERRCODE = 'no_data_found';
  END IF;

  -- Descoberta que falha não apaga a que deu certo antes: a tela continua
  -- oferecendo as fases conhecidas e mostra o erro ao lado.
  INSERT INTO crm_estruturas (tenant_id, conexao_id, estrutura, erro, descoberto_em)
  VALUES (v_tenant, p_conexao_id, p_estrutura, p_erro, now())
  ON CONFLICT (tenant_id, conexao_id) DO UPDATE
     SET estrutura = coalesce(EXCLUDED.estrutura, crm_estruturas.estrutura),
         erro = EXCLUDED.erro,
         descoberto_em = now();
END;
$$;

-- Fontes vencidas: ativas, de conexão ativa que sabe ler, e cujo intervalo
-- passou. O intervalo existe porque o worker bate a cada minuto e o CRM tem
-- limite de requisição; ler 500 cards a cada minuto seria o motor tirando o
-- CRM do ar.
CREATE FUNCTION public.fontes_crm_vencidas()
RETURNS TABLE(fonte_id uuid, tenant_id uuid, conexao_id uuid, provedor text,
              pipe_id text, fases text[], mapa jsonb, campaign_id uuid)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  SELECT f.id, f.tenant_id, f.conexao_id, c.provedor, f.pipe_id, f.fases, f.mapa, f.campaign_id
    FROM crm_fontes f
    JOIN crm_connections c ON c.tenant_id = f.tenant_id AND c.id = f.conexao_id
    JOIN crm_provider_catalog p ON p.slug = c.provedor
   WHERE f.ativa AND c.ativo AND p.tem_adapter
     AND (f.ultima_execucao IS NULL
          OR f.ultima_execucao <= now() - make_interval(mins => f.intervalo_minutos))
   ORDER BY f.ultima_execucao NULLS FIRST;
$$;

-- Cards que já são alguém nesta conexão. O worker pula estes antes de ler os
-- campos — reingerir 500 cards conhecidos a cada passada é custo sem fato novo.
CREATE FUNCTION public.refs_vinculadas(p_conexao_id uuid)
RETURNS SETOF text
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  SELECT ref_externa FROM crm_vinculos WHERE conexao_id = p_conexao_id;
$$;

-- Um card vira contato, vínculo e, se a fonte pede, inscrição.
--
-- As três numa transação, pelo motivo do D55: contato sem vínculo é contato
-- cujo fato nunca volta ao CRM, e vínculo sem inscrição é a fonte prometendo
-- uma campanha que não aconteceu.
--
-- Inscrever passa pela prévia de sempre (D35). Inscrever quem não tem canal
-- que a cadência use não dá erro — dá campanha "concluída" sem mensagem — e
-- uma fonte automática faria isso para cada card, sem ninguém olhando. Aqui
-- a recusa volta como texto e o worker a conta no resultado da fonte.
CREATE FUNCTION public.ingerir_do_crm(
  p_fonte_id     uuid,
  p_ref_externa  text,
  p_identidades  jsonb,
  p_nome         text DEFAULT NULL,
  p_metadados    jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE(contact_id uuid, acao text, inscricao text)
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
DECLARE
  f        crm_fontes%ROWTYPE;
  v_prov   text;
  v_contato uuid;
  v_acao   text;
  v_versao uuid;
  v_previa text;
  v_dono   uuid;
BEGIN
  SELECT * INTO f FROM crm_fontes WHERE id = p_fonte_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fonte inexistente: %', p_fonte_id USING ERRCODE = 'no_data_found';
  END IF;
  SELECT provedor INTO v_prov FROM crm_connections
   WHERE tenant_id = f.tenant_id AND id = f.conexao_id;

  IF p_ref_externa IS NULL OR length(trim(p_ref_externa)) = 0 THEN
    RAISE EXCEPTION 'card sem id não tem como receber o fato de volta'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT i.contact_id, i.acao INTO v_contato, v_acao
    FROM ingerir_contato(f.tenant_id, 'crm:' || v_prov, p_identidades, p_nome,
                         p_ref_externa, p_metadados) i;

  -- O card já é de outra pessoa nesta conexão: as identidades mudaram no CRM
  -- (alguém corrigiu o telefone) e casaram com outro contato. Não religar em
  -- silêncio — o fato desta pessoa iria para o card daquela.
  SELECT v.contact_id INTO v_dono FROM crm_vinculos v
   WHERE v.tenant_id = f.tenant_id AND v.conexao_id = f.conexao_id
     AND v.ref_externa = p_ref_externa;
  IF v_dono IS NOT NULL AND v_dono <> v_contato THEN
    RAISE EXCEPTION 'o card % já está ligado a outro contato', p_ref_externa
      USING ERRCODE = 'restrict_violation',
            HINT = 'fundir contatos é decisão de operação, não de importação';
  END IF;

  INSERT INTO crm_vinculos (tenant_id, conexao_id, contact_id, pipe_id, ref_externa)
  VALUES (f.tenant_id, f.conexao_id, v_contato, f.pipe_id, p_ref_externa)
  ON CONFLICT DO NOTHING;

  contact_id := v_contato;
  acao := v_acao;

  IF f.campaign_id IS NULL THEN
    inscricao := 'sem_campanha';
    RETURN NEXT; RETURN;
  END IF;

  SELECT flow_version_id INTO v_versao FROM campaigns
   WHERE tenant_id = f.tenant_id AND id = f.campaign_id;
  IF v_versao IS NULL THEN
    inscricao := 'campanha_sem_cadencia';
    RETURN NEXT; RETURN;
  END IF;

  SELECT pi.acao INTO v_previa
    FROM prever_inscricao(f.tenant_id, f.campaign_id, v_versao, ARRAY[v_contato]) pi;

  IF v_previa = 'inscrever' THEN
    PERFORM inscrever(v_contato, f.campaign_id, v_versao, now());
    inscricao := 'inscrito';
  ELSE
    inscricao := v_previa;
  END IF;
  RETURN NEXT;
END;
$$;

CREATE FUNCTION public.registrar_execucao_fonte(p_fonte_id uuid, p_resultado jsonb)
RETURNS void
LANGUAGE sql
SET search_path TO 'public', 'privado'
AS $$
  UPDATE crm_fontes
     SET ultima_execucao = now(), ultimo_resultado = p_resultado
   WHERE id = p_fonte_id;
$$;

-- ---------------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------------

-- Todas são do worker e da edge function. Nenhuma é da tela: a tela escreve
-- `crm_acoes` e `crm_fontes` direto, pela política (D41), e lê o resto.
DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.anotar_resultado_writeback(uuid, text)',
    'public.plano_de_writeback(uuid)',
    'public.registrar_estrutura_crm(uuid, jsonb, text)',
    'public.fontes_crm_vencidas()',
    'public.refs_vinculadas(uuid)',
    'public.ingerir_do_crm(uuid, text, jsonb, text, jsonb)',
    'public.registrar_execucao_fonte(uuid, jsonb)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', alvo);
    END IF;
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON crm_vinculos, crm_estruturas, crm_acoes, crm_fontes FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT SELECT ON crm_vinculos, crm_estruturas, crm_acoes, crm_fontes TO authenticated';
    EXECUTE 'GRANT DELETE ON crm_acoes, crm_fontes TO authenticated';
  END IF;
END;
$$;

-- A grade estreita, regenerada a partir do corpo de agora (D59) com as quatro
-- tabelas do D64 no fim.
CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  -- D54: por coluna onde a tela escreve.
  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;

  -- D62: a conta nasce pela tela com o que a tela preenche, e só. Com INSERT
  -- de tabela inteira dava para nascer com `credenciais_secret_id` apontando
  -- para o segredo de OUTRO cliente — o worker mandaria pela conta dele, o
  -- D59 na quarta tabela de credencial. E DELETE apagava em cascata as
  -- mensagens e os eventos da conta: história que é append-only (D62).
  REVOKE INSERT, DELETE ON sender_accounts FROM authenticated;
  GRANT INSERT (tenant_id, canal, provedor, identificador, apelido,
                tipo_permitido, quota_diaria, config)
    ON sender_accounts TO authenticated;

  -- D63: a blacklist é da tela, menos o dono da linha e a origem dela.
  REVOKE UPDATE ON blacklist_termos, blacklist_dominios FROM authenticated;
  GRANT UPDATE (termo, exige_uma_de, acao, nota, ativo) ON blacklist_termos TO authenticated;
  GRANT UPDATE (nota, ativo) ON blacklist_dominios TO authenticated;

  -- D54: as três do motor, leitura sim, escrita nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;

  -- D57: o funil. Renomear e reordenar estágio é da tela; mover card é de
  -- `mover_deal`, e sem esta revogação "porta única" seria convenção.
  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;

  -- D59, daqui para baixo.
  --
  -- As duas tabelas de credencial: a tela liga e desliga, e nada mais. Quem
  -- grava é a função DEFINER, que não usa privilégio do cliente.
  --
  -- O INSERT vai embora junto do UPDATE largo, e não é zelo a mais: com ele,
  -- dava para criar a linha com `credencial_secret_id` escolhido à mão,
  -- apontando para um segredo do Vault que não é desta conexão. Passar pela
  -- função é o que garante que o ponteiro nasce de `guardar_segredo`.
  REVOKE INSERT, UPDATE, DELETE ON ai_credentials, crm_connections FROM authenticated;
  GRANT UPDATE (ativo) ON ai_credentials TO authenticated;
  GRANT UPDATE (ativo) ON crm_connections TO authenticated;

  -- Servidor de provedor: nenhuma tela escreve. `salvar_servidor_provedor` é
  -- DEFINER, e `admin_secret_id` é ponteiro de Vault pelo mesmo motivo acima.
  REVOKE INSERT, UPDATE, DELETE ON provider_servers FROM authenticated;

  -- Catálogo é do produto, não do cliente. Nos três o RLS já recusa por falta
  -- de política de DML, e é justamente por isso que a revogação entra: confiar
  -- que "não tem política" é o mesmo que "não tem privilégio" é o D54 pela
  -- terceira vez. Quem lê continua lendo — `tem_adapter` e `campos` são o que
  -- a tela desenha.
  REVOKE INSERT, UPDATE, DELETE
      ON channel_provider_catalog, ai_provider_catalog, crm_provider_catalog
    FROM authenticated;

  -- D64. Vínculo e estrutura são do motor: a tela lê. Um vínculo escrito à
  -- mão é o fato de uma pessoa indo para o card de outra; uma estrutura
  -- escrita à mão é a tela oferecendo fase que não existe.
  REVOKE INSERT, UPDATE, DELETE ON crm_vinculos, crm_estruturas FROM authenticated;

  -- Ação e fonte são da tela, por coluna. Fora fica o dono da linha e, na
  -- fonte, o que a execução grava — `ultimo_resultado` escrito pela tela
  -- seria o painel dizendo que a fonte rodou quando não rodou.
  REVOKE INSERT, UPDATE ON crm_acoes, crm_fontes FROM authenticated;
  GRANT INSERT (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id, alvo_rotulo, valor, ordem, ativo)
    ON crm_acoes TO authenticated;
  GRANT UPDATE (alvo_id, alvo_rotulo, valor, ordem, ativo) ON crm_acoes TO authenticated;
  GRANT INSERT (tenant_id, conexao_id, nome, pipe_id, pipe_rotulo, fases, mapa,
                campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  GRANT UPDATE (nome, fases, mapa, campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
END;
$function$;

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
