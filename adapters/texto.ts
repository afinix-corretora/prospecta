/**
 * O texto de uma mensagem recebida, quando o provedor manda.
 *
 * Existe porque cada provedor guarda o corpo num lugar diferente, e porque
 * NENHUM deles é garantido: figura, áudio e sticker chegam sem texto nenhum,
 * e o SMS não tem webhook de entrada. Quem chama passa os candidatos que
 * conhece, em ordem de preferência, e recebe o primeiro que for texto de
 * verdade — ou `undefined`.
 *
 * O conhecimento de qual caminho cada provedor usa fica no arquivo do
 * provedor, que é onde a mudança acontece quando ele mexe no formato. Aqui
 * mora só a regra de "o que conta como texto", que é igual para todos.
 *
 * Isto importa para além de mostrar a resposta na tela: é deste campo que o
 * motor decide se alguém pediu para sair (D48). Devolver lixo aqui — um
 * objeto virando "[object Object]", um número virando "0" — seria alimentar
 * o detector de opt-out com ruído, e a supressão é imutável.
 */

/** Teto de tamanho. Mensagem não tem megabyte; o que tem é payload estranho. */
const LIMITE = 4096;

/**
 * O primeiro candidato que for uma string não vazia, aparado e limitado.
 *
 * Só aceita `string`: número, objeto e array são descartados de propósito.
 * Converter qualquer coisa com `String()` é como `[object Object]` entraria
 * no banco — e depois no classificador de opt-out.
 */
export function primeiroTexto(...candidatos: unknown[]): string | undefined {
  for (const c of candidatos) {
    if (typeof c !== 'string') continue;
    const limpo = c.trim();
    if (limpo === '') continue;
    return limpo.length > LIMITE ? limpo.slice(0, LIMITE) : limpo;
  }
  return undefined;
}

/** Acesso a `obj.a.b.c` sem estourar quando algum pedaço não existe. */
export function emCaminho(obj: unknown, ...chaves: string[]): unknown {
  let atual: unknown = obj;
  for (const k of chaves) {
    if (atual === null || typeof atual !== 'object') return undefined;
    atual = (atual as Record<string, unknown>)[k];
  }
  return atual;
}
