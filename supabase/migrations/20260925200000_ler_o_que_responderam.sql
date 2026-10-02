-- O que as pessoas responderam, legível (D56).
--
-- O D48 fez os cinco adapters pararem de jogar fora o texto da resposta e
-- gravá-lo em `message_events.payload ->> 'texto'`. Um leitor nasceu junto: o
-- classificador de opt-out, dentro do gatilho.
--
-- E só ele. Contando quem mais lê esse campo: ninguém. `eventos_da_campanha`
-- devolve o TIPO do evento — "respondido" — e não o texto. A linha do tempo da
-- campanha mostra que alguém respondeu e não mostra o quê.
--
-- Então acontece isto, hoje, e está tudo funcionando como projetado: a pessoa
-- responde, a invariante 4 encerra a cadência dela em todas as campanhas, o
-- opt-out é detectado se for o caso — e **ninguém no produto consegue ler o que
-- ela disse**. Para ver a resposta é preciso abrir o painel do Supabase e
-- escrever SQL, que é o que o D26 diz que o produto não pode exigir.
--
-- É a forma do D42 com uma diferença que a piora: lá, o texto ilegível era o
-- que o motor ia mandar; aqui é o que um lead acabou de dizer. O caminho
-- inteiro está certo e o resultado é uma pessoa interessada esperando resposta
-- que ninguém sabe que existe.
--
-- O que esta função NÃO é: não é caixa de entrada com estado. Não há "lida",
-- não há "respondida", não há atribuição. Inventar estado aqui seria criar
-- colunas sem quem as escreva — o `tem_adapter` do D31 de novo. É leitura, e
-- o que ela precisa provar é que o dado existe e chega à tela.
--
-- Campanha opcional de propósito: a resposta chega numa campanha, mas encerra
-- a cadência do contato em TODAS (invariante 4). Quem olha uma campanha quer
-- as dela; quem abre o dia quer as de todas. Uma função, dois usos.
--
-- Sem barra invertida (D32). Tenant explícito (D18).
-- Reversível: supabase/down/20260925200000_ler_o_que_responderam.down.sql

CREATE FUNCTION respostas_recebidas(
  p_tenant      uuid,
  p_campaign_id uuid DEFAULT NULL,
  p_limite      integer DEFAULT 100
)
RETURNS TABLE (
  ocorrido_em     timestamptz,
  contact_id      uuid,
  contato         text,
  canal           canal,
  destino         text,
  campanha        text,
  campaign_id     uuid,
  passo           integer,
  texto           text,
  -- O que a mensagem anterior dizia. Sem ela a resposta fica sem pergunta, e
  -- "sim, pode ser" não quer dizer nada solto.
  em_resposta_a   text,
  -- A resposta pode ter suprimido a pessoa (D48). Quem olha a caixa precisa
  -- saber disso antes de pegar o telefone.
  suprimido       boolean,
  motivo_supressao text
)
LANGUAGE sql STABLE SET search_path = public, privado, pg_catalog AS $$
  SELECT me.ocorrido_em,
         e.contact_id,
         coalesce(c.nome, '(sem nome)'),
         m.canal,
         ci.valor,
         camp.nome,
         camp.id,
         fs.ordem,
         -- Só string vira texto. Objeto viraria "[object Object]" e número
         -- viraria "0" — a mesma trava que o D48 pôs no classificador, pelo
         -- mesmo motivo: o payload é do provedor, não nosso.
         CASE WHEN jsonb_typeof(me.payload -> 'texto') = 'string'
              THEN me.payload ->> 'texto' END,
         m.conteudo,
         s.id IS NOT NULL,
         s.motivo
    FROM message_events me
    JOIN messages m            ON m.id = me.message_id AND m.tenant_id = p_tenant
    JOIN enrollments e         ON e.id = m.enrollment_id
    JOIN campaigns camp        ON camp.id = e.campaign_id
    JOIN contacts c            ON c.id = e.contact_id
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
    LEFT JOIN flow_steps fs    ON fs.id = m.step_id
    -- A supressão pode ser da pessoa inteira ou só daquele endereço, e as duas
    -- contam para quem vai ligar de volta (D49).
    LEFT JOIN suppression s
           ON s.tenant_id = p_tenant
          AND ((s.contact_id = e.contact_id AND s.canal IS NULL)
            OR (s.canal = m.canal AND s.valor_norm = ci.valor_norm))
   WHERE me.tipo = 'respondido'
     AND (p_campaign_id IS NULL OR camp.id = p_campaign_id)
   ORDER BY me.ocorrido_em DESC, me.criado_em DESC
   LIMIT least(coalesce(p_limite, 100), 500);
$$;

COMMENT ON FUNCTION respostas_recebidas(uuid, uuid, integer) IS
  'O que as pessoas responderam, com a mensagem que provocou a resposta e se
   ela suprimiu o contato. O texto era gravado desde o D48 e nenhuma tela o
   lia — resposta ilegível é lead perdido com tudo funcionando (D56).';

-- Superfície (D19). REVOKE de PUBLIC antes do GRANT: função nova nasce com
-- EXECUTE para PUBLIC, e `anon` é membro dele (D55).
DO $$
DECLARE papel text; alvo text := 'public.respostas_recebidas(uuid, uuid, integer)';
BEGIN
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
  FOREACH papel IN ARRAY ARRAY['service_role','postgres','authenticated'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
    END IF;
  END LOOP;
END;
$$;
