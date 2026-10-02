-- Escrever a cadência, em vez de só instanciar modelo (D55).
--
-- Até aqui, a única forma de existir um `flow_version` era
-- `criar_campanha_de_modelo`: o catálogo de modelos tinha sete receitas e
-- quem quisesse a oitava não tinha tela, nem função. "O esquema de fluxos
-- para construir de acordo com os canais que queremos rodar" existia inteiro
-- no schema — `flows`, `flow_versions`, `flow_steps`, com a imutabilidade do
-- D9 garantida por gatilho — e não tinha porta.
--
-- Três coisas estão embutidas aqui, e as três vêm de decisão antiga:
--
-- 1. **Publicar, nunca editar** (D9). `flow_versions` e `flow_steps` recusam
--    UPDATE e DELETE por gatilho desde a primeira migration. Esta função só
--    INSERE: "editar a cadência" é publicar a versão seguinte, e quem já está
--    inscrito termina na versão em que entrou. Não há caminho para o
--    contrário, e é de propósito.
--
-- 2. **Republicar NÃO repontar** — e é por isso que a função devolve a versão
--    nova em vez de trocá-la nas campanhas. Repontar é `definir_flow_da_
--    campanha`, uma campanha de cada vez, porque é lá que mora a conferência
--    de canais do D47: a versão nova pode ter deixado de tocar um canal que a
--    campanha habilita, e trocar em massa esconderia isso. A tela mostra
--    quantas campanhas ficaram na versão anterior — o silêncio é o que se
--    evita, não a troca.
--
-- 3. **Nada de cast em valor que veio do cliente** (D34). `'whatsap'::canal`
--    aborta a chamada inteira com uma mensagem de Postgres; o que a pessoa
--    precisa ler é qual PASSO está errado e o que ela escreveu. Então o canal
--    é casado contra os rótulos do enum e a recusa nomeia o índice. O mesmo
--    para `atraso_horas`, conferido por regexp antes de virar número.
--
-- Sobre `atraso_horas` do primeiro passo: o motor nunca o lê. O agendador usa
-- o atraso do passo SEGUINTE para marcar o `next_run_at` (`v_proximo.
-- atraso_horas`), e o primeiro disparo é o `next_run_at` que a inscrição
-- gravou. Gravar aqui o número que a pessoa digitou seria guardar um valor
-- que não tem efeito e que ela leria depois como se tivesse — então o passo 1
-- é gravado com 0, como `criar_campanha_de_modelo` já fazia, e a tela diz por
-- quê em vez de aceitar em silêncio.
--
-- Sem barra invertida (D32). Tenant explícito na assinatura (D18).
-- Reversível: supabase/down/20260925170000_escrever_a_cadencia.down.sql

-- ---------------------------------------------------------------------------
-- Quais variáveis os templates podem usar
-- ---------------------------------------------------------------------------
--
-- `renderizar` troca `{{chave}}` pelo valor de `contacts.metadados` mais o
-- `nome`, e **apaga** a marcação que não tiver valor. O rastro disso é o
-- "Olá , tudo bem?" que o D42 ensina a tela da campanha a marcar — mas marcar
-- depois é tarde: o template já rodou. Aqui a pessoa vê, antes de escrever,
-- quais chaves a base dela realmente tem, e com quantos contatos cada uma.
--
-- Contado no banco, não somado na tela: são milhares de contatos, e o
-- PostgREST não os traz linha a linha para a UI contar chave de JSON.
CREATE FUNCTION variaveis_disponiveis(p_tenant uuid)
RETURNS TABLE (chave text, contatos integer)
LANGUAGE sql STABLE SET search_path = public, privado, pg_catalog AS $$
  SELECT k AS chave, count(*)::integer AS contatos
    FROM contacts c, LATERAL jsonb_object_keys(c.metadados) k
   WHERE c.tenant_id = p_tenant
   GROUP BY k
  UNION ALL
  -- `nome` não mora em metadados: `renderizar` o recebe à parte, sempre.
  -- Contar só quem o tem preenchido é o mesmo aviso das outras chaves —
  -- template com {{nome}} numa base sem nome vira "Olá ,".
  SELECT 'nome', count(*)::integer FROM contacts c
   WHERE c.tenant_id = p_tenant AND coalesce(btrim(c.nome), '') <> ''
  ORDER BY 2 DESC, 1;
$$;

COMMENT ON FUNCTION variaveis_disponiveis(uuid) IS
  'As chaves que os templates deste cliente podem usar, com quantos contatos
   têm cada uma. Variável sem valor é apagada por renderizar, e o rastro é o
   "Olá ," do D42 — este número é o mesmo aviso, antes de escrever (D55).';

-- ---------------------------------------------------------------------------
-- Publicar uma versão
-- ---------------------------------------------------------------------------

CREATE FUNCTION publicar_versao_de_flow(
  p_tenant  uuid,
  p_flow_id uuid,
  p_nome    text,
  p_passos  jsonb
)
RETURNS TABLE (flow_id uuid, flow_version_id uuid, versao integer, passos_criados integer)
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog AS $$
DECLARE
  v_flow    uuid := p_flow_id;
  v_versao  integer;
  v_nova    uuid;
  v_passo   jsonb;
  v_i       integer := 0;
  v_canal   text;
  v_atraso  text;
  v_template text;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant é obrigatório' USING ERRCODE = 'null_value_not_allowed';
  END IF;

  IF p_passos IS NULL OR jsonb_typeof(p_passos) <> 'array' THEN
    RAISE EXCEPTION 'passos precisa ser uma lista' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Cadência sem passo nenhum nunca manda nada. `definir_flow_da_campanha` já
  -- a recusa (D47); recusar na publicação é a mesma recusa, mais cedo, com a
  -- pessoa ainda olhando para o que escreveu.
  IF jsonb_array_length(p_passos) = 0 THEN
    RAISE EXCEPTION 'uma cadência sem passo nenhum nunca manda nada'
      USING ERRCODE = 'invalid_parameter_value',
            HINT = 'acrescente ao menos um passo antes de publicar';
  END IF;

  -- ---- O flow: novo, ou versão seguinte de um que já existe ---------------
  IF v_flow IS NULL THEN
    IF coalesce(btrim(p_nome), '') = '' THEN
      RAISE EXCEPTION 'cadência nova precisa de nome'
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
    INSERT INTO flows (tenant_id, nome) VALUES (p_tenant, btrim(p_nome))
    RETURNING id INTO v_flow;
  ELSE
    -- O tenant vai na condição, não só na FK: recusar aqui dá mensagem de
    -- domínio; deixar para a FK dá violação de chave estrangeira, que não
    -- explica nada a quem está na tela.
    PERFORM 1 FROM flows WHERE tenant_id = p_tenant AND id = v_flow;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'cadência inexistente neste cliente: %', v_flow
        USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  SELECT coalesce(max(fv.versao), 0) + 1 INTO v_versao
    FROM flow_versions fv WHERE fv.tenant_id = p_tenant AND fv.flow_id = v_flow;

  INSERT INTO flow_versions (tenant_id, flow_id, versao)
  VALUES (p_tenant, v_flow, v_versao)
  RETURNING id INTO v_nova;

  -- ---- Os passos ----------------------------------------------------------
  FOR v_passo IN
    SELECT s FROM jsonb_array_elements(p_passos) WITH ORDINALITY AS t(s, i) ORDER BY i
  LOOP
    v_i := v_i + 1;
    v_canal := v_passo ->> 'canal';
    v_template := v_passo ->> 'template';
    v_atraso := v_passo ->> 'atraso_horas';

    -- Casado contra os rótulos do enum, nunca convertido com cast: o cast
    -- inválido aborta a chamada com uma mensagem que não diz qual passo é
    -- (D34).
    IF v_canal IS NULL OR NOT EXISTS (
      SELECT 1 FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid
       WHERE t.typname = 'canal' AND e.enumlabel = v_canal
    ) THEN
      RAISE EXCEPTION 'passo %: canal desconhecido (%)', v_i, coalesce(v_canal, '(vazio)')
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF coalesce(btrim(v_template), '') = '' THEN
      RAISE EXCEPTION 'passo %: falta o texto da mensagem', v_i
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF v_atraso IS NOT NULL AND v_atraso !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'passo %: atraso em horas precisa ser um número inteiro (%)',
        v_i, v_atraso USING ERRCODE = 'invalid_parameter_value';
    END IF;

    INSERT INTO flow_steps (tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
    VALUES (
      p_tenant, v_nova, v_i, v_canal::canal,
      -- O primeiro passo sai quando a inscrição vence; o agendador nunca lê
      -- o atraso dele. Gravar o que a pessoa digitou seria guardar um número
      -- sem efeito que ela leria depois como se tivesse.
      CASE WHEN v_i = 1 THEN 0 ELSE coalesce(v_atraso::integer, 24) END,
      btrim(v_template));
  END LOOP;

  flow_id := v_flow; flow_version_id := v_nova; versao := v_versao; passos_criados := v_i;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION publicar_versao_de_flow(uuid, uuid, text, jsonb) IS
  'Publica uma versão de cadência. Editar é publicar a seguinte (D9): esta
   função só insere. Não reponta campanha nenhuma — isso é
   definir_flow_da_campanha, uma a uma, onde mora a conferência do D47 (D55).';

-- A superfície é decisão, não herança (D19).
DO $$
DECLARE f text;
  da_ui text[] := ARRAY[
    'variaveis_disponiveis(uuid)',
    'publicar_versao_de_flow(uuid, uuid, text, jsonb)'
  ];
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    FOREACH f IN ARRAY da_ui LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    END LOOP;
  END IF;
END;
$$;
