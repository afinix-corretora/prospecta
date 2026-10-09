-- O resultado do envio passa a carregar de quem é a culpa.
--
-- A versão anterior penalizava o remetente em toda falha. Com os adapters
-- classificando a culpa (remetente / destino / transitorio), isso está errado:
-- um número que não existe no WhatsApp derrubaria uma conta saudável, e cinco
-- números ruins seguidos abririam o circuito de um remetente que nunca falhou.
-- Pool esvaziado por lista suja é o oposto da invariante 3.
--
-- Culpa do destino não é falha de conta — é identidade inválida, que é um dos
-- quatro fatos do contrato de writeback (D3).

-- DROP antes do CREATE, não CREATE OR REPLACE: mudar o número de parâmetros
-- cria sobrecarga em vez de substituir, e aí uma chamada com três argumentos
-- vira "function is not unique" em tempo de execução. Descoberto pelo teste;
-- em produção seria o despachante parando de gravar resultado.
DROP FUNCTION IF EXISTS registrar_resultado_envio(uuid, boolean, text, text);

CREATE FUNCTION registrar_resultado_envio(
  p_message_id  uuid,
  p_ok          boolean,
  p_provider_id text DEFAULT NULL,
  p_erro        text DEFAULT NULL,
  p_culpa       text DEFAULT 'transitorio'
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_sender     uuid;
  v_identidade uuid;
  v_contato    uuid;
BEGIN
  SELECT m.sender_account_id, m.contact_identity_id, e.contact_id
    INTO v_sender, v_identidade, v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = p_message_id;

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
    RETURN;
  END IF;

  IF p_culpa NOT IN ('remetente', 'destino', 'transitorio') THEN
    RAISE EXCEPTION 'culpa inválida: %', p_culpa
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE messages SET status = 'falha', reivindicada_em = NULL WHERE id = p_message_id;

  INSERT INTO message_events (message_id, tipo, payload)
  VALUES (p_message_id,
          (CASE WHEN p_culpa = 'destino' THEN 'rejeitado' ELSE 'falha' END)::tipo_evento,
          jsonb_build_object('erro', coalesce(p_erro, ''), 'culpa', p_culpa));

  IF p_culpa = 'destino' THEN
    -- O endereço é ruim, a conta não. Marca a identidade e conta ao CRM;
    -- o remetente não é penalizado.
    UPDATE contact_identities SET valida = false WHERE id = v_identidade;

    INSERT INTO outbox (contact_id, destino, fato, payload)
    VALUES (v_contato, 'crm', 'identidade_invalida',
            jsonb_build_object('contact_identity_id', v_identidade,
                               'erro', coalesce(p_erro, '')));
  ELSE
    -- Remetente e transitório contam contra a conta: provedor fora do ar
    -- repetidamente também precisa tirar o remetente do pool.
    PERFORM registrar_falha_remetente(v_sender);
  END IF;
END;
$$;
