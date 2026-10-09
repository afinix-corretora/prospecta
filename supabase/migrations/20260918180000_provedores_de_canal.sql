-- Catálogo de provedores de canal — o mesmo padrão do D17, agora para contato.
--
-- `sender_accounts.provedor` era texto livre, com um comentário explicando que
-- CHECK faria cada provedor novo exigir migration. O comentário estava certo
-- sobre o CHECK e errado sobre a conclusão: o jeito de não precisar de
-- migration é catálogo, não texto solto. Com catálogo, provedor novo é uma
-- linha; com texto solto, um typo em `provedor` vira remetente que o
-- despachante não sabe construir, e isso só aparece na hora do envio.
--
-- O catálogo também carrega os campos que cada provedor precisa, então a tela
-- de "conectar conta" se monta sozinha — escolher Gupshup mostra API key, app
-- e número; escolher Evolution mostra URL da instância. Nenhum código de UI
-- conhece provedor nenhum.
--
-- Múltiplas contas por provedor é o caso normal, não a exceção: cada conta da
-- Gupshup é um `sender_account` com `provedor = 'gupshup'` e o seu próprio
-- segredo no Vault. É assim que o pool e a quota por remetente (invariante 3)
-- continuam valendo sem nada de novo.

CREATE TABLE channel_provider_catalog (
  slug        text PRIMARY KEY,
  canal       canal NOT NULL,
  nome        text NOT NULL,
  descricao   text NOT NULL,
  -- Oficial = API da própria plataforma (direta ou via BSP homologado).
  -- Não oficial = automação de cliente. Muda risco de banimento (D11) e a
  -- base contratual, então é estrutural, não rótulo.
  oficial     boolean NOT NULL,
  -- Provedor sem adapter não vira opção de envio: o motor recusa antes de
  -- prometer, em vez de falhar na hora do disparo.
  tem_adapter boolean NOT NULL DEFAULT false,
  -- [{chave, rotulo, tipo, obrigatorio, segredo, ajuda}] — igual ao de IA.
  campos      jsonb NOT NULL,
  docs_url    text,
  ordem       integer NOT NULL DEFAULT 0,
  ativo       boolean NOT NULL DEFAULT true,
  CONSTRAINT channel_provider_catalog_campos_nao_vazio
    CHECK (jsonb_array_length(campos) > 0)
);

COMMENT ON TABLE channel_provider_catalog IS
  'Software, não dado de cliente: é o mesmo para todos os tenants. Provedor
   novo é uma linha aqui mais uma classe em adapters/, nada no motor.';

ALTER TABLE channel_provider_catalog ENABLE ROW LEVEL SECURITY;
CREATE POLICY channel_provider_catalog_sel
  ON channel_provider_catalog FOR SELECT USING (true);

-- ---------------------------------------------------------------------------
-- A conta passa a apontar para o catálogo
-- ---------------------------------------------------------------------------

ALTER TABLE sender_accounts
  -- Campos não-secretos do provedor: app da Gupshup, URL da instância
  -- Evolution, remetente da Comtele. O segredo continua só no Vault.
  ADD COLUMN config jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Nome que a pessoa dá para a conta. "+55 11 9..." não diz de quem é.
  ADD COLUMN apelido text;

COMMENT ON COLUMN sender_accounts.config IS
  'Só campo não-secreto. O que o catálogo marca como segredo é recusado aqui
   por gatilho — mesma garantia de ai_credentials.';

-- Provedor sem catálogo é remetente que o despachante não sabe construir.
ALTER TABLE sender_accounts
  ADD CONSTRAINT sender_accounts_provedor_fkey
  FOREIGN KEY (provedor) REFERENCES channel_provider_catalog(slug);

-- O provedor tem que falar o canal da conta: conta de SMS com provedor de
-- WhatsApp é erro de cadastro que só apareceria na hora do disparo.
-- Nasce em `privado` e com search_path fixo: é gatilho, não API (D19). O
-- teste de superfície pegou isto quando a função foi criada em `public`.
CREATE FUNCTION privado.validar_provedor_do_remetente() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE p channel_provider_catalog%ROWTYPE; v_proibida text;
BEGIN
  SELECT * INTO p FROM channel_provider_catalog WHERE slug = NEW.provedor;

  IF p.canal <> NEW.canal THEN
    RAISE EXCEPTION 'provedor % é de %, não de %', p.nome, p.canal, NEW.canal
      USING ERRCODE = 'restrict_violation';
  END IF;

  IF NOT p.ativo THEN
    RAISE EXCEPTION 'provedor % está inativo', p.nome USING ERRCODE = 'restrict_violation';
  END IF;

  -- Mesma garantia de ai_credentials: o que é segredo não tem onde ser
  -- gravado errado, porque o banco recusa.
  SELECT c ->> 'chave' INTO v_proibida
    FROM jsonb_array_elements(p.campos) c
   WHERE (c ->> 'segredo')::boolean AND NEW.config ? (c ->> 'chave')
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION
      'campo % é segredo e não pode ir em config — use o Vault (credenciais_secret_id)',
      v_proibida USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER sender_accounts_valida_provedor
  BEFORE INSERT OR UPDATE ON sender_accounts
  FOR EACH ROW EXECUTE FUNCTION privado.validar_provedor_do_remetente();

-- ---------------------------------------------------------------------------
-- O catálogo
-- ---------------------------------------------------------------------------

INSERT INTO channel_provider_catalog
  (slug, canal, nome, descricao, oficial, tem_adapter, campos, docs_url, ordem) VALUES

-- WhatsApp oficial via BSP. É o caminho escolhido para a operação oficial:
-- múltiplas contas e múltiplas apps da Gupshup convivem como remetentes
-- separados, cada um com sua quota e seu segredo.
('gupshup', 'whatsapp', 'Gupshup (WhatsApp oficial)',
 'API oficial do WhatsApp via BSP homologado. Cada app da Gupshup é uma conta aqui, com quota e segredo próprios.',
 true, true,
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Gupshup → Dashboard → API key"},
   {"chave":"app_name","rotulo":"Nome da app","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"O app name cadastrado na Gupshup, não o número"},
   {"chave":"source","rotulo":"Número de origem","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Com DDI, só dígitos — ex.: 5511999990000"},
   {"chave":"base_url","rotulo":"Base URL","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Padrão: https://api.gupshup.io/wa/api/v1"}]'::jsonb,
 'https://docs.gupshup.io', 1),

('meta_cloud', 'whatsapp', 'Meta Cloud API',
 'API oficial direto na Meta, sem intermediário. Alternativa à Gupshup quando a conta já é própria.',
 true, true,
 '[{"chave":"token","rotulo":"Access token","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Token permanente do app da Meta"},
   {"chave":"phone_number_id","rotulo":"Phone number ID","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Não é o número: é o ID que a Meta dá a ele"},
   {"chave":"waba_id","rotulo":"WABA ID","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Conta comercial do WhatsApp"}]'::jsonb,
 'https://developers.facebook.com/docs/whatsapp/cloud-api', 2),

-- Não oficial: automação de cliente. D11 trata banimento como custo previsto,
-- e D4 mantém esse pool longe do número institucional.
('evolution', 'whatsapp', 'Evolution API (não oficial)',
 'Automação de WhatsApp comum, sem homologação. Serve a campanha fria; nunca ao número institucional (D4).',
 false, true,
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"A apikey global ou da instância"},
   {"chave":"base_url","rotulo":"URL da instância","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Ex.: https://evo.suaempresa.com.br"},
   {"chave":"instancia","rotulo":"Nome da instância","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Como está cadastrada na Evolution"}]'::jsonb,
 'https://doc.evolution-api.com', 3),

('comtele', 'sms', 'Comtele',
 'SMS no Brasil. Remetente é alfanumérico ou short code, conforme o contrato.',
 true, true,
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Comtele → Painel → Chaves de API"},
   {"chave":"remetente","rotulo":"Remetente","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Alfanumérico, se o contrato permitir"}]'::jsonb,
 'https://docs.comtele.com.br', 4),

('smtp', 'email', 'SMTP',
 'Caixa de saída própria. Campanha fria usa domínio separado do institucional (D4).',
 true, false,
 '[{"chave":"senha","rotulo":"Senha","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":null},
   {"chave":"host","rotulo":"Servidor","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Ex.: smtp.suaempresa.com.br"},
   {"chave":"porta","rotulo":"Porta","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"587 com STARTTLS, 465 com TLS"},
   {"chave":"usuario","rotulo":"Usuário","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":null}]'::jsonb,
 NULL, 5),

('instagram_oficial', 'instagram', 'Instagram (Graph API)',
 'Direct pela API oficial. Só responde dentro da janela de 24h aberta pela própria pessoa (D10).',
 true, false,
 '[{"chave":"token","rotulo":"Access token","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Token da página ligada ao perfil"},
   {"chave":"ig_user_id","rotulo":"Instagram user ID","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"ID profissional, não o @"}]'::jsonb,
 'https://developers.facebook.com/docs/messenger-platform/instagram', 6);
