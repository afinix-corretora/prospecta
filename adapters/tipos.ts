// Contrato dos adapters de canal.
//
// Canal novo = classe nova, zero mudança no motor. O motor já decidiu tudo
// (identidade, remetente, conteúdo) antes de chegar aqui: o adapter só fala o
// dialeto do provedor.
//
// Nada de API específica de runtime neste diretório — só `fetch` e tipos web.
// Assim o mesmo arquivo roda no Deno das edge functions e no Node dos testes.
// Segredo entra por parâmetro, resolvido pelo chamador a partir do Vault;
// nenhum adapter lê variável de ambiente.

export type Canal = 'email' | 'whatsapp' | 'sms' | 'instagram';

export type TipoEvento =
  | 'enfileirado' | 'enviado' | 'entregue' | 'lido'
  | 'respondido' | 'clique' | 'falha' | 'rejeitado';

/** O que o motor entrega ao adapter. Já passou pelo gate de supressão. */
export interface PedidoEnvio {
  readonly messageId: string;
  readonly destino: string;
  readonly conteudo: string;
  /** Identificador do remetente físico: número, instância, inbox. */
  readonly remetente: string;
  /** Credenciais já resolvidas do Vault pelo chamador. */
  readonly credenciais: Record<string, string>;
}

export interface ResultadoEnvio {
  readonly ok: boolean;
  readonly providerMessageId?: string;
  readonly erro?: string;
  /**
   * Distingue o que é culpa da conta do que é culpa da mensagem.
   * Só `remetente` alimenta o circuit breaker — derrubar uma conta boa por
   * causa de um número inválido esvazia o pool sem motivo.
   */
  readonly culpa?: 'remetente' | 'destino' | 'transitorio';
}

/** Evento normalizado a partir do webhook do provedor. */
export interface EventoNormalizado {
  readonly providerMessageId: string;
  readonly tipo: TipoEvento;
  readonly ocorridoEm: string;
  readonly payload: Record<string, unknown>;
}

export interface Saude {
  readonly ok: boolean;
  readonly detalhe: string;
}

export interface ChannelAdapter {
  readonly canal: Canal;
  readonly provedor: string;
  send(pedido: PedidoEnvio): Promise<ResultadoEnvio>;
  /** Puro: recebe o corpo do webhook, devolve eventos. Sem I/O, sem banco. */
  normalizeWebhook(corpo: unknown): EventoNormalizado[];
  checkHealth(credenciais: Record<string, string>): Promise<Saude>;
}

/** `fetch` injetado para que o teste não precise de rede. */
export type Buscador = typeof fetch;

/** Marca de autoria em toda escrita externa, para o webhook descartar o eco. */
export const AUTORIA = 'motor-prospeccao';

export function erroDeRede(e: unknown): ResultadoEnvio {
  return {
    ok: false,
    erro: e instanceof Error ? e.message : String(e),
    culpa: 'transitorio',
  };
}

/** Lê um campo obrigatório das credenciais com erro legível. */
export function exigir(creds: Record<string, string>, chave: string): string {
  const v = creds[chave];
  if (!v) throw new Error(`credencial ausente: ${chave}`);
  return v;
}
