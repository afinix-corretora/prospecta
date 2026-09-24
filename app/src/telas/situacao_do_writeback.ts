/** A leitura da situação do dreno, separada do desenho (D46).
 *
 * Está num arquivo próprio, e não dentro do `.tsx`, porque é a parte que pode
 * estar errada: são três estados que produzem a MESMA ausência de sinal se
 * ninguém os separar. Aqui ela é pura e tem teste; lá é só desenho.
 *
 * O que separa os três é dois campos e nenhuma regra escrita à mão:
 *
 *   enviados === 0   nada nunca chegou ao CRM — não é o dreno que parou, é
 *                    que ele ainda não tem para onde levar
 *   idade            há quanto tempo o mais velho espera. Nulo, e não zero,
 *                    quando a fila está vazia: fila vazia não tem mais antigo
 */

export interface ResumoParaSituacao {
  pendentes: number;
  enviados: number;
  falhados: number;
  pendente_mais_antigo_em_horas: number | null;
}

export type Estado =
  | { tipo: 'vazio' }
  | { tipo: 'nunca_saiu'; horas: number | null }
  | { tipo: 'parado'; horas: number }
  | { tipo: 'ok' };

/** Horas a partir das quais um pendente deixa de ser fila e vira demora. O
 *  dreno tenta de novo com espera dobrando até seis horas, então um fato mais
 *  velho que isso já passou do teto de espera normal. */
export const HORAS_DE_DEMORA = 6;

export function situacaoDoWriteback(r: ResumoParaSituacao): Estado {
  const total = r.pendentes + r.enviados + r.falhados;
  if (total === 0) return { tipo: 'vazio' };

  // Distinguir isto de "parou" é o ponto da tela. Na fase de hoje a fila
  // crescendo é o comportamento CORRETO de um motor que guarda o que
  // descobriu enquanto o caminho de saída não existe. Mostrar isso como
  // alarme ensinaria a ignorar o alarme — que é como o de verdade passa
  // despercebido.
  if (r.enviados === 0) {
    return { tipo: 'nunca_saiu', horas: r.pendente_mais_antigo_em_horas };
  }

  const h = r.pendente_mais_antigo_em_horas;
  if (h !== null && h >= HORAS_DE_DEMORA) return { tipo: 'parado', horas: h };
  return { tipo: 'ok' };
}
