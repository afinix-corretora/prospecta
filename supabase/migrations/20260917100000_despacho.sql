-- Superfície de despacho: o que o ChannelAdapter consome e devolve.
--
-- O agendador decide e reivindica o passo; o adapter envia. Entre os dois há
-- uma fila de mensagens `pendente` que precisa ser reivindicada sem que dois
-- workers peguem a mesma.
--
-- Por que lease e não status intermediário: 'em_envio' seria status-como-mutex,
-- que é justamente o que o DECISOES.md manda descartar. Aqui o status continua
-- derivado dos eventos, e a reivindicação é um carimbo com prazo.

ALTER TABLE messages
  ADD COLUMN reivindicada_em timestamptz;

COMMENT ON COLUMN messages.reivindicada_em IS
  'Lease do despachante. Mensagem reivindicada há mais que o prazo volta ao
   pool: worker que morreu no meio não deixa mensagem presa para sempre.';

CREATE INDEX messages_pendentes_idx
  ON messages (criado_em) WHERE status = 'pendente';

-- ---------------------------------------------------------------------------
-- Reivindicação
-- ---------------------------------------------------------------------------

-- Entrega ao despachante tudo que ele precisa para enviar, sem que ele precise
-- consultar mais nada — e sem expor o segredo do remetente, que vive no Vault
-- e é resolvido pelo adapter.
CREATE FUNCTION reivindicar_pendentes(
  p_limite integer  DEFAULT 50,
  p_lease  interval DEFAULT interval '5 minutes'
)
RETURNS TABLE (
  message_id       uuid,
  canal            canal,
  destino          text,
  conteudo         text,
  sender_id        uuid,
  sender_ident     text,
  campanha_tipo    tipo_campanha
)
LANGUAGE sql AS $$
  WITH alvo AS (
    SELECT m.id
      FROM messages m
     WHERE m.status = 'pendente'
       AND (m.reivindicada_em IS NULL OR m.reivindicada_em < now() - p_lease)
     ORDER BY m.criado_em
     LIMIT p_limite
     FOR UPDATE SKIP LOCKED
  ), marcada AS (
    UPDATE messages m SET reivindicada_em = now()
      FROM alvo WHERE m.id = alvo.id
    RETURNING m.*
  )
  SELECT m.id, m.canal, ci.valor, m.conteudo,
         sa.id, sa.identificador, c.tipo
    FROM marcada m
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
    JOIN sender_accounts   sa ON sa.id = m.sender_account_id
    JOIN enrollments        e ON e.id = m.enrollment_id
    JOIN campaigns          c ON c.id = e.campaign_id;
$$;

-- ---------------------------------------------------------------------------
-- Resultado
-- ---------------------------------------------------------------------------

-- O adapter devolve o que aconteceu. Aqui o resultado vira evento (append-only),
-- status derivado e saúde do remetente — nas três coisas de uma vez, para não
-- existir estado meio gravado.
CREATE FUNCTION registrar_resultado_envio(
  p_message_id  uuid,
  p_ok          boolean,
  p_provider_id text DEFAULT NULL,
  p_erro        text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_sender uuid;
BEGIN
  SELECT sender_account_id INTO v_sender FROM messages WHERE id = p_message_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'mensagem inexistente: %', p_message_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_ok THEN
    UPDATE messages
       SET status = 'enviado',
           provider_message_id = p_provider_id,
           reivindicada_em = NULL
     WHERE id = p_message_id;

    INSERT INTO message_events (message_id, tipo, payload)
    VALUES (p_message_id, 'enviado',
            jsonb_build_object('provider_message_id', p_provider_id));

    PERFORM registrar_sucesso_remetente(v_sender);
  ELSE
    UPDATE messages
       SET status = 'falha', reivindicada_em = NULL
     WHERE id = p_message_id;

    INSERT INTO message_events (message_id, tipo, payload)
    VALUES (p_message_id, 'falha', jsonb_build_object('erro', coalesce(p_erro, '')));

    -- Falha de envio conta contra o remetente: é assim que a conta com
    -- problema sai do pool sozinha (invariante 3).
    PERFORM registrar_falha_remetente(v_sender);
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Eventos vindos do provedor
-- ---------------------------------------------------------------------------

-- O adapter normaliza o webhook e chama isto. Casar pelo id do provedor é o
-- que liga o retorno assíncrono à mensagem que o motor mandou.
--
-- Autoria: eventos cujo payload traz a nossa marca são eco do próprio motor e
-- são descartados, para não virar "resposta" do contato.
CREATE FUNCTION registrar_evento_provedor(
  p_provider_id text,
  p_tipo        tipo_evento,
  p_ocorrido_em timestamptz DEFAULT now(),
  p_payload     jsonb       DEFAULT '{}'::jsonb
) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_message uuid;
BEGIN
  IF p_payload ->> 'autoria' = 'motor-prospeccao' THEN
    RETURN false;
  END IF;

  SELECT id INTO v_message FROM messages
   WHERE provider_message_id = p_provider_id
   ORDER BY criado_em DESC LIMIT 1;

  IF v_message IS NULL THEN
    RETURN false;
  END IF;

  INSERT INTO message_events (message_id, tipo, ocorrido_em, payload)
  VALUES (v_message, p_tipo, p_ocorrido_em, p_payload);

  RETURN true;
END;
$$;
