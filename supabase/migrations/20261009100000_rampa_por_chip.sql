-- D75: a rampa de volume por chip.
--
-- Chip novo que começa mandando a quota cheia é o jeito mais rápido de perder
-- o número. A rampa é um TETO que sobe: no primeiro dia o chip manda pouco, e
-- cresce até a quota configurada. Nada aqui simula uso humano — o que sobe é
-- o volume de mensagem REAL da cadência.
--
-- Três decisões, e cada uma tem o seu porquê:
--
-- 1. `quota_diaria` NÃO é reescrita. Ela continua sendo o alvo que a pessoa
--    configurou; o teto de hoje é DERIVADO dela. Um job que reescrevesse a
--    coluna todo dia perderia o alvo e seria um modelo de lote, que é o que
--    este motor não é.
--
-- 2. A rampa anda em dias que o chip MANDOU DE VERDADE, não em dias de
--    calendário. Chip parado uma semana não construiu reputação nenhuma;
--    deixá-lo acordar no teto do dia 7 é exatamente o risco que a rampa existe
--    para evitar. E `simulado` não conta: em shadow mode o motor escolhe e
--    reserva remetente igual (D36), mas nada sai, então nada aquece. Por isso
--    existe `enviados_reais_na_janela`, escrito só por
--    `registrar_resultado_envio` quando o envio deu certo.
--
-- 3. A rampa é opt-in. `rampa_dias IS NULL` é o comportamento de sempre, byte
--    por byte. Ligar a rampa num chip que já roda é decisão de quem opera, não
--    efeito colateral desta migration.
--
-- O teto entra nos QUATRO lugares que hoje comparam o contador com a quota —
-- a reserva, o pool, e os dois adiamentos. Mexer num e esquecer o outro é o
-- D37 e o D40 de novo: o pool oferecendo o que a reserva recusa, ou o passo
-- adiado para um horário que não é o que o teto manda. Os quatro corpos abaixo
-- partem do que ESTÁ no projeto (`pg_get_functiondef`, 09/10), não de cópia
-- antiga (D59).

-- ---------------------------------------------------------------------------
-- O que o chip guarda
-- ---------------------------------------------------------------------------

ALTER TABLE sender_accounts
  ADD COLUMN rampa_dias    integer,
  ADD COLUMN rampa_inicial integer,
  ADD COLUMN rampa_dia     integer NOT NULL DEFAULT 1,
  ADD COLUMN enviados_reais_na_janela integer NOT NULL DEFAULT 0,

  -- Os dois parâmetros andam juntos: meia rampa seria um teto sem alvo ou um
  -- alvo sem teto.
  ADD CONSTRAINT sender_accounts_rampa_completa CHECK (
    (rampa_dias IS NULL AND rampa_inicial IS NULL)
    OR (rampa_dias IS NOT NULL AND rampa_inicial IS NOT NULL)
  ),
  ADD CONSTRAINT sender_accounts_rampa_faixa CHECK (
    rampa_dias IS NULL OR (rampa_dias BETWEEN 1 AND 365 AND rampa_inicial >= 1)
  ),
  ADD CONSTRAINT sender_accounts_rampa_dia_positivo CHECK (rampa_dia >= 1),
  -- Sem teto superior amarrado a `enviados_na_janela`: a janela vira dentro de
  -- `reservar_envio` e o resultado do envio chega depois, então os dois
  -- contadores podem se cruzar na virada. Contador que estoura CHECK faria
  -- `registrar_resultado_envio` falhar por um envio que SAIU.
  ADD CONSTRAINT sender_accounts_reais_nao_negativo CHECK (enviados_reais_na_janela >= 0);

COMMENT ON COLUMN sender_accounts.rampa_dias IS
  'D75: em quantos dias DE ENVIO o teto sai de rampa_inicial e chega a quota_diaria. NULL = sem rampa.';
COMMENT ON COLUMN sender_accounts.rampa_inicial IS
  'D75: o teto do primeiro dia da rampa. Pode passar de quota_diaria sem efeito: o teto nunca ultrapassa a quota.';
COMMENT ON COLUMN sender_accounts.rampa_dia IS
  'D75: em que dia da rampa o chip está. Anda +1 na virada da janela, e só se a janela que fechou teve envio real.';
COMMENT ON COLUMN sender_accounts.enviados_reais_na_janela IS
  'D75: envios que SAÍRAM na janela. Escrito por registrar_resultado_envio(ok). Em simulado fica 0, porque shadow mode não aquece chip.';

-- ---------------------------------------------------------------------------
-- O teto de hoje
-- ---------------------------------------------------------------------------

-- Reta de `rampa_inicial` até `quota_diaria` em `rampa_dias` dias de envio.
--
-- IMMUTABLE e sem leitura de tabela de propósito: é aritmética, entra em
-- expressão de qualquer um dos quatro leitores, e tem teste próprio. Existe
-- UMA implementação desta conta — a tela lê o resultado por
-- `rampa_dos_chips`, em vez de repetir a fórmula em TypeScript (D55).
CREATE FUNCTION privado.teto_da_rampa(
  p_quota    integer,
  p_dias     integer,
  p_inicial  integer,
  p_dia      integer
) RETURNS integer
LANGUAGE sql IMMUTABLE
-- `pg_catalog` e não `public, privado` como as vizinhas: esta função não
-- resolve nome de objeto nenhum — só `least`, `greatest`, `round` e
-- `coalesce`, que são do catálogo. Sem a cláusula, o advisor acusa
-- `search_path` mutável (a classe do D19), e um `round` plantado num schema
-- à frente mudaria a conta do teto. O custo é não poder ser inlined pelo
-- planner; com uma dezena de chips no pool, não se mede.
SET search_path = pg_catalog
AS $$
  SELECT CASE
    -- Sem rampa, ou rampa vencida: o alvo configurado, como sempre foi.
    WHEN p_dias IS NULL OR p_inicial IS NULL THEN p_quota
    WHEN coalesce(p_dia, 1) >= p_dias THEN p_quota
    WHEN p_dias <= 1 THEN p_quota
    ELSE least(
      p_quota,
      greatest(
        1,
        p_inicial + round(
          (p_quota - p_inicial)::numeric * (coalesce(p_dia, 1) - 1) / (p_dias - 1)
        )::integer
      )
    )
  END;
$$;

COMMENT ON FUNCTION privado.teto_da_rampa IS
  'D75: o teto de envio de hoje. Reta do inicial até a quota em `dias` dias DE ENVIO; nunca passa da quota.';

-- ---------------------------------------------------------------------------
-- Os quatro leitores do teto
-- ---------------------------------------------------------------------------

-- 1. A reserva. É aqui que a invariante 3 de fato acontece, e é aqui que a
-- rampa anda: na virada da janela, se a janela que fechou teve envio real.
--
-- A ordem dentro do UPDATE importa: `rampa_dia` é decidido LENDO
-- `enviados_reais_na_janela` antes de ele ser zerado, o que num UPDATE só o
-- Postgres garante (todas as expressões leem a linha velha). Zerar primeiro e
-- decidir depois nunca avançaria a rampa.
--
-- Anda +1 por virada, não pelos dias passados: três dias parado é UM dia de
-- envio fechado, não três.
CREATE OR REPLACE FUNCTION privado.reservar_envio(p_sender_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  v_ok boolean;
BEGIN
  -- Vira a janela antes de avaliar a quota, e faz a rampa andar.
  UPDATE sender_accounts
     SET janela = current_date,
         rampa_dia = CASE
           WHEN rampa_dias IS NOT NULL AND enviados_reais_na_janela > 0
             THEN least(rampa_dia + 1, rampa_dias)
           ELSE rampa_dia
         END,
         enviados_na_janela = 0,
         enviados_reais_na_janela = 0
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
     AND enviados_na_janela < privado.teto_da_rampa(
           quota_diaria, rampa_dias, rampa_inicial, rampa_dia)
  RETURNING true INTO v_ok;

  RETURN coalesce(v_ok, false);
END;
$function$;

-- 2. O pool: deixa de oferecer o chip que bateu o teto de HOJE, não o da quota.
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
     AND (sa.janela < current_date
          OR sa.enviados_na_janela < privado.teto_da_rampa(
               sa.quota_diaria, sa.rampa_dias, sa.rampa_inicial, sa.rampa_dia))
     AND p.tem_adapter AND p.ativo
   ORDER BY sa.health_score DESC, sa.enviados_na_janela ASC;
$function$;

-- 3 e 4. Os dois adiamentos. Sem o teto aqui, o passo seria adiado por uma
-- hora em vez de para amanhã — e voltaria a cada hora para ouvir o mesmo não.
CREATE OR REPLACE FUNCTION privado.proximo_horario_de_pool(p_tenant uuid, p_canal canal, p_tipo tipo_campanha)
RETURNS timestamp with time zone
LANGUAGE sql
STABLE
SET search_path TO 'public', 'privado'
AS $function$
  SELECT coalesce(
    min(CASE
      WHEN sa.estado = 'ativo' AND sa.janela >= current_date
           AND sa.enviados_na_janela >= privado.teto_da_rampa(
                 sa.quota_diaria, sa.rampa_dias, sa.rampa_inicial, sa.rampa_dia)
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
           AND sa.enviados_na_janela >= privado.teto_da_rampa(
                 sa.quota_diaria, sa.rampa_dias, sa.rampa_inicial, sa.rampa_dia)
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

-- ---------------------------------------------------------------------------
-- Quem conta o envio que SAIU
-- ---------------------------------------------------------------------------

-- Uma linha nova, no caminho do sucesso: `enviados_reais_na_janela`. É o que
-- separa dia de envio de dia de shadow mode. Corpo partido do projeto (09/10).
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
    -- D75: este envio saiu. É ele que faz a rampa andar na próxima virada.
    UPDATE sender_accounts
       SET enviados_reais_na_janela = enviados_reais_na_janela + 1
     WHERE id = v_sender;
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

-- ---------------------------------------------------------------------------
-- O que a tela lê
-- ---------------------------------------------------------------------------

-- A rampa de cada chip, com o teto JÁ CALCULADO. A tela não repete a fórmula
-- (D55), e não há segunda implementação para divergir.
--
-- SECURITY INVOKER de propósito: quem decide quais linhas é o RLS de
-- `sender_accounts`, que já tem teste. Repetir a política aqui em PL/pgSQL é
-- o que o D41 manda não fazer.
CREATE FUNCTION public.rampa_dos_chips(p_tenant uuid)
RETURNS TABLE (
  sender_id     uuid,
  apelido       text,
  canal         canal,
  quota_diaria  integer,
  rampa_dias    integer,
  rampa_inicial integer,
  rampa_dia     integer,
  teto_hoje     integer,
  enviados_hoje integer,
  reais_hoje    integer
)
LANGUAGE sql
STABLE
SET search_path = public, privado
AS $$
  SELECT sa.id, sa.apelido, sa.canal, sa.quota_diaria,
         sa.rampa_dias, sa.rampa_inicial, sa.rampa_dia,
         privado.teto_da_rampa(sa.quota_diaria, sa.rampa_dias, sa.rampa_inicial, sa.rampa_dia),
         -- A janela vira dentro de `reservar_envio`, então a linha pode estar
         -- com o contador de ontem. Para a tela, dia velho é zero.
         CASE WHEN sa.janela < current_date THEN 0 ELSE sa.enviados_na_janela END,
         CASE WHEN sa.janela < current_date THEN 0 ELSE sa.enviados_reais_na_janela END
    FROM sender_accounts sa
   WHERE sa.tenant_id = p_tenant AND sa.removido_em IS NULL
   ORDER BY sa.canal, sa.apelido;
$$;

COMMENT ON FUNCTION public.rampa_dos_chips IS
  'D75: a rampa de cada chip com o teto de hoje já calculado em SQL, para a tela não reproduzir a fórmula.';

DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION public.rampa_dos_chips(uuid) FROM PUBLIC, anon';
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.rampa_dos_chips(uuid) TO authenticated';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.rampa_dos_chips(uuid) TO service_role';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- A grade: a tela configura a rampa, e não mexe no andamento dela
-- ---------------------------------------------------------------------------

-- `rampa_dias` e `rampa_inicial` são a decisão de quem opera. `rampa_dia` e
-- `enviados_reais_na_janela` ficam de fora: são o andamento, que é do motor —
-- com eles abertos, zerar `rampa_dia` seria desfazer o aquecimento por
-- chamada de PostgREST, e inflar `enviados_reais_na_janela` faria a rampa
-- andar sem envio nenhum. É o D54 na coluna nova.
--
-- O corpo inteiro vem do projeto (09/10) com UMA linha trocada. Partir de
-- cópia antiga apagaria as revogações das vizinhas — foi o que aconteceu no
-- D59, e quem pegou foi um teste de outro assunto.
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
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id, ai_credential_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  -- D75: `rampa_dias` e `rampa_inicial` entram; o andamento da rampa, não.
  GRANT UPDATE (apelido, quota_diaria, estado, rampa_dias, rampa_inicial)
    ON sender_accounts TO authenticated;

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
  -- D66. O agente é da tela, por coluna: o que ele diz, quando passa para
  -- uma pessoa, o que nunca escreve e com que credencial. Fora fica o dono da
  -- linha e `pronto`, que é a marca de agente do catálogo. D69: e se ele
  -- responde sozinho.
  REVOKE UPDATE ON agents FROM authenticated;
  GRANT UPDATE (nome, papel, descricao, instrucoes, ai_credential_id, escalar_quando,
                limite_trocas, ativo, proibido, tamanho_maximo, autonomo)
    ON agents TO authenticated;

  -- O rascunho é do worker: a tela lê. Escrito à mão, seria um texto que
  -- parece ter sido composto pelo agente com os freios dele, sem ter sido —
  -- e, desde o D69, um `envio = 'fila'` sem mensagem nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;
END;
$function$;

-- Dentro de DO: migration que imprime resultado polui o stdout que o
-- `tests/run.sh` captura para nomear o banco.
DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
