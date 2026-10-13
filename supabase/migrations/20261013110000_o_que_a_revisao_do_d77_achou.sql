-- O que a revisão do D77 achou (D77b).
--
-- A revisão adversarial do D77 rodou depois de ele já estar no projeto (o app
-- foi publicado pelo push antes da migration, e a migration entrou para fechar
-- a janela). Esta é a corretiva, e cada corpo parte do que está no projeto:
--
--   despachante     a fila travada que o D77 tirou do agendador continuava no
--                   gêmeo dele (D40): mensagem de campanha desligada entrava no
--                   lote, era segurada e voltava à cabeça da fila.
--   pool da prévia  a prévia é INVOKER, e `sender_accounts` só se lê
--                   administrando: o operador via "sem conta" sempre. Ela
--                   também ignorava a conta de e-mail escolhida pela campanha e
--                   tratava circuito aberto como conta que falta.
--   busca           qualquer termo com 4 dígitos casava telefones — um e-mail
--                   também.
--   fonte de CRM    os exemplos de valor ignorado sumiam na passada seguinte.
--   credenciais     a mescla da configuração não secreta valia também com chave
--                   nova, e guardava um endereço que a pessoa não via.

-- 1. Credenciais

CREATE OR REPLACE FUNCTION public.salvar_credencial_ia(p_tenant uuid, p_nome text, p_provedor text, p_modelo text, p_campos jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  v_id      uuid;
  v_antigo  uuid;
  v_segredo uuid;
  v_config  jsonb;
  v_secreto jsonb;
  v_ruim    text;
  -- D77
  v_prov_antigo text;
  v_cfg_antigo  jsonb;
  v_reusa       boolean;
  v_e_segredo   boolean;
BEGIN
  -- SECURITY DEFINER pula a RLS de ai_credentials, então a checagem que a
  -- política faria é feita aqui. Mesma razão das duas funções do D26.
  IF NOT privado.pode_administrar(p_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente configura provedor de IA'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM ai_provider_catalog WHERE slug = p_provedor) THEN
    RAISE EXCEPTION 'provedor de IA desconhecido: %', p_provedor
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_modelo IS NULL OR length(trim(p_modelo)) = 0 THEN
    RAISE EXCEPTION 'credencial sem modelo não serve para chamar nada'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- O catálogo manda: campo que o provedor não declara não entra, nem no Vault
  -- nem em config. Sem isto, um erro de digitação na tela viraria uma chave
  -- guardada com nome que ninguém vai ler depois.
  SELECT k INTO v_ruim
    FROM jsonb_object_keys(coalesce(p_campos, '{}'::jsonb)) k
   WHERE NOT EXISTS (
     SELECT 1 FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = p_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe no provedor %', v_ruim, p_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT id, chave_secret_id, provedor, config
    INTO v_id, v_antigo, v_prov_antigo, v_cfg_antigo
    FROM ai_credentials WHERE tenant_id = p_tenant AND nome = p_nome;

  -- Separação pelo catálogo, não pela tela.
  SELECT
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE NOT seg), '{}'::jsonb),
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE seg AND length(trim(v)) > 0), '{}'::jsonb)
    INTO v_config, v_secreto
    FROM (
      SELECT e.key AS k, e.value #>> '{}' AS v,
             (c.campo ->> 'segredo')::boolean AS seg
        FROM jsonb_each(coalesce(p_campos, '{}'::jsonb)) e
        JOIN LATERAL (
          SELECT x AS campo FROM ai_provider_catalog p,
                 jsonb_array_elements(p.campos) x
           WHERE p.slug = p_provedor AND x ->> 'chave' = e.key
        ) c ON true
    ) s;

  -- D77: campo não secreto que a tela não mandou fica como estava. O
  -- formulário abre vazio, e editar só o modelo apagava em silêncio a
  -- organização da OpenAI, o base_url do proxy e a organização do Pipefy.
  -- Mandar o campo vazio continua limpando. Trocar de provedor não herda
  -- nada: a configuração de um não serve ao outro.
  --
  -- D77b: e só quando a chave também fica. Com chave nova, a tela manda o
  -- formulário inteiro (que abre preenchido com o que está guardado): herdar
  -- aqui guardava um base_url que a pessoa não via, e a lista de modelos
  -- validava a chave contra um endereço enquanto o motor a mandava para outro.
  IF v_id IS NOT NULL AND v_prov_antigo = p_provedor AND v_secreto = '{}'::jsonb THEN
    v_config := coalesce(v_cfg_antigo, '{}'::jsonb) || v_config;
  END IF;

  -- D77: a chave guardada foi dada a UM destino — o provedor e os campos que
  -- o catálogo marca como `destino` (o endereço, o domínio, o data center).
  -- Reaproveitá-la em branco depois de trocar qualquer um deles mandava a
  -- chave da Anthropic para a OpenAI, ou para o endereço recém-digitado, com
  -- "Credencial atualizada." na tela. E trocar uma das chaves pede as
  -- outras junto: o segredo é um objeto só, e a que não veio sumiria dele.
  v_reusa := v_antigo IS NOT NULL
        AND v_prov_antigo = p_provedor
        AND v_secreto = '{}'::jsonb
        AND NOT EXISTS (
              SELECT 1 FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
               WHERE p.slug = p_provedor AND coalesce((c ->> 'destino')::boolean, false)
                 AND NOT privado.mesmo_destino(v_config ->> (c ->> 'chave'),
                                               v_cfg_antigo ->> (c ->> 'chave')));

  -- Campo obrigatório em branco só passa quando já existe valor guardado: na
  -- edição a chave volta vazia da tela, porque segredo não é legível, e
  -- reenviar vazio não pode apagar a credencial de um agente que está rodando.
  SELECT c ->> 'rotulo', coalesce((c ->> 'segredo')::boolean, false)
    INTO v_ruim, v_e_segredo
    FROM ai_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(CASE WHEN (c ->> 'segredo')::boolean
                                   THEN v_secreto ->> (c ->> 'chave')
                                   ELSE v_config ->> (c ->> 'chave') END, ''))) = 0
     AND NOT ((c ->> 'segredo')::boolean AND v_reusa)
   LIMIT 1;

  -- D77: a recusa diz POR QUE a chave guardada não vale mais.
  IF v_ruim IS NOT NULL AND v_e_segredo AND v_antigo IS NOT NULL THEN
    RAISE EXCEPTION '%', CASE
        WHEN v_secreto <> '{}'::jsonb
          THEN 'trocar uma das chaves pede as outras junto: ' || v_ruim
        WHEN v_prov_antigo IS DISTINCT FROM p_provedor
          THEN 'trocar o provedor pede a chave nova — a guardada é do ' || v_prov_antigo || ': ' || v_ruim
        ELSE 'mudar o endereço pede a chave de novo — a guardada foi dada para o anterior: ' || v_ruim
      END USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo obrigatório em branco: %', v_ruim
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Um segredo só por credencial: o objeto inteiro vai junto, como em
  -- `salvar_credencial_remetente`. Provedor que pede duas chaves não vira duas
  -- linhas no Vault para depois desencontrarem.
  IF v_secreto <> '{}'::jsonb THEN
    v_segredo := privado.guardar_segredo(
      'ia:' || p_provedor || ':' || p_tenant::text || ':' || gen_random_uuid()::text,
      v_secreto::text);
  ELSIF v_reusa THEN
    v_segredo := v_antigo;
  ELSE
    v_segredo := NULL;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO ai_credentials (tenant_id, nome, provedor, modelo, chave_secret_id, config)
    VALUES (p_tenant, p_nome, p_provedor, trim(p_modelo), v_segredo, v_config)
    RETURNING id INTO v_id;
  ELSE
    UPDATE ai_credentials
       SET provedor = p_provedor, modelo = trim(p_modelo),
           chave_secret_id = v_segredo, config = v_config
     WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.salvar_credencial_crm(p_tenant uuid, p_nome text, p_provedor text, p_campos jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  v_id      uuid;
  v_antigo  uuid;
  v_segredo uuid;
  v_config  jsonb;
  v_secreto jsonb;
  v_ruim    text;
  -- D77
  v_prov_antigo text;
  v_cfg_antigo  jsonb;
  v_reusa       boolean;
  v_e_segredo   boolean;
BEGIN
  -- SECURITY DEFINER pula a RLS de crm_connections, então a checagem que a
  -- política faria é feita aqui. Mesma razão das outras três funções de
  -- credencial.
  IF NOT privado.pode_administrar(p_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente vincula plataforma'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM crm_provider_catalog WHERE slug = p_provedor) THEN
    RAISE EXCEPTION 'plataforma desconhecida: %', p_provedor
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_nome IS NULL OR length(trim(p_nome)) = 0 THEN
    RAISE EXCEPTION 'conexão sem nome não dá para escolher depois'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Campo que o provedor não declara não entra, nem no Vault nem em config.
  SELECT k INTO v_ruim
    FROM jsonb_object_keys(coalesce(p_campos, '{}'::jsonb)) k
   WHERE NOT EXISTS (
     SELECT 1 FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = p_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe na plataforma %', v_ruim, p_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT id, credencial_secret_id, provedor, config
    INTO v_id, v_antigo, v_prov_antigo, v_cfg_antigo
    FROM crm_connections WHERE tenant_id = p_tenant AND nome = trim(p_nome);

  -- Separação pelo catálogo, não pela tela.
  SELECT
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE NOT seg), '{}'::jsonb),
    coalesce(jsonb_object_agg(k, v) FILTER (WHERE seg AND length(trim(v)) > 0), '{}'::jsonb)
    INTO v_config, v_secreto
    FROM (
      SELECT e.key AS k, e.value #>> '{}' AS v,
             (c.campo ->> 'segredo')::boolean AS seg
        FROM jsonb_each(coalesce(p_campos, '{}'::jsonb)) e
        JOIN LATERAL (
          SELECT x AS campo FROM crm_provider_catalog p,
                 jsonb_array_elements(p.campos) x
           WHERE p.slug = p_provedor AND x ->> 'chave' = e.key
        ) c ON true
    ) s;

  -- D77: campo não secreto que a tela não mandou fica como estava. O
  -- formulário abre vazio, e editar só o modelo apagava em silêncio a
  -- organização da OpenAI, o base_url do proxy e a organização do Pipefy.
  -- Mandar o campo vazio continua limpando. Trocar de provedor não herda
  -- nada: a configuração de um não serve ao outro.
  --
  -- D77b: e só quando a chave também fica. Com chave nova, a tela manda o
  -- formulário inteiro (que abre preenchido com o que está guardado): herdar
  -- aqui guardava um base_url que a pessoa não via, e a lista de modelos
  -- validava a chave contra um endereço enquanto o motor a mandava para outro.
  IF v_id IS NOT NULL AND v_prov_antigo = p_provedor AND v_secreto = '{}'::jsonb THEN
    v_config := coalesce(v_cfg_antigo, '{}'::jsonb) || v_config;
  END IF;

  -- D77: a chave guardada foi dada a UM destino — o provedor e os campos que
  -- o catálogo marca como `destino` (o endereço, o domínio, o data center).
  -- Reaproveitá-la em branco depois de trocar qualquer um deles mandava a
  -- chave da Anthropic para a OpenAI, ou para o endereço recém-digitado, com
  -- "Credencial atualizada." na tela. E trocar uma das chaves pede as
  -- outras junto: o segredo é um objeto só, e a que não veio sumiria dele.
  v_reusa := v_antigo IS NOT NULL
        AND v_prov_antigo = p_provedor
        AND v_secreto = '{}'::jsonb
        AND NOT EXISTS (
              SELECT 1 FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
               WHERE p.slug = p_provedor AND coalesce((c ->> 'destino')::boolean, false)
                 AND NOT privado.mesmo_destino(v_config ->> (c ->> 'chave'),
                                               v_cfg_antigo ->> (c ->> 'chave')));

  -- Campo obrigatório em branco só passa quando já existe valor guardado: na
  -- edição o segredo volta vazio da tela, porque segredo não é legível, e
  -- reenviar vazio não pode apagar a credencial de uma conexão em uso.
  SELECT c ->> 'rotulo', coalesce((c ->> 'segredo')::boolean, false)
    INTO v_ruim, v_e_segredo
    FROM crm_provider_catalog p, jsonb_array_elements(p.campos) c
   WHERE p.slug = p_provedor
     AND (c ->> 'obrigatorio')::boolean
     AND length(trim(coalesce(CASE WHEN (c ->> 'segredo')::boolean
                                   THEN v_secreto ->> (c ->> 'chave')
                                   ELSE v_config ->> (c ->> 'chave') END, ''))) = 0
     AND NOT ((c ->> 'segredo')::boolean AND v_reusa)
   LIMIT 1;

  -- D77: a recusa diz POR QUE a chave guardada não vale mais.
  IF v_ruim IS NOT NULL AND v_e_segredo AND v_antigo IS NOT NULL THEN
    RAISE EXCEPTION '%', CASE
        WHEN v_secreto <> '{}'::jsonb
          THEN 'trocar uma das chaves pede as outras junto: ' || v_ruim
        WHEN v_prov_antigo IS DISTINCT FROM p_provedor
          THEN 'trocar o provedor pede a chave nova — a guardada é do ' || v_prov_antigo || ': ' || v_ruim
        ELSE 'mudar o endereço pede a chave de novo — a guardada foi dada para o anterior: ' || v_ruim
      END USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'campo obrigatório em branco: %', v_ruim
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Um segredo só por conexão, com o objeto inteiro junto. Salesforce e Zoho
  -- pedem duas chaves cada; duas linhas no Vault desencontram na primeira
  -- rotação de credencial.
  IF v_secreto <> '{}'::jsonb THEN
    v_segredo := privado.guardar_segredo(
      'crm:' || p_provedor || ':' || p_tenant::text || ':' || gen_random_uuid()::text,
      v_secreto::text);
  ELSIF v_reusa THEN
    v_segredo := v_antigo;
  ELSE
    v_segredo := NULL;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO crm_connections (tenant_id, nome, provedor, credencial_secret_id, config)
    VALUES (p_tenant, trim(p_nome), p_provedor, v_segredo, v_config)
    RETURNING id INTO v_id;
  ELSE
    UPDATE crm_connections
       SET provedor = p_provedor, credencial_secret_id = v_segredo, config = v_config
     WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$function$;

-- 2. Despachante

CREATE OR REPLACE FUNCTION public.reivindicar_pendentes(p_limite integer DEFAULT 50, p_lease interval DEFAULT '00:05:00'::interval)
 RETURNS TABLE(message_id uuid, tenant_id uuid, canal canal, destino text, conteudo text, sender_id uuid, sender_ident text, campanha_tipo tipo_campanha)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE
  m         record;
  candidato sender_accounts%ROWTYPE;
  v_novo    uuid;
BEGIN
  -- Circuito vencido fecha na borda do lote (D37).
  UPDATE sender_accounts
     SET estado = 'ativo', falhas_consecutivas = 0, circuito_aberto_ate = NULL
   WHERE estado = 'circuito_aberto'
     AND circuito_aberto_ate IS NOT NULL
     AND circuito_aberto_ate <= now();

  FOR m IN
    WITH alvo AS (
      SELECT msg.id FROM messages msg
       WHERE msg.status = 'pendente'
         AND (msg.reivindicada_em IS NULL OR msg.reivindicada_em < now() - p_lease)
         -- D77b: a parada temporária fica fora do lote, como no agendador
         -- (D77, D40). Antes ela entrava, era segurada e voltava à cabeça da
         -- fila: cem mensagens de uma campanha desligada ocupavam o LIMIT de
         -- todas as batidas, e nada de nenhum cliente saía.
         AND NOT EXISTS (
               SELECT 1 FROM enrollments e0 JOIN campaigns c0 ON c0.id = e0.campaign_id
                WHERE e0.id = msg.enrollment_id AND (e0.status = 'pausado' OR NOT c0.ativa))
       -- D77b: a que nunca foi olhada antes da que já esperou uma vez — a
       -- retida por falta de conta não volta à cabeça da fila.
       ORDER BY msg.reivindicada_em NULLS FIRST, msg.criado_em
       LIMIT p_limite FOR UPDATE SKIP LOCKED
    ), marcada AS (
      UPDATE messages msg SET reivindicada_em = now() FROM alvo WHERE msg.id = alvo.id
      RETURNING msg.*
    )
    SELECT msg.id, msg.tenant_id, msg.canal, msg.conteudo, msg.sender_account_id,
           ci.valor AS destino, ci.valor_norm, e.contact_id, c.tipo AS campanha_tipo,
           c.id AS campaign_id, c.remetente_email_id,
           e.status AS estado_enrollment, e.motivo_encerramento, c.ativa AS campanha_ativa,
           sa.estado AS estado_atual, sa.identificador AS ident_atual,
           cat.tem_adapter, cat.ativo AS provedor_ativo,
           -- D69: a mensagem do agente, e se ela ainda responde à última.
           msg.rascunho_id, ra.resposta_em,
           (msg.rascunho_id IS NOT NULL AND NOT EXISTS (
              SELECT 1 FROM message_events me2
                JOIN messages m2    ON m2.id = me2.message_id
                JOIN enrollments e2 ON e2.id = m2.enrollment_id
               WHERE me2.tenant_id = msg.tenant_id AND e2.contact_id = e.contact_id
                 AND me2.tipo = 'respondido' AND me2.ocorrido_em > me0.ocorrido_em)) AS responde_a_ultima,
           -- D76: o agente que escreveu ainda responde nesta campanha?
           (msg.rascunho_id IS NULL OR EXISTS (
              SELECT 1 FROM privado.agente_que_responde(msg.tenant_id, c.id, msg.canal) q
                JOIN agents ag ON ag.tenant_id = msg.tenant_id AND ag.id = q.agent_id AND ag.ativo
                              AND (ag.canal IS NULL OR ag.canal = msg.canal)
               WHERE q.agent_id = ra.agent_id)) AS agente_responde
      FROM marcada msg
      JOIN contact_identities ci ON ci.id = msg.contact_identity_id
      JOIN enrollments        e  ON e.id = msg.enrollment_id
      JOIN campaigns          c  ON c.id = e.campaign_id
      JOIN sender_accounts    sa ON sa.id = msg.sender_account_id
      JOIN channel_provider_catalog cat ON cat.slug = sa.provedor
      LEFT JOIN rascunhos     ra ON ra.id = msg.rascunho_id
      LEFT JOIN message_events me0 ON me0.id = ra.message_event_id
  LOOP
    -- 1. Supressão, acima de tudo (D39).
    IF esta_suprimido(m.tenant_id, m.contact_id, m.canal, m.valor_norm) THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      IF m.rascunho_id IS NOT NULL THEN
        PERFORM privado.devolver_rascunho(m.rascunho_id, 'o contato foi suprimido antes do envio');
      END IF;
      CONTINUE;
    END IF;

    -- 2. Parada definitiva: a cadência acabou por um motivo que significa
    -- "pare de falar com esta pessoa". `fim_dos_passos` não é um deles — é o
    -- encerramento normal, e acontece na MESMA passada que cria a última
    -- mensagem (D40).
    --
    -- D69: o critério positivo, e só um. Encerrada por `resposta`, passa a
    -- mensagem do agente que responde à ÚLTIMA resposta da pessoa. Mensagem de
    -- cadência nunca tem `rascunho_id` e segue cancelada.
    IF m.estado_enrollment = 'encerrado'
       AND m.motivo_encerramento IS DISTINCT FROM 'fim_dos_passos'
       AND NOT (m.rascunho_id IS NOT NULL AND m.motivo_encerramento = 'resposta' AND m.responde_a_ultima) THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      IF m.rascunho_id IS NOT NULL THEN
        PERFORM privado.devolver_rascunho(m.rascunho_id, CASE
          WHEN NOT m.responde_a_ultima THEN 'a pessoa respondeu de novo antes do envio'
          ELSE 'a inscrição foi encerrada por ' || coalesce(m.motivo_encerramento::text, '?') END);
      END IF;
      CONTINUE;
    END IF;

    -- D76: o freio alcança a mensagem que esperava a conta voltar. Desligar o
    -- agente, pôr "ninguém" ou trocar quem responde devolve o texto a uma
    -- pessoa — cancelar aqui não perde nada, porque a mensagem do agente não é
    -- recriável de qualquer jeito (`UNIQUE (rascunho_id)`).
    IF m.rascunho_id IS NOT NULL AND NOT m.agente_responde THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      PERFORM privado.devolver_rascunho(m.rascunho_id,
        'o agente que escreveu deixou de responder nesta campanha antes do envio');
      CONTINUE;
    END IF;

    -- D69: a janela de 24h, conferida de novo na saída — a mensagem pode ter
    -- esperado a conta voltar.
    IF m.rascunho_id IS NOT NULL AND m.canal IN ('whatsapp', 'instagram')
       AND m.resposta_em < now() - interval '24 hours' THEN
      UPDATE messages SET status = 'cancelado', reivindicada_em = NULL WHERE id = m.id;
      PERFORM privado.devolver_rascunho(m.rascunho_id, 'passou a janela de 24h esperando a conta despachar');
      CONTINUE;
    END IF;

    -- 3. Parada temporária: pausa e campanha desligada voltam atrás. Segura a
    -- mensagem em vez de cancelar — cancelada não é recriável, porque a chave
    -- única `(enrollment_id, step_id)` impede repetir o passo.
    IF m.estado_enrollment = 'pausado' OR NOT m.campanha_ativa THEN
      UPDATE messages SET reivindicada_em = NULL WHERE id = m.id;
      CONTINUE;
    END IF;

    -- 4. Quota NÃO entra: a reserva desta mensagem já foi paga na criação.
    -- E-mail com provedor escolhido pela campanha só sai por ele: trocar o
    -- provedor na tela vale para o que já está na fila, não só para o que
    -- ainda vai nascer (D62) — é o D37 aplicado à escolha da pessoa. A
    -- mensagem do agente sai pela conta que conversa, sempre (D69).
    IF m.estado_atual = 'ativo' AND m.tem_adapter AND m.provedor_ativo
       AND (m.rascunho_id IS NOT NULL OR m.canal <> 'email' OR m.remetente_email_id IS NULL
            OR m.sender_account_id = m.remetente_email_id) THEN
      message_id := m.id; tenant_id := m.tenant_id; canal := m.canal;
      destino := m.destino; conteudo := m.conteudo;
      sender_id := m.sender_account_id; sender_ident := m.ident_atual;
      campanha_tipo := m.campanha_tipo;
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- D69: a mensagem do agente não troca de conta. Outro número escrevendo
    -- no meio da conversa é outra conversa; ela espera, e a janela decide.
    IF m.rascunho_id IS NOT NULL THEN
      -- D77b: elegível já na próxima batida, mas atrás das que nunca foram
      -- olhadas (a ordem é por `reivindicada_em`, nulos primeiro).
      UPDATE messages SET reivindicada_em = now() - p_lease WHERE id = m.id;
      CONTINUE;
    END IF;

    -- 5. Remetente não despacha mais: procura outro no mesmo pool (D37).
    v_novo := NULL;
    FOR candidato IN
      SELECT * FROM privado.remetentes_da_campanha(m.tenant_id, m.campaign_id, m.canal)
    LOOP
      IF candidato.id <> m.sender_account_id AND reservar_envio(candidato.id) THEN
        v_novo := candidato.id;
        EXIT;
      END IF;
    END LOOP;

    IF v_novo IS NULL THEN
      -- D77b: idem — sem conta no pool, espera atrás das novas.
      UPDATE messages SET reivindicada_em = now() - p_lease WHERE id = m.id;
      CONTINUE;
    END IF;

    -- A reserva do remetente antigo não volta: furaria a invariante 3 (D37).
    UPDATE messages SET sender_account_id = v_novo WHERE id = m.id;

    SELECT * INTO candidato FROM sender_accounts WHERE id = v_novo;
    message_id := m.id; tenant_id := m.tenant_id; canal := m.canal;
    destino := m.destino; conteudo := m.conteudo;
    sender_id := v_novo; sender_ident := candidato.identificador;
    campanha_tipo := m.campanha_tipo;
    RETURN NEXT;
  END LOOP;
END;
$function$;

-- 3. O pool da campanha

-- D77b: "esta campanha tem para onde mandar neste canal?" — a pergunta da
-- prévia de inscrição, feita por quem tem direito de ver a resposta. A prévia
-- é INVOKER e `sender_accounts` só se lê administrando: para o operador, a
-- pergunta direta respondia "sem conta" sempre. DEFINER, com o papel
-- conferido aqui e a resposta reduzida a uma palavra — nenhuma linha sai.
--
-- O pool é o de `privado.remetentes_da_campanha` sem a quota de hoje (acabar a
-- quota é amanhã): tipo da campanha, provedor com adapter e ativo, e no e-mail
-- a conta que a campanha escolheu (D62). Circuito aberto CONTA — ele fecha
-- sozinho, e o agendador espera até lá.
--
--   ok         há conta ativa (ou de circuito aberto) no pool
--   desligada  as contas do pool existem e estão desligadas (ou a escolhida)
--   sem_conta  não há conta desse tipo neste canal
--   NULL       quem pergunta não opera este cliente
CREATE FUNCTION privado.pool_da_campanha(p_tenant uuid, p_campaign_id uuid, p_canal canal)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'privado'
AS $$
  WITH contas AS (
    SELECT sa.estado
      FROM campaigns c
      JOIN sender_accounts sa ON sa.tenant_id = c.tenant_id AND sa.canal = p_canal
                             AND sa.tipo_permitido = c.tipo AND sa.removido_em IS NULL
      JOIN channel_provider_catalog p ON p.slug = sa.provedor AND p.tem_adapter AND p.ativo
     WHERE c.tenant_id = p_tenant AND c.id = p_campaign_id
       AND (p_canal <> 'email' OR c.remetente_email_id IS NULL OR sa.id = c.remetente_email_id)
  )
  SELECT CASE
           WHEN NOT privado.pode_operar(p_tenant) THEN NULL
           WHEN EXISTS (SELECT 1 FROM contas WHERE estado IN ('ativo', 'circuito_aberto')) THEN 'ok'
           WHEN EXISTS (SELECT 1 FROM contas) THEN 'desligada'
           ELSE 'sem_conta'
         END
$$;
REVOKE ALL ON FUNCTION privado.pool_da_campanha(uuid, uuid, canal) FROM PUBLIC;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION privado.pool_da_campanha(uuid, uuid, canal) FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION privado.pool_da_campanha(uuid, uuid, canal) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION privado.pool_da_campanha(uuid, uuid, canal) TO service_role;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.prever_inscricao(p_tenant uuid, p_campaign_id uuid, p_flow_version_id uuid, p_contatos uuid[])
 RETURNS TABLE(contact_id uuid, nome text, acao text, canais_alcancaveis canal[], problema text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'privado'
AS $function$
  WITH camp AS (
    SELECT c.canais_habilitados, c.ativa, c.tipo
      FROM campaigns c
     WHERE c.tenant_id = p_tenant AND c.id = p_campaign_id
  ),
  -- Os canais que esta versão de flow realmente usa.
  passos AS (
    SELECT DISTINCT fs.canal
      FROM flow_steps fs
     WHERE fs.flow_version_id = p_flow_version_id
  ),
  -- O que sobra depois de cruzar flow com campanha. Vazio aqui é problema de
  -- configuração, não de contato: nenhum passo sairia para ninguém.
  uteis AS (
    SELECT coalesce(array_agg(DISTINCT p.canal), '{}'::canal[]) AS canais
      FROM passos p
      JOIN camp c ON p.canal = ANY (c.canais_habilitados)
  ),
  alvo AS (
    SELECT DISTINCT unnest(coalesce(p_contatos, '{}'::uuid[])) AS id
  ),
  -- Alcançável é identidade válida, num canal que o flow usa, e que não está
  -- suprimida. As três coisas — uma só já enganaria.
  alcance AS (
    SELECT a.id,
           -- O FILTER não é zelo: sem ele a junção externa sem par produz
           -- `{NULL}`, `array_length` devolve 1, e "não tem canal nenhum"
           -- passa por "tem um canal". Era o bug que dizia `inscrever` para
           -- quem o motor encerraria sem mandar nada.
           coalesce(array_agg(DISTINCT ci.canal) FILTER (WHERE ci.canal IS NOT NULL),
                    '{}'::canal[]) AS canais
      FROM alvo a
      -- `uteis` entra por junção, não por subconsulta escalar: dentro de
      -- `= ANY (...)` um sub-SELECT é comparado linha a linha, e a linha aqui
      -- é um array inteiro — daí `operator does not exist: canal = canal[]`.
      CROSS JOIN uteis u
      LEFT JOIN contact_identities ci
        ON ci.tenant_id = p_tenant AND ci.contact_id = a.id AND ci.valida
       AND ci.canal = ANY (u.canais)
       AND NOT esta_suprimido(p_tenant, a.id, ci.canal, ci.valor_norm)
     GROUP BY a.id
  )
  SELECT a.id,
         c.nome,
         CASE
           WHEN c.id IS NULL THEN 'desconhecido'
           WHEN esta_suprimido(p_tenant, a.id, NULL, NULL) THEN 'suprimido'
           WHEN EXISTS (
             SELECT 1 FROM enrollments e
              WHERE e.tenant_id = p_tenant AND e.contact_id = a.id
                AND e.campaign_id = p_campaign_id AND e.status <> 'encerrado'
           ) THEN 'ja_inscrito'
           WHEN coalesce(array_length(al.canais, 1), 0) = 0 THEN 'sem_canal'
           ELSE 'inscrever'
         END,
         al.canais,
         CASE
           WHEN c.id IS NULL THEN
             'contato não existe neste cliente'
           WHEN esta_suprimido(p_tenant, a.id, NULL, NULL) THEN
             'contato suprimido: inscrever devolveria nulo em silêncio'
           WHEN EXISTS (
             SELECT 1 FROM enrollments e
              WHERE e.tenant_id = p_tenant AND e.contact_id = a.id
                AND e.campaign_id = p_campaign_id AND e.status <> 'encerrado'
           ) THEN
             'já inscrito e não encerrado nesta campanha'
           WHEN coalesce(array_length((SELECT canais FROM uteis), 1), 0) = 0 THEN
             'nenhum passo do flow usa um canal habilitado na campanha: '
             || 'ninguém receberia nada'
           WHEN coalesce(array_length(al.canais, 1), 0) = 0 THEN
             'sem identidade válida em ' || array_to_string((SELECT canais FROM uteis), ', ')
             || ': o enrollment percorreria todos os passos e encerraria como concluído'
           -- D77: canal sem conta no pool DESTA campanha — inscrever não dá
           -- erro, e o agendador adia o passo de hora em hora, para sempre.
           -- D77b: a pergunta é de `privado.pool_da_campanha`, que vê as contas
           -- por quem opera (a prévia é INVOKER, e o operador não as lê), segue a
           -- conta de e-mail escolhida pela campanha e conta o circuito aberto.
           WHEN EXISTS (
             SELECT 1 FROM unnest(al.canais) AS u(canal)
              WHERE privado.pool_da_campanha(p_tenant, p_campaign_id, u.canal) IN ('sem_conta', 'desligada')
           ) THEN
             (SELECT string_agg(CASE privado.pool_da_campanha(p_tenant, p_campaign_id, u.canal)
                                  WHEN 'sem_conta' THEN 'sem conta ' || (SELECT tipo FROM camp)::text || ' em ' || u.canal::text
                                  ELSE 'a conta ' || (SELECT tipo FROM camp)::text || ' de ' || u.canal::text || ' está desligada'
                                END, '; ' ORDER BY u.canal)
                FROM unnest(al.canais) AS u(canal)
               WHERE privado.pool_da_campanha(p_tenant, p_campaign_id, u.canal) IN ('sem_conta', 'desligada'))
             || ': a inscrição entra, e o agendador adia o passo até haver conta ativa nesse pool'
           WHEN NOT (SELECT ativa FROM camp) THEN
             'campanha inativa: o agendador ignora enquanto ela estiver assim'
         END
    FROM alvo a
    JOIN alcance al ON al.id = a.id
    LEFT JOIN contacts c ON c.tenant_id = p_tenant AND c.id = a.id
   ORDER BY c.nome NULLS LAST, a.id;
$function$;

-- 4. Busca

CREATE OR REPLACE FUNCTION public.buscar_contatos(p_tenant uuid, p_termo text, p_limite integer DEFAULT 200)
RETURNS TABLE(contact_id uuid)
LANGUAGE sql STABLE
SET search_path TO 'public', 'privado'
AS $$
  WITH t AS (
    SELECT replace(replace(replace(btrim(coalesce(p_termo, '')), '\', '\\'), '%', '\%'), '_', '\_') AS termo,
           -- D77b: pelos dígitos só quando o termo É telefone. "carlos1234@x.com"
           -- achava todo número com 1234, e a tela marca todos e inscreve.
           CASE WHEN btrim(coalesce(p_termo, '')) ~ '^[0-9 ()+.-]+$'
                THEN regexp_replace(p_termo, '\D', '', 'g') ELSE '' END AS digitos
  )
  SELECT c.id
    FROM contacts c, t
   WHERE c.tenant_id = p_tenant
     AND t.termo <> ''
     AND (c.nome ILIKE '%' || t.termo || '%'
          OR EXISTS (SELECT 1 FROM contact_identities i
                      WHERE i.tenant_id = c.tenant_id AND i.contact_id = c.id
                        AND (i.valor_norm ILIKE '%' || t.termo || '%'
                             OR (length(t.digitos) >= 4 AND i.valor_norm LIKE '%' || t.digitos || '%'))))
   ORDER BY c.criado_em DESC
   LIMIT least(greatest(coalesce(p_limite, 200), 1), 500)
$$;

-- 5. Fonte de CRM

CREATE OR REPLACE FUNCTION public.registrar_execucao_fonte(p_fonte_id uuid, p_resultado jsonb)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'public', 'privado'
AS $function$
  -- D77b: o card ignorado ganha vínculo e não volta na passada seguinte, então
  -- os exemplos de lá sumiam em quinze minutos. Os últimos cinco ficam, os
  -- novos na frente, com a data de cada passada que os achou.
  UPDATE crm_fontes
     SET ultima_execucao = now(),
         ultimo_resultado = p_resultado || jsonb_build_object('ignorados_exemplos', coalesce((
           SELECT jsonb_agg(x ORDER BY o) FROM (
             SELECT x, o FROM (
               SELECT x || jsonb_build_object('em', coalesce(x ->> 'em', now()::text)) AS x, o
                 FROM jsonb_array_elements(coalesce(p_resultado -> 'ignorados_exemplos', '[]'::jsonb))
                      WITH ORDINALITY a(x, o)
               UNION ALL
               SELECT x, 100 + o
                 FROM jsonb_array_elements(coalesce(ultimo_resultado -> 'ignorados_exemplos', '[]'::jsonb))
                      WITH ORDINALITY b(x, o)
             ) t ORDER BY o LIMIT 5
           ) u), '[]'::jsonb))
   WHERE id = p_fonte_id;
$function$;
