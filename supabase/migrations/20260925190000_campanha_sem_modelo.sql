-- Campanha que não vem de modelo (D55).
--
-- O D55 deu ao cliente como escrever a própria cadência. Faltava o outro lado
-- do par: toda campanha do produto nasce de `criar_campanha_de_modelo`, e o
-- modelo traz junto o tipo, a base legal, os canais e a cadência. Quem
-- escrevesse a sua cadência ficava sem como rodá-la — a saída era instanciar
-- um modelo qualquer e repontar, o que deixa a campanha com o `template_slug`
-- de um modelo que não é o dela e com a base legal de outro.
--
-- Por que uma função, e não um `INSERT` da tela (que o RLS já autorizaria,
-- pelo D41): porque apontar o flow é uma segunda escrita. Inserir a campanha
-- e chamar `definir_flow_da_campanha` em seguida, do lado de fora, é a janela
-- do D54 de novo — criou, caiu a rede, campanha órfã. Dentro da função as
-- duas são uma transação só.
--
-- E o apontamento é feito CHAMANDO `definir_flow_da_campanha`, não com um
-- UPDATE aqui: é lá que mora a conferência de canais do D47. Aqui ela tem
-- mais serventia do que em `criar_campanha_de_modelo` — no modelo os passos
-- são filtrados pelos canais da campanha e cruzar é garantido; aqui a pessoa
-- escolheu as duas coisas separadamente, e escolher errado é possível.
--
-- `template_slug` fica NULL, e isso é informação: a campanha não descende de
-- modelo nenhum, e o dia em que o catálogo mudar ela não tem por que mudar.
--
-- Sem barra invertida (D32). Tenant explícito (D18).
-- Reversível: supabase/down/20260925190000_campanha_sem_modelo.down.sql

CREATE FUNCTION criar_campanha(
  p_tenant          uuid,
  p_nome            text,
  p_tipo            tipo_campanha,
  p_base_legal      text,
  p_canais          canal[],
  p_objetivo        text DEFAULT NULL,
  p_flow_version_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SET search_path = public, privado, pg_catalog AS $$
DECLARE v_id uuid;
BEGIN
  IF p_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant é obrigatório' USING ERRCODE = 'null_value_not_allowed';
  END IF;

  IF coalesce(btrim(p_nome), '') = '' THEN
    RAISE EXCEPTION 'a campanha precisa de nome' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Base legal não é rótulo: é o que autoriza falar com a pessoa, e o D4 a
  -- guarda na campanha justamente para que a resposta exista por escrito
  -- quando alguém perguntar. Vazia, ela seria uma coluna NOT NULL preenchida
  -- com espaço — a decoração do D46.
  IF coalesce(btrim(p_base_legal), '') = '' THEN
    RAISE EXCEPTION 'a campanha precisa de base legal'
      USING ERRCODE = 'invalid_parameter_value',
            HINT = 'em campanha morna, o opt-in; em fria, o interesse legítimo e sua justificativa';
  END IF;

  IF p_canais IS NULL OR cardinality(p_canais) = 0 THEN
    RAISE EXCEPTION 'a campanha precisa de pelo menos um canal habilitado'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO campaigns (tenant_id, nome, tipo, base_legal, canais_habilitados, objetivo)
  VALUES (p_tenant, btrim(p_nome), p_tipo, btrim(p_base_legal), p_canais,
          nullif(btrim(coalesce(p_objetivo, '')), ''))
  RETURNING id INTO v_id;

  -- Opcional: dá para criar a campanha antes de a cadência existir, como o
  -- D47 previu ao deixar a coluna NULL-ável. Quando vem, passa pela mesma
  -- conferência que a tela da campanha usaria.
  IF p_flow_version_id IS NOT NULL THEN
    PERFORM public.definir_flow_da_campanha(v_id, p_flow_version_id);
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION criar_campanha(uuid, text, tipo_campanha, text, canal[], text, uuid) IS
  'Campanha sem modelo, com a cadência apontada na mesma transação — porque
   inserir aqui e apontar lá fora é a campanha órfã do D54 (D55).';

-- Superfície (D19). REVOKE de PUBLIC antes do GRANT: função nova nasce com
-- EXECUTE para PUBLIC, e `anon` é membro dele — conceder sem revogar é
-- acrescentar um grant ao lado de uma porta aberta.
DO $$
DECLARE papel text; alvo text := 'public.criar_campanha(uuid, text, tipo_campanha, text, canal[], text, uuid)';
BEGIN
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
  FOREACH papel IN ARRAY ARRAY['service_role','postgres','authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
    END IF;
  END LOOP;
END;
$$;
