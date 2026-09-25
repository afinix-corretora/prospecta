-- Testes do mapa de status legado (backfill/mapa_status.sql).
--
-- Cobre os 27 valores dos três vocabulários antigos. Um valor sem asserção é
-- um valor que o backfill pode errar em silêncio.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA m;

CREATE TABLE m.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);

-- Confere o mapeamento completo de um valor legado.
CREATE FUNCTION m.esperado(
  p_origem text, p_status text,
  p_status_novo text, p_motivo text, p_suprimir boolean, p_reinscrever text,
  p_metadata jsonb DEFAULT '{}'::jsonb
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record; v_nome text; v_ok boolean;
BEGIN
  v_nome := p_origem || '.' || p_status
         || CASE WHEN p_metadata <> '{}'::jsonb THEN ' ' || p_metadata::text ELSE '' END;
  SELECT * INTO r FROM mapear_status_legado(p_origem, p_status, p_metadata);
  v_ok := r.status::text = p_status_novo
      AND coalesce(r.motivo::text,'-') = coalesce(p_motivo,'-')
      AND r.suprimir = p_suprimir
      AND r.reinscrever::text = p_reinscrever;
  INSERT INTO m.resultado (nome, ok, detalhe) VALUES (
    v_nome, v_ok,
    CASE WHEN v_ok THEN '' ELSE format('veio (%s, %s, suprimir=%s, %s), esperava (%s, %s, suprimir=%s, %s)',
      r.status, coalesce(r.motivo::text,'-'), r.suprimir, r.reinscrever,
      p_status_novo, coalesce(p_motivo,'-'), p_suprimir, p_reinscrever) END);
EXCEPTION WHEN others THEN
  INSERT INTO m.resultado (nome, ok, detalhe) VALUES (v_nome, false, 'erro: ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- rescue_leads — 14 valores
-- ---------------------------------------------------------------------------

SELECT m.esperado('rescue_leads','pending',      'ativo',    NULL,                   false,'nenhuma');
SELECT m.esperado('rescue_leads','in_progress',  'ativo',    NULL,                   false,'nenhuma');
SELECT m.esperado('rescue_leads','sent',         'ativo',    NULL,                   false,'nenhuma');
SELECT m.esperado('rescue_leads','paused',       'pausado',  NULL,                   false,'nenhuma');
SELECT m.esperado('rescue_leads','engaged',      'encerrado','resposta',             false,'nenhuma');
SELECT m.esperado('rescue_leads','responded',    'encerrado','resposta',             false,'nenhuma');
SELECT m.esperado('rescue_leads','reengaging',   'encerrado','resposta',             false,'reengajamento');
SELECT m.esperado('rescue_leads','waiting_cycle','encerrado','fim_dos_passos',       false,'mesma_campanha');
SELECT m.esperado('rescue_leads','qualified',    'encerrado','mudanca_etapa_crm',    false,'nenhuma');
SELECT m.esperado('rescue_leads','disqualified', 'encerrado','mudanca_etapa_crm',    false,'nenhuma');
SELECT m.esperado('rescue_leads','completed',    'encerrado','fim_dos_passos',       false,'nenhuma');
SELECT m.esperado('rescue_leads','blacklisted',  'encerrado','supressao',            true, 'nenhuma');
SELECT m.esperado('rescue_leads','failed',       'encerrado','falha_permanente',     false,'nenhuma');
SELECT m.esperado('rescue_leads','cancelled',    'encerrado','cancelado_operacional',false,'nenhuma');

-- ---------------------------------------------------------------------------
-- blast_leads — 8 valores
-- ---------------------------------------------------------------------------

SELECT m.esperado('blast_leads','pending',    'ativo',    NULL,                   false,'nenhuma');
SELECT m.esperado('blast_leads','processing', 'ativo',    NULL,                   false,'nenhuma');
SELECT m.esperado('blast_leads','sent',       'encerrado','fim_dos_passos',       false,'nenhuma');
SELECT m.esperado('blast_leads','positive',   'encerrado','mudanca_etapa_crm',    false,'nenhuma');
SELECT m.esperado('blast_leads','blacklisted','encerrado','supressao',            true, 'nenhuma');
SELECT m.esperado('blast_leads','failed',     'encerrado','falha_permanente',     false,'nenhuma');
SELECT m.esperado('blast_leads','cancelled',  'encerrado','cancelado_operacional',false,'nenhuma');

-- O valor sobrecarregado: três variantes, três destinos.
SELECT m.esperado('blast_leads','discarded','encerrado','supressao',true,'nenhuma',
                  '{"discarded_reason":"opt_out"}'::jsonb);
SELECT m.esperado('blast_leads','discarded','encerrado','cancelado_operacional',false,'nenhuma',
                  '{"discarded_reason":"manual"}'::jsonb);
SELECT m.esperado('blast_leads','discarded','encerrado','supressao',true,'nenhuma');

-- ---------------------------------------------------------------------------
-- broadcast_recipients — 5 valores
-- ---------------------------------------------------------------------------

SELECT m.esperado('broadcast_recipients','pending',   'ativo',    NULL,             false,'nenhuma');
SELECT m.esperado('broadcast_recipients','processing','ativo',    NULL,             false,'nenhuma');
SELECT m.esperado('broadcast_recipients','sent',      'encerrado','fim_dos_passos', false,'nenhuma');
SELECT m.esperado('broadcast_recipients','completed', 'encerrado','fim_dos_passos', false,'nenhuma');
SELECT m.esperado('broadcast_recipients','failed',    'encerrado','falha_permanente',false,'nenhuma');

-- ---------------------------------------------------------------------------
-- Propriedades do mapa
-- ---------------------------------------------------------------------------

-- 'sent' significa coisas opostas conforme a origem. É a razão de a função
-- receber a origem em vez de olhar só o status.
DO $$
DECLARE v_rescue text; v_blast text;
BEGIN
  SELECT status::text INTO v_rescue FROM mapear_status_legado('rescue_leads','sent');
  SELECT status::text INTO v_blast  FROM mapear_status_legado('blast_leads','sent');
  INSERT INTO m.resultado (nome, ok, detalhe) VALUES (
    'propriedade: sent depende da origem (rescue=ativo, blast=encerrado)',
    v_rescue = 'ativo' AND v_blast = 'encerrado',
    format('rescue=%s blast=%s', v_rescue, v_blast));
END;
$$;

-- Status desconhecido para o backfill em vez de inventar estado.
DO $$
BEGIN
  PERFORM * FROM mapear_status_legado('rescue_leads','status_que_nao_existe');
  INSERT INTO m.resultado (nome, ok, detalhe)
  VALUES ('propriedade: status desconhecido derruba o backfill', false, 'foi aceito');
EXCEPTION WHEN others THEN
  INSERT INTO m.resultado (nome, ok, detalhe)
  VALUES ('propriedade: status desconhecido derruba o backfill', true, '');
END;
$$;

-- Mesmo status, origem errada, também para.
DO $$
BEGIN
  PERFORM * FROM mapear_status_legado('blast_leads','waiting_cycle');
  INSERT INTO m.resultado (nome, ok, detalhe)
  VALUES ('propriedade: status válido em outra origem não passa', false, 'foi aceito');
EXCEPTION WHEN others THEN
  INSERT INTO m.resultado (nome, ok, detalhe)
  VALUES ('propriedade: status válido em outra origem não passa', true, '');
END;
$$;

-- Todo encerramento tem motivo; nenhum ativo ou pausado tem.
DO $$
DECLARE v_incoerentes integer;
BEGIN
  SELECT count(*) INTO v_incoerentes FROM (
    SELECT (mapear_status_legado(o, s)).* FROM (VALUES
      ('rescue_leads','pending'),('rescue_leads','in_progress'),('rescue_leads','sent'),
      ('rescue_leads','paused'),('rescue_leads','engaged'),('rescue_leads','responded'),
      ('rescue_leads','reengaging'),('rescue_leads','waiting_cycle'),('rescue_leads','qualified'),
      ('rescue_leads','disqualified'),('rescue_leads','completed'),('rescue_leads','blacklisted'),
      ('rescue_leads','failed'),('rescue_leads','cancelled'),
      ('blast_leads','pending'),('blast_leads','processing'),('blast_leads','sent'),
      ('blast_leads','positive'),('blast_leads','blacklisted'),('blast_leads','failed'),
      ('blast_leads','cancelled'),('blast_leads','discarded'),
      ('broadcast_recipients','pending'),('broadcast_recipients','processing'),
      ('broadcast_recipients','sent'),('broadcast_recipients','completed'),
      ('broadcast_recipients','failed')
    ) AS v(o,s)
  ) x WHERE (x.status = 'encerrado') <> (x.motivo IS NOT NULL);

  INSERT INTO m.resultado (nome, ok, detalhe) VALUES (
    'propriedade: encerrado tem motivo, ativo e pausado não',
    v_incoerentes = 0, format('%s incoerente(s)', v_incoerentes));
END;
$$;

-- Supressão só é pedida onde há registro de que a pessoa saiu.
DO $$
DECLARE v_inesperados integer;
BEGIN
  SELECT count(*) INTO v_inesperados FROM (
    SELECT s AS legado, (mapear_status_legado(o, s)).* FROM (VALUES
      ('rescue_leads','pending'),('rescue_leads','in_progress'),('rescue_leads','sent'),
      ('rescue_leads','paused'),('rescue_leads','engaged'),('rescue_leads','responded'),
      ('rescue_leads','reengaging'),('rescue_leads','waiting_cycle'),('rescue_leads','qualified'),
      ('rescue_leads','disqualified'),('rescue_leads','completed'),
      ('rescue_leads','failed'),('rescue_leads','cancelled'),
      ('blast_leads','pending'),('blast_leads','processing'),('blast_leads','sent'),
      ('blast_leads','positive'),('blast_leads','failed'),('blast_leads','cancelled'),
      ('broadcast_recipients','pending'),('broadcast_recipients','sent')
    ) AS v(o,s)
  ) x WHERE x.suprimir;

  INSERT INTO m.resultado (nome, ok, detalhe) VALUES (
    'propriedade: só blacklisted e discarded pedem supressão',
    v_inesperados = 0, format('%s status suprimiu sem motivo', v_inesperados));
END;
$$;

-- ---------------------------------------------------------------------------
-- Relatório
-- ---------------------------------------------------------------------------

\echo ''
\echo '============= MAPA DE STATUS ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM m.resultado ORDER BY id;

\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
FROM m.resultado;

DO $$
DECLARE v_falhas integer;
BEGIN
  SELECT count(*) INTO v_falhas FROM m.resultado WHERE NOT ok;
  IF v_falhas > 0 THEN
    RAISE EXCEPTION '% asserção(ões) do mapa de status falharam', v_falhas;
  END IF;
END;
$$;
