-- Revoga os grants nominais que o Supabase concede por padrão.
--
-- A migration anterior tirou EXECUTE de PUBLIC e achou que tinha fechado. O
-- advisor do projeto real mostrou que não: o Supabase instala
--
--   ALTER DEFAULT PRIVILEGES IN SCHEMA public
--     GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
--
-- então toda função nova nasce com EXECUTE concedido NOMINALMENTE a `anon` e
-- `authenticated`. `REVOKE ... FROM PUBLIC` não encosta em grant nominal, e
-- `criar_tenant` continuou sendo `/rest/v1/rpc/criar_tenant` para visitante
-- sem login.
--
-- O Postgres local não tem esse default privilege, então o teste passava.
-- É a diferença entre "o schema está certo" e "o projeto está seguro" — e o
-- que fecha a segunda é o advisor, não o suite.

-- Limpa o que já foi concedido.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS assinatura
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon, authenticated', r.assinatura);
  END LOOP;
END;
$$;

-- E impede que a próxima função nasça aberta. A superfície de API passa a ser
-- opt-in: função nova não é endpoint até alguém conceder EXECUTE de propósito.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;

-- Devolve, nominalmente, o que a UI chama.
DO $$
DECLARE
  f text;
  da_ui text[] := ARRAY[
    'criar_tenant(text, text)',
    'criar_campanha_de_modelo(uuid, text, text, canal[])',
    'atribuir_agente(uuid, uuid)',
    'agente_do_canal(uuid, canal)',
    'inscrever(uuid, uuid, uuid, timestamp with time zone)'
  ];
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    FOREACH f IN ARRAY da_ui LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    END LOOP;
  END IF;
END;
$$;
