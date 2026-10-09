/** Quais variáveis um template pede (D55).
 *
 * Isto é, inevitavelmente, uma **segunda leitura** da mesma marcação que
 * `privado.renderizar` interpreta em SQL — e segunda leitura divergente é o
 * D32 outra vez, na camada do texto em vez da identidade. A diferença é o que
 * está em jogo: ali, supressão furada; aqui, a tela dizer "todas existem na
 * base" sobre uma chave que o motor vai apagar.
 *
 * Por isso a regexp é a mesma, e não parecida. `renderizar` tem duas:
 *
 *   - a que troca uma chave conhecida:  {{\s*<chave>\s*}}
 *   - a que apaga o que sobrou:         {{\s*[\w.]+\s*}}
 *
 * A segunda é a que define o que **é** uma variável para o motor: letra,
 * dígito, sublinhado e ponto, com espaço opcional dentro das chaves. É ela
 * que está reproduzida abaixo, e é contra ela que o teste escreve os casos.
 *
 * Fica em arquivo próprio, fora do `.tsx`, porque o que precisa de teste é a
 * regra — não o desenho da tela.
 */

/** As chaves que o texto pede, sem repetição, na ordem em que aparecem. */
export function variaveisDoTexto(texto: string): string[] {
  const achadas = [...texto.matchAll(/\{\{\s*([\w.]+)\s*\}\}/g)]
    .map((m) => m[1])
    .filter((c): c is string => typeof c === 'string' && c.length > 0);
  return [...new Set(achadas)];
}
