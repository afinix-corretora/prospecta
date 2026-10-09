-- A rampa de volume por chip (D75).
--
-- O que este arquivo sustenta: o teto de hoje é a rampa, não a quota, e ele
-- vale nos QUATRO lugares que comparam o contador — a reserva, o pool e os
-- dois adiamentos. Mexer num e esquecer o outro é o D37 e o D40 de novo.
--
-- A asserção que só a rampa consegue satisfazer é esta: o chip é recusado
-- ENQUANTO `enviados_na_janela < quota_diaria`. Sem rampa, nada no motor
-- recusa nessa situação — então nenhuma destas passa por acaso.
--
-- E a que mais importa para o produto: shadow mode NÃO aquece chip. Em
-- `simulado` o motor escolhe e reserva remetente igual (D36), mas nada sai, e
-- a rampa anda em dia de envio REAL.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA rp;
CREATE TABLE rp.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION rp.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO rp.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t '00000000-0000-0000-0000-0000000000aa'
\set R 'cc000000-0000-0000-0000-0000000000c1'
\set S 'cc000000-0000-0000-0000-0000000000c2'
\set camp 'cc000000-0000-0000-0000-000000000c01'
\set flow 'cc000000-0000-0000-0000-000000000f01'
\set fv   'cc000000-0000-0000-0000-000000000f02'

-- R é o chip em rampa: quota 100, mas cinco dias para chegar lá, começando em
-- 4. S é o controle, do outro pool, sem rampa nenhuma.
INSERT INTO sender_accounts
  (id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria,
   health_score, config, rampa_dias, rampa_inicial)
VALUES (:'R','whatsapp','+5511900000901','Chip em rampa','gupshup','fria',100,100,
        '{"app_name":"r","source":"901"}'::jsonb, 5, 4),
       (:'S','whatsapp','+5511900000902','Chip maduro','gupshup','morna',100,100,
        '{"app_name":"s","source":"902"}'::jsonb, NULL, NULL);

-- ---------------------------------------------------------------------------
-- 1. A conta do teto
-- ---------------------------------------------------------------------------

SELECT rp.confere('dia 1 da rampa é o teto inicial',
  privado.teto_da_rampa(100, 5, 4, 1) = 4,
  privado.teto_da_rampa(100, 5, 4, 1)::text);

SELECT rp.confere('o meio da rampa fica entre o inicial e a quota',
  privado.teto_da_rampa(100, 5, 4, 3) = 52,
  privado.teto_da_rampa(100, 5, 4, 3)::text);

SELECT rp.confere('o último dia da rampa é a quota cheia',
  privado.teto_da_rampa(100, 5, 4, 5) = 100);

SELECT rp.confere('passado o fim da rampa, continua a quota cheia',
  privado.teto_da_rampa(100, 5, 4, 99) = 100);

SELECT rp.confere('sem rampa, o teto é a quota — o comportamento de sempre',
  privado.teto_da_rampa(100, NULL, NULL, 1) = 100);

SELECT rp.confere('inicial acima da quota não vira teto acima da quota',
  privado.teto_da_rampa(10, 5, 50, 1) = 10,
  privado.teto_da_rampa(10, 5, 50, 1)::text);

SELECT rp.confere('o teto nunca é zero: chip em rampa manda pelo menos um',
  (SELECT bool_and(privado.teto_da_rampa(1, 30, 1, d) >= 1)
     FROM generate_series(1, 30) d));

SELECT rp.confere('a rampa nunca é decrescente',
  (SELECT bool_and(privado.teto_da_rampa(300, 14, 5, d)
                <= privado.teto_da_rampa(300, 14, 5, d + 1))
     FROM generate_series(1, 20) d));

-- ---------------------------------------------------------------------------
-- 2. A reserva recusa ANTES da quota
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_ok boolean; v_contador integer := 0;
BEGIN
  FOR i IN 1..4 LOOP
    v_ok := privado.reservar_envio('cc000000-0000-0000-0000-0000000000c1');
    IF v_ok THEN v_contador := v_contador + 1; END IF;
  END LOOP;
  PERFORM rp.confere('as quatro vagas do dia 1 são dadas', v_contador = 4, v_contador::text);
END;
$$;

DO $$
DECLARE v_ok boolean;
BEGIN
  v_ok := privado.reservar_envio('cc000000-0000-0000-0000-0000000000c1');
  PERFORM rp.confere('a quinta vaga é recusada pelo teto da rampa', NOT v_ok);
END;
$$;

-- A asserção que prova que foi a rampa: o contador está LONGE da quota.
SELECT rp.confere('a recusa aconteceu com o contador longe da quota (4 de 100)',
  (SELECT enviados_na_janela = 4 AND quota_diaria = 100 FROM sender_accounts WHERE id = :'R'),
  (SELECT enviados_na_janela || ' de ' || quota_diaria FROM sender_accounts WHERE id = :'R'));

-- ---------------------------------------------------------------------------
-- 3. O pool para de oferecer no teto, não na quota
-- ---------------------------------------------------------------------------

SELECT rp.confere('o pool não oferece mais o chip que bateu o teto de hoje',
  NOT EXISTS (SELECT 1 FROM privado.remetentes_disponiveis(:'t','whatsapp','fria') WHERE id = :'R'));

SELECT rp.confere('o chip sem rampa segue no pool dele, com o mesmo contador em zero',
  EXISTS (SELECT 1 FROM privado.remetentes_disponiveis(:'t','whatsapp','morna') WHERE id = :'S'));

-- O mesmo chip, o mesmo contador, a rampa desligada: volta ao pool. É isto que
-- separa "esgotou" de "esgotou a rampa".
UPDATE sender_accounts SET rampa_dias = NULL, rampa_inicial = NULL WHERE id = :'R';

SELECT rp.confere('desligar a rampa devolve o chip ao pool sem mexer no contador',
  EXISTS (SELECT 1 FROM privado.remetentes_disponiveis(:'t','whatsapp','fria') WHERE id = :'R')
  AND (SELECT enviados_na_janela FROM sender_accounts WHERE id = :'R') = 4);

UPDATE sender_accounts SET rampa_dias = 5, rampa_inicial = 4 WHERE id = :'R';

-- ---------------------------------------------------------------------------
-- 4. Os dois adiamentos mandam para amanhã, não para dentro de uma hora
-- ---------------------------------------------------------------------------

SELECT rp.confere('o adiamento do pool é amanhã quando o teto da rampa fechou',
  privado.proximo_horario_de_pool(:'t','whatsapp','fria') = (current_date + 1)::timestamptz,
  privado.proximo_horario_de_pool(:'t','whatsapp','fria')::text);

INSERT INTO campaigns (id, nome, tipo, base_legal, canais_habilitados)
VALUES (:'camp','Fria com rampa','fria','legitimo_interesse','{whatsapp}');

SELECT rp.confere('o adiamento da campanha é amanhã pelo mesmo motivo',
  privado.proximo_horario_da_campanha(:'t',:'camp','whatsapp') = (current_date + 1)::timestamptz,
  privado.proximo_horario_da_campanha(:'t',:'camp','whatsapp')::text);

-- ---------------------------------------------------------------------------
-- 5. A rampa anda em dia de ENVIO, não de calendário
-- ---------------------------------------------------------------------------

-- Janela de ontem, nenhum envio real: a rampa não anda. É o dia de shadow
-- mode, e é o dia do chip que ficou parado.
UPDATE sender_accounts
   SET janela = current_date - 1, enviados_na_janela = 3,
       enviados_reais_na_janela = 0, rampa_dia = 1
 WHERE id = :'R';
SELECT privado.reservar_envio(:'R');

SELECT rp.confere('janela sem envio real fecha sem fazer a rampa andar',
  (SELECT rampa_dia = 1 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'rampa_dia=' || rampa_dia FROM sender_accounts WHERE id = :'R'));

-- Janela de ontem com envio real: a rampa anda um dia.
UPDATE sender_accounts
   SET janela = current_date - 1, enviados_na_janela = 3,
       enviados_reais_na_janela = 3, rampa_dia = 1
 WHERE id = :'R';
SELECT privado.reservar_envio(:'R');

SELECT rp.confere('janela com envio real faz a rampa andar um dia',
  (SELECT rampa_dia = 2 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'rampa_dia=' || rampa_dia FROM sender_accounts WHERE id = :'R'));

SELECT rp.confere('a virada zera os dois contadores da janela',
  (SELECT enviados_na_janela = 1 AND enviados_reais_na_janela = 0
     FROM sender_accounts WHERE id = :'R'),
  (SELECT enviados_na_janela || '/' || enviados_reais_na_janela
     FROM sender_accounts WHERE id = :'R'));

SELECT rp.confere('e o teto de hoje subiu junto, de 4 para 28',
  (SELECT privado.teto_da_rampa(quota_diaria, rampa_dias, rampa_inicial, rampa_dia) = 28
     FROM sender_accounts WHERE id = :'R'));

-- Três dias parado é UM dia de envio fechado, não três.
UPDATE sender_accounts
   SET janela = current_date - 3, enviados_reais_na_janela = 2, rampa_dia = 2
 WHERE id = :'R';
SELECT privado.reservar_envio(:'R');

SELECT rp.confere('três dias de calendário parados contam como um dia de envio',
  (SELECT rampa_dia = 3 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'rampa_dia=' || rampa_dia FROM sender_accounts WHERE id = :'R'));

-- No fim da rampa ela para de andar.
UPDATE sender_accounts
   SET janela = current_date - 1, enviados_reais_na_janela = 9, rampa_dia = 5
 WHERE id = :'R';
SELECT privado.reservar_envio(:'R');

SELECT rp.confere('no último dia a rampa para de andar',
  (SELECT rampa_dia = 5 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'rampa_dia=' || rampa_dia FROM sender_accounts WHERE id = :'R'));

-- ---------------------------------------------------------------------------
-- 6. Shadow mode não aquece chip
-- ---------------------------------------------------------------------------

INSERT INTO flows (id, nome) VALUES (:'flow','Fria de um toque');
INSERT INTO flow_versions (id, flow_id, versao) VALUES (:'fv',:'flow',1);
INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
VALUES (:'fv',1,'whatsapp',0,'oi');

UPDATE sender_accounts
   SET janela = current_date, enviados_na_janela = 0,
       enviados_reais_na_janela = 0, rampa_dia = 3
 WHERE id = :'R';

DO $$
DECLARE v uuid;
BEGIN
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15991119001","valor_norm":"5515991119001"}]'::jsonb,'Sombra');
  PERFORM inscrever(v, 'cc000000-0000-0000-0000-000000000c01',
                    'cc000000-0000-0000-0000-000000000f02', now() - interval '1 minute');
END;
$$;

SELECT count(*) FROM processar_vencidos(10, 'simulado');

SELECT rp.confere('em simulado a mensagem nasce simulada e o remetente é reservado (D36)',
  (SELECT count(*) = 1 FROM messages WHERE sender_account_id = :'R' AND status = 'simulado')
  AND (SELECT enviados_na_janela = 1 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'reservados=' || enviados_na_janela FROM sender_accounts WHERE id = :'R'));

SELECT rp.confere('mas shadow mode NÃO conta como envio real, então não aquece',
  (SELECT enviados_reais_na_janela = 0 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'reais=' || enviados_reais_na_janela FROM sender_accounts WHERE id = :'R'));

-- A consequência, encenada: a janela vira depois de um dia inteiro de shadow
-- mode e a rampa continua onde estava.
UPDATE sender_accounts SET janela = current_date - 1 WHERE id = :'R';
SELECT privado.reservar_envio(:'R');

SELECT rp.confere('um dia inteiro de shadow mode não avança a rampa',
  (SELECT rampa_dia = 3 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'rampa_dia=' || rampa_dia FROM sender_accounts WHERE id = :'R'));

-- ---------------------------------------------------------------------------
-- 7. Envio que SAIU conta
-- ---------------------------------------------------------------------------

UPDATE sender_accounts
   SET janela = current_date, enviados_na_janela = 0, enviados_reais_na_janela = 0
 WHERE id = :'R';

DO $$
DECLARE v uuid; v_msg uuid;
BEGIN
  SELECT contact_id INTO v FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa','planilha',
    '[{"canal":"whatsapp","valor":"15991119002","valor_norm":"5515991119002"}]'::jsonb,'Real');
  PERFORM inscrever(v, 'cc000000-0000-0000-0000-000000000c01',
                    'cc000000-0000-0000-0000-000000000f02', now() - interval '1 minute');
  PERFORM count(*) FROM processar_vencidos(10, 'real');

  SELECT id INTO v_msg FROM messages
   WHERE sender_account_id = 'cc000000-0000-0000-0000-0000000000c1'
     AND status = 'pendente' LIMIT 1;
  PERFORM registrar_resultado_envio(v_msg, true, 'id-do-provedor');
END;
$$;

SELECT rp.confere('envio que saiu entra no contador de envio real',
  (SELECT enviados_reais_na_janela = 1 FROM sender_accounts WHERE id = :'R'),
  (SELECT 'reais=' || enviados_reais_na_janela FROM sender_accounts WHERE id = :'R'));

-- ---------------------------------------------------------------------------
-- 8. A grade: a tela configura a rampa, e não mexe no andamento dela
-- ---------------------------------------------------------------------------

SELECT rp.confere('a tela configura os dois parâmetros da rampa',
  has_column_privilege('authenticated','sender_accounts','rampa_dias','UPDATE')
  AND has_column_privilege('authenticated','sender_accounts','rampa_inicial','UPDATE'));

SELECT rp.confere('e NÃO mexe no andamento — zerar rampa_dia seria desfazer o aquecimento',
  NOT has_column_privilege('authenticated','sender_accounts','rampa_dia','UPDATE'));

SELECT rp.confere('nem no contador de envio real, que faria a rampa andar sem envio',
  NOT has_column_privilege('authenticated','sender_accounts','enviados_reais_na_janela','UPDATE'));

SELECT rp.confere('a grade das vizinhas continua estreita (o D59 de novo)',
  NOT has_column_privilege('authenticated','sender_accounts','enviados_na_janela','UPDATE')
  AND NOT has_table_privilege('authenticated','messages','UPDATE')
  AND NOT has_table_privilege('authenticated','deals','UPDATE'));

-- ---------------------------------------------------------------------------
-- 9. O que a tela lê é o MESMO cálculo do motor
-- ---------------------------------------------------------------------------

UPDATE sender_accounts
   SET janela = current_date, enviados_na_janela = 7,
       enviados_reais_na_janela = 5, rampa_dia = 3
 WHERE id = :'R';

SELECT rp.confere('rampa_dos_chips devolve o teto calculado pela função do motor',
  (SELECT r.teto_hoje = privado.teto_da_rampa(sa.quota_diaria, sa.rampa_dias, sa.rampa_inicial, sa.rampa_dia)
     FROM rampa_dos_chips(:'t') r JOIN sender_accounts sa ON sa.id = r.sender_id
    WHERE r.sender_id = :'R'));

SELECT rp.confere('e devolve o que foi reservado e o que saiu hoje',
  (SELECT enviados_hoje = 7 AND reais_hoje = 5 FROM rampa_dos_chips(:'t') WHERE sender_id = :'R'));

-- Janela de ontem: para a tela, hoje é zero — senão o painel mostraria o
-- consumo de ontem como se fosse de hoje, até alguém reservar.
UPDATE sender_accounts SET janela = current_date - 1 WHERE id = :'R';

SELECT rp.confere('janela velha aparece como zero, não como o consumo de ontem',
  (SELECT enviados_hoje = 0 AND reais_hoje = 0 FROM rampa_dos_chips(:'t') WHERE sender_id = :'R'));

SELECT rp.confere('o chip sem rampa aparece com o teto igual à quota',
  (SELECT teto_hoje = 100 AND rampa_dias IS NULL FROM rampa_dos_chips(:'t') WHERE sender_id = :'S'));

SELECT rp.confere('rampa_dos_chips é da pessoa logada, e fechada para anônimo',
  has_function_privilege('authenticated','rampa_dos_chips(uuid)','EXECUTE')
  AND NOT has_function_privilege('anon','rampa_dos_chips(uuid)','EXECUTE'));

-- ---------------------------------------------------------------------------
-- 10. A coerência que o schema cobra
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  UPDATE sender_accounts SET rampa_dias = 10, rampa_inicial = NULL WHERE id = 'cc000000-0000-0000-0000-0000000000c2';
  PERFORM rp.confere('meia rampa é recusada pelo schema', false, 'aceitou');
EXCEPTION WHEN check_violation THEN
  PERFORM rp.confere('meia rampa é recusada pelo schema', true);
END;
$$;

DO $$
BEGIN
  UPDATE sender_accounts SET rampa_dias = 0, rampa_inicial = 1 WHERE id = 'cc000000-0000-0000-0000-0000000000c2';
  PERFORM rp.confere('rampa de zero dia é recusada', false, 'aceitou');
EXCEPTION WHEN check_violation THEN
  PERFORM rp.confere('rampa de zero dia é recusada', true);
END;
$$;

\echo ''
\echo '============= RAMPA POR CHIP ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM rp.resultado ORDER BY id;
\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM rp.resultado;

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM rp.resultado WHERE NOT ok;
  IF v > 0 THEN RAISE EXCEPTION '% asserção(ões) da rampa falharam', v; END IF;
END;
$$;
