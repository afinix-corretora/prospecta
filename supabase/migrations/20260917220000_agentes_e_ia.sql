-- Agentes de canal e provedores de IA.
--
-- Fronteira que define tudo aqui: o motor é dono da cadência; o agente é dono
-- da conversa. O motor decide quando tocar e por onde; quando a pessoa
-- responde, o enrollment encerra (invariante 4) e o agente assume dali.
-- Agente não acelera passo, não troca canal e não reescreve cadência — se
-- fizesse, seriam dois donos do mesmo estado.
--
-- Um agente é a persona de UM canal. "Responder WhatsApp" e "responder
-- Instagram" são trabalhos diferentes: janela de resposta, tom, tamanho de
-- mensagem e o que se pode mandar mudam. Por isso agente tem canal, e a
-- campanha escolhe um agente por canal habilitado.

-- ---------------------------------------------------------------------------
-- Catálogo de provedores
-- ---------------------------------------------------------------------------

-- Cada provedor declara os campos que precisa. É o que faz a tela de
-- configuração mudar sozinha quando o usuário troca de provedor, sem a UI
-- conhecer provedor nenhum.
CREATE TABLE ai_provider_catalog (
  slug              text PRIMARY KEY,
  nome              text NOT NULL,
  descricao         text NOT NULL,
  -- [{chave, rotulo, tipo, obrigatorio, segredo, ajuda}]
  campos            jsonb NOT NULL,
  modelos_sugeridos jsonb NOT NULL DEFAULT '[]'::jsonb,
  docs_url          text,
  ordem             integer NOT NULL DEFAULT 0,
  CONSTRAINT ai_provider_catalog_campos_nao_vazio CHECK (jsonb_array_length(campos) > 0)
);

COMMENT ON COLUMN ai_provider_catalog.modelos_sugeridos IS
  'Sugestões, não lista fechada — catálogo de modelo muda toda semana e lista
   fixa envelhece. O campo de modelo aceita texto livre.';

-- ---------------------------------------------------------------------------
-- Credenciais
-- ---------------------------------------------------------------------------

-- Não existe coluna para a chave. Só o ponteiro para o Vault: o que não tem
-- onde ser guardado errado não é guardado errado.
CREATE TABLE ai_credentials (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome            text NOT NULL,
  provedor        text NOT NULL REFERENCES ai_provider_catalog(slug),
  modelo          text NOT NULL,
  chave_secret_id uuid,
  -- Só campos não-secretos: base_url, organização, região.
  config          jsonb NOT NULL DEFAULT '{}'::jsonb,
  ativo           boolean NOT NULL DEFAULT true,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ai_credentials_nome_uk UNIQUE (nome)
);

-- Anti-regra "nunca colocar secret fora do Vault", verificada pelo banco.
-- O catálogo diz quais campos são segredo; gravar qualquer um deles em
-- `config` é recusado.
CREATE FUNCTION barrar_segredo_em_config() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_proibida text;
BEGIN
  SELECT c ->> 'chave' INTO v_proibida
    FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = NEW.provedor
     AND (c ->> 'segredo')::boolean
     AND NEW.config ? (c ->> 'chave')
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION
      'campo % é segredo e não pode ir em config — use o Vault (chave_secret_id)',
      v_proibida
      USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER ai_credentials_sem_segredo
  BEFORE INSERT OR UPDATE ON ai_credentials
  FOR EACH ROW EXECUTE FUNCTION barrar_segredo_em_config();

-- ---------------------------------------------------------------------------
-- Agentes
-- ---------------------------------------------------------------------------

CREATE TABLE agents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome              text NOT NULL,
  canal             canal NOT NULL,
  papel             text NOT NULL,
  descricao         text NOT NULL,
  -- O corpo detalhado: o que o agente faz, como fala, o que não pode fazer.
  instrucoes        text NOT NULL,
  ai_credential_id  uuid REFERENCES ai_credentials(id),
  -- Quando passar a conversa para gente de verdade.
  escalar_quando    text NOT NULL DEFAULT 'Pedido de proposta formal, reclamação ou dúvida sobre cobertura específica.',
  -- Teto de trocas antes de escalar. Agente que conversa para sempre é agente
  -- que nunca entrega o lead.
  limite_trocas     integer NOT NULL DEFAULT 10,
  pronto            boolean NOT NULL DEFAULT false,
  ativo             boolean NOT NULL DEFAULT true,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT agents_nome_uk UNIQUE (nome),
  CONSTRAINT agents_instrucoes_substanciais CHECK (length(trim(instrucoes)) >= 120),
  CONSTRAINT agents_limite_positivo CHECK (limite_trocas BETWEEN 1 AND 100)
);

COMMENT ON COLUMN agents.pronto IS
  'Agente do catálogo — o "modelo pré-definido de agente para aquele canal".';

CREATE INDEX agents_canal_idx ON agents (canal) WHERE ativo;

-- ---------------------------------------------------------------------------
-- Agente por canal dentro da campanha
-- ---------------------------------------------------------------------------

CREATE TABLE campaign_agents (
  campaign_id uuid NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
  canal       canal NOT NULL,
  agent_id    uuid NOT NULL REFERENCES agents(id),
  criado_em   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (campaign_id, canal)
);

COMMENT ON TABLE campaign_agents IS
  'Uma persona por canal por campanha. A chave primária composta é a regra:
   dois agentes no mesmo WhatsApp da mesma campanha seriam duas pessoas
   diferentes respondendo o mesmo contato.';

CREATE FUNCTION validar_agente_da_campanha() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE a agents%ROWTYPE; c campaigns%ROWTYPE;
BEGIN
  SELECT * INTO a FROM agents WHERE id = NEW.agent_id;
  SELECT * INTO c FROM campaigns WHERE id = NEW.campaign_id;

  IF NOT a.ativo THEN
    RAISE EXCEPTION 'agente % está inativo', a.nome USING ERRCODE = 'restrict_violation';
  END IF;

  -- Agente de Instagram atendendo WhatsApp responderia com o tom, o tamanho e
  -- as regras do canal errado.
  IF a.canal <> NEW.canal THEN
    RAISE EXCEPTION 'agente % é de %, não de %', a.nome, a.canal, NEW.canal
      USING ERRCODE = 'restrict_violation';
  END IF;

  IF NOT (NEW.canal = ANY (c.canais_habilitados)) THEN
    RAISE EXCEPTION 'campanha % não usa o canal %', c.nome, NEW.canal
      USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER campaign_agents_valida
  BEFORE INSERT OR UPDATE ON campaign_agents
  FOR EACH ROW EXECUTE FUNCTION validar_agente_da_campanha();

-- Atribui derivando o canal do próprio agente: um argumento a menos para
-- errar.
CREATE FUNCTION atribuir_agente(p_campaign_id uuid, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_canal canal;
BEGIN
  SELECT canal INTO v_canal FROM agents WHERE id = p_agent_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'agente inexistente: %', p_agent_id USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO campaign_agents (campaign_id, canal, agent_id)
  VALUES (p_campaign_id, v_canal, p_agent_id)
  ON CONFLICT (campaign_id, canal) DO UPDATE SET agent_id = EXCLUDED.agent_id;
END;
$$;

-- Quem responde por este canal nesta campanha.
CREATE FUNCTION agente_do_canal(p_campaign_id uuid, p_canal canal)
RETURNS agents
LANGUAGE sql STABLE AS $$
  SELECT a.* FROM campaign_agents ca JOIN agents a ON a.id = ca.agent_id
   WHERE ca.campaign_id = p_campaign_id AND ca.canal = p_canal AND a.ativo;
$$;

-- ---------------------------------------------------------------------------
-- Catálogo inicial de provedores
-- ---------------------------------------------------------------------------

INSERT INTO ai_provider_catalog (slug, nome, descricao, campos, modelos_sugeridos, docs_url, ordem) VALUES

('anthropic', 'Anthropic (Claude)',
 'Bom em seguir instrução longa e não sair do papel — útil quando o agente tem regra de compliance.',
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Começa com sk-ant-"},
   {"chave":"base_url","rotulo":"Base URL","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Só para proxy ou gateway próprio"}]'::jsonb,
 '["claude-opus-5","claude-sonnet-5","claude-haiku-4-5","claude-fable-5-1"]'::jsonb,
 'https://docs.claude.com/en/api', 1),

('openai', 'OpenAI',
 'O mais conhecido. Ecossistema grande e latência baixa nos modelos menores.',
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Começa com sk-"},
   {"chave":"organizacao","rotulo":"Organization ID","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Só se a conta tiver mais de uma organização"},
   {"chave":"base_url","rotulo":"Base URL","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Para Azure OpenAI ou gateway próprio"}]'::jsonb,
 '[]'::jsonb, 'https://platform.openai.com/docs', 2),

('google', 'Google Gemini',
 'Janela de contexto grande e preço competitivo no tier rápido.',
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Google AI Studio"},
   {"chave":"projeto","rotulo":"Projeto (Vertex)","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Só ao usar Vertex AI"},
   {"chave":"regiao","rotulo":"Região (Vertex)","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"ex.: us-central1"}]'::jsonb,
 '[]'::jsonb, 'https://ai.google.dev/docs', 3),

('perplexity', 'Perplexity',
 'Responde com busca na web embutida — serve quando o agente precisa de informação atual.',
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Começa com pplx-"}]'::jsonb,
 '[]'::jsonb, 'https://docs.perplexity.ai', 4),

('deepseek', 'DeepSeek',
 'Custo baixo por token. Boa opção para agente de triagem em volume alto.',
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":null},
   {"chave":"base_url","rotulo":"Base URL","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Padrão: https://api.deepseek.com"}]'::jsonb,
 '[]'::jsonb, 'https://api-docs.deepseek.com', 5),

('openrouter', 'OpenRouter',
 'Um endpoint para vários provedores. Útil para testar modelo novo sem abrir conta nova.',
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Começa com sk-or-"},
   {"chave":"referer","rotulo":"HTTP-Referer","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Identifica a aplicação no ranking do OpenRouter"}]'::jsonb,
 '[]'::jsonb, 'https://openrouter.ai/docs', 6),

('compativel', 'Endpoint compatível',
 'Qualquer API no formato OpenAI — modelo local, vLLM, Together, Groq.',
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":null},
   {"chave":"base_url","rotulo":"Base URL","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Endereço completo, ex.: https://api.exemplo.com/v1"}]'::jsonb,
 '[]'::jsonb, NULL, 7);

-- ---------------------------------------------------------------------------
-- Agentes prontos, um por canal
-- ---------------------------------------------------------------------------

INSERT INTO agents (nome, canal, papel, descricao, instrucoes, escalar_quando, limite_trocas, pronto) VALUES

('Ana — resgate no WhatsApp', 'whatsapp', 'Retomada de conversa',
 'Responde quem reagiu a uma campanha de resgate. Reabre o assunto e marca conversa com o corretor.',
 'Você atende pelo WhatsApp da Afinix Corretora, respondendo pessoas que já conversaram com a corretora antes e voltaram a responder agora.

Como falar: português do Brasil, tom de quem já conhece a pessoa. Mensagens curtas, de uma ou duas frases — no WhatsApp texto longo não é lido. Sem emoji em excesso, no máximo um. Nunca escreva em caixa alta.

O que fazer, nesta ordem:
1. Retome o assunto de onde parou, sem pedir para a pessoa repetir o que já disse.
2. Confirme se ainda faz sentido: plano individual ou empresarial, quantas vidas, cidade.
3. Se fizer sentido, ofereça horário para o corretor ligar. Proponha dois horários concretos.

O que nunca fazer: prometer valor, prazo de carência, cobertura ou reembolso. Você não cota. Se a pessoa insistir em preço, diga que o corretor fecha o número porque depende de idade e operadora.

Se a pessoa pedir para não ser mais contatada, confirme em uma frase e encerre. Não tente reverter.',
 'Pedido de proposta formal, pergunta sobre cobertura específica, reclamação, ou menção a processo ou órgão regulador.',
 8, true),

('Caio — prospecção fria no WhatsApp', 'whatsapp', 'Qualificação inicial',
 'Primeiro contato com quem nunca falou com a corretora. Descobre se há encaixe antes de gastar tempo do corretor.',
 'Você faz o primeiro contato pelo WhatsApp com empresas que nunca falaram com a Afinix Corretora.

Como falar: direto e curto. A pessoa não pediu esse contato, então cada mensagem precisa justificar a próxima. Uma pergunta por vez. Sem "tudo bem?" seguido de parágrafo de venda.

Primeira coisa: diga quem você é e por que está falando, em uma frase. Depois pergunte apenas se a empresa já tem plano de saúde para os funcionários.

Qualifica se: tem CNPJ ativo, mais de duas vidas, e demonstra interesse em ouvir proposta.
Não qualifica se: pessoa física sozinha, já renovou há menos de dois meses, ou responde só por educação.

O que nunca fazer: insistir depois de uma negativa, mandar mais de uma mensagem seguida sem resposta, prometer preço, ou dizer que é "da operadora". Você é de uma corretora.

Qualquer sinal de incômodo — "quem passou meu número", "não quero", "para de mandar" — confirme a remoção em uma frase e encerre. Isso vale mais que qualquer lead.',
 'Empresa qualificada e interessada, pedido de proposta, ou qualquer pergunta jurídica sobre origem do contato.',
 6, true),

('Bia — direct do Instagram', 'instagram', 'Atendimento na janela de 24h',
 'Responde quem chamou no direct. Trabalha só dentro da janela em que a resposta é permitida.',
 'Você responde o direct do Instagram da Afinix Corretora. Só entram aqui conversas que a própria pessoa começou.

Como falar: mais leve que no WhatsApp, o Instagram é um canal informal. Frases curtas. Pode usar um emoji quando couber, nunca mais de um por mensagem.

O que fazer: entenda o que a pessoa quer — cotação, dúvida sobre plano que já tem, ou informação sobre um post. Se for cotação, pergunte cidade, idade e se é para pessoa física ou empresa, uma pergunta de cada vez.

Restrição de canal que não pode ser ignorada: você só pode responder dentro da janela de 24 horas desde a última mensagem da pessoa. Passou disso, não mande nada — nem "oi, ainda está aí?". Se a conversa precisa continuar depois, peça o WhatsApp dentro da janela.

O que nunca fazer: cotar valor, falar de carência, ou pedir CPF, cartão ou qualquer dado sensível pelo direct.',
 'Pedido de cotação completa, dúvida sobre apólice existente, ou pedido de dado pessoal que não pode ir pelo direct.',
 10, true),

('Edu — atendimento por e-mail', 'email', 'Resposta escrita',
 'Lê e responde e-mails de campanha. Formato mais longo, com espaço para explicar.',
 'Você responde e-mails recebidos em resposta às campanhas da Afinix Corretora.

Como falar: português do Brasil, formal mas não empolado. E-mail comporta explicação — aqui você pode usar dois ou três parágrafos curtos, ou uma lista quando houver opções a comparar. Sempre com assunto claro e saudação com o nome da pessoa.

O que fazer:
1. Responda a pergunta que foi feita, antes de qualquer outra coisa.
2. Se a pessoa pediu comparação, apresente as opções em lista, sem valores.
3. Feche com um próximo passo concreto: uma ligação, um horário, um documento que você precisa.

O que nunca fazer: anexar proposta, citar valor, prometer cobertura, ou responder pergunta sobre sinistro em andamento — isso é do time de atendimento, não seu.

Se o e-mail for um pedido de descadastro, confirme em uma linha, informe que a remoção é imediata e não mande mais nada.',
 'Pedido de proposta formal, reclamação, dúvida sobre sinistro, ou qualquer assunto de apólice já ativa.',
 6, true),

('Rita — confirmação por SMS', 'sms', 'Confirmação curta',
 'Trata respostas de SMS. Canal de uma linha: confirma intenção e passa para outro canal.',
 'Você trata respostas recebidas por SMS nas campanhas da Afinix Corretora.

Restrição do canal, que manda em tudo: 160 caracteres. Sua resposta cabe em uma mensagem, sempre. Não existe conversa longa aqui — o SMS confirma uma intenção e move a conversa para onde ela cabe.

O que fazer: se a pessoa respondeu SIM ou algo equivalente, confirme e diga que o corretor vai chamar no WhatsApp hoje. Se respondeu qualquer coisa que indique saída — SAIR, PARE, NAO — confirme a remoção em uma linha.

O que nunca fazer: mandar link encurtado, pedir dado pessoal, mandar duas mensagens seguidas, ou tentar cotar. Se a pessoa fez uma pergunta que não cabe em 160 caracteres, diga que vai continuar pelo WhatsApp e pare por aqui.',
 'Qualquer pergunta que não caiba em uma mensagem, ou pedido de contato com pessoa.',
 3, true);
