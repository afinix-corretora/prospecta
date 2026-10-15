-- Ingestão de contato: o primeiro quadro do diagrama, que não existia (D32).
--
-- `CLAUDE.md` diz "entrada implementa `ContactSource`" e o D1 nomeia
-- `PlanilhaSource` e `PipefySource`. Nada disso existia — nem a interface. Em
-- SQL havia só `inscrever()`, que inscreve um contato **que já existe**. Não
-- havia como pôr contato no sistema a não ser escrevendo INSERT à mão, o que
-- significa que o motor completo nunca pôde rodar sobre dado real, nem em
-- shadow mode. É a mesma varredura do D31: o documento afirmava, o código não
-- fazia.
--
-- Por que o dedup mora aqui e não no TypeScript: duas linhas para a mesma
-- pessoa é exatamente o que o D2 proíbe, e evitar isso exige atomicidade com
-- o índice único `(tenant_id, canal, valor_norm)`. Separar o SELECT do INSERT
-- entre processos reabre a corrida — o mesmo argumento que manteve o roteador
-- em SQL.
--
-- Por que a NORMALIZAÇÃO não mora aqui: ela já mora em `adapters/telefone.ts`
-- e `adapters/email.ts`, e é o webhook que a usa para casar resposta pelo
-- número (D23). Reimplementá-la em SQL criaria duas normalizações, e o
-- comentário do `telefone.ts` já diz o que isso produz: "duas normalizações
-- divergentes significam supressão furada". Então o chamador manda `valor` e
-- `valor_norm`, e esta função **não normaliza — confere**. `privado.normalizada`
-- é uma trava contra chamador desatento, não um segundo normalizador.

CREATE FUNCTION privado.normalizada(p_canal canal, p_valor_norm text)
RETURNS boolean
LANGUAGE sql IMMUTABLE SET search_path = public, privado AS $$
  SELECT p_valor_norm = lower(trim(p_valor_norm))
     AND length(p_valor_norm) > 0
     AND CASE p_canal
           -- Telefone normalizado é só dígito, com DDI. 10 cobre o fixo sem
           -- DDI que a ingestão antiga deixava passar; 15 é o teto do E.164.
           WHEN 'whatsapp'  THEN p_valor_norm ~ '^[0-9]{10,15}$'
           WHEN 'sms'       THEN p_valor_norm ~ '^[0-9]{10,15}$'
           -- Ponto literal escrito como classe de caractere, de propósito: a
           -- forma com barra invertida já chegou duplicada num transporte e
           -- virou "exija uma barra invertida no e-mail", o que recusaria todo
           -- endereço. Quem pegou foi o digesto contra o banco de teste, não o
           -- suite — que roda no arquivo, onde estava certo (D32).
           WHEN 'email'     THEN p_valor_norm ~ '^[^[:space:]@,;<>]+@[^[:space:]@,;<>.]+([.][^[:space:]@,;<>.]+)+$'
           -- Handle sem arroba: o '@' é enfeite de tela, não parte do
           -- identificador, e guardá-lo às vezes com e às vezes sem é dedup
           -- furado.
           WHEN 'instagram' THEN p_valor_norm ~ '^[a-z0-9._]{1,30}$'
         END;
$$;

COMMENT ON FUNCTION privado.normalizada IS
  'Trava contra chamador desatento. NÃO normaliza: quem normaliza é
   adapters/telefone.ts e adapters/email.ts, e ter um segundo normalizador é
   como a supressão fica furada (D32).';

-- ---------------------------------------------------------------------------
-- A entrada
-- ---------------------------------------------------------------------------

-- SECURITY INVOKER de propósito: a RLS de `contacts` e `contact_identities` já
-- exige `pode_operar(tenant_id)` para escrever, então a política faz a
-- autorização e a função não precisa passar por cima dela. Mesmo desenho de
-- `criar_campanha_de_modelo`.
CREATE FUNCTION ingerir_contato(
  p_tenant      uuid,
  p_origem      text,
  p_identidades jsonb,
  p_nome        text  DEFAULT NULL,
  p_origem_ref  text  DEFAULT NULL,
  p_metadados   jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  contact_id             uuid,
  acao                   text,
  identidades_novas      integer,
  identidades_existentes integer,
  identidades_suprimidas integer
)
LANGUAGE plpgsql SET search_path = public, privado AS $$
DECLARE
  v_id       uuid;
  v_donos    uuid[];
  v_ruim     text;
  v_novas    integer := 0;
  v_existentes integer := 0;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'ingestão sem tenant explícito'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_origem IS NULL OR length(trim(p_origem)) = 0 THEN
    RAISE EXCEPTION 'todo contato registra de onde veio'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF jsonb_typeof(p_identidades) <> 'array' OR jsonb_array_length(p_identidades) = 0 THEN
    RAISE EXCEPTION 'contato sem identidade não é alcançável por canal nenhum'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- As identidades desta chamada, já conferidas.
  CREATE TEMP TABLE IF NOT EXISTS entrada (
    canal canal, valor text, valor_norm text
  ) ON COMMIT DROP;
  DELETE FROM entrada;

  INSERT INTO entrada (canal, valor, valor_norm)
  SELECT (e ->> 'canal')::canal, e ->> 'valor', e ->> 'valor_norm'
    FROM jsonb_array_elements(p_identidades) e;

  SELECT canal::text || ' ' || coalesce(valor_norm, '(nulo)') INTO v_ruim
    FROM entrada
   WHERE valor IS NULL OR valor_norm IS NULL
      OR NOT privado.normalizada(canal, valor_norm)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'identidade não normalizada: %', v_ruim
      USING ERRCODE = 'invalid_parameter_value',
            HINT = 'normalize com adapters/telefone.ts ou adapters/email.ts antes de ingerir';
  END IF;

  -- D2: quem diz que é a mesma pessoa é a identidade, nunca o nome. Dois
  -- "João Silva" são duas pessoas; o mesmo telefone é uma só.
  SELECT coalesce(array_agg(DISTINCT ci.contact_id), '{}')
    INTO v_donos
    FROM contact_identities ci
    JOIN entrada n ON n.canal = ci.canal AND n.valor_norm = ci.valor_norm
   WHERE ci.tenant_id = p_tenant;

  -- Duas identidades desta linha pertencem a contatos diferentes que já
  -- existem. Isso é fusão de pessoas, é destrutivo e não tem volta — então
  -- recusa alto em vez de escolher um dos dois em silêncio.
  IF array_length(v_donos, 1) > 1 THEN
    RAISE EXCEPTION
      'as identidades desta linha já pertencem a % contatos diferentes: %',
      array_length(v_donos, 1), v_donos
      USING ERRCODE = 'restrict_violation',
            HINT = 'fundir contatos é decisão de operação, não de importação';
  END IF;

  IF array_length(v_donos, 1) = 1 THEN
    v_id := v_donos[1];
    acao := 'atualizado';
    -- Nome só preenche, nunca piora: reimportar uma planilha sem a coluna de
    -- nome não pode apagar o nome que já estava lá. Metadados são mesclados
    -- pela mesma razão — a segunda fonte acrescenta, não substitui.
    UPDATE contacts c
       SET nome = coalesce(nullif(trim(p_nome), ''), c.nome),
           metadados = c.metadados || coalesce(p_metadados, '{}'::jsonb),
           origem_ref = coalesce(p_origem_ref, c.origem_ref),
           atualizado_em = now()
     WHERE c.id = v_id AND c.tenant_id = p_tenant;
  ELSE
    acao := 'criado';
    INSERT INTO contacts (tenant_id, nome, origem, origem_ref, metadados)
    VALUES (p_tenant, nullif(trim(p_nome), ''), p_origem, p_origem_ref,
            coalesce(p_metadados, '{}'::jsonb))
    RETURNING id INTO v_id;
  END IF;

  -- Reingestão não duplica: o índice único é a garantia, e o DO NOTHING é a
  -- consequência dela, não um substituto.
  WITH inseridas AS (
    INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem, origem_ref)
    SELECT p_tenant, v_id, n.canal, n.valor, n.valor_norm, p_origem, p_origem_ref
      FROM entrada n
    ON CONFLICT (tenant_id, canal, valor_norm) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_novas FROM inseridas;

  SELECT count(*) - v_novas INTO v_existentes FROM entrada;

  -- Identidade suprimida continua sendo gravada: o gate é o roteador, e o
  -- cadastro completo é o que faz o writeback no CRM fazer sentido. O que ela
  -- ganha aqui é visibilidade — quem importa 500 linhas merece saber que 12
  -- delas nunca serão tocadas.
  SELECT count(*) INTO identidades_suprimidas
    FROM entrada n
   WHERE esta_suprimido(p_tenant, v_id, n.canal, n.valor_norm);

  contact_id := v_id;
  identidades_novas := v_novas;
  identidades_existentes := v_existentes;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION ingerir_contato IS
  'Entrada de contato com dedup por identidade (D2), atômica com o índice
   único. Não normaliza: confere que o chamador normalizou (D32).';

-- ---------------------------------------------------------------------------
-- Superfície: esta É API — a tela de importação chama
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION ingerir_contato(uuid, text, jsonb, text, text, jsonb) FROM PUBLIC, anon';
  FOREACH papel IN ARRAY ARRAY['authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION ingerir_contato(uuid, text, jsonb, text, text, jsonb) TO %I', papel);
    END IF;
  END LOOP;

  -- A trava é engrenagem, não API: mora em `privado` e ninguém de fora chama.
  FOREACH papel IN ARRAY ARRAY['anon','authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION privado.normalizada(canal, text) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
