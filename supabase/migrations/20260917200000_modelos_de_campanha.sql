-- Modelos de campanha: o catálogo do hub.
--
-- Criar campanha do zero é escrever cadência, escolher canal e definir atraso
-- entre passos — trabalho de quem conhece o motor. O modelo é o atalho: quem
-- opera escolhe "Resgate multicanal", marca os canais que quer usar e sai com
-- uma campanha pronta.
--
-- Um modelo NÃO é uma campanha. É a receita. Instanciar cria campaign, flow,
-- flow_version e flow_steps novos — e, como flow_version é imutável (D9),
-- editar o modelo depois não mexe em nenhuma campanha já criada.

CREATE TABLE campaign_templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text NOT NULL UNIQUE,
  nome        text NOT NULL,
  descricao   text NOT NULL,
  objetivo    text NOT NULL,
  tipo        tipo_campanha NOT NULL,
  base_legal  text NOT NULL,
  -- Canais que o modelo sabe usar. O operador escolhe um subconjunto na hora
  -- de criar; o que não for escolhido some da cadência.
  canais      canal[] NOT NULL,
  passos      jsonb NOT NULL,
  ordem       integer NOT NULL DEFAULT 0,
  ativo       boolean NOT NULL DEFAULT true,
  criado_em   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT campaign_templates_canais_nao_vazio CHECK (cardinality(canais) > 0),
  CONSTRAINT campaign_templates_passos_nao_vazio CHECK (jsonb_array_length(passos) > 0)
);

COMMENT ON COLUMN campaign_templates.passos IS
  'Receita da cadência: [{"canal","atraso_horas","template"}], em ordem.';

-- Ligação de rastreio: de qual modelo esta campanha nasceu.
ALTER TABLE campaigns
  ADD COLUMN template_slug text REFERENCES campaign_templates(slug),
  ADD COLUMN objetivo text;

-- ---------------------------------------------------------------------------
-- Instanciação
-- ---------------------------------------------------------------------------

-- Cria campanha + flow + versão 1 + passos a partir de um modelo.
-- p_canais filtra a cadência: passo de canal não escolhido não entra.
CREATE FUNCTION criar_campanha_de_modelo(
  p_slug   text,
  p_nome   text,
  p_canais canal[] DEFAULT NULL
)
RETURNS TABLE (campaign_id uuid, flow_version_id uuid, passos_criados integer)
LANGUAGE plpgsql AS $$
DECLARE
  m          campaign_templates%ROWTYPE;
  v_canais   canal[];
  v_campanha uuid;
  v_flow     uuid;
  v_versao   uuid;
  v_passo    jsonb;
  v_ordem    integer := 0;
BEGIN
  SELECT * INTO m FROM campaign_templates WHERE slug = p_slug AND ativo;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'modelo inexistente ou inativo: %', p_slug
      USING ERRCODE = 'no_data_found';
  END IF;

  v_canais := coalesce(p_canais, m.canais);

  -- Canal que o modelo não conhece não entra por engano.
  IF EXISTS (SELECT 1 FROM unnest(v_canais) c WHERE NOT (c = ANY (m.canais))) THEN
    RAISE EXCEPTION 'modelo % não atende os canais pedidos (%), só %',
      p_slug, v_canais, m.canais
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Modelo sem nenhum passo nos canais escolhidos viraria campanha que não
  -- manda nada. Melhor recusar na criação do que descobrir em produção.
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(m.passos) s
     WHERE (s ->> 'canal')::canal = ANY (v_canais)
  ) THEN
    RAISE EXCEPTION 'modelo % não tem nenhum passo nos canais %', p_slug, v_canais
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO campaigns (nome, tipo, base_legal, canais_habilitados, template_slug, objetivo)
  VALUES (p_nome, m.tipo, m.base_legal, v_canais, m.slug, m.objetivo)
  RETURNING id INTO v_campanha;

  INSERT INTO flows (nome) VALUES (p_nome) RETURNING id INTO v_flow;
  INSERT INTO flow_versions (flow_id, versao) VALUES (v_flow, 1) RETURNING id INTO v_versao;

  FOR v_passo IN
    SELECT s FROM jsonb_array_elements(m.passos) WITH ORDINALITY AS t(s, i)
     WHERE (s ->> 'canal')::canal = ANY (v_canais)
     ORDER BY i
  LOOP
    v_ordem := v_ordem + 1;
    INSERT INTO flow_steps (flow_version_id, ordem, canal, atraso_horas, template)
    VALUES (v_versao, v_ordem,
            (v_passo ->> 'canal')::canal,
            -- Primeiro passo sai na hora, independente do que o modelo diz:
            -- o atraso do modelo é entre passos, não antes do primeiro.
            CASE WHEN v_ordem = 1 THEN 0
                 ELSE coalesce((v_passo ->> 'atraso_horas')::integer, 24) END,
            v_passo ->> 'template');
  END LOOP;

  campaign_id := v_campanha; flow_version_id := v_versao; passos_criados := v_ordem;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- Catálogo inicial
-- ---------------------------------------------------------------------------

INSERT INTO campaign_templates (slug, nome, descricao, objetivo, tipo, base_legal, canais, passos, ordem) VALUES

('resgate-whatsapp', 'Resgate por WhatsApp',
 'Três toques no WhatsApp para quem já conversou com a corretora e esfriou.',
 'Reabrir conversa com oportunidade parada', 'morna',
 'legítimo interesse — base própria com relacionamento prévio',
 '{whatsapp}',
 '[{"canal":"whatsapp","atraso_horas":0,"template":"Oi {{nome}}, aqui é da Afinix. Você chegou a olhar o plano que conversamos?"},
   {"canal":"whatsapp","atraso_horas":48,"template":"{{nome}}, consegui uma condição melhor que a da nossa conversa. Quer ver?"},
   {"canal":"whatsapp","atraso_horas":96,"template":"{{nome}}, ainda faz sentido retomar? Se não, é só me dizer que eu paro por aqui."}]'::jsonb, 1),

('resgate-multicanal', 'Resgate multicanal',
 'WhatsApp, e-mail e SMS alternados. Quem não responde num canal recebe no outro.',
 'Reabrir oportunidade usando todos os endereços conhecidos', 'morna',
 'legítimo interesse — base própria com relacionamento prévio',
 '{whatsapp,email,sms}',
 '[{"canal":"whatsapp","atraso_horas":0,"template":"Oi {{nome}}, aqui é da Afinix. Podemos retomar aquela cotação?"},
   {"canal":"email","atraso_horas":48,"template":"{{nome}}, separei duas opções que cabem no que você falou."},
   {"canal":"whatsapp","atraso_horas":72,"template":"{{nome}}, te mandei um e-mail com as opções. Prefere que eu resuma por aqui?"},
   {"canal":"sms","atraso_horas":120,"template":"Afinix: {{nome}}, sua cotação continua válida. Responda SIM para retomar."}]'::jsonb, 2),

('resgate-direct', 'Resgate por Direct',
 'Instagram para quem já falou com a corretora por lá. Só dentro da janela de 24h.',
 'Retomar conversa iniciada pelo próprio contato no Instagram', 'morna',
 'resposta em janela de 24h — contato iniciado pelo cliente',
 '{instagram}',
 '[{"canal":"instagram","atraso_horas":0,"template":"Oi {{nome}}! Vi que você perguntou sobre plano de saúde. Posso te ajudar?"},
   {"canal":"instagram","atraso_horas":12,"template":"{{nome}}, consigo montar uma simulação rápida se você me disser a idade e a cidade."}]'::jsonb, 3),

('renovacao-apolice', 'Renovação de apólice',
 'Aviso de vencimento em WhatsApp e SMS, começando 45 dias antes.',
 'Reter cliente antes do vencimento', 'morna',
 'execução de contrato — cliente ativo',
 '{whatsapp,sms}',
 '[{"canal":"whatsapp","atraso_horas":0,"template":"{{nome}}, sua apólice vence em breve. Quer que eu revise as condições antes da renovação?"},
   {"canal":"whatsapp","atraso_horas":168,"template":"{{nome}}, comparei seu plano com o que está no mercado hoje. Te mando?"},
   {"canal":"sms","atraso_horas":336,"template":"Afinix: {{nome}}, sua apólice vence em 15 dias. Responda SIM para falar com seu corretor."}]'::jsonb, 4),

('reengajamento', 'Reengajamento',
 'Para quem respondeu, esfriou e nunca fechou. Retoma de onde a conversa parou.',
 'Recuperar conversa que morreu no meio', 'morna',
 'legítimo interesse — contato respondeu anteriormente',
 '{whatsapp,email}',
 '[{"canal":"whatsapp","atraso_horas":0,"template":"{{nome}}, ficamos de continuar aquela conversa. Ainda quer que eu monte a proposta?"},
   {"canal":"email","atraso_horas":72,"template":"{{nome}}, deixo aqui o resumo do que conversamos, caso queira retomar."}]'::jsonb, 5),

('prospeccao-fria', 'Prospecção fria — WhatsApp',
 'Dois toques em lista fria, com chip separado e volume baixo por dia.',
 'Abrir conversa com quem nunca falou com a corretora', 'fria',
 'legítimo interesse — prospecção B2B',
 '{whatsapp}',
 '[{"canal":"whatsapp","atraso_horas":0,"template":"Olá {{nome}}, trabalho com plano de saúde empresarial em {{cidade}}. Faz sentido conversarmos?"},
   {"canal":"whatsapp","atraso_horas":96,"template":"{{nome}}, consigo fazer uma cotação sem compromisso. Quer que eu envie?"}]'::jsonb, 6),

('prospeccao-fria-multicanal', 'Prospecção fria — multicanal',
 'WhatsApp e e-mail em domínio separado do institucional. Pool frio isolado.',
 'Abrir conversa em lista fria sem arriscar o domínio da operação', 'fria',
 'legítimo interesse — prospecção B2B',
 '{whatsapp,email}',
 '[{"canal":"email","atraso_horas":0,"template":"{{nome}}, ajudo empresas de {{cidade}} a reduzir o custo do plano de saúde. Posso mandar um comparativo?"},
   {"canal":"whatsapp","atraso_horas":72,"template":"Olá {{nome}}, te mandei um e-mail sobre plano empresarial. Prefere falar por aqui?"},
   {"canal":"email","atraso_horas":168,"template":"{{nome}}, último toque. Se não for o momento, é só ignorar este e-mail."}]'::jsonb, 7);
