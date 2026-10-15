-- Reverte 20260917140000_culpa_no_resultado.sql
--
-- Volta à assinatura de quatro parâmetros. A de cinco precisa ser derrubada
-- explicitamente: CREATE OR REPLACE não removeu a anterior, criou sobrecarga.

DROP FUNCTION IF EXISTS registrar_resultado_envio(uuid, boolean, text, text, text);

CREATE OR REPLACE FUNCTION registrar_resultado_envio(
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
       SET status = 'enviado', provider_message_id = p_provider_id, reivindicada_em = NULL
     WHERE id = p_message_id;
    INSERT INTO message_events (message_id, tipo, payload)
    VALUES (p_message_id, 'enviado', jsonb_build_object('provider_message_id', p_provider_id));
    PERFORM registrar_sucesso_remetente(v_sender);
  ELSE
    UPDATE messages SET status = 'falha', reivindicada_em = NULL WHERE id = p_message_id;
    INSERT INTO message_events (message_id, tipo, payload)
    VALUES (p_message_id, 'falha', jsonb_build_object('erro', coalesce(p_erro, '')));
    PERFORM registrar_falha_remetente(v_sender);
  END IF;
END;
$$;
