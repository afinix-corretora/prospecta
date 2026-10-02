-- O backfill do legado, primeira parte: pessoas e supressão (Fase 2).
--
-- Ferramenta, não schema de runtime. Carregada depois de `mapa_status.sql` e
-- `legado.sql`, com `legado.*` preenchido e `backfill/normalizar.ts` já
-- rodado. Apagada depois, com `legado`.
--
-- O que esta parte faz, e por que é ela que vem primeiro:
--
--   supressão   quem pediu para sair no legado não recebe nada aqui, desde o
--               primeiro minuto. É a invariante 2, e o MAPA-STATUS manda que
--               ela venha antes de qualquer enrollment.
--   pessoas     uma por telefone normalizado, com as identidades que o
--               legado afirma: o telefone era de WhatsApp (o legado conversava
--               por ele), vira SMS também só quando é celular (D33), e o
--               e-mail de `contacts` entra quando é de uma pessoa só.
--
-- O que ela NÃO faz: levar as cadências ativas do legado para o motor. Para
-- isso cada campanha antiga precisa de uma cadência escolhida por alguém — e
-- inscrever sem cadência não existe (D47). A prévia conta quantos leads cada
-- campanha antiga ainda tinha em curso, para essa decisão ser tomada com o
-- número na mão; inscrever depois é a tela de contatos, com a prévia dela.
--
-- Duas funções, as duas com o tenant explícito:
--
--   backfill.previa(tenant)  diz tudo o que aconteceria. Não escreve nada.
--   backfill.gravar(tenant)  escreve, numa transação, e devolve o mesmo
--                            relatório com o que foi feito. Rodar de novo não
--                            duplica nada.
--
-- Sem barra invertida (D32).

CREATE SCHEMA IF NOT EXISTS backfill;
REVOKE ALL ON SCHEMA backfill FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- As pessoas que o legado conhece, uma por telefone normalizado
-- ---------------------------------------------------------------------------

-- Toda aparição de um telefone, de qualquer tabela, com o que ela traz.
-- `prioridade` decide de quem é o nome quando duas fontes discordam: o
-- cadastro de contato vem antes do lead, que vem antes do disparo.
CREATE VIEW backfill.aparicoes AS
  SELECT 'contacts'::text AS origem, c.id::text AS ref, c.phone_number AS bruto,
         coalesce(nullif(trim(c.name), ''), nullif(trim(c.call_name), '')) AS nome,
         nullif(trim(c.email), '') AS email, NULL::text AS cidade, NULL::jsonb AS variaveis,
         1 AS prioridade
    FROM legado.contacts c
  UNION ALL
  SELECT 'rescue_leads', r.id::text, r.phone_number, nullif(trim(r.name), ''), NULL,
         nullif(trim(r.city), ''), r.variables, 2
    FROM legado.rescue_leads r
  UNION ALL
  SELECT 'blast_leads', b.id::text, b.phone_number, nullif(trim(b.name), ''), NULL,
         nullif(trim(b.city), ''), b.variables, 3
    FROM legado.blast_leads b
  UNION ALL
  SELECT 'broadcast_recipients', x.id::text, x.phone_number, NULL, NULL, NULL, x.variables, 4
    FROM legado.broadcast_recipients x
  UNION ALL
  SELECT 'contact_blacklist', k.id::text, k.phone_number, NULL, NULL, NULL, NULL, 5
    FROM legado.contact_blacklist k;

-- Por que cada telefone deve ser suprimido, se deve. Três caminhos, todos
-- para o mesmo lado (D13.4): a blacklist, o contato bloqueado pelo operador,
-- e o lead que o mapa de status manda suprimir.
CREATE VIEW backfill.motivos_de_supressao AS
  SELECT k.phone_number AS bruto,
         'legado: lista de bloqueio' || coalesce(' (' || nullif(trim(k.reason), '') || ')', '') AS motivo
    FROM legado.contact_blacklist k
  UNION ALL
  SELECT c.phone_number,
         'legado: contato bloqueado' || coalesce(' (' || nullif(trim(c.blocked_reason), '') || ')', '')
    FROM legado.contacts c WHERE c.is_blocked
  UNION ALL
  SELECT r.phone_number, 'legado: ' || r.status || ' em resgate'
    FROM legado.rescue_leads r
   WHERE r.status = 'blacklisted'
  UNION ALL
  SELECT b.phone_number, 'legado: ' || b.status || ' em disparo'
    FROM legado.blast_leads b
   WHERE b.status = 'blacklisted'
      OR (b.status = 'discarded'
          AND coalesce(b.source_metadata ->> 'discarded_reason', 'opt_out') = 'opt_out');

-- A pessoa: um telefone válido, o melhor nome, e o e-mail quando ele é dela
-- só. E-mail que aparece em dois telefones diferentes não é ligado a nenhum
-- dos dois — fundir é decisão de operação (D32) —, e a prévia conta quantos.
CREATE VIEW backfill.pessoas AS
  WITH ap AS (
    SELECT a.*, t.valor_norm, t.celular
      FROM backfill.aparicoes a JOIN legado.telefones t ON t.bruto = a.bruto
     WHERE t.valido
  ),
  email_de AS (
    SELECT ap.valor_norm, e.valor_norm AS email
      FROM ap JOIN legado.emails e ON e.bruto = ap.email AND e.valido
  ),
  email_unico AS (
    SELECT email FROM email_de GROUP BY email HAVING count(DISTINCT valor_norm) = 1
  )
  SELECT ap.valor_norm,
         bool_or(ap.celular) AS celular,
         (array_agg(ap.nome ORDER BY ap.prioridade, ap.ref) FILTER (WHERE ap.nome IS NOT NULL))[1] AS nome,
         (SELECT min(d.email) FROM email_de d JOIN email_unico u ON u.email = d.email
           WHERE d.valor_norm = ap.valor_norm) AS email,
         (array_agg(ap.cidade ORDER BY ap.prioridade, ap.ref) FILTER (WHERE ap.cidade IS NOT NULL))[1] AS cidade,
         (array_agg(ap.variaveis ORDER BY ap.prioridade, ap.ref)
            FILTER (WHERE jsonb_typeof(ap.variaveis) = 'object'))[1] AS variaveis,
         array_agg(DISTINCT ap.origem || ':' || ap.ref) AS refs,
         (SELECT string_agg(DISTINCT m.motivo, '; ')
            FROM backfill.motivos_de_supressao m JOIN legado.telefones t2 ON t2.bruto = m.bruto
           WHERE t2.valor_norm = ap.valor_norm) AS suprimir_por
    FROM ap
   GROUP BY ap.valor_norm;

-- O que cada pessoa vira em `ingerir_contato`.
CREATE FUNCTION backfill.identidades(p_valor_norm text, p_celular boolean, p_email text)
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT jsonb_build_array(jsonb_build_object('canal', 'whatsapp', 'valor', p_valor_norm, 'valor_norm', p_valor_norm))
      || CASE WHEN p_celular
              THEN jsonb_build_array(jsonb_build_object('canal', 'sms', 'valor', p_valor_norm, 'valor_norm', p_valor_norm))
              ELSE '[]'::jsonb END
      || CASE WHEN p_email IS NOT NULL
              THEN jsonb_build_array(jsonb_build_object('canal', 'email', 'valor', p_email, 'valor_norm', p_email))
              ELSE '[]'::jsonb END;
$$;

-- Variáveis que a cadência pode citar: só as de texto. Objeto e número
-- viram ruído em `{{chave}}` — mesmo cuidado do D48 com o texto da resposta.
CREATE FUNCTION backfill.metadados(p_cidade text, p_variaveis jsonb, p_refs text[])
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $$
  SELECT coalesce((SELECT jsonb_object_agg(k, v)
                     FROM jsonb_each(coalesce(p_variaveis, '{}'::jsonb)) AS e(k, v)
                    WHERE jsonb_typeof(v) = 'string' AND length(trim(v #>> '{}')) > 0), '{}'::jsonb)
      || CASE WHEN p_cidade IS NOT NULL THEN jsonb_build_object('cidade', p_cidade) ELSE '{}'::jsonb END
      || jsonb_build_object('legado', to_jsonb(p_refs));
$$;

-- ---------------------------------------------------------------------------
-- A prévia
-- ---------------------------------------------------------------------------

CREATE FUNCTION backfill.previa(p_tenant uuid)
RETURNS TABLE(ordem integer, item text, quantidade bigint, detalhe text)
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
DECLARE
  v_par record;
  v_mapa record;
BEGIN
  IF p_tenant IS NULL OR NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant) THEN
    RAISE EXCEPTION 'backfill sem tenant explícito, ou tenant inexistente'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Normalização incompleta: o TypeScript não rodou, ou rodou antes de o
  -- dado chegar. Contar pessoas sem ele seria contar só parte delas.
  RETURN QUERY SELECT 0, 'valores ainda não normalizados'::text, count(*)::bigint,
    'rode backfill/normalizar.ts antes; com isto acima de zero a prévia mente'::text
    FROM legado.brutos;

  RETURN QUERY SELECT 10, 'aparições de telefone no legado', count(*)::bigint,
    'contatos, leads, destinatários e bloqueios, somados' FROM backfill.aparicoes;

  RETURN QUERY SELECT 11, 'telefone que não é discável', count(DISTINCT a.bruto)::bigint,
    'fica de fora: não vira contato e não tem como receber'
    FROM backfill.aparicoes a JOIN legado.telefones t ON t.bruto = a.bruto WHERE NOT t.valido;

  RETURN QUERY SELECT 20, 'pessoas (uma por telefone normalizado)', count(*)::bigint,
    'WhatsApp para todas, porque o legado conversava por esse número' FROM backfill.pessoas;

  RETURN QUERY SELECT 21, 'pessoas com celular (ganham SMS)', count(*)::bigint, ''
    FROM backfill.pessoas WHERE celular;

  -- O caso que a regra do celular esconde: número de WhatsApp antigo, salvo
  -- sem o nono dígito. Pela regra de `telefone.ts` ele é fixo — então entra
  -- como WhatsApp (o legado afirma) e NÃO ganha SMS. Mudar isso é mudar a
  -- normalização, que é decisão, não detalhe do backfill.
  RETURN QUERY SELECT 22, 'com cara de celular sem o nono dígito', count(*)::bigint,
    '55 + DDD + 8 dígitos começando em 6-9: entram só como WhatsApp'
    FROM backfill.pessoas
   WHERE length(valor_norm) = 12 AND valor_norm LIKE '55%' AND substr(valor_norm, 5, 1) IN ('6','7','8','9');

  RETURN QUERY SELECT 23, 'a mesma pessoa duas vezes, com e sem o nono dígito?', count(*)::bigint,
    'viram duas pessoas; juntar é decisão de operação (D32)'
    FROM backfill.pessoas p
   WHERE length(p.valor_norm) = 12 AND p.valor_norm LIKE '55%'
     AND EXISTS (SELECT 1 FROM backfill.pessoas q
                  WHERE q.valor_norm = substr(p.valor_norm, 1, 4) || '9' || substr(p.valor_norm, 5));

  RETURN QUERY SELECT 30, 'e-mails ligados', count(*)::bigint, '' FROM backfill.pessoas WHERE email IS NOT NULL;

  RETURN QUERY SELECT 31, 'e-mail em mais de uma pessoa', count(*)::bigint,
    'não é ligado a nenhuma delas: fundir pessoas é decisão de operação'
    FROM (SELECT e.valor_norm
            FROM backfill.aparicoes a JOIN legado.telefones t ON t.bruto = a.bruto AND t.valido
            JOIN legado.emails e ON e.bruto = a.email AND e.valido
           GROUP BY e.valor_norm HAVING count(DISTINCT t.valor_norm) > 1) x;

  RETURN QUERY SELECT 32, 'e-mail que não é e-mail', count(*)::bigint, 'fica de fora'
    FROM legado.emails WHERE NOT valido;

  RETURN QUERY SELECT 40, 'pessoas que já existem neste cliente', count(*)::bigint,
    'serão atualizadas, não duplicadas: o nome do legado substitui o atual quando vem preenchido (a regra de ingerir_contato), e os metadados mesclam'
    FROM backfill.pessoas p
   WHERE EXISTS (SELECT 1 FROM contact_identities ci
                  WHERE ci.tenant_id = p_tenant AND ci.canal = 'whatsapp' AND ci.valor_norm = p.valor_norm);

  RETURN QUERY SELECT 50, 'pessoas a suprimir', count(*)::bigint,
    'todas as que o legado bloqueou, por qualquer caminho, e em todos os canais (D13.4)'
    FROM backfill.pessoas WHERE suprimir_por IS NOT NULL;

  RETURN QUERY SELECT 51, 'já suprimidas neste cliente', count(*)::bigint, ''
    FROM backfill.pessoas p
    JOIN contact_identities ci ON ci.tenant_id = p_tenant AND ci.canal = 'whatsapp' AND ci.valor_norm = p.valor_norm
   WHERE p.suprimir_por IS NOT NULL AND esta_suprimido(p_tenant, ci.contact_id, NULL, NULL);

  RETURN QUERY SELECT 52, 'bloqueados sem telefone discável', count(DISTINCT m.bruto)::bigint,
    'não há como suprimir pelo número — e também não há como mandar para ele'
    FROM backfill.motivos_de_supressao m JOIN legado.telefones t ON t.bruto = m.bruto WHERE NOT t.valido;

  -- O mapa de status, linha por linha do que existe. Status sem mapeamento
  -- aparece aqui com a palavra no item, em vez de derrubar a prévia: a prévia
  -- existe para dizer o que vai dar errado, e `gravar` é que se recusa.
  FOR v_par IN
    SELECT 'rescue_leads' AS origem, status, NULL::jsonb AS meta, count(*) AS n FROM legado.rescue_leads GROUP BY status
    UNION ALL
    SELECT 'blast_leads', status, jsonb_build_object('discarded_reason', source_metadata ->> 'discarded_reason'), count(*)
      FROM legado.blast_leads GROUP BY status, source_metadata ->> 'discarded_reason'
    UNION ALL
    SELECT 'broadcast_recipients', status, NULL, count(*) FROM legado.broadcast_recipients GROUP BY status
    ORDER BY 1, 2
  LOOP
    BEGIN
      SELECT * INTO v_mapa FROM mapear_status_legado(v_par.origem, v_par.status, coalesce(v_par.meta, '{}'::jsonb));
      ordem := 60; item := v_par.origem || ' ' || v_par.status
        || coalesce(' (' || (v_par.meta ->> 'discarded_reason') || ')', '');
      quantidade := v_par.n;
      detalhe := v_mapa.status::text || coalesce(' / ' || v_mapa.motivo::text, '')
        || CASE WHEN v_mapa.suprimir THEN ' / suprime' ELSE '' END
        || CASE WHEN v_mapa.reinscrever <> 'nenhuma' THEN ' / reinscrever: ' || v_mapa.reinscrever::text ELSE '' END;
      RETURN NEXT;
    EXCEPTION WHEN restrict_violation THEN
      ordem := 61; item := 'SEM MAPEAMENTO: ' || v_par.origem || ' ' || v_par.status;
      quantidade := v_par.n; detalhe := 'gravar se recusa enquanto isto existir';
      RETURN NEXT;
    END;
  END LOOP;

  -- O que fica para decisão: quem o legado ainda estava cadenciando.
  RETURN QUERY SELECT 70, 'leads em curso no resgate: ' || coalesce(c.name, r.campaign_id::text), count(*)::bigint,
    'não são inscritos por aqui: cada campanha antiga precisa de uma cadência escolhida'
    FROM legado.rescue_leads r LEFT JOIN legado.rescue_campaigns c ON c.id = r.campaign_id
   WHERE r.status IN ('pending','in_progress','sent','paused','waiting_cycle','reengaging')
   GROUP BY coalesce(c.name, r.campaign_id::text);

  RETURN QUERY SELECT 71, 'leads em curso no disparo: ' || coalesce(c.name, b.campaign_id::text), count(*)::bigint,
    'idem'
    FROM legado.blast_leads b LEFT JOIN legado.blast_campaigns c ON c.id = b.campaign_id
   WHERE b.status IN ('pending','processing')
   GROUP BY coalesce(c.name, b.campaign_id::text);
END;
$$;

-- ---------------------------------------------------------------------------
-- A gravação
-- ---------------------------------------------------------------------------

CREATE TABLE backfill.recusas (
  valor_norm text NOT NULL,
  motivo     text NOT NULL,
  em         timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION backfill.gravar(p_tenant uuid)
RETURNS TABLE(ordem integer, item text, quantidade bigint, detalhe text)
LANGUAGE plpgsql
SET search_path TO 'public', 'privado'
AS $$
DECLARE
  pe         record;
  v_contato  uuid;
  v_criados  bigint := 0;
  v_atual    bigint := 0;
  v_recusas  bigint := 0;
  v_supr     bigint := 0;
  v_supr_id  bigint := 0;
  v_outbox   bigint := 0;
  v_falta    bigint;
  v_sem_mapa text;
BEGIN
  IF p_tenant IS NULL OR NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant) THEN
    RAISE EXCEPTION 'backfill sem tenant explícito, ou tenant inexistente'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT count(*) INTO v_falta FROM legado.brutos;
  IF v_falta > 0 THEN
    RAISE EXCEPTION '% valor(es) ainda não normalizado(s)', v_falta
      USING ERRCODE = 'object_not_in_prerequisite_state',
            HINT = 'rode backfill/normalizar.ts antes de gravar';
  END IF;

  -- Status sem mapeamento para tudo (D13): inventar estado é como a
  -- comparação da Fase 3 passa a medir contra uma base errada.
  SELECT string_agg(DISTINCT x.item, ', ') INTO v_sem_mapa
    FROM backfill.previa(p_tenant) x WHERE x.ordem = 61;
  IF v_sem_mapa IS NOT NULL THEN
    RAISE EXCEPTION 'status legado sem mapeamento: %', v_sem_mapa
      USING ERRCODE = 'restrict_violation';
  END IF;

  DELETE FROM backfill.recusas;

  FOR pe IN SELECT * FROM backfill.pessoas ORDER BY valor_norm LOOP
    BEGIN
      SELECT i.contact_id INTO v_contato
        FROM ingerir_contato(p_tenant, 'legado', backfill.identidades(pe.valor_norm, pe.celular, pe.email),
                             pe.nome, pe.valor_norm, backfill.metadados(pe.cidade, pe.variaveis, pe.refs)) i;
    EXCEPTION WHEN restrict_violation THEN
      -- As identidades desta pessoa já são de contatos diferentes neste
      -- cliente. Não se funde: a pessoa fica de fora, dita.
      INSERT INTO backfill.recusas (valor_norm, motivo) VALUES (pe.valor_norm, SQLERRM);
      v_contato := NULL;
    END;

    IF pe.suprimir_por IS NOT NULL THEN
      IF v_contato IS NOT NULL THEN
        INSERT INTO suppression (tenant_id, contact_id, motivo)
        SELECT p_tenant, v_contato, left(pe.suprimir_por, 500)
         WHERE NOT esta_suprimido(p_tenant, v_contato, NULL, NULL)
        ON CONFLICT DO NOTHING;
      ELSE
        -- Não virou contato, mas o pedido de sair continua valendo: suprime o
        -- endereço, nos dois canais do telefone. A invariante 2 não pode
        -- depender de a ingestão ter dado certo.
        INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
        SELECT p_tenant, c.canal, pe.valor_norm, left(pe.suprimir_por, 500)
          FROM (VALUES ('whatsapp'::canal), ('sms'::canal)) c(canal)
        ON CONFLICT DO NOTHING;
      END IF;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_recusas FROM backfill.recusas;

  SELECT count(*) FILTER (WHERE c.criado_em = now()),
         count(*) FILTER (WHERE c.criado_em <> now())
    INTO v_criados, v_atual
    FROM backfill.pessoas p
    JOIN contact_identities ci ON ci.tenant_id = p_tenant AND ci.canal = 'whatsapp' AND ci.valor_norm = p.valor_norm
    JOIN contacts c ON c.tenant_id = p_tenant AND c.id = ci.contact_id
   WHERE NOT EXISTS (SELECT 1 FROM backfill.recusas r WHERE r.valor_norm = p.valor_norm);

  SELECT count(*) INTO v_supr FROM suppression
   WHERE tenant_id = p_tenant AND criado_em = now() AND contact_id IS NOT NULL;
  SELECT count(*) INTO v_supr_id FROM suppression
   WHERE tenant_id = p_tenant AND criado_em = now() AND contact_id IS NULL;

  -- O gatilho do D45 enfileira `opt_out` para cada supressão nova. Estas são
  -- decisões que o legado já tinha tomado e que o CRM, se soube, soube por
  -- ele; e nenhum destes contatos tem card ligado, então o dreno só os tiraria
  -- da fila dizendo "sem card". Saem daqui — contadas, não caladas.
  WITH apagados AS (
    DELETE FROM outbox
     WHERE tenant_id = p_tenant AND fato = 'opt_out' AND status = 'pendente' AND criado_em = now()
    RETURNING 1
  ) SELECT count(*) INTO v_outbox FROM apagados;

  ordem := 100; item := 'contatos criados'; quantidade := v_criados; detalhe := ''; RETURN NEXT;
  ordem := 101; item := 'contatos que já existiam, atualizados'; quantidade := v_atual; detalhe := ''; RETURN NEXT;
  ordem := 102; item := 'pessoas recusadas (identidades já de contatos diferentes)'; quantidade := v_recusas;
    detalhe := 'listadas em backfill.recusas; se bloqueadas no legado, suprimidas pelo endereço'; RETURN NEXT;
  ordem := 103; item := 'supressões novas, por pessoa'; quantidade := v_supr; detalhe := 'todos os canais'; RETURN NEXT;
  ordem := 104; item := 'supressões novas, por endereço'; quantidade := v_supr_id;
    detalhe := 'de quem não virou contato'; RETURN NEXT;
  ordem := 105; item := 'fatos de opt-out não reenviados ao CRM'; quantidade := v_outbox;
    detalhe := 'decisões do legado, sem card para receber'; RETURN NEXT;
END;
$$;

-- O que o MAPA-STATUS manda conferir depois, na parte que esta etapa cobre.
-- Nenhuma linha pode voltar.
CREATE FUNCTION backfill.conferir(p_tenant uuid)
RETURNS TABLE(problema text, valor text)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  -- 1. Ninguém que o legado bloqueou ficou alcançável por telefone.
  SELECT 'bloqueado no legado e não suprimido aqui', t.valor_norm
    FROM backfill.motivos_de_supressao m
    JOIN legado.telefones t ON t.bruto = m.bruto AND t.valido
   WHERE NOT esta_suprimido(p_tenant,
           (SELECT ci.contact_id FROM contact_identities ci
             WHERE ci.tenant_id = p_tenant AND ci.canal = 'whatsapp' AND ci.valor_norm = t.valor_norm),
           'whatsapp', t.valor_norm)
  UNION ALL
  -- 2. Nenhuma pessoa do legado ficou sem contato, salvo as recusadas.
  SELECT 'pessoa do legado sem contato e sem recusa', p.valor_norm
    FROM backfill.pessoas p
   WHERE NOT EXISTS (SELECT 1 FROM contact_identities ci
                      WHERE ci.tenant_id = p_tenant AND ci.canal = 'whatsapp' AND ci.valor_norm = p.valor_norm)
     AND NOT EXISTS (SELECT 1 FROM backfill.recusas r WHERE r.valor_norm = p.valor_norm);
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA backfill FROM PUBLIC;
