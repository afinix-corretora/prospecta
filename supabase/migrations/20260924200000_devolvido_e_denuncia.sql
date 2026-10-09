-- Devolucao e denuncia, que nao sao a mesma coisa (D49, parte 2 de 2).
--
-- A operacao pediu que "bounce e denuncia tambem suprimam". Suprimem — mas
-- de formas diferentes, porque sao fatos de naturezas diferentes, e trata-los
-- igual escreveria no CRM uma vontade que ninguem manifestou.
--
--   denuncia              VONTADE. A pessoa marcou como spam. Suprime a PESSOA
--                         inteira, em todo canal, e o CRM ouve `opt_out`.
--
--   devolvido permanente  FATO SOBRE O ENDERECO. A caixa nao existe. Suprime
--                         so AQUELE ENDERECO, e o CRM ouve
--                         `identidade_invalida`. Dizer `opt_out` aqui seria
--                         inventar uma decisao da pessoa (D45).
--
--   devolvido temporario  NADA. Caixa cheia numa terca-feira nao e motivo para
--                         perder um contato bom para sempre.
--
-- A composicao com o D45 sai de graca e e o que torna isto barato: o gatilho
-- de writeback da supressao volta cedo quando `contact_id` e nulo. Supressao
-- por ENDERECO tem contact_id nulo. Logo, devolucao nao produz `opt_out`
-- sozinha — nao por um `IF` que alguem lembrou de escrever, mas porque as
-- duas formas de suprimir ja eram estruturalmente diferentes.
--
-- Por que suprimir o endereco, se invalidar a identidade ja tira do pool?
--
-- Escrevi primeiro que era para sobreviver a reimportacao — e estava ERRADO:
-- `contact_identities` e unica em (tenant, canal, valor_norm) e a ingestao usa
-- ON CONFLICT DO NOTHING, entao a linha invalidada persiste. O teste me pegou.
--
-- A razao verdadeira e o D37 aplicado a identidade em vez de remetente:
-- invalidar decide o FUTURO, e a mensagem que ja existe carrega a identidade
-- na propria linha. Entre o agendador criar a mensagem e o despachante pega-la
-- ha uma janela ilimitada (D37), e e dentro dela que a devolucao chega. Quem
-- barra a mensagem em voo e `esta_suprimido`, que o despacho consulta (D39) —
-- `valida` ele nem olha.
--
-- Sem a supressao por endereco, essa mensagem sai para uma caixa morta. Em
-- e-mail isso nao e so desperdicio: devolver de novo derruba a reputacao do
-- dominio, que e o ativo que faz as proximas chegarem.
--
-- O DEFAULT do desconhecido e nao suprimir. Provedor que nao diz se a
-- devolucao foi permanente cai no caso temporario, de proposito: falso
-- negativo se conserta pela tela, falso positivo e imutavel.
--
-- Sem barra invertida (D32).

CREATE FUNCTION privado.devolucao_ou_denuncia() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE
  v_contato    uuid;
  v_identidade uuid;
  v_canal      canal;
  v_valor      text;
  v_permanente boolean;
BEGIN
  SELECT e.contact_id, m.contact_identity_id, m.canal
    INTO v_contato, v_identidade, v_canal
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = NEW.message_id;

  IF v_contato IS NULL THEN RETURN NEW; END IF;

  -- ---------------------------------------------------------------------
  -- Denuncia: vontade, e a mais forte que existe
  -- ---------------------------------------------------------------------
  IF NEW.tipo = 'denuncia' THEN
    IF NOT EXISTS (SELECT 1 FROM suppression s
                    WHERE s.tenant_id = NEW.tenant_id
                      AND s.contact_id = v_contato AND s.canal IS NULL) THEN
      INSERT INTO suppression (tenant_id, contact_id, motivo)
      VALUES (NEW.tenant_id, v_contato, 'denunciou como spam');
    END IF;
    RETURN NEW;
  END IF;

  -- ---------------------------------------------------------------------
  -- Devolucao: fato sobre o endereco, e so quando o provedor diz que e
  -- definitiva
  -- ---------------------------------------------------------------------

  -- `permanente` e o que o adapter escreve quando o provedor distingue. Sem
  -- ele, nao ha o que decidir: fica como temporario.
  v_permanente := coalesce((NEW.payload ->> 'permanente')::boolean, false);
  IF NOT v_permanente THEN RETURN NEW; END IF;

  SELECT ci.valor_norm INTO v_valor
    FROM contact_identities ci WHERE ci.id = v_identidade;
  IF v_valor IS NULL THEN RETURN NEW; END IF;

  -- Duas travas, e nao uma, porque cobrem janelas diferentes: `valida = false`
  -- tira do pool das decisoes FUTURAS; a supressao barra a mensagem que ja
  -- esta pendente, que carrega a identidade na linha e nao volta a perguntar
  -- se ela e valida (ver o cabecalho).
  UPDATE contact_identities SET valida = false WHERE id = v_identidade;

  IF NOT EXISTS (SELECT 1 FROM suppression s
                  WHERE s.tenant_id = NEW.tenant_id
                    AND s.canal = v_canal AND s.valor_norm = v_valor) THEN
    INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
    VALUES (NEW.tenant_id, v_canal, v_valor, 'devolucao permanente do provedor');
  END IF;

  -- O CRM ouve que o endereco e ruim — nao que a pessoa pediu para sair.
  INSERT INTO outbox (tenant_id, contact_id, destino, fato, payload)
  VALUES (NEW.tenant_id, v_contato, 'crm', 'identidade_invalida',
          jsonb_build_object('contact_identity_id', v_identidade,
                             'canal', v_canal,
                             'motivo', 'devolucao permanente'));

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION privado.devolucao_ou_denuncia IS
  'Denuncia suprime a pessoa (vontade); devolucao permanente suprime o
   endereco (fato). Temporaria nao suprime nada. O writeback certo sai de cada
   caminho porque as duas formas de suprimir ja sao diferentes (D45/D49).';

CREATE TRIGGER message_events_devolucao_ou_denuncia
  AFTER INSERT ON message_events
  FOR EACH ROW
  WHEN (NEW.tipo IN ('devolvido', 'denuncia'))
  EXECUTE FUNCTION privado.devolucao_ou_denuncia();

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION privado.devolucao_ou_denuncia() FROM PUBLIC, anon, authenticated';
  FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION privado.devolucao_ou_denuncia() TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
