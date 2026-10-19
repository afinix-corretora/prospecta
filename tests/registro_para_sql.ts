// O catálogo e o registro de adapters dizem a mesma coisa, ou não dizem nada.
//
// `channel_provider_catalog.tem_adapter` é o que o pool lê antes de escolher
// um remetente (D31). `adapters/registro.ts` é o que o despachante consulta na
// hora de enviar. São duas listas, escritas à mão, em linguagens diferentes,
// que precisam concordar — e nada as comparava.
//
// As duas divergências possíveis falham de jeitos opostos, e as duas são
// silenciosas do lado errado:
//
//   * `tem_adapter = true` sem entrada no registro: o pool oferece a conta, o
//     despachante levanta "provedor sem adapter" na hora do envio. Fica como
//     falha da mensagem, não como erro de cadastro;
//   * entrada no registro com `tem_adapter = false`: o adapter existe,
//     funciona, e o pool nunca oferece a conta. O passo é adiado para sempre
//     e nada aparece como erro. Foi assim que o `tem_adapter` entrou no D31 —
//     coluna que ninguém compara é decoração.
//
// O `smtp` é a exceção declarada: está no catálogo com `tem_adapter = false`
// de propósito, porque socket não cabe num diretório que só usa `fetch` (D30).
// O teste não o trata como caso especial — ele cai naturalmente do lado certo,
// e é isso que prova que a regra está escrita e não a exceção.
//
// Escreve SQL em stdout; quem roda é `tests/run.sh`, que o joga no psql.

import { PROVEDORES_POR_CANAL } from '../adapters/registro.ts';
import { PLATAFORMAS_COM_ADAPTER } from '../adapters/crm.ts';
import { PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';

const linhas: string[] = [];
const p = (s: string) => linhas.push(s);

p(`\\set ON_ERROR_STOP on`);
p(`SET client_min_messages = warning;`);
p(`CREATE SCHEMA rg;`);
p(`CREATE TABLE rg.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);`);
p(`CREATE FUNCTION rg.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN INSERT INTO rg.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $f$;`);

// O registro, tal como o TypeScript o tem AGORA, virado em tabela. É a única
// coisa deste arquivo que não é literal: derivar é o ponto.
const pares = Object.entries(PROVEDORES_POR_CANAL)
  .flatMap(([canal, provedores]) => provedores.map((prov) => ({ canal, prov })));

p(`CREATE TABLE rg.registro (canal canal NOT NULL, provedor text NOT NULL);`);
if (pares.length > 0) {
  p(`INSERT INTO rg.registro (canal, provedor) VALUES\n  `
    + pares.map(({ canal, prov }) => `('${canal}', '${prov}')`).join(',\n  ')
    + ';');
}

// Cenário que consegue falhar: sem isto, um registro vazio passaria em todas
// as asserções de "nenhuma divergência" (D36).
p(`SELECT rg.confere('o registro de adapters não está vazio',
  (SELECT count(*) > 0 FROM rg.registro),
  (SELECT count(*)::text FROM rg.registro));`);

p(`SELECT rg.confere('todo provedor do registro existe no catálogo',
  NOT EXISTS (SELECT 1 FROM rg.registro r
               WHERE NOT EXISTS (SELECT 1 FROM channel_provider_catalog c
                                  WHERE c.slug = r.provedor)),
  coalesce((SELECT string_agg(r.provedor, ', ') FROM rg.registro r
             WHERE NOT EXISTS (SELECT 1 FROM channel_provider_catalog c
                                WHERE c.slug = r.provedor)), ''));`);

p(`SELECT rg.confere('todo provedor do registro está no canal que o catálogo diz',
  NOT EXISTS (SELECT 1 FROM rg.registro r
               JOIN channel_provider_catalog c ON c.slug = r.provedor
              WHERE c.canal <> r.canal),
  coalesce((SELECT string_agg(r.provedor || ': registro diz ' || r.canal
                              || ', catálogo diz ' || c.canal, '; ')
              FROM rg.registro r JOIN channel_provider_catalog c ON c.slug = r.provedor
             WHERE c.canal <> r.canal), ''));`);

// A divergência que o pool sente: oferece e o despachante não sabe enviar.
p(`SELECT rg.confere('nenhum tem_adapter=true sem adapter escrito',
  NOT EXISTS (SELECT 1 FROM channel_provider_catalog c
               WHERE c.tem_adapter
                 AND NOT EXISTS (SELECT 1 FROM rg.registro r WHERE r.provedor = c.slug)),
  coalesce((SELECT string_agg(c.slug, ', ') FROM channel_provider_catalog c
             WHERE c.tem_adapter
               AND NOT EXISTS (SELECT 1 FROM rg.registro r WHERE r.provedor = c.slug)), ''));`);

// A divergência que ninguém sente, e que por isso é a pior: o adapter existe,
// funciona, e o pool nunca oferece a conta.
p(`SELECT rg.confere('nenhum adapter escrito ficou com tem_adapter=false',
  NOT EXISTS (SELECT 1 FROM rg.registro r
               JOIN channel_provider_catalog c ON c.slug = r.provedor
              WHERE NOT c.tem_adapter),
  coalesce((SELECT string_agg(r.provedor, ', ') FROM rg.registro r
             JOIN channel_provider_catalog c ON c.slug = r.provedor
            WHERE NOT c.tem_adapter), ''));`);

// O caso declarado, conferido pela regra e não por exceção: `smtp` está no
// catálogo, não está no registro, e é por isso que `tem_adapter` é falso.
p(`SELECT rg.confere('smtp continua no catálogo sem adapter, de propósito (D30)',
  (SELECT NOT tem_adapter FROM channel_provider_catalog WHERE slug = 'smtp')
  AND NOT EXISTS (SELECT 1 FROM rg.registro WHERE provedor = 'smtp'));`);

// E o canal que o registro declara vazio: o schema tem o enum, o produto não
// tem como enviar, e dizer isso em voz alta é melhor do que descobrir depois.
p(`SELECT rg.confere('canal sem adapter nenhum no registro também não tem no catálogo',
  NOT EXISTS (
    SELECT 1 FROM channel_provider_catalog c
     WHERE c.tem_adapter
       AND c.canal NOT IN (SELECT canal FROM rg.registro)),
  coalesce((SELECT string_agg(c.slug || ' (' || c.canal || ')', ', ')
              FROM channel_provider_catalog c
             WHERE c.tem_adapter
               AND c.canal NOT IN (SELECT canal FROM rg.registro)), ''));`);

// O mesmo par para o CRM (D64). `crm_provider_catalog.tem_adapter` é o que
// `reivindicar_writebacks` e `fontes_crm_vencidas` leem antes de entregar
// trabalho ao worker; `PLATAFORMAS_COM_ADAPTER` é o que o worker sabe fazer.
// Catálogo sem adapter: o fato é reivindicado e queima as oito tentativas em
// "plataforma sem adapter". Adapter sem catálogo: o fato espera para sempre,
// e a tela do dreno diz "nunca saiu" com toda a razão do mundo.
p(`CREATE TABLE rg.crm (provedor text NOT NULL);`);
p(`INSERT INTO rg.crm (provedor) VALUES ${PLATAFORMAS_COM_ADAPTER.map((x) => `('${x}')`).join(', ')};`);
p(`SELECT rg.confere('CRM: o catálogo e o registro dizem as mesmas plataformas',
  NOT EXISTS (SELECT slug FROM crm_provider_catalog WHERE tem_adapter
              EXCEPT SELECT provedor FROM rg.crm)
  AND NOT EXISTS (SELECT provedor FROM rg.crm
                  EXCEPT SELECT slug FROM crm_provider_catalog WHERE tem_adapter),
  coalesce((SELECT string_agg(slug, ', ') FROM crm_provider_catalog WHERE tem_adapter), '(nenhuma no catálogo)')
  || ' x ' || (SELECT string_agg(provedor, ', ') FROM rg.crm));`);

// E o terceiro par (D66): quem compõe o rascunho. Catálogo sem adapter faz o
// agente com credencial dizer "não compõe" sem motivo; adapter sem catálogo
// faz a fila do agente esperar para sempre por um provedor que já funciona.
p(`CREATE TABLE rg.ia (provedor text NOT NULL);`);
p(`INSERT INTO rg.ia (provedor) VALUES ${PROVEDORES_IA_COM_ADAPTER.map((x) => `('${x}')`).join(', ')};`);
p(`SELECT rg.confere('IA: o catálogo e o registro dizem os mesmos provedores',
  NOT EXISTS (SELECT slug FROM ai_provider_catalog WHERE tem_adapter EXCEPT SELECT provedor FROM rg.ia)
  AND NOT EXISTS (SELECT provedor FROM rg.ia EXCEPT SELECT slug FROM ai_provider_catalog WHERE tem_adapter),
  coalesce((SELECT string_agg(slug, ', ') FROM ai_provider_catalog WHERE tem_adapter), '(nenhum)')
  || ' x ' || (SELECT string_agg(provedor, ', ') FROM rg.ia));`);

p("\\echo ''");
p("\\echo '============= CATÁLOGO x REGISTRO DE ADAPTERS ============='");
p(`SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM rg.resultado ORDER BY id;`);
p(`SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM rg.resultado;`);
p(`DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM rg.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'catálogo x registro: % asserções falharam',
      (SELECT count(*) FROM rg.resultado WHERE NOT ok);
  END IF;
END; $g$;`);

console.log(linhas.join('\n'));
