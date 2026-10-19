// Contrato das plataformas de CRM (D64).
//
// O terceiro par do diagrama: canal é `ChannelAdapter`, fonte é
// `ContactSource`, e CRM é isto — o lugar para onde os fatos voltam e de onde
// os contatos podem vir. Plataforma nova é classe nova aqui e uma linha em
// `PLATAFORMAS_COM_ADAPTER`; o motor não muda.
//
// Mesma regra do diretório inteiro: só `fetch`, injetável. É o que faz o
// mesmo arquivo rodar no Deno da edge function e no Node do teste (D30).

import type { Buscador } from './tipos.ts';
import { PipefyAdapter } from './pipefy.ts';

/** O que a plataforma tem, na forma que a tela desenha. */
export interface EstruturaCrm {
  readonly pipes: PipeCrm[];
}

export interface PipeCrm {
  readonly id: string;
  readonly nome: string;
  readonly fases: FaseCrm[];
  /** Campos do formulário inicial: no Pipefy, onde mora telefone e e-mail. */
  readonly camposIniciais: CampoCrm[];
}

export interface FaseCrm {
  readonly id: string;
  readonly nome: string;
  readonly campos: CampoCrm[];
}

export interface CampoCrm {
  readonly id: string;
  readonly rotulo: string;
  readonly tipo: string;
  readonly opcoes: string[];
}

/** Um card lido, com cada campo pelo id e pelo rótulo. */
export interface CardCrm {
  readonly id: string;
  readonly titulo: string;
  readonly faseId: string;
  readonly campos: ReadonlyArray<{ readonly id: string; readonly rotulo: string; readonly valor: string }>;
}

export type AcaoCrm =
  | { readonly tipo: 'mover_fase'; readonly ref: string; readonly alvoId: string }
  | { readonly tipo: 'preencher_campo'; readonly ref: string; readonly alvoId: string; readonly valor: string };

/** Credenciais já juntadas: o `config` da conexão mais o segredo do Vault. */
export type CredenciaisCrm = Readonly<Record<string, string>>;

export interface CrmAdapter {
  readonly provedor: string;
  descobrir(cred: CredenciaisCrm): Promise<EstruturaCrm>;
  /** Cards das fases pedidas, até `limite` no total. */
  listarCards(cred: CredenciaisCrm, fases: readonly string[], limite: number): Promise<CardCrm[]>;
  /**
   * Executa uma ação, e repetir tem de ser inofensivo: o dreno tenta de novo
   * quando a passada anterior falhou no meio, e a ação que já tinha dado
   * certo roda outra vez. Por isso não há "comentar" nem "criar card".
   * Devolve o que fez, em português, para `outbox.resultado`.
   */
  executar(cred: CredenciaisCrm, acao: AcaoCrm): Promise<string>;
}

/**
 * Plataformas com adapter. Tem de bater com `crm_provider_catalog.tem_adapter`
 * — `tests/registro_para_sql.ts` compara as duas, pelo mesmo motivo do D54:
 * duas listas escritas à mão em linguagens diferentes divergem em silêncio.
 */
export const PLATAFORMAS_COM_ADAPTER = ['pipefy'] as const;

export function criarCrm(provedor: string, buscar: Buscador = fetch): CrmAdapter {
  switch (provedor) {
    case 'pipefy': return new PipefyAdapter(buscar);
    default:
      throw new Error(`plataforma sem adapter: ${provedor}`);
  }
}
