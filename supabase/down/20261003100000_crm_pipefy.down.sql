-- Reverte o D64: o CRM volta a ser lugar nenhum.
--
-- Os corpos de `reivindicar_writebacks` e de `estreitar_escrita_do_cliente`
-- são os de antes do D64, lidos do banco montado até o D63.

DROP FUNCTION public.registrar_execucao_fonte(uuid, jsonb);
DROP FUNCTION public.ingerir_do_crm(uuid, text, jsonb, text, jsonb);
DROP FUNCTION public.refs_vinculadas(uuid);
DROP FUNCTION public.fontes_crm_vencidas();
DROP FUNCTION public.registrar_estrutura_crm(uuid, jsonb, text);
DROP FUNCTION public.plano_de_writeback(uuid);
DROP FUNCTION public.anotar_resultado_writeback(uuid, text);

CREATE OR REPLACE FUNCTION public.reivindicar_writebacks(p_limite integer DEFAULT 50, p_lease interval DEFAULT '00:05:00'::interval)
 RETURNS TABLE(writeback_id uuid, tenant_id uuid, contact_id uuid, destino text, fato fato_writeback, payload jsonb, autoria text, tentativas integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'privado'
AS $function$
BEGIN
  RETURN QUERY
  WITH lote AS (
    SELECT o.id
      FROM outbox o
     WHERE o.status = 'pendente'
       AND o.proxima_tentativa_em <= now()
       AND (o.reivindicada_em IS NULL OR o.reivindicada_em < now() - p_lease)
     ORDER BY o.proxima_tentativa_em
     LIMIT p_limite
     FOR UPDATE SKIP LOCKED
  ), pego AS (
    UPDATE outbox o SET reivindicada_em = now()
      FROM lote l WHERE o.id = l.id
     RETURNING o.*
  )
  SELECT p.id, p.tenant_id, p.contact_id, p.destino, p.fato, p.payload,
         p.autoria, p.tentativas
    FROM pego p;
END;
$function$;

ALTER TABLE outbox DROP COLUMN resultado;

DROP TABLE crm_fontes;
DROP TABLE crm_acoes;
DROP TABLE crm_estruturas;
DROP TABLE crm_vinculos;

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
