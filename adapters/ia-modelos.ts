// Quais modelos uma chave de IA alcança (D72).
//
// O campo "Modelo" era livre de propósito: catálogo de modelo muda toda
// semana, e uma lista escrita à mão no banco envelheceria sem avisar (é o
// `modelos_sugeridos` da OpenAI, vazio desde sempre). A resposta certa não é
// outra lista à mão: é perguntar ao provedor, com a chave que a pessoa acabou
// de colar, e deixá-la escolher do que ELA alcança.
//
// Só `fetch`, injetável, pela regra do diretório (D30). Nada aqui guarda nem
// devolve a chave: ela entra, vira cabeçalho, e o que sai são nomes.

import type { Buscador } from './tipos.ts';

export type ListaDeModelos =
  | { readonly ok: true; readonly modelos: readonly string[] }
  /** `semListagem`: o provedor não publica lista — a tela volta ao campo livre. */
  | { readonly ok: false; readonly erro: string; readonly semListagem?: boolean };

const BASE: Record<string, string> = {
  openai: 'https://api.openai.com/v1',
  deepseek: 'https://api.deepseek.com',
  openrouter: 'https://openrouter.ai/api/v1',
  anthropic: 'https://api.anthropic.com',
  google: 'https://generativelanguage.googleapis.com/v1beta',
};

/** Perplexity não tem rota de listagem; a tela usa as sugestões do catálogo. */
const SEM_LISTAGEM = new Set(['perplexity']);

/** O que a OpenAI devolve e não conversa: embedding, áudio, imagem, moderação. */
const NAO_CONVERSA =
  /embed|whisper|tts|dall-e|davinci|babbage|moderation|audio|realtime|transcribe|image|search|instruct|computer-use|sora/i;

export async function listarModelos(
  provedor: string,
  credenciais: Readonly<Record<string, string>>,
  buscar: Buscador = fetch,
): Promise<ListaDeModelos> {
  if (SEM_LISTAGEM.has(provedor)) {
    return { ok: false, erro: 'este provedor não publica a lista de modelos', semListagem: true };
  }
  const chave = (credenciais.api_key ?? '').trim();
  if (!chave) return { ok: false, erro: 'falta a chave de API' };

  const base = (credenciais.base_url || BASE[provedor] || '').replace(/\/+$/, '');
  if (!base) return { ok: false, erro: 'falta o endereço da API (base_url)' };
  // A chave só sai por https. Endpoint compatível em http seria a chave do
  // cliente atravessando a rede em claro, a partir de um botão "buscar".
  if (!base.startsWith('https://')) return { ok: false, erro: 'o endereço da API precisa ser https' };

  try {
    if (provedor === 'anthropic') return await anthropic(base, chave, buscar);
    if (provedor === 'google') return await google(base, chave, buscar);
    return await compativel(provedor, base, chave, credenciais, buscar);
  } catch (e) {
    return { ok: false, erro: `não foi possível falar com o provedor: ${e instanceof Error ? e.message : String(e)}` };
  }
}

async function corpo(r: Response): Promise<Record<string, unknown>> {
  try { return (await r.json()) as Record<string, unknown>; } catch { return {}; }
}

function falha(r: Response, c: Record<string, unknown>): ListaDeModelos {
  if (r.status === 401 || r.status === 403) {
    return { ok: false, erro: 'o provedor recusou a chave — confira se ela foi copiada inteira e se está ativa' };
  }
  const e = c.error as { message?: unknown } | string | undefined;
  const m = typeof e === 'string' ? e : e?.message;
  return { ok: false, erro: typeof m === 'string' && m ? `HTTP ${r.status}: ${m}` : `HTTP ${r.status}` };
}

/** Mais novo primeiro quando o provedor diz a data; senão, por nome. */
function ordenar(itens: { id: string; criado: number }[]): string[] {
  const vistos = new Set<string>();
  return itens
    .sort((a, b) => b.criado - a.criado || a.id.localeCompare(b.id))
    .map((x) => x.id)
    .filter((id) => (vistos.has(id) ? false : (vistos.add(id), true)));
}

async function compativel(
  provedor: string, base: string, chave: string,
  credenciais: Readonly<Record<string, string>>, buscar: Buscador,
): Promise<ListaDeModelos> {
  const headers: Record<string, string> = { Authorization: `Bearer ${chave}` };
  if (provedor === 'openai' && credenciais.organizacao) headers['OpenAI-Organization'] = credenciais.organizacao;
  const r = await buscar(`${base}/models`, { headers });
  const c = await corpo(r);
  if (!r.ok) return falha(r, c);
  const dados = Array.isArray(c.data) ? c.data as { id?: unknown; created?: unknown }[] : [];
  const itens = dados
    .filter((m) => typeof m.id === 'string' && m.id)
    .map((m) => ({ id: m.id as string, criado: typeof m.created === 'number' ? m.created : 0 }))
    .filter((m) => !NAO_CONVERSA.test(m.id))
    // Da OpenAI, só as famílias que conversam por chat completions. Dos
    // outros, a lista inteira: o filtro acima já tira o que não é texto.
    .filter((m) => provedor !== 'openai' || /^(gpt-|o\d|chatgpt-)/.test(m.id));
  return { ok: true, modelos: ordenar(itens) };
}

async function anthropic(base: string, chave: string, buscar: Buscador): Promise<ListaDeModelos> {
  const r = await buscar(`${base}/v1/models?limit=100`, {
    headers: { 'x-api-key': chave, 'anthropic-version': '2023-06-01' },
  });
  const c = await corpo(r);
  if (!r.ok) return falha(r, c);
  const dados = Array.isArray(c.data) ? c.data as { id?: unknown; created_at?: unknown }[] : [];
  return {
    ok: true,
    modelos: ordenar(dados
      .filter((m) => typeof m.id === 'string' && m.id)
      .map((m) => ({
        id: m.id as string,
        criado: typeof m.created_at === 'string' ? Date.parse(m.created_at) || 0 : 0,
      }))),
  };
}

async function google(base: string, chave: string, buscar: Buscador): Promise<ListaDeModelos> {
  // A chave do Gemini vai em cabeçalho, não na URL: URL acaba em log.
  const r = await buscar(`${base}/models?pageSize=200`, { headers: { 'x-goog-api-key': chave } });
  const c = await corpo(r);
  if (!r.ok) return falha(r, c);
  const dados = Array.isArray(c.models)
    ? c.models as { name?: unknown; supportedGenerationMethods?: unknown }[] : [];
  return {
    ok: true,
    modelos: ordenar(dados
      .filter((m) => typeof m.name === 'string'
        && Array.isArray(m.supportedGenerationMethods)
        && (m.supportedGenerationMethods as unknown[]).includes('generateContent'))
      .map((m) => ({ id: (m.name as string).replace(/^models\//, ''), criado: 0 }))
      .filter((m) => !NAO_CONVERSA.test(m.id))),
  };
}
