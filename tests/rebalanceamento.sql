-- Rebalanceamento dos pendentes (D37).
--
-- O que este arquivo sustenta: mensagem pendente cujo remetente adoeceu não é
-- entregue a ele. Ou ela muda de remetente, ou volta para a fila — nunca vai
-- para uma conta que o pool já recusa.
--
-- A asserção mais importante é a negativa: o despachante NÃO pode receber a
-- mensagem com o remetente morto. Era isso que acontecia.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA rb;
CREATE TABLE rb.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION rb.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO rb.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t '00000000-0000-0000-0000-0000000000aa'
\set camp 'ff000000-0000-0000-0000-000000000001'
\set fv   'ff000000-0000-0000-0000-000000000003'
\set A 'ff000000-0000-0000-0000-0000000000a1'
\set B 'ff000000-0000-0000-0000-0000000000a2'

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES (:'camp','Resgate','morna','opt-in','{whatsapp}');
INSERT INTO flows (id, nome) VALUES ('ff000000-0000-0000-0000-000000000002','F');
INSERT INTO flow_versions (id, flow_id, versao)
VALUES (:'fv','ff000000-0000-0000-0000-000000000002',1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:'fv',1,'whatsapp',0,'oi');

-- A com health maior para ser escolhida primeiro; B é a rede.
INSERT INTO sender_accounts
  (id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, health_score, config)
VALUES (:'A','whatsapp','+5511900000001','A','gupshup','morna',200,100,'{"app_name":"a","source":"1"}'::jsonb),
       (:'B','whatsapp','+5511900000002','B','gupshup','morna',200, 90,'{"app_name":"b","source":"2"}'::jsonb);

DO $$
DECLARE v uuid;
BEGIN
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15991110000","valor_norm":"5515991110000"}]'::jsonb,'Alvo');
  PERFORM inscrever(v, 'ff000000-0000-0000-0000-000000000001',
                    'ff000000-0000-0000-0000-000000000003', now() - interval '1 minute');
END;
$$;

SELECT count(*) FROM processar_vencidos(10, 'real');

SELECT rb.confere('o roteador escolheu A, a de maior health',
  (SELECT sender_account_id FROM messages LIMIT 1) = :'A'::uuid);

-- ---------------------------------------------------------------------------
-- A adoece com a mensagem já pendente
-- ---------------------------------------------------------------------------

DO $$
DECLARE i int;
BEGIN
  FOR i IN 1..5 LOOP
    PERFORM registrar_falha_remetente('ff000000-0000-0000-0000-0000000000a1');
  END LOOP;
END;
$$;

SELECT rb.confere('o circuito de A abriu e o pool passou a oferecer só B',
  (SELECT estado FROM sender_accounts WHERE id = :'A') = 'circuito_aberto'
  AND (SELECT count(*) FROM privado.remetentes_disponiveis(:'t','whatsapp','morna')) = 1
  AND (SELECT id FROM privado.remetentes_disponiveis(:'t','whatsapp','morna')) = :'B'::uuid);

CREATE TEMP TABLE lote AS SELECT * FROM reivindicar_pendentes(10);

-- A negativa: era exatamente isto que acontecia antes.
SELECT rb.confere('o despachante NÃO recebe a mensagem com o remetente morto',
  NOT EXISTS (SELECT 1 FROM lote WHERE sender_id = :'A'::uuid),
  (SELECT coalesce(string_agg(sender_id::text, ','), '(lote vazio)') FROM lote));

SELECT rb.confere('a mensagem foi entregue, mas com B',
  (SELECT count(*) FROM lote) = 1
  AND (SELECT sender_id FROM lote) = :'B'::uuid
  AND (SELECT sender_ident FROM lote) = '+5511900000002',
  (SELECT coalesce(sender_ident,'(nulo)') FROM lote));

SELECT rb.confere('o rebalanceamento foi gravado na mensagem, não só devolvido',
  (SELECT sender_account_id FROM messages LIMIT 1) = :'B'::uuid);

-- Invariante 3: a reserva migra junto, senão B pode passar da quota.
SELECT rb.confere('B pagou a reserva do envio que assumiu',
  (SELECT enviados_na_janela FROM sender_accounts WHERE id = :'B') = 1);

SELECT rb.confere('a reserva de A não foi devolvida (furaria a invariante 3)',
  (SELECT enviados_na_janela FROM sender_accounts WHERE id = :'A') = 1,
  (SELECT enviados_na_janela::text FROM sender_accounts WHERE id = :'A'));

-- ---------------------------------------------------------------------------
-- Sem para onde ir: volta para a fila, não vai para a conta morta
-- ---------------------------------------------------------------------------

DO $$
DECLARE v uuid; i int;
BEGIN
  -- Zera o lease para poder reivindicar de novo, e derruba B também.
  UPDATE messages SET reivindicada_em = NULL;
  FOR i IN 1..5 LOOP
    PERFORM registrar_falha_remetente('ff000000-0000-0000-0000-0000000000a2');
  END LOOP;
END;
$$;

CREATE TEMP TABLE lote2 AS SELECT * FROM reivindicar_pendentes(10);

SELECT rb.confere('pool vazio: nada é entregue',
  (SELECT count(*) FROM lote2) = 0,
  (SELECT count(*)::text FROM lote2));

SELECT rb.confere('e a mensagem volta para a fila, pronta para a próxima batida',
  (SELECT status FROM messages LIMIT 1) = 'pendente'
  AND (SELECT reivindicada_em FROM messages LIMIT 1) IS NULL);

-- ---------------------------------------------------------------------------
-- Circuito vencido volta sozinho
-- ---------------------------------------------------------------------------

-- Antes do D37 o circuito só se fechava dentro de `reservar_envio`, que só
-- roda para quem já foi escolhido — e o pool não escolhia conta de circuito
-- aberto. A conta ficava presa até alguém tentar usá-la, e ninguém tentava.
UPDATE sender_accounts SET circuito_aberto_ate = now() - interval '1 minute'
 WHERE id = :'B';

CREATE TEMP TABLE lote3 AS SELECT * FROM reivindicar_pendentes(10);

SELECT rb.confere('circuito vencido fecha na borda do lote',
  (SELECT estado FROM sender_accounts WHERE id = :'B') = 'ativo'
  AND (SELECT falhas_consecutivas FROM sender_accounts WHERE id = :'B') = 0,
  (SELECT estado::text FROM sender_accounts WHERE id = :'B'));

SELECT rb.confere('e a mensagem sai, por B recuperada',
  (SELECT count(*) FROM lote3) = 1 AND (SELECT sender_id FROM lote3) = :'B'::uuid,
  (SELECT count(*)::text FROM lote3));

-- ---------------------------------------------------------------------------
-- O caminho normal não mudou
-- ---------------------------------------------------------------------------

SELECT rb.confere('remetente saudável é entregue como está, sem reserva extra',
  (SELECT enviados_na_janela FROM sender_accounts WHERE id = :'B') = 1,
  (SELECT enviados_na_janela::text FROM sender_accounts WHERE id = :'B'));

DO $$
DECLARE v_lote int;
BEGIN
  UPDATE messages SET reivindicada_em = NULL;
  -- B vira um provedor sem adapter: o catálogo declara `smtp` assim (D30).
  UPDATE channel_provider_catalog SET tem_adapter = false WHERE slug = 'gupshup';
  SELECT count(*) INTO v_lote FROM reivindicar_pendentes(10);
  PERFORM rb.confere('nenhum provedor com adapter: nada entregue',
    v_lote = 0, v_lote::text);
  UPDATE channel_provider_catalog SET tem_adapter = true WHERE slug = 'gupshup';
END;
$$;

-- ---------------------------------------------------------------------------
-- Superfície
-- ---------------------------------------------------------------------------

SELECT rb.confere('reivindicar_pendentes não é chamável do navegador',
  NOT has_function_privilege('anon', 'reivindicar_pendentes(integer, interval)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'reivindicar_pendentes(integer, interval)', 'EXECUTE'));

SELECT rb.confere('search_path fixo',
  (SELECT proconfig FROM pg_proc WHERE proname = 'reivindicar_pendentes')
    @> ARRAY['search_path=public, privado']);

\echo ''
\echo '============= REBALANCEAMENTO ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM rb.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM rb.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM rb.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'rebalanceamento: % asserções falharam',
      (SELECT count(*) FROM rb.resultado WHERE NOT ok);
  END IF;
END;
$$;
