// Contrato das fontes de contato — o primeiro quadro do diagrama.
//
// Simétrico ao `ChannelAdapter`: assim como canal novo é classe nova sem
// mexer no motor, fonte nova é classe nova sem mexer na ingestão. Planilha
// hoje, CRM depois, webhook de formulário quando aparecer.
//
// Uma fonte **lê e normaliza**, e para por aí. Ela não escreve no banco, não
// decide dedup e não sabe o que é tenant. Quem grava é `ingerir_contato`, em
// SQL, porque evitar duas linhas para a mesma pessoa exige atomicidade com o
// índice único `(tenant_id, canal, valor_norm)` — separar o SELECT do INSERT
// entre processos reabre a corrida (D32).
//
// Isso é o que torna a prévia possível: colher é puro, então dá para mostrar
// "entram 480, 12 são reimportação, 3 não têm identidade" antes de qualquer
// escrita. Mesma ideia do shadow mode — o caminho inteiro roda sem efeito.

import type { Canal } from './tipos.ts';

/**
 * Endereço num canal, já normalizado por quem sabe normalizar.
 *
 * `valor` é o que a fonte mostrou, para a tela exibir de volta o que a pessoa
 * digitou; `valorNorm` é a chave. Os dois viajam porque `contact_identities`
 * guarda os dois, e porque `privado.normalizada` **confere** o segundo em vez
 * de recalculá-lo: um segundo normalizador é como a supressão fica furada.
 */
export interface IdentidadeLida {
  readonly canal: Canal;
  readonly valor: string;
  readonly valorNorm: string;
}

export interface ContatoLido {
  readonly nome?: string;
  /** Chave do registro na fonte: id da planilha, card do CRM. */
  readonly origemRef?: string;
  readonly identidades: IdentidadeLida[];
  /** O que sobrou das colunas. Vira `contacts.metadados`. */
  readonly metadados: Record<string, string>;
  /** Onde estava na fonte, para a recusa apontar a linha certa. */
  readonly linha: number;
}

/** Registro que não vira contato, com o motivo dito em português. */
export interface LinhaRecusada {
  readonly linha: number;
  readonly motivo: string;
  /** O registro como veio, para a pessoa achá-lo na planilha. */
  readonly valores: Record<string, string>;
}

/**
 * Valor que parecia identidade e não era, numa linha que foi aceita assim
 * mesmo por ter outra identidade boa.
 *
 * Existe porque o silêncio aqui é caro: um telefone com dígito a menos numa
 * linha que tem e-mail bom entraria como contato sem ninguém saber que o
 * telefone se perdeu. A linha não é recusada — o aviso é.
 */
export interface ValorIgnorado {
  readonly linha: number;
  readonly coluna: string;
  readonly valor: string;
  readonly motivo: string;
}

export interface Colheita {
  /** Vai para `contacts.origem`. Toda linha registra de onde veio. */
  readonly origem: string;
  readonly contatos: ContatoLido[];
  readonly recusadas: LinhaRecusada[];
  readonly ignorados: ValorIgnorado[];
}

export interface ContactSource {
  readonly origem: string;
  colher(): Promise<Colheita>;
}

/** O que `ingerir_contato` espera como `p_identidades`. */
export function identidadesParaJson(c: ContatoLido): unknown[] {
  return c.identidades.map((i) => ({
    canal: i.canal, valor: i.valor, valor_norm: i.valorNorm,
  }));
}
