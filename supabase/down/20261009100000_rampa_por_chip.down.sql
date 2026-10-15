-- Desfaz o D75: o teto volta a ser a quota configurada, em todos os quatro
-- lugares. A ordem é restaurar os leitores primeiro e só então apagar a
-- função e as colunas, para nenhum corpo ficar apontando para o que não existe.

CREATE OR REPLACE FUNCTION privado.reservar_envio(p_sender_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  v_ok boolean;
BEGIN
  -- Vira a janela antes de avaliar a quota.
  UPDATE sender_accounts
     SET janela = current_date, enviados_na_janela = 0
   WHERE id = p_sender_id AND janela < current_date;

  -- Fecha o circuito quando o prazo passou.
  UPDATE sender_accounts
     SET estado = 'ativo', falhas_consecutivas = 0, circuito_aberto_ate = NULL
   WHERE id = p_sender_id
     AND estado = 'circuito_aberto'
     AND circuito_aberto_ate IS NOT NULL
     AND circuito_aberto_ate <= now();

  UPDATE sender_accounts
     SET enviados_na_janela = enviados_na_janela + 1
   WHERE id = p_sender_id
     AND estado = 'ativo'
     AND enviados_na_janela < quota_diaria
  RETURNING true INTO v_ok;

  RETURN coalesce(v_ok, false);
END;
$function$;

CREATE OR REPLACE FUNCTION privado.remetentes_disponiveis(p_tenant uuid, p_canal canal, p_tipo tipo_campanha)
RETURNS SETOF sender_accounts
LANGUAGE sql
STABLE
SET search_path TO 'public', 'privado'
AS $function$
  SELECT sa.*
    FROM sender_accounts sa
    JOIN channel_provider_catalog p ON p.slug = sa.provedor
   WHERE sa.tenant_id = p_tenant AND sa.canal = p_canal AND sa.tipo_permitido = p_tipo
     AND sa.estado = 'ativo'
     AND (sa.janela < current_date OR sa.enviados_na_janela < sa.quota_diaria)
     AND p.tem_adapter AND p.ativo
   ORDER BY sa.health_score DESC, sa.enviados_na_janela ASC;
$function$;

CREATE OR REPLACE FUNCTION privado.proximo_horario_de_pool(p_tenant uuid, p_canal canal, p_tipo tipo_campanha)
RETURNS timestamp with time zone
LANGUAGE sql
STABLE
SET search_path TO 'public', 'privado'
AS $function$
  SELECT coalesce(
    min(CASE
      WHEN sa.estado = 'ativo' AND sa.janela >= current_date
           AND sa.enviados_na_janela >= sa.quota_diaria
        THEN (current_date + 1)::timestamptz
      WHEN sa.estado = 'circuito_aberto' AND sa.circuito_aberto_ate IS NOT NULL
        THEN sa.circuito_aberto_ate
    END),
    now() + interval '1 hour')
  FROM sender_accounts sa
  WHERE sa.tenant_id = p_tenant AND sa.canal = p_canal AND sa.tipo_permitido = p_tipo;
$function$;

CREATE OR REPLACE FUNCTION privado.proximo_horario_da_campanha(p_tenant uuid, p_campaign_id uuid, p_canal canal)
RETURNS timestamp with time zone
LANGUAGE sql
STABLE
SET search_path TO 'public', 'privado'
AS $function$
  SELECT coalesce(
    min(CASE
      WHEN sa.estado = 'ativo' AND sa.janela >= current_date
           AND sa.enviados_na_janela >= sa.quota_diaria
        THEN (current_date + 1)::timestamptz
      WHEN sa.estado = 'circuito_aberto' AND sa.circuito_aberto_ate IS NOT NULL
        THEN sa.circuito_aberto_ate
    END),
    now() + interval '1 hour')
  FROM campaigns c
  JOIN sender_accounts sa
    ON sa.tenant_id = c.tenant_id AND sa.canal = p_canal AND sa.tipo_permitido = c.tipo
  WHERE c.id = p_campaign_id AND c.tenant_id = p_tenant
    AND (p_canal <> 'email' OR c.remetente_email_id IS NULL OR sa.id = c.remetente_email_id);
$function$;

CREATE OR REPLACE FUNCTION public.registrar_resultado_envio(
  p_message_id uuid, p_ok boolean, p_provider_id text DEFAULT NULL::text,
  p_erro text DEFAULT NULL::text, p_culpa text DEFAULT 'transitorio'::text
) RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $function$
DECLARE v_sender uuid; v_identidade uuid; v_contato uuid; v_tenant uuid;
BEGIN
  SELECT m.sender_account_id, m.contact_identity_id, e.contact_id, m.tenant_id
    INTO v_sender, v_identidade, v_contato, v_tenant
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = p_message_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'mensagem inexistente: %', p_message_id USING ERRCODE = 'no_data_found';
  END IF;

  IF p_ok THEN
    UPDATE messages SET status = 'enviado', provider_message_id = p_provider_id,
                        reivindicada_em = NULL WHERE id = p_message_id;
    INSERT INTO message_events (tenant_id, message_id, tipo, payload)
    VALUES (v_tenant, p_message_id, 'enviado',
            jsonb_build_object('provider_message_id', p_provider_id));
    PERFORM registrar_sucesso_remetente(v_sender);
    RETURN;
  END IF;

  IF p_culpa NOT IN ('remetente','destino','transitorio') THEN
    RAISE EXCEPTION 'culpa inválida: %', p_culpa USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE messages SET status = 'falha', reivindicada_em = NULL WHERE id = p_message_id;

  INSERT INTO message_events (tenant_id, message_id, tipo, payload)
  VALUES (v_tenant, p_message_id,
          (CASE WHEN p_culpa = 'destino' THEN 'rejeitado' ELSE 'falha' END)::tipo_evento,
          jsonb_build_object('erro', coalesce(p_erro,''), 'culpa', p_culpa));

  IF p_culpa = 'destino' THEN
    UPDATE contact_identities SET valida = false WHERE id = v_identidade;
    INSERT INTO outbox (tenant_id, contact_id, destino, fato, payload)
    VALUES (v_tenant, v_contato, 'crm', 'identidade_invalida',
            jsonb_build_object('contact_identity_id', v_identidade, 'erro', coalesce(p_erro,'')));
  ELSE
    PERFORM registrar_falha_remetente(v_sender);
  END IF;
END;
$function$;

DROP FUNCTION IF EXISTS public.rampa_dos_chips(uuid);

ALTER TABLE sender_accounts
  DROP CONSTRAINT IF EXISTS sender_accounts_rampa_completa,
  DROP CONSTRAINT IF EXISTS sender_accounts_rampa_faixa,
  DROP CONSTRAINT IF EXISTS sender_accounts_rampa_dia_positivo,
  DROP CONSTRAINT IF EXISTS sender_accounts_reais_nao_negativo,
  DROP COLUMN IF EXISTS rampa_dias,
  DROP COLUMN IF EXISTS rampa_inicial,
  DROP COLUMN IF EXISTS rampa_dia,
  DROP COLUMN IF EXISTS enviados_reais_na_janela;

DROP FUNCTION IF EXISTS privado.teto_da_rampa(integer, integer, integer, integer);

-- A grade volta a não conhecer as colunas da rampa.
CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id, ai_credential_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;

  REVOKE INSERT, DELETE ON sender_accounts FROM authenticated;
  GRANT INSERT (tenant_id, canal, provedor, identificador, apelido,
                tipo_permitido, quota_diaria, config)
    ON sender_accounts TO authenticated;

  REVOKE UPDATE ON blacklist_termos, blacklist_dominios FROM authenticated;
  GRANT UPDATE (termo, exige_uma_de, acao, nota, ativo) ON blacklist_termos TO authenticated;
  GRANT UPDATE (nota, ativo) ON blacklist_dominios TO authenticated;

  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;

  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;

  REVOKE INSERT, UPDATE, DELETE ON ai_credentials, crm_connections FROM authenticated;
  GRANT UPDATE (ativo) ON ai_credentials TO authenticated;
  GRANT UPDATE (ativo) ON crm_connections TO authenticated;

  REVOKE INSERT, UPDATE, DELETE ON provider_servers FROM authenticated;

  REVOKE INSERT, UPDATE, DELETE
      ON channel_provider_catalog, ai_provider_catalog, crm_provider_catalog
    FROM authenticated;

  REVOKE INSERT, UPDATE, DELETE ON crm_vinculos, crm_estruturas FROM authenticated;

  REVOKE INSERT, UPDATE ON crm_acoes, crm_fontes FROM authenticated;
  GRANT INSERT (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id, alvo_rotulo, valor, ordem, ativo)
    ON crm_acoes TO authenticated;
  GRANT UPDATE (alvo_id, alvo_rotulo, valor, ordem, ativo) ON crm_acoes TO authenticated;
  GRANT INSERT (tenant_id, conexao_id, nome, pipe_id, pipe_rotulo, fases, mapa,
                campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  GRANT UPDATE (nome, fases, mapa, campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;

  REVOKE UPDATE ON agents FROM authenticated;
  GRANT UPDATE (nome, papel, descricao, instrucoes, ai_credential_id, escalar_quando,
                limite_trocas, ativo, proibido, tamanho_maximo, autonomo)
    ON agents TO authenticated;

  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;
END;
$function$;

-- Dentro de DO: migration que imprime resultado polui o stdout que o
-- `tests/run.sh` captura para nomear o banco.
DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
