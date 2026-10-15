-- O funil: onde cada lead está (D57).
--
-- Até aqui o motor sabia o que aconteceu com cada contato — recebeu, respondeu,
-- encerrou — e não sabia dizer **onde ele está**. Quem abria o produto via
-- campanhas e mensagens, nunca "quantos leads em prospecção, quantos
-- responderam, quantos viraram oportunidade".
--
-- A receita vem da nota `Padrão - Kanban e Pipeline` da base de conhecimento
-- da casa, que catalogou o padrão em SETE projetos anteriores e, com ele, as
-- armadilhas já pagas em produção. As quatro que moldaram este arquivo:
--
-- 1. **Estágio por `slug`, nunca por nome.** Dois projetos quebraram quando o
--    cliente renomeou um estágio e o backend procurava por `'Perdeu'` ou fazia
--    `ilike`. Aqui o código só conhece `slug` e `tipo`; `nome` é rótulo de
--    tela e pode ser trocado à vontade.
--
-- 2. **Uma porta só para mover.** `mover_deal` grava a atividade, carimba
--    `entrou_no_estagio_em` e aplica a regra de precedência. UPDATE direto em
--    `deals.stage_id` não é caminho — tanto que o privilégio de coluna do D54
--    não o concede.
--
-- 3. **Automação nunca tira de ganho nem de perdido.** Num dos projetos, a
--    análise de sentimento moveu para "Perdeu" uma conversa que tinha acabado
--    de agendar reunião. Pessoa move de onde quiser; automação, não.
--
-- 4. **Classificações serializadas.** Dois classificadores em paralelo
--    disputaram o mesmo card no mesmo projeto. Aqui o motor é a única
--    automação que escreve, e cada gatilho move só a partir dos estágios que
--    ele mesmo reconhece.
--
-- E a armadilha que este repositório já conhece por conta própria: a nota
-- registra `is_ai_managed` como coluna que **existia só na UI** em dois
-- projetos — o `tem_adapter` do D31 com outro nome. Por isso este arquivo não
-- traz nenhuma coluna de "gerenciado por IA": ela entra quando houver quem a
-- leia, e não antes.
--
-- Sem barra invertida (D32). Tenant explícito e FK composta (D18).
-- Reversível: supabase/down/20260925210000_o_funil.down.sql

-- ---------------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------------

-- O que o estágio SIGNIFICA para a automação, independente do nome que o
-- cliente lhe der. É isto que a regra de precedência lê.
CREATE TYPE tipo_estagio AS ENUM ('aberto', 'ganho', 'perdido');

-- Quem moveu. `motor` é fato mecânico (mandou, respondeu, encerrou); `ia` é
-- juízo de um classificador; `pessoa` é alguém arrastando o card. Guardar isso
-- é o que permite auditar um auto-move errado depois — foi a falta disso que
-- deixou o caso do sentimento invisível por semanas no projeto anterior.
CREATE TYPE origem_movimento AS ENUM ('motor', 'ia', 'pessoa');

-- ---------------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------------

CREATE TABLE pipelines (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL DEFAULT privado.tenant_padrao()
             REFERENCES tenants(id) ON DELETE CASCADE,
  nome       text NOT NULL,
  slug       text NOT NULL,
  padrao     boolean NOT NULL DEFAULT false,
  criado_em  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pipelines_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT pipelines_slug_uk UNIQUE (tenant_id, slug),
  CONSTRAINT pipelines_nome_nao_vazio CHECK (length(btrim(nome)) > 0)
);

CREATE INDEX pipelines_tenant_idx ON pipelines (tenant_id);

-- Um funil padrão por cliente, e no máximo um.
CREATE UNIQUE INDEX pipelines_padrao_uk ON pipelines (tenant_id) WHERE padrao;

COMMENT ON TABLE pipelines IS
  'Funil comercial. O cliente pode ter mais de um; um é o padrão (D57).';

CREATE TABLE pipeline_stages (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL DEFAULT privado.tenant_padrao()
              REFERENCES tenants(id) ON DELETE CASCADE,
  pipeline_id uuid NOT NULL,
  nome        text NOT NULL,
  -- O identificador que o CÓDIGO usa. `nome` é da tela e pode ser renomeado.
  slug        text NOT NULL,
  posicao     integer NOT NULL,
  cor         text,
  tipo        tipo_estagio NOT NULL DEFAULT 'aberto',
  criado_em   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pipeline_stages_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT pipeline_stages_slug_uk UNIQUE (pipeline_id, slug),
  CONSTRAINT pipeline_stages_posicao_uk UNIQUE (pipeline_id, posicao),
  CONSTRAINT pipeline_stages_posicao_positiva CHECK (posicao > 0),
  CONSTRAINT pipeline_stages_nome_nao_vazio CHECK (length(btrim(nome)) > 0),
  CONSTRAINT pipeline_stages_slug_formato CHECK (slug ~ '^[a-z0-9_]+$'),
  CONSTRAINT pipeline_stages_pipeline_tenant_fkey
    FOREIGN KEY (tenant_id, pipeline_id) REFERENCES pipelines(tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX pipeline_stages_tenant_idx ON pipeline_stages (tenant_id);
CREATE INDEX pipeline_stages_pipeline_idx ON pipeline_stages (pipeline_id, posicao);

COMMENT ON COLUMN pipeline_stages.slug IS
  'O que o código conhece. Renomear `nome` não quebra nada; era assim que
   quebrava nos projetos que procuravam o estágio pelo nome (D57).';
COMMENT ON COLUMN pipeline_stages.tipo IS
  'O que o estágio significa para a automação. `ganho` e `perdido` são
   protegidos: só pessoa tira um card de lá (D57).';

CREATE TABLE deals (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL DEFAULT privado.tenant_padrao()
                        REFERENCES tenants(id) ON DELETE CASCADE,
  contact_id            uuid NOT NULL,
  pipeline_id           uuid NOT NULL,
  stage_id              uuid NOT NULL,
  -- De qual campanha o lead veio. Informativo: o card é da PESSOA, não da
  -- campanha — resposta encerra a cadência dela em todas (invariante 4).
  campaign_id           uuid,
  entrou_no_estagio_em  timestamptz NOT NULL DEFAULT now(),
  movido_por            origem_movimento NOT NULL DEFAULT 'motor',
  motivo                text,
  criado_em             timestamptz NOT NULL DEFAULT now(),
  atualizado_em         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deals_tenant_id_uk UNIQUE (tenant_id, id),
  -- Um card por pessoa por funil. Não por enrollment: quem está em três
  -- campanhas é uma pessoa só no funil.
  CONSTRAINT deals_contato_uk UNIQUE (tenant_id, contact_id, pipeline_id),
  CONSTRAINT deals_contact_tenant_fkey
    FOREIGN KEY (tenant_id, contact_id) REFERENCES contacts(tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT deals_pipeline_tenant_fkey
    FOREIGN KEY (tenant_id, pipeline_id) REFERENCES pipelines(tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT deals_stage_tenant_fkey
    FOREIGN KEY (tenant_id, stage_id) REFERENCES pipeline_stages(tenant_id, id),
  CONSTRAINT deals_campaign_tenant_fkey
    FOREIGN KEY (tenant_id, campaign_id) REFERENCES campaigns(tenant_id, id) ON DELETE SET NULL
);

CREATE INDEX deals_tenant_idx ON deals (tenant_id);
CREATE INDEX deals_stage_idx ON deals (stage_id);
CREATE INDEX deals_contact_idx ON deals (contact_id);

COMMENT ON TABLE deals IS
  'O card do lead no funil. Um por pessoa por funil — resposta encerra a
   cadência em todas as campanhas, então o estado é da pessoa (D57).';

-- Append-only, como `message_events`: a linha do tempo do card é o que
-- permite auditar um auto-move errado, e reescrevê-la apagaria a prova.
CREATE TABLE deal_activities (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL DEFAULT privado.tenant_padrao()
                 REFERENCES tenants(id) ON DELETE CASCADE,
  deal_id        uuid NOT NULL,
  de_stage_id    uuid,
  para_stage_id  uuid NOT NULL,
  origem         origem_movimento NOT NULL,
  motivo         text,
  ocorrido_em    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deal_activities_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT deal_activities_deal_tenant_fkey
    FOREIGN KEY (tenant_id, deal_id) REFERENCES deals(tenant_id, id) ON DELETE CASCADE,
  CONSTRAINT deal_activities_para_tenant_fkey
    FOREIGN KEY (tenant_id, para_stage_id) REFERENCES pipeline_stages(tenant_id, id)
);

CREATE INDEX deal_activities_tenant_idx ON deal_activities (tenant_id);
CREATE INDEX deal_activities_deal_idx ON deal_activities (deal_id, ocorrido_em DESC);

CREATE TRIGGER deal_activities_append_only
  BEFORE UPDATE OR DELETE ON deal_activities
  FOR EACH ROW EXECUTE FUNCTION privado.recusar_escrita();

CREATE TRIGGER deals_atualizado_em
  BEFORE UPDATE ON deals
  FOR EACH ROW EXECUTE FUNCTION privado.tocar_atualizado_em();

-- ---------------------------------------------------------------------------
-- RLS (D18)
-- ---------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['pipelines','pipeline_stages','deals','deal_activities'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR SELECT
      USING (privado.pertence_ao_tenant(tenant_id))$f$, t || '_sel', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR INSERT
      WITH CHECK (privado.pode_operar(tenant_id))$f$, t || '_ins', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR UPDATE
      USING (privado.pode_operar(tenant_id)) WITH CHECK (privado.pode_operar(tenant_id))$f$,
      t || '_upd', t);
    EXECUTE format($f$CREATE POLICY %I ON %I FOR DELETE
      USING (privado.pode_administrar(tenant_id))$f$, t || '_del', t);
  END LOOP;
END;
$$;
