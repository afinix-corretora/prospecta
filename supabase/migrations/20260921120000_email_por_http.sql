-- E-mail ganha adapter, e ele fala HTTP (D30).
--
-- O canal `email` existe no enum desde a primeira migration e estava sem
-- adapter desde então. O catálogo declarava `smtp`, e era por isso que ficava
-- parado: `adapters/tipos.ts` diz, na primeira linha do arquivo, que ali só
-- entra `fetch` — é o que faz o mesmo adapter rodar no Deno da edge function e
-- no Node do teste, sem mock de runtime. SMTP precisa de socket. Ligar SMTP
-- significaria abrir uma exceção nessa regra para os quatro canais, e um
-- provedor HTTP entrega o mesmo e-mail sem cobrar esse preço.
--
-- `smtp` NÃO sai do catálogo, pelo mesmo motivo que a Evolution não saiu
-- quando a UAZAPI entrou: sumir com a opção esconde a decisão. Fica com
-- `tem_adapter = false` e a descrição dizendo por quê — o motor recusa o envio
-- antes de prometer, em vez de falhar na hora do disparo.
--
-- Duas escolhas do adapter aparecem aqui, no catálogo, porque é ele quem manda
-- na tela:
--
-- `assunto_padrao` é OBRIGATÓRIO. `flow_steps.template` é um texto só, porque
-- os outros três canais não têm assunto; em vez de abrir coluna no motor para
-- a necessidade de um canal, o passo pode trazer `Assunto: ...` na primeira
-- linha, e quando não traz vale este. Sendo obrigatório, "passo de e-mail sem
-- assunto" deixa de ser um estado possível — a mesma escolha de sempre aqui:
-- garantia por constraint, não por convenção.
--
-- `responder_para` é o que faz a invariante 4 valer no e-mail. A resposta só
-- vira `email.received` se cair num domínio de inbound; sem isso a pessoa
-- responde para uma caixa que o motor não lê e a cadência continua andando —
-- exatamente o furo que o D23 fechou no WhatsApp não oficial.

INSERT INTO channel_provider_catalog
  (slug, canal, nome, descricao, oficial, tem_adapter, campos, docs_url, ordem) VALUES
('resend', 'email', 'Resend',
 'E-mail por API HTTP. Cada domínio verificado vira uma conta aqui, com quota e chave próprias. Campanha fria usa domínio separado do institucional (D4).',
 true, true,
 '[{"chave":"api_key","rotulo":"API key","tipo":"senha","obrigatorio":true,"segredo":true,"ajuda":"Resend → API Keys, com permissão de envio"},
   {"chave":"assunto_padrao","rotulo":"Assunto padrão","tipo":"texto","obrigatorio":true,"segredo":false,"ajuda":"Vale quando o passo não começa com uma linha Assunto: ..."},
   {"chave":"nome_remetente","rotulo":"Nome de exibição","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Aparece antes do endereço: Ana da Afinix <ana@...>"},
   {"chave":"responder_para","rotulo":"Responder para","tipo":"texto","obrigatorio":false,"segredo":false,"ajuda":"Endereço de inbound da Resend — é por ele que a resposta encerra a cadência"}]'::jsonb,
 'https://resend.com/docs', 5);

-- SMTP continua listado, e agora diz por que está sem adapter.
UPDATE channel_provider_catalog SET ordem = 6, descricao =
  'Caixa de saída própria. Sem adapter: SMTP precisa de socket, e o motor só fala HTTP (D30). Use um provedor de e-mail por API.'
 WHERE slug = 'smtp';

UPDATE channel_provider_catalog SET ordem = 7 WHERE slug = 'instagram_oficial';

-- ---------------------------------------------------------------------------
-- Campo obrigatório passa a ser obrigatório de verdade
-- ---------------------------------------------------------------------------

-- `salvar_credencial_ia` já recusava campo obrigatório em branco; a de
-- remetente só recusava campo que o provedor não declara. A diferença nunca
-- doeu porque a tela também validava — mas quem valida não pode ser a tela
-- (D28), e `assunto_padrao` só é uma garantia se o banco a cobrar.
--
-- Junto vem o que a de IA já fazia e esta não: segredo em branco não apaga o
-- que está guardado. A chave volta vazia da tela porque segredo não é legível,
-- e reenviar vazio para editar o assunto padrão zerava a credencial de um chip
-- em operação. Campo não-secreto em branco continua limpando o valor — apagar
-- o "responder para" tem que ser possível.
CREATE OR REPLACE FUNCTION salvar_credencial_remetente(
  p_sender_id   uuid,
  p_credenciais jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE
  v_tenant uuid; v_provedor text; v_segredo uuid; v_proibida text;
  v_id_antigo uuid; v_antigo jsonb; v_final jsonb;
BEGIN
  SELECT tenant_id, provedor, credenciais_secret_id
    INTO v_tenant, v_provedor, v_id_antigo
    FROM sender_accounts WHERE id = p_sender_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remetente inexistente: %', p_sender_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT privado.pode_administrar(v_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente configura remetente'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- O catálogo manda: campo que não é do provedor não entra no Vault como se
  -- fosse credencial dele.
  SELECT k INTO v_proibida
    FROM jsonb_object_keys(coalesce(p_credenciais, '{}'::jsonb)) k
   WHERE NOT EXISTS (
     SELECT 1 FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = v_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe no provedor %', v_proibida, v_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_antigo := coalesce(nullif(privado.ler_segredo(v_id_antigo), ''), '{}')::jsonb;

  -- O blob final: o que veio da tela, com o segredo antigo preservado quando a
  -- tela mandou branco. Percorre o catálogo, e não as chaves recebidas, porque
  -- o valor guardado de um campo que a tela nem enviou também precisa entrar.
  SELECT coalesce(jsonb_object_agg(k, v), '{}'::jsonb) INTO v_final
    FROM (
      SELECT c ->> 'chave' AS k,
             CASE WHEN (c ->> 'segredo')::boolean
                   AND length(trim(coalesce(p_credenciais ->> (c ->> 'chave'), ''))) = 0
                  THEN v_antigo ->> (c ->> 'chave')
                  ELSE nullif(trim(coalesce(p_credenciais ->> (c ->> 'chave'), '')), '')
             END AS v
        FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
       WHERE p.slug = v_provedor
    ) s
   WHERE v IS NOT NULL;

  SELECT c ->> 'rotulo' INTO v_proibida
    FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = v_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(v_final ->> (c ->> 'chave'), ''))) = 0
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION 'campo obrigatório em branco: %', v_proibida
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_segredo := privado.guardar_segredo(
    'remetente:' || v_provedor || ':' || p_sender_id::text || ':' || gen_random_uuid()::text,
    v_final::text);

  UPDATE sender_accounts SET credenciais_secret_id = v_segredo WHERE id = p_sender_id;
END;
$$;

COMMENT ON FUNCTION salvar_credencial_remetente IS
  'Grava a credencial de um remetente a partir da tela. O catálogo decide quais
   campos existem e quais são obrigatórios; segredo em branco na edição mantém
   o que já está no Vault (D28, D30).';
