-- Recusa ou oportunidade (D58).
--
-- A pergunta é "é recusa?", nunca "é positiva?". A base da casa registra que
-- tentar detectar entusiasmo foi o que falhou no projeto anterior — o
-- classificador reperguntava dados e reativava tarde e duplicado.
--
-- E a assimetria é o INVERSO da do D48:
--
--   falso positivo de recusa -> lead bom nunca chega ao consultor. Caro e
--                               silencioso.
--   falso negativo de recusa -> alguém sem interesse aparece na coluna
--                               Oportunidade. Barato e visível.
--
-- Por isso metade deste arquivo testa coisas que NÃO são recusa.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ql;
CREATE TABLE ql.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION ql.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ql.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

CREATE FUNCTION ql.recusa(p_texto text, p_esperado boolean)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := privado.eh_recusa(p_texto);
  PERFORM ql.confere(
    CASE WHEN p_esperado THEN 'RECUSA: ' ELSE 'não é recusa: ' END || p_texto,
    (v IS NOT NULL) = p_esperado,
    coalesce(v, '(nenhum termo)'));
END; $$;

-- ===========================================================================
-- 1. O que É recusa
-- ===========================================================================

SELECT ql.recusa('Não tenho interesse, obrigado', true);
SELECT ql.recusa('sem interesse', true);
SELECT ql.recusa('Nao me interessa', true);
SELECT ql.recusa('não interessa', true);
SELECT ql.recusa('Não, obrigado!', true);
SELECT ql.recusa('nao obrigada', true);
SELECT ql.recusa('Não preciso', true);
SELECT ql.recusa('para de me mandar mensagem', true);
SELECT ql.recusa('não quero nada', true);
SELECT ql.recusa('nao quero obrigado', true);

-- ===========================================================================
-- 2. O que NÃO é recusa — e é aqui que o dinheiro está
-- ===========================================================================

-- O caso que o D48 documentou do outro lado: resposta de COMPRA que parece
-- recusa se olhada por palavra solta.
SELECT ql.recusa('não quero individual, quero empresarial', false);
SELECT ql.recusa('nao quero o basico, quero o completo', false);

-- Quem já tem plano e respondeu é exatamente quem quer trocar de operadora.
SELECT ql.recusa('já tenho plano pela empresa', false);
SELECT ql.recusa('ja tenho a unimed', false);

-- Interesse explícito.
SELECT ql.recusa('tenho interesse sim', false);
SELECT ql.recusa('quero saber mais', false);
SELECT ql.recusa('me manda os valores', false);
SELECT ql.recusa('qual o preço?', false);

-- Dúvida, adiamento e resposta morna: tudo vai para uma pessoa.
SELECT ql.recusa('agora não posso falar, me liga amanhã', false);
SELECT ql.recusa('quem é?', false);
SELECT ql.recusa('pode me explicar melhor?', false);
SELECT ql.recusa('vou pensar', false);
SELECT ql.recusa('ok', false);

-- Texto vazio ou ausente não é recusa — é falta de informação.
SELECT ql.recusa('', false);
SELECT ql.confere('texto nulo não é recusa', privado.eh_recusa(NULL) IS NULL);

-- Palavra inteira, não fragmento: a mesma trava do D48.
SELECT ql.recusa('o plano nao preciscava ser tao caro', false);

-- ===========================================================================
-- 3. Ponta a ponta: a resposta move o card
-- ===========================================================================

\set tenant '\'a1000000-0000-0000-0000-0000000000a0\''

INSERT INTO tenants (id, nome, slug) VALUES (:tenant, 'Corretora Qualifica', 'corretora-qualifica');
INSERT INTO campaigns (id, tenant_id, nome, tipo, base_legal, canais_habilitados)
VALUES ('a1000000-0000-0000-0000-0000000000c1', :tenant, 'Q', 'morna', 'opt-in', '{whatsapp}');
INSERT INTO flows (id, tenant_id, nome) VALUES ('a1000000-0000-0000-0000-0000000000e0', :tenant, 'Q');
INSERT INTO flow_versions (id, tenant_id, flow_id, versao)
VALUES ('a1000000-0000-0000-0000-0000000000e1', :tenant, 'a1000000-0000-0000-0000-0000000000e0', 1);
INSERT INTO flow_steps (id, tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
VALUES ('a1000000-0000-0000-0000-0000000000e2', :tenant, 'a1000000-0000-0000-0000-0000000000e1',
        1, 'whatsapp', 0, 'oi');
INSERT INTO sender_accounts (id, tenant_id, canal, provedor, identificador, tipo_permitido, quota_diaria)
VALUES ('a1000000-0000-0000-0000-00000000005a', :tenant, 'whatsapp', 'uazapi',
        '5511990001010', 'morna', 100);

-- Três pessoas: uma que se interessa, uma que recusa, uma que pede para sair.
INSERT INTO contacts (id, tenant_id, nome, origem) VALUES
  ('a1000000-0000-0000-0000-0000000000d1', :tenant, 'Ana Interessada', 'planilha'),
  ('a1000000-0000-0000-0000-0000000000d2', :tenant, 'Bruno Recusou', 'planilha'),
  ('a1000000-0000-0000-0000-0000000000d3', :tenant, 'Carla PediuSair', 'planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
SELECT :tenant, id, 'whatsapp', '+55 11 95000-000' || right(id::text, 1),
       '551195000000' || right(id::text, 1), 'planilha'
  FROM contacts WHERE tenant_id = :tenant;

INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id)
SELECT ('a1000000-0000-0000-0000-0000000000b' || right(id::text, 1))::uuid, :tenant, id,
       'a1000000-0000-0000-0000-0000000000c1', 'a1000000-0000-0000-0000-0000000000e1'
  FROM contacts WHERE tenant_id = :tenant;

INSERT INTO messages (id, tenant_id, enrollment_id, step_id, contact_identity_id,
                      sender_account_id, canal, status, conteudo)
SELECT ('a1000000-0000-0000-0000-00000000aa0' || right(e.contact_id::text, 1))::uuid,
       :tenant, e.id, 'a1000000-0000-0000-0000-0000000000e2', ci.id,
       'a1000000-0000-0000-0000-00000000005a', 'whatsapp', 'pendente', 'oi'
  FROM enrollments e JOIN contact_identities ci ON ci.contact_id = e.contact_id
 WHERE e.tenant_id = :tenant;

UPDATE messages SET status = 'enviado' WHERE tenant_id = :tenant;

CREATE FUNCTION ql.estagio(p_contato uuid) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT s.slug FROM deals d JOIN pipeline_stages s ON s.id = d.stage_id
   WHERE d.contact_id = p_contato;
$$;

SELECT ql.confere('os três estão em contatado antes de responder',
  (SELECT count(*) = 3 FROM contacts c WHERE c.tenant_id = :tenant
     AND ql.estagio(c.id) = 'contatado'),
  (SELECT string_agg(ql.estagio(c.id), ', ') FROM contacts c WHERE c.tenant_id = :tenant));

-- Ana se interessa.
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
VALUES (:tenant, 'a1000000-0000-0000-0000-00000000aa01', 'respondido',
        '{"texto":"tenho interesse sim, quero saber os valores"}'::jsonb);
SELECT ql.confere('quem se interessa vira oportunidade',
  ql.estagio('a1000000-0000-0000-0000-0000000000d1') = 'oportunidade',
  ql.estagio('a1000000-0000-0000-0000-0000000000d1'));

-- Bruno recusa: fica em respondeu, sem estágio de recusa inventado.
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
VALUES (:tenant, 'a1000000-0000-0000-0000-00000000aa02', 'respondido',
        '{"texto":"nao tenho interesse, obrigado"}'::jsonb);
SELECT ql.confere('quem recusa fica em respondeu, não vira oportunidade',
  ql.estagio('a1000000-0000-0000-0000-0000000000d2') = 'respondeu',
  ql.estagio('a1000000-0000-0000-0000-0000000000d2'));
-- O achado do D58: antes desta correção, "nao tenho interesse" estava na
-- lista de OPT-OUT valendo sozinho, e esta pessoa era suprimida para sempre.
-- Recusar a oferta não é pedir para sair da lista.
SELECT ql.confere('e quem recusa NÃO é suprimido — pode valer uma campanha futura',
  NOT EXISTS (SELECT 1 FROM suppression
               WHERE contact_id = 'a1000000-0000-0000-0000-0000000000d2'));

SELECT ql.confere('"nao tenho interesse" deixou de ser opt-out',
  privado.pedido_de_saida('nao tenho interesse, obrigado') IS NULL,
  coalesce(privado.pedido_de_saida('nao tenho interesse, obrigado'), '(nenhum)'));
SELECT ql.confere('"sem interesse" deixou de ser opt-out',
  privado.pedido_de_saida('sem interesse') IS NULL,
  coalesce(privado.pedido_de_saida('sem interesse'), '(nenhum)'));

-- E o que É pedido de saída continua sendo, valendo sozinho.
SELECT ql.confere('"pare" continua suprimindo sozinho',
  privado.pedido_de_saida('pare') IS NOT NULL);
SELECT ql.confere('"descadastrar" continua suprimindo sozinho',
  privado.pedido_de_saida('quero descadastrar') IS NOT NULL);
SELECT ql.confere('"nao envie mais" continua suprimindo sozinho',
  privado.pedido_de_saida('nao envie mais') IS NOT NULL);

-- Carla pede para sair: opt_out ganha de tudo.
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
VALUES (:tenant, 'a1000000-0000-0000-0000-00000000aa03', 'respondido',
        '{"texto":"pare de me mandar mensagem, quero sair da lista"}'::jsonb);
SELECT ql.confere('quem pede para sair vai para opt_out, não para oportunidade',
  ql.estagio('a1000000-0000-0000-0000-0000000000d3') = 'opt_out',
  ql.estagio('a1000000-0000-0000-0000-0000000000d3'));
SELECT ql.confere('e é suprimido',
  EXISTS (SELECT 1 FROM suppression
           WHERE contact_id = 'a1000000-0000-0000-0000-0000000000d3'));

-- A linha do tempo diz QUEM decidiu.
SELECT ql.confere('o movimento para oportunidade ficou marcado como decisão de classificador',
  (SELECT origem = 'ia' FROM deal_activities a
     JOIN pipeline_stages s ON s.id = a.para_stage_id
    WHERE s.slug = 'oportunidade'
      AND a.deal_id = (SELECT id FROM deals WHERE contact_id = 'a1000000-0000-0000-0000-0000000000d1')),
  (SELECT origem::text FROM deal_activities a
     JOIN pipeline_stages s ON s.id = a.para_stage_id
    WHERE s.slug = 'oportunidade'
      AND a.deal_id = (SELECT id FROM deals WHERE contact_id = 'a1000000-0000-0000-0000-0000000000d1')));

-- E a invariante 4 continua valendo: responder encerrou a cadência dos três.
SELECT ql.confere('responder encerrou a cadência, oportunidade ou não',
  (SELECT count(*) = 3 FROM enrollments
    WHERE tenant_id = :tenant AND status = 'encerrado' AND motivo_encerramento = 'resposta'));

-- Payload que não é string não classifica nada (a trava do D48).
INSERT INTO contacts (id, tenant_id, nome, origem)
VALUES ('a1000000-0000-0000-0000-0000000000d4', :tenant, 'Davi Audio', 'planilha');
INSERT INTO contact_identities (tenant_id, contact_id, canal, valor, valor_norm, origem)
VALUES (:tenant, 'a1000000-0000-0000-0000-0000000000d4', 'whatsapp',
        '+55 11 95000-0004', '5511950000004', 'planilha');
INSERT INTO enrollments (id, tenant_id, contact_id, campaign_id, flow_version_id)
VALUES ('a1000000-0000-0000-0000-0000000000b4', :tenant, 'a1000000-0000-0000-0000-0000000000d4',
        'a1000000-0000-0000-0000-0000000000c1', 'a1000000-0000-0000-0000-0000000000e1');
INSERT INTO messages (id, tenant_id, enrollment_id, step_id, contact_identity_id,
                      sender_account_id, canal, status, conteudo)
VALUES ('a1000000-0000-0000-0000-00000000aa04', :tenant, 'a1000000-0000-0000-0000-0000000000b4',
        'a1000000-0000-0000-0000-0000000000e2',
        (SELECT id FROM contact_identities WHERE contact_id = 'a1000000-0000-0000-0000-0000000000d4'),
        'a1000000-0000-0000-0000-00000000005a', 'whatsapp', 'enviado', 'oi');
INSERT INTO message_events (tenant_id, message_id, tipo, payload)
VALUES (:tenant, 'a1000000-0000-0000-0000-00000000aa04', 'respondido',
        '{"texto":{"body":"veio como objeto"}}'::jsonb);

-- Respondeu de verdade (o funil registra), mas não foi classificado: sem
-- texto legível, não há juízo a fazer. Fica para uma pessoa ler.
SELECT ql.confere('resposta sem texto legível para em respondeu, sem virar oportunidade',
  ql.estagio('a1000000-0000-0000-0000-0000000000d4') = 'respondeu',
  ql.estagio('a1000000-0000-0000-0000-0000000000d4'));

SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS status, nome, detalhe
  FROM ql.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM ql.resultado;

DO $$
DECLARE n integer;
BEGIN
  SELECT count(*) INTO n FROM ql.resultado WHERE NOT ok;
  IF n > 0 THEN RAISE EXCEPTION 'qualificação: % asserção(ões) falharam', n; END IF;
END;
$$;
