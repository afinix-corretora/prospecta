-- Os classificadores globais voltam, com a grade que tinham (D48, D58).

CREATE OR REPLACE FUNCTION privado.pedido_de_saida(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION privado.eh_recusa(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
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
$function$;

-- A grade de cada um, como era: o do D48 fechado e concedido ao serviço; o do
-- D58 nasceu sem revogação nenhuma.
DO $$
DECLARE papel text;
BEGIN
  REVOKE ALL ON FUNCTION privado.pedido_de_saida(text) FROM PUBLIC;
  FOREACH papel IN ARRAY ARRAY['anon','authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('REVOKE ALL ON FUNCTION privado.pedido_de_saida(text) FROM %I', papel);
    END IF;
  END LOOP;
  FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION privado.pedido_de_saida(text) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;

