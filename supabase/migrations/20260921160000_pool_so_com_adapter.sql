-- O pool passa a olhar o catálogo (D31).
--
-- `tem_adapter` existia desde o D17 e não era lido por ninguém em SQL. O
-- README, o comentário da tabela e a migration do D30 diziam a mesma coisa —
-- "provedor sem adapter não vira opção de envio: o motor recusa antes de
-- prometer, em vez de falhar na hora do disparo" — e isso simplesmente não
-- acontecia. `remetentes_disponiveis` filtrava estado, quota e tipo da conta,
-- e nunca perguntava ao catálogo se aquele provedor sabe enviar.
--
-- O estrago não é o erro: é o passo queimado. Com uma conta de e-mail em
-- `smtp`, o roteador escolhia a conta, `processar_vencidos` criava a mensagem
-- e avançava `passo_atual` e `next_run_at`, e só lá no despachante o
-- `criarAdapter` estourava — virando `culpa = 'remetente'`, falha registrada e
-- health score derrubado. A pessoa nunca recebeu o toque, a cadência andou
-- como se tivesse recebido, e o console mostrava uma conta boa adoecendo.
--
-- Reproduzido antes de corrigir: conta 'smtp' + passo de e-mail devolvia
-- `mensagem_criada` e uma `messages` pendente apontando para um provedor que
-- não tem classe nenhuma em `adapters/`.
--
-- Filtrar aqui é o bastante porque é o único lugar de onde o roteador tira
-- remetente. Sem candidato, ele já faz a coisa certa: `adiado_sem_remetente`,
-- que é recuperável — no dia em que o adapter existir, ou em que a conta for
-- movida para um provedor que envia, os enrollments parados andam sozinhos.
--
-- `ativo` entra junto porque é a mesma garantia pela mesma razão: o gatilho
-- `validar_provedor_do_remetente` recusa cadastrar conta em provedor inativo,
-- mas nada impedia uma conta já criada de continuar sendo escolhida depois de
-- o provedor ser desligado no catálogo.
--
-- O que NÃO muda: cadastrar a conta continua permitido. Os chips do legado
-- apontam para provedores que podem não ter adapter no dia do backfill, e é
-- por isso que o D22 manteve a Evolution no catálogo — quebrar a chave
-- estrangeira para ganhar essa checagem seria trocar um problema por outro.
-- `proximo_horario_de_pool` também não muda: ela só responde "quando vale a
-- pena reperguntar", e reperguntar cedo demais não machuca ninguém.

-- A função mora em `privado`, não em `public`: o endurecimento do D19 moveu
-- para lá tudo que é engrenagem. Qualificar o schema não é estilo — um
-- `CREATE OR REPLACE FUNCTION remetentes_disponiveis` sem qualificar cria uma
-- SEGUNDA função em `public` que sombra a real pelo search_path, e o motor
-- passa a rodar por uma cópia que nenhuma migration conhece. Quem pegou isso
-- foi o teste de reversibilidade, ao tentar devolver a original a `public`.
--
-- `SET search_path` também vem no corpo, e não por ALTER de outra migration:
-- o D19 fixou o search_path com um ALTER em massa, e um CREATE OR REPLACE
-- posterior descarta isso junto com a grade de privilégios.

CREATE OR REPLACE FUNCTION privado.remetentes_disponiveis(
  p_tenant uuid, p_canal canal, p_tipo tipo_campanha
)
RETURNS SETOF sender_accounts
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  SELECT sa.*
    FROM sender_accounts sa
    JOIN channel_provider_catalog p ON p.slug = sa.provedor
   WHERE sa.tenant_id = p_tenant AND sa.canal = p_canal AND sa.tipo_permitido = p_tipo
     AND sa.estado = 'ativo'
     AND (sa.janela < current_date OR sa.enviados_na_janela < sa.quota_diaria)
     AND p.tem_adapter AND p.ativo
   ORDER BY sa.health_score DESC, sa.enviados_na_janela ASC;
$$;

COMMENT ON FUNCTION privado.remetentes_disponiveis IS
  'O pool que o roteador enxerga. Conta cujo provedor não sabe enviar fica de
   fora: o passo é adiado, não queimado numa mensagem que vai falhar (D31).';

-- A grade do D19 para `privado`: os quatro papéis executam, porque RLS e
-- gatilhos chamam daqui e o schema não é publicado pelo PostgREST. Repetir o
-- GRANT não é enfeite — um CREATE OR REPLACE descarta atributos da função, e
-- foi assim que a primeira versão desta migration devolveu a função a `anon`.
DO $$
DECLARE papel text;
BEGIN
  FOREACH papel IN ARRAY ARRAY['anon','authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION privado.remetentes_disponiveis(uuid, canal, tipo_campanha) TO %I',
        papel);
    END IF;
  END LOOP;
END;
$$;
