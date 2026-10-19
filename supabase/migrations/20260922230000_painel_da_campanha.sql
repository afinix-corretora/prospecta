-- O que o motor fez, visível no produto (D36).
--
-- Depois de inscrever, o app não mostrava nada. O console (`ui/console.html`)
-- mostra o demo, não o cliente — então a pessoa liga o motor e fica no escuro
-- exatamente na hora em que mais precisa ver: shadow mode roda completo e não
-- envia nada, e sem uma tela dizendo "criou 14 mensagens simuladas" o modo que
-- de-risca o projeto inteiro é indistinguível de estar quebrado.
--
-- Por que contar no SQL e não no cliente: contagem sobre milhares de
-- enrollments não vai pelo PostgREST linha a linha. E o `next_run_at` mínimo
-- responde a única pergunta que a pessoa realmente faz na primeira semana —
-- "quando é a próxima?".
--
-- Sem barra invertida (D32).

CREATE FUNCTION resumo_da_campanha(p_tenant uuid, p_campaign_id uuid)
RETURNS TABLE (
  inscritos_ativos integer,
  inscritos_pausados integer,
  encerrados       integer,
  por_motivo       jsonb,
  mensagens        integer,
  por_status       jsonb,
  respostas        integer,
  cliques          integer,
  vencidos_agora   integer,
  proximo_disparo  timestamptz
)
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  WITH e AS (
    SELECT * FROM enrollments
     WHERE tenant_id = p_tenant AND campaign_id = p_campaign_id
  ),
  m AS (
    SELECT msg.* FROM messages msg JOIN e ON e.id = msg.enrollment_id
     WHERE msg.tenant_id = p_tenant
  ),
  ev AS (
    SELECT me.tipo FROM message_events me JOIN m ON m.id = me.message_id
  )
  SELECT
    (SELECT count(*) FROM e WHERE status = 'ativo')::integer,
    (SELECT count(*) FROM e WHERE status = 'pausado')::integer,
    (SELECT count(*) FROM e WHERE status = 'encerrado')::integer,
    -- Objeto, não lista: a tela lê por chave e não depende da ordem do enum.
    coalesce((SELECT jsonb_object_agg(motivo_encerramento, n) FROM (
      SELECT motivo_encerramento, count(*) AS n FROM e
       WHERE motivo_encerramento IS NOT NULL GROUP BY 1) x), '{}'::jsonb),
    (SELECT count(*) FROM m)::integer,
    coalesce((SELECT jsonb_object_agg(status, n) FROM (
      SELECT status, count(*) AS n FROM m GROUP BY 1) y), '{}'::jsonb),
    -- Resposta e clique vêm de `message_events`, que é append-only: contar
    -- pelo evento é o que faz o número bater com a invariante 4 e com o D7.
    (SELECT count(*) FROM ev WHERE tipo = 'respondido')::integer,
    (SELECT count(*) FROM ev WHERE tipo = 'clique')::integer,
    (SELECT count(*) FROM e
      WHERE status = 'ativo' AND next_run_at IS NOT NULL AND next_run_at <= now())::integer,
    (SELECT min(next_run_at) FROM e WHERE status = 'ativo' AND next_run_at IS NOT NULL);
$$;

COMMENT ON FUNCTION resumo_da_campanha IS
  'Contadores de uma campanha para a tela. Conta no banco porque milhares de
   enrollments não passam pelo PostgREST linha a linha (D36).';

-- ---------------------------------------------------------------------------
-- A linha do tempo
-- ---------------------------------------------------------------------------

-- `message_events` é append-only e o status é derivado, nunca sobrescrito
-- (convenção do CLAUDE.md). Então a linha do tempo não é enfeite: é a própria
-- fonte de verdade, lida na ordem em que os fatos aconteceram.
CREATE FUNCTION eventos_da_campanha(
  p_tenant uuid, p_campaign_id uuid, p_limite integer DEFAULT 100
)
RETURNS TABLE (
  ocorrido_em timestamptz,
  contato     text,
  canal       canal,
  tipo        tipo_evento,
  -- O status da mensagem, e não o remetente, é o que diz se algo saiu de
  -- casa: em shadow mode o motor **escolhe e reserva** remetente normalmente,
  -- só não envia. Uma coluna de remetente vazia seria o sinal errado, e uma
  -- que dissesse "(shadow mode)" seria mentira — quem sabe é o `simulado`.
  status      status_message,
  remetente   text,
  destino     text
)
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  SELECT me.ocorrido_em,
         coalesce(c.nome, '(sem nome)'),
         m.canal,
         me.tipo,
         m.status,
         coalesce(sa.apelido, sa.identificador, '(sem remetente)'),
         ci.valor
    FROM message_events me
    JOIN messages m       ON m.id = me.message_id AND m.tenant_id = p_tenant
    JOIN enrollments e    ON e.id = m.enrollment_id AND e.campaign_id = p_campaign_id
    JOIN contacts c       ON c.id = e.contact_id
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
    LEFT JOIN sender_accounts sa ON sa.id = m.sender_account_id
   ORDER BY me.ocorrido_em DESC, me.criado_em DESC
   LIMIT least(coalesce(p_limite, 100), 500);
$$;

COMMENT ON FUNCTION eventos_da_campanha IS
  'Linha do tempo de uma campanha a partir de message_events, que é append-only
   e é a fonte de verdade do status (D36).';

-- ---------------------------------------------------------------------------
-- Superfície: as duas são API — a tela da campanha chama
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; f text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'resumo_da_campanha(uuid, uuid)',
    'eventos_da_campanha(uuid, uuid, integer)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f);
    FOREACH papel IN ARRAY ARRAY['authenticated','service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', f, papel);
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
