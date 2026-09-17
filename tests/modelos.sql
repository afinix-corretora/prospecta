-- Testes dos modelos de campanha e da instanciação.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA mo;
CREATE TABLE mo.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION mo.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO mo.resultado (nome, ok, detalhe) VALUES (p_nome, coalesce(p_cond,false), p_detalhe); END; $$;

-- ---------------------------------------------------------------------------
-- Catálogo
-- ---------------------------------------------------------------------------

SELECT mo.confere('catálogo tem modelos ativos',
  (SELECT count(*) >= 7 FROM campaign_templates WHERE ativo));

SELECT mo.confere('todo modelo declara base legal',
  NOT EXISTS (SELECT 1 FROM campaign_templates WHERE length(trim(base_legal)) = 0));

SELECT mo.confere('todo passo de modelo usa um canal que o modelo declara',
  NOT EXISTS (
    SELECT 1 FROM campaign_templates t, jsonb_array_elements(t.passos) s
     WHERE NOT ((s ->> 'canal')::canal = ANY (t.canais))));

SELECT mo.confere('todo passo de modelo tem texto',
  NOT EXISTS (
    SELECT 1 FROM campaign_templates t, jsonb_array_elements(t.passos) s
     WHERE coalesce(length(trim(s ->> 'template')),0) = 0));

SELECT mo.confere('modelo frio nunca usa canal de janela restrita',
  NOT EXISTS (SELECT 1 FROM campaign_templates
               WHERE tipo = 'fria' AND 'instagram' = ANY (canais)));

-- ---------------------------------------------------------------------------
-- Instanciar com todos os canais
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_camp campaigns%ROWTYPE;
BEGIN
  SELECT * INTO r FROM criar_campanha_de_modelo('resgate-multicanal','Resgate Q4');

  PERFORM mo.confere('instanciar cria a cadência inteira', r.passos_criados = 4, r.passos_criados::text);

  SELECT * INTO v_camp FROM campaigns WHERE id = r.campaign_id;
  PERFORM mo.confere('campanha herda tipo e base legal do modelo',
    v_camp.tipo = 'morna' AND length(v_camp.base_legal) > 0);
  PERFORM mo.confere('campanha guarda de qual modelo nasceu',
    v_camp.template_slug = 'resgate-multicanal');
  PERFORM mo.confere('campanha nasce ativa', v_camp.ativa);

  PERFORM mo.confere('passos ficam em ordem contígua a partir de 1',
    (SELECT array_agg(ordem ORDER BY ordem) = ARRAY[1,2,3,4]
       FROM flow_steps WHERE flow_version_id = r.flow_version_id));

  PERFORM mo.confere('primeiro passo sai na hora',
    (SELECT atraso_horas = 0 FROM flow_steps
      WHERE flow_version_id = r.flow_version_id AND ordem = 1));

  PERFORM mo.confere('passos seguintes mantêm o atraso do modelo',
    (SELECT bool_and(atraso_horas > 0) FROM flow_steps
      WHERE flow_version_id = r.flow_version_id AND ordem > 1));

  PERFORM mo.confere('versão criada é a 1',
    (SELECT versao = 1 FROM flow_versions WHERE id = r.flow_version_id));
END;
$$;

-- ---------------------------------------------------------------------------
-- Instanciar escolhendo canais — o que o wizard faz
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record;
BEGIN
  -- Mesmo modelo, só WhatsApp: os passos de e-mail e SMS somem.
  SELECT * INTO r FROM criar_campanha_de_modelo('resgate-multicanal','Só WhatsApp','{whatsapp}');

  PERFORM mo.confere('escolher um canal reduz a cadência a esse canal',
    r.passos_criados = 2, r.passos_criados::text);
  PERFORM mo.confere('nenhum passo de canal não escolhido sobrou',
    (SELECT bool_and(canal = 'whatsapp') FROM flow_steps WHERE flow_version_id = r.flow_version_id));
  PERFORM mo.confere('campanha habilita só os canais escolhidos',
    (SELECT canais_habilitados = '{whatsapp}'::canal[] FROM campaigns WHERE id = r.campaign_id));
  PERFORM mo.confere('renumeração mantém a ordem contígua',
    (SELECT array_agg(ordem ORDER BY ordem) = ARRAY[1,2]
       FROM flow_steps WHERE flow_version_id = r.flow_version_id));
  PERFORM mo.confere('o primeiro passo depois do filtro também sai na hora',
    (SELECT atraso_horas = 0 FROM flow_steps
      WHERE flow_version_id = r.flow_version_id AND ordem = 1));
END;
$$;

DO $$
BEGIN
  PERFORM * FROM criar_campanha_de_modelo('resgate-whatsapp','Impossível','{email}');
  PERFORM mo.confere('canal fora do modelo é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM mo.confere('canal fora do modelo é recusado', true);
END;
$$;

DO $$
BEGIN
  PERFORM * FROM criar_campanha_de_modelo('modelo-que-nao-existe','X');
  PERFORM mo.confere('modelo inexistente é recusado', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM mo.confere('modelo inexistente é recusado', true);
END;
$$;

DO $$
BEGIN
  UPDATE campaign_templates SET ativo = false WHERE slug = 'reengajamento';
  PERFORM * FROM criar_campanha_de_modelo('reengajamento','X');
  PERFORM mo.confere('modelo inativo não vira campanha nova', false, 'foi aceito');
EXCEPTION WHEN others THEN
  PERFORM mo.confere('modelo inativo não vira campanha nova', true);
END;
$$;

-- ---------------------------------------------------------------------------
-- D9: modelo não é a campanha
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_antes text;
BEGIN
  SELECT * INTO r FROM criar_campanha_de_modelo('resgate-whatsapp','Congelada');
  SELECT template INTO v_antes FROM flow_steps
   WHERE flow_version_id = r.flow_version_id AND ordem = 1;

  -- Editar o modelo depois não pode mexer em campanha já criada.
  UPDATE campaign_templates
     SET passos = '[{"canal":"whatsapp","atraso_horas":0,"template":"TEXTO NOVO"}]'::jsonb
   WHERE slug = 'resgate-whatsapp';

  PERFORM mo.confere('D9: editar o modelo não altera campanha já criada',
    (SELECT template = v_antes FROM flow_steps
      WHERE flow_version_id = r.flow_version_id AND ordem = 1));
END;
$$;

-- ---------------------------------------------------------------------------
-- A campanha criada de modelo funciona no motor
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_contato uuid; v_enr uuid; v_acao text;
BEGIN
  SELECT * INTO r FROM criar_campanha_de_modelo('prospeccao-fria','Fria SP','{whatsapp}');

  INSERT INTO sender_accounts (canal, identificador, provedor, tipo_permitido, quota_diaria)
  VALUES ('whatsapp','chip-frio-1','evolution','fria',50);

  v_contato := gen_random_uuid();
  INSERT INTO contacts (id, nome, origem, metadados)
  VALUES (v_contato,'Yara','planilha','{"cidade":"Bauru"}');
  INSERT INTO contact_identities (contact_id, canal, valor, valor_norm, origem)
  VALUES (v_contato,'whatsapp','+5514911111','5514911111','planilha');

  v_enr := inscrever(v_contato, r.campaign_id, r.flow_version_id, now() - interval '1 minute');
  SELECT acao INTO v_acao FROM processar_vencidos(10,'simulado') WHERE enrollment_id = v_enr;

  PERFORM mo.confere('campanha de modelo dispara no motor', v_acao = 'mensagem_criada', v_acao);
  PERFORM mo.confere('variáveis do modelo são preenchidas',
    (SELECT conteudo LIKE '%Yara%' AND conteudo LIKE '%Bauru%'
       FROM messages WHERE enrollment_id = v_enr));
  PERFORM mo.confere('D4: campanha fria pegou remetente frio',
    (SELECT sa.tipo_permitido = 'fria' FROM messages m
       JOIN sender_accounts sa ON sa.id = m.sender_account_id
      WHERE m.enrollment_id = v_enr));
END;
$$;

\echo ''
\echo '============= MODELOS DE CAMPANHA ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
FROM mo.resultado ORDER BY id;
\echo ''
SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM mo.resultado;

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM mo.resultado WHERE NOT ok;
  IF v > 0 THEN RAISE EXCEPTION '% asserção(ões) de modelos falharam', v; END IF;
END;
$$;
