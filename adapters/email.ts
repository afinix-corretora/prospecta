// Dialeto do e-mail: endereço normalizado e assunto separado do corpo.
//
// Fica fora do adapter de propósito. Normalização de endereço é chave de dedup
// e de supressão — pelo mesmo motivo que `telefone.ts` é um só arquivo, duas
// normalizações divergentes significam supressão furada. E a separação entre
// assunto e corpo vale para qualquer provedor de e-mail, não só o de hoje.

/** Minúsculo, sem espaço e sem o nome de exibição: `Ana <a@x> → a@x`. */
export function normalizarEmail(bruto: string): string {
  const s = (bruto ?? '').trim();
  if (!s) return '';
  const entreSinais = s.match(/<([^>]+)>\s*$/);
  return (entreSinais ? entreSinais[1] : s).trim().toLowerCase();
}

/** Uma arroba, um domínio com ponto, e nada que separe lista. */
export function emailValido(bruto: string): boolean {
  const e = normalizarEmail(bruto);
  return /^[^\s@,;<>]+@[^\s@,;<>.]+(\.[^\s@,;<>.]+)+$/.test(e) && e.length <= 254;
}

/** `Ana <a@x>` quando há nome; só o endereço quando não há. */
export function montarRemetente(endereco: string, nome?: string): string {
  const e = normalizarEmail(endereco);
  if (!e) return '';
  const n = (nome ?? '').trim().replace(/["<>]/g, '');
  return n ? `${n} <${e}>` : e;
}

export interface AssuntoECorpo {
  readonly assunto: string;
  readonly corpo: string;
}

/**
 * Tira o assunto do próprio template.
 *
 * `flow_steps.template` é um texto só, porque os outros três canais não têm
 * assunto. Em vez de abrir uma coluna no motor para uma necessidade de um
 * canal, o assunto entra como a primeira linha marcada:
 *
 *     Assunto: Comparativo do plano de saúde
 *
 *     {{nome}}, separei duas opções...
 *
 * O marcador é explícito porque a alternativa óbvia — "a primeira linha é o
 * assunto" — transforma todo parágrafo curto de abertura em assunto sem que
 * ninguém tenha pedido.
 *
 * Sem marcador, vale `padrao`, que é campo obrigatório do remetente: assim
 * "passo de e-mail sem assunto" não existe como estado possível.
 *
 * Marcador sem nada depois não conta. Template pela metade é erro de quem
 * escreveu, e é melhor ele sair num e-mail estranho do que virar falha que
 * derruba a conta do pool.
 */
export function separarAssunto(conteudo: string, padrao: string): AssuntoECorpo {
  const texto = (conteudo ?? '').replace(/\r\n/g, '\n').trim();
  const linhas = texto.split('\n');
  const marcador = linhas[0]?.match(/^\s*assunto\s*:\s*(.+?)\s*$/i);

  if (marcador) {
    const resto = linhas.slice(1).join('\n').trim();
    if (resto) return { assunto: marcador[1], corpo: resto };
  }

  return { assunto: (padrao ?? '').trim(), corpo: texto };
}
