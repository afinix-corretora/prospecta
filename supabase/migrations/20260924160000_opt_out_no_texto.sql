-- Quem pede para sair, sai (D48).
--
-- Ate aqui, responder encerrava o enrollment (invariante 4) mas NAO suprimia.
-- Quem respondeu "pare" saia daquela cadencia e voltava a receber na campanha
-- seguinte — o motor honrava a resposta e esquecia o pedido.
--
-- Duas partes: o vocabulario numa tabela, a logica numa funcao. A tabela
-- existe para a lista de palavras mudar sem migration nem leitura de codigo;
-- a funcao existe porque casar palavra em texto livre tem armadilha, e
-- armadilha nao se resolve com lista.
--
-- A ARMADILHA, neste negocio, e especifica e cara: supressao e IMUTAVEL, e
-- duas das palavras obvias sao ambiguas justamente onde o dinheiro esta.
--
--   "quero SAIR do meu plano"          -> quer trocar de operadora. E o melhor
--                                         lead que existe, nao um opt-out.
--   "NAO QUERO individual, quero PME"  -> e uma resposta de compra.
--
-- Suprimir esses dois seria perder a venda E fazer o oposto da vontade da
-- pessoa. Por isso termo ambiguo exige CONTEXTO DE RECEBIMENTO nas tres
-- palavras seguintes: "nao quero recebER", "sair da lista". Termo que nao tem
-- outra leitura possivel numa resposta a prospeccao — "pare", "descadastrar" —
-- vale sozinho.
--
-- Falso positivo aqui e irreversivel; falso negativo e recuperavel pela tela
-- de supressao. Quando os dois erros custam diferente, a trava mora do lado
-- do erro caro.
--
-- Sem barra invertida (D32).

-- ---------------------------------------------------------------------------
-- O vocabulario
-- ---------------------------------------------------------------------------

CREATE TABLE opt_out_termos (
  termo         text PRIMARY KEY,
  exige_uma_de  text[],
  nota          text NOT NULL,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT opt_out_termos_normalizado
    CHECK (termo = lower(termo) AND termo = btrim(termo) AND length(termo) > 1)
);

COMMENT ON TABLE opt_out_termos IS
  'Palavras que, numa resposta, viram pedido de saida. Sem tenant de proposito:
   e idioma, nao dado de cliente — igual aos catalogos. `exige_uma_de` NULL
   significa que o termo vale sozinho (D48).';

COMMENT ON COLUMN opt_out_termos.exige_uma_de IS
  'Quando preenchido, o termo so conta se uma destas palavras aparecer nas TRES
   palavras seguintes. E o que separa "nao quero receber" de "nao quero
   individual, quero empresarial".';

COMMENT ON COLUMN opt_out_termos.nota IS
  'Por que este termo esta aqui, e por que exige (ou nao) contexto. Quem for
   mexer na lista le isto primeiro.';

-- Sem acento e em minuscula: a comparacao acontece sobre o texto normalizado.
INSERT INTO opt_out_termos (termo, exige_uma_de, nota) VALUES
  ('pare', NULL,
   'Palavra-chave padrao de opt-out no Brasil. Numa resposta a prospeccao nao tem outra leitura.'),
  ('parar', ARRAY['receber','enviar','mensagens','contato','mandar'],
   'Sozinho pode ser "parar o plano". Exige o que se quer parar.'),
  ('descadastrar', NULL, 'So existe neste sentido.'),
  ('descadastre', NULL, 'Variante imperativa de descadastrar.'),
  -- Termo composto resolve o contexto que vem ANTES: "pode descartar" traz o
  -- sentido no proprio termo, e a busca ja prefere o termo mais longo.
  ('pode descartar', NULL, 'Pedido explicito. O "pode" antes e o que desambigua.'),
  ('pode descartar meu', NULL, 'Variante com objeto.'),
  ('descartar', ARRAY['meu','minha','cadastro','contato','lista','tudo','isso','esse','essa'],
   'AMBIGUO: "vou comparar e descartar as opcoes ruins" e alguem ENGAJADO. Exige objeto de cadastro.'),
  ('descarte', ARRAY['meu','minha','cadastro','contato','lista','tudo','isso','esse','essa'],
   'Mesma ambiguidade de descartar.'),
  ('nao tenho interesse', NULL,
   'Recusa explicita, sem outra leitura. Estava faltando ao lado de "sem interesse".'),
  ('sair', ARRAY['lista','cadastro','contato','contatos','receber','mailing'],
   'AMBIGUO E CARO: "quero sair do meu plano" e intencao de troca, ou seja, o melhor lead que existe. Exige contexto de lista, nunca vale sozinho.'),
  ('nao quero', ARRAY['receber','mais','contato','nada','mensagens','mensagem','ligacao','ser'],
   'AMBIGUO: "nao quero individual, quero empresarial" e resposta de compra. Exige contexto de recebimento.'),
  ('nao perturbe', NULL, 'Pedido inequivoco.'),
  ('nao me envie', NULL, 'Pedido inequivoco.'),
  ('nao envie mais', NULL, 'Pedido inequivoco.'),
  ('remover da lista', NULL, 'Pedido inequivoco.'),
  ('tirar da lista', NULL, 'Pedido inequivoco.'),
  ('me tira da lista', NULL, 'Pedido inequivoco.'),
  ('tira', ARRAY['lista','cadastro','mailing','daqui','dessa','desse','disso','contatos'],
   'AMBIGUO: "me tira uma duvida" e alguem ENGAJADO. So conta com objeto de lista.'),
  ('tire', ARRAY['lista','cadastro','mailing','daqui','dessa','desse','disso','contatos'],
   'Variante imperativa de tira, mesma ambiguidade.'),
  -- "para" sozinho seria catastrofico: e a preposicao mais comum do idioma.
  -- "para de" ja e construcao verbal, e ainda assim pede contexto.
  ('para de', ARRAY['mandar','enviar','me','falar','ligar','mensagem','mensagens'],
   'AMBIGUO: "para" e preposicao. So a construcao "para de <verbo de envio>" conta.'),
  ('parem de', ARRAY['mandar','enviar','me','falar','ligar','mensagem','mensagens'],
   'Plural de "para de".'),
  ('sem interesse', NULL,
   'Recusa explicita. Nao e ambiguo como "nao quero": nao existe "sem interesse em X, quero Y".'),
  ('spam', NULL, 'Quem chama de spam esta denunciando, nao negociando.');

-- ---------------------------------------------------------------------------
-- A logica
-- ---------------------------------------------------------------------------

-- Minuscula, sem acento, so letra e numero, com espaco nas pontas. O espaco
-- nas pontas e o que faz " pare " casar palavra inteira e nao pedaco de
-- "preparel" — casar por fragmento e como "sair" viraria "sairam".
CREATE FUNCTION privado.normalizar_resposta(p_texto text)
RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT ' ' || btrim(regexp_replace(
           translate(lower(coalesce(p_texto, '')),
                     'áàâãäéèêëíìîïóòôõöúùûüçñ',
                     'aaaaaeeeeiiiiooooouuuucn'),
           '[^a-z0-9]+', ' ', 'g')) || ' ';
$$;

COMMENT ON FUNCTION privado.normalizar_resposta IS
  'Texto da resposta em forma comparavel: minuscula, sem acento, pontuacao
   virando espaco, e espaco nas pontas para casar palavra inteira (D48).';

-- Devolve o termo que casou, ou NULL. Devolver o TERMO e nao um booleano e de
-- proposito: ele vai para o motivo da supressao, e seis meses depois "pare"
-- explica a linha melhor do que "true".
CREATE FUNCTION privado.pedido_de_saida(p_texto text)
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

  FOR t IN SELECT termo, exige_uma_de FROM opt_out_termos ORDER BY length(termo) DESC LOOP
    v_pos := position(' ' || t.termo || ' ' IN v_texto);
    CONTINUE WHEN v_pos = 0;

    -- Termo sem contexto exigido vale sozinho.
    IF t.exige_uma_de IS NULL THEN RETURN t.termo; END IF;

    -- Com contexto: olhar so as TRES palavras seguintes. Procurar a palavra
    -- de contexto no texto inteiro seria pior que nao ter contexto nenhum —
    -- "nao quero individual, prefiro receber por email" casaria.
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

COMMENT ON FUNCTION privado.pedido_de_saida IS
  'O termo de opt-out que a resposta contem, ou NULL. Termo ambiguo so conta
   com contexto nas tres palavras seguintes — falso positivo aqui e imutavel,
   falso negativo se conserta pela tela (D48).';

-- ---------------------------------------------------------------------------
-- O gatilho
-- ---------------------------------------------------------------------------

CREATE FUNCTION privado.opt_out_no_texto() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_termo text; v_contato uuid;
BEGIN
  -- `texto` e a chave que os adapters preenchem quando o provedor entrega o
  -- corpo da mensagem. Provedor que nao entrega (SMS hoje nao tem webhook de
  -- entrada) simplesmente nao aciona isto — e nao adianta fingir que aciona.
  v_termo := privado.pedido_de_saida(NEW.payload ->> 'texto');
  IF v_termo IS NULL THEN RETURN NEW; END IF;

  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = NEW.message_id;
  IF v_contato IS NULL THEN RETURN NEW; END IF;

  -- A pessoa toda, em todo canal: quem pede para parar nao esta pedindo para
  -- parar so no WhatsApp. E o `motivo` carrega o termo, para a linha poder ser
  -- auditada depois sem ir atras do evento.
  IF NOT EXISTS (SELECT 1 FROM suppression s
                  WHERE s.tenant_id = NEW.tenant_id
                    AND s.contact_id = v_contato AND s.canal IS NULL) THEN
    INSERT INTO suppression (tenant_id, contact_id, motivo)
    VALUES (NEW.tenant_id, v_contato,
            'pediu para sair na resposta (termo: ' || v_termo || ')');
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION privado.opt_out_no_texto IS
  'Resposta com pedido de saida suprime o contato inteiro. O writeback opt_out
   sai sozinho pelo gatilho da supressao (D45/D48).';

-- Roda depois de `message_events_encerra_enrollment` (ordem alfabetica): a
-- cadencia encerra primeiro, a supressao entra em seguida.
CREATE TRIGGER message_events_opt_out_no_texto
  AFTER INSERT ON message_events
  FOR EACH ROW
  WHEN (NEW.tipo = 'respondido')
  EXECUTE FUNCTION privado.opt_out_no_texto();

-- ---------------------------------------------------------------------------
-- Superficie (D19)
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'privado.normalizar_resposta(text)',
    'privado.pedido_de_saida(text)',
    'privado.opt_out_no_texto()'
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

-- A lista e leitura de tela (para quem for editar saber o que ja existe) e
-- escrita de plataforma. RLS nao se aplica: nao ha tenant a recortar.
ALTER TABLE opt_out_termos ENABLE ROW LEVEL SECURITY;
CREATE POLICY opt_out_termos_sel ON opt_out_termos FOR SELECT USING (true);
GRANT SELECT ON opt_out_termos TO authenticated, anon;
