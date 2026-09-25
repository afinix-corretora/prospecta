-- Ler o que o motor compôs (D42).
--
-- O shadow mode existe para rodar o caminho inteiro sem enviar nada. Mas o
-- texto que ele compôs — o template já renderizado, que é o que a pessoa
-- receberia — não aparecia em lugar nenhum do produto. O painel da campanha
-- mostra eventos (entrega, resposta, clique), não conteúdo.
--
-- Sem isso, o modo que de-risca o projeto não consegue pegar a classe de erro
-- mais óbvia: o template errado. E há uma que ele pega sozinho se a pessoa
-- puder ler.
--
-- `renderizar` troca chave ausente por string vazia, e não pela marcação crua.
-- A decisão está certa — "mandar `Oi {{nome}}` para um cliente é pior do que
-- mandar `Oi`" — mas o resultado, para um contato sem nome, é isto:
--
--     Olá {{nome}}, tudo bem?   ->   Olá , tudo bem?
--     {{nome}}, você é de {{cidade}}.  ->   , você é de .
--
-- Ninguém escreve "Olá ," à mão. A planilha que entra sem coluna de nome —
-- que é o caso normal de uma lista fria — produz isso em toda mensagem.
--
-- Então a função devolve o conteúdo E marca a suspeita. Marcar, não corrigir:
-- consertar o texto seria decidir a redação por quem escreveu o template, e
-- "Olá, tudo bem?" pode não ser o que a pessoa queria dizer. A tela mostra, e
-- quem escreveu decide.
--
-- Sem barra invertida (D32): as classes POSIX fazem o mesmo trabalho.

CREATE FUNCTION mensagens_da_campanha(
  p_tenant uuid, p_campaign_id uuid, p_limite integer DEFAULT 50
)
RETURNS TABLE (
  message_id  uuid,
  criado_em   timestamptz,
  contato     text,
  canal       canal,
  destino     text,
  passo       integer,
  status      status_message,
  remetente   text,
  conteudo    text,
  buraco      boolean
)
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  SELECT m.id,
         m.criado_em,
         coalesce(c.nome, '(sem nome)'),
         m.canal,
         ci.valor,
         fs.ordem,
         m.status,
         coalesce(sa.apelido, sa.identificador, '(sem remetente)'),
         m.conteudo,
         -- Best-effort, e assumido como tal: pontuação órfã ou espaço dobrado
         -- é o rastro que uma variável vazia deixa. Falso positivo aqui custa
         -- uma olhada; falso negativo custa uma campanha inteira dizendo
         -- "Olá ,".
         m.conteudo ~ '(^|[[:space:]])[,.;:!?]|[[:space:]][[:space:]]'
    FROM messages m
    JOIN enrollments e ON e.id = m.enrollment_id AND e.campaign_id = p_campaign_id
    JOIN contacts    c ON c.id = e.contact_id
    JOIN contact_identities ci ON ci.id = m.contact_identity_id
    JOIN flow_steps fs ON fs.id = m.step_id
    LEFT JOIN sender_accounts sa ON sa.id = m.sender_account_id
   WHERE m.tenant_id = p_tenant
   ORDER BY m.criado_em DESC
   LIMIT least(coalesce(p_limite, 50), 200);
$$;

COMMENT ON FUNCTION mensagens_da_campanha IS
  'O texto que o motor compôs, com a marca de suspeita de variável vazia. Em
   shadow mode é a única forma de ver o que a pessoa receberia (D42).';

-- ---------------------------------------------------------------------------
-- Superfície: é API — a tela da campanha chama
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION mensagens_da_campanha(uuid, uuid, integer) FROM PUBLIC, anon';
  FOREACH papel IN ARRAY ARRAY['authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION mensagens_da_campanha(uuid, uuid, integer) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
