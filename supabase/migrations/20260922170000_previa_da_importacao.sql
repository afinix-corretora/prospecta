-- Prévia da importação: contar sem gravar (D34).
--
-- `ingerir_contato` grava. A tela precisa da outra metade — dizer quantos
-- entram, quantos são reimportação, quantos estão suprimidos e quais linhas
-- seriam recusadas, **antes** de escrever qualquer coisa. É a mesma ideia do
-- shadow mode: o caminho inteiro roda sem efeito.
--
-- Sem isto só há duas opções, e as duas são ruins: importar e ver o que
-- aconteceu, ou abrir transação e desfazer — que o PostgREST não permite e
-- que, mesmo permitindo, seria uma escrita de verdade segurando trava numa
-- tabela quente enquanto alguém lê a tela.
--
-- Por que recusar linha aqui em vez de deixar a exceção acontecer: a trava de
-- `ingerir_contato` recusa a **chamada**, não a linha. Uma identidade
-- malformada no meio de 500 mata a importação inteira. A prévia separa as
-- linhas que passam das que não passam para que a pessoa decida antes.
--
-- Não tem barra invertida nenhuma, de propósito — mesma razão do D32.

CREATE FUNCTION prever_ingestao(p_tenant uuid, p_linhas jsonb)
RETURNS TABLE (
  linha                  integer,
  acao                   text,
  contact_id             uuid,
  nome_atual             text,
  identidades_novas      integer,
  identidades_existentes integer,
  identidades_suprimidas integer,
  problema               text
)
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  WITH bruto AS (
    SELECT (e ->> 'linha')::integer AS linha,
           e -> 'identidades'       AS ids
      FROM jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) e
  ),
  -- O canal vem como texto do cliente. Converter com cast abortaria a prévia
  -- inteira num valor inválido, que é exatamente o que ela existe para
  -- evitar; então casa contra os rótulos do enum e deixa NULL o que não casa.
  ident AS (
    SELECT b.linha,
           c.rotulo            AS canal,
           i ->> 'canal'       AS canal_bruto,
           i ->> 'valor_norm'  AS valor_norm
      FROM bruto b
      CROSS JOIN LATERAL jsonb_array_elements(coalesce(b.ids, '[]'::jsonb)) i
      LEFT JOIN LATERAL (
        SELECT v AS rotulo FROM unnest(enum_range(NULL::canal)) v
         WHERE v::text = i ->> 'canal'
      ) c ON true
  ),
  marcada AS (
    SELECT i.linha, i.canal_bruto, i.valor_norm,
           i.canal IS NULL                                  AS sem_canal,
           i.canal IS NOT NULL AND i.valor_norm IS NOT NULL
             AND privado.normalizada(i.canal, i.valor_norm) AS boa,
           ci.contact_id                                    AS dono,
           esta_suprimido(p_tenant, ci.contact_id, i.canal, i.valor_norm) AS suprimida
      FROM ident i
      -- Identidade de outro tenant não é vista, e é isso mesmo: para este
      -- cliente ela não existe, e a linha conta como contato novo.
      LEFT JOIN contact_identities ci
        ON ci.tenant_id = p_tenant AND ci.canal = i.canal AND ci.valor_norm = i.valor_norm
  ),
  agregada AS (
    SELECT m.linha,
           count(*)::integer                                        AS total,
           count(*) FILTER (WHERE NOT m.boa)::integer               AS ruins,
           count(*) FILTER (WHERE m.sem_canal)::integer             AS sem_canal,
           min(m.canal_bruto) FILTER (WHERE m.sem_canal)            AS canal_estranho,
           count(*) FILTER (WHERE m.dono IS NOT NULL)::integer      AS existentes,
           count(*) FILTER (WHERE m.dono IS NULL)::integer          AS novas,
           count(*) FILTER (WHERE m.suprimida)::integer             AS suprimidas,
           min(m.canal_bruto) FILTER (WHERE NOT m.boa)              AS canal_ruim,
           min(m.valor_norm)  FILTER (WHERE NOT m.boa)              AS valor_ruim,
           array_agg(DISTINCT m.dono) FILTER (WHERE m.dono IS NOT NULL) AS donos
      FROM marcada m
     GROUP BY m.linha
  )
  SELECT b.linha,
         CASE WHEN coalesce(a.total, 0) = 0        THEN 'recusar'
              WHEN a.ruins > 0                     THEN 'recusar'
              WHEN array_length(a.donos, 1) > 1    THEN 'recusar'
              WHEN array_length(a.donos, 1) = 1    THEN 'atualizar'
              ELSE 'criar' END,
         CASE WHEN array_length(a.donos, 1) = 1 THEN a.donos[1] END,
         (SELECT c.nome FROM contacts c
           WHERE c.tenant_id = p_tenant AND array_length(a.donos, 1) = 1
             AND c.id = a.donos[1]),
         coalesce(a.novas, 0),
         coalesce(a.existentes, 0),
         coalesce(a.suprimidas, 0),
         CASE
           WHEN coalesce(a.total, 0) = 0 THEN
             'linha sem identidade: não é alcançável por canal nenhum'
           -- Canal que o motor não conhece é outro problema que identidade
           -- mal formada, e dizer "não normalizada" mandaria a pessoa corrigir
           -- o valor quando o que está errado é o cabeçalho da coluna.
           WHEN a.sem_canal > 0 THEN
             'canal desconhecido: ' || coalesce(a.canal_estranho, '(ausente)')
           WHEN a.ruins > 0 THEN
             'identidade não normalizada: ' || coalesce(a.canal_ruim, '(canal ausente)')
             || ' ' || coalesce(a.valor_ruim, '(nulo)')
           WHEN array_length(a.donos, 1) > 1 THEN
             'as identidades desta linha já pertencem a '
             || array_length(a.donos, 1) || ' contatos diferentes; fundir é decisão de operação'
         END
    FROM bruto b
    LEFT JOIN agregada a ON a.linha = b.linha
   ORDER BY b.linha;
$$;

COMMENT ON FUNCTION prever_ingestao IS
  'Prévia da importação: o que ingerir_contato faria, sem gravar nada. Linha a
   linha, porque a trava recusa a chamada inteira e uma identidade ruim no meio
   de 500 mataria a importação (D34).';

-- ---------------------------------------------------------------------------
-- Superfície: isto É API — a tela de importação chama antes de importar.
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION prever_ingestao(uuid, jsonb) FROM PUBLIC, anon';
  FOREACH papel IN ARRAY ARRAY['authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION prever_ingestao(uuid, jsonb) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
