-- Volta a criar campanha e flow sem ligá-los.
--
-- Reverter isto devolve a campanha órfã descrita na migration. Está aqui
-- porque toda migration é reversível; a campanha criada enquanto a versão
-- corrigida esteve no ar continua ligada, e isso é desejável.

CREATE OR REPLACE FUNCTION criar_campanha_de_modelo(
  p_tenant uuid, p_slug text, p_nome text, p_canais canal[] DEFAULT NULL
)
RETURNS TABLE (campaign_id uuid, flow_version_id uuid, passos_criados integer)
LANGUAGE plpgsql AS $$
DECLARE
  m campaign_templates%ROWTYPE; v_canais canal[];
  v_campanha uuid; v_flow uuid; v_versao uuid; v_passo jsonb; v_ordem integer := 0;
BEGIN
  SELECT * INTO m FROM campaign_templates
   WHERE slug = p_slug AND ativo AND (tenant_id IS NULL OR tenant_id = p_tenant)
   ORDER BY tenant_id NULLS LAST LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'modelo inexistente ou inativo: %', p_slug USING ERRCODE = 'no_data_found';
  END IF;

  v_canais := coalesce(p_canais, m.canais);

  IF EXISTS (SELECT 1 FROM unnest(v_canais) c WHERE NOT (c = ANY (m.canais))) THEN
    RAISE EXCEPTION 'modelo % não atende os canais pedidos (%), só %', p_slug, v_canais, m.canais
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(m.passos) s
                  WHERE (s ->> 'canal')::canal = ANY (v_canais)) THEN
    RAISE EXCEPTION 'modelo % não tem nenhum passo nos canais %', p_slug, v_canais
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO campaigns (tenant_id, nome, tipo, base_legal, canais_habilitados,
                         template_slug, objetivo)
  VALUES (p_tenant, p_nome, m.tipo, m.base_legal, v_canais, m.slug, m.objetivo)
  RETURNING id INTO v_campanha;

  INSERT INTO flows (tenant_id, nome) VALUES (p_tenant, p_nome) RETURNING id INTO v_flow;
  INSERT INTO flow_versions (tenant_id, flow_id, versao)
  VALUES (p_tenant, v_flow, 1) RETURNING id INTO v_versao;

  FOR v_passo IN
    SELECT s FROM jsonb_array_elements(m.passos) WITH ORDINALITY AS t(s, i)
     WHERE (s ->> 'canal')::canal = ANY (v_canais) ORDER BY i
  LOOP
    v_ordem := v_ordem + 1;
    INSERT INTO flow_steps (tenant_id, flow_version_id, ordem, canal, atraso_horas, template)
    VALUES (p_tenant, v_versao, v_ordem, (v_passo ->> 'canal')::canal,
            CASE WHEN v_ordem = 1 THEN 0
                 ELSE coalesce((v_passo ->> 'atraso_horas')::integer, 24) END,
            v_passo ->> 'template');
  END LOOP;

  campaign_id := v_campanha; flow_version_id := v_versao; passos_criados := v_ordem;
  RETURN NEXT;
END;
$$;
