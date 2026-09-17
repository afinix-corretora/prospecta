// Testes dos adapters de canal.
//
// Roda com: node --experimental-strip-types --test tests/adapters.test.ts
//
// `fetch` é injetado, então nenhum teste toca a rede. Os corpos de resposta e
// de webhook são as formas reais dos provedores, tiradas do código legado
// (send-evolution-message, meta-send-via-bsp, comtele-send-sms) durante o
// inventário da Fase 0.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import type { Buscador, PedidoEnvio } from '../adapters/tipos.ts';
import { WhatsAppEvolutionAdapter } from '../adapters/whatsapp-evolution.ts';
import { WhatsAppMetaAdapter } from '../adapters/whatsapp-meta.ts';
import { SmsComteleAdapter } from '../adapters/sms-comtele.ts';
import { criarAdapter, canalTemAdapter, PROVEDORES_POR_CANAL } from '../adapters/registro.ts';
import { normalizarTelefone, telefoneValido } from '../adapters/telefone.ts';

/** fetch falso que grava a chamada e devolve o que o teste mandar. */
function fetchFalso(status: number, corpo: unknown) {
  const chamadas: { url: string; init?: RequestInit }[] = [];
  const buscar = (async (url: unknown, init?: RequestInit) => {
    chamadas.push({ url: String(url), init });
    return new Response(JSON.stringify(corpo), {
      status,
      headers: { 'Content-Type': 'application/json' },
    });
  }) as unknown as Buscador;
  return { buscar, chamadas };
}

function fetchQueExplode(erro: string) {
  return (async () => { throw new Error(erro); }) as unknown as Buscador;
}

const PEDIDO: PedidoEnvio = {
  messageId: 'm-1',
  destino: '+55 11 90000-0001',
  conteudo: 'Oi Ana',
  remetente: 'instancia-a',
  credenciais: { api_url: 'https://evo.exemplo.com/', api_key: 'chave' },
};

// ---------------------------------------------------------------------------
// Telefone
// ---------------------------------------------------------------------------

test('normaliza celular nacional com DDI', () => {
  assert.equal(normalizarTelefone('(11) 90000-0001'), '5511900000001');
});

test('normaliza fixo nacional com DDI', () => {
  assert.equal(normalizarTelefone('11 3000-0001'), '551130000001');
});

test('número que já tem DDI não ganha outro', () => {
  assert.equal(normalizarTelefone('+55 11 90000-0001'), '5511900000001');
});

test('entrada sem dígitos vira vazio', () => {
  assert.equal(normalizarTelefone('sem numero'), '');
  assert.equal(telefoneValido('sem numero'), false);
});

test('a mesma entrada em formatos diferentes normaliza igual', () => {
  // É disto que dependem o dedup de identidade e a supressão.
  const formas = ['+55 (11) 90000-0001', '5511900000001', '55 11 900000001', '(11) 900000001'];
  const normalizadas = new Set(formas.map(normalizarTelefone));
  assert.equal(normalizadas.size, 1, [...normalizadas].join(' | '));
});

// ---------------------------------------------------------------------------
// Evolution
// ---------------------------------------------------------------------------

test('evolution: envia no endpoint e formato que o provedor espera', async () => {
  const { buscar, chamadas } = fetchFalso(200, { key: { id: 'EVO123' } });
  const r = await new WhatsAppEvolutionAdapter(buscar).send(PEDIDO);

  assert.equal(r.ok, true);
  assert.equal(r.providerMessageId, 'EVO123');
  assert.equal(chamadas.length, 1);
  assert.equal(chamadas[0].url, 'https://evo.exemplo.com/message/sendText/instancia-a');

  const headers = chamadas[0].init!.headers as Record<string, string>;
  assert.equal(headers.apikey, 'chave');

  const corpo = JSON.parse(String(chamadas[0].init!.body));
  assert.deepEqual(corpo, { number: '5511900000001', text: 'Oi Ana' });
});

test('evolution: 401 culpa o remetente, para o circuito poder abrir', async () => {
  const { buscar } = fetchFalso(401, { message: 'unauthorized' });
  const r = await new WhatsAppEvolutionAdapter(buscar).send(PEDIDO);
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'remetente');
  assert.equal(r.erro, 'unauthorized');
});

test('evolution: 400 culpa o destino, não a conta', async () => {
  const { buscar } = fetchFalso(400, { message: 'number does not exist' });
  const r = await new WhatsAppEvolutionAdapter(buscar).send(PEDIDO);
  assert.equal(r.culpa, 'destino');
});

test('evolution: 500 é transitório', async () => {
  const { buscar } = fetchFalso(500, {});
  const r = await new WhatsAppEvolutionAdapter(buscar).send(PEDIDO);
  assert.equal(r.culpa, 'transitorio');
  assert.equal(r.erro, 'HTTP 500');
});

test('evolution: queda de rede é transitória, não queima a conta', async () => {
  const r = await new WhatsAppEvolutionAdapter(fetchQueExplode('ECONNRESET')).send(PEDIDO);
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'transitorio');
});

test('evolution: credencial ausente culpa o remetente e não chama a rede', async () => {
  const { buscar, chamadas } = fetchFalso(200, {});
  const r = await new WhatsAppEvolutionAdapter(buscar)
    .send({ ...PEDIDO, credenciais: { api_url: 'https://x' } });
  assert.equal(r.culpa, 'remetente');
  assert.match(r.erro!, /api_key/);
  assert.equal(chamadas.length, 0);
});

test('evolution: mensagem recebida vira respondido', () => {
  const eventos = new WhatsAppEvolutionAdapter().normalizeWebhook({
    event: 'messages.upsert',
    data: { key: { id: 'EVO123', fromMe: false, remoteJid: '5511900000001@s.whatsapp.net' },
            messageTimestamp: 1789999999 },
  });
  assert.equal(eventos.length, 1);
  assert.equal(eventos[0].tipo, 'respondido');
  assert.equal(eventos[0].providerMessageId, 'EVO123');
  assert.equal(eventos[0].ocorridoEm, new Date(1789999999_000).toISOString());
});

test('evolution: o próprio eco (fromMe) é descartado', () => {
  // Sem isto, o motor encerraria o enrollment no instante do próprio disparo.
  const eventos = new WhatsAppEvolutionAdapter().normalizeWebhook({
    event: 'messages.upsert',
    data: { key: { id: 'EVO123', fromMe: true }, messageTimestamp: 1789999999 },
  });
  assert.deepEqual(eventos, []);
});

test('evolution: status de entrega vira evento de entrega', () => {
  const eventos = new WhatsAppEvolutionAdapter().normalizeWebhook({
    event: 'messages.update',
    data: [{ keyId: 'EVO123', status: 'DELIVERY_ACK', messageTimestamp: 1789999999 }],
  });
  assert.equal(eventos.length, 1);
  assert.equal(eventos[0].tipo, 'entregue');
});

test('evolution: webhook desconhecido não vira evento', () => {
  const a = new WhatsAppEvolutionAdapter();
  assert.deepEqual(a.normalizeWebhook({ event: 'presence.update', data: {} }), []);
  assert.deepEqual(a.normalizeWebhook({}), []);
  assert.deepEqual(a.normalizeWebhook(null), []);
});

// ---------------------------------------------------------------------------
// Meta Cloud
// ---------------------------------------------------------------------------

const PEDIDO_META: PedidoEnvio = {
  ...PEDIDO,
  remetente: '109876543210',
  credenciais: { access_token: 'tok', api_version: 'v21.0' },
};

test('meta: envia no formato da Cloud API', async () => {
  const { buscar, chamadas } = fetchFalso(200, { messages: [{ id: 'wamid.ABC' }] });
  const r = await new WhatsAppMetaAdapter(buscar).send(PEDIDO_META);

  assert.equal(r.ok, true);
  assert.equal(r.providerMessageId, 'wamid.ABC');
  assert.equal(chamadas[0].url, 'https://graph.facebook.com/v21.0/109876543210/messages');

  const corpo = JSON.parse(String(chamadas[0].init!.body));
  assert.deepEqual(corpo, {
    messaging_product: 'whatsapp',
    to: '5511900000001',
    type: 'text',
    text: { body: 'Oi Ana' },
  });
});

test('meta: versão da API vem da credencial, não hardcoded', async () => {
  // No legado, whatsapp-sender fixava v18.0 e meta-send-via-bsp era
  // configurável — divergentes entre si.
  const { buscar, chamadas } = fetchFalso(200, { messages: [{ id: 'x' }] });
  await new WhatsAppMetaAdapter(buscar).send({
    ...PEDIDO_META,
    credenciais: { access_token: 'tok', api_version: 'v22.0' },
  });
  assert.match(chamadas[0].url, /\/v22\.0\//);
});

test('meta: token expirado (código 190) culpa o remetente', async () => {
  const { buscar } = fetchFalso(401, { error: { message: 'Session expired', code: 190 } });
  const r = await new WhatsAppMetaAdapter(buscar).send(PEDIDO_META);
  assert.equal(r.culpa, 'remetente');
  assert.equal(r.erro, 'Session expired');
});

test('meta: conta restrita (133x) culpa o remetente', async () => {
  const { buscar } = fetchFalso(400, { error: { message: 'account restricted', code: 1331 } });
  const r = await new WhatsAppMetaAdapter(buscar).send(PEDIDO_META);
  assert.equal(r.culpa, 'remetente');
});

test('meta: destino sem WhatsApp (131026) culpa o destino', async () => {
  const { buscar } = fetchFalso(400, { error: { message: 'not a WhatsApp user', code: 131026 } });
  const r = await new WhatsAppMetaAdapter(buscar).send(PEDIDO_META);
  assert.equal(r.culpa, 'destino');
});

test('meta: status de entrega vira evento', () => {
  const eventos = new WhatsAppMetaAdapter().normalizeWebhook({
    entry: [{ changes: [{ value: { statuses: [
      { id: 'wamid.ABC', status: 'delivered', timestamp: '1789999999' },
      { id: 'wamid.DEF', status: 'read', timestamp: '1789999999' },
    ] } }] }],
  });
  assert.deepEqual(eventos.map((e) => e.tipo), ['entregue', 'lido']);
});

test('meta: resposta é ligada à nossa mensagem pelo context.id', () => {
  const eventos = new WhatsAppMetaAdapter().normalizeWebhook({
    entry: [{ changes: [{ value: { messages: [
      { from: '5511900000001', timestamp: '1789999999', type: 'text',
        context: { id: 'wamid.ABC' } },
    ] } }] }],
  });
  assert.equal(eventos.length, 1);
  assert.equal(eventos[0].tipo, 'respondido');
  assert.equal(eventos[0].providerMessageId, 'wamid.ABC');
});

test('meta: mensagem sem context não vira resposta de enrollment nenhum', () => {
  // Sem context não dá para saber a que disparo ela responde. Inventar um
  // vínculo encerraria o enrollment errado.
  const eventos = new WhatsAppMetaAdapter().normalizeWebhook({
    entry: [{ changes: [{ value: { messages: [
      { from: '5511900000001', timestamp: '1789999999', type: 'text' },
    ] } }] }],
  });
  assert.deepEqual(eventos, []);
});

test('meta: status desconhecido é ignorado', () => {
  const eventos = new WhatsAppMetaAdapter().normalizeWebhook({
    entry: [{ changes: [{ value: { statuses: [{ id: 'x', status: 'inventado' }] } }] }],
  });
  assert.deepEqual(eventos, []);
});

// ---------------------------------------------------------------------------
// Comtele
// ---------------------------------------------------------------------------

const PEDIDO_SMS: PedidoEnvio = {
  ...PEDIDO,
  remetente: 'AFINIX',
  credenciais: { auth_key: 'ak' },
};

test('comtele: envia no formato da API v2', async () => {
  const { buscar, chamadas } = fetchFalso(200, { Success: true, Object: 42 });
  const r = await new SmsComteleAdapter(buscar).send(PEDIDO_SMS);

  assert.equal(r.ok, true);
  assert.equal(r.providerMessageId, '42');
  assert.equal(chamadas[0].url, 'https://sms.comtele.com.br/api/v2/send');
  assert.equal((chamadas[0].init!.headers as Record<string, string>)['auth-key'], 'ak');

  assert.deepEqual(JSON.parse(String(chamadas[0].init!.body)), {
    Sender: 'AFINIX', Receivers: '5511900000001', Content: 'Oi Ana',
  });
});

test('comtele: Success false é falha mesmo com HTTP 200', async () => {
  const { buscar } = fetchFalso(200, { Success: false, Message: 'saldo insuficiente' });
  const r = await new SmsComteleAdapter(buscar).send(PEDIDO_SMS);
  assert.equal(r.ok, false);
  assert.equal(r.erro, 'saldo insuficiente');
});

test('comtele: sem webhook de entrega, nenhum evento é inventado', () => {
  assert.deepEqual(new SmsComteleAdapter().normalizeWebhook({ qualquer: 'coisa' }), []);
});

// ---------------------------------------------------------------------------
// Registro
// ---------------------------------------------------------------------------

test('registro devolve o adapter de cada provedor', () => {
  assert.equal(criarAdapter('evolution').provedor, 'evolution');
  assert.equal(criarAdapter('meta_cloud').canal, 'whatsapp');
  assert.equal(criarAdapter('comtele').canal, 'sms');
});

test('provedor sem adapter falha alto, não silencioso', () => {
  assert.throws(() => criarAdapter('uazapi'), /provedor sem adapter/);
});

test('canais sem adapter são declarados, não descobertos em produção', () => {
  assert.equal(canalTemAdapter('whatsapp'), true);
  assert.equal(canalTemAdapter('sms'), true);
  assert.equal(canalTemAdapter('email'), false);
  assert.equal(canalTemAdapter('instagram'), false);
});

test('todo provedor listado no registro tem adapter construível', () => {
  for (const provedores of Object.values(PROVEDORES_POR_CANAL)) {
    for (const p of provedores) {
      assert.doesNotThrow(() => criarAdapter(p), `provedor ${p}`);
    }
  }
});

test('adapter declara o canal que o registro promete', () => {
  for (const [canal, provedores] of Object.entries(PROVEDORES_POR_CANAL)) {
    for (const p of provedores) {
      assert.equal(criarAdapter(p).canal, canal);
    }
  }
});
