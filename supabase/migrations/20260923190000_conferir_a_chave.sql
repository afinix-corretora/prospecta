-- Conferir a chave do motor antes de agendar (D44).
--
-- Ligar o motor tem dois passos manuais: guardar a service key no Vault com o
-- nome `chave_do_motor`, e rodar `privado.agendar_motor(...)`. O segundo
-- reclama alto quando está errado. O primeiro não reclama nunca.
--
-- Na tela do Supabase, a `anon` e a `service_role` ficam uma debaixo da outra,
-- com o mesmo formato e quase o mesmo tamanho. Colar a de cima é o erro mais
-- fácil do procedimento inteiro — e o sintoma é este:
--
--     o job agenda            cron.job mostra o job, ativo
--     a batida sai            pg_net enfileira e devolve na hora
--     o worker responde 401   e a passada não faz nada
--     ultimas_passadas(10)    mostra 401, se alguém pensar em olhar
--
-- Um motor parado por chave errada é indistinguível, na tela, de um motor
-- ocioso por não haver vencidos. É o mesmo formato do D31 e do D42: o estado
-- errado existe e nada no produto o nomeia.
--
-- Então a conferência responde ANTES, e responde sobre a chave sem NUNCA
-- devolver a chave. Toda linha é um fato a respeito dela — existe, que papel
-- carrega, de que projeto é, se expirou. O valor não sai daqui, e há teste
-- que falha se algum dia sair.
--
-- Sem barra invertida (D32).

-- Base64url -> texto. O JWT usa o alfabeto url-safe e corta o enchimento;
-- `decode(..., 'base64')` quer o alfabeto normal e o enchimento inteiro.
CREATE FUNCTION privado.b64url(p_seg text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT convert_from(
           decode(translate(p_seg, '-_', '+/')
                  || repeat('=', (4 - length(p_seg) % 4) % 4), 'base64'),
           'UTF8');
$$;

COMMENT ON FUNCTION privado.b64url IS
  'Decodifica um segmento base64url (alfabeto url-safe, sem enchimento), como
   os de um JWT. Auxiliar de conferir_chave_do_motor (D44).';

CREATE FUNCTION privado.conferir_chave_do_motor(p_url text DEFAULT NULL)
RETURNS TABLE (item text, ok boolean, detalhe text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE
  v_chave   text;
  v_partes  text[];
  v_payload jsonb;
  v_papel   text;
  v_ref     text;
  v_exp     bigint;
  v_host    text;
BEGIN
  -- 1. O Vault existe?
  IF to_regnamespace('vault') IS NULL THEN
    RETURN QUERY SELECT 'vault', false,
      'a extensão do Vault não está instalada neste banco';
    RETURN;
  END IF;
  RETURN QUERY SELECT 'vault', true, 'disponível';

  -- 2. O segredo existe, com o nome exato?
  v_chave := privado.chave_do_motor();
  IF v_chave IS NULL OR v_chave = '' THEN
    RETURN QUERY SELECT 'segredo', false,
      'não há segredo chamado chave_do_motor no Vault. O nome é exato, em '
      || 'minúsculas, sem espaço — um nome parecido não é encontrado';
    RETURN;
  END IF;
  RETURN QUERY SELECT 'segredo', true,
    'encontrado, com ' || length(v_chave)::text || ' caracteres';

  -- 2b. Espaço nas pontas. Copiar de um terminal traz quebra de linha junto,
  -- e ela não aparece em campo de senha nenhum. A chave viaja no cabeçalho
  -- `Authorization`, onde um caractere a mais é chave diferente — e o 401 que
  -- volta é idêntico ao de chave errada. Reportar, não aparar em silêncio: o
  -- worker usa o valor como está, então aparar aqui esconderia o defeito.
  -- `btrim` de um argumento só apara ESPAÇO. Quebra de linha e tabulação
  -- passam direto, e são justamente as que uma cópia de terminal traz. O
  -- conjunto vai por `chr()` porque a barra invertida não entra aqui (D32).
  IF v_chave <> btrim(v_chave, ' ' || chr(9) || chr(10) || chr(13)) THEN
    RETURN QUERY SELECT 'limpeza', false,
      'o segredo tem espaço ou quebra de linha nas pontas. Isso vai junto no '
      || 'cabeçalho Authorization e o 401 fica igual ao de chave errada — '
      || 'regrave o segredo sem o excesso';
    v_chave := btrim(v_chave, ' ' || chr(9) || chr(10) || chr(13));
  ELSE
    RETURN QUERY SELECT 'limpeza', true, 'sem espaço nem quebra nas pontas';
  END IF;

  -- 3. Formato. Há dois: o JWT antigo e o `sb_secret_` novo.
  IF v_chave LIKE 'sb_publishable_%' THEN
    RETURN QUERY SELECT 'formato', false,
      'esta é a chave PUBLICÁVEL (sb_publishable_), que o navegador usa e a '
      || 'RLS limita. O worker precisa da secreta (sb_secret_)';
    RETURN;
  END IF;

  IF v_chave LIKE 'sb_secret_%' THEN
    RETURN QUERY SELECT 'formato', true,
      'chave secreta do formato novo (sb_secret_). Não carrega papel nem '
      || 'projeto legíveis: o que ela alcança se confere no painel';
    RETURN QUERY SELECT 'papel', true,
      'implícito no formato: sb_secret_ passa por cima da RLS';
    RETURN;
  END IF;

  v_partes := string_to_array(v_chave, '.');
  IF array_length(v_partes, 1) <> 3 THEN
    RETURN QUERY SELECT 'formato', false,
      'não é um JWT nem uma chave sb_secret_. Confira se não sobrou espaço, '
      || 'quebra de linha ou aspas na cópia';
    RETURN;
  END IF;

  BEGIN
    v_payload := privado.b64url(v_partes[2])::jsonb;
  EXCEPTION WHEN others THEN
    RETURN QUERY SELECT 'formato', false,
      'tem três partes, mas o corpo não decodifica: a cópia veio truncada '
      || 'ou com caractere a mais';
    RETURN;
  END;
  RETURN QUERY SELECT 'formato', true, 'JWT legível';

  -- 4. O papel. É AQUI que mora o erro comum.
  v_papel := v_payload ->> 'role';
  IF v_papel IS NULL THEN
    RETURN QUERY SELECT 'papel', false,
      'o JWT não declara role. Não parece uma chave de API do Supabase';
  ELSIF v_papel = 'service_role' THEN
    RETURN QUERY SELECT 'papel', true, 'service_role — é a correta';
  ELSIF v_papel = 'anon' THEN
    RETURN QUERY SELECT 'papel', false,
      'esta é a chave ANÔNIMA. Na tela do Supabase ela fica logo acima da '
      || 'service_role, com o mesmo formato. Com ela o worker responde 401 '
      || 'em toda batida, e a passada vazia parece não haver vencidos';
  ELSE
    RETURN QUERY SELECT 'papel', false,
      'role inesperado: ' || v_papel || '. O worker precisa de service_role';
  END IF;

  -- 5. O projeto. Chave certa do projeto errado falha igual.
  v_ref := v_payload ->> 'ref';
  IF p_url IS NULL THEN
    RETURN QUERY SELECT 'projeto',
      (v_ref IS NOT NULL),
      CASE WHEN v_ref IS NULL THEN 'o JWT não declara ref'
           ELSE 'a chave é do projeto ' || v_ref
                || '. Passe a URL do worker para eu conferir se é o mesmo' END;
  ELSE
    -- Host da URL, sem depender de regex com barra invertida (D32).
    v_host := split_part(split_part(p_url, '://', 2), '/', 1);
    IF v_ref IS NULL THEN
      RETURN QUERY SELECT 'projeto', false, 'o JWT não declara ref';
    ELSIF v_host LIKE v_ref || '.%' THEN
      RETURN QUERY SELECT 'projeto', true,
        'a chave é do projeto ' || v_ref || ', o mesmo da URL';
    ELSE
      RETURN QUERY SELECT 'projeto', false,
        'a chave é do projeto ' || v_ref || ', e a URL aponta para ' || v_host
        || '. Chave certa do projeto errado também devolve 401';
    END IF;
  END IF;

  -- 6. Validade.
  v_exp := (v_payload ->> 'exp')::bigint;
  IF v_exp IS NULL THEN
    RETURN QUERY SELECT 'validade', true, 'sem expiração declarada';
  ELSIF to_timestamp(v_exp) <= now() THEN
    RETURN QUERY SELECT 'validade', false,
      'a chave expirou em ' || to_char(to_timestamp(v_exp), 'DD/MM/YYYY')
      || '. Gere outra no painel e substitua o segredo';
  ELSE
    RETURN QUERY SELECT 'validade', true,
      'válida até ' || to_char(to_timestamp(v_exp), 'DD/MM/YYYY');
  END IF;
END;
$$;

COMMENT ON FUNCTION privado.conferir_chave_do_motor IS
  'Diz se a chave no Vault serve, antes de agendar — sem nunca devolver a
   chave. Existe porque colar a anon no lugar da service_role não reclama em
   lugar nenhum: o worker responde 401 e a passada vazia parece ausência de
   vencidos (D44).';

-- ---------------------------------------------------------------------------
-- Superfície: operação da plataforma, como as outras cinco (D29)
-- ---------------------------------------------------------------------------

-- Não é API. Devolve fatos sobre um segredo, e quem opera o motor é quem
-- chama. `authenticated` não alcança — o suite confere isso.
DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'privado.b64url(text)',
    'privado.conferir_chave_do_motor(text)'
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
