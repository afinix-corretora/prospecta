// WhatsApp oficial via Gupshup.
//
// É o caminho oficial escolhido para a operação. A Gupshup é BSP homologada:
// o número é um WABA de verdade, com template e janela de 24h, mas a API é a
// dela, não a Graph da Meta.
//
// Múltiplas contas é o caso normal, não a exceção: cada app da Gupshup é um
// `sender_account` com o seu `app_name`, o seu `source` e o seu segredo no
// Vault. O pool e a quota por remetente (invariante 3) continuam valendo sem
// nada de novo — é por isso que `app_name` e `source` vêm em `credenciais`,
// resolvidos pelo chamador, e não de constante aqui dentro.
//
// A API de envio é form-urlencoded, não JSON. Não é descuido de quem escreveu:
// é o que a Gupshup aceita em /wa/api/v1/msg.

import type {
  Buscador, ChannelAdapter, EventoNormalizado, PedidoEnvio,
  ResultadoEnvio, Saude, TipoEvento,
} from './tipos.ts';
import { erroDeRede, exigir } from './tipos.ts';
import { normalizarTelefone } from './telefone.ts';

const BASE_PADRAO = 'https://api.gupshup.io/wa/api/v1';

export class WhatsAppGupshupAdapter implements ChannelAdapter {
  readonly canal = 'whatsapp' as const;
  readonly provedor = 'gupshup';

  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async send(pedido: PedidoEnvio): Promise<ResultadoEnvio> {
    let apiKey: string;
    let app: string;
    try {
      apiKey = exigir(pedido.credenciais, 'api_key');
      app = exigir(pedido.credenciais, 'app_name');
    } catch (e) {
      return { ok: false, erro: (e as Error).message, culpa: 'remetente' };
    }

    const numero = normalizarTelefone(pedido.destino);
    if (!numero) return { ok: false, erro: 'destino sem dígitos', culpa: 'destino' };

    // `remetente` é o identificador da conta no motor; o número de origem que
    // a Gupshup espera pode estar normalizado diferente, então a credencial
    // manda quando existe.
    const origem = normalizarTelefone(pedido.credenciais.source || pedido.remetente);
    if (!origem) return { ok: false, erro: 'remetente sem dígitos', culpa: 'remetente' };

    const base = pedido.credenciais.base_url || BASE_PADRAO;

    const corpo = new URLSearchParams({
      channel: 'whatsapp',
      source: origem,
      destination: numero,
      'src.name': app,
      message: JSON.stringify({ type: 'text', text: pedido.conteudo }),
    });

    try {
      const resp = await this.buscar(`${base}/msg`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          apikey: apiKey,
        },
        body: corpo.toString(),
      });

      const dados = await resp.json().catch(() => ({} as Record<string, unknown>));

      if (!resp.ok) {
        const msg = (dados as { message?: string }).message;
        return {
          ok: false,
          erro: msg ?? `HTTP ${resp.status}`,
          culpa: culpaGupshup(resp.status, msg),
        };
      }

      // Sucesso traz {status:"submitted", messageId:"..."}.
      const id = (dados as { messageId?: string }).messageId;
      if (!id) {
        return { ok: false, erro: 'resposta sem messageId', culpa: 'transitorio' };
      }
      return { ok: true, providerMessageId: id };
    } catch (e) {
      return erroDeRede(e);
    }
  }

  // A Gupshup manda um evento por POST, com `type` dizendo o que é. Resposta
  // de pessoa vem como type:"message"; confirmação, como type:"message-event".
  normalizeWebhook(corpo: unknown): EventoNormalizado[] {
    const raiz = corpo as { type?: string; payload?: Record<string, unknown> };
    const p = raiz?.payload;
    if (!p) return [];

    if (raiz.type === 'message-event') {
      const tipo = TIPO_POR_EVENTO[String(p.type ?? '')];
      const id = p.gsId ?? p.id;
      if (!id || !tipo) return [];
      return [{
        providerMessageId: String(id),
        tipo,
        ocorridoEm: instante(p.ts),
        payload: { evento: p.type, destino: p.destination ?? null },
      }];
    }

    if (raiz.type === 'message') {
      // `context.gsId` aponta para a mensagem nossa que está sendo respondida.
      // Sem ele não dá para ligar a resposta a um enrollment, e inventar o
      // vínculo seria encerrar a cadência da pessoa errada.
      const ctx = p.context as { gsId?: string; id?: string } | undefined;
      const alvo = ctx?.gsId ?? ctx?.id;
      if (!alvo) return [];
      return [{
        providerMessageId: String(alvo),
        tipo: 'respondido' as TipoEvento,
        ocorridoEm: instante(p.timestamp ?? p.ts),
        payload: { de: p.source ?? null, tipo_mensagem: p.type ?? null },
      }];
    }

    return [];
  }

  async checkHealth(credenciais: Record<string, string>): Promise<Saude> {
    try {
      const base = credenciais.base_url || BASE_PADRAO;
      const app = exigir(credenciais, 'app_name');
      const resp = await this.buscar(`${base}/app/${encodeURIComponent(app)}/wallet/balance`, {
        headers: { apikey: exigir(credenciais, 'api_key') },
      });
      return { ok: resp.ok, detalhe: `HTTP ${resp.status}` };
    } catch (e) {
      return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
    }
  }
}

const TIPO_POR_EVENTO: Record<string, TipoEvento> = {
  sent: 'enviado',
  delivered: 'entregue',
  read: 'lido',
  failed: 'falha',
  enqueued: 'enfileirado',
};

// 401/403 é a apikey; 400 costuma ser número fora do WhatsApp ou janela
// fechada. Só o primeiro grupo alimenta o circuit breaker.
function culpaGupshup(status: number, mensagem?: string): ResultadoEnvio['culpa'] {
  const m = (mensagem ?? '').toLowerCase();
  if (status === 401 || status === 403) return 'remetente';
  if (m.includes('authentication') || m.includes('apikey')) return 'remetente';
  if (m.includes('not a valid whatsapp') || m.includes('invalid destination')) return 'destino';
  if (status === 400) return 'destino';
  if (status === 429) return 'transitorio';
  return 'transitorio';
}

function instante(bruto: unknown): string {
  const n = Number(bruto);
  // A Gupshup manda epoch em milissegundos nos eventos e em segundos nas
  // mensagens. Abaixo de 10^12 é segundo.
  if (Number.isFinite(n) && n > 0) {
    return new Date(n < 1e12 ? n * 1000 : n).toISOString();
  }
  return new Date().toISOString();
}
