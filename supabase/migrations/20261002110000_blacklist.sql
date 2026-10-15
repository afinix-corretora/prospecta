-- A blacklist é do cliente (D63).
--
-- O pedido: Configurações ganha "Blacklist", onde o cliente define os termos,
-- o que acontece quando uma resposta casa com eles, e os bloqueios que quiser.
-- E uma decisão de operação que reverte a do D58: quem responde "não tenho
-- interesse" também vai para a blacklist — recusa da oferta suprime, como o
-- pedido de saída.
--
-- Até aqui o vocabulário era do PRODUTO: `opt_out_termos` (D48) e
-- `recusa_termos` (D58), sem tenant, iguais para todo cliente, editáveis só
-- por migration. O comentário de `tests/tenants.sql` já dizia o que mudar
-- quando um cliente precisasse de vocabulário próprio: é decisão. A decisão
-- chegou, e com ela três coisas.
--
-- 1. `blacklist_termos`, por tenant. Cada termo tem uma AÇÃO, porque "casou"
--    não diz o que fazer:
--
--      suprimir             a pessoa inteira, em todo canal (vontade). O CRM
--                           ouve `opt_out` pelo gatilho do D45.
--      identidade_invalida  só aquele endereço ("número errado") — fato sobre o
--                           endereço, o caminho do D49, e o CRM ouve
--                           `identidade_invalida`.
--      recusa               encerra o ciclo e não suprime: o card fica em
--                           `respondeu` e não vira oportunidade. É o
--                           comportamento do D58, que continua disponível
--                           para o cliente que o preferir.
--
--    As listas globais viram o PADRÃO que todo cliente recebe ao nascer, e o
--    cliente edita a dele à vontade. Nenhum classificador lê mais as globais.
--
-- 2. `blacklist_dominios`, por tenant: e-mail de um domínio inteiro que nunca
--    recebe nada. Entra em `esta_suprimido`, que é a pergunta que o roteador,
--    o gatilho de `messages` e o despacho já fazem — um portão a mais seria um
--    caminho a mais para esquecer (invariante 2).
--
-- 3. A ordem entre ações, quando mais de um termo casa: `suprimir` antes de
--    `identidade_invalida` antes de `recusa`, e dentro da mesma ação o termo
--    mais longo primeiro (o mais específico). Pedido de saída ganha de recusa
--    porque honrar quem pediu para sair é a invariante 2; o contrário seria a
--    recusa engolindo um "pare".
--
-- O que NÃO muda: supressão continua imutável. Apagar um termo da blacklist
-- não devolve quem ele já suprimiu — a tela diz isso ao lado do botão.
--
-- Sem barra invertida (D32).
-- Reversível: supabase/down/20261002110000_blacklist.down.sql

-- ---------------------------------------------------------------------------
-- As duas tabelas
-- ---------------------------------------------------------------------------

CREATE TYPE acao_blacklist AS ENUM ('suprimir', 'identidade_invalida', 'recusa');

CREATE TABLE blacklist_termos (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  termo         text NOT NULL,
  exige_uma_de  text[],
  acao          acao_blacklist NOT NULL,
  nota          text,
  ativo         boolean NOT NULL DEFAULT true,
  -- `padrao` veio da lista do produto no nascimento do cliente; `cliente` foi
  -- escrito pela tela. Só informa: o cliente edita e apaga os dois.
  origem        text NOT NULL DEFAULT 'cliente',
  criado_em     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT blacklist_termos_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT blacklist_termos_termo_uk UNIQUE (tenant_id, termo),
  CONSTRAINT blacklist_termos_origem CHECK (origem IN ('padrao', 'cliente')),
  -- O gatilho abaixo normaliza; isto garante que ninguém grava por fora dele.
  -- Uma letra só casaria em quase toda frase.
  CONSTRAINT blacklist_termos_normalizado
    CHECK (termo ~ '^[a-z0-9]+( [a-z0-9]+)*$' AND length(termo) > 1)
);
CREATE INDEX blacklist_termos_tenant_idx ON blacklist_termos (tenant_id);

COMMENT ON TABLE blacklist_termos IS
  'D63: termos que, numa resposta, disparam uma ação. Por cliente: nasce com a
   lista padrão do produto e o cliente edita. `exige_uma_de` preenchido = o termo
   só vale com uma dessas palavras nas TRÊS seguintes (a trava do D48).';

CREATE TABLE blacklist_dominios (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL DEFAULT privado.tenant_padrao() REFERENCES tenants(id) ON DELETE CASCADE,
  dominio    text NOT NULL,
  nota       text,
  ativo      boolean NOT NULL DEFAULT true,
  criado_em  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT blacklist_dominios_tenant_id_uk UNIQUE (tenant_id, id),
  CONSTRAINT blacklist_dominios_dominio_uk UNIQUE (tenant_id, dominio),
  CONSTRAINT blacklist_dominios_formato
    CHECK (dominio ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
);
CREATE INDEX blacklist_dominios_tenant_idx ON blacklist_dominios (tenant_id);

COMMENT ON TABLE blacklist_dominios IS
  'D63: domínio de e-mail que nunca recebe nada deste cliente. Vale para o
   domínio e os subdomínios. Lido por esta_suprimido, então vale no roteador e
   no despacho (invariante 2).';

-- ---------------------------------------------------------------------------
-- Normalização: um lugar só (D32)
-- ---------------------------------------------------------------------------

-- A tela manda o que a pessoa digitou. Quem decide a forma comparável é a
-- mesma função que normaliza a resposta — duas normalizações divergentes
-- seriam um termo que nunca casa, e "nunca casa" não dá erro.
--
-- DEFINER porque quem grava é a tela, como `authenticated`, e o normalizador
-- do D48 não é chamável por ela — de propósito: ele mora em `privado`.
CREATE FUNCTION privado.normalizar_blacklist_termo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
BEGIN
  NEW.termo := btrim(privado.normalizar_resposta(NEW.termo));
  IF NEW.exige_uma_de IS NOT NULL THEN
    SELECT array_agg(DISTINCT p ORDER BY p) INTO NEW.exige_uma_de
      FROM (SELECT btrim(privado.normalizar_resposta(c)) AS p
              FROM unnest(NEW.exige_uma_de) c) x
     WHERE p <> '';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER blacklist_termos_normaliza
  BEFORE INSERT OR UPDATE OF termo, exige_uma_de ON blacklist_termos
  FOR EACH ROW EXECUTE FUNCTION privado.normalizar_blacklist_termo();

-- Domínio: minúsculo, sem espaço, sem a arroba que quem cola costuma trazer.
CREATE FUNCTION privado.normalizar_blacklist_dominio() RETURNS trigger
LANGUAGE plpgsql SET search_path = public, privado AS $$
BEGIN
  NEW.dominio := lower(btrim(NEW.dominio));
  NEW.dominio := regexp_replace(NEW.dominio, '^.*@', '');
  RETURN NEW;
END;
$$;

CREATE TRIGGER blacklist_dominios_normaliza
  BEFORE INSERT OR UPDATE OF dominio ON blacklist_dominios
  FOR EACH ROW EXECUTE FUNCTION privado.normalizar_blacklist_dominio();

-- ---------------------------------------------------------------------------
-- O padrão que todo cliente recebe
-- ---------------------------------------------------------------------------

-- As duas listas do produto, e três termos de endereço errado. Recusa entra
-- como `suprimir`: é a decisão do D63, e o cliente que discordar troca a ação
-- termo a termo na tela. `nao quero` existe nas duas listas com contextos
-- diferentes; aqui vira um termo só, com a UNIÃO dos contextos — os dois
-- fecham a frase do mesmo lado.
CREATE FUNCTION privado.semear_blacklist(p_tenant uuid) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_n integer;
BEGIN
  WITH padrao AS (
    SELECT o.termo, o.exige_uma_de, 'suprimir'::acao_blacklist AS acao, o.nota
      FROM opt_out_termos o
    UNION ALL
    SELECT r.termo, r.exige_uma_de, 'suprimir'::acao_blacklist,
           'recusa, que suprime desde o D63 — ' || r.nota
      FROM recusa_termos r
    UNION ALL
    SELECT v.termo, NULL::text[], 'identidade_invalida'::acao_blacklist, v.nota
      FROM (VALUES
        ('numero errado', 'O endereço não é desta pessoa. Fato sobre o endereço, não vontade.'),
        ('pessoa errada', 'Idem.'),
        ('nao conheco essa pessoa', 'Idem, na forma mais comum de quem herdou o número.')
      ) v(termo, nota)
  )
  INSERT INTO blacklist_termos (tenant_id, termo, exige_uma_de, acao, nota, origem)
  SELECT p_tenant, p.termo,
         -- Termo que vale sozinho em alguma das listas vale sozinho aqui.
         CASE WHEN bool_or(p.exige_uma_de IS NULL) THEN NULL
              ELSE (SELECT array_agg(DISTINCT c ORDER BY c)
                      FROM padrao p2 CROSS JOIN LATERAL unnest(p2.exige_uma_de) c
                     WHERE p2.termo = p.termo) END,
         p.acao, string_agg(p.nota, ' / '), 'padrao'
    FROM padrao p
   GROUP BY p.termo, p.acao
  ON CONFLICT (tenant_id, termo) DO NOTHING;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

COMMENT ON FUNCTION privado.semear_blacklist IS
  'Copia a lista padrão do produto para a blacklist de um cliente. Não
   sobrescreve o que ele já tem (D63).';

CREATE FUNCTION privado.semear_blacklist_do_tenant() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
BEGIN
  PERFORM privado.semear_blacklist(NEW.id);
  RETURN NEW;
END;
$$;

-- Todo cliente nasce protegido: sem isto, o primeiro cliente criado depois
-- desta migration teria blacklist vazia, e "pare" passaria batido — o
-- silêncio que nenhum teste de unidade pega.
CREATE TRIGGER tenants_semeia_blacklist
  AFTER INSERT ON tenants
  FOR EACH ROW EXECUTE FUNCTION privado.semear_blacklist_do_tenant();

DO $$
DECLARE t uuid;
BEGIN
  FOR t IN SELECT id FROM tenants LOOP
    PERFORM privado.semear_blacklist(t);
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- O classificador
-- ---------------------------------------------------------------------------

-- O mesmo algoritmo do D48 (termo inteiro; contexto nas três palavras
-- seguintes), sobre a lista do CLIENTE. Devolve a regra, não um booleano: a
-- ação decide o que fazer, e o termo vai para o motivo da supressão.
CREATE FUNCTION privado.regra_da_resposta(p_tenant uuid, p_texto text)
RETURNS TABLE (regra_id uuid, termo text, acao acao_blacklist)
LANGUAGE plpgsql STABLE SET search_path = public, privado AS $$
DECLARE
  v_texto  text := privado.normalizar_resposta(p_texto);
  t        record;
  v_pos    integer;
  v_resto  text;
  v_janela text;
BEGIN
  IF btrim(v_texto) = '' THEN RETURN; END IF;

  FOR t IN
    SELECT b.id, b.termo, b.exige_uma_de, b.acao
      FROM blacklist_termos b
     WHERE b.tenant_id = p_tenant AND b.ativo
     ORDER BY CASE b.acao WHEN 'suprimir' THEN 0 WHEN 'identidade_invalida' THEN 1 ELSE 2 END,
              length(b.termo) DESC, b.termo
  LOOP
    v_pos := position(' ' || t.termo || ' ' IN v_texto);
    CONTINUE WHEN v_pos = 0;

    IF t.exige_uma_de IS NOT NULL THEN
      v_resto := substr(v_texto, v_pos + length(t.termo) + 1);
      SELECT coalesce(string_agg(w, ' ' ORDER BY i), '') INTO v_janela
        FROM unnest(string_to_array(btrim(v_resto), ' ')) WITH ORDINALITY AS u(w, i)
       WHERE i <= 3;
      CONTINUE WHEN NOT EXISTS (
        SELECT 1 FROM unnest(t.exige_uma_de) c
         WHERE position(' ' || c || ' ' IN ' ' || v_janela || ' ') > 0);
    END IF;

    regra_id := t.id; termo := t.termo; acao := t.acao;
    RETURN NEXT;
    RETURN;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION privado.regra_da_resposta IS
  'A regra da blacklist do cliente que a resposta dispara, ou nenhuma linha.
   suprimir > identidade_invalida > recusa; dentro da ação, o termo mais longo
   (D63).';

-- Os classificadores do D48 e do D58 liam as listas globais e perdem aqui o
-- último leitor: os dois gatilhos abaixo passam a chamar o de cima. Quem os
-- apaga é a migration seguinte, separada desta de propósito: no projeto,
-- apagar função espera a confirmação de uma pessoa, e o resto do D63 não
-- precisa esperar junto. Sem chamador, as duas não mudam comportamento nenhum.

-- ---------------------------------------------------------------------------
-- Os gatilhos de resposta
-- ---------------------------------------------------------------------------

-- Corpo do D48 com o classificador trocado e as duas ações novas. A trava de
-- tipo do D48 entra aqui também: o corpo antigo lia `->> 'texto'` de qualquer
-- coisa, e número virando "0" alimentaria uma decisão que não tem volta.
CREATE OR REPLACE FUNCTION privado.opt_out_no_texto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  r            record;
  v_contato    uuid;
  v_identidade uuid;
  v_canal      canal;
  v_valor      text;
BEGIN
  -- `texto` e a chave que os adapters preenchem quando o provedor entrega o
  -- corpo da mensagem. Provedor que nao entrega (SMS hoje nao tem webhook de
  -- entrada) simplesmente nao aciona isto — e nao adianta fingir que aciona.
  IF jsonb_typeof(NEW.payload -> 'texto') IS DISTINCT FROM 'string' THEN RETURN NEW; END IF;

  SELECT * INTO r FROM privado.regra_da_resposta(NEW.tenant_id, NEW.payload ->> 'texto');
  -- `recusa` encerra o ciclo e nao suprime: a cadencia ja acabou pela
  -- invariante 4, e o gatilho de qualificacao e quem deixa o card onde esta.
  IF r.regra_id IS NULL OR r.acao = 'recusa' THEN RETURN NEW; END IF;

  SELECT e.contact_id, m.contact_identity_id, m.canal
    INTO v_contato, v_identidade, v_canal
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = NEW.message_id;
  IF v_contato IS NULL THEN RETURN NEW; END IF;

  IF r.acao = 'suprimir' THEN
    -- A pessoa toda, em todo canal: quem pede para parar nao esta pedindo para
    -- parar so no WhatsApp. E o `motivo` carrega o termo, para a linha poder
    -- ser auditada depois sem ir atras do evento.
    IF NOT EXISTS (SELECT 1 FROM suppression s
                    WHERE s.tenant_id = NEW.tenant_id
                      AND s.contact_id = v_contato AND s.canal IS NULL) THEN
      INSERT INTO suppression (tenant_id, contact_id, motivo)
      VALUES (NEW.tenant_id, v_contato,
              'blacklist na resposta (termo: ' || r.termo || ')');
    END IF;
    RETURN NEW;
  END IF;

  -- identidade_invalida: o caminho do D49. Duas travas, porque cobrem janelas
  -- diferentes — `valida = false` decide o roteamento futuro, a supressao do
  -- endereco barra a mensagem que ja esta pendente.
  SELECT ci.valor_norm INTO v_valor FROM contact_identities ci WHERE ci.id = v_identidade;
  IF v_valor IS NULL THEN RETURN NEW; END IF;

  UPDATE contact_identities SET valida = false WHERE id = v_identidade;

  IF NOT EXISTS (SELECT 1 FROM suppression s
                  WHERE s.tenant_id = NEW.tenant_id
                    AND s.canal = v_canal AND s.valor_norm = v_valor) THEN
    INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
    VALUES (NEW.tenant_id, v_canal, v_valor,
            'blacklist na resposta: endereço errado (termo: ' || r.termo || ')');
  END IF;

  -- O CRM ouve que o endereco e ruim — nao que a pessoa pediu para sair.
  INSERT INTO outbox (tenant_id, contact_id, destino, fato, payload)
  VALUES (NEW.tenant_id, v_contato, 'crm', 'identidade_invalida',
          jsonb_build_object('contact_identity_id', v_identidade,
                             'canal', v_canal,
                             'motivo', 'resposta: ' || r.termo));

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION privado.opt_out_no_texto IS
  'A blacklist do cliente na resposta: suprimir a pessoa, invalidar o endereço,
   ou nada (recusa). O writeback sai de cada caminho (D45/D49/D63).';

-- Corpo do D58 com o classificador trocado. Casou QUALQUER regra da blacklist
-- — suprimir, endereço errado ou recusa —, o card não vira oportunidade.
CREATE OR REPLACE FUNCTION privado.qualifica_resposta()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
DECLARE v_texto text; v_contato uuid; v_deal uuid;
BEGIN
  -- Só string vira texto: objeto viraria "[object Object]" e número viraria
  -- "0". A mesma trava do D48, pelo mesmo motivo — o payload é do provedor.
  IF jsonb_typeof(NEW.payload -> 'texto') <> 'string' THEN RETURN NEW; END IF;
  v_texto := NEW.payload ->> 'texto';

  -- Casou a blacklist do cliente: o gatilho anterior já fez o que a ação
  -- manda, e nenhuma das três é oportunidade. Recusa fica em `respondeu`;
  -- suprimido está em `perdido`, de onde automação não tira (D57).
  IF EXISTS (SELECT 1 FROM privado.regra_da_resposta(NEW.tenant_id, v_texto)) THEN
    RETURN NEW;
  END IF;

  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = NEW.message_id;
  IF v_contato IS NULL THEN RETURN NEW; END IF;

  SELECT d.id INTO v_deal FROM deals d
   WHERE d.tenant_id = NEW.tenant_id AND d.contact_id = v_contato
     AND d.pipeline_id = (SELECT id FROM pipelines
                           WHERE tenant_id = NEW.tenant_id AND padrao);
  IF v_deal IS NULL THEN RETURN NEW; END IF;

  -- `ia` e não `motor`: isto é JUÍZO, não fato mecânico. Hoje o juízo vem de
  -- uma lista de termos; amanhã pode vir de um modelo. O valor gravado não
  -- muda quando isso acontecer, e é esse o ponto — a linha do tempo do card
  -- continua dizendo "um classificador decidiu isto".
  PERFORM mover_deal(v_deal, 'oportunidade', 'ia',
                     'respondeu e não recusou');

  RETURN NEW;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Domínio bloqueado: dentro da pergunta que todo caminho já faz
-- ---------------------------------------------------------------------------

-- Corpo atual de `esta_suprimido` com uma cláusula a mais. Ela casa o domínio
-- e os subdomínios (`a@x.com` e `a@mail.x.com` para `x.com`), e nunca um
-- domínio que só termina igual (`a@xx.com` não é `x.com`).
CREATE OR REPLACE FUNCTION privado.esta_suprimido(p_tenant uuid, p_contact_id uuid, p_canal canal, p_valor_norm text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM suppression s
    WHERE s.tenant_id = p_tenant AND (
         (s.contact_id = p_contact_id AND s.canal IS NULL)
      OR (s.contact_id = p_contact_id AND s.canal = p_canal)
      OR (s.canal = p_canal AND s.valor_norm = p_valor_norm))
  ) OR (
    p_canal = 'email' AND p_valor_norm IS NOT NULL AND EXISTS (
      SELECT 1 FROM blacklist_dominios d
       WHERE d.tenant_id = p_tenant AND d.ativo
         AND (p_valor_norm LIKE '%@' || d.dominio OR p_valor_norm LIKE '%.' || d.dominio))
  );
$function$;

-- ---------------------------------------------------------------------------
-- A tela testa uma frase sem reescrever o classificador (D55)
-- ---------------------------------------------------------------------------

-- "Esta frase dispara o quê?" é a pergunta de quem edita a lista. Responder em
-- TypeScript seria a segunda leitura da mesma regra, que diverge em silêncio;
-- a função pergunta ao classificador de verdade.
CREATE FUNCTION public.testar_blacklist(p_tenant uuid, p_texto text)
RETURNS TABLE (regra_id uuid, termo text, acao acao_blacklist)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, privado AS $$
BEGIN
  IF NOT privado.pertence_ao_tenant(p_tenant) THEN
    RAISE EXCEPTION 'sem acesso a este cliente' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY SELECT * FROM privado.regra_da_resposta(p_tenant, p_texto);
END;
$$;

-- ---------------------------------------------------------------------------
-- RLS: lê quem pertence, escreve quem administra
-- ---------------------------------------------------------------------------

ALTER TABLE blacklist_termos ENABLE ROW LEVEL SECURITY;
CREATE POLICY blacklist_termos_sel ON blacklist_termos FOR SELECT
  USING (privado.pertence_ao_tenant(tenant_id));
CREATE POLICY blacklist_termos_ins ON blacklist_termos FOR INSERT
  WITH CHECK (privado.pode_administrar(tenant_id));
CREATE POLICY blacklist_termos_upd ON blacklist_termos FOR UPDATE
  USING (privado.pode_administrar(tenant_id)) WITH CHECK (privado.pode_administrar(tenant_id));
CREATE POLICY blacklist_termos_del ON blacklist_termos FOR DELETE
  USING (privado.pode_administrar(tenant_id));

ALTER TABLE blacklist_dominios ENABLE ROW LEVEL SECURITY;
CREATE POLICY blacklist_dominios_sel ON blacklist_dominios FOR SELECT
  USING (privado.pertence_ao_tenant(tenant_id));
CREATE POLICY blacklist_dominios_ins ON blacklist_dominios FOR INSERT
  WITH CHECK (privado.pode_administrar(tenant_id));
CREATE POLICY blacklist_dominios_upd ON blacklist_dominios FOR UPDATE
  USING (privado.pode_administrar(tenant_id)) WITH CHECK (privado.pode_administrar(tenant_id));
CREATE POLICY blacklist_dominios_del ON blacklist_dominios FOR DELETE
  USING (privado.pode_administrar(tenant_id));

-- ---------------------------------------------------------------------------
-- Superfície (D19, D55)
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text; alvo text;
BEGIN
  FOREACH alvo IN ARRAY ARRAY[
    'privado.normalizar_blacklist_termo()',
    'privado.normalizar_blacklist_dominio()',
    'privado.semear_blacklist(uuid)',
    'privado.semear_blacklist_do_tenant()',
    'privado.regra_da_resposta(uuid, text)',
    'public.testar_blacklist(uuid, text)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', alvo);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', alvo);
    END IF;
    FOREACH papel IN ARRAY ARRAY['service_role','postgres'] LOOP
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I', alvo, papel);
      END IF;
    END LOOP;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.testar_blacklist(uuid, text) TO authenticated';
    EXECUTE 'GRANT SELECT, INSERT, DELETE ON blacklist_termos, blacklist_dominios TO authenticated';
  END IF;
  -- Quem não entrou não lê a lista de ninguém. O RLS já devolveria zero
  -- linhas; a revogação diz o mesmo sem depender dele.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON blacklist_termos, blacklist_dominios FROM anon';
  END IF;
END;
$$;

-- A grade: tabela nova nasce larga e não herda a estreitada (D59). O UPDATE é
-- por coluna — `tenant_id` e `origem` não são da tela —, e o resto mora no
-- corpo atual de `estreitar_escrita_do_cliente` (D62) com as duas linhas.
CREATE OR REPLACE FUNCTION privado.estreitar_escrita_do_cliente()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    RETURN;
  END IF;

  -- D54: por coluna onde a tela escreve.
  REVOKE UPDATE ON campaigns, enrollments, sender_accounts FROM authenticated;
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  GRANT UPDATE (apelido, quota_diaria, estado) ON sender_accounts TO authenticated;

  -- D62: a conta nasce pela tela com o que a tela preenche, e só. Com INSERT
  -- de tabela inteira dava para nascer com `credenciais_secret_id` apontando
  -- para o segredo de OUTRO cliente — o worker mandaria pela conta dele, o
  -- D59 na quarta tabela de credencial. E DELETE apagava em cascata as
  -- mensagens e os eventos da conta: história que é append-only (D62).
  REVOKE INSERT, DELETE ON sender_accounts FROM authenticated;
  GRANT INSERT (tenant_id, canal, provedor, identificador, apelido,
                tipo_permitido, quota_diaria, config)
    ON sender_accounts TO authenticated;

  -- D63: a blacklist é da tela, menos o dono da linha e a origem dela.
  REVOKE UPDATE ON blacklist_termos, blacklist_dominios FROM authenticated;
  GRANT UPDATE (termo, exige_uma_de, acao, nota, ativo) ON blacklist_termos TO authenticated;
  GRANT UPDATE (nota, ativo) ON blacklist_dominios TO authenticated;

  -- D54: as três do motor, leitura sim, escrita nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON messages, message_events, outbox FROM authenticated;

  -- D57: o funil. Renomear e reordenar estágio é da tela; mover card é de
  -- `mover_deal`, e sem esta revogação "porta única" seria convenção.
  REVOKE UPDATE ON deals FROM authenticated;
  REVOKE UPDATE, DELETE ON deal_activities FROM authenticated;

  -- D59, daqui para baixo.
  --
  -- As duas tabelas de credencial: a tela liga e desliga, e nada mais. Quem
  -- grava é a função DEFINER, que não usa privilégio do cliente.
  --
  -- O INSERT vai embora junto do UPDATE largo, e não é zelo a mais: com ele,
  -- dava para criar a linha com `credencial_secret_id` escolhido à mão,
  -- apontando para um segredo do Vault que não é desta conexão. Passar pela
  -- função é o que garante que o ponteiro nasce de `guardar_segredo`.
  REVOKE INSERT, UPDATE, DELETE ON ai_credentials, crm_connections FROM authenticated;
  GRANT UPDATE (ativo) ON ai_credentials TO authenticated;
  GRANT UPDATE (ativo) ON crm_connections TO authenticated;

  -- Servidor de provedor: nenhuma tela escreve. `salvar_servidor_provedor` é
  -- DEFINER, e `admin_secret_id` é ponteiro de Vault pelo mesmo motivo acima.
  REVOKE INSERT, UPDATE, DELETE ON provider_servers FROM authenticated;

  -- Catálogo é do produto, não do cliente. Nos três o RLS já recusa por falta
  -- de política de DML, e é justamente por isso que a revogação entra: confiar
  -- que "não tem política" é o mesmo que "não tem privilégio" é o D54 pela
  -- terceira vez. Quem lê continua lendo — `tem_adapter` e `campos` são o que
  -- a tela desenha.
  REVOKE INSERT, UPDATE, DELETE
      ON channel_provider_catalog, ai_provider_catalog, crm_provider_catalog
    FROM authenticated;
END;
$function$;

DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
