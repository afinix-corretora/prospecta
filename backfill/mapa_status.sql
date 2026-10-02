-- Mapa executável de status legado → modelo novo.
--
-- Ferramenta de backfill, não schema de runtime: carregada durante a migração
-- de dados e descartada depois. Vive fora de supabase/migrations/ por isso.
--
-- A regra que justifica a função existir: o mesmo valor significa coisas
-- diferentes conforme a origem. `sent` em rescue_leads é cadência em curso;
-- `sent` em blast_leads é cadência terminada, porque blast é disparo único.
-- Um CASE espalhado pelo script de backfill erraria isso em silêncio.
--
-- Decisões que este mapa materializa: D13 em DECISOES.md. Detalhe e
-- justificativa em MAPA-STATUS.md.

CREATE TYPE acao_reinscricao AS ENUM ('nenhuma', 'mesma_campanha', 'reengajamento');

CREATE FUNCTION mapear_status_legado(
  p_origem   text,
  p_status   text,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  status      status_enrollment,
  motivo      motivo_encerramento,
  suprimir    boolean,
  reinscrever acao_reinscricao
)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_motivo_descarte text := p_metadata ->> 'discarded_reason';
BEGIN
  -- Ativos e pausados: nenhum encerramento, nenhum efeito colateral.
  IF (p_origem = 'rescue_leads'  AND p_status IN ('pending','in_progress','sent'))
  OR (p_origem = 'blast_leads'   AND p_status IN ('pending','processing'))
  OR (p_origem = 'broadcast_recipients' AND p_status IN ('pending','processing'))
  THEN
    RETURN QUERY SELECT 'ativo'::status_enrollment, NULL::motivo_encerramento,
                        false, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  IF p_origem = 'rescue_leads' AND p_status = 'paused' THEN
    RETURN QUERY SELECT 'pausado'::status_enrollment, NULL::motivo_encerramento,
                        false, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  -- Respondeu. 'responded' é vocabulário morto no CHECK (nenhuma function
  -- escreve), mapeado por segurança caso exista linha antiga.
  IF p_origem = 'rescue_leads' AND p_status IN ('engaged','responded') THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment, 'resposta'::motivo_encerramento,
                        false, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  -- D13.1: camada 2 do resgate vira enrollment novo em campanha própria.
  -- O lead está em reengaging porque respondeu e esfriou — o enrollment
  -- original encerra por resposta, e o reengajamento é outra inscrição.
  IF p_origem = 'rescue_leads' AND p_status = 'reengaging' THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment, 'resposta'::motivo_encerramento,
                        false, 'reengajamento'::acao_reinscricao;
    RETURN;
  END IF;

  -- D13.2: ciclo vira encerramento + reinscrição, para preservar o histórico
  -- de cada passada e respeitar o índice único de enrollment ativo por campanha.
  IF p_origem = 'rescue_leads' AND p_status = 'waiting_cycle' THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment, 'fim_dos_passos'::motivo_encerramento,
                        false, 'mesma_campanha'::acao_reinscricao;
    RETURN;
  END IF;

  -- Despachado ao CRM: o CRM já sabe, não gerar outbox no backfill.
  IF (p_origem = 'rescue_leads' AND p_status IN ('qualified','disqualified'))
  OR (p_origem = 'blast_leads'  AND p_status = 'positive')
  THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment, 'mudanca_etapa_crm'::motivo_encerramento,
                        false, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  -- Cadência terminada. Em blast, 'sent' já é o fim: disparo único.
  IF (p_origem = 'rescue_leads' AND p_status = 'completed')
  OR (p_origem = 'blast_leads'  AND p_status = 'sent')
  OR (p_origem = 'broadcast_recipients' AND p_status IN ('sent','completed'))
  THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment, 'fim_dos_passos'::motivo_encerramento,
                        false, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  -- Supressão. D13.4: suprime a pessoa, todos os canais.
  IF p_status = 'blacklisted' THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment, 'supressao'::motivo_encerramento,
                        true, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  -- `discarded` é o valor sobrecarregado: opt-out detectado e descarte manual
  -- gravam o mesmo status. Só o metadado separa os dois.
  IF p_origem = 'blast_leads' AND p_status = 'discarded' THEN
    IF v_motivo_descarte = 'opt_out' OR v_motivo_descarte IS NULL THEN
      -- Sem metadado vai para o lado seguro (D13.4): suprimir alguém
      -- descartado por engano custa um lead; remessagear quem pediu para sair
      -- custa reclamação e remetente queimado.
      RETURN QUERY SELECT 'encerrado'::status_enrollment, 'supressao'::motivo_encerramento,
                          true, 'nenhuma'::acao_reinscricao;
    ELSE
      RETURN QUERY SELECT 'encerrado'::status_enrollment,
                          'cancelado_operacional'::motivo_encerramento,
                          false, 'nenhuma'::acao_reinscricao;
    END IF;
    RETURN;
  END IF;

  -- D13.3: decisão humana não é falha do motor.
  IF p_status = 'cancelled' THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment,
                        'cancelado_operacional'::motivo_encerramento,
                        false, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  IF p_status = 'failed' THEN
    RETURN QUERY SELECT 'encerrado'::status_enrollment, 'falha_permanente'::motivo_encerramento,
                        false, 'nenhuma'::acao_reinscricao;
    RETURN;
  END IF;

  -- Sem mapeamento conhecido o backfill para. Inventar estado aqui é como o
  -- shadow mode da Fase 3 passa a comparar contra uma baseline errada.
  RAISE EXCEPTION 'status legado sem mapeamento: origem=% status=%', p_origem, p_status
    USING ERRCODE = 'restrict_violation';
END;
$$;
