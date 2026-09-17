// WhatsApp não-oficial via Evolution API (self-hosted).
//
// Este é o WhatsApp não-oficial real do grupo. O DECISOES.md (D6) supunha
// UAZAPI; o inventário da Fase 0 mostrou que UAZAPI não existe na base e que
// o que roda é Evolution. Ver INVENTARIO-FASE-0.md.
//
// Migra de `send-evolution-message` e `evolution-webhook`, que juntos tinham
// 1409 linhas — a maior parte delas roteamento e persistência que agora vivem
// no motor.

import type {
  Buscador, ChannelAdapter, EventoNormalizado, PedidoEnvio,
  ResultadoEnvio, Saude, TipoEvento,
} from './tipos.ts';
import { AUTORIA, erroDeRede, exigir } from './tipos.ts';
import { normalizarTelefone } from './telefone.ts';

interface ChaveEvolution {
  id?: string;
  fromMe?: boolean;
  remoteJid?: string;
}

export class WhatsAppEvolutionAdapter implements ChannelAdapter {
  readonly canal = 'whatsapp' as const;
  readonly provedor = 'evolution';

  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async send(pedido: PedidoEnvio): Promise<ResultadoEnvio> {
    let url: string;
    let apiKey: string;
    try {
      url = exigir(pedido.credenciais, 'api_url').replace(/\/$/, '');
      apiKey = exigir(pedido.credenciais, 'api_key');
    } catch (e) {
      // Credencial ausente é problema da conta, não da mensagem.
      return { ok: false, erro: (e as Error).message, culpa: 'remetente' };
    }

    const numero = normalizarTelefone(pedido.destino);
    if (!numero) return { ok: false, erro: 'destino sem dígitos', culpa: 'destino' };

    try {
      const resp = await this.buscar(`${url}/message/sendText/${pedido.remetente}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: apiKey },
        body: JSON.stringify({ number: numero, text: pedido.conteudo }),
      });

      const corpo = await resp.json().catch(() => ({} as Record<string, unknown>));

      if (!resp.ok) {
        return {
          ok: false,
          erro: descreverErro(corpo, resp.status),
          // 401/403 é a instância caída ou desconectada: tira do pool.
          // 400 costuma ser número que não existe no WhatsApp.
          culpa: resp.status === 401 || resp.status === 403 ? 'remetente'
               : resp.status === 400 ? 'destino'
               : 'transitorio',
        };
      }

      const chave = (corpo as { key?: ChaveEvolution }).key;
      return { ok: true, providerMessageId: chave?.id };
    } catch (e) {
      return erroDeRede(e);
    }
  }

  normalizeWebhook(corpo: unknown): EventoNormalizado[] {
    const raiz = corpo as {
      event?: string;
      data?: Record<string, unknown> | Record<string, unknown>[];
    };
    if (!raiz?.event) return [];

    const itens = Array.isArray(raiz.data) ? raiz.data : raiz.data ? [raiz.data] : [];

    if (raiz.event === 'messages.upsert') {
      return itens.flatMap((item) => {
        const chave = item.key as ChaveEvolution | undefined;
        // fromMe é o eco do que nós mesmos mandamos. Tratar como resposta do
        // contato faria o motor encerrar o enrollment no próprio disparo.
        if (!chave?.id || chave.fromMe) return [];
        return [{
          providerMessageId: chave.id,
          tipo: 'respondido' as TipoEvento,
          ocorridoEm: instante(item.messageTimestamp),
          payload: { remoteJid: chave.remoteJid ?? null, autoria: null },
        }];
      });
    }

    if (raiz.event === 'messages.update') {
      return itens.flatMap((item) => {
        const id = (item.keyId ?? (item.key as ChaveEvolution | undefined)?.id) as string | undefined;
        const tipo = TIPO_POR_STATUS[String(item.status ?? '').toUpperCase()];
        if (!id || !tipo) return [];
        return [{
          providerMessageId: id,
          tipo,
          ocorridoEm: instante(item.messageTimestamp),
          payload: { status: item.status },
        }];
      });
    }

    return [];
  }

  async checkHealth(credenciais: Record<string, string>): Promise<Saude> {
    try {
      const url = exigir(credenciais, 'api_url').replace(/\/$/, '');
      const resp = await this.buscar(`${url}/instance/connectionState/${credenciais.instancia ?? ''}`, {
        headers: { apikey: exigir(credenciais, 'api_key') },
      });
      const corpo = await resp.json().catch(() => ({} as Record<string, unknown>));
      const estado = (corpo as { instance?: { state?: string } })?.instance?.state;
      return { ok: resp.ok && estado === 'open', detalhe: estado ?? `HTTP ${resp.status}` };
    } catch (e) {
      return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
    }
  }
}

const TIPO_POR_STATUS: Record<string, TipoEvento> = {
  SERVER_ACK: 'enviado',
  DELIVERY_ACK: 'entregue',
  READ: 'lido',
  PLAYED: 'lido',
  ERROR: 'falha',
};

function instante(bruto: unknown): string {
  const n = Number(bruto);
  // Evolution manda epoch em segundos.
  if (Number.isFinite(n) && n > 0) return new Date(n * 1000).toISOString();
  return new Date().toISOString();
}

function descreverErro(corpo: unknown, status: number): string {
  const c = corpo as { message?: unknown; error?: unknown };
  const m = c?.message ?? c?.error;
  if (typeof m === 'string' && m) return m;
  if (m) return JSON.stringify(m);
  return `HTTP ${status}`;
}

export { AUTORIA };
