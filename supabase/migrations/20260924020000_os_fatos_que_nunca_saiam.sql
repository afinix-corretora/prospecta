-- Os três fatos do contrato que nunca eram produzidos (D45).
--
-- O `CLAUDE.md` desenha a última seta da arquitetura assim:
--
--     message_events ──▶ outbox ──▶ writeback CRM
--
-- e o D3 fixa o contrato em quatro fatos: `opt_out`, `identidade_invalida`,
-- `respondido`, `campanha_concluida`. Conferindo o que o motor de fato grava:
--
--     identidade_invalida   2 inserts, em registrar_resultado_envio
--     opt_out               nenhum — a palavra só existe na definição do enum
--     respondido            nenhum — o 'respondido' que aparece no código é
--                           `tipo_evento` em message_events, outro enum com a
--                           mesma palavra
--     campanha_concluida    nenhum — idem opt_out
--
-- Três dos quatro nunca nasciam. O estrago não é abstrato:
--
--   alguém pede para sair      entra em suppression, o CRM nunca fica sabendo,
--                              e o corretor liga para quem pediu para não ser
--                              incomodado
--   alguém responde            o enrollment encerra, o CRM continua mostrando
--                              lead frio — o mais quente da base fica parado
--   a campanha termina         o lead fica "em cadência" no CRM para sempre
--
-- É o formato do D31, do D37 e do D42: a garantia estava escrita e a
-- verificação não existia. Aqui nem o produtor existia.
--
-- Por gatilho, não por chamada. Os dois caminhos de encerramento são
-- diferentes — `encerrar_enrollment` para o agendador, e o gatilho de
-- `message_events` para a invariante 4 — e um gatilho em `enrollments` pega
-- os dois de uma vez. Pedir para cada chamador lembrar de gravar o fato é a
-- convenção que este projeto recusa em todo lugar.
--
-- Sem barra invertida (D32).

-- ---------------------------------------------------------------------------
-- Dedup do fato que é da PESSOA, não do enrollment
-- ---------------------------------------------------------------------------

-- Uma resposta encerra TODOS os enrollments do contato (invariante 4). Sem
-- isto, quem está em três campanhas gera três `respondido` idênticos, e o CRM
-- recebe a mesma escrita três vezes.
--
-- `campanha_concluida` fica de fora de propósito: esse fato é do par
-- (contato, campanha), e uma linha por enrollment é o certo.
--
-- O predicado inclui `status = 'pendente'`: depois de entregue, um fato novo
-- pode nascer — quem respondeu hoje pode responder de novo daqui a um mês, e
-- o CRM precisa saber das duas vezes.
CREATE UNIQUE INDEX outbox_fato_da_pessoa_uk
  ON outbox (tenant_id, contact_id, fato)
  WHERE fato IN ('respondido', 'opt_out') AND status = 'pendente';

-- ---------------------------------------------------------------------------
-- Encerramento -> respondido / campanha_concluida
-- ---------------------------------------------------------------------------

CREATE FUNCTION privado.writeback_do_encerramento() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_fato fato_writeback;
BEGIN
  -- Dois dos cinco motivos viram fato; os outros três não, e cada um por uma
  -- razão diferente:
  --
  --   supressao          quem conta ao CRM é o gatilho de `suppression`, que
  --                      sabe o motivo real. O enrollment encerrado é
  --                      consequência, não o fato.
  --   mudanca_etapa_crm  o CRM foi quem nos contou. Escrever de volta é o eco
  --                      que o D3 manda evitar.
  --   falha_permanente   não há fato para ele no contrato estreito, e alargar
  --                      o contrato é decisão, não detalhe de implementação.
  v_fato := CASE NEW.motivo_encerramento
              WHEN 'resposta'       THEN 'respondido'::fato_writeback
              WHEN 'fim_dos_passos' THEN 'campanha_concluida'::fato_writeback
            END;
  IF v_fato IS NULL THEN RETURN NEW; END IF;

  -- Shadow mode não escreve no CRM. Rodar o caminho inteiro sem efeito
  -- externo é o que `simulado` significa, e o CRM é externo — contar a ele
  -- que a campanha concluiu, quando nenhuma mensagem saiu, é uma mentira que
  -- o backfill não desfaz.
  --
  -- A mesma condição resolve o caso do D35 de graça: enrollment que percorreu
  -- todos os passos sem identidade nenhuma encerra em `fim_dos_passos` sem
  -- ter mensagem alguma. "Campanha concluída" para quem nunca foi contatado
  -- é exatamente o silêncio que a prévia da inscrição existe para quebrar.
  IF NOT EXISTS (
    SELECT 1 FROM messages m
     WHERE m.enrollment_id = NEW.id AND m.status <> 'simulado'
  ) THEN
    RETURN NEW;
  END IF;

  INSERT INTO outbox (tenant_id, contact_id, destino, fato, payload)
  VALUES (NEW.tenant_id, NEW.contact_id, 'crm', v_fato,
          jsonb_build_object('enrollment_id', NEW.id,
                             'campaign_id', NEW.campaign_id,
                             'motivo', NEW.motivo_encerramento))
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION privado.writeback_do_encerramento IS
  'Enfileira respondido e campanha_concluida quando o enrollment encerra.
   Em gatilho porque há dois caminhos de encerramento e nenhum deles deve
   precisar lembrar. Não dispara em shadow mode (D45).';

CREATE TRIGGER enrollments_writeback
  AFTER UPDATE ON enrollments
  FOR EACH ROW
  WHEN (OLD.status <> 'encerrado' AND NEW.status = 'encerrado')
  EXECUTE FUNCTION privado.writeback_do_encerramento();

-- ---------------------------------------------------------------------------
-- Supressão -> opt_out
-- ---------------------------------------------------------------------------

CREATE FUNCTION privado.writeback_da_supressao() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
BEGIN
  -- Supressão por identidade (canal + valor, sem contato) não vira fato: a
  -- `outbox` escreve sobre uma PESSOA, e aqui não há pessoa para citar. O
  -- contato continua suprimido naquele endereço — só não há o que contar ao
  -- CRM, que também não conhece a identidade isolada.
  IF NEW.contact_id IS NULL THEN RETURN NEW; END IF;

  INSERT INTO outbox (tenant_id, contact_id, destino, fato, payload)
  VALUES (NEW.tenant_id, NEW.contact_id, 'crm', 'opt_out',
          jsonb_build_object('motivo', NEW.motivo,
                             'canal', NEW.canal,
                             'suprimido_em', NEW.criado_em))
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION privado.writeback_da_supressao IS
  'Enfileira opt_out quando um contato entra na supressão. Hoje toda linha de
   suppression é opt-out; se bounce e denúncia passarem a suprimir, a decisão
   que fizer isso precisa distinguir — dizer ao CRM que houve opt-out quando
   houve bounce é reportar uma vontade que ninguém manifestou (D45).';

CREATE TRIGGER suppression_writeback
  AFTER INSERT ON suppression
  FOR EACH ROW
  EXECUTE FUNCTION privado.writeback_da_supressao();

-- ---------------------------------------------------------------------------
-- Superfície: gatilho não é API (D19)
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'privado.writeback_do_encerramento()',
    'privado.writeback_da_supressao()'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', alvo);
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
