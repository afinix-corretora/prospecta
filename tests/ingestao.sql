-- Ingestão de contato (D32).
--
-- O que este arquivo sustenta: reimportar a mesma planilha não duplica pessoa
-- (D2), quem diz que é a mesma pessoa é a identidade e nunca o nome, fundir
-- dois contatos existentes é recusado em vez de decidido em silêncio, e
-- identidade não normalizada não entra — porque `valor_norm` é a chave de
-- dedup e de supressão ao mesmo tempo.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

CREATE SCHEMA ig;
CREATE TABLE ig.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);
CREATE FUNCTION ig.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN INSERT INTO ig.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $$;

\set t '00000000-0000-0000-0000-0000000000aa'

-- ---------------------------------------------------------------------------
-- A trava de normalização
-- ---------------------------------------------------------------------------

SELECT ig.confere('telefone normalizado é só dígito com DDI',
  privado.normalizada('whatsapp','5511999990000')
  AND NOT privado.normalizada('whatsapp','+55 11 99999-0000'));

SELECT ig.confere('e-mail normalizado é minúsculo e sem espaço',
  privado.normalizada('email','ana@exemplo.com.br')
  AND NOT privado.normalizada('email','Ana@Exemplo.com.br')
  AND NOT privado.normalizada('email','ana@exemplo'));

SELECT ig.confere('handle do Instagram não guarda a arroba',
  privado.normalizada('instagram','afinix.corretora')
  AND NOT privado.normalizada('instagram','@afinix.corretora'));

-- ---------------------------------------------------------------------------
-- Criar, reimportar, acrescentar canal
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_primeiro uuid;
BEGIN
  SELECT * INTO r FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"(11) 99999-0000","valor_norm":"5511999990000"}]'::jsonb,
    'Marina Alves', 'linha-1', '{"cidade":"São Paulo"}'::jsonb);

  v_primeiro := r.contact_id;
  PERFORM ig.confere('primeira ingestão cria o contato',
    r.acao = 'criado' AND r.identidades_novas = 1 AND r.identidades_existentes = 0, r.acao);

  -- Mesma planilha de novo: mesma pessoa, nada duplicado.
  SELECT * INTO r FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"(11) 99999-0000","valor_norm":"5511999990000"}]'::jsonb,
    'Marina Alves', 'linha-1', '{}'::jsonb);

  PERFORM ig.confere('reimportar a mesma linha não duplica (D2)',
    r.acao = 'atualizado' AND r.contact_id = v_primeiro
    AND r.identidades_novas = 0 AND r.identidades_existentes = 1,
    r.acao || ' novas=' || r.identidades_novas);

  PERFORM ig.confere('reimportar não cria segunda pessoa',
    (SELECT count(*) = 1 FROM contacts WHERE nome = 'Marina Alves'));

  -- Segunda fonte acrescenta o e-mail à MESMA pessoa, pelo telefone.
  SELECT * INTO r FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'pipefy',
    '[{"canal":"whatsapp","valor":"+5511999990000","valor_norm":"5511999990000"},
      {"canal":"email","valor":"Marina@Exemplo.com","valor_norm":"marina@exemplo.com"}]'::jsonb,
    NULL, 'card-9', '{"apolice":"AB-1"}'::jsonb);

  PERFORM ig.confere('canal novo entra na mesma pessoa, não numa nova',
    r.contact_id = v_primeiro AND r.identidades_novas = 1 AND r.identidades_existentes = 1,
    'novas=' || r.identidades_novas || ' existentes=' || r.identidades_existentes);

  PERFORM ig.confere('nome não é apagado por fonte que não traz nome',
    (SELECT nome = 'Marina Alves' FROM contacts WHERE id = v_primeiro),
    (SELECT coalesce(nome,'(nulo)') FROM contacts WHERE id = v_primeiro));

  PERFORM ig.confere('metadados são mesclados, não substituídos',
    (SELECT metadados ? 'cidade' AND metadados ? 'apolice' FROM contacts WHERE id = v_primeiro),
    (SELECT metadados::text FROM contacts WHERE id = v_primeiro));
END;
$$;

-- ---------------------------------------------------------------------------
-- O que precisa ser recusado
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  PERFORM ingerir_contato('00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"(11) 98888-0000","valor_norm":"(11) 98888-0000"}]'::jsonb);
  PERFORM ig.confere('identidade não normalizada é recusada', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM ig.confere('identidade não normalizada é recusada', true);
WHEN others THEN
  PERFORM ig.confere('identidade não normalizada é recusada', false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

DO $$
BEGIN
  PERFORM ingerir_contato('00000000-0000-0000-0000-0000000000aa', 'planilha', '[]'::jsonb, 'Sem canal');
  PERFORM ig.confere('contato sem identidade é recusado', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM ig.confere('contato sem identidade é recusado', true);
END;
$$;

DO $$
BEGIN
  PERFORM ingerir_contato('00000000-0000-0000-0000-0000000000aa', '   ',
    '[{"canal":"email","valor":"x@y.com","valor_norm":"x@y.com"}]'::jsonb);
  PERFORM ig.confere('contato sem origem é recusado', false, 'aceitou');
EXCEPTION WHEN invalid_parameter_value THEN
  PERFORM ig.confere('contato sem origem é recusado', true);
END;
$$;

-- Fusão: o telefone é de uma pessoa, o e-mail é de outra, as duas já existem.
DO $$
BEGIN
  PERFORM ingerir_contato('00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"email","valor":"outro@exemplo.com","valor_norm":"outro@exemplo.com"}]'::jsonb,
    'Outra Pessoa');

  PERFORM ingerir_contato('00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"whatsapp","valor":"+5511999990000","valor_norm":"5511999990000"},
      {"canal":"email","valor":"outro@exemplo.com","valor_norm":"outro@exemplo.com"}]'::jsonb);

  PERFORM ig.confere('fundir dois contatos existentes é recusado, não decidido', false, 'fundiu em silêncio');
EXCEPTION WHEN restrict_violation THEN
  PERFORM ig.confere('fundir dois contatos existentes é recusado, não decidido', true);
WHEN others THEN
  PERFORM ig.confere('fundir dois contatos existentes é recusado, não decidido',
    false, SQLSTATE || ': ' || SQLERRM);
END;
$$;

-- ---------------------------------------------------------------------------
-- Supressão: grava e avisa, o gate continua sendo o roteador
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record;
BEGIN
  INSERT INTO suppression (tenant_id, canal, valor_norm, motivo)
  VALUES ('00000000-0000-0000-0000-0000000000aa','email','suprimido@exemplo.com','opt-out');

  SELECT * INTO r FROM ingerir_contato(
    '00000000-0000-0000-0000-0000000000aa', 'planilha',
    '[{"canal":"email","valor":"suprimido@exemplo.com","valor_norm":"suprimido@exemplo.com"}]'::jsonb,
    'Quem pediu para sair');

  PERFORM ig.confere('endereço suprimido é ingerido e contado, não escondido',
    r.identidades_suprimidas = 1 AND r.identidades_novas = 1,
    'suprimidas=' || r.identidades_suprimidas);
END;
$$;

-- ---------------------------------------------------------------------------
-- Tenant: o mesmo telefone pode ser de dois clientes do produto
-- ---------------------------------------------------------------------------

DO $$
DECLARE r record; v_outro uuid := '00000000-0000-0000-0000-0000000000bb';
BEGIN
  INSERT INTO tenants (id, nome, slug) VALUES (v_outro, 'Outro Cliente', 'outro');

  SELECT * INTO r FROM ingerir_contato(v_outro, 'planilha',
    '[{"canal":"whatsapp","valor":"+5511999990000","valor_norm":"5511999990000"}]'::jsonb,
    'Mesma pessoa, outro cliente');

  PERFORM ig.confere('o mesmo número em outro tenant é outro contato',
    r.acao = 'criado' AND r.identidades_novas = 1, r.acao);

  PERFORM ig.confere('e não vaza para o tenant de origem',
    (SELECT count(*) = 2 FROM contact_identities
      WHERE canal = 'whatsapp' AND valor_norm = '5511999990000'));
END;
$$;

\echo ''
\echo '============= INGESTÃO ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM ig.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou,
       count(*) AS total
  FROM ig.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ig.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'ingestão: % asserções falharam',
      (SELECT count(*) FROM ig.resultado WHERE NOT ok);
  END IF;
END;
$$;
