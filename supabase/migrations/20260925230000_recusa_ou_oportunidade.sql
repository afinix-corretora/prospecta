-- Resposta que não é recusa vira oportunidade (D58).
--
-- O pedido: resposta positiva para a cadência, o contato sai da fila e vira
-- lead ganho. A base de conhecimento da casa tem o playbook, e ele começa por
-- uma correção de rumo que custou caro ao projeto anterior:
--
--   > IA qualificadora no resgate reperguntava dados e reativava tarde e
--   > duplicado -> classificador de UMA mensagem
--   > prompt classificador RECUSA x NAO-RECUSA (duvida = nao-recusa)
--
-- Ou seja: a pergunta certa **não** é "esta resposta é positiva?". É "esta
-- resposta é uma recusa?" — e tudo o que não for recusa vai para uma pessoa.
-- Tentar detectar entusiasmo é o que falhou; detectar recusa e entregar o
-- resto é o que funcionou.
--
-- ---------------------------------------------------------------------------
-- A assimetria, e ela é o INVERSO da do D48
-- ---------------------------------------------------------------------------
--
-- No D48 (opt-out) o erro caro era o falso POSITIVO: suprimir é imutável, e
-- suprimir quem queria comprar apaga o cliente para sempre. A trava ficou
-- apertada, e termo ambíguo passou a exigir contexto.
--
-- Aqui é ao contrário:
--
--   falso positivo de RECUSA  -> um lead bom nunca chega ao consultor. Caro,
--                                e silencioso: ninguém descobre.
--   falso negativo de RECUSA  -> alguém sem interesse aparece na coluna
--                                Oportunidade e uma pessoa descarta em dois
--                                segundos. Barato, e visível.
--
-- Então a trava muda de lado: **a barra para chamar algo de recusa é alta.**
-- Só entra termo que não tem outra leitura possível numa resposta a
-- prospecção. "ja tenho plano" fica de fora de propósito — quem já tem plano
-- e respondeu é exatamente o lead de quem quer trocar de operadora.
--
-- ---------------------------------------------------------------------------
-- Onde isto roda, e por que a ordem importa
-- ---------------------------------------------------------------------------
--
-- Os gatilhos de `message_events` disparam em ordem alfabética de NOME. Hoje:
--
--   message_events_devolucao_ou_denuncia
--   message_events_encerra_enrollment      <- invariante 4
--   message_events_funil                   <- D57: move para `respondeu`
--   message_events_opt_out_no_texto        <- D48: suprime se pediu para sair
--   message_events_qualifica_resposta      <- este
--
-- O nome começa com `q` de propósito: precisa rodar DEPOIS do opt-out. E,
-- mesmo que a ordem mudasse, `mover_deal` recusaria — quem pediu para sair
-- está em `opt_out`, que é `perdido`, e automação não tira card de lá (D57).
-- A checagem explícita existe para quem lê o código, a regra existe para
-- quando alguém mexer na ordem.
--
-- Sem barra invertida (D32).
-- Reversível: supabase/down/20260925230000_recusa_ou_oportunidade.down.sql

-- ---------------------------------------------------------------------------
-- O vocabulário da recusa
-- ---------------------------------------------------------------------------

CREATE TABLE recusa_termos (
  termo        text PRIMARY KEY,
  exige_uma_de text[],
  nota         text NOT NULL,
  criado_em    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT recusa_termos_normalizado
    CHECK (termo = lower(termo) AND termo = btrim(termo) AND length(termo) > 1)
);

COMMENT ON TABLE recusa_termos IS
  'Palavras que, numa resposta, significam recusa. Sem tenant: é idioma, não
   dado de cliente. Tudo o que NÃO casa aqui vai para uma pessoa — a dúvida
   joga a favor do lead (D58).';

COMMENT ON COLUMN recusa_termos.exige_uma_de IS
  'Quando preenchido, o termo só conta se uma destas palavras aparecer nas TRÊS
   palavras seguintes. É o que separa "não quero nada" de "não quero
   individual, quero empresarial".';

INSERT INTO recusa_termos (termo, exige_uma_de, nota) VALUES
  ('sem interesse', NULL,
   'Não tem outra leitura numa resposta a prospecção.'),
  ('nao tenho interesse', NULL,
   'Idem. A forma mais comum de recusa educada.'),
  ('nao me interessa', NULL,
   'Idem.'),
  ('nao interessa', NULL,
   'Forma curta. Sozinha já é recusa.'),
  ('nao obrigado', NULL,
   'Recusa educada padrão.'),
  ('nao obrigada', NULL,
   'A mesma, no feminino. Lista de palavras não deduz flexão.'),
  ('nao preciso', NULL,
   'Quem responde "nao preciso" a uma oferta de plano está recusando.'),
  ('para de me mandar', NULL,
   'Recusa com irritação. O opt-out do D48 pega as formas mais diretas; esta
    sobra para cá quando nao casa la.'),
  ('nao quero', ARRAY['nada','obrigado','obrigada','isso','nenhum'],
   'AMBÍGUO e caro: "nao quero individual, quero empresarial" é uma resposta
    de COMPRA. Só conta com contexto que feche a frase. Foi este caso exato
    que o D48 documentou do outro lado.');

-- ---------------------------------------------------------------------------
-- O classificador
-- ---------------------------------------------------------------------------

-- Mesmo algoritmo de `privado.pedido_de_saida` (D48), sobre o outro
-- vocabulário. Repetido de propósito e não fatorado: as duas listas têm
-- assimetrias OPOSTAS, e uma função comum convidaria alguém a "melhorar" as
-- duas de uma vez — que é exatamente o que não pode acontecer.
CREATE FUNCTION privado.eh_recusa(p_texto text)
RETURNS text
LANGUAGE plpgsql STABLE SET search_path = public, privado AS $$
DECLARE
  v_texto  text := privado.normalizar_resposta(p_texto);
  t        record;
  v_pos    integer;
  v_resto  text;
  v_janela text;
BEGIN
  IF btrim(v_texto) = '' THEN RETURN NULL; END IF;

  FOR t IN SELECT termo, exige_uma_de FROM recusa_termos ORDER BY length(termo) DESC LOOP
    v_pos := position(' ' || t.termo || ' ' IN v_texto);
    CONTINUE WHEN v_pos = 0;

    IF t.exige_uma_de IS NULL THEN RETURN t.termo; END IF;

    v_resto := substr(v_texto, v_pos + length(t.termo) + 1);
    SELECT coalesce(string_agg(w, ' ' ORDER BY i), '') INTO v_janela
      FROM unnest(string_to_array(btrim(v_resto), ' ')) WITH ORDINALITY AS u(w, i)
     WHERE i <= 3;

    IF EXISTS (SELECT 1 FROM unnest(t.exige_uma_de) c
                WHERE position(' ' || c || ' ' IN ' ' || v_janela || ' ') > 0) THEN
      RETURN t.termo;
    END IF;
  END LOOP;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION privado.eh_recusa IS
  'O termo de recusa que a resposta contém, ou NULL. NULL significa "entregue
   a uma pessoa" — a dúvida joga a favor do lead, porque perder um lead bom é
   silencioso e descartar um ruim custa dois segundos (D58).';

-- ---------------------------------------------------------------------------
-- O gatilho
-- ---------------------------------------------------------------------------

CREATE FUNCTION privado.qualifica_resposta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado, pg_catalog AS $$
DECLARE v_texto text; v_contato uuid; v_deal uuid; v_recusa text;
BEGIN
  -- Só string vira texto: objeto viraria "[object Object]" e número viraria
  -- "0". A mesma trava do D48, pelo mesmo motivo — o payload é do provedor.
  IF jsonb_typeof(NEW.payload -> 'texto') <> 'string' THEN RETURN NEW; END IF;
  v_texto := NEW.payload ->> 'texto';

  -- Quem pediu para sair já foi tratado pelo gatilho anterior. `mover_deal`
  -- recusaria de qualquer forma (o card está em `perdido`), mas dizer isto
  -- aqui poupa quem lê de ter que reconstruir a ordem dos gatilhos.
  IF privado.pedido_de_saida(v_texto) IS NOT NULL THEN RETURN NEW; END IF;

  v_recusa := privado.eh_recusa(v_texto);
  -- Recusou: o card fica em `respondeu`. Não inventamos um estágio de recusa
  -- — a pessoa respondeu, e uma campanha futura pode fazer sentido. Quem quer
  -- nunca mais ser incomodado disse isso, e aí é opt-out.
  IF v_recusa IS NOT NULL THEN RETURN NEW; END IF;

  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = NEW.message_id;
  IF v_contato IS NULL THEN RETURN NEW; END IF;

  SELECT d.id INTO v_deal FROM deals d
   WHERE d.tenant_id = NEW.tenant_id AND d.contact_id = v_contato
     AND d.pipeline_id = (SELECT id FROM pipelines
                           WHERE tenant_id = NEW.tenant_id AND padrao);
  IF v_deal IS NULL THEN RETURN NEW; END IF;

  -- `ia` e não `motor`: isto é JUÍZO, não fato mecânico. Hoje o juízo vem de
  -- uma lista de termos; amanhã pode vir de um modelo. O valor gravado não
  -- muda quando isso acontecer, e é esse o ponto — a linha do tempo do card
  -- continua dizendo "um classificador decidiu isto".
  PERFORM mover_deal(v_deal, 'oportunidade', 'ia',
                     'respondeu e não recusou');

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION privado.qualifica_resposta IS
  'Resposta que não é opt-out nem recusa vira oportunidade. A pergunta é
   "é recusa?", nunca "é positiva?" — detectar entusiasmo foi o que falhou no
   projeto anterior (D58).';

-- O `q` do nome não é estético: os gatilhos de message_events disparam em
-- ordem alfabética, e este precisa vir depois de `..._opt_out_no_texto`.
CREATE TRIGGER message_events_qualifica_resposta
  AFTER INSERT ON message_events
  FOR EACH ROW
  WHEN (NEW.tipo = 'respondido')
  EXECUTE FUNCTION privado.qualifica_resposta();

-- ---------------------------------------------------------------------------
-- Superfície (D19)
-- ---------------------------------------------------------------------------

-- A lista é legível pela tela, como a do opt-out: quem opera precisa poder
-- conferir por que uma resposta foi classificada assim.
GRANT SELECT ON recusa_termos TO authenticated;
