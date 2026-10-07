-- D72: o agente de configuração, e a primeira chave que é do PRODUTO.
--
-- Até aqui toda chave de IA era do cliente (D59) e entrava pela tela. O agente
-- que conversa no Setup rápido é outra coisa: ele existe ANTES de o cliente
-- ter qualquer conta conectada — é ele que ajuda a conectar —, então a chave
-- dele é da plataforma. Por decisão do usuário, ela só se troca pelo backend
-- (o Vault do projeto, ou uma sessão de desenvolvimento), nunca pela tela.
--
-- Por isso esta migration NÃO cria porta de escrita nenhuma. O segredo entra
-- no Vault com o nome `openai_agente_setup` (feito no projeto em 07/10, fora
-- de qualquer arquivo — chave não entra no git), e daqui saem só duas leituras:
--
--   segredo_do_agente_setup()   o valor, para a edge function `agente-setup`,
--                               que roda com a chave do serviço. Ninguém mais.
--   agente_de_setup_disponivel() um FATO a respeito dele (existe?), para a tela
--                               dizer "o agente está pronto" ou "falta a chave
--                               da plataforma". Nunca o valor (D44).
--
-- Sem Vault (o Postgres de teste), as duas respondem "não há" em vez de
-- quebrar: a leitura do Vault é dinâmica, como em `privado.ler_segredo`.

CREATE FUNCTION segredo_do_agente_setup()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v text;
BEGIN
  IF to_regnamespace('vault') IS NULL THEN RETURN NULL; END IF;
  EXECUTE 'SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = $1'
    INTO v USING 'openai_agente_setup';
  RETURN v;
END;
$$;

COMMENT ON FUNCTION segredo_do_agente_setup() IS
  'Chave OpenAI da plataforma para o agente de configuração (D72). Só o service_role chama.';

CREATE FUNCTION agente_de_setup_disponivel()
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v boolean;
BEGIN
  IF to_regnamespace('vault') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT EXISTS (SELECT 1 FROM vault.secrets WHERE name = $1)'
    INTO v USING 'openai_agente_setup';
  RETURN coalesce(v, false);
END;
$$;

COMMENT ON FUNCTION agente_de_setup_disponivel() IS
  'Se a chave do agente de configuração existe no Vault. Fato, nunca o valor (D44).';

-- Função nova nasce com EXECUTE para PUBLIC, e `anon` é membro dele (D55):
-- revogar antes de conceder é o que torna a concessão uma decisão.
DO $$
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION segredo_do_agente_setup() FROM PUBLIC, anon';
  EXECUTE 'REVOKE ALL ON FUNCTION agente_de_setup_disponivel() FROM PUBLIC, anon';
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON FUNCTION segredo_do_agente_setup() FROM authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION agente_de_setup_disponivel() TO authenticated';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION segredo_do_agente_setup() TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION agente_de_setup_disponivel() TO service_role';
  END IF;
END;
$$;
