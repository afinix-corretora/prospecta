// A normalização do backfill, feita por quem normaliza (D32).
//
// Lê do stdin linhas `tipo<TAB>bruto` — o que `legado.brutos` devolve — e
// escreve no stdout o SQL que preenche `legado.telefones` e `legado.emails`.
// Quem decide é `adapters/telefone.ts` e `adapters/email.ts`, os mesmos que a
// planilha, o CRM e os webhooks usam. O SQL do backfill só lê o resultado.
//
//   psql -Atc "SELECT tipo || chr(9) || bruto FROM legado.brutos" \
//     | node --experimental-strip-types backfill/normalizar.ts \
//     | psql -v ON_ERROR_STOP=1
//
// Sem dependência e sem rede, pelo mesmo motivo de `adapters/`: o que roda
// aqui roda igual no teste.

import { celularBrasileiro, normalizarTelefone, telefoneValido } from '../adapters/telefone.ts';
import { emailValido, normalizarEmail } from '../adapters/email.ts';

/** Literal SQL sem barra invertida: aspas simples dobradas, e só. */
export function literal(v: string | null): string {
  return v === null ? 'NULL' : `'${v.replace(/'/g, "''")}'`;
}

export function linhaParaSql(tipo: string, bruto: string): string | null {
  if (tipo === 'telefone') {
    const valido = telefoneValido(bruto);
    return `INSERT INTO legado.telefones (bruto, valor_norm, valido, celular) VALUES (`
      + `${literal(bruto)}, ${literal(valido ? normalizarTelefone(bruto) : null)}, `
      + `${valido}, ${valido && celularBrasileiro(bruto)}) ON CONFLICT (bruto) DO NOTHING;`;
  }
  if (tipo === 'email') {
    const valido = emailValido(bruto);
    return `INSERT INTO legado.emails (bruto, valor_norm, valido) VALUES (`
      + `${literal(bruto)}, ${literal(valido ? normalizarEmail(bruto) : null)}, ${valido}) `
      + `ON CONFLICT (bruto) DO NOTHING;`;
  }
  return null;
}

async function principal() {
  let texto = '';
  for await (const pedaco of process.stdin) texto += pedaco;
  const saida: string[] = ['BEGIN;'];
  let desconhecidas = 0;
  for (const linha of texto.split('\n')) {
    if (!linha) continue;
    const tab = linha.indexOf('\t');
    const sql = tab < 0 ? null : linhaParaSql(linha.slice(0, tab), linha.slice(tab + 1));
    if (sql) saida.push(sql); else desconhecidas += 1;
  }
  saida.push('COMMIT;');
  process.stdout.write(saida.join('\n') + '\n');
  // Linha que não é `tipo<TAB>bruto` não vira nada — mas não some calada.
  if (desconhecidas > 0) process.stderr.write(`normalizar: ${desconhecidas} linha(s) sem formato ignoradas\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) await principal();
