-- O e-mail de cada campanha, a conta que se remove sem apagar a história, e a
-- conexão que se confere pela tela (D62).
--
-- O pedido: o cliente cadastra quantos provedores de e-mail quiser (Resend,
-- SMTP Locaweb, mais de uma conta de cada) e, ao rodar a campanha, escolhe UM.
-- Até aqui o e-mail de uma campanha saía por qualquer conta de e-mail do pool
-- certo — o rodízio que vale para chip de WhatsApp. Para e-mail isso não serve:
-- domínio, remetente e reputação são escolha de quem roda a campanha.
--
-- Três decisões, e o que cada uma evita:
--
-- 1. A escolha mora em `campaigns.remetente_email_id`, e quem a respeita é o
--    roteador. `remetentes_da_campanha` é `remetentes_disponiveis` com o filtro
--    da campanha; o agendador E o despachante passam a perguntar a ela, porque
--    escolher no agendador e deixar o despacho rebalancear para outra conta é
--    o D40 outra vez: os dois discordando sobre o mesmo fato. NULL continua
--    sendo o rodízio de antes — é o que as campanhas existentes já fazem, e
--    mudar o comportamento delas em silêncio é pior do que mantê-lo.
--
-- 2. Remover conta é ARQUIVAR. `messages` aponta para a conta com ON DELETE
--    CASCADE, e `message_events` vai junto: apagar uma conta apagava a história
--    de tudo o que ela mandou, e o webhook dela — que ainda recebe bounce de
--    e-mail enviado ontem — deixava de resolver. `removido_em` tira do pool,
--    da tela e da escolha; o DELETE sai do cliente.
--
-- 3. Verificar a conexão é do worker, não da tela. A tela não tem o segredo e
--    não deve ter; a edge function `verificar-remetente` lê do Vault, chama o
--    `checkHealth` do adapter e grava o resultado aqui. A tela só lê.

-- ---------------------------------------------------------------------------
-- A conta: arquivada, e com a última verificação gravada
-- ---------------------------------------------------------------------------

ALTER TABLE sender_accounts
  ADD COLUMN removido_em         timestamptz,
  ADD COLUMN verificado_em       timestamptz,
  ADD COLUMN verificacao_ok      boolean,
  ADD COLUMN verificacao_detalhe text,
  -- Removida e no pool ao mesmo tempo não existe. Sem isto, devolver a conta
  -- ao pool pela tela (`estado`, que a tela escreve) ressuscitava uma conta
  -- que ninguém mais vê.
  ADD CONSTRAINT sender_accounts_removida_fora_do_pool
    CHECK (removido_em IS NULL OR estado = 'desativado');

COMMENT ON COLUMN sender_accounts.removido_em IS
  'D62: arquivada. Fora do pool, da tela e da escolha da campanha; a história e o webhook ficam.';
COMMENT ON COLUMN sender_accounts.verificacao_ok IS
  'D62: resultado do último checkHealth, gravado pela edge function verificar-remetente. Informativo: quem tira a conta do pool é o circuito.';

-- O endereço volta a poder ser cadastrado depois de removido. Com a unicidade
-- valendo também para as arquivadas, "removi e quero cadastrar de novo" só se
-- resolveria apagando — que é o que este arquivo existe para não fazer.
ALTER TABLE sender_accounts DROP CONSTRAINT sender_accounts_identificador_uk;
CREATE UNIQUE INDEX sender_accounts_identificador_uk
  ON sender_accounts (tenant_id, canal, identificador)
  WHERE removido_em IS NULL;

-- ---------------------------------------------------------------------------
-- A campanha escolhe o e-mail
-- ---------------------------------------------------------------------------

ALTER TABLE campaigns
  ADD COLUMN remetente_email_id uuid,
  ADD CONSTRAINT campaigns_remetente_email_tenant_fkey
    FOREIGN KEY (tenant_id, remetente_email_id) REFERENCES sender_accounts (tenant_id, id);

COMMENT ON COLUMN campaigns.remetente_email_id IS
  'D62: a conta de e-mail por onde ESTA campanha manda. NULL = rodízio entre as contas de e-mail do pool, como antes.';

-- O que a escolha precisa ser para o motor conseguir cumpri-la. Cada recusa é
-- uma campanha que, sem ela, adiaria todo passo de e-mail para sempre sem
-- erro nenhum — ou estouraria o D4 dentro do agendador, no meio do lote.
--
-- DEFINER porque o operador escolhe o e-mail da campanha e não enxerga
-- `sender_accounts` (o RLS de lá é de quem administra). A função só LÊ a conta
-- para recusar; não devolve nada dela.
CREATE FUNCTION privado.validar_email_da_campanha()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, privado
AS $$
DECLARE sa sender_accounts%ROWTYPE;
BEGIN
  IF NEW.remetente_email_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Escolher e-mail numa campanha que não manda e-mail é gravar um valor que
  -- o motor não lê (D55).
  IF NOT ('email' = ANY (NEW.canais_habilitados)) THEN
    RAISE EXCEPTION 'a campanha % não usa e-mail: não há provedor de e-mail a escolher', NEW.nome
      USING ERRCODE = 'restrict_violation';
  END IF;

  SELECT * INTO sa FROM sender_accounts
   WHERE tenant_id = NEW.tenant_id AND id = NEW.remetente_email_id;

  IF sa.canal IS DISTINCT FROM 'email' THEN
    RAISE EXCEPTION 'a conta escolhida não é de e-mail'
      USING ERRCODE = 'restrict_violation';
  END IF;

  IF sa.removido_em IS NOT NULL THEN
    RAISE EXCEPTION 'a conta % foi removida', coalesce(sa.apelido, sa.identificador)
      USING ERRCODE = 'restrict_violation';
  END IF;

  -- D4 aqui, e não só no INSERT da mensagem: lá ele é exceção dentro do lote
  -- do agendador. Aqui é uma recusa legível na hora da escolha.
  IF sa.tipo_permitido <> NEW.tipo THEN
    RAISE EXCEPTION 'a conta % é do pool %, e a campanha é %: campanha fria não usa remetente de base própria, nem o contrário (D4)',
      coalesce(sa.apelido, sa.identificador), sa.tipo_permitido, NEW.tipo
      USING ERRCODE = 'restrict_violation';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION privado.validar_email_da_campanha() FROM PUBLIC;

CREATE TRIGGER campaigns_valida_email
  BEFORE INSERT OR UPDATE OF remetente_email_id, tipo, canais_habilitados ON campaigns
  FOR EACH ROW EXECUTE FUNCTION privado.validar_email_da_campanha();

-- ---------------------------------------------------------------------------
-- O roteador pergunta à campanha
-- ---------------------------------------------------------------------------

-- O pool de uma campanha num canal: o de sempre, e — no e-mail — só a conta
-- escolhida, quando há escolha. Mesma ordem de `remetentes_disponiveis`.
CREATE FUNCTION privado.remetentes_da_campanha(p_tenant uuid, p_campaign_id uuid, p_canal canal)
RETURNS SETOF sender_accounts
LANGUAGE sql
STABLE
SET search_path = public, privado
AS $$
  SELECT r.*
    FROM campaigns c
   CROSS JOIN LATERAL privado.remetentes_disponiveis(p_tenant, p_canal, c.tipo) r
   WHERE c.id = p_campaign_id AND c.tenant_id = p_tenant
     AND (p_canal <> 'email' OR c.remetente_email_id IS NULL OR r.id = c.remetente_email_id)
   ORDER BY r.health_score DESC, r.enviados_na_janela ASC;
$$;

-- Quando volta a haver remetente para esta campanha neste canal. Sem o filtro,
-- a campanha que escolheu uma conta de e-mail esgotada seria acordada pela
-- quota de OUTRA conta — passada inútil, e o relato "adiado até" mentindo.
CREATE FUNCTION privado.proximo_horario_da_campanha(p_tenant uuid, p_campaign_id uuid, p_canal canal)
RETURNS timestamptz
LANGUAGE sql
STABLE
SET search_path = public, privado
AS $$
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
$$;

-- Agendador e despachante passam a perguntar à campanha. Os dois corpos abaixo
-- são o corpo ATUAL de cada função (lido do banco montado com todas as
-- migrations anteriores, D59), com a troca da chamada e nada mais.
CREATE OR REPLACE FUNCTION public.processar_vencidos(p_limite integer DEFAULT 100, p_modo text DEFAULT 'simulado'::text)
 RETURNS TABLE(enrollment_id uuid, acao text, detalhe text)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  e enrollments%ROWTYPE; v_campanha campaigns%ROWTYPE; v_passo flow_steps%ROWTYPE;
  v_identidade contact_identities%ROWTYPE; v_remetente sender_accounts%ROWTYPE;
  v_contato contacts%ROWTYPE; v_proximo flow_steps%ROWTYPE;
  v_conteudo text; v_status status_message; v_vars jsonb; v_quando timestamptz;
BEGIN
  IF p_modo NOT IN ('simulado','real') THEN
    RAISE EXCEPTION 'modo inválido: % (use simulado ou real)', p_modo
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_status := CASE WHEN p_modo = 'simulado' THEN 'simulado' ELSE 'pendente' END::status_message;

  FOR e IN
    SELECT * FROM enrollments
     WHERE status = 'ativo' AND next_run_at IS NOT NULL AND next_run_at <= now()
     ORDER BY next_run_at LIMIT p_limite FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_campanha FROM campaigns WHERE id = e.campaign_id;
    IF NOT v_campanha.ativa THEN
      enrollment_id := e.id; acao := 'ignorado_campanha_inativa'; detalhe := v_campanha.nome;
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_contato FROM contacts WHERE id = e.contact_id;

    IF esta_suprimido(e.tenant_id, e.contact_id, NULL, NULL) THEN
      PERFORM encerrar_enrollment(e.id, 'supressao');
      enrollment_id := e.id; acao := 'encerrado_supressao'; detalhe := 'contato suprimido';
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_passo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > e.passo_atual
     ORDER BY ordem LIMIT 1;

    IF NOT FOUND THEN
      PERFORM encerrar_enrollment(e.id, 'fim_dos_passos');
      enrollment_id := e.id; acao := 'encerrado_fim'; detalhe := ''; RETURN NEXT; CONTINUE;
    END IF;

    IF NOT (v_passo.canal = ANY (v_campanha.canais_habilitados)) THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_canal'; detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_identidade FROM contact_identities
     WHERE contact_id = e.contact_id AND canal = v_passo.canal AND valida
     ORDER BY criado_em DESC LIMIT 1;

    IF NOT FOUND THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_sem_identidade'; detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    IF esta_suprimido(e.tenant_id, e.contact_id, v_identidade.canal, v_identidade.valor_norm) THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_identidade_suprimida';
      detalhe := v_passo.canal::text; RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_remetente
      FROM remetentes_da_campanha(e.tenant_id, v_campanha.id, v_passo.canal) LIMIT 1;

    IF NOT FOUND OR NOT reservar_envio(v_remetente.id) THEN
      v_quando := proximo_horario_da_campanha(e.tenant_id, v_campanha.id, v_passo.canal);
      UPDATE enrollments SET next_run_at = greatest(v_quando, now() + interval '1 minute')
       WHERE id = e.id;
      enrollment_id := e.id; acao := 'adiado_sem_remetente';
      detalhe := v_passo.canal::text || ' até ' || to_char(v_quando, 'DD/MM HH24:MI');
      RETURN NEXT; CONTINUE;
    END IF;

    v_vars := coalesce(v_contato.metadados,'{}'::jsonb)
           || jsonb_build_object('nome', coalesce(v_contato.nome,''));
    v_conteudo := renderizar(v_passo.template, v_vars);

    BEGIN
      INSERT INTO messages (tenant_id, enrollment_id, step_id, contact_identity_id,
                            sender_account_id, canal, status, conteudo)
      VALUES (e.tenant_id, e.id, v_passo.id, v_identidade.id,
              v_remetente.id, v_passo.canal, v_status, v_conteudo);
    EXCEPTION WHEN unique_violation THEN
      enrollment_id := e.id; acao := 'passo_ja_reivindicado'; detalhe := v_passo.ordem::text;
      RETURN NEXT; CONTINUE;
    END;

    SELECT * INTO v_proximo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > v_passo.ordem
     ORDER BY ordem LIMIT 1;

    IF FOUND THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem,
        next_run_at = now() + make_interval(hours => v_proximo.atraso_horas) WHERE id = e.id;
    ELSE
      UPDATE enrollments SET passo_atual = v_passo.ordem WHERE id = e.id;
      PERFORM encerrar_enrollment(e.id,'fim_dos_passos');
    END IF;

    enrollment_id := e.id; acao := 'mensagem_criada'; detalhe := v_passo.ordem::text;
    RETURN NEXT;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.reivindicar_pendentes(p_limite integer DEFAULT 50, p_lease interval DEFAULT '00:05:00'::interval)
 RETURNS TABLE(message_id uuid, tenant_id uuid, canal canal, destino text, conteudo text, sender_id uuid, sender_ident text, campanha_tipo tipo_campanha)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  m         record;
  candidato sender_accounts%ROWTYPE;
  v_novo    uuid;
BEGIN
  -- Circuito vencido fecha na borda do lote (D37).
  UPDATE sender_accounts
     SET estado = 'ativo', falhas_consecutivas = 0, circuito_aberto_ate = NULL
   WHERE estado = 'circuito_aberto'
     AND circuito_aberto_ate IS NOT NULL
     AND circuito_aberto_ate <= now();

  FOR m IN
    WITH alvo AS (
      SELECT msg.id FROM messages msg
       WHERE msg.status = 'pendente'
         AND (msg.reivindicada_em IS NULL OR msg.reivindicada_em < now() - p_lease)
       ORDER BY msg.criado_em LIMIT p_limite FOR UPDATE SKIP LOCKED
    ), marcada AS (
      UPDATE messages msg SET reivindicada_em = now() FROM alvo WHERE msg.id = alvo.id
      RETURNING msg.*
    )
    SELECT msg.id, msg.tenant_id, msg.canal, msg.conteudo, msg.sender_account_id,
           ci.valor AS destino, ci.valor_norm, e.contact_id, c.tipo AS campanha_tipo,
           c.id AS campaign_id, c.remetente_email_id,
           e.status AS estado_enrollment, e.motivo_encerramento, c.ativa AS campanha_ativa,
           sa.estado AS estado_atual, sa.identificador AS ident_atual,
           cat.tem_adapter, cat.ativo AS provedor_ativo
      FROM marcada msg
      JOIN contact_identities ci ON ci.id = msg.contact_identity_id
      JOIN enrollments        e  ON e.id = msg.enrollment_id
      JOIN campaigns          c  ON c.id = e.campaign_id
      JOIN sender_accounts    sa ON sa.id = msg.sender_account_id
      JOIN channel_provider_catalog cat ON cat.slug = sa.provedor
  LOOP
    -- 1. Supressão, acima de tudo (D39).
    IF esta_suprimido(m.tenant_id, m.contact_id, m.canal, m.valor_norm) THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      CONTINUE;
    END IF;

    -- 2. Parada definitiva: a cadência acabou por um motivo que significa
    -- "pare de falar com esta pessoa". `fim_dos_passos` não é um deles — é o
    -- encerramento normal, e acontece na MESMA passada que cria a última
    -- mensagem (D40).
    IF m.estado_enrollment = 'encerrado'
       AND m.motivo_encerramento IS DISTINCT FROM 'fim_dos_passos' THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      CONTINUE;
    END IF;

    -- 3. Parada temporária: pausa e campanha desligada voltam atrás. Segura a
    -- mensagem em vez de cancelar — cancelada não é recriável, porque a chave
    -- única `(enrollment_id, step_id)` impede repetir o passo.
    IF m.estado_enrollment = 'pausado' OR NOT m.campanha_ativa THEN
      UPDATE messages SET reivindicada_em = NULL WHERE id = m.id;
      CONTINUE;
    END IF;

    -- 4. Quota NÃO entra: a reserva desta mensagem já foi paga na criação.
    -- E-mail com provedor escolhido pela campanha só sai por ele: trocar o
    -- provedor na tela vale para o que já está na fila, não só para o que
    -- ainda vai nascer (D62) — é o D37 aplicado à escolha da pessoa.
    IF m.estado_atual = 'ativo' AND m.tem_adapter AND m.provedor_ativo
       AND (m.canal <> 'email' OR m.remetente_email_id IS NULL
            OR m.sender_account_id = m.remetente_email_id) THEN
      message_id := m.id; tenant_id := m.tenant_id; canal := m.canal;
      destino := m.destino; conteudo := m.conteudo;
      sender_id := m.sender_account_id; sender_ident := m.ident_atual;
      campanha_tipo := m.campanha_tipo;
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- 5. Remetente não despacha mais: procura outro no mesmo pool (D37).
    v_novo := NULL;
    FOR candidato IN
      SELECT * FROM privado.remetentes_da_campanha(m.tenant_id, m.campaign_id, m.canal)
    LOOP
      IF candidato.id <> m.sender_account_id AND reservar_envio(candidato.id) THEN
        v_novo := candidato.id;
        EXIT;
      END IF;
    END LOOP;

    IF v_novo IS NULL THEN
      UPDATE messages SET reivindicada_em = NULL WHERE id = m.id;
      CONTINUE;
    END IF;

    -- A reserva do remetente antigo não volta: furaria a invariante 3 (D37).
    UPDATE messages SET sender_account_id = v_novo WHERE id = m.id;

    SELECT * INTO candidato FROM sender_accounts WHERE id = v_novo;
    message_id := m.id; tenant_id := m.tenant_id; canal := m.canal;
    destino := m.destino; conteudo := m.conteudo;
    sender_id := v_novo; sender_ident := candidato.identificador;
    campanha_tipo := m.campanha_tipo;
    RETURN NEXT;
  END LOOP;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Remover, ler e verificar
-- ---------------------------------------------------------------------------

-- Arquivar uma conta. Recusa quando alguma campanha a escolheu: removê-la
-- deixaria aquela campanha com todo passo de e-mail adiado para sempre, sem
-- erro — o silêncio do D35. Quem remove escolhe outro provedor lá primeiro.
--
-- O ponteiro do Vault fica: uma mensagem já reivindicada, em voo, ainda
-- precisa do segredo para sair, e o pendente que sobrar o despacho rebalanceia
-- para o pool (D37). Só o service_role lê esse segredo.
CREATE FUNCTION public.remover_remetente(p_sender_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, privado
AS $$
DECLARE v_tenant uuid; v_removido timestamptz; v_campanhas text;
BEGIN
  SELECT tenant_id, removido_em INTO v_tenant, v_removido
    FROM sender_accounts WHERE id = p_sender_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remetente inexistente: %', p_sender_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT privado.pode_administrar(v_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente remove conta'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_removido IS NOT NULL THEN
    RETURN;
  END IF;

  SELECT string_agg(nome, ', ' ORDER BY nome) INTO v_campanhas
    FROM campaigns WHERE tenant_id = v_tenant AND remetente_email_id = p_sender_id;
  IF v_campanhas IS NOT NULL THEN
    RAISE EXCEPTION 'esta conta é o e-mail de: %. Escolha outro provedor nelas antes de remover', v_campanhas
      USING ERRCODE = 'restrict_violation';
  END IF;

  UPDATE sender_accounts SET estado = 'desativado', removido_em = now()
   WHERE id = p_sender_id;
END;
$$;

-- As contas de e-mail que uma campanha pode escolher, para quem OPERA o
-- cliente. Não é a política de RLS repetida (D41): `sender_accounts` é de quem
-- administra, e a linha inteira tem o token do webhook — que é credencial. O
-- operador precisa do nome da conta e de saber se ela funciona; isto devolve
-- isso e só isso.
CREATE FUNCTION public.contas_de_email(p_tenant uuid)
RETURNS TABLE (id uuid, apelido text, identificador text, provedor text, provedor_nome text,
               tipo_permitido tipo_campanha, estado estado_remetente,
               verificado_em timestamptz, verificacao_ok boolean, verificacao_detalhe text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, privado
AS $$
BEGIN
  IF NOT privado.pode_operar(p_tenant) THEN
    RAISE EXCEPTION 'sem acesso a este cliente' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT sa.id, sa.apelido, sa.identificador, sa.provedor, p.nome, sa.tipo_permitido,
         sa.estado, sa.verificado_em, sa.verificacao_ok, sa.verificacao_detalhe
    FROM sender_accounts sa
    JOIN channel_provider_catalog p ON p.slug = sa.provedor
   WHERE sa.tenant_id = p_tenant AND sa.canal = 'email' AND sa.removido_em IS NULL
   ORDER BY coalesce(sa.apelido, sa.identificador);
END;
$$;

-- O resultado do `checkHealth`. Só a edge function grava: ela é quem tem o
-- segredo para perguntar ao provedor. Detalhe aparado — é texto de provedor,
-- e a tela o mostra como está.
CREATE FUNCTION public.registrar_verificacao_remetente(p_sender_id uuid, p_ok boolean, p_detalhe text)
RETURNS void
LANGUAGE sql
SET search_path = public, privado
AS $$
  UPDATE sender_accounts
     SET verificado_em = now(), verificacao_ok = p_ok, verificacao_detalhe = left(p_detalhe, 300)
   WHERE id = p_sender_id;
$$;

-- Função nova nasce com EXECUTE para PUBLIC, do qual anon é membro (D19/D55):
-- REVOKE primeiro, GRANT depois, e o GRANT só para papel que existe.
DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.remover_remetente(uuid)',
    'public.contas_de_email(uuid)',
    'public.registrar_verificacao_remetente(uuid, boolean, text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;

  -- A tela remove e lê. Gravar a verificação fica fora de `authenticated`:
  -- quem pode dizer "esta conta funciona" é quem perguntou ao provedor.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.remover_remetente(uuid) TO authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.contas_de_email(uuid) TO authenticated';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- A grade: a coluna nova da campanha, e o INSERT e o DELETE da conta
-- ---------------------------------------------------------------------------

-- Corpo ATUAL de `estreitar_escrita_do_cliente`, com duas mudanças (D59: o
-- CREATE OR REPLACE troca o corpo inteiro, então ele parte do que está no
-- banco, não de uma cópia antiga).
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
END;
$function$;

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
