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

/**
 * Modelo de raciocínio da OpenAI (gpt-5, o1, o3, o4…), que aceita
 * `reasoning_effort`. Os "-chat" (gpt-5-chat-latest) não são de raciocínio e
 * RECUSAM o campo com 400 — que viraria erro definitivo em toda composição.
 */
export function ehModeloDeRaciocinio(modelo: string): boolean {
  const m = modelo.trim().toLowerCase();
  return /^(openai\/)?(gpt-5|o\d)/.test(m) && !/chat/.test(m);
}

/**
 * Folga de tokens acima do que o texto precisa. O teto de tokens só limita
 * CUSTO: quem limita o tamanho é o freio. Modelo que raciocina — e pelo
 * OpenRouter o Gemini 2.5, o DeepSeek R1 e o Sonar Reasoning raciocinam
 * sempre — gasta o orçamento pensando antes de escrever; sem folga, devolve
 * vazio com `finish_reason = length` e o raciocínio já cobrado.
 */
export const FOLGA_DE_TOKENS = 3000;

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

// Os dois não melhoram repetindo o MESMO pedido, e repetir paga de novo a
// cada passada, fora do teto diário (que só conta o que vira linha). Por isso
// são definitivos: viram `erro` com o motivo, e uma pessoa vê (D76).
const CORTADO: Composicao = {
  ok: false, definitivo: true,
  erro: 'o modelo não terminou dentro do limite de tokens (texto cortado no meio não é mandado)',
};
const VAZIO: Composicao = { ok: false, definitivo: true, erro: 'o modelo devolveu uma resposta sem texto' };
const PENSOU_DEMAIS: Composicao = {
  ok: false, definitivo: true,
  erro: 'o modelo gastou o limite de tokens raciocinando e não escreveu a resposta — escolha um modelo sem raciocínio para o agente',
};

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
      if (corpo.stop_reason === 'max_tokens') return CORTADO;
      const blocos = Array.isArray(corpo.content) ? corpo.content as { type?: unknown; text?: unknown }[] : [];
      const texto = blocos.filter((b) => b.type === 'text' && typeof b.text === 'string')
        .map((b) => b.text as string).join('').trim();
      return texto ? { ok: true, texto } : VAZIO;
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

    // A OpenAI recusa `max_tokens` nos modelos novos ("use
    // max_completion_tokens", HTTP 400) — conferido ao vivo com o gpt-5.5, que
    // é a conta do cliente hoje (D76). Os outros provedores do protocolo
    // continuam no nome antigo, que é o que eles documentam.
    const raciocina = ehModeloDeRaciocinio(p.modelo);
    const teto = this.provedor === 'openai'
      ? { max_completion_tokens: p.maxTokens + FOLGA_DE_TOKENS }
      : { max_tokens: p.maxTokens + FOLGA_DE_TOKENS };

    try {
      const r = await this.buscar(`${base}/chat/completions`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          model: p.modelo,
          ...teto,
          // Escrever uma mensagem curta não pede raciocínio longo; sem isto o
          // modelo pode gastar o orçamento pensando e devolver vazio.
          ...(raciocina && this.provedor === 'openai' ? { reasoning_effort: 'low' } : {}),
          messages: [
            { role: 'system', content: p.sistema },
            { role: 'user', content: p.mensagem },
          ],
        }),
      });
      const corpo = await corpoJson(r);
      if (!r.ok) return { ok: false, erro: mensagemDeErro(corpo, r.status), definitivo: definitivoPorStatus(r.status) };
      const escolha = (corpo.choices as {
        message?: { content?: unknown; refusal?: unknown }; finish_reason?: unknown;
      }[] | undefined)?.[0];
      if (typeof escolha?.message?.refusal === 'string' && escolha.message.refusal) {
        return { ok: false, erro: 'o modelo recusou compor esta resposta', definitivo: true };
      }
      const texto = typeof escolha?.message?.content === 'string' ? escolha.message.content.trim() : '';
      if (escolha?.finish_reason === 'length') return texto ? CORTADO : PENSOU_DEMAIS;
      return texto ? { ok: true, texto } : VAZIO;
    } catch (e) {
      return { ok: false, erro: e instanceof Error ? e.message : String(e), definitivo: false };
    }
  }
}
