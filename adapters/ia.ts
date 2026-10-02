// Modelos de IA: quem compõe o rascunho do agente (D66).
//
// Dois protocolos cobrem seis dos sete provedores do catálogo: o do Claude
// (Messages API) e o de "chat completions", que OpenAI, DeepSeek, OpenRouter,
// Perplexity e qualquer endpoint compatível falam. O Gemini tem protocolo
// próprio e fica sem adapter — `ai_provider_catalog.tem_adapter` diz isso, e
// `tests/registro_para_sql.ts` confere que as duas listas concordam.
//
// Só `fetch`, injetável, pela regra do diretório (D30). A chave chega
// resolvida do Vault pelo chamador; nada aqui lê ambiente.

import type { Buscador } from './tipos.ts';

export interface PedidoDeComposicao {
  readonly credenciais: Readonly<Record<string, string>>;
  readonly modelo: string;
  readonly sistema: string;
  readonly mensagem: string;
  readonly maxTokens: number;
}

export type Composicao =
  | { readonly ok: true; readonly texto: string }
  /**
   * `definitivo`: repetir não vai adiantar (chave recusada, modelo que não
   * existe, recusa do modelo). Transitório (429, 5xx, rede) é tentado de novo
   * na próxima passada, e por isso não vira linha em `rascunhos`.
   */
  | { readonly ok: false; readonly erro: string; readonly definitivo: boolean };

export interface ModeloIA {
  readonly provedor: string;
  compor(pedido: PedidoDeComposicao): Promise<Composicao>;
}

/** Tem de bater com `ai_provider_catalog.tem_adapter` (D54). */
export const PROVEDORES_IA_COM_ADAPTER = [
  'anthropic', 'openai', 'deepseek', 'openrouter', 'perplexity', 'compativel',
] as const;

const BASE_PADRAO: Record<string, string> = {
  openai: 'https://api.openai.com/v1',
  deepseek: 'https://api.deepseek.com',
  openrouter: 'https://openrouter.ai/api/v1',
  perplexity: 'https://api.perplexity.ai',
};

export function criarIa(provedor: string, buscar: Buscador = fetch): ModeloIA {
  if (provedor === 'anthropic') return new ClaudeIA(buscar);
  if ((PROVEDORES_IA_COM_ADAPTER as readonly string[]).includes(provedor)) {
    return new ChatCompletionsIA(provedor, buscar);
  }
  throw new Error(`provedor de IA sem adapter: ${provedor}`);
}

/** 401, 403, 404 e 400 não melhoram sozinhos; o resto pode melhorar. */
function definitivoPorStatus(status: number): boolean {
  return status === 400 || status === 401 || status === 403 || status === 404 || status === 422;
}

async function corpoJson(r: Response): Promise<Record<string, unknown>> {
  try { return (await r.json()) as Record<string, unknown>; } catch { return {}; }
}

function mensagemDeErro(corpo: Record<string, unknown>, status: number): string {
  const e = corpo.error as { message?: unknown } | string | undefined;
  const m = typeof e === 'string' ? e : e?.message;
  return typeof m === 'string' && m ? `HTTP ${status}: ${m}` : `HTTP ${status}`;
}

class ClaudeIA implements ModeloIA {
  readonly provedor = 'anthropic';
  private readonly buscar: Buscador;
  constructor(buscar: Buscador) { this.buscar = buscar; }

  async compor(p: PedidoDeComposicao): Promise<Composicao> {
    const chave = p.credenciais.api_key ?? '';
    if (!chave) return { ok: false, erro: 'credencial sem api_key', definitivo: true };
    const base = (p.credenciais.base_url || 'https://api.anthropic.com').replace(/\/+$/, '');
    try {
      const r = await this.buscar(`${base}/v1/messages`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': chave,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify({
          model: p.modelo,
          max_tokens: p.maxTokens,
          system: p.sistema,
          messages: [{ role: 'user', content: p.mensagem }],
        }),
      });
      const corpo = await corpoJson(r);
      if (!r.ok) return { ok: false, erro: mensagemDeErro(corpo, r.status), definitivo: definitivoPorStatus(r.status) };
      if (corpo.stop_reason === 'refusal') {
        return { ok: false, erro: 'o modelo recusou compor esta resposta', definitivo: true };
      }
      const blocos = Array.isArray(corpo.content) ? corpo.content as { type?: unknown; text?: unknown }[] : [];
      const texto = blocos.filter((b) => b.type === 'text' && typeof b.text === 'string')
        .map((b) => b.text as string).join('').trim();
      return texto ? { ok: true, texto } : { ok: false, erro: 'resposta sem texto', definitivo: false };
    } catch (e) {
      return { ok: false, erro: e instanceof Error ? e.message : String(e), definitivo: false };
    }
  }
}

class ChatCompletionsIA implements ModeloIA {
  readonly provedor: string;
  private readonly buscar: Buscador;
  constructor(provedor: string, buscar: Buscador) { this.provedor = provedor; this.buscar = buscar; }

  async compor(p: PedidoDeComposicao): Promise<Composicao> {
    const chave = p.credenciais.api_key ?? '';
    if (!chave) return { ok: false, erro: 'credencial sem api_key', definitivo: true };
    const base = (p.credenciais.base_url || BASE_PADRAO[this.provedor] || '').replace(/\/+$/, '');
    if (!base) return { ok: false, erro: 'endpoint compatível sem base_url', definitivo: true };

    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${chave}`,
    };
    if (this.provedor === 'openai' && p.credenciais.organizacao) headers['OpenAI-Organization'] = p.credenciais.organizacao;
    if (this.provedor === 'openrouter' && p.credenciais.referer) headers['HTTP-Referer'] = p.credenciais.referer;

    try {
      const r = await this.buscar(`${base}/chat/completions`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          model: p.modelo,
          max_tokens: p.maxTokens,
          messages: [
            { role: 'system', content: p.sistema },
            { role: 'user', content: p.mensagem },
          ],
        }),
      });
      const corpo = await corpoJson(r);
      if (!r.ok) return { ok: false, erro: mensagemDeErro(corpo, r.status), definitivo: definitivoPorStatus(r.status) };
      const escolha = (corpo.choices as { message?: { content?: unknown; refusal?: unknown } }[] | undefined)?.[0];
      if (typeof escolha?.message?.refusal === 'string' && escolha.message.refusal) {
        return { ok: false, erro: 'o modelo recusou compor esta resposta', definitivo: true };
      }
      const texto = typeof escolha?.message?.content === 'string' ? escolha.message.content.trim() : '';
      return texto ? { ok: true, texto } : { ok: false, erro: 'resposta sem texto', definitivo: false };
    } catch (e) {
      return { ok: false, erro: e instanceof Error ? e.message : String(e), definitivo: false };
    }
  }
}
