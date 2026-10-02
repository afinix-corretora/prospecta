-- Agendador e roteador de canal.
--
-- Por que em SQL e não no adapter: a decisão ("quem está vencido, por qual
-- identidade, com qual remetente") precisa ser atômica com a reivindicação do
-- passo. Espalhar isso entre o SELECT e o INSERT em outro processo reabre a
-- janela de corrida que a invariante 1 fecha.
--
-- O que NÃO está aqui: I/O com provedor. O adapter (Fase 1) pega a mensagem
-- já decidida e a envia. Consequência útil: o shadow mode da Fase 3 roda
-- inteiro sem existir nenhum adapter — é este arquivo gravando 'simulado'.
--
-- Fronteira do roteador: a supressão é checada aqui, antes de escolher
-- remetente e antes de qualquer envio, como manda a invariante 2. O trigger
-- em messages continua existindo como rede, não como gate.

-- ---------------------------------------------------------------------------
-- Template
-- ---------------------------------------------------------------------------

-- Substitui {{chave}} pelos valores de p_vars. Chave ausente vira string
-- vazia, nunca a marcação crua — mandar "Oi {{nome}}" para um cliente é pior
-- do que mandar "Oi".
CREATE FUNCTION renderizar(p_template text, p_vars jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_saida text := p_template;
  v_chave text;
BEGIN
  FOR v_chave IN SELECT jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) LOOP
    v_saida := regexp_replace(
      v_saida,
      '\{\{\s*' || regexp_replace(v_chave, '([^\w])', '\\\1', 'g') || '\s*\}\}',
      coalesce(p_vars ->> v_chave, ''),
      'g');
  END LOOP;
  -- Qualquer marcação que sobrou não tinha valor.
  RETURN regexp_replace(v_saida, '\{\{\s*[\w\.]+\s*\}\}', '', 'g');
END;
$$;

-- ---------------------------------------------------------------------------
-- Encerramento
-- ---------------------------------------------------------------------------

CREATE FUNCTION encerrar_enrollment(p_id uuid, p_motivo motivo_encerramento)
RETURNS void
LANGUAGE sql AS $$
  UPDATE enrollments
     SET status = 'encerrado',
         encerrado_em = now(),
         motivo_encerramento = p_motivo,
         next_run_at = NULL
   WHERE id = p_id AND status <> 'encerrado';
$$;

-- ---------------------------------------------------------------------------
-- Agendador
-- ---------------------------------------------------------------------------

-- Uma passada do worker. Devolve o que fez em cada enrollment, para que o
-- shadow mode possa ser comparado passo a passo em vez de por total.
--
-- p_modo:
--   'simulado' — grava messages com status 'simulado'. Não envia (nada aqui
--                envia); o adapter ignora mensagens simuladas.
--   'real'     — grava 'pendente'. O adapter pega as pendentes e envia.
--
-- A quota é reservada nos dois modos, de propósito: o shadow mode existe para
-- mostrar o que o motor faria, e o que ele faria inclui ser freado pelo rate
-- limit. Reservar só no modo real produziria uma simulação otimista.
CREATE FUNCTION processar_vencidos(
  p_limite integer DEFAULT 100,
  p_modo   text    DEFAULT 'simulado'
)
RETURNS TABLE (enrollment_id uuid, acao text, detalhe text)
LANGUAGE plpgsql AS $$
DECLARE
  e            enrollments%ROWTYPE;
  v_campanha   campaigns%ROWTYPE;
  v_passo      flow_steps%ROWTYPE;
  v_identidade contact_identities%ROWTYPE;
  v_remetente  sender_accounts%ROWTYPE;
  v_contato    contacts%ROWTYPE;
  v_proximo    flow_steps%ROWTYPE;
  v_conteudo   text;
  v_status     status_message;
  v_vars       jsonb;
BEGIN
  IF p_modo NOT IN ('simulado', 'real') THEN
    RAISE EXCEPTION 'modo inválido: % (use simulado ou real)', p_modo
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_status := CASE WHEN p_modo = 'simulado' THEN 'simulado' ELSE 'pendente' END::status_message;

  FOR e IN
    SELECT * FROM enrollments
     WHERE status = 'ativo' AND next_run_at IS NOT NULL AND next_run_at <= now()
     ORDER BY next_run_at
     LIMIT p_limite
     FOR UPDATE SKIP LOCKED
  LOOP
    SELECT * INTO v_campanha FROM campaigns WHERE id = e.campaign_id;

    -- Campanha desligada segura a cadência sem encerrar ninguém.
    IF NOT v_campanha.ativa THEN
      enrollment_id := e.id; acao := 'ignorado_campanha_inativa'; detalhe := v_campanha.nome;
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_contato FROM contacts WHERE id = e.contact_id;

    -- INVARIANTE 2, no roteador: antes de escolher remetente, antes do adapter.
    IF esta_suprimido(e.contact_id, NULL, NULL) THEN
      PERFORM encerrar_enrollment(e.id, 'supressao');
      enrollment_id := e.id; acao := 'encerrado_supressao'; detalhe := 'contato suprimido';
      RETURN NEXT; CONTINUE;
    END IF;

    SELECT * INTO v_passo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > e.passo_atual
     ORDER BY ordem LIMIT 1;

    IF NOT FOUND THEN
      PERFORM encerrar_enrollment(e.id, 'fim_dos_passos');
      enrollment_id := e.id; acao := 'encerrado_fim'; detalhe := '';
      RETURN NEXT; CONTINUE;
    END IF;

    -- D4: canal precisa estar habilitado na campanha. Um flow compartilhado
    -- entre campanhas pode ter passo de e-mail numa campanha só de WhatsApp.
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

    -- Endereço suprimido não encerra a pessoa: só inutiliza este canal.
    IF esta_suprimido(e.contact_id, v_identidade.canal, v_identidade.valor_norm) THEN
      UPDATE enrollments SET passo_atual = v_passo.ordem, next_run_at = now() WHERE id = e.id;
      enrollment_id := e.id; acao := 'passo_pulado_identidade_suprimida';
      detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    -- INVARIANTE 3: pool respeita tipo de campanha, quota e circuito.
    SELECT * INTO v_remetente
      FROM remetentes_disponiveis(v_passo.canal, v_campanha.tipo) LIMIT 1;

    IF NOT FOUND OR NOT reservar_envio(v_remetente.id) THEN
      -- Sem vaga agora: adia sem consumir o passo. É assim que os pendentes
      -- rebalanceiam quando uma conta sai do pool.
      UPDATE enrollments SET next_run_at = now() + interval '15 minutes' WHERE id = e.id;
      enrollment_id := e.id; acao := 'adiado_sem_remetente'; detalhe := v_passo.canal::text;
      RETURN NEXT; CONTINUE;
    END IF;

    v_vars := coalesce(v_contato.metadados, '{}'::jsonb)
           || jsonb_build_object('nome', coalesce(v_contato.nome, ''));
    v_conteudo := renderizar(v_passo.template, v_vars);

    -- A reivindicação do passo. Colisão aqui é outro worker que chegou antes;
    -- não é erro, é a invariante 1 funcionando.
    BEGIN
      INSERT INTO messages (enrollment_id, step_id, contact_identity_id,
                            sender_account_id, canal, status, conteudo)
      VALUES (e.id, v_passo.id, v_identidade.id,
              v_remetente.id, v_passo.canal, v_status, v_conteudo);
    EXCEPTION WHEN unique_violation THEN
      enrollment_id := e.id; acao := 'passo_ja_reivindicado'; detalhe := v_passo.ordem::text;
      RETURN NEXT; CONTINUE;
    END;

    -- Avança. Se não há próximo passo, a cadência acabou agora — não espera
    -- outra passada só para descobrir isso.
    SELECT * INTO v_proximo FROM flow_steps
     WHERE flow_version_id = e.flow_version_id AND ordem > v_passo.ordem
     ORDER BY ordem LIMIT 1;

    IF FOUND THEN
      UPDATE enrollments
         SET passo_atual = v_passo.ordem,
             next_run_at = now() + make_interval(hours => v_proximo.atraso_horas)
       WHERE id = e.id;
    ELSE
      UPDATE enrollments SET passo_atual = v_passo.ordem WHERE id = e.id;
      PERFORM encerrar_enrollment(e.id, 'fim_dos_passos');
    END IF;

    enrollment_id := e.id; acao := 'mensagem_criada'; detalhe := v_passo.ordem::text;
    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION processar_vencidos IS
  'Uma passada do agendador. Decide e reivindica; não envia. O adapter consome
   messages com status pendente.';

-- ---------------------------------------------------------------------------
-- Inscrição
-- ---------------------------------------------------------------------------

-- Inscreve um contato, recusando quem está suprimido antes de criar estado.
CREATE FUNCTION inscrever(
  p_contact_id      uuid,
  p_campaign_id     uuid,
  p_flow_version_id uuid,
  p_quando          timestamptz DEFAULT now()
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  IF esta_suprimido(p_contact_id, NULL, NULL) THEN
    RETURN NULL;
  END IF;

  INSERT INTO enrollments (contact_id, campaign_id, flow_version_id, next_run_at)
  VALUES (p_contact_id, p_campaign_id, p_flow_version_id, p_quando)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
