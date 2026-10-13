// Ler com anexos (D78b): a MESMA conta de IA que compõe o agente, lendo PDF e
// imagem além de texto.
//
// O caminho de composição (`ia.ts`) manda uma mensagem de texto; ler o
// material da empresa precisa de mais: o PDF e o print vão como blocos do
// próprio pedido, em base64. O pedido continua sendo montado por `criarIa` —
// URL, cabeçalhos, tokens, folga de quem raciocina e a leitura da resposta
// (recusa, corte, vazio, erro definitivo ou não) moram lá, uma vez só. O que
// este arquivo faz é trocar, no corpo que `ia.ts` montou, o texto da mensagem
// da pessoa pelos blocos com os anexos. Duas cópias de "o que é erro
// definitivo" seriam a regra divergindo em silêncio (D55); a troca, se o corpo
// de `ia.ts` mudar de forma, falha alto, e `tests/coleta.test.ts` a confere.
//
// `ia.ts` fica intocado de propósito: ele está no pacote do worker e do
// "Testar", e mudá-lo pediria republicar os dois por uma função que nenhum
// deles usa (D52).
//
// Só `fetch`, injetável (D30).

import type { Buscador } from './tipos.ts';
import type { Composicao } from './ia.ts';
import { criarIa } from './ia.ts';

export type Parte =
  | { readonly tipo: 'texto'; readonly texto: string }
  | { readonly tipo: 'pdf'; readonly nome: string; readonly base64: string }
  | { readonly tipo: 'imagem'; readonly nome: string; readonly mime: 'image/png' | 'image/jpeg'; readonly base64: string };

export interface PedidoDeLeitura {
  readonly credenciais: Readonly<Record<string, string>>;
  readonly modelo: string;
  readonly sistema: string;
  readonly partes: readonly Parte[];
  readonly maxTokens: number;
}

export interface Leitor {
  readonly provedor: string;
  ler(pedido: PedidoDeLeitura): Promise<Composicao>;
}

/**
 * Quem lê PDF e imagem pelo protocolo que o adapter fala. Claude (blocos
 * `document` e `image`), OpenAI (`file` e `image_url`, do gpt-4o em diante) e
 * OpenRouter (os mesmos dois). O DeepSeek não lê PDF, e o Perplexity e o
 * endpoint compatível não têm formato documentado que se possa conferir: com
 * eles, o material de texto vale e o anexo é recusado com o motivo.
 */
export const LEEM_ANEXOS = ['anthropic', 'openai', 'openrouter'] as const;

export function leAnexos(provedor: string): boolean {
  return (LEEM_ANEXOS as readonly string[]).includes(provedor);
}

/** Um PDF de 10 MB leva tempo para ser lido; mais que isto, a edge function
 *  inteira estouraria o próprio prazo antes de dizer por quê. */
export const PRAZO_DO_MODELO_MS = 120_000;

function textoDasPartes(partes: readonly Parte[]): string {
  return partes.filter((p): p is Extract<Parte, { tipo: 'texto' }> => p.tipo === 'texto')
    .map((p) => p.texto).join('\n\n');
}

/** Os blocos do Claude. A documentação pede o documento antes do texto que fala dele. */
export function blocosDoClaude(partes: readonly Parte[]): unknown[] {
  return partes.map((p) => p.tipo === 'texto' ? { type: 'text', text: p.texto }
    : p.tipo === 'pdf'
      ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: p.base64 } }
      : { type: 'image', source: { type: 'base64', media_type: p.mime, data: p.base64 } });
}

/** As partes do "chat completions" (OpenAI e OpenRouter). */
export function partesDoChat(partes: readonly Parte[]): unknown[] {
  return partes.map((p) => p.tipo === 'texto' ? { type: 'text', text: p.texto }
    : p.tipo === 'pdf'
      ? { type: 'file', file: { filename: p.nome, file_data: `data:application/pdf;base64,${p.base64}` } }
      : { type: 'image_url', image_url: { url: `data:${p.mime};base64,${p.base64}` } });
}

/**
 * Troca o texto da mensagem da pessoa pelos blocos. Recusa — em vez de mandar
 * só o texto — se o corpo não tiver a forma esperada: ler sem os anexos seria
 * um resumo do site passando por resumo do PDF.
 */
function trocarConteudo(corpo: string, marca: string, blocos: unknown[]): string {
  const o = JSON.parse(corpo) as { messages?: { role?: unknown; content?: unknown }[] };
  const alvo = Array.isArray(o.messages) ? [...o.messages].reverse().find((m) => m.role === 'user') : undefined;
  if (!alvo || alvo.content !== marca) throw new Error('o pedido do adapter de IA mudou de forma: os anexos não foram mandados');
  alvo.content = blocos;
  return JSON.stringify(o);
}

function erroDePrazo(erro: string, prazoMs: number): string {
  return /timed?\s*out|timeout|aborted/i.test(erro) ? `o modelo não respondeu em ${Math.round(prazoMs / 1000)} s` : erro;
}

export function criarLeitor(provedor: string, buscar: Buscador = fetch, prazoMs = PRAZO_DO_MODELO_MS): Leitor {
  return {
    provedor,
    async ler(p) {
      const anexos = p.partes.some((x) => x.tipo !== 'texto');
      if (anexos && !leAnexos(provedor)) {
        return { ok: false, definitivo: true, erro: `${provedor} não lê PDF nem imagem por aqui` };
      }
      // Sem anexo, a mensagem É o texto, e o corpo é o de sempre. Com anexo, o
      // texto é a marca que a troca procura — e também o que o modelo leria se
      // a troca não acontecesse, o que ela não deixa acontecer.
      const marca = textoDasPartes(p.partes) || '(material anexado)';
      const blocos = anexos ? (provedor === 'anthropic' ? blocosDoClaude(p.partes) : partesDoChat(p.partes)) : null;
      const comAnexos: Buscador = (url, init) => buscar(url, {
        ...init,
        ...(blocos ? { body: trocarConteudo(String(init?.body ?? ''), marca, blocos) } : {}),
        signal: AbortSignal.timeout(prazoMs),
      });
      const r = await criarIa(provedor, comAnexos).compor({
        credenciais: p.credenciais, modelo: p.modelo, sistema: p.sistema, mensagem: marca, maxTokens: p.maxTokens,
      });
      return r.ok ? r : { ...r, erro: erroDePrazo(r.erro, prazoMs) };
    },
  };
}
