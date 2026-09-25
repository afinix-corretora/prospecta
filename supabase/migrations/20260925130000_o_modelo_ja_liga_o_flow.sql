-- O modelo liga o flow que ele mesmo acabou de criar (D54).
--
-- O D47 deu à campanha a coluna `flow_version_id` e o ato de apontá-la, e
-- deixou de fora o único lugar do produto que cria os dois lados na mesma
-- chamada. `criar_campanha_de_modelo` cria a campanha, cria o flow, cria a
-- versão, cria os passos, DEVOLVE os dois ids — e não os liga. Toda campanha
-- nascida pelo Hub nasce, portanto, sem flow.
--
-- E o efeito disso é silencioso, que é o que torna a falta grave: campanha
-- sem flow não dá erro na tela; ela só faz `inscrever_pela_campanha` e
-- `prever_inscricao_pela_campanha` recusarem quando alguém finalmente for
-- inscrever, e é nesse momento — depois de importar a planilha, depois de
-- escolher os contatos — que a pessoa descobre. É o "pergunte uma vez o que é
-- da campanha" do D47 respondido com "nunca".
--
-- A ligação é feita chamando `definir_flow_da_campanha`, e não com um UPDATE
-- aqui dentro, de propósito: a conferência de canais do D47 mora lá. Cruzar
-- não pode falhar neste caminho (os passos foram filtrados justamente pelos
-- canais da campanha, e a função já recusa acima o modelo sem passo nenhum),
-- e é exatamente por isso que chamar custa nada e repetir a regra custaria a
-- próxima divergência entre as duas cópias.
--
-- Por que dentro da função e não na tela: `tests/tenants.sql` e o backfill
-- chamam `criar_campanha_de_modelo` direto, sem app nenhum. Ligar do lado de
-- fora deixaria esses caminhos com o defeito, e deixaria uma janela — criou,
-- caiu a rede, campanha órfã — que aqui não existe, porque a função inteira é
-- uma transação.
--
-- Sem barra invertida (D32).

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

  -- A linha que faltava. Os passos já existem quando ela roda: a conferência
  -- de canais do D47 precisa deles para ter o que cruzar.
  PERFORM public.definir_flow_da_campanha(v_campanha, v_versao);

  campaign_id := v_campanha; flow_version_id := v_versao; passos_criados := v_ordem;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION criar_campanha_de_modelo(uuid, text, text, canal[]) IS
  'Cria campanha, flow, versão e passos a partir do modelo — e liga a campanha
   à versão criada, para que a pergunta do D47 nasça respondida (D54).';

-- CREATE OR REPLACE preserva a ACL, mas repetir o GRANT é a disciplina desta
-- base desde o D31: função que a UI chama e que perde EXECUTE vira um 404
-- que ninguém relaciona com a migration que a substituiu.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION criar_campanha_de_modelo(uuid, text, text, canal[])
      TO authenticated;
  END IF;
END;
$$;
