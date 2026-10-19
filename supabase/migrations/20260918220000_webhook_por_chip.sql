-- Um endpoint de webhook por chip, e o Vault de verdade.
--
-- Três coisas que estavam abertas fecham aqui.
--
-- 1. D23: nas APIs não oficiais a resposta do contato não cita a nossa
--    mensagem, então não havia como ligar a resposta ao enrollment e a
--    invariante 4 silenciosamente não valia. Agora cada `sender_account` tem
--    a sua URL de webhook; quem recebe sabe de qual chip veio, e daí sai o
--    tenant. Casar pelo número passa a ser possível sem tenant implícito.
--
-- 2. `get_decrypted_meta_token` era chamada pelo worker e não existia em
--    migration nenhuma — nome herdado do legado. Na primeira mensagem real o
--    despachante quebraria em `credenciaisDoRemetente`. Entram helpers
--    próprios, com nome do domínio.
--
-- 3. Provisionar instância exige guardar um segredo que a plataforma acabou de
--    receber do provedor. Sem escrita no Vault isso viraria coluna de texto —
--    exatamente a anti-regra.

-- ---------------------------------------------------------------------------
-- Vault
-- ---------------------------------------------------------------------------

-- EXECUTE dinâmico de propósito: o schema `vault` só existe no Supabase, e o
-- Postgres do teste precisa conseguir aplicar a migration. Referência direta
-- faria a função não compilar fora de produção.
CREATE FUNCTION privado.guardar_segredo(p_nome text, p_valor text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id uuid;
BEGIN
  IF to_regnamespace('vault') IS NULL THEN
    RAISE EXCEPTION 'Vault indisponível: segredo não tem onde ser guardado'
      USING ERRCODE = 'feature_not_supported';
  END IF;
  EXECUTE 'SELECT vault.create_secret($1, $2)' INTO v_id USING p_valor, p_nome;
  RETURN v_id;
END;
$$;

CREATE FUNCTION privado.ler_segredo(p_secret_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v text;
BEGIN
  IF p_secret_id IS NULL OR to_regnamespace('vault') IS NULL THEN RETURN NULL; END IF;
  EXECUTE 'SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = $1'
    INTO v USING p_secret_id;
  RETURN v;
END;
$$;

-- O que o despachante chama. Devolve o JSON de credenciais já decifrado, e
-- nada além disso: quem tem esta função não ganha acesso ao Vault inteiro.
CREATE FUNCTION segredo_do_remetente(p_sender_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id uuid;
BEGIN
  SELECT credenciais_secret_id INTO v_id FROM sender_accounts WHERE id = p_sender_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remetente inexistente: %', p_sender_id USING ERRCODE = 'no_data_found';
  END IF;
  RETURN privado.ler_segredo(v_id);
END;
$$;

COMMENT ON FUNCTION segredo_do_remetente IS
  'Substitui get_decrypted_meta_token, que o worker chamava e não existia.';

CREATE FUNCTION segredo_do_servidor(p_server_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id uuid;
BEGIN
  SELECT admin_secret_id INTO v_id FROM provider_servers WHERE id = p_server_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'servidor inexistente: %', p_server_id USING ERRCODE = 'no_data_found';
  END IF;
  RETURN privado.ler_segredo(v_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- Servidor do provedor: onde as instâncias são criadas
-- ---------------------------------------------------------------------------

-- Não é tabela por canal (anti-regra): é por provedor. Um servidor UAZAPI
-- hospeda N instâncias; cada instância vira um `sender_account`. O mesmo
-- formato serve a uma Evolution self-hosted no dia que precisar.
CREATE TABLE provider_servers (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE
                      DEFAULT privado.tenant_padrao(),
  provedor          text NOT NULL REFERENCES channel_provider_catalog(slug),
  nome              text NOT NULL,
  base_url          text NOT NULL,
  -- O token de administração vive no Vault, como todo o resto. Não existe
  -- coluna para ele, de propósito.
  admin_secret_id   uuid,
  ativo             boolean NOT NULL DEFAULT true,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT provider_servers_nome_uk UNIQUE (tenant_id, nome),
  CONSTRAINT provider_servers_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT provider_servers_base_url_http CHECK (base_url ~ '^https?://')
);

CREATE INDEX provider_servers_tenant_idx ON provider_servers (tenant_id);

COMMENT ON TABLE provider_servers IS
  'Conta de plataforma no provedor: URL e token de admin. É daqui que a
   plataforma cria instância nova sem ninguém entrar no painel do provedor.';

ALTER TABLE provider_servers ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_servers FORCE ROW LEVEL SECURITY;
-- Servidor guarda credencial de admin: leitura e escrita só para quem
-- administra, como em sender_accounts e ai_credentials.
CREATE POLICY provider_servers_sel ON provider_servers FOR SELECT
  USING (privado.pode_administrar(tenant_id));
CREATE POLICY provider_servers_todos ON provider_servers FOR ALL
  USING (privado.pode_administrar(tenant_id))
  WITH CHECK (privado.pode_administrar(tenant_id));

-- De qual servidor a conta nasceu. Nulo para conta cadastrada à mão.
ALTER TABLE sender_accounts
  ADD COLUMN provider_server_id uuid,
  ADD CONSTRAINT sender_accounts_server_tenant_fkey
    FOREIGN KEY (tenant_id, provider_server_id)
    REFERENCES provider_servers (tenant_id, id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- Um endpoint por chip
-- ---------------------------------------------------------------------------

ALTER TABLE sender_accounts
  ADD COLUMN webhook_token uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD CONSTRAINT sender_accounts_webhook_token_uk UNIQUE (webhook_token);

COMMENT ON COLUMN sender_accounts.webhook_token IS
  'A URL do webhook desta conta termina neste token. É o que diz de qual chip
   veio o evento — e, por ele, de qual tenant. Sem isso a resposta sem citação
   não tem como virar encerramento (D23).';

-- O webhook chega sem JWT, então quem resolve é o service_role via RPC.
CREATE FUNCTION resolver_webhook(p_token uuid)
RETURNS TABLE (sender_id uuid, tenant_id uuid, provedor text, canal canal)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, privado AS $$
  SELECT sa.id, sa.tenant_id, sa.provedor, sa.canal
    FROM sender_accounts sa
   WHERE sa.webhook_token = p_token;
$$;

COMMENT ON FUNCTION resolver_webhook IS
  'Token da URL → conta, tenant, provedor. SECURITY DEFINER porque o webhook
   chega sem sessão; o token aleatório é a credencial.';

-- ---------------------------------------------------------------------------
-- Resposta sem citação: casa pelo número (D23)
-- ---------------------------------------------------------------------------

-- Recebe o chip, não o tenant: tenant implícito em assinatura é anti-regra, e
-- aqui ele é derivado de um dado que o chamador tem de verdade.
--
-- Grava o evento na última mensagem que este tenant mandou para esta
-- identidade — que é, literalmente, a mensagem que a pessoa está respondendo.
-- O encerramento continua saindo do gatilho de `message_events`, então a
-- invariante 4 não ganha um segundo caminho: ganha uma segunda entrada para o
-- mesmo caminho.
CREATE FUNCTION registrar_resposta_por_numero(
  p_sender_id   uuid,
  p_valor_norm  text,
  p_ocorrido_em timestamptz DEFAULT now(),
  p_payload     jsonb       DEFAULT '{}'::jsonb
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_tenant uuid; v_canal canal; v_mensagem uuid;
BEGIN
  IF p_payload ->> 'autoria' = 'motor-prospeccao' THEN RETURN false; END IF;

  SELECT tenant_id, canal INTO v_tenant, v_canal
    FROM sender_accounts WHERE id = p_sender_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remetente inexistente: %', p_sender_id USING ERRCODE = 'no_data_found';
  END IF;

  -- A última mensagem para esta identidade, deste tenant, neste canal.
  --
  -- Não filtra pelo chip: a pessoa responde para quem falou com ela, e o pool
  -- pode ter rodado entre um toque e outro.
  --
  -- Não filtra por status, de propósito. `pendente` precisa entrar porque o
  -- webhook pode ganhar do despachante: o provedor entrega, a pessoa responde
  -- e o retorno chega antes de `registrar_resultado_envio` gravar `enviado`.
  -- Filtrar por status perderia exatamente a resposta mais rápida, que é a
  -- mais valiosa. E mesmo numa mensagem que falhou, resposta é resposta —
  -- encerrar a cadência continua sendo o certo.
  SELECT m.id INTO v_mensagem
    FROM messages m
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
   WHERE m.tenant_id = v_tenant
     AND ci.canal = v_canal
     AND ci.valor_norm = p_valor_norm
   ORDER BY m.criado_em DESC
   LIMIT 1;

  -- Número que nunca recebeu nada deste tenant não é resposta a nada. Pode ser
  -- alguém escrevendo do nada para o chip; não é assunto do motor.
  IF v_mensagem IS NULL THEN RETURN false; END IF;

  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em, payload)
  VALUES (v_tenant, v_mensagem, 'respondido', p_ocorrido_em,
          p_payload || jsonb_build_object('casado_por', 'numero'));

  RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- Provisionamento: a instância criada vira conta
-- ---------------------------------------------------------------------------

-- Chamada pela edge function depois de a instância existir no provedor, com o
-- segredo já em mãos. Guardar o segredo e criar a conta numa transação só
-- evita conta sem credencial ou segredo órfão no Vault.
-- `p_webhook_token` vem de fora de propósito. A instância precisa nascer já
-- apontando para o endpoint dela, e o endpoint é o token — então quem
-- provisiona sorteia o token antes de falar com o provedor. Deixar o DEFAULT
-- gerar aqui obrigaria a criar a instância sem webhook e voltar para apontar,
-- o que deixa uma janela em que a resposta do contato se perde.
CREATE FUNCTION criar_remetente_provisionado(
  p_server_id      uuid,
  p_apelido        text,
  p_identificador  text,
  p_tipo_permitido tipo_campanha,
  p_quota_diaria   integer,
  p_credenciais    jsonb,
  p_webhook_token  uuid,
  p_config         jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (sender_id uuid, webhook_token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE s provider_servers%ROWTYPE; v_canal canal; v_segredo uuid; v_id uuid; v_token uuid;
BEGIN
  SELECT * INTO s FROM provider_servers WHERE id = p_server_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'servidor inexistente: %', p_server_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT canal INTO v_canal FROM channel_provider_catalog WHERE slug = s.provedor;

  v_segredo := privado.guardar_segredo(
    'remetente:' || s.provedor || ':' || p_identificador, p_credenciais::text);

  INSERT INTO sender_accounts (
    tenant_id, canal, identificador, apelido, provedor, provider_server_id,
    tipo_permitido, quota_diaria, credenciais_secret_id, config, webhook_token)
  VALUES (
    s.tenant_id, v_canal, p_identificador, p_apelido, s.provedor, s.id,
    p_tipo_permitido, p_quota_diaria, v_segredo, p_config,
    coalesce(p_webhook_token, gen_random_uuid()))
  RETURNING id, sender_accounts.webhook_token INTO v_id, v_token;

  sender_id := v_id; webhook_token := v_token;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- Superfície: nada disto é API de usuário logado
-- ---------------------------------------------------------------------------

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'segredo_do_remetente(uuid)',
    'resolver_webhook(uuid)',
    'registrar_resposta_por_numero(uuid, text, timestamp with time zone, jsonb)',
    'segredo_do_servidor(uuid)',
    'criar_remetente_provisionado(uuid, text, text, tipo_campanha, integer, jsonb, uuid, jsonb)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
    END IF;
  END LOOP;
END;
$$;
