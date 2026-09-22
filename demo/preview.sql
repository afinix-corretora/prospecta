-- Preview: uma cadência real rodando ao longo de dias.
--
-- Semeia duas campanhas com situações que valem a pena ver, avança o relógio
-- de evento em evento e registra cada decisão do motor. O provedor é simulado
-- aqui dentro (em produção quem responde é o adapter), mas o agendador, o
-- roteador, o pool e as quatro invariantes são os de verdade.
--
-- Roda com: demo/gerar.sh

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA p;

-- Relógio virtual: o motor usa now(), então "avançar dias" é puxar os
-- next_run_at para trás e anotar quanto tempo passou.
CREATE TABLE p.relogio (decorrido interval NOT NULL DEFAULT interval '0');
INSERT INTO p.relogio VALUES (interval '0');

CREATE TABLE p.linha (
  id serial PRIMARY KEY,
  momento    interval NOT NULL,
  ator       text NOT NULL,     -- motor | provedor | pessoa | operador
  contato    text,
  acao       text NOT NULL,
  detalhe    text NOT NULL DEFAULT '',
  canal      text,
  remetente  text
);

CREATE FUNCTION p.agora() RETURNS interval
LANGUAGE sql AS $$ SELECT decorrido FROM p.relogio $$;

CREATE FUNCTION p.registrar(
  p_ator text, p_contato text, p_acao text,
  p_detalhe text DEFAULT '', p_canal text DEFAULT NULL, p_remetente text DEFAULT NULL
) RETURNS void LANGUAGE sql AS $$
  INSERT INTO p.linha (momento, ator, contato, acao, detalhe, canal, remetente)
  VALUES (p.agora(), p_ator, p_contato, p_acao, p_detalhe, p_canal, p_remetente);
$$;

-- ---------------------------------------------------------------------------
-- Cenário
-- ---------------------------------------------------------------------------

-- As campanhas nascem de modelos do catálogo, como no hub.
CREATE TABLE p.ids (chave text PRIMARY KEY, campanha uuid, versao uuid);

DO $$
DECLARE r record; v_tenant uuid := current_setting('app.tenant')::uuid;
BEGIN
  SELECT * INTO r FROM criar_campanha_de_modelo(
    v_tenant, 'resgate-multicanal', 'Resgate 2024', '{whatsapp,email}');
  INSERT INTO p.ids VALUES ('resgate', r.campaign_id, r.flow_version_id);

  SELECT * INTO r FROM criar_campanha_de_modelo(
    v_tenant, 'prospeccao-fria', 'Lista fria SP', '{whatsapp}');
  INSERT INTO p.ids VALUES ('fria', r.campaign_id, r.flow_version_id);
END;
$$;

-- Cada canal ganha sua persona de resposta.
DO $$
DECLARE v_resgate uuid; v_fria uuid;
BEGIN
  SELECT campanha INTO v_resgate FROM p.ids WHERE chave = 'resgate';
  SELECT campanha INTO v_fria    FROM p.ids WHERE chave = 'fria';
  PERFORM atribuir_agente(v_resgate, (SELECT id FROM agents WHERE nome LIKE 'Ana%'));
  PERFORM atribuir_agente(v_resgate, (SELECT id FROM agents WHERE nome LIKE 'Edu%'));
  PERFORM atribuir_agente(v_fria,    (SELECT id FROM agents WHERE nome LIKE 'Caio%'));
END;
$$;

-- Pool: morno e frio separados por schema, não por disciplina (D4).
-- O servidor UAZAPI: é dele que a plataforma cria instância nova sem ninguém
-- entrar no painel do provedor.
INSERT INTO provider_servers (id, provedor, nome, base_url)
VALUES ('dd000000-0000-0000-0000-0000000000d1','uazapi','UAZAPI Afinix',
        'https://afinix.uazapi.com');

-- Duas contas da Gupshup no mesmo canal e no mesmo pool: é o caso normal, e é
-- o que mostra que quota é por conta, não por canal.
INSERT INTO sender_accounts
  (id, canal, identificador, apelido, provedor, tipo_permitido, quota_diaria, config) VALUES
  ('dd000000-0000-0000-0000-000000000001','whatsapp','+55 11 99000-0001','Comercial',
   'gupshup','morna',200,'{"app_name":"afinix-comercial","source":"5511990000001"}'::jsonb),
  ('dd000000-0000-0000-0000-000000000004','whatsapp','+55 11 99000-0002','Retenção',
   'gupshup','morna',200,'{"app_name":"afinix-retencao","source":"5511990000002"}'::jsonb),
  -- Resend, não SMTP: `smtp` é declarado sem adapter (D30) e desde o D31 o pool
  -- nem enxerga conta assim. O demo com uma conta dessas era o cenário que o
  -- D31 conserta — mostrava e-mail saindo por um provedor que não envia.
  ('dd000000-0000-0000-0000-000000000002','email','resgate@afinix-relaciona.com.br','Domínio de relacionamento',
   'resend','morna',300,
   '{"assunto_padrao":"Seu plano de saúde na Afinix","nome_remetente":"Afinix Corretora","responder_para":"resgate@inbound.afinix-relaciona.com.br"}'::jsonb),
  -- Chip frio com quota baixa de propósito: é o que faz o freio aparecer.
  ('dd000000-0000-0000-0000-000000000003','whatsapp','+55 11 98000-0009','Chip frio SP',
   'uazapi','fria',2,'{"base_url":"https://afinix.uazapi.com","instancia":"fria-sp"}'::jsonb);

-- O chip frio veio do servidor, como viria pela tela de criar instância.
UPDATE sender_accounts SET provider_server_id = 'dd000000-0000-0000-0000-0000000000d1'
 WHERE id = 'dd000000-0000-0000-0000-000000000003';

-- ---------------------------------------------------------------------------
-- Importação: pela porta de entrada, não por INSERT
-- ---------------------------------------------------------------------------

-- As pessoas entram de `demo/contatos.csv`, lidas por `PlanilhaSource` e
-- gravadas por `ingerir_contato` — o mesmo caminho da tela. Antes este
-- arquivo dava INSERT nas sete, que era justamente o "INSERT à mão" que a
-- ingestão veio substituir (D32): um demo que pula a porta de entrada não
-- exercita a porta de entrada.
--
-- O uuid de cada contato passa a vir do banco, então o cenário chama as
-- pessoas por `p.quem('Nome')`.
\i :ingestao

-- Tulio já tinha pedido para sair antes de a campanha começar.
INSERT INTO suppression (contact_id, motivo)
VALUES (p.quem('Tulio Barros'),'opt-out registrado na campanha anterior');

-- ---------------------------------------------------------------------------
-- Inscrição nas campanhas
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_id uuid; v_camp uuid; v_ver uuid;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('Marina Alves','resgate'), ('Otávio Lima','resgate'),
      ('Paula Ribeiro','resgate'), ('Rui Nogueira','resgate'),
      ('Tulio Barros','resgate'),
      ('Sônia Prado','fria'), ('Vera Castro','fria')
    ) AS v(nome, chave)
  LOOP
    SELECT campanha, versao INTO v_camp, v_ver FROM p.ids WHERE chave = r.chave;
    v_id := inscrever(p.quem(r.nome), v_camp, v_ver, now());
    IF v_id IS NULL THEN
      PERFORM p.registrar('motor', r.nome, 'inscricao_recusada',
        'já estava na supressão — nem chega a criar estado');
    ELSE
      PERFORM p.registrar('motor', r.nome, 'inscrito',
        (SELECT nome FROM campaigns WHERE id = v_camp));
    END IF;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- O laço: avança para o próximo evento agendado e roda uma passada
-- ---------------------------------------------------------------------------

CREATE FUNCTION p.avancar_relogio() RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_proximo timestamptz; v_delta interval; v_dia_antes integer; v_dia_depois integer;
BEGIN
  SELECT min(next_run_at) INTO v_proximo FROM enrollments
   WHERE status = 'ativo' AND next_run_at IS NOT NULL;
  IF v_proximo IS NULL THEN RETURN false; END IF;

  v_delta := greatest(v_proximo - now(), interval '0');
  SELECT floor(extract(epoch from decorrido)/86400)::int INTO v_dia_antes FROM p.relogio;

  UPDATE enrollments SET next_run_at = next_run_at - v_delta
   WHERE status = 'ativo' AND next_run_at IS NOT NULL;
  UPDATE p.relogio SET decorrido = decorrido + v_delta;

  SELECT floor(extract(epoch from decorrido)/86400)::int INTO v_dia_depois FROM p.relogio;

  -- O relógio virtual anda puxando next_run_at, mas current_date é real e não
  -- se move — então a janela de quota nunca viraria sozinha aqui. Quando o dia
  -- simulado troca, o harness faz o que o calendário faria em produção.
  IF v_dia_depois > v_dia_antes THEN
    UPDATE sender_accounts SET janela = current_date - 1;
    PERFORM p.registrar('operador', NULL, 'novo_dia',
      format('dia %s da cadência — quotas diárias renovadas', v_dia_depois + 1));
  END IF;

  RETURN true;
END;
$$;

CREATE FUNCTION p.nome_de(p_enrollment uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT c.nome FROM enrollments e JOIN contacts c ON c.id = e.contact_id WHERE e.id = p_enrollment;
$$;

-- Provedor simulado: em produção é o adapter que faz o HTTP e devolve isto.
CREATE FUNCTION p.responder_provedor() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r record; v_nome text; v_id text;
BEGIN
  FOR r IN SELECT * FROM reivindicar_pendentes(50) LOOP
    v_nome := (SELECT c.nome FROM messages m
                 JOIN enrollments e ON e.id = m.enrollment_id
                 JOIN contacts c ON c.id = e.contact_id
                WHERE m.id = r.message_id);
    v_id := 'PROV-' || substr(r.message_id::text, 1, 8);

    -- O número da Vera não existe no WhatsApp: culpa do destino.
    IF v_nome = 'Vera Castro' THEN
      PERFORM registrar_resultado_envio(r.message_id, false, NULL,
        'not a WhatsApp user', 'destino');
      PERFORM p.registrar('provedor', v_nome, 'rejeitado',
        'número não existe no WhatsApp', r.canal::text, r.sender_ident);
    ELSE
      PERFORM registrar_resultado_envio(r.message_id, true, v_id, NULL);
      PERFORM p.registrar('provedor', v_nome, 'entregue_ao_provedor',
        v_id, r.canal::text, r.sender_ident);
    END IF;
  END LOOP;
END;
$$;

DO $$
DECLARE
  r record; v_passada integer := 0; v_nome text;
  v_msg uuid; v_prov text; v_chip uuid;
BEGIN
  WHILE v_passada < 40 LOOP
    v_passada := v_passada + 1;
    EXIT WHEN NOT p.avancar_relogio();

    FOR r IN SELECT * FROM processar_vencidos(100, 'real') LOOP
      v_nome := p.nome_de(r.enrollment_id);
      PERFORM p.registrar('motor', v_nome, r.acao, r.detalhe,
        (SELECT m.canal::text FROM messages m
          WHERE m.enrollment_id = r.enrollment_id ORDER BY m.criado_em DESC LIMIT 1),
        (SELECT sa.identificador FROM messages m
           JOIN sender_accounts sa ON sa.id = m.sender_account_id
          WHERE m.enrollment_id = r.enrollment_id ORDER BY m.criado_em DESC LIMIT 1));
    END LOOP;

    PERFORM p.responder_provedor();

    -- Otávio responde depois do primeiro contato.
    IF p.agora() >= interval '3 hours' AND NOT EXISTS (
      SELECT 1 FROM p.linha WHERE contato = 'Otávio Lima' AND acao = 'respondeu')
    THEN
      SELECT m.id, m.provider_message_id, m.sender_account_id
        INTO v_msg, v_prov, v_chip FROM messages m
        JOIN enrollments e ON e.id = m.enrollment_id
       WHERE e.contact_id = p.quem('Otávio Lima')
         AND m.provider_message_id IS NOT NULL
       ORDER BY m.criado_em DESC LIMIT 1;
      IF v_prov IS NOT NULL THEN
        PERFORM registrar_evento_provedor(v_chip, v_prov, 'respondido', now(),
          '{"texto":"oi, pode me mandar os valores?"}'::jsonb);
        PERFORM p.registrar('pessoa','Otávio Lima','respondeu',
          'oi, pode me mandar os valores?','whatsapp');
      END IF;
    END IF;

    -- Marina clica no link do e-mail, mas não responde (D7).
    IF p.agora() >= interval '50 hours' AND NOT EXISTS (
      SELECT 1 FROM p.linha WHERE contato = 'Marina Alves' AND acao = 'clicou')
    THEN
      SELECT m.provider_message_id, m.sender_account_id INTO v_prov, v_chip FROM messages m
        JOIN enrollments e ON e.id = m.enrollment_id
       WHERE e.contact_id = p.quem('Marina Alves')
         AND m.canal = 'email' AND m.provider_message_id IS NOT NULL
       ORDER BY m.criado_em DESC LIMIT 1;
      IF v_prov IS NOT NULL THEN
        PERFORM registrar_evento_provedor(v_chip, v_prov, 'clique', now(), '{}'::jsonb);
        PERFORM p.registrar('pessoa','Marina Alves','clicou',
          'abriu o link do e-mail — engajamento, não resposta','email');
      END IF;
    END IF;

    -- No dia 2, alguém pede para sair por outro canal.
    IF p.agora() >= interval '30 hours' AND NOT EXISTS (
      SELECT 1 FROM suppression WHERE contact_id = p.quem('Paula Ribeiro'))
    THEN
      INSERT INTO suppression (contact_id, motivo)
      VALUES (p.quem('Paula Ribeiro'),'pediu remoção por telefone');
      PERFORM p.registrar('operador','Paula Ribeiro','suprimida',
        'pediu remoção por telefone; entra na lista global');
    END IF;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Saída
-- ---------------------------------------------------------------------------

\pset format unaligned
\pset tuples_only on

SELECT jsonb_pretty(jsonb_build_object(
  'linha', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'momento', (extract(epoch from momento) / 3600)::int,
      'ator', ator, 'contato', contato, 'acao', acao,
      'detalhe', detalhe, 'canal', canal, 'remetente', remetente
    ) ORDER BY id), '[]'::jsonb) FROM p.linha),

  'enrollments', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', c.nome, 'campanha', ca.nome, 'status', e.status,
      'passo', e.passo_atual, 'motivo', e.motivo_encerramento
    ) ORDER BY c.nome), '[]'::jsonb)
    FROM enrollments e JOIN contacts c ON c.id = e.contact_id
    JOIN campaigns ca ON ca.id = e.campaign_id),

  'mensagens', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', c.nome, 'canal', m.canal, 'status', m.status,
      'conteudo', m.conteudo,
      'remetente', sa.identificador
    ) ORDER BY m.criado_em), '[]'::jsonb)
    FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
    JOIN contacts c ON c.id = e.contact_id
    LEFT JOIN sender_accounts sa ON sa.id = m.sender_account_id),

  'remetentes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'identificador', identificador, 'apelido', apelido, 'canal', canal,
      'provedor', provedor, 'tipo', tipo_permitido,
      'usado', enviados_na_janela, 'quota', quota_diaria,
      'saude', health_score, 'estado', estado, 'config', config,
      'webhook_token', webhook_token, 'servidor', provider_server_id
    ) ORDER BY identificador), '[]'::jsonb) FROM sender_accounts),

  'servidores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'provedor', provedor, 'nome', nome, 'base_url', base_url,
      'tem_admin', admin_secret_id IS NOT NULL, 'ativo', ativo,
      'instancias', (SELECT count(*) FROM sender_accounts sa
                      WHERE sa.provider_server_id = ps.id)
    ) ORDER BY nome), '[]'::jsonb) FROM provider_servers ps),

  -- O catálogo de provedores de canal: é dele que a UI monta a tela de
  -- conectar conta, sem conhecer Gupshup nem Evolution.
  'provedores_canal', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'slug', slug, 'canal', canal, 'nome', nome, 'descricao', descricao,
      'oficial', oficial, 'tem_adapter', tem_adapter,
      'campos', campos, 'docs', docs_url
    ) ORDER BY canal, ordem), '[]'::jsonb) FROM channel_provider_catalog WHERE ativo),

  'supressao', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', coalesce(c.nome, s.valor_norm), 'motivo', s.motivo
    )), '[]'::jsonb) FROM suppression s LEFT JOIN contacts c ON c.id = s.contact_id),

  'outbox', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'contato', c.nome, 'fato', o.fato, 'autoria', o.autoria
    )), '[]'::jsonb) FROM outbox o JOIN contacts c ON c.id = o.contact_id),

  'horas_simuladas', (SELECT (extract(epoch from decorrido)/3600)::int FROM p.relogio),

  'modelos', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'slug', slug, 'nome', nome, 'descricao', descricao, 'objetivo', objetivo,
      'tipo', tipo, 'canais', canais, 'passos', jsonb_array_length(passos),
      'base_legal', base_legal,
      'cadencia', (SELECT jsonb_agg(jsonb_build_object(
          'canal', s ->> 'canal', 'atraso', (s ->> 'atraso_horas')::int))
        FROM jsonb_array_elements(t.passos) s)
    ) ORDER BY ordem), '[]'::jsonb) FROM campaign_templates t WHERE ativo),

  'provedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'slug', slug, 'nome', nome, 'descricao', descricao,
      'campos', campos, 'modelos', modelos_sugeridos, 'docs', docs_url
    ) ORDER BY ordem), '[]'::jsonb) FROM ai_provider_catalog),

  -- Usar um agente do catálogo copia a linha para o tenant. Sem o DISTINCT ON,
  -- o console mostraria o original e a cópia como dois agentes diferentes.
  'agentes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'nome', nome, 'canal', canal, 'papel', papel, 'descricao', descricao,
      'instrucoes', instrucoes, 'escalar', escalar_quando,
      'limite', limite_trocas, 'pronto', tenant_id IS NULL
    ) ORDER BY canal, nome), '[]'::jsonb)
    FROM (SELECT DISTINCT ON (nome) * FROM agents WHERE ativo
           ORDER BY nome, tenant_id NULLS LAST) a),

  'campanhas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'nome', c.nome, 'tipo', c.tipo, 'objetivo', c.objetivo,
      'modelo', c.template_slug, 'ativa', c.ativa,
      'canais', c.canais_habilitados,
      'inscritos', (SELECT count(*) FROM enrollments e WHERE e.campaign_id = c.id),
      'em_cadencia', (SELECT count(*) FROM enrollments e
                       WHERE e.campaign_id = c.id AND e.status = 'ativo'),
      'enviadas', (SELECT count(*) FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
                    WHERE e.campaign_id = c.id AND m.status IN ('enviado','simulado')),
      'falhas', (SELECT count(*) FROM messages m JOIN enrollments e ON e.id = m.enrollment_id
                  WHERE e.campaign_id = c.id AND m.status = 'falha'),
      'respostas', (SELECT count(*) FROM enrollments e
                     WHERE e.campaign_id = c.id AND e.motivo_encerramento = 'resposta'),
      'concluidas', (SELECT count(*) FROM enrollments e
                      WHERE e.campaign_id = c.id AND e.motivo_encerramento = 'fim_dos_passos'),
      'suprimidos', (SELECT count(*) FROM enrollments e
                      WHERE e.campaign_id = c.id AND e.motivo_encerramento = 'supressao'),
      'agentes', (SELECT coalesce(jsonb_object_agg(ca.canal, a.nome), '{}'::jsonb)
                   FROM campaign_agents ca JOIN agents a ON a.id = ca.agent_id
                  WHERE ca.campaign_id = c.id),
      'passos', (SELECT count(*) FROM flow_steps fs
                  WHERE fs.flow_version_id = (SELECT e2.flow_version_id FROM enrollments e2
                                               WHERE e2.campaign_id = c.id LIMIT 1))
    ) ORDER BY c.nome), '[]'::jsonb) FROM campaigns c)
));
