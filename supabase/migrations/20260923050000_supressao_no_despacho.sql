-- A supressão passa a valer também depois da mensagem criada (D39).
--
-- A invariante 2 do `CLAUDE.md` diz: "Contato em `suppression` nunca recebe
-- nada, **por nenhum caminho de código**." O gatilho
-- `messages_respeita_supressao` guarda o INSERT em `messages` — ou seja, o
-- momento em que o roteador cria a mensagem. O despacho não tinha portão
-- nenhum.
--
-- A janela entre criar e despachar não é teórica: a mensagem nasce
-- `pendente` e espera o despachante. Se a pessoa pede para sair nesse meio —
-- por telefone, por outro canal, por importação de lista de opt-out — a
-- mensagem sai assim mesmo. E desde o D37 a janela é **ilimitada**: sem
-- remetente disponível, a mensagem fica pendente indefinidamente.
--
-- Reproduzido antes de corrigir: mensagem pendente, `suppression` inserida,
-- `esta_suprimido` devolvendo true, e `reivindicar_pendentes` entregando a
-- mensagem ao despachante mesmo assim.
--
-- Num produto de prospecção fria no Brasil, é o defeito mais caro da lista:
-- o opt-out está registrado e a mensagem vai embora.
--
-- Sem barra invertida (D32).

-- `cancelado` é estado de primeira classe, não sinônimo de falha. Mesmo
-- argumento do D13, que criou `cancelado_operacional`: forçar isto em `falha`
-- faria o painel contar opt-out honrado como falha do motor — e faria a conta
-- que enviou levar a culpa no health score.
ALTER TYPE status_message ADD VALUE IF NOT EXISTS 'cancelado';

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
  -- O fim do castigo é aqui. O circuito se fecha dentro de `reservar_envio`,
  -- que só roda para quem já foi escolhido — uma conta de circuito vencido
  -- ficava fora do pool até alguém tentar usá-la, e ninguém tentava. A borda
  -- do lote é o momento natural de reavaliar (D37).
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
           sa.estado AS estado_atual, sa.identificador AS ident_atual,
           cat.tem_adapter, cat.ativo AS provedor_ativo
      FROM marcada msg
      JOIN contact_identities ci ON ci.id = msg.contact_identity_id
      JOIN enrollments        e  ON e.id = msg.enrollment_id
      JOIN campaigns          c  ON c.id = e.campaign_id
      JOIN sender_accounts    sa ON sa.id = msg.sender_account_id
      JOIN channel_provider_catalog cat ON cat.slug = sa.provedor
  LOOP
    -- O portão que faltava (D39). A supressão é reperguntada aqui porque o
    -- gatilho de `messages` guarda a criação, e entre criar e despachar a
    -- pessoa pode ter pedido para sair. Vale antes de qualquer outra coisa:
    -- a supressão está acima de quota, de pool e de rebalanceamento.
    IF esta_suprimido(m.tenant_id, m.contact_id, m.canal, m.valor_norm) THEN
      -- `cancelado`, não `falha`: opt-out honrado não é defeito do motor nem
      -- da conta que ia enviar.
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      -- O enrollment é encerrado pelo agendador na próxima batida, que já faz
      -- isso e tem teste. Aqui o assunto é só não deixar a mensagem sair.
      CONTINUE;
    END IF;

    -- Quota NÃO entra nesta checagem: a reserva desta mensagem já foi paga
    -- quando o roteador a criou. Recobrar seria negar o envio duas vezes.
    IF m.estado_atual = 'ativo' AND m.tem_adapter AND m.provedor_ativo THEN
      message_id := m.id; tenant_id := m.tenant_id; canal := m.canal;
      destino := m.destino; conteudo := m.conteudo;
      sender_id := m.sender_account_id; sender_ident := m.ident_atual;
      campanha_tipo := m.campanha_tipo;
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- O remetente gravado não despacha mais. Procura outro no mesmo pool.
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
      -- Sem para onde ir: devolve à fila em vez de entregar a um remetente
      -- morto. Adiar é recuperável; queimar a tentativa não é, e cada
      -- tentativa contra conta morta afunda ainda mais o health score dela.
      -- A mensagem fica `pendente`, que é o que o painel da campanha mostra.
      UPDATE messages SET reivindicada_em = NULL WHERE id = m.id;
      CONTINUE;
    END IF;

    -- A reserva do remetente antigo NÃO é devolvida, de propósito. Não dá
    -- para saber se ele chegou a entregar antes de adoecer, e devolver o
    -- crédito é o único jeito de furar a invariante 3. Contar a mais aperta o
    -- envio; contar a menos ultrapassa a quota.
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
  'Entrega o lote pendente ao despachante. Recusa quem foi suprimido depois da
   mensagem criada (D39), rebalanceia quem aponta para remetente que não
   despacha mais, e sem candidato devolve à fila (D37).';

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
