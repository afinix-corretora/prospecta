// Porta de acesso ao banco.
//
// O despachante e o receptor de webhook falam com esta interface, não com o
// supabase-js. Assim a lógica é testável sem banco e sem rede, e a edge
// function fica sendo só a fiação — a única parte que não dá para exercitar
// fora do Supabase.

import type { TipoEvento } from '../adapters/tipos.ts';

export interface MensagemParaEnviar {
  readonly message_id: string;
  readonly canal: string;
  readonly destino: string;
  readonly conteudo: string;
  readonly sender_id: string;
  readonly sender_ident: string;
  readonly campanha_tipo: string;
}

export type Culpa = 'remetente' | 'destino' | 'transitorio';

export interface Banco {
  /** Uma passada do agendador. */
  processarVencidos(limite: number, modo: 'simulado' | 'real'): Promise<number>;

  /** Reivindica mensagens pendentes com lease. */
  reivindicarPendentes(limite: number): Promise<MensagemParaEnviar[]>;

  /**
   * Provedor e credenciais do remetente, resolvidas do Vault.
   * Fora daqui ninguém toca em segredo.
   */
  credenciaisDoRemetente(senderId: string): Promise<{
    provedor: string;
    credenciais: Record<string, string>;
  }>;

  registrarResultado(
    messageId: string,
    ok: boolean,
    providerMessageId?: string,
    erro?: string,
    culpa?: Culpa,
  ): Promise<void>;

  /** Devolve true se o evento foi gravado; false se foi eco ou id desconhecido. */
  registrarEventoProvedor(
    providerMessageId: string,
    tipo: TipoEvento,
    ocorridoEm: string,
    payload: Record<string, unknown>,
  ): Promise<boolean>;

  /**
   * Resposta que o provedor não ligou a mensagem nenhuma (D23). O chip diz o
   * tenant; o banco acha a última mensagem que esse tenant mandou para este
   * número e grava o evento nela. Devolve false quando o número nunca recebeu
   * nada — alguém escrevendo do nada para o chip não é resposta a nada.
   */
  registrarRespostaPorNumero(
    senderId: string,
    valorNorm: string,
    ocorridoEm: string,
    payload: Record<string, unknown>,
  ): Promise<boolean>;
}
