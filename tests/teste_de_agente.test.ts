// "Testar" o agente na tela (D76), sem rede: o que a edge function
// `agente-testar` decide.
//
// O que importa:
//   - sem pessoa logada, conta que ela não alcança, ou pedido ruim: nem o
//     segredo é lido, nem o modelo é chamado;
//   - a fala de teste é a ÚLTIMA mensagem da pessoa no pedido ao modelo;
//   - o texto passa pelos MESMOS freios do worker — pedido de saída vira
//     escalada, texto longo é barrado pelo limite do canal;
//   - o segredo não volta na resposta.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { testarDoPedido } from '../motor/teste-de-agente.ts';
import type { ContaParaTeste, PortaTeste } from '../motor/teste-de-agente.ts';
import type { ModeloIA, PedidoDeComposicao, Composicao } from '../adapters/ia.ts';
import { MARCA_SAIR } from '../adapters/prompt-do-agente.ts';

const CONTA = '11111111-1111-4111-8111-111111111111';

const AGENTE = {
  agente_nome: 'Ana', papel: 'assistente de relacionamento', descricao: 'Retoma.', tom: 'Fale calmo.',
  instrucoes: 'Retome a conversa de onde parou, uma pergunta por vez, sem prometer nada.',
  contexto: 'Falamos em nome da Afinix Corretora, em Rio Preto. Planos de saúde.', objetivo: 'resgate',
  escalar_quando: 'Pedido de proposta.', proibido: ['garantimos'], tamanho_maximo: null,
  contato_nome: 'Marina', metadados: {}, campanha: 'Exemplo',
  historico: [{ de: 'nos', texto: 'Oi Marina, ainda faz sentido retomar?' }, { de: 'pessoa', texto: 'exemplo' }],
};

function porta(o: { logada?: boolean; conta?: ContaParaTeste | null; regra?: { termo: string; acao: string } } = {}) {
  let segredos = 0;
  const p: PortaTeste = {
    async pessoaLogada() { return o.logada ?? true; },
    async credencialVisivel() {
      return o.conta === undefined
        ? { tenant_id: 't1', provedor: 'openai', modelo: 'gpt-5.5', ativo: true, config: { organizacao: 'org-1' } } : o.conta;
    },
    async segredo() { segredos += 1; return JSON.stringify({ api_key: 'sk-segredo-que-nao-volta' }); },
    async regraDaBlacklist() { return o.regra ?? null; },
  };
  return { p, segredos: () => segredos };
}

class IaFalsa implements ModeloIA {
  readonly provedor = 'openai';
  pedidos: PedidoDeComposicao[] = [];
  private readonly r: Composicao;
  constructor(r: Composicao) { this.r = r; }
  async compor(p: PedidoDeComposicao) { this.pedidos.push(p); return this.r; }
}

const pedido = (extra: Record<string, unknown> = {}) =>
  ({ credencial_id: CONTA, canal: 'whatsapp', texto: 'tenho interesse, como funciona?', agente: AGENTE, ...extra });

test('compõe com o texto da tela: a fala de teste é a última da pessoa, e a chave vem do Vault', async () => {
  const { p } = porta();
  const ia = new IaFalsa({ ok: true, texto: 'Oi, Marina! Que bom. Prefere conversar com um especialista?' });
  const r = await testarDoPedido(p, pedido(), undefined, () => ia);
  assert.equal(r.status, 200);
  assert.ok(r.corpo.ok && r.corpo.situacao === 'pronto');
  const enviado = ia.pedidos[0]!;
  assert.match(enviado.mensagem, /Pessoa: tenho interesse, como funciona\?\n\nEscreva a próxima mensagem\.$/);
  assert.doesNotMatch(enviado.mensagem, /Pessoa: exemplo/, 'a fala do exemplo é trocada pela de teste');
  assert.match(enviado.sistema, /COMO ESTE CANAL FUNCIONA \(WhatsApp\)/);
  assert.equal(enviado.credenciais.api_key, 'sk-segredo-que-nao-volta');
  assert.equal(enviado.credenciais.organizacao, 'org-1');
  assert.ok(!JSON.stringify(r).includes('sk-segredo'), 'o segredo não volta à tela');
});

test('os freios do worker valem: pedido de saída escala, texto longo é barrado pelo canal', async () => {
  const saida = await testarDoPedido(porta().p, pedido({ texto: 'para de me mandar mensagem' }), undefined,
    () => new IaFalsa({ ok: true, texto: MARCA_SAIR }));
  assert.ok(saida.corpo.ok && saida.corpo.situacao === 'escalar');
  const longo = await testarDoPedido(porta().p, pedido({ canal: 'sms' }), undefined,
    () => new IaFalsa({ ok: true, texto: 'a'.repeat(200) }));
  assert.ok(longo.corpo.ok && longo.corpo.situacao === 'bloqueado' && /160/.test(longo.corpo.motivo));
});

test('erro do provedor volta como situação, não como falha da tela', async () => {
  const r = await testarDoPedido(porta().p, pedido(), undefined,
    () => new IaFalsa({ ok: false, erro: 'HTTP 400: Unsupported parameter', definitivo: true }));
  assert.equal(r.status, 200);
  assert.ok(r.corpo.ok && r.corpo.situacao === 'erro' && /Unsupported/.test(r.corpo.motivo));
});

test('sem pessoa, sem conta alcançável ou com pedido ruim: nem segredo, nem modelo', async () => {
  for (const [o, ped, status] of [
    [{ logada: false }, pedido(), 401],
    [{}, pedido({ credencial_id: 'x' }), 400],
    [{}, pedido({ canal: 'telegram' }), 400],
    [{}, pedido({ texto: '   ' }), 400],
    [{}, pedido({ agente: { ...AGENTE, instrucoes: 'curto' } }), 400],
    [{ conta: null }, pedido(), 404],
    [{ conta: { tenant_id: 't1', provedor: 'openai', modelo: 'm', ativo: false, config: {} } }, pedido(), 409],
    [{ conta: { tenant_id: 't1', provedor: 'google', modelo: 'm', ativo: true, config: {} } }, pedido(), 409],
  ] as const) {
    const { p, segredos } = porta(o as Parameters<typeof porta>[0]);
    const ia = new IaFalsa({ ok: true, texto: 'oi' });
    const r = await testarDoPedido(p, ped, undefined, () => ia);
    assert.equal(r.status, status, JSON.stringify(ped).slice(0, 80));
    assert.equal(ia.pedidos.length + segredos(), 0);
  }
});

test('o que não é string não vira texto no prompt (o D48 aqui)', async () => {
  const ia = new IaFalsa({ ok: true, texto: 'Oi!' });
  await testarDoPedido(porta().p, pedido({
    agente: { ...AGENTE, contexto: { malicioso: true }, proibido: ['ok', 3, null], tamanho_maximo: 99999 },
  }), undefined, () => ia);
  assert.doesNotMatch(ia.pedidos[0]!.sistema, /object Object/);
  assert.match(ia.pedidos[0]!.sistema, /nunca mais de 700\)/, 'tamanho fora da faixa é ignorado: vale o do canal');
});

test('a blacklist do cliente lê a fala antes do modelo, como no worker', async () => {
  const sai = porta({ regra: { termo: 'para de me mandar', acao: 'suprimir' } });
  const ia = new IaFalsa({ ok: true, texto: 'oi' });
  const r = await testarDoPedido(sai.p, pedido({ texto: 'para de me mandar mensagem' }), undefined, () => ia);
  assert.ok(r.corpo.ok && r.corpo.situacao === 'blacklist' && /suprime a pessoa/.test(r.corpo.motivo));
  assert.equal(ia.pedidos.length + sai.segredos(), 0, 'nem o segredo é lido');
  const recusa = await testarDoPedido(porta({ regra: { termo: 'não tenho interesse', acao: 'recusa' } }).p,
    pedido({ texto: 'não tenho interesse' }), undefined, () => new IaFalsa({ ok: true, texto: 'oi' }));
  assert.ok(recusa.corpo.ok && recusa.corpo.situacao === 'recusa');
});

test('metadados com teto: 5000 chaves enormes não viram um pedido de 5 MB', async () => {
  const ia = new IaFalsa({ ok: true, texto: 'Oi!' });
  const enorme: Record<string, string> = {};
  for (let i = 0; i < 5000; i++) enorme['k' + i] = 'v'.repeat(1000);
  await testarDoPedido(porta().p, pedido({ agente: { ...AGENTE, metadados: enorme } }), undefined, () => ia);
  assert.ok(ia.pedidos[0]!.mensagem.length < 20_000, String(ia.pedidos[0]!.mensagem.length));
});
