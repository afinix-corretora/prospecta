-- O evento do provedor passa a dizer de qual chip veio (D38).
--
-- `registrar_evento_provedor(p_provider_id, ...)` não recebia tenant nenhum e
-- procurava assim:
--
--     SELECT id FROM messages
--      WHERE provider_message_id = p_provider_id
--      ORDER BY criado_em DESC LIMIT 1;
--
-- Em todos os clientes. Com `provider_message_id` colidido entre dois
-- tenants, o evento cai na mensagem mais nova — e se o evento é `respondido`,
-- **encerra a cadência do cliente errado**. Se é `rejeitado`, invalida a
-- identidade de outro cliente e escreve `identidade_invalida` no CRM dele.
--
-- Reproduzido antes de corrigir: dois clientes com a mesma
-- `provider_message_id`, um webhook de resposta, e o enrollment do Cliente B
-- encerrado por um evento que podia ter vindo do chip do Cliente A.
--
-- É o dano do D24 na outra via de casamento. E é literalmente a anti-regra do
-- `CLAUDE.md`: "Nunca deixar tenant implícito em assinatura de função. É como
-- bug entre clientes acontece." A irmã dela, `registrar_resposta_por_numero`,
-- já fazia certo desde o D24 — recebe o chip, tira o tenant dele e filtra. E
-- o comentário do `motor/webhooks.ts` explicava a razão no ramo de baixo
-- enquanto o ramo de cima cometia o erro:
--
--     Sem chip não há tenant, e sem tenant casar pelo número escolheria a
--     mensagem de outro cliente. Melhor descartar do que acertar o errado.
--
-- A assinatura antiga é DERRUBADA, não mantida ao lado: deixá-la viva é
-- deixar o buraco alcançável.
--
-- Sem barra invertida (D32).

DROP FUNCTION IF EXISTS registrar_evento_provedor(text, tipo_evento, timestamptz, jsonb);

CREATE FUNCTION registrar_evento_provedor(
  p_sender_id   uuid,
  p_provider_id text,
  p_tipo        tipo_evento,
  p_ocorrido_em timestamptz DEFAULT now(),
  p_payload     jsonb       DEFAULT '{}'::jsonb
) RETURNS boolean
LANGUAGE plpgsql SET search_path = public, privado AS $$
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
$$;

COMMENT ON FUNCTION registrar_evento_provedor IS
  'Evento de provedor casado por provider_message_id, dentro do tenant do chip
   que recebeu o webhook. Sem o chip o casamento atravessa clientes (D38).';

-- A grade que a função tinha: só o worker chama, pelo service key.
DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION registrar_evento_provedor(uuid, text, tipo_evento, timestamptz, jsonb) FROM PUBLIC, anon, authenticated';
  FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION registrar_evento_provedor(uuid, text, tipo_evento, timestamptz, jsonb) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
