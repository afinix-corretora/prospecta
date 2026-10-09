-- As duas funções do D55 não são endpoint de visitante (D19).
--
-- Corretiva imediata da migration anterior, e quem a pegou foi o meta-teste
-- de `tests/tenants.sql`: "anon não chama absolutamente nada em public".
--
-- O erro é o que o D19 descreve e o D31 já tinha cobrado uma vez: no Postgres,
-- função nova nasce com `EXECUTE` concedido a `PUBLIC`, e `anon` é membro de
-- `PUBLIC`. Conceder a `authenticated` — que foi o que a migration anterior
-- fez — não fecha nada: só acrescenta um grant nominal ao lado do implícito
-- que já estava aberto.
--
-- Na prática: `/rest/v1/rpc/publicar_versao_de_flow` respondia a visitante sem
-- login. O RLS ainda barraria a escrita (as políticas de `flows` e
-- `flow_versions` pedem `pode_operar`), então não era gravação de estranho —
-- mas `variaveis_disponiveis` é `STABLE` e só lê, e a lista de chaves de
-- metadados de um cliente não é coisa que se devolva a quem não entrou.
--
-- O padrão correto está em `20260924120000_a_campanha_aponta_o_flow.sql`:
-- REVOKE de `PUBLIC, anon` primeiro, e só então o GRANT nominal. Conceder sem
-- revogar é acrescentar, não decidir.
--
-- Em arquivo próprio e não editando o anterior: aquele já está registrado no
-- projeto, e reescrever migration aplicada é o que faz o repositório deixar de
-- responder pelo que está no ar (D51, D52).
--
-- Sem barra invertida (D32).

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'public.variaveis_disponiveis(uuid)',
    'public.publicar_versao_de_flow(uuid, uuid, text, jsonb)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    FOREACH papel IN ARRAY ARRAY['service_role','postgres','authenticated'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;
END;
$$;
