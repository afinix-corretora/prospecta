-- O despachante passa a concordar com o agendador (D40).
--
-- Sequência do D39: se a supressão precisava de portão no despacho porque a
-- janela `pendente` é ilimitada, a pergunta seguinte é **o que mais assume
-- que essa janela é curta**. Três coisas, e as três foram reproduzidas:
--
--   situação                        enrollment              despachava?
--   pessoa respondeu                encerrado / resposta    sim
--   operador pausou                 pausado                 sim
--   campanha desligada              ativo, campanha off     sim
--
-- A primeira é a invariante 4 furada pela borda: "resposta em qualquer canal
-- encerra o enrollment inteiro, não só o passo" — e a mensagem já enfileirada
-- saía mesmo assim, ou seja, a pessoa que acabou de responder levava mais um
-- toque. As outras duas são o despachante discordando do agendador sobre o
-- mesmo fato: `processar_vencidos` já pula campanha inativa
-- (`ignorado_campanha_inativa`) e só olha enrollment `ativo`.
--
-- A regra óbvia — "só despacha enrollment ativo" — está ERRADA, e o mesmo
-- experimento mostrou por quê: no último passo de toda cadência o agendador
-- cria a mensagem e **encerra** o enrollment com `fim_dos_passos` na mesma
-- passada. Filtrar por `ativo` mataria a última mensagem de todas as
-- campanhas. Foi o cenário de um passo só que expôs isso.
--
-- Então são três saídas, não duas:
--
--   cancelar  parada definitiva — encerrado por motivo que não é
--             `fim_dos_passos`. Não volta atrás, e a chave única
--             `(enrollment_id, step_id)` impede recriar o passo.
--   segurar   pausa e campanha desligada são temporárias. A mensagem fica
--             `pendente` e sai quando religarem. Mesma lógica do D37: adiar é
--             recuperável, queimar não é.
--   despachar o resto, inclusive `encerrado / fim_dos_passos`.
--
-- `falha_permanente` entra em "cancelar" junto com os outros: nada no motor o
-- produz hoje (só o mapa do backfill), e enrollment que terminou em falha
-- permanente não ganha nada com mais um toque enfileirado.
--
-- Sem barra invertida (D32).

CREATE OR REPLACE FUNCTION reivindicar_pendentes(
  p_limite integer DEFAULT 50, p_lease interval DEFAULT interval '5 minutes'
)
RETURNS TABLE (
  message_id uuid, tenant_id uuid, canal canal, destino text, conteudo text,
  sender_id uuid, sender_ident text, campanha_tipo tipo_campanha
)
LANGUAGE plpgsql SET search_path = public, privado AS $$
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
    IF m.estado_atual = 'ativo' AND m.tem_adapter AND m.provedor_ativo THEN
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
      SELECT * FROM privado.remetentes_disponiveis(m.tenant_id, m.canal, m.campanha_tipo)
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
$$;

COMMENT ON FUNCTION reivindicar_pendentes IS
  'Entrega o lote pendente ao despachante, concordando com o agendador sobre
   supressão (D39), encerramento e pausa (D40), e rebalanceando remetente que
   não despacha mais (D37). Parada definitiva cancela; temporária segura.';

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION reivindicar_pendentes(integer, interval) FROM PUBLIC, anon, authenticated';
  FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION reivindicar_pendentes(integer, interval) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
