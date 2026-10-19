-- O backfill do legado, primeira parte: pessoas e supressão (D65).
--
-- Roda depois de `tests/backfill_fixture.sql` e de `backfill/normalizar.ts`
-- — o par que roda em produção, e não uma cópia da normalização escrita à
-- mão aqui dentro (D32). O que importa, em ordem de custo:
--
--   1. quem o legado bloqueou, por qualquer caminho, não é alcançável aqui —
--      nem quando a pessoa não pôde virar contato;
--   2. a prévia não escreve nada, e diz o que a regra do celular esconde;
--   3. nada é fundido, nada some calado, e rodar de novo não duplica.

\set ON_ERROR_STOP on
SET client_min_messages = warning;
\set tenant '\'bf000000-0000-0000-0000-0000000000a0\''

CREATE TABLE bf.previa AS SELECT * FROM backfill.previa(:tenant);
CREATE FUNCTION bf.n(p_ordem int) RETURNS bigint LANGUAGE sql AS
  $$ SELECT coalesce(sum(quantidade), 0)::bigint FROM bf.previa WHERE ordem = p_ordem $$;

SELECT bf.confere('normalizado pelo TypeScript: nada falta', bf.n(0) = 0, bf.n(0)::text);
SELECT bf.confere('a prévia não escreveu nada',
  (SELECT count(*) FROM contacts WHERE tenant_id = :tenant) = 3
  AND (SELECT count(*) FROM suppression WHERE tenant_id = :tenant) = 0);

-- Ana, Davi, Bruno, Júlia, Carla, Eva, Nina, Fábio, Gil, Hugo, Kátia, Lia, Mário.
SELECT bf.confere('treze pessoas, uma por telefone normalizado', bf.n(20) = 13, bf.n(20)::text);
SELECT bf.confere('telefones que não são discáveis ficam de fora, contados', bf.n(11) = 2, bf.n(11)::text);
SELECT bf.confere('o celular salvo sem nono dígito é apontado', bf.n(22) = 1, bf.n(22)::text);
SELECT bf.confere('e a dupla com e sem o nono dígito também', bf.n(23) = 1, bf.n(23)::text);
SELECT bf.confere('o e-mail de duas pessoas é contado e não ligado', bf.n(31) = 1, bf.n(31)::text);
SELECT bf.confere('duas pessoas já existem no cliente', bf.n(40) = 2, bf.n(40)::text);
-- Eva (bloqueada), Fábio (lista), Nina (lista), Gil (blacklisted), Kátia (discarded sem motivo).
SELECT bf.confere('cinco pessoas a suprimir, por três caminhos', bf.n(50) = 5, bf.n(50)::text);
SELECT bf.confere('o bloqueado sem telefone discável é dito', bf.n(52) = 1, bf.n(52)::text);
SELECT bf.confere('o mapa de status cobre tudo o que o legado tem',
  NOT EXISTS (SELECT 1 FROM bf.previa WHERE ordem = 61)
  AND (SELECT count(*) FROM bf.previa WHERE ordem = 60) = 7,
  (SELECT string_agg(item || ' -> ' || detalhe, ' | ') FROM bf.previa WHERE ordem = 60));
SELECT bf.confere('discarded sem motivo suprime; com motivo, não',
  (SELECT detalhe LIKE '%suprime%' FROM bf.previa WHERE item = 'blast_leads discarded')
  AND (SELECT detalhe NOT LIKE '%suprime%' FROM bf.previa WHERE item = 'blast_leads discarded (manual)'));
SELECT bf.confere('quem ainda estava em cadência é contado por campanha, não inscrito',
  (SELECT quantidade FROM bf.previa WHERE item = 'leads em curso no resgate: Resgate Outubro') = 1);

-- Status que o mapa não conhece: a prévia diz, gravar se recusa.
INSERT INTO legado.rescue_leads (id, campaign_id, phone_number, current_step, status, cycle_count, source,
                                 created_at, updated_at, layer2_step, resume_context)
VALUES ('bf000000-0000-0000-0000-0000000004ff', 'bf000000-0000-0000-0000-000000000301', '11 94444-0004', 0,
        'status_novo', 0, 'csv', now(), now(), 0, '{}');
SELECT bf.confere('status sem mapeamento aparece na prévia',
  EXISTS (SELECT 1 FROM backfill.previa(:tenant) WHERE ordem = 61 AND item LIKE '%status_novo%'));
SELECT bf.confere('e gravar se recusa inteiro',
  bf.sqlstate_de('SELECT * FROM backfill.gravar(''bf000000-0000-0000-0000-0000000000a0'')') = '23001');
SELECT bf.confere('sem ter escrito nada',
  (SELECT count(*) FROM contacts WHERE tenant_id = :tenant) = 3);
DELETE FROM legado.rescue_leads WHERE id = 'bf000000-0000-0000-0000-0000000004ff';

-- ===========================================================================
-- Gravar
-- ===========================================================================

CREATE TABLE bf.gravou AS SELECT * FROM backfill.gravar(:tenant);
CREATE FUNCTION bf.g(p_ordem int) RETURNS bigint LANGUAGE sql AS
  $$ SELECT quantidade FROM bf.gravou WHERE ordem = p_ordem $$;
CREATE FUNCTION bf.contato(p_whatsapp text) RETURNS uuid LANGUAGE sql AS
  $$ SELECT contact_id FROM contact_identities
      WHERE tenant_id = 'bf000000-0000-0000-0000-0000000000a0' AND canal = 'whatsapp' AND valor_norm = p_whatsapp $$;
CREATE FUNCTION bf.canais(p_whatsapp text) RETURNS text LANGUAGE sql AS
  $$ SELECT string_agg(ci.canal::text, ',' ORDER BY ci.canal::text) FROM contact_identities ci
      WHERE ci.tenant_id = 'bf000000-0000-0000-0000-0000000000a0' AND ci.contact_id = bf.contato(p_whatsapp) $$;

SELECT bf.confere('onze contatos criados, Bruno atualizado, Nina recusada',
  bf.g(100) = 11 AND bf.g(101) = 1 AND bf.g(102) = 1,
  bf.g(100) || '/' || bf.g(101) || '/' || bf.g(102));

-- Invariante 2, pessoa por pessoa.
SELECT bf.confere('Eva, bloqueada pelo operador, está suprimida em tudo',
  esta_suprimido(:tenant, bf.contato('5511977770001'), NULL, NULL));
SELECT bf.confere('Fábio, que só existia na lista de bloqueio, também',
  esta_suprimido(:tenant, bf.contato('5511966660002'), NULL, NULL));
SELECT bf.confere('Gil (blacklisted no resgate) e Kátia (descartada sem motivo) também',
  esta_suprimido(:tenant, bf.contato('5511955550003'), NULL, NULL)
  AND esta_suprimido(:tenant, bf.contato('5511922220006'), NULL, NULL));
SELECT bf.confere('Nina não virou contato, e mesmo assim não é alcançável pelo número',
  esta_suprimido(:tenant, NULL, 'whatsapp', '5511988880009')
  AND esta_suprimido(:tenant, NULL, 'sms', '5511988880009'));
SELECT bf.confere('linha de base: Lia, descartada à mão com motivo, NÃO é suprimida',
  NOT esta_suprimido(:tenant, bf.contato('5511922220007'), NULL, NULL));
SELECT bf.confere('linha de base: Ana, em cadência no legado, NÃO é suprimida',
  NOT esta_suprimido(:tenant, bf.contato('5511987654321'), NULL, NULL));

-- O que cada pessoa virou.
SELECT bf.confere('Ana: WhatsApp, SMS e o e-mail dela, normalizado',
  bf.canais('5511987654321') = 'email,sms,whatsapp'
  AND EXISTS (SELECT 1 FROM contact_identities WHERE tenant_id = :tenant AND canal = 'email' AND valor_norm = 'ana@x.com'),
  bf.canais('5511987654321'));
SELECT bf.confere('Davi, sem o nono dígito: só WhatsApp, e outra pessoa que não a Ana',
  bf.canais('551187654321') = 'whatsapp' AND bf.contato('551187654321') <> bf.contato('5511987654321'),
  bf.canais('551187654321'));
SELECT bf.confere('Carla, fixo: só WhatsApp', bf.canais('551133334444') = 'whatsapp', bf.canais('551133334444'));
SELECT bf.confere('o e-mail de Bruno e Júlia não foi ligado a nenhum dos dois',
  NOT EXISTS (SELECT 1 FROM contact_identities WHERE tenant_id = :tenant AND valor_norm = 'compartilhado@x.com'));
-- O nome: `ingerir_contato` troca quando o novo vem preenchido (vazio não
-- apaga). É a regra de toda ingestão, e a prévia a diz com essas palavras.
SELECT bf.confere('Bruno continua um contato só; o nome do legado substitui o da planilha',
  (SELECT count(*) FROM contact_identities WHERE tenant_id = :tenant AND canal = 'whatsapp'
      AND valor_norm = '5511912345678') = 1
  AND bf.contato('5511912345678') = 'bf000000-0000-0000-0000-0000000000c1'
  AND (SELECT nome FROM contacts WHERE id = 'bf000000-0000-0000-0000-0000000000c1') = 'Bruno Legado',
  (SELECT nome FROM contacts WHERE id = 'bf000000-0000-0000-0000-0000000000c1'));
SELECT bf.confere('Nina recusada está listada, com o motivo',
  EXISTS (SELECT 1 FROM backfill.recusas WHERE valor_norm = '5511988880009' AND motivo LIKE '%contatos diferentes%'));
SELECT bf.confere('o nome vem do cadastro antes do lead',
  (SELECT nome FROM contacts WHERE id = bf.contato('5511987654321')) = 'Ana Lima');
SELECT bf.confere('metadados: cidade, só variáveis de texto, e de onde veio',
  (SELECT metadados ->> 'cidade' = 'Sorocaba' AND metadados ->> 'plano' = 'Amil'
          AND NOT metadados ? 'idade' AND NOT metadados ? 'extra'
          AND jsonb_array_length(metadados -> 'legado') = 2
     FROM contacts WHERE id = bf.contato('5511987654321')),
  (SELECT metadados::text FROM contacts WHERE id = bf.contato('5511987654321')));
SELECT bf.confere('origem diz legado', (SELECT origem FROM contacts WHERE id = bf.contato('5511987654321')) = 'legado');

-- O que não foi para o CRM, e que isso foi dito.
SELECT bf.confere('nenhum opt-out do legado ficou na fila do CRM',
  NOT EXISTS (SELECT 1 FROM outbox WHERE tenant_id = :tenant AND fato = 'opt_out'));
SELECT bf.confere('e o relatório conta os que não foram (linha de base: o gatilho os criou)',
  bf.g(105) = bf.g(103) AND bf.g(105) = 4, bf.g(105) || ' de ' || bf.g(103));

SELECT bf.confere('conferir: nenhuma linha', NOT EXISTS (SELECT 1 FROM backfill.conferir(:tenant)),
  (SELECT string_agg(problema || ' ' || valor, '; ') FROM backfill.conferir(:tenant)));

-- De novo, sem duplicar nada.
CREATE TABLE bf.de_novo AS SELECT * FROM backfill.gravar(:tenant);
SELECT bf.confere('rodar de novo não cria contato nem supressão',
  (SELECT quantidade FROM bf.de_novo WHERE ordem = 100) = 0
  AND (SELECT quantidade FROM bf.de_novo WHERE ordem = 103) = 0
  AND (SELECT quantidade FROM bf.de_novo WHERE ordem = 104) = 0
  AND (SELECT count(*) FROM contacts WHERE tenant_id = :tenant) = 14,
  (SELECT string_agg(ordem || '=' || quantidade, ' ') FROM bf.de_novo));

-- E o outro cliente não foi tocado.
SELECT bf.confere('o tenant padrão continua sem contato do legado',
  NOT EXISTS (SELECT 1 FROM contacts WHERE origem = 'legado' AND tenant_id <> :tenant));

-- ===========================================================================

\echo ''
\echo '============= BACKFILL DO LEGADO ============='
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM bf.resultado ORDER BY id;

SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total
  FROM bf.resultado;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM bf.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'backfill: % asserções falharam', (SELECT count(*) FROM bf.resultado WHERE NOT ok);
  END IF;
END;
$$;
