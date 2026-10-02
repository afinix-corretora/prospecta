// O agente sem rede (D66): o pedido ao modelo, os freios e as sete saídas.
//
// As asserções que importam são as que o modelo não controla: que a recusa,
// o limite e a falta de credencial não chamam modelo nenhum; que o freio
// barra o que a instrução só pediu; e que o erro transitório não vira linha.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { criarIa, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';
import type { ModeloIA, PedidoDeComposicao } from '../adapters/ia.ts';
import { aplicarFreios, montarPedido, MARCA_ESCALAR, rascunharRespostas } from '../motor/agente.ts';
import type { BancoAgente, RespostaParaRascunhar, Situacao } from '../motor/porta-agente.ts';

const BASE: RespostaParaRascunhar = {
  message_event_id: 'ev1', tenant_id: 't', contact_id: 'c', canal: 'whatsapp',
  texto: 'Quanto fica para mim e minha esposa?', regra: null,
  agent_id: 'a1', agente_nome: 'Lia', papel: 'SDR de resgate', descricao: 'Reativa quem já cotou.',
  instrucoes: 'Seja breve e cordial. Pergunte a idade das vidas antes de falar de valor.',
  escalar_quando: 'Pedido de proposta formal ou reclamação.', limite_trocas: 3,
  proibido: ['garantimos', 'sem carência'], tamanho_maximo: 300,
  credencial_id: 'k1', provedor: 'anthropic', modelo: 'claude-sonnet-5', provedor_compoe: true,
  contato_nome: 'Marina', metadados: { plano: 'Amil', idade: 42 }, campanha: 'Resgate Outubro',
  historico: [{ de: 'nos', texto: 'Oi Marina, ainda pensa no plano?' }, { de: 'pessoa', texto: 'Quanto fica para mim e minha esposa?' }],
  rascunhos_anteriores: 0,
};

// ---------------------------------------------------------------------------
// O pedido
// ---------------------------------------------------------------------------

test('pedido: a instrução do cliente, as regras fixas, a escalada e o proibido', () => {
  const p = montarPedido(BASE);
  assert.match(p.sistema, /Você é Lia, SDR de resgate/);
  assert.match(p.sistema, /Pergunte a idade das vidas/);
  assert.match(p.sistema, /no máximo 300 caracteres/);
  assert.match(p.sistema, /Não invente preço/);
  assert.match(p.sistema, /Pedido de proposta formal.*\[ESCALAR\]/);
  assert.match(p.sistema, /"garantimos", "sem carência"/);
});

test('pedido: a conversa em ordem e só variáveis de texto do contato', () => {
  const p = montarPedido(BASE);
  assert.ok(p.mensagem.indexOf('Nós: Oi Marina') < p.mensagem.indexOf('Pessoa: Quanto fica'));
  assert.match(p.mensagem, /- plano: Amil/);
  assert.doesNotMatch(p.mensagem, /idade: 42/, 'número não vira variável');
});

// ---------------------------------------------------------------------------
// Os freios
// ---------------------------------------------------------------------------

test('freio: a marca de escalada vira "escalar", e não texto', () => {
  assert.equal(aplicarFreios(MARCA_ESCALAR, BASE).situacao, 'escalar');
});

test('freio: o proibido é barrado mesmo com acento e caixa diferentes', () => {
  const f = aplicarFreios('Claro! E o melhor: SEM CARENCIA nenhuma.', BASE);
  assert.equal(f.situacao, 'bloqueado');
  assert.match((f as { motivo: string }).motivo, /sem carência/);
});

test('freio: o tamanho máximo é conferido, não só pedido', () => {
  assert.equal(aplicarFreios('a'.repeat(301), BASE).situacao, 'bloqueado');
  assert.equal(aplicarFreios('a'.repeat(300), BASE).situacao, 'pronto');
});

test('freio: pedido de CPF ou cartão nunca vira rascunho, seja qual for a instrução', () => {
  assert.equal(aplicarFreios('Me passa seu CPF para eu cotar?', BASE).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Qual o número do cartão?', BASE).situacao, 'bloqueado');
  assert.equal(aplicarFreios('Qual a idade de vocês dois?', BASE).situacao, 'pronto');
});

// ---------------------------------------------------------------------------
// As sete saídas
// ---------------------------------------------------------------------------

function banco(respostas: RespostaParaRascunhar[]) {
  const gravados: { ev: string; s: Situacao; texto: string | null; motivo: string | null }[] = [];
  let segredos = 0;
  const b: BancoAgente = {
    async respostasParaRascunhar() { return respostas; },
    async credenciaisDaIa() { segredos += 1; return { api_key: 'sk-ant-x' }; },
    async registrarRascunho(ev, _a, s, texto, motivo) { gravados.push({ ev, s, texto, motivo }); },
  };
  return { b, gravados, segredos: () => segredos };
}

class IaFalsa implements ModeloIA {
  readonly provedor = 'anthropic';
  pedidos: PedidoDeComposicao[] = [];
  private readonly resposta: Awaited<ReturnType<ModeloIA['compor']>>;
  constructor(resposta: Awaited<ReturnType<ModeloIA['compor']>>) { this.resposta = resposta; }
  async compor(p: PedidoDeComposicao) { this.pedidos.push(p); return this.resposta; }
}

test('saídas: recusa, limite e sem credencial não chamam modelo nem leem segredo', async () => {
  const ia = new IaFalsa({ ok: true, texto: 'oi' });
  const { b, gravados, segredos } = banco([
    { ...BASE, message_event_id: 'r', regra: 'recusa' },
    { ...BASE, message_event_id: 'l', rascunhos_anteriores: 3 },
    { ...BASE, message_event_id: 's', credencial_id: null, provedor: null, modelo: null },
    { ...BASE, message_event_id: 'g', provedor: 'google', provedor_compoe: false },
  ]);
  const r = await rascunharRespostas(b, 10, { criar: () => ia });
  assert.deepEqual(gravados.map((g) => [g.ev, g.s]), [['r', 'recusa'], ['l', 'limite'], ['s', 'sem_credencial'], ['g', 'sem_credencial']]);
  assert.equal(ia.pedidos.length, 0);
  assert.equal(segredos(), 0);
  assert.ok(gravados.every((g) => g.texto === null && g.motivo));
  assert.deepEqual(r.porSituacao, { recusa: 1, limite: 1, sem_credencial: 2 });
});

test('saídas: o texto bom vira rascunho pronto; o barrado, bloqueado com motivo', async () => {
  const bom = banco([BASE]);
  await rascunharRespostas(bom.b, 10, { criar: () => new IaFalsa({ ok: true, texto: '  Qual a idade de vocês?  ' }) });
  assert.deepEqual(bom.gravados[0], { ev: 'ev1', s: 'pronto', texto: 'Qual a idade de vocês?', motivo: null });

  const ruim = banco([BASE]);
  await rascunharRespostas(ruim.b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Garantimos o menor preço!' }) });
  assert.equal(ruim.gravados[0]!.s, 'bloqueado');
  assert.equal(ruim.gravados[0]!.texto, null);
});

test('saídas: erro definitivo fica gravado; transitório não vira linha', async () => {
  const def = banco([BASE]);
  await rascunharRespostas(def.b, 10, { criar: () => new IaFalsa({ ok: false, erro: 'HTTP 401', definitivo: true }) });
  assert.equal(def.gravados[0]!.s, 'erro');

  const trans = banco([BASE]);
  const r = await rascunharRespostas(trans.b, 10, { criar: () => new IaFalsa({ ok: false, erro: 'HTTP 529', definitivo: false }) });
  assert.equal(trans.gravados.length, 0, 'a próxima passada tenta de novo');
  assert.equal(r.adiadas, 1);
});

// ---------------------------------------------------------------------------
// Os protocolos
// ---------------------------------------------------------------------------

function buscador(status: number, corpo: unknown) {
  const chamadas: { url: string; headers: Headers; corpo: Record<string, unknown> }[] = [];
  const buscar = (async (url: string | URL | Request, init?: RequestInit) => {
    chamadas.push({ url: String(url), headers: new Headers(init?.headers), corpo: JSON.parse(String(init?.body)) });
    return new Response(JSON.stringify(corpo), { status });
  }) as typeof fetch;
  return { buscar, chamadas };
}

const PEDIDO: PedidoDeComposicao = {
  credenciais: { api_key: 'sk-x' }, modelo: 'm', sistema: 'S', mensagem: 'M', maxTokens: 350,
};

test('claude: Messages API com x-api-key e versão, texto juntado dos blocos', async () => {
  const { buscar, chamadas } = buscador(200, { content: [{ type: 'text', text: 'Olá ' }, { type: 'text', text: 'Marina' }], stop_reason: 'end_turn' });
  const r = await criarIa('anthropic', buscar).compor(PEDIDO);
  assert.deepEqual(r, { ok: true, texto: 'Olá Marina' });
  const c = chamadas[0]!;
  assert.equal(c.url, 'https://api.anthropic.com/v1/messages');
  assert.equal(c.headers.get('x-api-key'), 'sk-x');
  assert.equal(c.headers.get('anthropic-version'), '2023-06-01');
  assert.deepEqual(c.corpo, { model: 'm', max_tokens: 350, system: 'S', messages: [{ role: 'user', content: 'M' }] });
});

test('claude: recusa do modelo é definitiva; 401 também; 529 não', async () => {
  const recusa = await criarIa('anthropic', buscador(200, { content: [], stop_reason: 'refusal' }).buscar).compor(PEDIDO);
  assert.deepEqual(recusa.ok ? null : recusa.definitivo, true);
  const chave = await criarIa('anthropic', buscador(401, { error: { message: 'invalid x-api-key' } }).buscar).compor(PEDIDO);
  assert.deepEqual(chave.ok ? null : [chave.definitivo, chave.erro], [true, 'HTTP 401: invalid x-api-key']);
  const cheio = await criarIa('anthropic', buscador(529, {}).buscar).compor(PEDIDO);
  assert.equal(cheio.ok ? null : cheio.definitivo, false);
});

test('chat completions: endpoint por provedor, Bearer e system + user', async () => {
  for (const [prov, url] of [['openai', 'https://api.openai.com/v1/chat/completions'],
                             ['deepseek', 'https://api.deepseek.com/chat/completions'],
                             ['openrouter', 'https://openrouter.ai/api/v1/chat/completions']] as const) {
    const { buscar, chamadas } = buscador(200, { choices: [{ message: { content: 'oi' } }] });
    assert.deepEqual(await criarIa(prov, buscar).compor(PEDIDO), { ok: true, texto: 'oi' });
    assert.equal(chamadas[0]!.url, url);
    assert.equal(chamadas[0]!.headers.get('authorization'), 'Bearer sk-x');
    assert.deepEqual(chamadas[0]!.corpo.messages, [{ role: 'system', content: 'S' }, { role: 'user', content: 'M' }]);
  }
});

test('compatível: sem base_url é erro definitivo, sem chamar nada', async () => {
  const { buscar, chamadas } = buscador(200, {});
  const r = await criarIa('compativel', buscar).compor(PEDIDO);
  assert.equal(r.ok ? null : r.definitivo, true);
  assert.equal(chamadas.length, 0);
});

test('registro de IA: toda declarada cria, o Gemini não', () => {
  for (const p of PROVEDORES_IA_COM_ADAPTER) assert.equal(criarIa(p).provedor, p);
  assert.throws(() => criarIa('google'), /sem adapter/);
});
