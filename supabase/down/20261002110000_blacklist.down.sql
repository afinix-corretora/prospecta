-- Reverte o D63: a blacklist volta a ser do produto.
--
-- Os corpos abaixo são os de antes do D63, lidos do banco montado com as
-- migrations anteriores (D59). Os classificadores antigos que os gatilhos
-- voltam a chamar já existem: quem os recria é o down da migration seguinte,
-- que roda antes deste.

CREATE OR REPLACE FUNCTION privado.opt_out_no_texto()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado'
AS $function$
DECLARE v_termo text; v_contato uuid;
BEGIN
  -- `texto` e a chave que os adapters preenchem quando o provedor entrega o
  -- corpo da mensagem. Provedor que nao entrega (SMS hoje nao tem webhook de
  -- entrada) simplesmente nao aciona isto — e nao adianta fingir que aciona.
  v_termo := privado.pedido_de_saida(NEW.payload ->> 'texto');
  IF v_termo IS NULL THEN RETURN NEW; END IF;

  SELECT e.contact_id INTO v_contato
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
   WHERE m.id = NEW.message_id;
  IF v_contato IS NULL THEN RETURN NEW; END IF;

  -- A pessoa toda, em todo canal: quem pede para parar nao esta pedindo para
  -- parar so no WhatsApp. E o `motivo` carrega o termo, para a linha poder ser
  -- auditada depois sem ir atras do evento.
  IF NOT EXISTS (SELECT 1 FROM suppression s
                  WHERE s.tenant_id = NEW.tenant_id
                    AND s.contact_id = v_contato AND s.canal IS NULL) THEN
    INSERT INTO suppression (tenant_id, contact_id, motivo)
    VALUES (NEW.tenant_id, v_contato,
            'pediu para sair na resposta (termo: ' || v_termo || ')');
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION privado.qualifica_resposta()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'privado', 'pg_catalog'
AS $function$
DECLARE v_texto text; v_contato uuid; v_deal uuid; v_recusa text;
BEGIN
  -- Só string vira texto: objeto viraria "[object Object]" e número viraria
  -- "0". A mesma trava do D48, pelo mesmo motivo — o payload é do provedor.
  IF jsonb_typeof(NEW.payload -> 'texto') <> 'string' THEN RETURN NEW; END IF;
  v_texto := NEW.payload ->> 'texto';

  -- Quem pediu para sair já foi tratado pelo gatilho anterior. `mover_deal`
  -- recusaria de qualquer forma (o card está em `perdido`), mas dizer isto
  -- aqui poupa quem lê de ter que reconstruir a ordem dos gatilhos.
  IF privado.pedido_de_saida(v_texto) IS NOT NULL THEN RETURN NEW; END IF;

  v_recusa := privado.eh_recusa(v_texto);
  -- Recusou: o card fica em `respondeu`. Não inventamos um estágio de recusa
  -- — a pessoa respondeu, e uma campanha futura pode fazer sentido. Quem quer
  -- nunca mais ser incomodado disse isso, e aí é opt-out.
  IF v_recusa IS NOT NULL THEN RETURN NEW; END IF;

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
  );
$function$;

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

DROP FUNCTION IF EXISTS public.testar_blacklist(uuid, text);
DROP FUNCTION IF EXISTS privado.regra_da_resposta(uuid, text);
DROP TRIGGER IF EXISTS tenants_semeia_blacklist ON tenants;
DROP FUNCTION IF EXISTS privado.semear_blacklist_do_tenant();
DROP FUNCTION IF EXISTS privado.semear_blacklist(uuid);
DROP TABLE IF EXISTS blacklist_dominios;
DROP TABLE IF EXISTS blacklist_termos;
DROP FUNCTION IF EXISTS privado.normalizar_blacklist_dominio();
DROP FUNCTION IF EXISTS privado.normalizar_blacklist_termo();
DROP TYPE IF EXISTS acao_blacklist;
