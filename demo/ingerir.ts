// Gera o SQL de ingestão do demo a partir de `demo/contatos.csv`.
//
// Por que o demo lê um CSV em vez de dar INSERT nas sete pessoas: porque era
// assim que ele fazia, e era justamente o "INSERT à mão" que a ingestão veio
// substituir (D32). Um demo que pula a porta de entrada não exercita a porta
// de entrada — e o CLAUDE.md diz que este demo existe para pegar o que teste
// unitário nenhum pega.
//
// Agora o caminho é o inteiro: planilha do jeito que a operação exporta, com
// `;`, acento no cabeçalho e um fixo no meio, passando por `PlanilhaSource`,
// `prever_ingestao` e `ingerir_contato`. As duas linhas a mais no arquivo são
// de propósito: um telefone fixo, que não vira WhatsApp nem SMS (D33), e uma
// linha sem contato nenhum. É o que faz a recusa aparecer no console em vez
// de virar um número que ninguém vê.
//
// Escreve SQL em stdout; quem roda é `demo/gerar.sh`.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { PlanilhaSource } from '../adapters/planilha.ts';
import { identidadesParaJson } from '../adapters/fonte.ts';

const csv = readFileSync(fileURLToPath(new URL('./contatos.csv', import.meta.url)), 'utf8');
const colheita = new PlanilhaSource(csv, { origem: 'planilha' }).colherAgora();

const lit = (tag: string, v: string) => `$${tag}$${v}$${tag}$`;
const nulo = (tag: string, v: string | undefined) => (v === undefined ? 'NULL' : lit(tag, v));

const l: string[] = [];
const p = (s: string) => l.push(s);

p('-- GERADO por demo/ingerir.ts a partir de demo/contatos.csv. Não editar.');
p('');
p('-- O nome é a chave do cenário porque o uuid agora vem do banco: quem');
p('-- decide a identidade do contato é a ingestão, não o arquivo do demo.');
p('CREATE TABLE p.pessoas (rotulo text PRIMARY KEY, contact_id uuid NOT NULL);');
p(`CREATE FUNCTION p.quem(p_rotulo text) RETURNS uuid
LANGUAGE sql STABLE AS $f$
  SELECT contact_id FROM p.pessoas WHERE rotulo = p_rotulo;
$f$;`);
p('');

// A prévia roda antes, como roda na tela: é ela que dá os números do console.
const linhas = colheita.contatos.map((c) => ({
  linha: c.linha,
  identidades: c.identidades.map((i) => ({ canal: i.canal, valor_norm: i.valorNorm })),
}));

p('DO $g$');
p('DECLARE r record; v_novos int := 0; v_reimport int := 0;');
p('BEGIN');
p(`  FOR r IN SELECT * FROM prever_ingestao(
      current_setting('app.tenant')::uuid, ${lit('pv', JSON.stringify(linhas))}::jsonb)
  LOOP
    IF r.acao = 'criar' THEN v_novos := v_novos + 1;
    ELSIF r.acao = 'atualizar' THEN v_reimport := v_reimport + 1;
    END IF;
  END LOOP;`);
p(`  PERFORM p.registrar('operador', NULL, 'previa_da_importacao',
    v_novos || ' entrariam como novos, ' || v_reimport || ' seriam reimportação'
    || ' — conferido antes de gravar');`);
p('END');
p('$g$;');
p('');

p('DO $g$');
p('DECLARE r record;');
p('BEGIN');
for (const c of colheita.contatos) {
  const rotulo = c.nome ?? `linha ${c.linha}`;
  p(`  SELECT * INTO r FROM ingerir_contato(
    current_setting('app.tenant')::uuid, ${lit('o', colheita.origem)},
    ${lit('j', JSON.stringify(identidadesParaJson(c)))}::jsonb,
    ${nulo('n', c.nome)}, ${nulo('r', c.origemRef)},
    ${lit('m', JSON.stringify(c.metadados))}::jsonb);`);
  p(`  INSERT INTO p.pessoas VALUES (${lit('k', rotulo)}, r.contact_id);`);
  p(`  PERFORM p.registrar('operador', ${lit('k', rotulo)}, 'importada',
    r.acao || ' com ' || r.identidades_novas || ' identidade(s)');`);
}
p('END');
p('$g$;');
p('');

// O que não virou contato aparece, em vez de sumir num número.
//
// Tudo dentro de DO/PERFORM: `SELECT p.registrar(...)` solto imprime uma
// tabela de resultado, e a saída deste arquivo é o JSON que alimenta o
// console — uma linha a mais e o `json.loads` do injetar.py morre.
p('DO $g$');
p('BEGIN');
for (const r of colheita.recusadas) {
  const nome = Object.values(r.valores).find((v) => v.trim()) ?? `linha ${r.linha}`;
  p(`  PERFORM p.registrar('operador', ${lit('k', nome)}, 'linha_recusada',
    ${lit('d', `linha ${r.linha}: ${r.motivo}`)});`);
}
for (const g of colheita.ignorados) {
  p(`  PERFORM p.registrar('operador', NULL, 'valor_ignorado',
    ${lit('d', `linha ${g.linha}, coluna ${g.coluna}: ${g.valor} — ${g.motivo}`)});`);
}
p('END');
p('$g$;');

console.log(l.join('\n'));
