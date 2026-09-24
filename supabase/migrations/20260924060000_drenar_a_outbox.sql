-- O dreno da outbox: a metade que o D45 deixou faltando (D46).
--
-- O D45 fez os três fatos nascerem. Ninguém os consumia: as linhas entravam
-- `pendente` e ficavam. `tentativas`, `proxima_tentativa_em` e `ultimo_erro`
-- existem desde a primeira migration e **nenhum SQL as escrevia** — é a mesma
-- forma do `tem_adapter` do D31, coluna que parece garantia e é decoração.
--
-- Esta migration é o análogo exato do despacho de mensagens, de propósito:
--
--     messages   reivindicar_pendentes    registrar_resultado_envio
--     outbox     reivindicar_writebacks   registrar_resultado_writeback
--
-- Mesma forma, mesmo lease, mesma casa (`public` com EXECUTE só para
-- `service_role`, que é o que permite o worker chamar por PostgREST sem
-- expor nada ao cliente).
--
-- O que NÃO está aqui: falar com o CRM. O adapter do Pipefy depende do OAuth
-- de `_shared/pipefy.ts`, que mora no projeto legado. A divisão é a mesma do
-- agendador e dos `adapters/`: a decisão e a reivindicação são atômicas e
-- ficam no banco; o I/O é de quem tem a credencial.
--
-- Sem barra invertida (D32).

-- ---------------------------------------------------------------------------
-- Lease
-- ---------------------------------------------------------------------------

ALTER TABLE outbox ADD COLUMN reivindicada_em timestamptz;

COMMENT ON COLUMN outbox.reivindicada_em IS
  'Quando o dreno pegou a linha. Worker que morre no meio nao trava o fato:
   passado o lease, a linha volta ao lote (igual a messages.reivindicada_em).';

-- A linha reivindicada continua `pendente`, e isso importa: o indice unico do
-- D45 so vale para `pendente`, entao enquanto um `respondido` esta em voo
-- nenhum outro igual entra na fila. Reivindicar nao abre a porta que o D45
-- fechou.

-- ---------------------------------------------------------------------------
-- Reivindicar
-- ---------------------------------------------------------------------------

CREATE FUNCTION reivindicar_writebacks(
  p_limite integer  DEFAULT 50,
  p_lease  interval DEFAULT interval '5 minutes'
)
RETURNS TABLE (
  writeback_id uuid, tenant_id uuid, contact_id uuid, destino text,
  fato fato_writeback, payload jsonb, autoria text, tentativas integer
)
LANGUAGE plpgsql SET search_path = public, privado AS $$
BEGIN
  RETURN QUERY
  WITH lote AS (
    SELECT o.id
      FROM outbox o
     WHERE o.status = 'pendente'
       AND o.proxima_tentativa_em <= now()
       AND (o.reivindicada_em IS NULL OR o.reivindicada_em < now() - p_lease)
     ORDER BY o.proxima_tentativa_em
     LIMIT p_limite
     FOR UPDATE SKIP LOCKED
  ), pego AS (
    UPDATE outbox o SET reivindicada_em = now()
      FROM lote l WHERE o.id = l.id
     RETURNING o.*
  )
  SELECT p.id, p.tenant_id, p.contact_id, p.destino, p.fato, p.payload,
         p.autoria, p.tentativas
    FROM pego p;
END;
$$;

COMMENT ON FUNCTION reivindicar_writebacks IS
  'Lote do dreno da outbox. Decide e reivindica; nao escreve no CRM.
   Devolve tenant_id porque a credencial do CRM e por cliente, e `autoria`
   porque e ela que faz o webhook de volta descartar o proprio eco (D46).';

-- ---------------------------------------------------------------------------
-- Registrar o resultado
-- ---------------------------------------------------------------------------

-- Teto de tentativas. Oito, com espera dobrando ate seis horas, cobre mais de
-- um dia de CRM fora do ar sem martelar o provedor.
--
-- Desistir tem preco: o fato nunca chega ao CRM. Por isso desistir e VISIVEL
-- — `resumo_da_outbox` conta os falhados e `writebacks_falhados` diz quais e
-- por que. Desistir em silencio seria repetir o D45 uma camada acima.
CREATE FUNCTION registrar_resultado_writeback(
  p_writeback_id uuid,
  p_ok           boolean,
  p_erro         text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE
  v_tentativas integer;
  c_teto       constant integer := 8;
BEGIN
  SELECT o.tentativas INTO v_tentativas FROM outbox o WHERE o.id = p_writeback_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'writeback inexistente: %', p_writeback_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_ok THEN
    UPDATE outbox
       SET status = 'enviado', reivindicada_em = NULL, ultimo_erro = NULL
     WHERE id = p_writeback_id;
    RETURN;
  END IF;

  v_tentativas := v_tentativas + 1;

  IF v_tentativas >= c_teto THEN
    -- Sai de `pendente`, o que libera a trava do D45: o fato nao chegou ao
    -- CRM, entao uma ocorrencia nova da mesma pessoa tem direito de tentar
    -- de novo em vez de ser recusada por causa de uma linha morta.
    UPDATE outbox
       SET status = 'falha', tentativas = v_tentativas,
           reivindicada_em = NULL, ultimo_erro = coalesce(p_erro, '')
     WHERE id = p_writeback_id;
  ELSE
    UPDATE outbox
       SET tentativas = v_tentativas,
           reivindicada_em = NULL,
           ultimo_erro = coalesce(p_erro, ''),
           proxima_tentativa_em =
             now() + least(interval '6 hours', interval '1 minute' * (2 ^ v_tentativas))
     WHERE id = p_writeback_id;
  END IF;
END;
$$;

COMMENT ON FUNCTION registrar_resultado_writeback IS
  'Fecha uma linha do lote do dreno. Falha volta para `pendente` com espera
   dobrada; no oitavo tropeco vira `falha`, que e visivel e libera a trava de
   dedup do D45 — o fato nao chegou, entao um novo tem direito de tentar.';

-- ---------------------------------------------------------------------------
-- Ler: dreno parado nao pode parecer fila vazia
-- ---------------------------------------------------------------------------

-- A licao do D36 e do D44 aplicada aqui. "Zero writebacks saindo" tem duas
-- causas opostas — nada aconteceu, ou o dreno morreu — e sem o numero abaixo
-- as duas sao a mesma tela. `pendente_mais_antigo_em_horas` e o unico numero
-- que as separa: fila vazia nao tem mais antigo.
CREATE FUNCTION resumo_da_outbox()
RETURNS TABLE (
  pendentes bigint, enviados bigint, falhados bigint,
  vencidos_agora bigint, pendente_mais_antigo_em_horas numeric
)
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  SELECT count(*) FILTER (WHERE status = 'pendente'),
         count(*) FILTER (WHERE status = 'enviado'),
         count(*) FILTER (WHERE status = 'falha'),
         count(*) FILTER (WHERE status = 'pendente' AND proxima_tentativa_em <= now()),
         round(extract(epoch FROM
                 now() - min(criado_em) FILTER (WHERE status = 'pendente')
               ) / 3600.0, 1)
    FROM outbox;
$$;

COMMENT ON FUNCTION resumo_da_outbox IS
  'Estado do dreno para a tela. `pendente_mais_antigo_em_horas` e o numero que
   distingue dreno parado de fila vazia — sem ele as duas situacoes sao a
   mesma tela (D46, na linha do D36 e do D44).';

CREATE FUNCTION writebacks_falhados(p_limite integer DEFAULT 50)
RETURNS TABLE (
  writeback_id uuid, contact_id uuid, nome text, destino text,
  fato fato_writeback, tentativas integer, ultimo_erro text,
  criado_em timestamptz
)
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  SELECT o.id, o.contact_id, c.nome, o.destino, o.fato, o.tentativas,
         o.ultimo_erro, o.criado_em
    FROM outbox o
    LEFT JOIN contacts c ON c.id = o.contact_id AND c.tenant_id = o.tenant_id
   WHERE o.status = 'falha'
   ORDER BY o.criado_em DESC
   LIMIT p_limite;
$$;

COMMENT ON FUNCTION writebacks_falhados IS
  'Os fatos que desistiram de chegar ao CRM, com o erro e de quem sao. Existe
   para que desistir nao seja silencioso (D46).';

-- ---------------------------------------------------------------------------
-- Superficie (D19)
-- ---------------------------------------------------------------------------

-- As duas do worker: `service_role` so, igual ao despacho de mensagens.
--
-- As duas de leitura: `authenticated` so, e NAO service_role — de proposito.
-- Nenhuma das duas recebe tenant na assinatura; quem recorta e o RLS da
-- outbox, e o RLS nao alcanca `service_role`. Com os dois papeis a mesma
-- chamada devolveria coisas diferentes conforme quem chama: para a tela, o
-- cliente; para o worker, todos os clientes somados. Uma funcao com duas
-- semanticas e exatamente a anti-regra do tenant implicito, e o jeito de
-- fechar isso sem inventar parametro e deixar um unico papel possivel —
-- aquele que o RLS alcanca. O worker nao precisa ler: ele dreno, nao mostra.
DO $$
DECLARE papel text; alvo text;
BEGIN
  -- Worker: reivindicar e fechar.
  FOREACH alvo IN ARRAY ARRAY[
    'public.reivindicar_writebacks(integer, interval)',
    'public.registrar_resultado_writeback(uuid, boolean, text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', alvo);
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;

  -- Tela: so quem o RLS recorta.
  FOREACH alvo IN ARRAY ARRAY[
    'public.resumo_da_outbox()',
    'public.writebacks_falhados(integer)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', alvo);
    -- O banco de teste nao tem `service_role`; o projeto tem. Revogar so
    -- onde o papel existe.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role', alvo);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', alvo);
    END IF;
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO postgres', alvo);
  END LOOP;
END;
$$;
