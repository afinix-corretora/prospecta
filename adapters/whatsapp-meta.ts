// WhatsApp oficial via Meta Cloud API.
//
// D6: oficial para base própria com opt-in. Migra de `meta-send-via-bsp` e
// `meta-webhook`. A versão da Graph API entra por credencial — no legado ela
// estava hardcoded como v18.0 em `whatsapp-sender` e configurável em
// `meta-send-via-bsp`, divergentes entre si.

import type {
  Buscador, ChannelAdapter, EventoNormalizado, PedidoEnvio,
  ResultadoEnvio, Saude, TipoEvento,
} from './tipos.ts';
import { erroDeRede, exigir } from './tipos.ts';
import { normalizarTelefone } from './telefone.ts';
import { emCaminho, primeiroTexto } from './texto.ts';

const VERSAO_PADRAO = 'v21.0';

export class WhatsAppMetaAdapter implements ChannelAdapter {
  readonly canal = 'whatsapp' as const;
  readonly provedor = 'meta_cloud';

  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async send(pedido: PedidoEnvio): Promise<ResultadoEnvio> {
    let token: string;
    try {
      token = exigir(pedido.credenciais, 'access_token');
    } catch (e) {
      return { ok: false, erro: (e as Error).message, culpa: 'remetente' };
    }

    const versao = pedido.credenciais.api_version || VERSAO_PADRAO;
    const numero = normalizarTelefone(pedido.destino);
    if (!numero) return { ok: false, erro: 'destino sem dígitos', culpa: 'destino' };

    // `remetente` é o phone_number_id da conta na Meta.
    const url = `https://graph.facebook.com/${versao}/${pedido.remetente}/messages`;

    try {
      const resp = await this.buscar(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          messaging_product: 'whatsapp',
          to: numero,
          type: 'text',
          text: { body: pedido.conteudo },
        }),
      });

      const corpo = await resp.json().catch(() => ({} as Record<string, unknown>));

      if (!resp.ok) {
        const erro = (corpo as { error?: { message?: string; code?: number } }).error;
        return {
          ok: false,
          erro: erro?.message ?? `HTTP ${resp.status}`,
          culpa: culpaMeta(resp.status, erro?.code),
        };
      }

      const id = (corpo as { messages?: { id?: string }[] }).messages?.[0]?.id;
      return { ok: true, providerMessageId: id };
    } catch (e) {
      return erroDeRede(e);
    }
  }

  normalizeWebhook(corpo: unknown): EventoNormalizado[] {
    const raiz = corpo as {
      entry?: { changes?: { value?: Record<string, unknown> }[] }[];
    };
    const eventos: EventoNormalizado[] = [];

    for (const entrada of raiz?.entry ?? []) {
      for (const mudanca of entrada.changes ?? []) {
        const valor = mudanca.value ?? {};

        // Confirmações de entrega do que nós mandamos.
        for (const s of (valor.statuses as Record<string, unknown>[] | undefined) ?? []) {
          const tipo = TIPO_POR_STATUS[String(s.status ?? '')];
          if (!s.id || !tipo) continue;
          eventos.push({
            providerMessageId: String(s.id),
            tipo,
            ocorridoEm: instante(s.timestamp),
            payload: { status: s.status },
          });
        }

        // Mensagens recebidas. `context.id` aponta para a mensagem nossa que
        // está sendo respondida — é o que liga a resposta ao enrollment.
        for (const m of (valor.messages as Record<string, unknown>[] | undefined) ?? []) {
          const contexto = m.context as { id?: string } | undefined;
          if (!contexto?.id) continue;
          eventos.push({
            providerMessageId: contexto.id,
            tipo: 'respondido' as TipoEvento,
            ocorridoEm: instante(m.timestamp),
            payload: {
              de: m.from ?? null,
              tipo_mensagem: m.type ?? null,
              // `text.body` nas de texto; legenda nas de mídia (D48).
              texto: primeiroTexto(emCaminho(m, 'text', 'body'),
                                    emCaminho(m, 'image', 'caption'),
                                    emCaminho(m, 'video', 'caption'),
                                    emCaminho(m, 'button', 'text')) ?? null,
            },
          });
        }
      }
    }

    return eventos;
  }

  async checkHealth(credenciais: Record<string, string>): Promise<Saude> {
    try {
      const versao = credenciais.api_version || VERSAO_PADRAO;
      const id = exigir(credenciais, 'phone_number_id');
      const resp = await this.buscar(`https://graph.facebook.com/${versao}/${id}`, {
        headers: { Authorization: `Bearer ${exigir(credenciais, 'access_token')}` },
      });
      return { ok: resp.ok, detalhe: `HTTP ${resp.status}` };
    } catch (e) {
      return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
    }
  }
}

const TIPO_POR_STATUS: Record<string, TipoEvento> = {
  sent: 'enviado',
  delivered: 'entregue',
  read: 'lido',
  failed: 'falha',
};

// 190 = token expirado, 133x = conta restrita ou banida: é a conta, não a
// mensagem. 131026 = destino sem WhatsApp.
function culpaMeta(status: number, codigo?: number): ResultadoEnvio['culpa'] {
  if (codigo === 190 || (codigo != null && codigo >= 1330 && codigo <= 1339)) return 'remetente';
  if (codigo === 131026 || codigo === 131051) return 'destino';
  if (status === 401 || status === 403) return 'remetente';
  if (status === 400) return 'destino';
  return 'transitorio';
}

function instante(bruto: unknown): string {
  const n = Number(bruto);
  if (Number.isFinite(n) && n > 0) return new Date(n * 1000).toISOString();
  return new Date().toISOString();
}
