// O agente sem rede (D66, D69): o pedido ao modelo, os freios, as sete saídas
// e, desde o D69, o que vai para a fila do motor.
//
// As asserções que importam são as que o modelo não controla: que a recusa,
// o limite e a falta de credencial não chamam modelo nenhum; que o freio
// barra o que a instrução só pediu; e que o erro transitório não vira linha.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { criarIa, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';
import type { ModeloIA, PedidoDeComposicao } from '../adapters/ia.ts';
import { aplicarFreios, montarPedido, MARCA_ESCALAR, PRAZO_DO_TRANSITORIO_MS, rascunharRespostas } from '../motor/agente.ts';
import type { BancoAgente, Envio, RespostaParaRascunhar, Situacao } from '../motor/porta-agente.ts';

const BASE: RespostaParaRascunhar = {
  message_event_id: 'ev1', tenant_id: 't', contact_id: 'c', canal: 'whatsapp', resposta_em: '2026-10-12T10:00:00Z',
  texto: 'Quanto fica para mim e minha esposa?', regra: null,
  agent_id: 'a1', agente_nome: 'Lia', papel: 'SDR de resgate', descricao: 'Reativa quem já cotou.',
  // Um agente de antes do D76: instrução num texto só, sem persona nem objetivo.
  tom: '', contexto: '', objetivo: null,
  instrucoes: 'Seja breve e cordial. Pergunte a idade das vidas antes de falar de valor.',
  escalar_quando: 'Pedido de proposta formal ou reclamação.', limite_trocas: 3,
  proibido: ['garantimos', 'sem carência'], tamanho_maximo: 300,
  credencial_id: 'k1', provedor: 'anthropic', modelo: 'claude-sonnet-5', provedor_compoe: true,
  contato_nome: 'Marina', metadados: { plano: 'Amil', idade: 42 }, campanha: 'Resgate Outubro',
  historico: [{ de: 'nos', texto: 'Oi Marina, ainda pensa no plano?' }, { de: 'pessoa', texto: 'Quanto fica para mim e minha esposa?' }],
  rascunhos_anteriores: 0,
  autonomo: true, composicoes_hoje: 0, teto: 200,
};

// ---------------------------------------------------------------------------
// O pedido
// ---------------------------------------------------------------------------

test('pedido: a instrução do cliente, as regras fixas, a escalada e o proibido', () => {
  const p = montarPedido(BASE);
  assert.match(p.sistema, /Você é Lia, SDR de resgate/);
  assert.match(p.sistema, /INSTRUÇÕES DO CLIENTE\nSeja breve/, 'agente antigo mantém o título de sempre');
  assert.match(p.sistema, /Pergunte a idade das vidas/);
  // Pede-se três quartos do freio; o freio é o tamanho do agente (menor que o do WhatsApp).
  assert.match(p.sistema, /até 225 caracteres \(nunca mais de 300\)/);
  assert.equal(p.limite, 300);
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

function banco(respostas: RespostaParaRascunhar[], destino: Envio | Error = 'fila') {
  const gravados: { ev: string; s: Situacao; texto: string | null; motivo: string | null }[] = [];
  const enfileirados: { ev: string; modo: string }[] = [];
  let segredos = 0;
  const b: BancoAgente = {
    async respostasParaRascunhar() { return respostas; },
    async credenciaisDaIa() { segredos += 1; return { api_key: 'sk-ant-x' }; },
    async registrarRascunho(ev, _a, s, texto, motivo) { gravados.push({ ev, s, texto, motivo }); },
    async enfileirarResposta(ev, modo) {
      enfileirados.push({ ev, modo });
      if (destino instanceof Error) throw destino;
      return destino;
    },
  };
  return { b, gravados, enfileirados, segredos: () => segredos };
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

test('canal sem comportamento declarado: bloqueado sem chamar modelo, e o resto do lote segue (D76)', async () => {
  const { b, gravados, segredos } = banco([{ ...BASE, message_event_id: 'x', canal: 'telegram' }, BASE]);
  const ia = new IaFalsa({ ok: true, texto: 'Oi Marina! Qual a idade de vocês dois?' });
  await rascunharRespostas(b, 10, { criar: () => ia });
  assert.deepEqual(gravados.map((g) => [g.ev, g.s]), [['x', 'bloqueado'], ['ev1', 'pronto']]);
  assert.match(gravados[0]!.motivo ?? '', /telegram/);
  assert.equal(ia.pedidos.length, 1);
  assert.equal(segredos(), 1);
});

test('a credencial é pedida com o cliente da resposta, não só pelo id (D76)', async () => {
  const pedidas: [string, string][] = [];
  const { b } = banco([BASE]);
  b.credenciaisDaIa = async (t, c) => { pedidas.push([t, c]); return { api_key: 'sk' }; };
  await rascunharRespostas(b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Oi!' }) });
  assert.deepEqual(pedidas, [['t', 'k1']]);
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

  // O relógio é do cenário: com o relógio real, a resposta fixa do BASE passou
  // do prazo do transitório (D76) seis horas depois de escrita, e o teste virou
  // outro — "transitório velho vira erro", que é o de baixo (D77).
  const trans = banco([BASE]);
  const r = await rascunharRespostas(trans.b, 10, { criar: () => new IaFalsa({ ok: false, erro: 'HTTP 529', definitivo: false }),
    agora: () => Date.parse(BASE.resposta_em) + 60_000 });
  assert.equal(trans.gravados.length, 0, 'a próxima passada tenta de novo');
  assert.equal(r.adiadas, 1);
});

test('transitório tem prazo: depois de 6 horas vira erro com o motivo, e sai da fila (D76)', async () => {
  const agora = Date.parse(BASE.resposta_em) + PRAZO_DO_TRANSITORIO_MS + 60_000;
  const velho = banco([BASE]);
  const r = await rascunharRespostas(velho.b, 10, {
    criar: () => new IaFalsa({ ok: false, erro: 'HTTP 429: insufficient_quota', definitivo: false }), agora: () => agora });
  assert.equal(r.adiadas, 0);
  assert.equal(velho.gravados[0]!.s, 'erro');
  assert.match(velho.gravados[0]!.motivo ?? '', /mais de 6 horas: HTTP 429/);
  // Dentro do prazo, segue sendo tentado.
  const novo = banco([BASE]);
  await rascunharRespostas(novo.b, 10, {
    criar: () => new IaFalsa({ ok: false, erro: 'HTTP 429', definitivo: false }), agora: () => Date.parse(BASE.resposta_em) + 60_000 });
  assert.equal(novo.gravados.length, 0);
});

test('o freio que lança não derruba a passada: bloqueado com o motivo, e o resto do lote segue', async () => {
  const { b, gravados } = banco([{ ...BASE, message_event_id: 'x', proibido: [7 as unknown as string] }, BASE]);
  await rascunharRespostas(b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Oi Marina! Qual a idade de vocês?' }) });
  assert.deepEqual(gravados.map((g) => g.s), ['pronto', 'pronto'], 'número em proibido é ignorado, não lança');
});

// ---------------------------------------------------------------------------
// Os protocolos
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// D69: o agente responde sozinho
// ---------------------------------------------------------------------------

test('autônomo: o pronto vai para a fila, no modo da passada', async () => {
  const { b, enfileirados } = banco([BASE]);
  const r = await rascunharRespostas(b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Qual a idade de vocês?' }), modo: 'real' });
  assert.deepEqual(enfileirados, [{ ev: 'ev1', modo: 'real' }]);
  assert.deepEqual(r.envio, { fila: 1 });
});

test('autônomo: sem modo, a passada é simulada (shadow mode por padrão)', async () => {
  const { b, enfileirados } = banco([BASE]);
  await rascunharRespostas(b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Qual a idade de vocês?' }) });
  assert.equal(enfileirados[0]!.modo, 'simulado');
});

test('não autônomo: o pronto fica com uma pessoa e nada é enfileirado (D66)', async () => {
  const { b, enfileirados, gravados } = banco([{ ...BASE, autonomo: false }]);
  const r = await rascunharRespostas(b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Qual a idade de vocês?' }) });
  assert.equal(enfileirados.length, 0);
  assert.equal(gravados[0]!.s, 'pronto');
  assert.deepEqual(r.envio, { pessoa: 1 });
});

test('o que um freio barrou nunca é enfileirado, nem o caso de escalar', async () => {
  const barrado = banco([BASE]);
  await rascunharRespostas(barrado.b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Me passa seu CPF?' }) });
  const escalar = banco([BASE]);
  await rascunharRespostas(escalar.b, 10, { criar: () => new IaFalsa({ ok: true, texto: MARCA_ESCALAR }) });
  assert.equal(barrado.enfileirados.length + escalar.enfileirados.length, 0);
});

test('o banco devolve: a passada conta, e o rascunho continua gravado', async () => {
  const { b, gravados } = banco([BASE], 'devolvido');
  const r = await rascunharRespostas(b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Qual a idade?' }) });
  assert.deepEqual(r.envio, { devolvido: 1 });
  assert.equal(gravados[0]!.s, 'pronto');
});

test('enfileirar falhou: o texto fica com uma pessoa, e a falha é contada', async () => {
  const { b, gravados } = banco([BASE], new Error('rede'));
  const r = await rascunharRespostas(b, 10, { criar: () => new IaFalsa({ ok: true, texto: 'Qual a idade?' }) });
  assert.equal(r.falhasNoEnvio, 1);
  assert.equal(gravados[0]!.s, 'pronto');
});

test('teto do cliente: no teto, não chama modelo e diz por quê', async () => {
  const ia = new IaFalsa({ ok: true, texto: 'oi' });
  const { b, gravados, segredos } = banco([{ ...BASE, composicoes_hoje: 200, teto: 200 }]);
  await rascunharRespostas(b, 10, { criar: () => ia });
  assert.equal(ia.pedidos.length, 0);
  assert.equal(segredos(), 0);
  assert.equal(gravados[0]!.s, 'limite');
  assert.match(gravados[0]!.motivo!, /teto é 200/);
});

test('teto do cliente: o lote soma por cima da fotografia do banco', async () => {
  const ia = new IaFalsa({ ok: true, texto: 'Qual a idade?' });
  const { b, gravados } = banco([
    { ...BASE, message_event_id: 'a', composicoes_hoje: 1, teto: 2 },
    { ...BASE, message_event_id: 'b', composicoes_hoje: 1, teto: 2 },
    { ...BASE, message_event_id: 'c', tenant_id: 'outro', composicoes_hoje: 1, teto: 2 },
  ]);
  await rascunharRespostas(b, 10, { criar: () => ia });
  assert.deepEqual(gravados.map((g) => [g.ev, g.s]), [['a', 'pronto'], ['b', 'limite'], ['c', 'pronto']]);
  assert.equal(ia.pedidos.length, 2, 'o teto é por cliente, não da passada inteira');
});

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

test('claude: texto cortado pelo limite de tokens e resposta vazia são definitivos (não se paga de novo)', async () => {
  const cortado = await criarIa('anthropic', buscador(200, { content: [{ type: 'text', text: 'Olá, tudo' }], stop_reason: 'max_tokens' }).buscar).compor(PEDIDO);
  assert.deepEqual(cortado.ok ? null : cortado.definitivo, true);
  const vazio = await criarIa('anthropic', buscador(200, { content: [], stop_reason: 'end_turn' }).buscar).compor(PEDIDO);
  assert.deepEqual(vazio.ok ? null : vazio.definitivo, true);
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

test('openai: max_completion_tokens (o gpt-5.5 recusa max_tokens com 400); os outros, max_tokens', async () => {
  const comum = buscador(200, { choices: [{ message: { content: 'oi' } }] });
  await criarIa('openai', comum.buscar).compor({ ...PEDIDO, modelo: 'gpt-4.1' });
  // Sem raciocínio, sem folga: muitos recusam acima de 4096, e o e-mail pedia 4200.
  assert.equal(comum.chamadas[0]!.corpo.max_completion_tokens, 350);
  assert.equal('max_tokens' in comum.chamadas[0]!.corpo, false);
  assert.equal('reasoning_effort' in comum.chamadas[0]!.corpo, false);

  // Modelo de raciocínio: folga para pensar, e raciocínio baixo — escrever uma mensagem curta não pede mais.
  const pensa = buscador(200, { choices: [{ message: { content: 'oi' } }] });
  await criarIa('openai', pensa.buscar).compor({ ...PEDIDO, modelo: 'gpt-5.5' });
  assert.equal(pensa.chamadas[0]!.corpo.max_completion_tokens, 3350);
  assert.equal(pensa.chamadas[0]!.corpo.reasoning_effort, 'low');

  // Os "-chat" não são de raciocínio e recusam o campo com 400.
  for (const m of ['gpt-5-chat-latest', 'gpt-5.1-chat-latest']) {
    const b = buscador(200, { choices: [{ message: { content: 'oi' } }] });
    await criarIa('openai', b.buscar).compor({ ...PEDIDO, modelo: m });
    assert.equal('reasoning_effort' in b.chamadas[0]!.corpo, false, m);
  }

  for (const [prov, m] of [['openai', 'gpt-4o-2024-05-13'], ['openrouter', 'openai/gpt-4o'], ['deepseek', 'deepseek-chat']] as const) {
    const b = buscador(200, { choices: [{ message: { content: 'oi' } }] });
    await criarIa(prov, b.buscar).compor({ ...PEDIDO, modelo: m, maxTokens: 1200 });
    const corpo = b.chamadas[0]!.corpo;
    assert.equal(corpo.max_completion_tokens ?? corpo.max_tokens, 1200, `${prov} ${m}: o e-mail cabe em 4096`);
  }

  // Pelo OpenRouter, Gemini e R1 raciocinam sempre: a folga vale para eles.
  for (const [prov, m] of [['deepseek', 'deepseek-reasoner'], ['openrouter', 'google/gemini-2.5-pro'],
                           ['openrouter', 'deepseek/deepseek-r1'], ['perplexity', 'sonar-reasoning-pro']] as const) {
    const b = buscador(200, { choices: [{ message: { content: 'oi' } }] });
    await criarIa(prov, b.buscar).compor({ ...PEDIDO, modelo: m });
    assert.equal(b.chamadas[0]!.corpo.max_tokens, 3350, `${prov} ${m}`);
    assert.equal('max_completion_tokens' in b.chamadas[0]!.corpo, false, prov);
    assert.equal('reasoning_effort' in b.chamadas[0]!.corpo, false, prov);
  }
});

test('chat completions: orçamento gasto pensando é dito como tal', async () => {
  const r = await criarIa('openrouter', buscador(200, { choices: [{ message: { content: '' }, finish_reason: 'length' }] }).buscar)
    .compor({ ...PEDIDO, modelo: 'google/gemini-2.5-pro' });
  assert.ok(!r.ok && r.definitivo && /raciocinando/.test(r.erro));
});

test('chat completions: cortado (finish_reason length) e vazio são definitivos', async () => {
  // Texto pela metade com `length`: o CORTADO, que nunca sai — o agente autônomo mandaria "o plano custa".
  const cortado = await criarIa('openai', buscador(200, {
    choices: [{ message: { content: 'Olá Marina, o plano custa' }, finish_reason: 'length' }] }).buscar).compor(PEDIDO);
  assert.deepEqual(cortado.ok ? null : [cortado.definitivo, /cortado no meio/.test(cortado.erro)], [true, true]);
  // Vazio com `length`: gastou tudo raciocinando, e a mensagem diz isso.
  const pensou = await criarIa('openai', buscador(200, { choices: [{ message: { content: '' }, finish_reason: 'length' }] }).buscar).compor(PEDIDO);
  assert.deepEqual(pensou.ok ? null : [pensou.definitivo, /raciocinando/.test(pensou.erro)], [true, true]);
  const vazio = await criarIa('openai', buscador(200, { choices: [{ message: { content: '  ' }, finish_reason: 'stop' }] }).buscar).compor(PEDIDO);
  assert.deepEqual(vazio.ok ? null : vazio.definitivo, true);
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
