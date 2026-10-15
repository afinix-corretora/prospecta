// Gera o SQL da prova de ponta a ponta da planilha.
//
// Por que existir, sendo que `tests/fontes.test.ts` já confere o que a fonte
// produz e `tests/ingestao.sql` já confere o que a função aceita: porque os
// dois trabalham com cópias. O teste de TypeScript repete as expressões da
// trava, e o de SQL usa identidades escritas à mão. Nenhum dos dois roda a
// saída real da `PlanilhaSource` contra a `ingerir_contato` real — e é o par
// que roda em produção, não cada metade.
//
// Uma divergência aqui não é hipótese: renomear `valor_norm` no JSON ou
// afrouxar um normalizador deixa os dois lados verdes e a importação inteira
// morre numa exceção, porque a trava recusa a chamada toda, não a linha.
//
// O que este teste NÃO cobre: diferença entre o arquivo de migration e o
// banco do projeto. Ele roda no arquivo. Quem vê isso é o digesto estrutural
// — foi assim que a barra duplicada da regex de e-mail apareceu (D32).
//
// Escreve SQL em stdout; quem roda é `tests/run.sh`, que o joga no psql.

import { PlanilhaSource } from '../adapters/planilha.ts';
import { identidadesParaJson } from '../adapters/fonte.ts';

const TENANT = '00000000-0000-0000-0000-0000000000aa';

// Uma planilha com os casos que a operação produz de verdade: celular e fixo
// na mesma coluna, coluna que declara canal, perfil colado como URL, linha sem
// contato nenhum, e a mesma pessoa de novo — desta vez sem o nome.
const CSV = [
  'Nome;Telefone;WhatsApp;E-mail;Instagram;Plano atual;Código',
  'Marina Souza;(15) 99123-4567;;MARINA <M.Souza@Exemplo.Com.BR>;@marina.souza;Amil;A-1',
  'João Lima;1533221100;;joao@exemplo.com.br;;Unimed;A-2',
  'Ana Paula;;+55 15 99888-7777;;instagram.com/Ana.Paula/;;A-3',
  'Só Nome;;;;;;A-4',
  ';(15) 99123-4567;;;;;A-5',
].join('\n') + '\n';

const colheita = new PlanilhaSource(CSV).colherAgora();

/** Literal SQL com cifrão etiquetado: nenhum valor da planilha o fecha. */
function lit(tag: string, v: string): string {
  return `$${tag}$${v}$${tag}$`;
}

function nulo(tag: string, v: string | undefined): string {
  return v === undefined ? 'NULL' : lit(tag, v);
}

const linhas: string[] = [];
const p = (s: string) => linhas.push(s);

p("\\set ON_ERROR_STOP on");
p('SET client_min_messages = warning;');
p('CREATE SCHEMA pl;');
p(`CREATE TABLE pl.resultado (
  id serial PRIMARY KEY, nome text NOT NULL, ok boolean NOT NULL, detalhe text NOT NULL DEFAULT ''
);`);
p(`CREATE FUNCTION pl.confere(p_nome text, p_cond boolean, p_detalhe text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN INSERT INTO pl.resultado (nome, ok, detalhe)
  VALUES (p_nome, coalesce(p_cond,false), coalesce(p_detalhe,'')); END; $f$;`);

// A colheita atravessa a fronteira exatamente como saiu da fonte.
p('DO $t$');
p('DECLARE r record;');
p('BEGIN');
for (const c of colheita.contatos) {
  const json = JSON.stringify(identidadesParaJson(c));
  p(`  SELECT * INTO r FROM ingerir_contato(
    '${TENANT}'::uuid, ${lit('o', colheita.origem)}, ${lit('j', json)}::jsonb,
    ${nulo('n', c.nome)}, ${nulo('r', c.origemRef)},
    ${lit('m', JSON.stringify(c.metadados))}::jsonb);`);
  p(`  PERFORM pl.confere(
    ${lit('c', `linha ${c.linha} entrou sem exceção`)}, r.contact_id IS NOT NULL,
    coalesce(r.acao, '(sem retorno)'));`);
}
p('END');
p('$t$;');

// O que a fonte contou e o que o banco gravou têm que ser o mesmo número. É
// aqui que uma divergência de normalização apareceria: o banco a recusaria
// com exceção, ou a gravaria como identidade a mais.
const identidadesDistintas = new Set(
  colheita.contatos.flatMap((c) => c.identidades.map((i) => `${i.canal}|${i.valorNorm}`)),
).size;

p(`SELECT pl.confere('pessoas: a fonte viu 4 linhas com contato e o banco tem 3',
  (SELECT count(*) FROM contacts WHERE tenant_id = '${TENANT}') = 3,
  'a quinta linha é a mesma Marina, casada pelo telefone');`);

p(`SELECT pl.confere('identidades: banco tem as ${identidadesDistintas} que a fonte produziu',
  (SELECT count(*) FROM contact_identities WHERE tenant_id = '${TENANT}') = ${identidadesDistintas},
  (SELECT count(*)::text FROM contact_identities WHERE tenant_id = '${TENANT}'));`);

p(`SELECT pl.confere('a fonte recusou a linha sem contato antes de chegar ao banco',
  ${colheita.recusadas.length} = 1 AND ${colheita.recusadas[0]?.linha ?? 0} = 5);`);

p(`SELECT pl.confere('reimportar sem a coluna de nome não apaga o nome',
  (SELECT nome FROM contacts c
     JOIN contact_identities ci ON ci.contact_id = c.id
    WHERE ci.valor_norm = '5515991234567' AND ci.canal = 'whatsapp'
      AND c.tenant_id = '${TENANT}' LIMIT 1) = 'Marina Souza');`);

p(`SELECT pl.confere('a coluna que o motor não conhece virou metadado',
  (SELECT metadados ->> 'plano_atual' FROM contacts
    WHERE nome = 'Marina Souza' AND tenant_id = '${TENANT}') = 'Amil');`);

p(`SELECT pl.confere('o fixo não entrou como WhatsApp',
  NOT EXISTS (SELECT 1 FROM contact_identities
               WHERE tenant_id = '${TENANT}' AND valor_norm = '551533221100'));`);

p(`SELECT pl.confere('o perfil colado como URL virou handle limpo',
  EXISTS (SELECT 1 FROM contact_identities
           WHERE tenant_id = '${TENANT}' AND canal = 'instagram'
             AND valor_norm = 'ana.paula'));`);

p(`SELECT pl.confere('nenhuma identidade escapou da trava de normalização',
  NOT EXISTS (SELECT 1 FROM contact_identities
               WHERE tenant_id = '${TENANT}'
                 AND NOT privado.normalizada(canal, valor_norm)));`);

p("\\echo ''");
p("\\echo '============= PLANILHA PONTA A PONTA ============='");
p(`SELECT CASE WHEN ok THEN 'PASS' ELSE 'FALHA' END AS status, nome,
       CASE WHEN ok THEN '' ELSE detalhe END AS detalhe
  FROM pl.resultado ORDER BY id;`);
p(`SELECT count(*) FILTER (WHERE ok) AS passou,
       count(*) FILTER (WHERE NOT ok) AS falhou, count(*) AS total FROM pl.resultado;`);
p(`DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM pl.resultado WHERE NOT ok) THEN
    RAISE EXCEPTION 'planilha ponta a ponta: % asserções falharam',
      (SELECT count(*) FROM pl.resultado WHERE NOT ok);
  END IF;
END; $g$;`);

console.log(linhas.join('\n'));
