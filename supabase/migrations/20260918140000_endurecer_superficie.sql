-- Endurece a superfície que o PostgREST publica.
--
-- Os advisors do Supabase apontaram dois buracos que só aparecem quando o
-- schema encosta num projeto real, porque dependem de como o PostgREST expõe
-- `public` — teste de banco local nenhum pega:
--
--   1. `criar_tenant` era SECURITY DEFINER, chamável por `anon`, e aceitava
--      `p_dono`. Qualquer um, sem login, criava tenant em nome de um uuid
--      arbitrário: escrita não autenticada no banco.
--   2. Toda função em `public` nasce com EXECUTE para PUBLIC, então as
--      auxiliares de RLS (`tem_papel`, `pertence_ao_tenant`) e o motor inteiro
--      (`processar_vencidos`, `reivindicar_pendentes`) viravam endpoint
--      `/rest/v1/rpc/...` para qualquer visitante.
--
-- Mais: função SECURITY DEFINER sem `search_path` fixo é escalada de
-- privilégio — o chamador põe um schema dele na frente e a função passa a ler
-- a tabela dele.
--
-- A correção NÃO é revogar EXECUTE das auxiliares e pronto: expressão de
-- política RLS e corpo de função de gatilho passam, sim, pela checagem de
-- EXECUTE do papel que está escrevendo. Revogar de PUBLIC quebra o RLS e os
-- gatilhos (verificado — `permission denied for function pertence_ao_tenant`).
--
-- A correção é separar por schema, que é o que o PostgREST enxerga:
--
--   public   — só tabelas e as funções que são API de verdade.
--   privado  — RLS, gatilhos e as engrenagens do motor. Fora de `db-schemas`,
--              então não existe endpoint para elas, mas continuam chamáveis de
--              dentro do banco por quem escreve.
--
-- IMPORTANTE na hora de configurar o projeto: `privado` não pode ser
-- adicionado em Settings → API → Exposed schemas. Adicionar desfaz isto aqui.

CREATE SCHEMA privado;

COMMENT ON SCHEMA privado IS
  'Funções internas: RLS, gatilhos e motor. Nunca exposta pelo PostgREST — é
   o que impede cada engrenagem do motor de virar endpoint público.';

-- ---------------------------------------------------------------------------
-- O que é API, e só isso, fica em public
-- ---------------------------------------------------------------------------

DO $$
DECLARE
  r record;
  -- Chamadas de fora do banco. As quatro primeiras são o worker (service_role);
  -- o resto é a UI (authenticated), e tudo passa pelo RLS.
  api text[] := ARRAY[
    'processar_vencidos', 'reivindicar_pendentes',
    'registrar_resultado_envio', 'registrar_evento_provedor',
    'criar_tenant', 'criar_campanha_de_modelo', 'atribuir_agente',
    'agente_do_canal', 'inscrever'
  ];
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS assinatura
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND NOT (p.proname = ANY (api))
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET SCHEMA privado', r.assinatura);
  END LOOP;
END;
$$;

-- Políticas, DEFAULTs de coluna e gatilhos guardam OID, não nome: todos
-- seguem a função para o schema novo sem serem reescritos.

-- ---------------------------------------------------------------------------
-- search_path fixo em toda função, nos dois schemas
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS assinatura
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('public', 'privado')
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, privado', r.assinatura);
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Onboarding: o dono é sempre quem chamou
-- ---------------------------------------------------------------------------

-- A forma de três argumentos continua existindo para backfill e para o
-- servidor, mas perde o DEFAULT — senão colidiria com a de dois.
DROP FUNCTION IF EXISTS criar_tenant(text, text, uuid);

CREATE FUNCTION criar_tenant(p_nome text, p_slug text, p_dono uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_id uuid;
BEGIN
  IF p_dono IS NULL THEN
    RAISE EXCEPTION 'sem usuário para ser dono do tenant'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO tenants (nome, slug) VALUES (p_nome, p_slug) RETURNING id INTO v_id;
  INSERT INTO tenant_users (tenant_id, user_id, papel) VALUES (v_id, p_dono, 'dono');
  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION criar_tenant(text, text, uuid) IS
  'Forma administrativa: diz de quem é o tenant. Só service_role — pela API o
   usuário só cria tenant para si mesmo (forma de dois argumentos).';

-- O caminho do cadastro self-service. Não há como dizer de quem é o tenant:
-- é de quem está logado. Sem JWT, recusa.
CREATE FUNCTION criar_tenant(p_nome text, p_slug text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_dono uuid;
BEGIN
  v_dono := usuario_atual();
  IF v_dono IS NULL THEN
    RAISE EXCEPTION 'é preciso estar autenticado para criar um tenant'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN criar_tenant(p_nome, p_slug, v_dono);
END;
$$;

-- ---------------------------------------------------------------------------
-- Nega tudo, libera nominalmente
-- ---------------------------------------------------------------------------

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

DO $$
DECLARE
  papel text;
  f text;
  -- O que a UI legitimamente chama. Tudo aqui é SECURITY INVOKER e passa pelo
  -- RLS: `criar_campanha_de_modelo` só cria onde o WITH CHECK deixa.
  da_ui text[] := ARRAY[
    'criar_tenant(text, text)',
    'criar_campanha_de_modelo(uuid, text, text, canal[])',
    'atribuir_agente(uuid, uuid)',
    'agente_do_canal(uuid, canal)',
    'inscrever(uuid, uuid, uuid, timestamp with time zone)'
  ];
BEGIN
  -- Quem escreve precisa poder executar o que o RLS e os gatilhos chamam. Isso
  -- não é superfície: `privado` não é publicada, então não há endpoint.
  FOREACH papel IN ARRAY ARRAY['anon','authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT USAGE ON SCHEMA privado TO %I', papel);
      EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA privado TO %I', papel);
    END IF;
  END LOOP;

  -- O worker e as migrations falam com o motor inteiro.
  FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO %I', papel);
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    FOREACH f IN ARRAY da_ui LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f);
    END LOOP;
  END IF;
END;
$$;

-- `anon` não chama nada em `public`. Quem não fez login não tem o que fazer no
-- motor — nem criar tenant, que era o buraco.
