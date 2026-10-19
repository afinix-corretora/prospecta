-- Os pendentes passam a rebalancear de verdade (D37).
--
-- O `CLAUDE.md` promete, na invariante 3: "Conta com erro sai do pool sozinha
-- (circuit breaker) e **os pendentes rebalanceiam**." E o comentário do
-- `registrar_falha_remetente` diz até por que isso funcionaria:
--
--     Conta com erro sai do pool sozinha; os pendentes rebalanceiam porque
--     remetentes_disponiveis deixa de retorná-la.
--
-- O raciocínio está escrito e está errado. `remetentes_disponiveis` decide
-- para quem vão as mensagens **futuras**: quem a consulta é o roteador, em
-- `processar_vencidos`, na hora de criar a mensagem. Uma mensagem que já
-- existe carrega o remetente gravado na própria linha, e
-- `reivindicar_pendentes` nunca reperguntava ao pool — só fazia JOIN em
-- `sender_accounts` e entregava o que estava lá.
--
-- Reproduzido antes de corrigir, com duas contas boas no mesmo pool:
--
--   mensagem pendente com o remetente A        A: ativo
--   A acumula 5 falhas, circuito abre          A: circuito_aberto, B: ativo
--   remetentes_disponiveis devolve             B          (certo)
--   reivindicar_pendentes devolve              a mensagem, com A  (errado)
--
-- O estrago é um laço: o despachante tenta enviar por uma conta morta, falha,
-- a falha volta como `culpa = 'remetente'` e afunda A mais um pouco, a
-- mensagem continua `pendente`, e na próxima expiração do lease tudo se
-- repete. B fica parado ao lado. É o mesmo formato do D31 — a garantia estava
-- escrita, a verificação não existia.
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
  -- O fim do castigo é aqui. O circuito se fecha dentro de `reservar_envio`,
  -- que só roda para quem já foi escolhido — uma conta de circuito vencido
  -- ficava fora do pool até alguém tentar usá-la, e ninguém tentava. A borda
  -- do lote é o momento natural de reavaliar.
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
           ci.valor AS destino, c.tipo AS campanha_tipo,
           sa.estado AS estado_atual, sa.identificador AS ident_atual,
           cat.tem_adapter, cat.ativo AS provedor_ativo
      FROM marcada msg
      JOIN contact_identities ci ON ci.id = msg.contact_identity_id
      JOIN enrollments        e  ON e.id = msg.enrollment_id
      JOIN campaigns          c  ON c.id = e.campaign_id
      JOIN sender_accounts    sa ON sa.id = msg.sender_account_id
      JOIN channel_provider_catalog cat ON cat.slug = sa.provedor
  LOOP
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
  'Entrega o lote pendente ao despachante, rebalanceando quem aponta para
   remetente que não despacha mais. Sem candidato, devolve à fila em vez de
   entregar a uma conta morta (D37).';

-- `CREATE OR REPLACE` descarta a grade de privilégios do D19. Reaplicar não é
-- zelo: sem isto a função volta a nascer aberta ao PUBLIC.
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

-- E o comentário que dizia o contrário sai de circulação. Qualificado com
-- `privado.` e com a assinatura inteira: o D19 moveu a função para lá, e sem
-- o schema o COMMENT não acha nada.
COMMENT ON FUNCTION privado.registrar_falha_remetente(uuid, integer, interval) IS
  'Circuit breaker do remetente. Tira a conta do pool para as mensagens
   futuras; quem move as que já existem é reivindicar_pendentes (D37).';
