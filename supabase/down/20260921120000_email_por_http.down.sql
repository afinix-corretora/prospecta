-- Reverte o e-mail por HTTP.
--
-- Só remove o provedor se nenhuma conta estiver usando: apagar provedor com
-- remetente apontando para ele é o que a chave estrangeira existe para
-- impedir — mesma cautela do down da UAZAPI.

DELETE FROM channel_provider_catalog
 WHERE slug = 'resend'
   AND NOT EXISTS (SELECT 1 FROM sender_accounts WHERE provedor = 'resend');

UPDATE channel_provider_catalog SET ordem = 5, descricao =
  'Caixa de saída própria. Campanha fria usa domínio separado do institucional (D4).'
 WHERE slug = 'smtp';

UPDATE channel_provider_catalog SET ordem = 6 WHERE slug = 'instagram_oficial';

-- Volta a versão do D26: sem checagem de obrigatório e sem preservar o segredo
-- antigo. Recriar o corpo inteiro é o único jeito de reverter um OR REPLACE.
CREATE OR REPLACE FUNCTION salvar_credencial_remetente(
  p_sender_id   uuid,
  p_credenciais jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, privado AS $$
DECLARE v_tenant uuid; v_provedor text; v_segredo uuid; v_proibida text;
BEGIN
  SELECT tenant_id, provedor INTO v_tenant, v_provedor
    FROM sender_accounts WHERE id = p_sender_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remetente inexistente: %', p_sender_id USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT privado.pode_administrar(v_tenant) THEN
    RAISE EXCEPTION 'só quem administra o cliente configura remetente'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- O catálogo manda: campo que não é do provedor não entra no Vault como se
  -- fosse credencial dele.
  SELECT k INTO v_proibida
    FROM jsonb_object_keys(p_credenciais) k
   WHERE NOT EXISTS (
     SELECT 1 FROM channel_provider_catalog p, jsonb_array_elements(p.campos) c
      WHERE p.slug = v_provedor AND c ->> 'chave' = k)
   LIMIT 1;

  IF v_proibida IS NOT NULL THEN
    RAISE EXCEPTION 'campo % não existe no provedor %', v_proibida, v_provedor
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_segredo := privado.guardar_segredo(
    'remetente:' || v_provedor || ':' || p_sender_id::text || ':' || gen_random_uuid()::text,
    p_credenciais::text);

  UPDATE sender_accounts SET credenciais_secret_id = v_segredo WHERE id = p_sender_id;
END;
$$;

COMMENT ON FUNCTION salvar_credencial_remetente IS NULL;
