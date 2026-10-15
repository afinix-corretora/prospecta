-- O agente responde sozinho (D69, opção B de PROPOSTA-CONVERSA.md §8).
--
-- Decidido pelo usuário em 05/10: o agente tem autonomia para responder. O que
-- o D66 deixava na mão de uma pessoa agora sai pelo motor, pelo MESMO caminho
-- de envio da cadência — supressão no gatilho, supressão no despacho (D39),
-- pool por tipo de campanha, quota (invariante 3). Nenhum envio novo fora do
-- roteador.
--
-- As três travas que o laço autônomo encontra, e o que muda em cada uma:
--
--   invariante 4   continua absoluta. A resposta encerra TODAS as inscrições
--                  da pessoa, e a cadência não volta a falar com ela. O que
--                  passa é outra coisa: a mensagem do agente, que nunca é de
--                  cadência.
--   gate do D40    ganha um critério POSITIVO, e só um. Numa inscrição
--                  encerrada por `resposta`, passa somente a mensagem que tem
--                  `rascunho_id` E responde à ÚLTIMA resposta da pessoa.
--                  Mensagem de cadência nunca tem `rascunho_id`, então segue
--                  cancelada como hoje. Resposta nova da pessoa aposenta a
--                  mensagem do agente que respondia à anterior.
--   (enrollment_id, step_id)
--                  a mensagem do agente não tem passo. A chave dela é
--                  `UNIQUE (rascunho_id)`: um rascunho, uma mensagem, no
--                  máximo. NULL não colide na chave antiga, que fica como está.
--
-- As quatro respostas do §8, como o usuário as deixou:
--
--   (a) autonomia por agente (`agents.autonomo`), LIGADA por padrão: é a
--       decisão. Desligar devolve o agente ao D66 — rascunho para uma pessoa.
--   (b) a resposta do agente PAGA quota. O provedor conta igual, e o chip
--       banido não distingue prospecção de conversa (invariante 3).
--   (c) janela de 24h no WhatsApp e no Instagram: fora dela a mensagem não
--       sai, e o rascunho volta para uma pessoa com o motivo.
--   (d) teto diário de composições por cliente (`tenants.teto_agente_dia`),
--       contado na própria `rascunhos`. Passou, a situação é `limite`.
--
-- E uma que o §8 não tinha: a resposta sai pela MESMA conta que conversa com
-- a pessoa. Trocar de chip no meio da conversa é outro número escrevendo para
-- ela — no WhatsApp oficial, fora da sessão. Por isso a mensagem do agente
-- nunca é rebalanceada (D37): conta fora do ar segura a mensagem, e a janela
-- de 24h decide quando ela deixa de valer.
--
-- "Não mandou" nunca é silêncio (D66): `rascunhos.envio` diz se o texto foi
-- para a fila, ficou com uma pessoa porque o agente não é autônomo, ou foi
-- DEVOLVIDO a uma pessoa — e `envio_motivo` diz por quê.
--
-- Sem barra invertida (D32). Sem DROP (D63): `respostas_para_rascunhar` fica
-- sem chamador e sai numa migration própria.
-- Reversível: supabase/down/20261006100000_agente_responde.down.sql

-- ---------------------------------------------------------------------------
-- (a) e (d)
-- ---------------------------------------------------------------------------

ALTER TABLE agents ADD COLUMN autonomo boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN agents.autonomo IS
  'Ligado: o rascunho pronto vira mensagem e sai pelo motor (D69). Desligado: '
  'o rascunho fica para uma pessoa mandar, como no D66. Os freios valem nos dois.';

ALTER TABLE tenants ADD COLUMN teto_agente_dia integer NOT NULL DEFAULT 200,
  ADD CONSTRAINT tenants_teto_agente_dia CHECK (teto_agente_dia BETWEEN 0 AND 5000);

COMMENT ON COLUMN tenants.teto_agente_dia IS
  'Quantas composições de agente o cliente faz em 24h, somando todos os agentes. '
  'Conta o que chamou o modelo, saindo ou não. Passou, a resposta fica com uma pessoa.';

-- ---------------------------------------------------------------------------
-- O destino do rascunho
-- ---------------------------------------------------------------------------

ALTER TABLE rascunhos
  ADD COLUMN envio text NOT NULL DEFAULT 'pessoa',
  ADD COLUMN envio_motivo text,
  ADD CONSTRAINT rascunhos_envio CHECK (envio IN ('pessoa', 'fila', 'devolvido')),
  -- Só texto pronto tem para onde ir.
  ADD CONSTRAINT rascunhos_envio_so_pronto CHECK (envio = 'pessoa' OR situacao = 'pronto'),
  ADD CONSTRAINT rascunhos_devolvido_tem_motivo CHECK (envio <> 'devolvido' OR envio_motivo IS NOT NULL);

COMMENT ON COLUMN rascunhos.envio IS
  'pessoa: o agente não é autônomo, uma pessoa manda. fila: virou mensagem e sai '
  'pelo motor. devolvido: o agente é autônomo, mas o motor não mandou — o motivo '
  'está em envio_motivo, e o texto fica para uma pessoa.';

-- ---------------------------------------------------------------------------
-- A mensagem sem passo
-- ---------------------------------------------------------------------------

ALTER TABLE messages
  ALTER COLUMN step_id DROP NOT NULL,
  ADD COLUMN rascunho_id uuid,
  ADD CONSTRAINT messages_rascunho_tenant_fkey FOREIGN KEY (tenant_id, rascunho_id)
    REFERENCES rascunhos (tenant_id, id),
  -- Ou é passo de cadência, ou é resposta de agente. Nunca as duas, nunca
  -- nenhuma: mensagem sem origem é a que ninguém sabe explicar.
  ADD CONSTRAINT messages_passo_ou_rascunho CHECK ((step_id IS NULL) <> (rascunho_id IS NULL)),
  -- Um rascunho, uma mensagem (invariante 1 da conversa).
  ADD CONSTRAINT messages_rascunho_uk UNIQUE (rascunho_id);

COMMENT ON COLUMN messages.rascunho_id IS
  'Preenchido só na mensagem do agente (D69). É o que a deixa passar pelo gate '
  'do D40 numa inscrição encerrada por resposta — e só se responder à última.';

-- ---------------------------------------------------------------------------
-- O que o worker lê: a fila do D66, com o que a autonomia precisa
-- ---------------------------------------------------------------------------

-- Nome novo porque a assinatura muda, e trocar o tipo de retorno exige DROP
-- (D63). A antiga fica sem chamador.
CREATE FUNCTION public.respostas_para_o_agente(p_limite integer DEFAULT 20)
RETURNS TABLE(
  message_event_id uuid, tenant_id uuid, contact_id uuid, resposta_em timestamptz,
  canal canal, texto text, regra text,
  agent_id uuid, agente_nome text, papel text, descricao text, instrucoes text,
  escalar_quando text, limite_trocas integer, proibido text[], tamanho_maximo integer,
  credencial_id uuid, provedor text, modelo text, provedor_compoe boolean,
  contato_nome text, metadados jsonb, campanha text, historico jsonb, rascunhos_anteriores integer,
  autonomo boolean, composicoes_hoje integer, teto integer)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  WITH respostas AS (
    SELECT me.id, me.tenant_id, e.contact_id, me.ocorrido_em, m.canal, me.payload ->> 'texto' AS texto,
           e.campaign_id, m.contact_identity_id,
           row_number() OVER (PARTITION BY me.tenant_id, e.contact_id
                              ORDER BY me.ocorrido_em DESC, me.criado_em DESC) AS n
      FROM message_events me
      JOIN messages m    ON m.tenant_id = me.tenant_id AND m.id = me.message_id
      JOIN enrollments e ON e.tenant_id = m.tenant_id AND e.id = m.enrollment_id
     WHERE me.tipo = 'respondido'
       AND jsonb_typeof(me.payload -> 'texto') = 'string'
       AND me.ocorrido_em > now() - interval '7 days'
  )
  SELECT r.id, r.tenant_id, r.contact_id, r.ocorrido_em, r.canal, r.texto,
         (SELECT x.acao::text FROM privado.regra_da_resposta(r.tenant_id, r.texto) x LIMIT 1),
         a.id, a.nome, a.papel, a.descricao, a.instrucoes,
         a.escalar_quando, a.limite_trocas, a.proibido, a.tamanho_maximo,
         ac.id, ac.provedor, ac.modelo, coalesce(pc.tem_adapter AND ac.ativo, false),
         c.nome, c.metadados, camp.nome,
         -- A conversa até aqui, nos dois sentidos, mais antiga primeiro. Só o
         -- que saiu de verdade: rascunho de simulado não é conversa. A
         -- mensagem do agente entra como "nós", que é o que ela é.
         (SELECT coalesce(jsonb_agg(h.item ORDER BY h.quando), '[]'::jsonb) FROM (
            SELECT jsonb_build_object('de', 'nos', 'texto', m2.conteudo) AS item, m2.criado_em AS quando
              FROM messages m2 JOIN enrollments e2 ON e2.tenant_id = m2.tenant_id AND e2.id = m2.enrollment_id
             WHERE m2.tenant_id = r.tenant_id AND e2.contact_id = r.contact_id
               AND m2.status NOT IN ('simulado', 'cancelado', 'falha', 'pendente')
            UNION ALL
            SELECT jsonb_build_object('de', 'pessoa', 'texto', me2.payload ->> 'texto'), me2.ocorrido_em
              FROM message_events me2
              JOIN messages m3    ON m3.tenant_id = me2.tenant_id AND m3.id = me2.message_id
              JOIN enrollments e3 ON e3.tenant_id = m3.tenant_id AND e3.id = m3.enrollment_id
             WHERE me2.tenant_id = r.tenant_id AND e3.contact_id = r.contact_id
               AND me2.tipo = 'respondido' AND jsonb_typeof(me2.payload -> 'texto') = 'string'
            ORDER BY 2 DESC LIMIT 20) h),
         -- As trocas da conversa: texto pronto que saiu ou ficou com uma
         -- pessoa. O devolvido não conta — ele não foi uma troca.
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.contact_id = r.contact_id
             AND x.situacao = 'pronto' AND x.envio <> 'devolvido'),
         a.autonomo,
         -- (d): composições do cliente nas últimas 24h. Conta o que chamou o
         -- modelo; recusa, limite e falta de credencial não custaram nada.
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.criado_em > now() - interval '1 day'
             AND x.situacao IN ('pronto', 'escalar', 'bloqueado', 'erro')),
         t.teto_agente_dia
    FROM respostas r
    JOIN tenants t    ON t.id = r.tenant_id
    JOIN contacts c   ON c.tenant_id = r.tenant_id AND c.id = r.contact_id
    JOIN campaigns camp ON camp.tenant_id = r.tenant_id AND camp.id = r.campaign_id
    JOIN campaign_agents ca ON ca.tenant_id = r.tenant_id AND ca.campaign_id = r.campaign_id AND ca.canal = r.canal
    JOIN agents a     ON a.tenant_id = r.tenant_id AND a.id = ca.agent_id AND a.ativo
    -- A conta escolhida na campanha vale sobre a do agente (D68): o agente é
    -- uma persona que várias campanhas dividem, e a conta é decisão de cada uma.
    LEFT JOIN ai_credentials ac ON ac.tenant_id = a.tenant_id
                               AND ac.id = coalesce(camp.ai_credential_id, a.ai_credential_id)
    LEFT JOIN ai_provider_catalog pc ON pc.slug = ac.provedor
    JOIN contact_identities ci ON ci.tenant_id = r.tenant_id AND ci.id = r.contact_identity_id
   WHERE r.n = 1
     AND NOT EXISTS (SELECT 1 FROM rascunhos x WHERE x.tenant_id = r.tenant_id AND x.message_event_id = r.id)
     -- Nem rascunho para quem pediu para sair: um texto pronto é convite a
     -- uma pessoa mandar — e agora ao motor. A pessoa inteira e o endereço.
     AND NOT esta_suprimido(r.tenant_id, r.contact_id, r.canal, ci.valor_norm)
   ORDER BY r.ocorrido_em
   LIMIT least(coalesce(p_limite, 20), 100);
$$;

-- ---------------------------------------------------------------------------
-- Devolver a uma pessoa
-- ---------------------------------------------------------------------------

CREATE FUNCTION privado.devolver_rascunho(p_rascunho_id uuid, p_motivo text)
RETURNS void
LANGUAGE sql
SET search_path TO 'public', 'privado'
AS $$
  UPDATE rascunhos SET envio = 'devolvido', envio_motivo = left(p_motivo, 500)
   WHERE id = p_rascunho_id AND situacao = 'pronto';
$$;

-- ---------------------------------------------------------------------------
-- O rascunho vira mensagem
-- ---------------------------------------------------------------------------

-- Chamada pelo worker logo depois de gravar um rascunho `pronto`. Devolve o
-- destino: 'fila', 'pessoa' ou 'devolvido'. Pode ser repetida: a segunda vez
-- não cria nada.
CREATE FUNCTION public.enfileirar_resposta(p_message_event_id uuid, p_modo text DEFAULT 'simulado')
RETURNS text
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
DECLARE
  r rascunhos%ROWTYPE; v_evento message_events%ROWTYPE; v_origem messages%ROWTYPE;
  v_enrollment enrollments%ROWTYPE; v_campanha campaigns%ROWTYPE;
  v_autonomo boolean; v_conta sender_accounts%ROWTYPE; v_chip uuid;
  v_despacha boolean; v_status status_message; v_valor_norm text;
BEGIN
  IF p_modo NOT IN ('simulado', 'real') THEN
    RAISE EXCEPTION 'modo inválido: % (use simulado ou real)', p_modo
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_status := CASE WHEN p_modo = 'simulado' THEN 'simulado' ELSE 'pendente' END::status_message;

  SELECT * INTO r FROM rascunhos WHERE message_event_id = p_message_event_id;
  IF NOT FOUND OR r.situacao <> 'pronto' THEN
    RETURN 'pessoa';
  END IF;
  IF r.envio <> 'pessoa' THEN
    RETURN r.envio;   -- já decidido: a segunda chamada não cria nada
  END IF;

  SELECT a.autonomo INTO v_autonomo FROM agents a
   WHERE a.tenant_id = r.tenant_id AND a.id = r.agent_id;
  IF NOT coalesce(v_autonomo, false) THEN
    RETURN 'pessoa';
  END IF;

  SELECT * INTO v_evento FROM message_events WHERE id = r.message_event_id;
  SELECT * INTO v_origem FROM messages WHERE id = v_evento.message_id;
  SELECT * INTO v_enrollment FROM enrollments WHERE id = v_origem.enrollment_id;
  SELECT * INTO v_campanha FROM campaigns WHERE id = v_enrollment.campaign_id;
  SELECT valor_norm INTO v_valor_norm FROM contact_identities WHERE id = v_origem.contact_identity_id;

  -- A pessoa respondeu de novo: quem responde é o rascunho da mais recente.
  IF EXISTS (
    SELECT 1 FROM message_events me2
      JOIN messages m2    ON m2.id = me2.message_id
      JOIN enrollments e2 ON e2.id = m2.enrollment_id
     WHERE me2.tenant_id = r.tenant_id AND e2.contact_id = r.contact_id
       AND me2.tipo = 'respondido' AND me2.ocorrido_em > v_evento.ocorrido_em
  ) THEN
    PERFORM privado.devolver_rascunho(r.id, 'a pessoa respondeu de novo antes de o agente mandar');
    RETURN 'devolvido';
  END IF;

  IF esta_suprimido(r.tenant_id, r.contact_id, v_origem.canal, v_valor_norm) THEN
    PERFORM privado.devolver_rascunho(r.id, 'o contato está suprimido');
    RETURN 'devolvido';
  END IF;

  IF NOT v_campanha.ativa THEN
    PERFORM privado.devolver_rascunho(r.id, 'a campanha está desligada');
    RETURN 'devolvido';
  END IF;

  -- Só a resposta reabre a conversa. Encerrada por supressão, por mudança de
  -- etapa no CRM ou por uma pessoa, a decisão foi parar de falar.
  IF v_enrollment.status = 'encerrado' AND v_enrollment.motivo_encerramento IS DISTINCT FROM 'resposta' THEN
    PERFORM privado.devolver_rascunho(r.id,
      'a inscrição foi encerrada por ' || coalesce(v_enrollment.motivo_encerramento::text, '?'));
    RETURN 'devolvido';
  END IF;

  -- (c) A janela de 24h.
  IF v_origem.canal IN ('whatsapp', 'instagram') AND r.resposta_em < now() - interval '24 hours' THEN
    PERFORM privado.devolver_rascunho(r.id, 'passou a janela de 24h desde a última mensagem da pessoa');
    RETURN 'devolvido';
  END IF;

  -- A conta que conversa: a que recebeu a resposta (o webhook grava o chip no
  -- evento), ou a que mandou a mensagem respondida.
  BEGIN
    v_chip := nullif(v_evento.payload ->> 'chip', '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_chip := NULL;
  END;
  SELECT * INTO v_conta FROM sender_accounts
   WHERE tenant_id = r.tenant_id AND canal = v_origem.canal
     AND id = coalesce(v_chip, v_origem.sender_account_id);
  IF NOT FOUND THEN
    SELECT * INTO v_conta FROM sender_accounts
     WHERE tenant_id = r.tenant_id AND id = v_origem.sender_account_id;
  END IF;
  IF v_conta.id IS NULL THEN
    PERFORM privado.devolver_rascunho(r.id, 'não há conta que esteja conversando com a pessoa');
    RETURN 'devolvido';
  END IF;

  SELECT v_conta.removido_em IS NULL AND cat.tem_adapter AND cat.ativo
    INTO v_despacha
    FROM channel_provider_catalog cat WHERE cat.slug = v_conta.provedor;
  IF NOT coalesce(v_despacha, false) THEN
    PERFORM privado.devolver_rascunho(r.id,
      'a conta ' || coalesce(v_conta.apelido, v_conta.identificador) || ' não tem como despachar');
    RETURN 'devolvido';
  END IF;

  -- (b) A resposta paga quota, como qualquer mensagem (invariante 3). Quem
  -- decide se a conta está de pé é `reservar_envio`, que também fecha o
  -- circuito vencido — conferir o estado antes dela devolveria à toa.
  IF NOT reservar_envio(v_conta.id) THEN
    SELECT * INTO v_conta FROM sender_accounts WHERE id = v_conta.id;
    PERFORM privado.devolver_rascunho(r.id,
      'a conta ' || coalesce(v_conta.apelido, v_conta.identificador) || CASE
        WHEN v_conta.estado <> 'ativo' THEN ' está fora do pool (' || v_conta.estado::text || ')'
        ELSE ' está sem quota hoje' END);
    RETURN 'devolvido';
  END IF;

  BEGIN
    INSERT INTO messages (tenant_id, enrollment_id, step_id, rascunho_id, contact_identity_id,
                          sender_account_id, canal, status, conteudo)
    VALUES (r.tenant_id, v_origem.enrollment_id, NULL, r.id, v_origem.contact_identity_id,
            v_conta.id, v_origem.canal, v_status, r.texto);
  EXCEPTION
    WHEN unique_violation THEN
      NULL;  -- outra passada chegou antes: a mensagem existe
    WHEN restrict_violation THEN
      -- Os gatilhos de supressão e de pool têm a palavra final.
      PERFORM privado.devolver_rascunho(r.id, 'barrada na criação: ' || SQLERRM);
      RETURN 'devolvido';
  END;

  UPDATE rascunhos SET envio = 'fila' WHERE id = r.id;
  RETURN 'fila';
END;
$$;

-- ---------------------------------------------------------------------------
-- O despacho: o critério positivo do D40, a janela e a conta fixa
-- ---------------------------------------------------------------------------

-- Regenerada a partir do corpo atual (D59), com três mudanças marcadas D69.
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
           cat.tem_adapter, cat.ativo AS provedor_ativo,
           -- D69: a mensagem do agente, e se ela ainda responde à última.
           msg.rascunho_id, ra.resposta_em,
           (msg.rascunho_id IS NOT NULL AND NOT EXISTS (
              SELECT 1 FROM message_events me2
                JOIN messages m2    ON m2.id = me2.message_id
                JOIN enrollments e2 ON e2.id = m2.enrollment_id
               WHERE me2.tenant_id = msg.tenant_id AND e2.contact_id = e.contact_id
                 AND me2.tipo = 'respondido' AND me2.ocorrido_em > me0.ocorrido_em)) AS responde_a_ultima
      FROM marcada msg
      JOIN contact_identities ci ON ci.id = msg.contact_identity_id
      JOIN enrollments        e  ON e.id = msg.enrollment_id
      JOIN campaigns          c  ON c.id = e.campaign_id
      JOIN sender_accounts    sa ON sa.id = msg.sender_account_id
      JOIN channel_provider_catalog cat ON cat.slug = sa.provedor
      LEFT JOIN rascunhos     ra ON ra.id = msg.rascunho_id
      LEFT JOIN message_events me0 ON me0.id = ra.message_event_id
  LOOP
    -- 1. Supressão, acima de tudo (D39).
    IF esta_suprimido(m.tenant_id, m.contact_id, m.canal, m.valor_norm) THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      IF m.rascunho_id IS NOT NULL THEN
        PERFORM privado.devolver_rascunho(m.rascunho_id, 'o contato foi suprimido antes do envio');
      END IF;
      CONTINUE;
    END IF;

    -- 2. Parada definitiva: a cadência acabou por um motivo que significa
    -- "pare de falar com esta pessoa". `fim_dos_passos` não é um deles — é o
    -- encerramento normal, e acontece na MESMA passada que cria a última
    -- mensagem (D40).
    --
    -- D69: o critério positivo, e só um. Encerrada por `resposta`, passa a
    -- mensagem do agente que responde à ÚLTIMA resposta da pessoa. Mensagem de
    -- cadência nunca tem `rascunho_id` e segue cancelada.
    IF m.estado_enrollment = 'encerrado'
       AND m.motivo_encerramento IS DISTINCT FROM 'fim_dos_passos'
       AND NOT (m.rascunho_id IS NOT NULL AND m.motivo_encerramento = 'resposta' AND m.responde_a_ultima) THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      IF m.rascunho_id IS NOT NULL THEN
        PERFORM privado.devolver_rascunho(m.rascunho_id, CASE
          WHEN NOT m.responde_a_ultima THEN 'a pessoa respondeu de novo antes do envio'
          ELSE 'a inscrição foi encerrada por ' || coalesce(m.motivo_encerramento::text, '?') END);
      END IF;
      CONTINUE;
    END IF;

    -- D69: a janela de 24h, conferida de novo na saída — a mensagem pode ter
    -- esperado a conta voltar.
    IF m.rascunho_id IS NOT NULL AND m.canal IN ('whatsapp', 'instagram')
       AND m.resposta_em < now() - interval '24 hours' THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      PERFORM privado.devolver_rascunho(m.rascunho_id, 'passou a janela de 24h esperando a conta despachar');
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
    -- ainda vai nascer (D62) — é o D37 aplicado à escolha da pessoa. A
    -- mensagem do agente sai pela conta que conversa, sempre (D69).
    IF m.estado_atual = 'ativo' AND m.tem_adapter AND m.provedor_ativo
       AND (m.rascunho_id IS NOT NULL OR m.canal <> 'email' OR m.remetente_email_id IS NULL
            OR m.sender_account_id = m.remetente_email_id) THEN
      message_id := m.id; tenant_id := m.tenant_id; canal := m.canal;
      destino := m.destino; conteudo := m.conteudo;
      sender_id := m.sender_account_id; sender_ident := m.ident_atual;
      campanha_tipo := m.campanha_tipo;
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- D69: a mensagem do agente não troca de conta. Outro número escrevendo
    -- no meio da conversa é outra conversa; ela espera, e a janela decide.
    IF m.rascunho_id IS NOT NULL THEN
      UPDATE messages SET reivindicada_em = NULL WHERE id = m.id;
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
-- O chip que recebeu a resposta fica no evento
-- ---------------------------------------------------------------------------

-- Regeneradas a partir do corpo atual (D59); a única mudança é o `chip`.
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

  -- D69: a conta que recebeu é a que responde.
  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em, payload)
  VALUES (v_tenant, v_message, p_tipo, p_ocorrido_em, p_payload || jsonb_build_object('chip', p_sender_id));
  RETURN true;
END;
$function$;

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

  -- D69: o chip que recebeu fica no evento — é por ele que o agente responde,
  -- mesmo que a última mensagem tenha saído por outro do pool.
  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em, payload)
  VALUES (v_tenant, v_mensagem, 'respondido', p_ocorrido_em,
          p_payload || jsonb_build_object('casado_por', 'numero', 'chip', p_sender_id));

  RETURN true;
END;
$function$;

-- ---------------------------------------------------------------------------
-- A tela da campanha enxerga a mensagem sem passo
-- ---------------------------------------------------------------------------

-- Regenerada a partir do corpo atual (D59). A junção com o passo vira LEFT:
-- com JOIN, a mensagem do agente sumiria da tela que existe para mostrar o
-- que o motor mandou (D36). `passo` nulo é "o agente".
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
    LEFT JOIN flow_steps fs ON fs.id = m.step_id
    LEFT JOIN sender_accounts sa ON sa.id = m.sender_account_id
   WHERE m.tenant_id = p_tenant
   ORDER BY m.criado_em DESC
   LIMIT least(coalesce(p_limite, 50), 200);
$function$;

-- ---------------------------------------------------------------------------
-- Superfície: só o worker
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.respostas_para_o_agente(integer)',
    'public.enfileirar_resposta(uuid, text)',
    'privado.devolver_rascunho(uuid, text)'
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
END;
$$;

-- A grade estreita, regenerada a partir do corpo do D68 (D59). Duas mudanças:
-- `autonomo` entra no UPDATE de agents, e messages ganha `rascunho_id`, que o
-- REVOKE de tabela inteira do D54 já cobre — conferido, não suposto.
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

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
