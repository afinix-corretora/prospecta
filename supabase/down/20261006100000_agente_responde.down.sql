-- Reverte o D69: o agente volta a só compor (D66).
--
-- A mensagem do agente não tem passo e não cabe no schema de antes: sai junto.
-- Os corpos restaurados são os que estavam aplicados antes desta migration.

DROP FUNCTION IF EXISTS public.enfileirar_resposta(uuid, text);
DROP FUNCTION IF EXISTS public.respostas_para_o_agente(integer);

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
$function$

;

CREATE OR REPLACE FUNCTION public.registrar_evento_provedor(p_sender_id uuid, p_provider_id text, p_tipo tipo_evento, p_ocorrido_em timestamp with time zone DEFAULT now(), p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE v_tenant uuid; v_message uuid;
BEGIN
  -- O eco do próprio motor não é evento de ninguém.
  IF p_payload ->> 'autoria' = 'motor-prospeccao' THEN RETURN false; END IF;

  SELECT tenant_id INTO v_tenant FROM sender_accounts WHERE id = p_sender_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remetente inexistente: %', p_sender_id USING ERRCODE = 'no_data_found';
  END IF;

  -- O filtro que faltava. Sem ele, `provider_message_id` repetido entre
  -- clientes entrega o evento a quem gravou por último.
  SELECT id INTO v_message FROM messages
   WHERE tenant_id = v_tenant AND provider_message_id = p_provider_id
   ORDER BY criado_em DESC LIMIT 1;

  -- Id que não é deste cliente não é assunto dele. Devolver false em vez de
  -- levantar: webhook de provedor chega em rajada e repetido, e derrubar a
  -- chamada faria o lote inteiro cair por causa de um evento alheio.
  IF v_message IS NULL THEN RETURN false; END IF;

  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em, payload)
  VALUES (v_tenant, v_message, p_tipo, p_ocorrido_em, p_payload);
  RETURN true;
END;
$function$

;

CREATE OR REPLACE FUNCTION public.registrar_resposta_por_numero(p_sender_id uuid, p_valor_norm text, p_ocorrido_em timestamp with time zone DEFAULT now(), p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
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
$function$

;

CREATE OR REPLACE FUNCTION public.mensagens_da_campanha(p_tenant uuid, p_campaign_id uuid, p_limite integer DEFAULT 50)
 RETURNS TABLE(message_id uuid, criado_em timestamp with time zone, contato text, canal canal, destino text, passo integer, status status_message, remetente text, conteudo text, buraco boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
  SELECT m.id,
         m.criado_em,
         coalesce(c.nome, '(sem nome)'),
         m.canal,
         ci.valor,
         fs.ordem,
         m.status,
         coalesce(sa.apelido, sa.identificador, '(sem remetente)'),
         m.conteudo,
         -- Best-effort, e assumido como tal: pontuação órfã ou espaço dobrado
         -- é o rastro que uma variável vazia deixa. Falso positivo aqui custa
         -- uma olhada; falso negativo custa uma campanha inteira dizendo
         -- "Olá ,".
         m.conteudo ~ '(^|[[:space:]])[,.;:!?]|[[:space:]][[:space:]]'
    FROM messages m
    JOIN enrollments e ON e.id = m.enrollment_id AND e.campaign_id = p_campaign_id
    JOIN contacts    c ON c.id = e.contact_id
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
    JOIN flow_steps fs ON fs.id = m.step_id
    LEFT JOIN sender_accounts sa ON sa.id = m.sender_account_id
   WHERE m.tenant_id = p_tenant
   ORDER BY m.criado_em DESC
   LIMIT least(coalesce(p_limite, 50), 200);
$function$

;

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
  -- D66. O agente é da tela, por coluna: o que ele diz, quando passa para
  -- uma pessoa, o que nunca escreve e com que credencial. Fora fica o dono da
  -- linha e `pronto`, que é a marca de agente do catálogo.
  REVOKE UPDATE ON agents FROM authenticated;
  GRANT UPDATE (nome, papel, descricao, instrucoes, ai_credential_id, escalar_quando,
                limite_trocas, ativo, proibido, tamanho_maximo)
    ON agents TO authenticated;

  -- O rascunho é do worker: a tela lê. Escrito à mão, seria um texto que
  -- parece ter sido composto pelo agente com os freios dele, sem ter sido.
  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;
END;
$function$

;

DROP FUNCTION IF EXISTS privado.devolver_rascunho(uuid, text);

DELETE FROM messages WHERE rascunho_id IS NOT NULL;
ALTER TABLE messages
  DROP CONSTRAINT IF EXISTS messages_rascunho_uk,
  DROP CONSTRAINT IF EXISTS messages_passo_ou_rascunho,
  DROP CONSTRAINT IF EXISTS messages_rascunho_tenant_fkey,
  DROP COLUMN IF EXISTS rascunho_id,
  ALTER COLUMN step_id SET NOT NULL;

ALTER TABLE rascunhos
  DROP CONSTRAINT IF EXISTS rascunhos_devolvido_tem_motivo,
  DROP CONSTRAINT IF EXISTS rascunhos_envio_so_pronto,
  DROP CONSTRAINT IF EXISTS rascunhos_envio,
  DROP COLUMN IF EXISTS envio_motivo,
  DROP COLUMN IF EXISTS envio;

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_teto_agente_dia, DROP COLUMN IF EXISTS teto_agente_dia;
ALTER TABLE agents DROP COLUMN IF EXISTS autonomo;

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
