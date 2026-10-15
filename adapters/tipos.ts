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
  | 'respondido' | 'clique' | 'falha' | 'rejeitado'
  // Assíncronos, e diferentes de `rejeitado` (que é recusa na hora do envio):
  // `devolvido` é aceitar e devolver depois; `denuncia` é a pessoa marcar
  // como spam, que não é problema de endereço nenhum (D49).
  | 'devolvido' | 'denuncia';

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

/**
 * Evento normalizado a partir do webhook do provedor.
 *
 * Duas formas de casar com a mensagem que o motor mandou, porque os provedores
 * não são iguais nisso:
 *
 * - `providerMessageId` — o provedor disse a qual mensagem o evento se refere.
 *   É o caso das oficiais e de toda confirmação de entrega.
 * - `deNumero` — o provedor não disse. Acontece na resposta de quem usa API não
 *   oficial: a mensagem dele não cita nada, e o id que vem no payload é o dele,
 *   que não existe em `messages`. Aí o vínculo é pelo número, resolvido no
 *   banco a partir do chip que recebeu o webhook (D23).
 *
 * Exatamente um dos dois. Emitir `providerMessageId` inventado para fingir o
 * primeiro caso grava um evento que nunca casa.
 */
export interface EventoNormalizado {
  readonly providerMessageId?: string;
  readonly deNumero?: string;
  readonly tipo: TipoEvento;
  readonly ocorridoEm: string;
  readonly payload: Record<string, unknown>;
}

/**
 * Provisionamento de instância. Só provedor que hospeda instância implementa —
 * a Meta e a Gupshup não criam número, quem cria é a operadora.
 */
export interface PedidoProvisionamento {
  /** URL do servidor do provedor. */
  readonly baseUrl: string;
  /** Token de administração, resolvido do Vault pelo chamador. */
  readonly adminToken: string;
  /** Nome da instância no painel do provedor. */
  readonly nome: string;
  /** Para onde o provedor deve mandar os eventos desta instância. */
  readonly webhookUrl?: string;
}

export interface ResultadoProvisionamento {
  readonly ok: boolean;
  readonly erro?: string;
  /** Credenciais da instância nova, para ir direto ao Vault. */
  readonly credenciais?: Record<string, string>;
  /** Identificador da instância no provedor. */
  readonly instancia?: string;
  /** QR em base64, quando o provedor devolve na criação. */
  readonly qrcode?: string;
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
  /** Opcional: só quem hospeda instância sabe criar uma. */
  provisionar?(pedido: PedidoProvisionamento): Promise<ResultadoProvisionamento>;
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
