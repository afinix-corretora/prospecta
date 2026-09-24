-- O dreno da outbox (D46).
--
-- O D45 fez os fatos nascerem e este arquivo cobra que eles SAIAM. As
-- asserções que mais importam são três, e nenhuma é "o feliz funciona":
--
--   1. reivindicar não pode abrir a porta que o D45 fechou — a linha em voo
--      continua `pendente`, e a trava de dedup tem de continuar valendo;
--   2. desistir não pode ser silencioso, nem prender a trava para sempre;
--   3. dreno parado não pode parecer fila vazia.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA dr;
CREATE TABLE dr.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION dr.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO dr.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

INSERT INTO contacts (id, nome, origem) VALUES
  ('d0000000-0000-0000-0000-000000000001','Ana Dreno','planilha'),
  ('d0000000-0000-0000-0000-000000000002','Bruno Dreno','planilha');

-- ===========================================================================
-- 1. Reivindicar, e o que reivindicar NÃO pode soltar
-- ===========================================================================

DO $$
DECLARE v_id uuid; v_n integer; v_status text; v_dup boolean;
BEGIN
  INSERT INTO outbox (contact_id, destino, fato, payload)
  VALUES ('d0000000-0000-0000-0000-000000000001','crm','respondido','{"a":1}')
  RETURNING id INTO v_id;

  SELECT count(*) INTO v_n FROM reivindicar_writebacks(50) r WHERE r.writeback_id = v_id;
  PERFORM dr.confere('o fato pendente entra no lote do dreno', v_n = 1, v_n::text);

  -- Dentro do lease, ninguém pega de novo: dois workers não escrevem o mesmo
  -- fato duas vezes no CRM.
  SELECT count(*) INTO v_n FROM reivindicar_writebacks(50) r WHERE r.writeback_id = v_id;
  PERFORM dr.confere('dentro do lease o mesmo fato não sai duas vezes', v_n = 0, v_n::text);

  -- A asserção do D45 atravessada pelo D46: em voo, a linha continua
  -- `pendente`, e é isso que mantém a trava de dedup de pé. Se reivindicar
  -- tivesse mudado o status, este INSERT passaria.
  SELECT status::text INTO v_status FROM outbox WHERE id = v_id;
  PERFORM dr.confere('a linha em voo continua pendente', v_status = 'pendente', v_status);

  BEGIN
    INSERT INTO outbox (contact_id, destino, fato)
    VALUES ('d0000000-0000-0000-0000-000000000001','crm','respondido');
    v_dup := true;
  EXCEPTION WHEN unique_violation THEN v_dup := false;
  END;
  PERFORM dr.confere('com o fato em voo, um igual ainda é recusado (trava do D45)',
    NOT v_dup);

  -- Entregue: o fato sai da fila.
  PERFORM registrar_resultado_writeback(v_id, true, NULL);
  SELECT status::text INTO v_status FROM outbox WHERE id = v_id;
  PERFORM dr.confere('entregue vira enviado', v_status = 'enviado', v_status);
  PERFORM dr.confere('e larga o lease',
    (SELECT reivindicada_em IS NULL FROM outbox WHERE id = v_id));

  -- ...e aí um fato novo da mesma pessoa tem direito de existir. Quem
  -- respondeu hoje pode responder de novo daqui a um mês.
  BEGIN
    INSERT INTO outbox (contact_id, destino, fato)
    VALUES ('d0000000-0000-0000-0000-000000000001','crm','respondido');
    v_dup := true;
  EXCEPTION WHEN unique_violation THEN v_dup := false;
  END;
  PERFORM dr.confere('entregue o anterior, o fato pode acontecer de novo', v_dup);
END;
$$;

-- ===========================================================================
-- 2. Falhar, esperar mais a cada vez, e desistir de forma visível
-- ===========================================================================

DO $$
DECLARE
  v_id uuid; v_t integer; v_status text; v_erro text;
  v_espera1 interval; v_espera2 interval; v_n integer;
BEGIN
  INSERT INTO outbox (contact_id, destino, fato)
  VALUES ('d0000000-0000-0000-0000-000000000002','crm','campanha_concluida')
  RETURNING id INTO v_id;

  PERFORM registrar_resultado_writeback(v_id, false, 'CRM fora do ar');

  SELECT tentativas, status::text, ultimo_erro, proxima_tentativa_em - now()
    INTO v_t, v_status, v_erro, v_espera1
    FROM outbox WHERE id = v_id;

  PERFORM dr.confere('falha conta a tentativa', v_t = 1, v_t::text);
  PERFORM dr.confere('e não desiste na primeira', v_status = 'pendente', v_status);
  PERFORM dr.confere('e guarda o erro', v_erro = 'CRM fora do ar', coalesce(v_erro,'(nulo)'));
  PERFORM dr.confere('e larga o lease para o próximo lote',
    (SELECT reivindicada_em IS NULL FROM outbox WHERE id = v_id));

  -- Antes da hora, não volta ao lote. Sem o filtro de `proxima_tentativa_em`
  -- o dreno marteleria o CRM caído num laço apertado.
  SELECT count(*) INTO v_n FROM reivindicar_writebacks(50) r WHERE r.writeback_id = v_id;
  PERFORM dr.confere('antes da hora marcada não volta ao lote', v_n = 0, v_n::text);

  PERFORM registrar_resultado_writeback(v_id, false, 'de novo');
  SELECT proxima_tentativa_em - now() INTO v_espera2 FROM outbox WHERE id = v_id;
  PERFORM dr.confere('a espera cresce a cada tropeço', v_espera2 > v_espera1,
    v_espera1::text || ' -> ' || v_espera2::text);

  -- Até o teto. Duas já foram; faltam seis para as oito.
  FOR i IN 3..8 LOOP
    PERFORM registrar_resultado_writeback(v_id, false, 'tentativa ' || i);
  END LOOP;

  SELECT status::text, tentativas INTO v_status, v_t FROM outbox WHERE id = v_id;
  PERFORM dr.confere('no teto de tentativas, desiste', v_status = 'falha', v_status);
  PERFORM dr.confere('e o contador mostra quantas foram', v_t = 8, v_t::text);

  -- Desistir não é silencioso: a tela consegue listar o que não chegou.
  SELECT count(*) INTO v_n FROM writebacks_falhados(50) f
   WHERE f.writeback_id = v_id AND f.ultimo_erro = 'tentativa 8' AND f.nome = 'Bruno Dreno';
  PERFORM dr.confere('o fato que desistiu aparece na lista, com erro e dono',
    v_n = 1, v_n::text);

  -- E desistir também não prende a trava do D45 para sempre: o fato NÃO
  -- chegou ao CRM, então uma ocorrência nova tem direito de tentar.
  INSERT INTO outbox (contact_id, destino, fato)
  VALUES ('d0000000-0000-0000-0000-000000000002','crm','opt_out');
  PERFORM registrar_resultado_writeback(
    (SELECT id FROM outbox
      WHERE contact_id = 'd0000000-0000-0000-0000-000000000002'
        AND fato = 'opt_out' AND status = 'pendente'), false, 'x');
END;
$$;

-- ===========================================================================
-- 3. Worker que morre no meio não tranca o fato
-- ===========================================================================

DO $$
DECLARE v_id uuid; v_n integer;
BEGIN
  INSERT INTO outbox (contact_id, destino, fato)
  VALUES ('d0000000-0000-0000-0000-000000000001','crm','identidade_invalida')
  RETURNING id INTO v_id;

  PERFORM reivindicar_writebacks(50);

  SELECT count(*) INTO v_n FROM reivindicar_writebacks(50) r WHERE r.writeback_id = v_id;
  PERFORM dr.confere('worker vivo: o fato segue reservado', v_n = 0, v_n::text);

  -- O worker morreu sem responder. Passado o lease, a linha volta.
  UPDATE outbox SET reivindicada_em = now() - interval '30 minutes' WHERE id = v_id;

  SELECT count(*) INTO v_n FROM reivindicar_writebacks(50) r WHERE r.writeback_id = v_id;
  PERFORM dr.confere('worker morto: passado o lease, o fato volta ao lote',
    v_n = 1, v_n::text);
END;
$$;

-- ===========================================================================
-- 4. Resultado de writeback inexistente falha alto
-- ===========================================================================

DO $$
DECLARE v_estourou boolean := false;
BEGIN
  BEGIN
    PERFORM registrar_resultado_writeback(
      'd0000000-0000-0000-0000-00000000dead'::uuid, true, NULL);
  EXCEPTION WHEN no_data_found THEN v_estourou := true;
  END;
  PERFORM dr.confere('resultado de writeback inexistente falha alto', v_estourou);
END;
$$;

-- ===========================================================================
-- 5. Dreno parado não pode parecer fila vazia
-- ===========================================================================

DO $$
DECLARE v_idade numeric; v_pend bigint; v_venc bigint; v_falh bigint;
BEGIN
  -- Primeiro: fila realmente vazia. Fecha tudo que sobrou pendente.
  UPDATE outbox SET status = 'enviado' WHERE status = 'pendente';

  SELECT pendentes, pendente_mais_antigo_em_horas INTO v_pend, v_idade
    FROM resumo_da_outbox();
  PERFORM dr.confere('fila vazia: nenhum pendente', v_pend = 0, v_pend::text);
  PERFORM dr.confere('fila vazia: não existe "mais antigo"', v_idade IS NULL,
    coalesce(v_idade::text,'(nulo)'));

  -- Agora a situação que a tela precisa distinguir: um fato parado há horas.
  -- Sem este número, isto e o caso de cima são a mesma tela.
  INSERT INTO outbox (contact_id, destino, fato)
  VALUES ('d0000000-0000-0000-0000-000000000001','crm','respondido');
  UPDATE outbox SET criado_em = now() - interval '9 hours'
   WHERE contact_id = 'd0000000-0000-0000-0000-000000000001'
     AND fato = 'respondido' AND status = 'pendente';

  SELECT pendentes, vencidos_agora, falhados, pendente_mais_antigo_em_horas
    INTO v_pend, v_venc, v_falh, v_idade FROM resumo_da_outbox();

  PERFORM dr.confere('dreno parado: o pendente aparece', v_pend = 1, v_pend::text);
  PERFORM dr.confere('dreno parado: e está vencido agora', v_venc = 1, v_venc::text);
  PERFORM dr.confere('dreno parado: a idade do mais antigo denuncia a parada',
    v_idade >= 8.9 AND v_idade <= 9.1, coalesce(v_idade::text,'(nulo)'));
  PERFORM dr.confere('o que desistiu continua contado à parte',
    v_falh >= 1, v_falh::text);
END;
$$;

-- ===========================================================================
-- 6. O recorte por tenant das duas de leitura, cobrado no schema
-- ===========================================================================

-- Nenhuma das duas recebe tenant na assinatura: quem recorta é o RLS da
-- outbox. Isso só vale enquanto forem SECURITY INVOKER e só `authenticated`
-- puder chamá-las. Trocar para DEFINER desligaria o RLS em silêncio, e um
-- GRANT para `service_role` daria à mesma chamada uma segunda semântica —
-- todos os clientes somados. As duas asserções abaixo são derivadas do
-- catálogo, não de uma lista escrita à mão.
DO $$
DECLARE v_def integer; v_sr integer;
BEGIN
  SELECT count(*) INTO v_def FROM pg_proc p
   WHERE p.proname IN ('resumo_da_outbox','writebacks_falhados') AND p.prosecdef;
  PERFORM dr.confere('as duas de leitura são SECURITY INVOKER, senão o RLS não recorta',
    v_def = 0, v_def::text || ' com SECURITY DEFINER');

  SELECT count(*) INTO v_sr FROM pg_proc p
   WHERE p.proname IN ('resumo_da_outbox','writebacks_falhados')
     AND array_to_string(p.proacl::text[], ' ') LIKE '%service_role=%';
  PERFORM dr.confere('e não são chamáveis pelo papel que o RLS não alcança',
    v_sr = 0, v_sr::text || ' com grant para service_role');

  -- E o contrário, para a asserção não passar por ausência: o worker PRECISA
  -- poder reivindicar. Se este grant sumir, o dreno para de existir em
  -- silêncio, que é o defeito que este arquivo inteiro persegue.
  SELECT count(*) INTO v_sr FROM pg_proc p
   WHERE p.proname IN ('reivindicar_writebacks','registrar_resultado_writeback')
     AND array_to_string(p.proacl::text[], ' ') LIKE '%service_role=%';
  PERFORM dr.confere('as duas do worker seguem chamáveis por service_role',
    v_sr = 2, v_sr::text || ' de 2');
END;
$$;

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM dr.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM dr.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM dr.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'dreno: % asserção(ões) falharam', n; END IF;
END;
$$;
