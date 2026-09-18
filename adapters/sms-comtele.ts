// SMS via Comtele.
//
// Classificado em "migra quase intacto" no inventário: o cliente legado
// (`comtele-send-sms`) tinha uma responsabilidade só e nenhum acoplamento ao
// modelo de lote. O que muda aqui é de onde vem a credencial — parâmetro, não
// consulta ao banco dentro do adapter.

import type {
  Buscador, ChannelAdapter, EventoNormalizado, PedidoEnvio,
  ResultadoEnvio, Saude,
} from './tipos.ts';
import { erroDeRede, exigir } from './tipos.ts';
import { normalizarTelefone } from './telefone.ts';

const ENDPOINT = 'https://sms.comtele.com.br/api/v2/send';

export class SmsComteleAdapter implements ChannelAdapter {
  readonly canal = 'sms' as const;
  readonly provedor = 'comtele';

  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async send(pedido: PedidoEnvio): Promise<ResultadoEnvio> {
    let authKey: string;
    try {
      authKey = exigir(pedido.credenciais, 'auth_key');
    } catch (e) {
      return { ok: false, erro: (e as Error).message, culpa: 'remetente' };
    }

    const receptor = normalizarTelefone(pedido.destino);
    if (!receptor) return { ok: false, erro: 'telefone inválido', culpa: 'destino' };

    try {
      const resp = await this.buscar(ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'auth-key': authKey },
        body: JSON.stringify({
          Sender: pedido.remetente || undefined,
          Receivers: receptor,
          Content: pedido.conteudo,
        }),
      });

      const corpo = await resp.json().catch(() => ({} as Record<string, unknown>));
      const c = corpo as { Success?: boolean; Message?: string; Object?: unknown };

      if (!resp.ok || c.Success === false) {
        return {
          ok: false,
          erro: c.Message ?? `HTTP ${resp.status}`,
          culpa: resp.status === 401 || resp.status === 403 ? 'remetente'
               : resp.status >= 500 ? 'transitorio'
               : 'destino',
        };
      }

      return { ok: true, providerMessageId: c.Object != null ? String(c.Object) : undefined };
    } catch (e) {
      return erroDeRede(e);
    }
  }

  // A Comtele entrega status por consulta, não por webhook de entrega por
  // mensagem. Sem webhook, sem evento — melhor devolver nada do que inventar
  // um 'entregue' que ninguém confirmou.
  normalizeWebhook(_corpo: unknown): EventoNormalizado[] {
    return [];
  }

  async checkHealth(credenciais: Record<string, string>): Promise<Saude> {
    try {
      const resp = await this.buscar('https://sms.comtele.com.br/api/v2/status', {
        headers: { 'auth-key': exigir(credenciais, 'auth_key') },
      });
      return { ok: resp.ok, detalhe: `HTTP ${resp.status}` };
    } catch (e) {
      return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
    }
  }
}
