// "Buscar modelos" sem rede (D72).
//
// O `fetch` é falso e grava cada chamada. O que importa conferir:
//
//   - a chave vira cabeçalho do jeito de cada provedor e NUNCA vai na URL;
//   - sem chave, sem https ou sem endereço, ninguém é chamado;
//   - da OpenAI sai só o que conversa, o mais novo primeiro;
//   - 401 vira frase que diz o que fazer, não "erro";
//   - conta salva: só quem a enxerga pelo RLS chega ao segredo, e o campo
//     digitado vale sobre o guardado;
//   - sem pessoa logada (a chave anon também é JWT), nada acontece.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { listarModelos } from '../adapters/ia-modelos.ts';
import { modelosDoPedido, type PortaModelos } from '../motor/modelos-ia.ts';

interface Chamada { url: string; headers: Headers }

function buscador(responder: (c: Chamada) => { status?: number; json: unknown }) {
  const chamadas: Chamada[] = [];
  const buscar = (async (url: string | URL | Request, init?: RequestInit) => {
    const c = { url: String(url), headers: new Headers(init?.headers) };
    chamadas.push(c);
    const r = responder(c);
    return new Response(JSON.stringify(r.json), { status: r.status ?? 200 });
  }) as typeof fetch;
  return { buscar, chamadas };
}

const CHAVE = 'sk-teste-0123456789';

test('OpenAI: Bearer, só modelos de conversa, mais novo primeiro', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { data: [
    { id: 'gpt-4o-mini', created: 100 },
    { id: 'text-embedding-3-large', created: 300 },
    { id: 'gpt-5', created: 200 },
    { id: 'whisper-1', created: 50 },
    { id: 'o3-mini', created: 150 },
    { id: 'gpt-4o-realtime-preview', created: 250 },
    { id: 'dall-e-3', created: 90 },
    { id: 'babbage-002', created: 10 },
  ] } }));
  const r = await listarModelos('openai', { api_key: CHAVE }, buscar);
  assert.deepEqual(r, { ok: true, modelos: ['gpt-5', 'o3-mini', 'gpt-4o-mini'] });
  assert.equal(chamadas[0].url, 'https://api.openai.com/v1/models');
  assert.equal(chamadas[0].headers.get('Authorization'), `Bearer ${CHAVE}`);
  assert.ok(!chamadas[0].url.includes(CHAVE));
});

test('OpenAI: organização vira cabeçalho quando preenchida', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { data: [] } }));
  await listarModelos('openai', { api_key: CHAVE, organizacao: 'org-x' }, buscar);
  assert.equal(chamadas[0].headers.get('OpenAI-Organization'), 'org-x');
});

test('Anthropic: x-api-key e versão, ordem pela data', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { data: [
    { id: 'claude-velho', created_at: '2024-01-01T00:00:00Z' },
    { id: 'claude-novo', created_at: '2026-01-01T00:00:00Z' },
  ] } }));
  const r = await listarModelos('anthropic', { api_key: CHAVE }, buscar);
  assert.deepEqual(r, { ok: true, modelos: ['claude-novo', 'claude-velho'] });
  assert.equal(chamadas[0].url, 'https://api.anthropic.com/v1/models?limit=100');
  assert.equal(chamadas[0].headers.get('x-api-key'), CHAVE);
  assert.equal(chamadas[0].headers.get('anthropic-version'), '2023-06-01');
  assert.equal(chamadas[0].headers.get('Authorization'), null);
});

test('Gemini: chave em cabeçalho, nunca na URL; só quem gera conteúdo', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { models: [
    { name: 'models/gemini-2.5-pro', supportedGenerationMethods: ['generateContent'] },
    { name: 'models/text-embedding-004', supportedGenerationMethods: ['embedContent'] },
  ] } }));
  const r = await listarModelos('google', { api_key: CHAVE }, buscar);
  assert.deepEqual(r, { ok: true, modelos: ['gemini-2.5-pro'] });
  assert.equal(chamadas[0].headers.get('x-goog-api-key'), CHAVE);
  assert.ok(!chamadas[0].url.includes(CHAVE));
});

test('compatível: usa a base_url dada, e recusa http', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { data: [{ id: 'llama-3' }] } }));
  const ok = await listarModelos('compativel', { api_key: CHAVE, base_url: 'https://llm.exemplo.com/v1/' }, buscar);
  assert.deepEqual(ok, { ok: true, modelos: ['llama-3'] });
  assert.equal(chamadas[0].url, 'https://llm.exemplo.com/v1/models');

  const http = await listarModelos('compativel', { api_key: CHAVE, base_url: 'http://llm.exemplo.com/v1' }, buscar);
  assert.equal(http.ok, false);
  const sem = await listarModelos('compativel', { api_key: CHAVE }, buscar);
  assert.equal(sem.ok, false);
  assert.equal(chamadas.length, 1, 'nem http nem endereço vazio chamam ninguém');
});

test('sem chave, ninguém é chamado; Perplexity diz que não lista', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: {} }));
  assert.equal((await listarModelos('openai', { api_key: '  ' }, buscar)).ok, false);
  const p = await listarModelos('perplexity', { api_key: CHAVE }, buscar);
  assert.deepEqual(p, { ok: false, erro: 'este provedor não publica a lista de modelos', semListagem: true });
  assert.equal(chamadas.length, 0);
});

test('401 vira instrução; outro erro traz a mensagem do provedor', async () => {
  const a = buscador(() => ({ status: 401, json: { error: { message: 'Incorrect API key' } } }));
  const r401 = await listarModelos('openai', { api_key: CHAVE }, a.buscar);
  assert.equal(r401.ok, false);
  assert.match((r401 as { erro: string }).erro, /recusou a chave/);
  assert.ok(!(r401 as { erro: string }).erro.includes(CHAVE));

  const b = buscador(() => ({ status: 429, json: { error: { message: 'Rate limit' } } }));
  assert.deepEqual(await listarModelos('openai', { api_key: CHAVE }, b.buscar), { ok: false, erro: 'HTTP 429: Rate limit' });
});

function porta(opcoes: { logada?: boolean; visivel?: boolean; segredo?: string | null } = {}) {
  const lidos: string[] = [];
  const p: PortaModelos = {
    async pessoaLogada() { return opcoes.logada ?? true; },
    async credencialVisivel() {
      return (opcoes.visivel ?? true) ? { provedor: 'openai', config: { organizacao: 'org-guardada' } } : null;
    },
    async segredo(id) { lidos.push(id); return opcoes.segredo === undefined ? JSON.stringify({ api_key: 'sk-guardada' }) : opcoes.segredo; },
  };
  return { p, lidos };
}

const ID = '11111111-2222-4333-8444-555555555555';

test('conta salva: o segredo do Vault entra, o campo digitado vale sobre ele', async () => {
  const { p } = porta();
  const { buscar, chamadas } = buscador(() => ({ json: { data: [{ id: 'gpt-5' }] } }));
  const r = await modelosDoPedido(p, { credencial_id: ID }, buscar);
  assert.deepEqual(r, { status: 200, corpo: { ok: true, modelos: ['gpt-5'] } });
  assert.equal(chamadas[0].headers.get('Authorization'), 'Bearer sk-guardada');
  assert.equal(chamadas[0].headers.get('OpenAI-Organization'), 'org-guardada');

  await modelosDoPedido(p, { credencial_id: ID, campos: { api_key: 'sk-digitada', base_url: 7 } }, buscar);
  assert.equal(chamadas[1].headers.get('Authorization'), 'Bearer sk-digitada');
  assert.equal(chamadas[1].url, 'https://api.openai.com/v1/models', 'número no campo não vira endereço');
});

test('conta que o RLS não mostra: 404, e o segredo nem é lido', async () => {
  const { p, lidos } = porta({ visivel: false });
  const { buscar, chamadas } = buscador(() => ({ json: {} }));
  const r = await modelosDoPedido(p, { credencial_id: ID }, buscar);
  assert.equal(r.status, 404);
  assert.equal(lidos.length, 0);
  assert.equal(chamadas.length, 0);
});

test('sem pessoa logada: 401, nada é chamado', async () => {
  const { p, lidos } = porta({ logada: false });
  const { buscar, chamadas } = buscador(() => ({ json: {} }));
  assert.equal((await modelosDoPedido(p, { provedor: 'openai', campos: { api_key: CHAVE } }, buscar)).status, 401);
  assert.equal((await modelosDoPedido(p, { credencial_id: ID }, buscar)).status, 401);
  assert.equal(lidos.length + chamadas.length, 0);
});

test('pedido malformado: 400', async () => {
  const { p } = porta();
  const { buscar } = buscador(() => ({ json: {} }));
  assert.equal((await modelosDoPedido(p, { credencial_id: 'x; drop' }, buscar)).status, 400);
  assert.equal((await modelosDoPedido(p, { provedor: '../etc' }, buscar)).status, 400);
  assert.equal((await modelosDoPedido(p, {}, buscar)).status, 400);
});
