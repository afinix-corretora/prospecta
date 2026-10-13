-- A conta nasce só pela função (D78).
--
-- Desde o D77 o app cria conta por `conectar_conta`, que grava a linha e o
-- segredo numa transação só. O INSERT por coluna de `sender_accounts` para
-- `authenticated` ficou de pé porque o app de antes ainda estava no ar e
-- cadastrava por ele; o app novo está publicado desde o push do D77b, e
-- nenhuma tela nem edge function insere em `sender_accounts` com o JWT da
-- pessoa (o chip criado vai por `criar_remetente_provisionado`, do
-- service_role).
--
-- A grade mora em `privado.estreitar_escrita_do_cliente`, nominal por tabela
-- (D54): revogar fora dela seria desfeito no próximo `GRANT ALL` do suite, e o
-- suite conferiria uma grade diferente da de produção. O corpo abaixo partiu do
-- que está no projeto — o md5 do corpo (`prosrc`) no projeto e no banco de
-- teste montado pelo repositório é o mesmo — e muda só o bloco de
-- `sender_accounts` (D59). `REVOKE INSERT` de tabela leva junto o INSERT de
-- cada coluna: não há GRANT a desfazer além de não fazê-lo mais.

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
  GRANT UPDATE (nome, objetivo, ativa, flow_version_id, remetente_email_id, ai_credential_id)
    ON campaigns TO authenticated;
  GRANT UPDATE (status) ON enrollments TO authenticated;
  -- D75: `rampa_dias` e `rampa_inicial` entram; o andamento da rampa, não.
  GRANT UPDATE (apelido, quota_diaria, estado, rampa_dias, rampa_inicial)
    ON sender_accounts TO authenticated;

  -- D62: a conta nasce pela tela com o que a tela preenche, e só. Com INSERT
  -- de tabela inteira dava para nascer com `credenciais_secret_id` apontando
  -- para o segredo de OUTRO cliente — o worker mandaria pela conta dele, o
  -- D59 na quarta tabela de credencial. E DELETE apagava em cascata as
  -- mensagens e os eventos da conta: história que é append-only (D62).
  --
  -- D78: nem por coluna. A conta nasce por `conectar_conta` (D77), que grava a
  -- linha e o segredo na mesma transação, ou por `criar_remetente_provisionado`
  -- (D25), do service_role. O INSERT por coluna era a porta para a conta órfã
  -- que o D77 fechou: a linha nascia ativa, no pool, sem segredo nenhum, e o
  -- despacho a escolhia e falhava. Ficou aberto só enquanto o app de antes,
  -- que cadastrava por ele, estava no ar.
  REVOKE INSERT, DELETE ON sender_accounts FROM authenticated;

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
  -- D76: os dois vocabulários de catálogo (D58, D63) estavam fora desta lista
  -- e seguiam com escrita de tabela inteira — a política segurava, o
  -- privilégio não. O do cliente é `blacklist_termos`, que fica como está.
  REVOKE INSERT, UPDATE, DELETE ON opt_out_termos, recusa_termos FROM authenticated;

  -- D64. Vínculo e estrutura são do motor: a tela lê. Um vínculo escrito à
  -- mão é o fato de uma pessoa indo para o card de outra; uma estrutura
  -- escrita à mão é a tela oferecendo fase que não existe.
  REVOKE INSERT, UPDATE, DELETE ON crm_vinculos, crm_estruturas FROM authenticated;

  -- Ação e fonte são da tela, por coluna. Fora fica o dono da linha e, na
  -- fonte, o que a execução grava — `ultimo_resultado` escrito pela tela
  -- seria o painel dizendo que a fonte rodou quando não rodou.
  REVOKE INSERT, UPDATE ON crm_acoes, crm_fontes FROM authenticated;
  GRANT INSERT (tenant_id, conexao_id, pipe_id, fato, tipo, alvo_id, alvo_rotulo, valor, ordem, ativo)
    ON crm_acoes TO authenticated;
  GRANT UPDATE (alvo_id, alvo_rotulo, valor, ordem, ativo) ON crm_acoes TO authenticated;
  GRANT INSERT (tenant_id, conexao_id, nome, pipe_id, pipe_rotulo, fases, mapa,
                campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  GRANT UPDATE (nome, fases, mapa, campaign_id, intervalo_minutos, ativa)
    ON crm_fontes TO authenticated;
  -- D66. O agente é da tela, por coluna: o que ele diz, quando passa para
  -- uma pessoa, o que nunca escreve e com que credencial. Fora fica o dono da
  -- linha e `pronto`, que é a marca de agente do catálogo. D69: e se ele
  -- responde sozinho.
  REVOKE UPDATE ON agents FROM authenticated;
  GRANT UPDATE (nome, papel, descricao, instrucoes, ai_credential_id, escalar_quando,
                limite_trocas, ativo, proibido, tamanho_maximo, autonomo,
                tom, contexto, persona, objetivo)
    ON agents TO authenticated;
  -- D76: remover agente é desligá-lo. O DELETE apagava em cascata a exceção
  -- das campanhas (trocando quem responde sem ninguém ver) e deixava o
  -- histórico de rascunhos sem quem o compôs. `canal` fica fora do UPDATE: o
  -- agente de antes continua do canal dele, e o novo nasce de todos.
  REVOKE DELETE ON agents FROM authenticated;

  -- D76: quem responde. A tela escolhe o agente e o canal; a vigência é do
  -- gatilho, e o dono da linha não muda.
  REVOKE INSERT, UPDATE ON campaign_agents, agentes_por_canal FROM authenticated;
  GRANT INSERT (tenant_id, campaign_id, canal, agent_id, herda) ON campaign_agents TO authenticated;
  GRANT UPDATE (agent_id, herda) ON campaign_agents TO authenticated;
  -- Sem DELETE: apagar a exceção faria valer a data antiga do agente do canal.
  -- Voltar ao do canal é `herda`, que tem data.
  REVOKE DELETE ON campaign_agents FROM authenticated;
  GRANT INSERT (tenant_id, canal, agent_id) ON agentes_por_canal TO authenticated;
  GRANT UPDATE (agent_id) ON agentes_por_canal TO authenticated;

  -- O rascunho é do worker: a tela lê. Escrito à mão, seria um texto que
  -- parece ter sido composto pelo agente com os freios dele, sem ter sido —
  -- e, desde o D69, um `envio = 'fila'` sem mensagem nenhuma.
  REVOKE INSERT, UPDATE, DELETE ON rascunhos FROM authenticated;

  -- D77: o funil. O código conhece estágio por `slug` e `tipo` (D57), e o
  -- motor move por eles dentro do gatilho da resposta: com o UPDATE de tabela
  -- inteira, um operador renomeava o slug e toda resposta de quem tem card
  -- deixava de ser gravada. A tela renomeia (`nome`), pinta e reordena; criar,
  -- apagar e mudar slug, tipo ou o funil padrão é do produto.
  REVOKE INSERT, UPDATE, DELETE ON pipelines, pipeline_stages FROM authenticated;
  GRANT UPDATE (nome) ON pipelines TO authenticated;
  GRANT UPDATE (nome, cor, posicao) ON pipeline_stages TO authenticated;

  -- D77: TRUNCATE não passa pelo RLS — esvazia a tabela de todos os clientes.
  -- Nenhuma tela trunca, e o Supabase o dá a authenticated junto do ALL.
  REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM authenticated;

  -- D76: anon não escreve em tabela nenhuma. O RLS já recusa (nenhuma
  -- política de escrita aceita quem não entrou), mas o Supabase dá a anon o
  -- mesmo ALL de tabela que dá a authenticated: a política segurava enquanto o
  -- privilégio soltava, que é o D54 — e o suite, que concedia só SELECT a anon,
  -- conferia uma grade mais estreita que a de produção.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM anon;
  END IF;
END;
$function$;

-- Dentro de DO: migration que imprime resultado polui o stdout que o
-- `tests/run.sh` captura para nomear o banco.
DO $$ BEGIN PERFORM privado.estreitar_escrita_do_cliente(); END $$;
