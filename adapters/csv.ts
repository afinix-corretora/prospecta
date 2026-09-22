// Leitor de CSV.
//
// Escrito à mão, e não com biblioteca, pela mesma regra dos adapters: nada
// aqui pode depender de runtime, para o arquivo rodar no Deno da edge function
// e no Node do teste. São ~60 linhas e o formato é pequeno.
//
// Três coisas que o caso real exige e que o `split(',')` ingênuo erra:
//
// - **Separador.** O Excel em português exporta com `;`, não com vírgula. Uma
//   planilha da operação é o caso normal aqui, não a exceção.
// - **Aspas.** `"Silva, João"` é um campo só, e `""` dentro de aspas é uma
//   aspa literal. Endereço com vírgula aparece em toda base de contatos.
// - **BOM.** O Excel prefixa o arquivo com `﻿`, e sem tirar isso a
//   primeira coluna do cabeçalho se chama `﻿nome` e nunca casa.

/** Separadores que valem a pena testar, na ordem de desempate. */
const SEPARADORES = [';', ',', '\t'];

/** Conta ocorrências fora de aspas — dentro delas o separador é texto. */
function forasDeAspas(linha: string, sep: string): number {
  let n = 0;
  let dentro = false;
  for (let i = 0; i < linha.length; i += 1) {
    const c = linha[i];
    if (c === '"') dentro = !dentro;
    else if (c === sep && !dentro) n += 1;
  }
  return n;
}

/** O separador que mais aparece no cabeçalho. Empate resolve pela ordem. */
export function separadorDe(texto: string): string {
  const cabecalho = texto.replace(/^﻿/, '').split(/\r?\n/)[0] ?? '';
  let melhor = ',';
  let maior = -1;
  for (const s of SEPARADORES) {
    const n = forasDeAspas(cabecalho, s);
    if (n > maior) { maior = n; melhor = s; }
  }
  return maior > 0 ? melhor : ',';
}

/**
 * Linhas de células. Preserva campo vazio e respeita quebra de linha dentro
 * de aspas — um endereço de duas linhas é uma célula, não duas.
 */
export function lerCsv(texto: string, sep = separadorDe(texto)): string[][] {
  const limpo = texto.replace(/^﻿/, '');
  const linhas: string[][] = [];
  let celulas: string[] = [];
  let atual = '';
  let dentro = false;

  for (let i = 0; i < limpo.length; i += 1) {
    const c = limpo[i];

    if (dentro) {
      if (c === '"') {
        if (limpo[i + 1] === '"') { atual += '"'; i += 1; }
        else dentro = false;
      } else atual += c;
      continue;
    }

    if (c === '"') { dentro = true; continue; }
    if (c === sep) { celulas.push(atual); atual = ''; continue; }
    if (c === '\r') continue;
    if (c === '\n') { celulas.push(atual); linhas.push(celulas); celulas = []; atual = ''; continue; }
    atual += c;
  }

  if (atual !== '' || celulas.length > 0) { celulas.push(atual); linhas.push(celulas); }

  // Linha vazia continua na lista, de propósito. Descartá-la aqui tornaria o
  // índice diferente do número da linha que o Excel mostra, e é justamente
  // por esse número que a pessoa acha a linha recusada na planilha dela.
  // Quem pula linha em branco é quem interpreta: `vazia()` diz qual é.
  return linhas;
}

/** Linha sem nada preenchido: artefato de arquivo, não registro. */
export function vazia(linha: string[]): boolean {
  return !linha.some((c) => c.trim() !== '');
}

/** Cabeçalho comparável: sem acento, sem espaço nas pontas, minúsculo. */
export function chaveDeColuna(bruto: string): string {
  return (bruto ?? '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}
