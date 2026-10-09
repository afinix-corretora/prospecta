-- Plataformas vinculadas: cada cliente traz o CRM dele, com credencial dele.
--
-- O produto já fazia isso duas vezes e nunca para CRM. `sender_accounts` guarda
-- o chip do cliente pelo `salvar_credencial_remetente` (D26); `ai_credentials`
-- guarda a chave de modelo pelo `salvar_credencial_ia` (D19 do painel). As duas
-- são por tenant, com o segredo no Vault e a separação decidida pelo catálogo,
-- não pela tela (D28). O CRM ficou de fora: existia UM destino, o Pipefy, e
-- ele nem era configurável — o `_shared/pipefy.ts` do contrato nunca foi
-- escrito, então o writeback tinha fila (`outbox`) e não tinha para onde ir.
--
-- Isto é o terceiro uso do mesmo padrão, e o que o torna necessário é o modelo
-- de negócio: cada licença é um tenant, e cada tenant tem o CRM que já usa.
-- Um `client_id` de Pipefy fixo no código seria o produto inteiro apontando
-- para o CRM de um cliente só.
--
-- ATENÇÃO, e é o ponto mais importante deste arquivo: vincular uma plataforma
-- GUARDA A CREDENCIAL E NADA MAIS. Nenhum adapter de CRM existe — `tem_adapter`
-- é `false` nas oito linhas, e é verdade, não pendência esquecida. O `outbox`
-- continua drenando para lugar nenhum até o primeiro adapter existir.
--
-- Isso é o D55 (`campaign_agents`) acontecendo de novo por escolha, não por
-- descuido: a tela DIZ que a vinculação ainda não escreve no CRM, porque o
-- jeito de descobrir sozinho seria um lead que o vendedor nunca viu. A coluna
-- `tem_adapter` existe para que o dia em que um adapter entrar, a mudança seja
-- de uma linha do catálogo — e para que ninguém tenha que confiar na memória
-- de quem leu este comentário.
--
-- Por que catálogo e não `if` por provedor: a tela não conhece CRM nenhum.
-- Ela desenha os campos que o catálogo declara e manda tudo num objeto só;
-- quem separa Vault de `config` é a função, lendo o catálogo (D28). CRM novo
-- é uma linha aqui, zero mudança de UI.
--
-- A autenticação de cada um foi conferida na documentação do provedor, não
-- escrita de memória — esquema de auth troca de versão e o campo errado no
-- catálogo vira credencial guardada com nome que ninguém vai ler (o `docs_url`
-- de cada linha é a página conferida).
--
-- Sem barra invertida (D32).

-- ---------------------------------------------------------------------------
-- Catálogo de plataformas
-- ---------------------------------------------------------------------------

-- Sem `tenant_id` de propósito: é catálogo do produto, igual a
-- `channel_provider_catalog` e `ai_provider_catalog`. Mas COM RLS — é a lição
-- que o `recusa_termos` do D58 custou: a lista que isenta uma tabela do
-- `tenant_id` isentava também da pergunta do RLS, e quem pegou foi o advisor.
CREATE TABLE crm_provider_catalog (
  slug        text PRIMARY KEY,
  nome        text NOT NULL,
  descricao   text NOT NULL,
  -- [{chave, rotulo, tipo, obrigatorio, segredo, ajuda}] — mesmo formato dos
  -- outros dois catálogos, porque a tela é a mesma ideia.
  campos      jsonb NOT NULL,
  -- O que o D31 cobra: coluna de catálogo que ninguém lê não é garantia. Esta
  -- é lida pela tela (para dizer a verdade ao usuário) e será lida pelo dreno
  -- do outbox quando ele escolher destino.
  tem_adapter boolean NOT NULL DEFAULT false,
  docs_url    text,
  ordem       integer NOT NULL DEFAULT 0,
  CONSTRAINT crm_provider_catalog_campos_nao_vazio CHECK (jsonb_array_length(campos) > 0)
);

COMMENT ON TABLE crm_provider_catalog IS
  'Plataformas de CRM que o produto sabe receber credencial. tem_adapter = false
   significa que o writeback para ela ainda não foi escrito — a credencial fica
   guardada e nada a lê.';

COMMENT ON COLUMN crm_provider_catalog.tem_adapter IS
  'Falso em todas as linhas hoje. Não é "não dá": é "ainda não". A distinção
   importa porque o D54 proibiu fundir as duas — uma se resolve escrevendo
   código nosso, a outra não se resolve por tela nenhuma.';

ALTER TABLE crm_provider_catalog ENABLE ROW LEVEL SECURITY;
CREATE POLICY crm_provider_catalog_sel ON crm_provider_catalog FOR SELECT USING (true);

-- ---------------------------------------------------------------------------
-- Conexões do cliente
-- ---------------------------------------------------------------------------

-- Não existe coluna para a credencial. Só o ponteiro para o Vault: o que não
-- tem onde ser guardado errado não é guardado errado.
CREATE TABLE crm_connections (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- `privado.` explícito: o D19 moveu para lá tudo o que não é API, e
  -- `tenant_padrao` foi junto. Os DEFAULTs antigos seguiram por OID, mas
  -- coluna nova precisa do nome certo.
  tenant_id           uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  nome                text NOT NULL,
  provedor            text NOT NULL REFERENCES crm_provider_catalog(slug),
  credencial_secret_id uuid,
  -- Só campos não-secretos: domínio da empresa, data center, client_id.
  config              jsonb NOT NULL DEFAULT '{}'::jsonb,
  ativo               boolean NOT NULL DEFAULT true,
  criado_em           timestamptz NOT NULL DEFAULT now(),
  atualizado_em       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT crm_connections_nome_uk UNIQUE (tenant_id, nome),
  CONSTRAINT crm_connections_tenant_id_uk UNIQUE (tenant_id, id)
);

CREATE INDEX crm_connections_tenant_idx ON crm_connections (tenant_id);

COMMENT ON TABLE crm_connections IS
  'CRM que este cliente vinculou. Uma linha por conexão; o segredo está no
   Vault, apontado por credencial_secret_id.';

-- Gatilho espelho de `ai_credentials_sem_segredo`: o banco recusa segredo em
-- `config` mesmo que a função seja contornada. Precisa ser função própria e
-- não a `barrar_segredo_em_config()` do D17 porque aquela consulta
-- `ai_provider_catalog` pelo nome — catálogo é diferente, pergunta é a mesma.
CREATE FUNCTION privado.barrar_segredo_em_config_crm() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE v_proibida text;
BEGIN
  SELECT c ->> 'chave' INTO v_proibida
    FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = NEW.provedor
     AND (c ->> 'segredo')::boolean
     AND NEW.config ? (c ->> 'chave')
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION
      'campo % é segredo e não pode ir em config — use o Vault (credencial_secret_id)',
      v_proibida
      USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER crm_connections_sem_segredo
  BEFORE INSERT OR UPDATE ON crm_connections
  FOR EACH ROW EXECUTE FUNCTION privado.barrar_segredo_em_config_crm();

CREATE TRIGGER crm_connections_atualizado_em
  BEFORE UPDATE ON crm_connections
  FOR EACH ROW EXECUTE FUNCTION privado.tocar_atualizado_em();

-- Credencial de CRM é tão sensível quanto chip e chave de modelo: só admin,
-- inclusive na leitura. Mesma decisão que `sender_accounts` e `ai_credentials`
-- receberam no D18.
ALTER TABLE crm_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE crm_connections FORCE ROW LEVEL SECURITY;
CREATE POLICY crm_connections_sel ON crm_connections FOR SELECT
  USING (privado.pode_administrar(tenant_id));
CREATE POLICY crm_connections_todos ON crm_connections FOR ALL
  USING (privado.pode_administrar(tenant_id))
  WITH CHECK (privado.pode_administrar(tenant_id));

-- ---------------------------------------------------------------------------
-- Gravar pela tela
-- ---------------------------------------------------------------------------

CREATE FUNCTION salvar_credencial_crm(
  p_tenant   uuid,
  p_nome     text,
  p_provedor text,
  p_campos   jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE
  v_id      uuid;
  v_antigo  uuid;
  v_segredo uuid;
  v_config  jsonb;
  v_secreto jsonb;
  v_ruim    text;
BEGIN
  -- SECURITY DEFINER pula a RLS de crm_connections, então a checagem que a
  -- política faria é feita aqui. Mesma razão das outras três funções de
  -- credencial.
  IF NOT privado.pode_administrar(p_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente vincula plataforma'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM crm_provider_catalog WHERE slug = p_provedor) THEN
    RAISE EXCEPTION 'plataforma desconhecida: %', p_provedor
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_nome IS NULL OR length(trim(p_nome)) = 0 THEN
    RAISE EXCEPTION 'conexão sem nome não dá para escolher depois'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Campo que o provedor não declara não entra, nem no Vault nem em config.
  SELECT k INTO v_ruim
    FROM jsonb_object_keys(coalesce(p_campos, '{}'::jsonb)) k
   WHERE NOT EXISTS (
     SELECT 1 FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = p_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe na plataforma %', v_ruim, p_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT id, credencial_secret_id INTO v_id, v_antigo
    FROM crm_connections WHERE tenant_id = p_tenant AND nome = trim(p_nome);

  -- Separação pelo catálogo, não pela tela.
  SELECT
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE NOT seg), '{}'::jsonb),
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE seg AND length(trim(v)) > 0), '{}'::jsonb)
    INTO v_config, v_secreto
    FROM (
      SELECT e.key AS k, e.value #>> '{}' AS v,
             (c.campo ->> 'segredo')::boolean AS seg
        FROM jsonb_each(coalesce(p_campos, '{}'::jsonb)) e
        JOIN LATERAL (
          SELECT x AS campo FROM crm_provider_catalog p,
                 jsonb_array_elements(p.campos) x
           WHERE p.slug = p_provedor AND x ->> 'chave' = e.key
        ) c ON true
    ) s;

  -- Campo obrigatório em branco só passa quando já existe valor guardado: na
  -- edição o segredo volta vazio da tela, porque segredo não é legível, e
  -- reenviar vazio não pode apagar a credencial de uma conexão em uso.
  SELECT c ->> 'rotulo' INTO v_ruim
    FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(p_campos ->> (c ->> 'chave'), ''))) = 0
     AND NOT ((c ->> 'segredo')::boolean AND v_antigo IS NOT NULL)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo obrigatório em branco: %', v_ruim
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Um segredo só por conexão, com o objeto inteiro junto. Salesforce e Zoho
  -- pedem duas chaves cada; duas linhas no Vault desencontram na primeira
  -- rotação de credencial.
  IF v_secreto <> '{}'::jsonb THEN
    v_segredo := privado.guardar_segredo(
      'crm:' || p_provedor || ':' || p_tenant::text || ':' || gen_random_uuid()::text,
      v_secreto::text);
  ELSE
    v_segredo := v_antigo;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO crm_connections (tenant_id, nome, provedor, credencial_secret_id, config)
    VALUES (p_tenant, trim(p_nome), p_provedor, v_segredo, v_config)
    RETURNING id INTO v_id;
  ELSE
    UPDATE crm_connections
       SET provedor = p_provedor, credencial_secret_id = v_segredo, config = v_config
     WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION salvar_credencial_crm IS
  'Vincula plataforma a partir da tela: o catálogo separa segredo de config, o
   segredo vai para o Vault. Checa pode_administrar em código porque SECURITY
   DEFINER passa por cima da RLS (D26). Guardar a credencial não liga writeback
   nenhum — nenhum adapter de CRM existe ainda.';

-- Simétrica a `segredo_do_remetente` e `segredo_da_credencial_ia`: o worker
-- precisa da credencial para chamar o CRM, e ninguém mais precisa. Já existe
-- antes do adapter porque é ela que torna o adapter possível sem mexer no
-- Vault de novo.
CREATE FUNCTION segredo_da_conexao_crm(p_conexao_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id uuid;
BEGIN
  SELECT credencial_secret_id INTO v_id FROM crm_connections WHERE id = p_conexao_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'conexão de CRM inexistente: %', p_conexao_id
      USING ERRCODE = 'no_data_found';
  END IF;
  IF v_id IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN privado.ler_segredo(v_id);
END;
$$;

-- Função nova nasce com EXECUTE para PUBLIC, do qual anon é membro (D19/D55).
-- REVOKE primeiro, GRANT depois: conceder sem revogar é acrescentar um grant
-- ao lado de uma porta aberta, não decidir.
DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.salvar_credencial_crm(uuid, text, text, jsonb)',
    'public.segredo_da_conexao_crm(uuid)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;

  -- A tela vincula; o segredo é só do worker. `segredo_da_conexao_crm` fica
  -- fora de `authenticated` de propósito: admin logado não precisa ler de volta
  -- a credencial que ele mesmo colou, e uma função que devolve segredo
  -- alcançável pelo PostgREST é o D44 pelo avesso.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.salvar_credencial_crm(uuid, text, text, jsonb) TO authenticated';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- As oito plataformas
-- ---------------------------------------------------------------------------

-- `tem_adapter` fica no default `false` em todas: o writeback não existe para
-- nenhuma. Quando o primeiro sair, é UPDATE de uma linha — e o teste que conta
-- adapters vai pegar quem mentir.
INSERT INTO crm_provider_catalog (slug, nome, descricao, campos, docs_url, ordem) VALUES

('softcare', 'Softcare (CRM da casa)',
 'O CRM do grupo. Por ser nosso, é o único em que o contrato de escrita pode ser ajustado dos dois lados em vez de negociado com a documentação de terceiro.',
 '[{"chave":"base_url","rotulo":"URL da instalação","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Endereço da API do Softcare deste cliente"},
   {"chave":"token","rotulo":"Token de integração","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Gerado na administração do Softcare"}]'::jsonb,
 NULL, 1),

('pipefy', 'Pipefy',
 'O CRM do legado da Afinix. O contrato de escrita está no D3 e o mapa de fases no backfill; a armadilha conhecida é FIELD_EDITABLE_ONLY_ON_ITS_ORIGINAL_PHASE — mover o card antes de editar o campo de origem.',
 '[{"chave":"client_id","rotulo":"Client ID","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"App do Pipefy, fluxo client_credentials"},
   {"chave":"client_secret","rotulo":"Client secret","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Nunca gravado: o token é gerado a cada uso"},
   {"chave":"organizacao_id","rotulo":"ID da organização","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Só se a conta tiver mais de uma"}]'::jsonb,
 'https://developers.pipefy.com/reference/authentication', 2),

('hubspot', 'HubSpot',
 'O mais usado no mundo em inbound. Token de private app vai no cabeçalho Authorization como Bearer — é a integração mais simples da lista.',
 '[{"chave":"token","rotulo":"Private app access token","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Settings ▸ Integrations ▸ Private Apps. Escopos de crm.objects.contacts e crm.objects.deals"}]'::jsonb,
 'https://developers.hubspot.com/docs/apps/legacy-apps/private-apps/overview', 3),

('pipedrive', 'Pipedrive',
 'Forte em time de vendas pequeno. A URL da API carrega o domínio da empresa, então o domínio é campo e não constante.',
 '[{"chave":"api_token","rotulo":"API token","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Configurações pessoais ▸ API. Vai no cabeçalho x-api-token"},
   {"chave":"dominio_empresa","rotulo":"Domínio da empresa","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"O trecho de https://SEU-DOMINIO.pipedrive.com"}]'::jsonb,
 'https://pipedrive.readme.io/docs/core-api-concepts-authentication', 4),

('rdstation_crm', 'RD Station CRM',
 'O mais comum no mercado brasileiro de PME. A v1 autentica por token na query string; a v2 é OAuth2. O token da v1 é o que a maioria dos clientes tem à mão.',
 '[{"chave":"token","rotulo":"Token da instância","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Configurações ▸ Integrações ▸ API do RD Station CRM"}]'::jsonb,
 'https://developers.rdstation.com/reference/crm-v2-authentication', 5),

('ploomes', 'Ploomes',
 'Brasileiro, comum em operação de corretora e de venda consultiva. Autentica por User-Key de usuário de integração, criado na administração.',
 '[{"chave":"user_key","rotulo":"User-Key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Administração ▸ Usuários de integração ▸ API Key. Só admin cria"}]'::jsonb,
 'https://developers.ploomes.com/', 6),

('salesforce', 'Salesforce',
 'O maior do mercado enterprise. Server-to-server usa OAuth2 client_credentials, que exige um usuário de execução escolhido na Connected App.',
 '[{"chave":"client_id","rotulo":"Consumer key","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Connected App com Enable Client Credentials Flow ligado"},
   {"chave":"client_secret","rotulo":"Consumer secret","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Da mesma Connected App"},
   {"chave":"dominio","rotulo":"My Domain URL","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"https://sua-empresa.my.salesforce.com — o instance_url da resposta do token pode diferir e é ele que vale para os dados"}]'::jsonb,
 'https://help.salesforce.com/s/articleView?id=xcloud.remoteaccess_oauth_client_credentials_flow.htm&type=5', 7),

('zoho_crm', 'Zoho CRM',
 'Barato e completo, forte em operação que já usa o resto do Zoho. A conta vive num data center específico e o endereço de token muda com ele — escolher errado devolve erro de credencial inválida com credencial correta.',
 '[{"chave":"client_id","rotulo":"Client ID","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Zoho API Console, Self Client ou Server-based"},
   {"chave":"client_secret","rotulo":"Client secret","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Do mesmo cliente do API Console"},
   {"chave":"refresh_token","rotulo":"Refresh token","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Gerado uma vez com escopo ZohoCRM.modules.ALL; não expira"},
   {"chave":"data_center","rotulo":"Data center","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"com, eu, in, com.au, jp, ca ou com.cn — o sufixo do accounts.zoho.SEU-DC"}]'::jsonb,
 'https://www.zoho.com/crm/developer/docs/api/v8/access-refresh.html', 8);

COMMENT ON COLUMN crm_provider_catalog.campos IS
  'Conferido na documentação de cada provedor, não escrito de memória: esquema
   de autenticação troca de versão, e campo errado aqui vira credencial
   guardada com nome que nenhum adapter vai procurar. docs_url é a página que
   foi lida. O Softcare não tem docs_url porque é nosso — o contrato dele se
   confirma com quem o mantém, não com uma página pública.';
