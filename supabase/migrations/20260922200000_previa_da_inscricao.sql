-- Prévia da inscrição em campanha (D35).
--
-- Simétrica à prévia da importação: dizer o que aconteceria antes de gravar.
-- Aqui a pergunta é outra, e a resposta silenciosa é pior.
--
-- Inscrever um contato sem identidade no canal dos passos **não dá erro**. O
-- roteador faz `passo_pulado_sem_identidade` e empurra o enrollment para o
-- passo seguinte; passo a passo, ele caminha até o fim e encerra em
-- `fim_dos_passos`. O relatório mostra "campanha concluída" para alguém que
-- nunca recebeu nada. Inscrever 500 e descobrir isso depois é caro de duas
-- formas: o tempo perdido e a confiança no número.
--
-- E inscrever de novo quem já está inscrito **dá erro** — o índice parcial
-- `enrollments_contato_campanha_ativo_uk` recusa, e a recusa mata a chamada
-- inteira, não a linha. Mesmo argumento do D34.
--
-- A terceira: contato suprimido faz `inscrever` devolver NULL, em silêncio.
-- Quem chamou recebe um nulo sem motivo e não sabe se foi supressão, campanha
-- inexistente ou bug.
--
-- Sem barra invertida, como as outras (D32).

CREATE FUNCTION prever_inscricao(
  p_tenant          uuid,
  p_campaign_id     uuid,
  p_flow_version_id uuid,
  p_contatos        uuid[]
)
RETURNS TABLE (
  contact_id         uuid,
  nome               text,
  acao               text,
  canais_alcancaveis canal[],
  problema           text
)
LANGUAGE sql STABLE SET search_path = public, privado AS $$
  WITH camp AS (
    SELECT c.canais_habilitados, c.ativa
      FROM campaigns c
     WHERE c.tenant_id = p_tenant AND c.id = p_campaign_id
  ),
  -- Os canais que esta versão de flow realmente usa.
  passos AS (
    SELECT DISTINCT fs.canal
      FROM flow_steps fs
     WHERE fs.flow_version_id = p_flow_version_id
  ),
  -- O que sobra depois de cruzar flow com campanha. Vazio aqui é problema de
  -- configuração, não de contato: nenhum passo sairia para ninguém.
  uteis AS (
    SELECT coalesce(array_agg(DISTINCT p.canal), '{}'::canal[]) AS canais
      FROM passos p
      JOIN camp c ON p.canal = ANY (c.canais_habilitados)
  ),
  alvo AS (
    SELECT DISTINCT unnest(coalesce(p_contatos, '{}'::uuid[])) AS id
  ),
  -- Alcançável é identidade válida, num canal que o flow usa, e que não está
  -- suprimida. As três coisas — uma só já enganaria.
  alcance AS (
    SELECT a.id,
           -- O FILTER não é zelo: sem ele a junção externa sem par produz
           -- `{NULL}`, `array_length` devolve 1, e "não tem canal nenhum"
           -- passa por "tem um canal". Era o bug que dizia `inscrever` para
           -- quem o motor encerraria sem mandar nada.
           coalesce(array_agg(DISTINCT ci.canal) FILTER (WHERE ci.canal IS NOT NULL),
                    '{}'::canal[]) AS canais
      FROM alvo a
      -- `uteis` entra por junção, não por subconsulta escalar: dentro de
      -- `= ANY (...)` um sub-SELECT é comparado linha a linha, e a linha aqui
      -- é um array inteiro — daí `operator does not exist: canal = canal[]`.
      CROSS JOIN uteis u
      LEFT JOIN contact_identities ci
        ON ci.tenant_id = p_tenant AND ci.contact_id = a.id AND ci.valida
       AND ci.canal = ANY (u.canais)
       AND NOT esta_suprimido(p_tenant, a.id, ci.canal, ci.valor_norm)
     GROUP BY a.id
  )
  SELECT a.id,
         c.nome,
         CASE
           WHEN c.id IS NULL THEN 'desconhecido'
           WHEN esta_suprimido(p_tenant, a.id, NULL, NULL) THEN 'suprimido'
           WHEN EXISTS (
             SELECT 1 FROM enrollments e
              WHERE e.tenant_id = p_tenant AND e.contact_id = a.id
                AND e.campaign_id = p_campaign_id AND e.status <> 'encerrado'
           ) THEN 'ja_inscrito'
           WHEN coalesce(array_length(al.canais, 1), 0) = 0 THEN 'sem_canal'
           ELSE 'inscrever'
         END,
         al.canais,
         CASE
           WHEN c.id IS NULL THEN
             'contato não existe neste cliente'
           WHEN esta_suprimido(p_tenant, a.id, NULL, NULL) THEN
             'contato suprimido: inscrever devolveria nulo em silêncio'
           WHEN EXISTS (
             SELECT 1 FROM enrollments e
              WHERE e.tenant_id = p_tenant AND e.contact_id = a.id
                AND e.campaign_id = p_campaign_id AND e.status <> 'encerrado'
           ) THEN
             'já inscrito e não encerrado nesta campanha'
           WHEN coalesce(array_length((SELECT canais FROM uteis), 1), 0) = 0 THEN
             'nenhum passo do flow usa um canal habilitado na campanha: '
             || 'ninguém receberia nada'
           WHEN coalesce(array_length(al.canais, 1), 0) = 0 THEN
             'sem identidade válida em ' || array_to_string((SELECT canais FROM uteis), ', ')
             || ': o enrollment percorreria todos os passos e encerraria como concluído'
           WHEN NOT (SELECT ativa FROM camp) THEN
             'campanha inativa: o agendador ignora enquanto ela estiver assim'
         END
    FROM alvo a
    JOIN alcance al ON al.id = a.id
    LEFT JOIN contacts c ON c.tenant_id = p_tenant AND c.id = a.id
   ORDER BY c.nome NULLS LAST, a.id;
$$;

COMMENT ON FUNCTION prever_inscricao IS
  'Prévia da inscrição: quem entraria, quem já está, quem está suprimido e quem
   não tem como ser alcançado. Sem gravar nada. Existe porque inscrever sem
   identidade não dá erro — dá uma campanha concluída sem mensagem (D35).';

-- ---------------------------------------------------------------------------
-- Superfície: é API — a tela de campanha chama antes de inscrever.
-- ---------------------------------------------------------------------------

DO $$
DECLARE papel text;
BEGIN
  EXECUTE 'REVOKE ALL ON FUNCTION prever_inscricao(uuid, uuid, uuid, uuid[]) FROM PUBLIC, anon';
  FOREACH papel IN ARRAY ARRAY['authenticated','service_role','postgres'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = papel) THEN
      EXECUTE format(
        'GRANT EXECUTE ON FUNCTION prever_inscricao(uuid, uuid, uuid, uuid[]) TO %I', papel);
    END IF;
  END LOOP;
END;
$$;
