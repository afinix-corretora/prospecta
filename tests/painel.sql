-- Painel da campanha (D36).
--
-- O que este arquivo sustenta: os números da tela são os do motor. Um painel
-- que conta diferente do banco é pior do que nenhum painel — a pessoa decide
-- com base nele.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA pn;
CREATE TABLE pn.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION pn.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO pn.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t    '00000000-0000-0000-0000-0000000000aa'
\set camp 'ee000000-0000-0000-0000-000000000001'
\set outra 'ee000000-0000-0000-0000-00000000000f'
\set fv   'ee000000-0000-0000-0000-000000000003'

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES (:'camp', 'Resgate', 'morna', 'opt-in', '{whatsapp}'),
       (:'outra', 'Outra campanha', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('ee000000-0000-0000-0000-000000000002', 'Resgate');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES (:'fv', 'ee000000-0000-0000-0000-000000000002', 1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:'fv', 1, 'whatsapp', 0, 'oi {{nome}}'), (:'fv', 2, 'whatsapp', 24, 'e aí');

INSERT INTO sender_accounts
  (id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, config)
VALUES ('ee000000-0000-0000-0000-0000000000a1','whatsapp','+55 11 99000-0001','Comercial',
        'gupshup','morna',200,'{"app_name":"a","source":"5511990000001"}'::jsonb);

-- Quatro pessoas, e a quarta é de outra campanha de propósito: o resumo tem
-- que ser da campanha pedida, não do tenant inteiro.
DO $$
DECLARE v uuid; i int;
BEGIN
  FOR i IN 1..4 LOOP
    SELECT contact_id INTO v FROM ingerir_contato(
      '00000000-0000-0000-0000-0000000000aa', 'planilha',
      format('[{"canal":"whatsapp","valor":"1599000000%s","valor_norm":"551599000000%s"}]', i, i)::jsonb,
      'Pessoa ' || i);
    IF i < 4 THEN
      PERFORM inscrever(v, 'ee000000-0000-0000-0000-000000000001',
                        'ee000000-0000-0000-0000-000000000003', now() - interval '1 minute');
    ELSE
      PERFORM inscrever(v, 'ee000000-0000-0000-0000-00000000000f',
                        'ee000000-0000-0000-0000-000000000003', now() - interval '1 minute');
    END IF;
  END LOOP;
END;
$$;

SELECT pn.confere('sem passada nenhuma: 3 ativos, 0 mensagens, 3 vencidos',
  (SELECT inscritos_ativos FROM resumo_da_campanha(:'t', :'camp')) = 3
  AND (SELECT mensagens FROM resumo_da_campanha(:'t', :'camp')) = 0
  AND (SELECT vencidos_agora FROM resumo_da_campanha(:'t', :'camp')) = 3,
  (SELECT inscritos_ativos || '/' || mensagens || '/' || vencidos_agora
     FROM resumo_da_campanha(:'t', :'camp')));

-- Shadow mode: o motor roda completo e não envia. É o número que precisa
-- aparecer na tela, senão o modo que de-risca o projeto parece estar quebrado.
SELECT count(*) FROM processar_vencidos(100, 'simulado');

SELECT pn.confere('shadow mode aparece: 3 mensagens, todas simuladas',
  (SELECT mensagens FROM resumo_da_campanha(:'t', :'camp')) = 3
  AND (SELECT por_status ->> 'simulado' FROM resumo_da_campanha(:'t', :'camp')) = '3',
  (SELECT mensagens || ' ' || por_status::text FROM resumo_da_campanha(:'t', :'camp')));

SELECT pn.confere('a campanha vizinha não entra na conta',
  (SELECT mensagens FROM resumo_da_campanha(:'t', :'outra')) = 1
  AND (SELECT inscritos_ativos FROM resumo_da_campanha(:'t', :'outra')) = 1,
  (SELECT inscritos_ativos || '/' || mensagens FROM resumo_da_campanha(:'t', :'outra')));

SELECT pn.confere('depois da passada o próximo disparo é no futuro',
  (SELECT proximo_disparo FROM resumo_da_campanha(:'t', :'camp')) > now()
  AND (SELECT vencidos_agora FROM resumo_da_campanha(:'t', :'camp')) = 0);

-- ---------------------------------------------------------------------------
-- Resposta e clique vêm do evento, não de coluna
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_msg uuid; v_outra uuid;
BEGIN
  SELECT m.id INTO v_msg FROM messages m
    JOIN enrollments e ON e.id = m.enrollment_id
   WHERE e.campaign_id = 'ee000000-0000-0000-0000-000000000001'
   ORDER BY m.criado_em LIMIT 1;

  SELECT m.id INTO v_outra FROM messages m
    JOIN enrollments e ON e.id = m.enrollment_id
   WHERE e.campaign_id = 'ee000000-0000-0000-0000-000000000001' AND m.id <> v_msg
   ORDER BY m.criado_em LIMIT 1;

  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em)
  VALUES ('00000000-0000-0000-0000-0000000000aa', v_msg,   'entregue',   now() - interval '3 min'),
         ('00000000-0000-0000-0000-0000000000aa', v_outra, 'clique',     now() - interval '2 min'),
         ('00000000-0000-0000-0000-0000000000aa', v_msg,   'respondido', now() - interval '1 min');
END;
$$;

SELECT pn.confere('resposta contada pelo evento, e encerra o enrollment (inv. 4)',
  (SELECT respostas FROM resumo_da_campanha(:'t', :'camp')) = 1
  AND (SELECT encerrados FROM resumo_da_campanha(:'t', :'camp')) = 1
  AND (SELECT por_motivo ->> 'resposta' FROM resumo_da_campanha(:'t', :'camp')) = '1',
  (SELECT respostas || ' / ' || encerrados || ' / ' || por_motivo::text
     FROM resumo_da_campanha(:'t', :'camp')));

-- D7: clique é engajamento. Aparece no painel e NÃO encerra.
SELECT pn.confere('clique conta como clique e não vira encerramento (D7)',
  (SELECT cliques FROM resumo_da_campanha(:'t', :'camp')) = 1
  AND (SELECT por_motivo ? 'clique' FROM resumo_da_campanha(:'t', :'camp')) IS NOT TRUE,
  (SELECT cliques || ' / ' || por_motivo::text FROM resumo_da_campanha(:'t', :'camp')));

SELECT pn.confere('ativos caíram para 2 depois do encerramento',
  (SELECT inscritos_ativos FROM resumo_da_campanha(:'t', :'camp')) = 2);

-- ---------------------------------------------------------------------------
-- A linha do tempo
-- ---------------------------------------------------------------------------

SELECT pn.confere('a linha do tempo tem os três eventos, mais novo primeiro',
  (SELECT count(*) FROM eventos_da_campanha(:'t', :'camp')) = 3
  AND (SELECT tipo FROM eventos_da_campanha(:'t', :'camp') LIMIT 1) = 'respondido',
  (SELECT count(*)::text FROM eventos_da_campanha(:'t', :'camp')));

SELECT pn.confere('a linha do tempo diz quem, por onde e para qual endereço',
  (SELECT contato FROM eventos_da_campanha(:'t', :'camp') LIMIT 1) LIKE 'Pessoa%'
  AND (SELECT canal FROM eventos_da_campanha(:'t', :'camp') LIMIT 1) = 'whatsapp'
  AND (SELECT destino FROM eventos_da_campanha(:'t', :'camp') LIMIT 1) LIKE '15990000%');

-- Em shadow mode o motor escolhe e RESERVA remetente normalmente — só não
-- envia. Quem diz que nada saiu de casa é o status da mensagem, e foi este
-- teste que corrigiu a suposição contrária.
SELECT pn.confere('shadow mode aparece no status, com remetente reservado',
  (SELECT status FROM eventos_da_campanha(:'t', :'camp') LIMIT 1) = 'simulado'
  AND (SELECT remetente FROM eventos_da_campanha(:'t', :'camp') LIMIT 1) = 'Comercial',
  (SELECT status || ' / ' || remetente FROM eventos_da_campanha(:'t', :'camp') LIMIT 1));

SELECT pn.confere('a linha do tempo não vaza evento da campanha vizinha',
  NOT EXISTS (
    SELECT 1 FROM eventos_da_campanha(:'t', :'outra')));

SELECT pn.confere('o limite pedido é respeitado',
  (SELECT count(*) FROM eventos_da_campanha(:'t', :'camp', 2)) = 2,
  (SELECT count(*)::text FROM eventos_da_campanha(:'t', :'camp', 2)));

-- O teto só é testável com mais linhas do que ele. Com três eventos a
-- asserção passava com e sem `least(..., 500)` — que é teto de enfeite, o
-- mesmo formato do `tem_adapter` do D31. Então: 600 eventos de verdade.
DO $$
DECLARE v_msg uuid;
BEGIN
  SELECT m.id INTO v_msg FROM messages m
    JOIN enrollments e ON e.id = m.enrollment_id
   WHERE e.campaign_id = 'ee000000-0000-0000-0000-000000000001'
   ORDER BY m.criado_em LIMIT 1;

  -- 'entregue' de propósito: 'respondido' encerraria enrollment e mexeria nas
  -- contagens que as asserções acima já fixaram.
  INSERT INTO message_events (tenant_id, message_id, tipo, ocorrido_em)
  SELECT '00000000-0000-0000-0000-0000000000aa', v_msg, 'entregue',
         now() - (i * interval '1 second')
    FROM generate_series(1, 600) i;
END;
$$;

SELECT pn.confere('o teto de 500 existe de verdade, não só no texto',
  (SELECT count(*) FROM eventos_da_campanha(:'t', :'camp', 100000)) = 500,
  (SELECT count(*)::text FROM eventos_da_campanha(:'t', :'camp', 100000)));

-- ---------------------------------------------------------------------------
-- Superfície
-- ---------------------------------------------------------------------------

SELECT pn.confere('anon não chama o painel',
  NOT has_function_privilege('anon', 'resumo_da_campanha(uuid, uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'eventos_da_campanha(uuid, uuid, integer)', 'EXECUTE'));

SELECT pn.confere('authenticated chama o painel',
  has_function_privilege('authenticated', 'resumo_da_campanha(uuid, uuid)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'eventos_da_campanha(uuid, uuid, integer)', 'EXECUTE'));

SELECT pn.confere('as duas são STABLE',
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('resumo_da_campanha','eventos_da_campanha') AND provolatile = 's') = 2);

SELECT pn.confere('search_path fixo nas duas',
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('resumo_da_campanha','eventos_da_campanha')
      AND proconfig @> ARRAY['search_path=public, privado']) = 2);

\echo ''
\echo '============= PAINEL DA CAMPANHA ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM pn.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM pn.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pn.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'painel: % asserções falharam',
      (SELECT count(*) FROM pn.resultado WHERE NOT ok);
  END IF;
END;
$$;
