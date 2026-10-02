/** O que este cliente consegue entregar hoje, e por que não (D54).
 *
 * Puro de propósito: o cruzamento é a regra, e a regra precisa de teste. A
 * leitura do banco fica em `dados.ts`; aqui só entra o que já foi lido.
 *
 * A pergunta é a mesma que `privado.remetentes_disponiveis` faz antes de
 * escolher um remetente — `tem_adapter AND ativo`, e conta no estado `ativo`
 * (D31). A diferença é QUANDO: ali, depois de o passo vencer, quando a única
 * saída é adiar; aqui, antes de a campanha ser oferecida.
 *
 * Os dois "não" são separados porque só um deles é resolvível por tela:
 * `sem_remetente` se conserta cadastrando um chip, `sem_adapter` não se
 * conserta de jeito nenhum hoje — é código que ainda não existe (D30). Fundir
 * os dois num "indisponível" mandaria a pessoa procurar uma configuração que
 * não existe.
 */

export type MotivoDoCanal = 'entrega' | 'sem_adapter' | 'sem_remetente';

export interface CanalEntregavel {
  canal: string;
  motivo: MotivoDoCanal;
}

interface ProvedorLido { slug: string; canal: string; tem_adapter: boolean; ativo: boolean }
interface RemetenteLido { canal: string; provedor: string; estado: string }

export function cruzarEntregaveis(
  provedores: readonly ProvedorLido[],
  remetentes: readonly RemetenteLido[],
): CanalEntregavel[] {
  const canais = [...new Set(provedores.map((p) => p.canal))];

  return canais.map((canal) => {
    const comAdapter = provedores.filter(
      (p) => p.canal === canal && p.tem_adapter && p.ativo);

    // Nenhum provedor sabe enviar neste canal. Não é falta de conta.
    if (comAdapter.length === 0) return { canal, motivo: 'sem_adapter' };

    // Conta cujo provedor não tem adapter não conta como remetente: é
    // exatamente a linha que o pool recusa, e contá-la aqui faria a tela
    // prometer o que o despachante recusaria depois.
    const entrega = remetentes.some(
      (r) => r.canal === canal
        && r.estado === 'ativo'
        && comAdapter.some((p) => p.slug === r.provedor),
    );

    return { canal, motivo: entrega ? 'entrega' : 'sem_remetente' };
  });
}
