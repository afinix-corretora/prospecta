-- Reverte o portão de supressão no despacho.
--
-- O valor 'cancelado' NÃO sai do enum: `ALTER TYPE ... DROP VALUE` não existe
-- no PostgreSQL, e recriar o tipo obrigaria a reescrever a coluna de toda
-- mensagem. Valor de enum a mais é inerte; a função é que volta.
--
-- Nota: esta é a versão que despacha para quem já pediu para sair (D39).

CREATE OR REPLACE FUNCTION reivindicar_pendentes(
  p_limite integer DEFAULT 50, p_lease interval DEFAULT interval '5 minutes'
)
RETURNS TABLE (
  message_id uuid, tenant_id uuid, canal canal, destino text, conteudo text,
  sender_id uuid, sender_ident text, campanha_tipo tipo_campanha
)
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE
  m record; candidato sender_accounts%ROWTYPE; v_novo uuid;
BEGIN
  UPDATE sender_accounts
     SET estado = 'ativo', falhas_consecutivas = 0, circuito_aberto_ate = NULL
   WHERE estado = 'circuito_aberto'
     AND circuito_aberto_ate IS NOT NULL AND circuito_aberto_ate <= now();

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
    IF m.estado_atual = 'ativo' AND m.tem_adapter AND m.provedor_ativo THEN
      message_id := m.id; tenant_id := m.tenant_id; canal := m.canal;
      destino := m.destino; conteudo := m.conteudo;
      sender_id := m.sender_account_id; sender_ident := m.ident_atual;
      campanha_tipo := m.campanha_tipo;
      RETURN NEXT; CONTINUE;
    END IF;

    v_novo := NULL;
    FOR candidato IN
      SELECT * FROM privado.remetentes_disponiveis(m.tenant_id, m.canal, m.campanha_tipo)
    LOOP
      IF candidato.id <> m.sender_account_id AND reservar_envio(candidato.id) THEN
        v_novo := candidato.id; EXIT;
      END IF;
    END LOOP;

    IF v_novo IS NULL THEN
      UPDATE messages SET reivindicada_em = NULL WHERE id = m.id;
      CONTINUE;
    END IF;

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
