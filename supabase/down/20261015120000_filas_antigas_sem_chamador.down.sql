-- As duas filas antigas do agente voltam, com o corpo e a grade que tinham
-- depois do D76: só o worker (service_role) as executa (D66, D69).

CREATE OR REPLACE FUNCTION public.respostas_para_rascunhar(p_limite integer DEFAULT 20)
 RETURNS TABLE(message_event_id uuid, tenant_id uuid, contact_id uuid, resposta_em timestamp with time zone, canal canal, texto text, regra text, agent_id uuid, agente_nome text, papel text, descricao text, instrucoes text, escalar_quando text, limite_trocas integer, proibido text[], tamanho_maximo integer, credencial_id uuid, provedor text, modelo text, provedor_compoe boolean, contato_nome text, metadados jsonb, campanha text, historico jsonb, rascunhos_anteriores integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
  WITH respostas AS (
    SELECT me.id, me.tenant_id, e.contact_id, me.ocorrido_em, m.canal, me.payload ->> 'texto' AS texto,
           e.campaign_id, m.contact_identity_id,
           row_number() OVER (PARTITION BY me.tenant_id, e.contact_id
                              ORDER BY me.ocorrido_em DESC, me.criado_em DESC) AS n
      FROM message_events me
      JOIN messages m    ON m.tenant_id = me.tenant_id AND m.id = me.message_id
      JOIN enrollments e ON e.tenant_id = m.tenant_id AND e.id = m.enrollment_id
     WHERE me.tipo = 'respondido'
       AND jsonb_typeof(me.payload -> 'texto') = 'string'
       AND me.ocorrido_em > now() - interval '7 days'
  )
  SELECT r.id, r.tenant_id, r.contact_id, r.ocorrido_em, r.canal, r.texto,
         (SELECT x.acao::text FROM privado.regra_da_resposta(r.tenant_id, r.texto) x LIMIT 1),
         a.id, a.nome, a.papel, a.descricao, a.instrucoes,
         a.escalar_quando, a.limite_trocas, a.proibido, a.tamanho_maximo,
         ac.id, ac.provedor, ac.modelo, coalesce(pc.tem_adapter AND ac.ativo, false),
         c.nome, c.metadados, camp.nome,
         -- A conversa até aqui, nos dois sentidos, mais antiga primeiro. Só o
         -- que saiu de verdade: rascunho de simulado não é conversa.
         (SELECT coalesce(jsonb_agg(h.item ORDER BY h.quando), '[]'::jsonb) FROM (
            SELECT jsonb_build_object('de', 'nos', 'texto', m2.conteudo) AS item, m2.criado_em AS quando
              FROM messages m2 JOIN enrollments e2 ON e2.tenant_id = m2.tenant_id AND e2.id = m2.enrollment_id
             WHERE m2.tenant_id = r.tenant_id AND e2.contact_id = r.contact_id
               AND m2.status NOT IN ('simulado', 'cancelado', 'falha', 'pendente')
            UNION ALL
            SELECT jsonb_build_object('de', 'pessoa', 'texto', me2.payload ->> 'texto'), me2.ocorrido_em
              FROM message_events me2
              JOIN messages m3    ON m3.tenant_id = me2.tenant_id AND m3.id = me2.message_id
              JOIN enrollments e3 ON e3.tenant_id = m3.tenant_id AND e3.id = m3.enrollment_id
             WHERE me2.tenant_id = r.tenant_id AND e3.contact_id = r.contact_id
               AND me2.tipo = 'respondido' AND jsonb_typeof(me2.payload -> 'texto') = 'string'
            ORDER BY 2 DESC LIMIT 20) h),
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.contact_id = r.contact_id AND x.situacao = 'pronto')
    FROM respostas r
    JOIN contacts c   ON c.tenant_id = r.tenant_id AND c.id = r.contact_id
    JOIN campaigns camp ON camp.tenant_id = r.tenant_id AND camp.id = r.campaign_id
    JOIN campaign_agents ca ON ca.tenant_id = r.tenant_id AND ca.campaign_id = r.campaign_id AND ca.canal = r.canal
    JOIN agents a     ON a.tenant_id = r.tenant_id AND a.id = ca.agent_id AND a.ativo
    -- A conta escolhida na campanha vale sobre a do agente (D68): o agente é
    -- uma persona que várias campanhas dividem, e a conta é decisão de cada uma.
    LEFT JOIN ai_credentials ac ON ac.tenant_id = a.tenant_id
                               AND ac.id = coalesce(camp.ai_credential_id, a.ai_credential_id)
    LEFT JOIN ai_provider_catalog pc ON pc.slug = ac.provedor
    JOIN contact_identities ci ON ci.tenant_id = r.tenant_id AND ci.id = r.contact_identity_id
   WHERE r.n = 1
     AND NOT EXISTS (SELECT 1 FROM rascunhos x WHERE x.tenant_id = r.tenant_id AND x.message_event_id = r.id)
     -- Nem rascunho para quem pediu para sair: um texto pronto é convite a
     -- uma pessoa mandar. A pessoa inteira e o endereço, como no despacho.
     AND NOT esta_suprimido(r.tenant_id, r.contact_id, r.canal, ci.valor_norm)
   ORDER BY r.ocorrido_em
   LIMIT least(coalesce(p_limite, 20), 100);
$function$

;

CREATE OR REPLACE FUNCTION public.respostas_para_o_agente(p_limite integer DEFAULT 20)
 RETURNS TABLE(message_event_id uuid, tenant_id uuid, contact_id uuid, resposta_em timestamp with time zone, canal canal, texto text, regra text, agent_id uuid, agente_nome text, papel text, descricao text, instrucoes text, escalar_quando text, limite_trocas integer, proibido text[], tamanho_maximo integer, credencial_id uuid, provedor text, modelo text, provedor_compoe boolean, contato_nome text, metadados jsonb, campanha text, historico jsonb, rascunhos_anteriores integer, autonomo boolean, composicoes_hoje integer, teto integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
  WITH respostas AS (
    SELECT me.id, me.tenant_id, e.contact_id, me.ocorrido_em, m.canal, me.payload ->> 'texto' AS texto,
           e.campaign_id, m.contact_identity_id,
           row_number() OVER (PARTITION BY me.tenant_id, e.contact_id
                              ORDER BY me.ocorrido_em DESC, me.criado_em DESC) AS n
      FROM message_events me
      JOIN messages m    ON m.tenant_id = me.tenant_id AND m.id = me.message_id
      JOIN enrollments e ON e.tenant_id = m.tenant_id AND e.id = m.enrollment_id
     WHERE me.tipo = 'respondido'
       AND jsonb_typeof(me.payload -> 'texto') = 'string'
       AND me.ocorrido_em > now() - interval '7 days'
  )
  SELECT r.id, r.tenant_id, r.contact_id, r.ocorrido_em, r.canal, r.texto,
         (SELECT x.acao::text FROM privado.regra_da_resposta(r.tenant_id, r.texto) x LIMIT 1),
         a.id, a.nome, a.papel, a.descricao, a.instrucoes,
         a.escalar_quando, a.limite_trocas, a.proibido,
         -- D76: nulo é "o do canal", que o v7 não conhece. Esta fila fica sem
         -- chamador com o v8; o 700 é o que o v7 sempre usou, para ele continuar
         -- sendo um rollback seguro.
         coalesce(a.tamanho_maximo, 700),
         ac.id, ac.provedor, ac.modelo, coalesce(pc.tem_adapter AND ac.ativo, false),
         c.nome, c.metadados, camp.nome,
         -- A conversa até aqui, nos dois sentidos, mais antiga primeiro. Só o
         -- que saiu de verdade: rascunho de simulado não é conversa. A
         -- mensagem do agente entra como "nós", que é o que ela é.
         (SELECT coalesce(jsonb_agg(h.item ORDER BY h.quando), '[]'::jsonb) FROM (
            SELECT jsonb_build_object('de', 'nos', 'texto', m2.conteudo) AS item, m2.criado_em AS quando
              FROM messages m2 JOIN enrollments e2 ON e2.tenant_id = m2.tenant_id AND e2.id = m2.enrollment_id
             WHERE m2.tenant_id = r.tenant_id AND e2.contact_id = r.contact_id
               AND m2.status NOT IN ('simulado', 'cancelado', 'falha', 'pendente')
            UNION ALL
            SELECT jsonb_build_object('de', 'pessoa', 'texto', me2.payload ->> 'texto'), me2.ocorrido_em
              FROM message_events me2
              JOIN messages m3    ON m3.tenant_id = me2.tenant_id AND m3.id = me2.message_id
              JOIN enrollments e3 ON e3.tenant_id = m3.tenant_id AND e3.id = m3.enrollment_id
             WHERE me2.tenant_id = r.tenant_id AND e3.contact_id = r.contact_id
               AND me2.tipo = 'respondido' AND jsonb_typeof(me2.payload -> 'texto') = 'string'
            ORDER BY 2 DESC LIMIT 20) h),
         -- As trocas da conversa: texto pronto que saiu ou ficou com uma
         -- pessoa. O devolvido não conta — ele não foi uma troca.
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.contact_id = r.contact_id
             AND x.situacao = 'pronto' AND x.envio <> 'devolvido'),
         a.autonomo,
         -- (d): composições do cliente nas últimas 24h. Conta o que chamou o
         -- modelo; recusa, limite e falta de credencial não custaram nada.
         (SELECT count(*)::integer FROM rascunhos x
           WHERE x.tenant_id = r.tenant_id AND x.criado_em > now() - interval '1 day'
             AND x.situacao IN ('pronto', 'escalar', 'bloqueado', 'erro')),
         t.teto_agente_dia
    FROM respostas r
    JOIN tenants t    ON t.id = r.tenant_id
    JOIN contacts c   ON c.tenant_id = r.tenant_id AND c.id = r.contact_id
    JOIN campaigns camp ON camp.tenant_id = r.tenant_id AND camp.id = r.campaign_id
    JOIN campaign_agents ca ON ca.tenant_id = r.tenant_id AND ca.campaign_id = r.campaign_id AND ca.canal = r.canal
    JOIN agents a     ON a.tenant_id = r.tenant_id AND a.id = ca.agent_id AND a.ativo
                     -- D76: o v7 não sabe montar o prompt do agente de todos os
                     -- canais. Com ele, o agente novo não compõe.
                     AND a.canal IS NOT NULL
    -- A conta escolhida na campanha vale sobre a do agente (D68): o agente é
    -- uma persona que várias campanhas dividem, e a conta é decisão de cada uma.
    LEFT JOIN ai_credentials ac ON ac.tenant_id = a.tenant_id
                               AND ac.id = coalesce(camp.ai_credential_id, a.ai_credential_id)
    LEFT JOIN ai_provider_catalog pc ON pc.slug = ac.provedor
    JOIN contact_identities ci ON ci.tenant_id = r.tenant_id AND ci.id = r.contact_identity_id
   WHERE r.n = 1
     -- D76: a vigência vale também aqui. As linhas que já existem estão em
     -- -infinity, então para elas o v7 segue igual; a exceção escolhida ou o
     -- agente religado depois da migration não responde o que chegou antes —
     -- no intervalo até o v8 e em qualquer volta ao v7.
     AND r.ocorrido_em >= greatest(ca.vigente_desde, a.ativo_desde)
     AND NOT EXISTS (SELECT 1 FROM rascunhos x WHERE x.tenant_id = r.tenant_id AND x.message_event_id = r.id)
     -- Nem rascunho para quem pediu para sair: um texto pronto é convite a
     -- uma pessoa mandar — e agora ao motor. A pessoa inteira e o endereço.
     AND NOT esta_suprimido(r.tenant_id, r.contact_id, r.canal, ci.valor_norm)
   ORDER BY r.ocorrido_em
   LIMIT least(coalesce(p_limite, 20), 100);
$function$

;

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.respostas_para_rascunhar(integer)',
    'public.respostas_para_o_agente(integer)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', alvo);
    END IF;
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;
END $$;
