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
import { WhatsAppGupshupAdapter } from '../adapters/whatsapp-gupshup.ts';
import { WhatsAppUazapiAdapter } from '../adapters/whatsapp-uazapi.ts';
import { WhatsAppEvolutionAdapter } from '../adapters/whatsapp-evolution.ts';
import { WhatsAppMetaAdapter } from '../adapters/whatsapp-meta.ts';
import { SmsComteleAdapter } from '../adapters/sms-comtele.ts';
import { EmailResendAdapter } from '../adapters/email-resend.ts';
import { criarAdapter, canalTemAdapter, PROVEDORES_POR_CANAL } from '../adapters/registro.ts';
import { normalizarTelefone, telefoneValido } from '../adapters/telefone.ts';
import { emailValido, montarRemetente, normalizarEmail, separarAssunto } from '../adapters/email.ts';

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

test('evolution: mensagem recebida vira respondido, casada pelo número', () => {
  // Este teste travava o comportamento errado: `key.id` é o id da mensagem DO
  // CONTATO, não da nossa, e casar por ele nunca achava nada em `messages` —
  // a invariante 4 não valia neste canal. Agora o vínculo é pelo número (D23).
  const eventos = new WhatsAppEvolutionAdapter().normalizeWebhook({
    event: 'messages.upsert',
    data: { key: { id: 'EVO123', fromMe: false, remoteJid: '5511900000001@s.whatsapp.net' },
            messageTimestamp: 1789999999 },
  });
  assert.equal(eventos.length, 1);
  assert.equal(eventos[0].tipo, 'respondido');
  assert.equal(eventos[0].deNumero, '5511900000001');
  assert.equal(eventos[0].providerMessageId, undefined);
  assert.equal(eventos[0].ocorridoEm, new Date(1789999999_000).toISOString());
});

test('evolution: mensagem de grupo não encerra cadência', () => {
  const eventos = new WhatsAppEvolutionAdapter().normalizeWebhook({
    event: 'messages.upsert',
    data: { key: { id: 'EVO9', fromMe: false, remoteJid: '120363000000000000@g.us' } },
  });
  assert.deepEqual(eventos, []);
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
// WhatsApp oficial via Gupshup — o caminho oficial da operação
// ---------------------------------------------------------------------------

const CRED_GUP = {
  api_key: 'chave-gup',
  app_name: 'afinix-comercial',
  source: '5511990000001',
};

function pedidoGupshup(extra: Partial<PedidoEnvio> = {}): PedidoEnvio {
  return {
    messageId: 'm-gup', destino: '+55 11 90000-0001', conteudo: 'Oi Ana',
    remetente: '+55 11 99000-0001', credenciais: CRED_GUP, ...extra,
  };
}

test('gupshup envia form-urlencoded, não JSON', async () => {
  const { buscar, chamadas } = fetchFalso(200, { status: 'submitted', messageId: 'gs-1' });
  const r = await new WhatsAppGupshupAdapter(buscar).send(pedidoGupshup());

  assert.equal(r.ok, true);
  assert.equal(r.providerMessageId, 'gs-1');
  const init = chamadas[0].init!;
  assert.equal((init.headers as Record<string, string>)['Content-Type'],
               'application/x-www-form-urlencoded');
  assert.equal((init.headers as Record<string, string>).apikey, 'chave-gup');
});

test('gupshup manda destino e origem normalizados', async () => {
  const { buscar, chamadas } = fetchFalso(200, { messageId: 'gs-2' });
  await new WhatsAppGupshupAdapter(buscar).send(pedidoGupshup());

  const corpo = new URLSearchParams(String(chamadas[0].init!.body));
  assert.equal(corpo.get('destination'), '5511900000001');
  assert.equal(corpo.get('source'), '5511990000001');
  assert.equal(corpo.get('src.name'), 'afinix-comercial');
  assert.equal(JSON.parse(corpo.get('message')!).text, 'Oi Ana');
});

test('cada conta da gupshup manda pela sua app, não por uma global', async () => {
  // É o que sustenta "múltiplas contas, múltiplas APIs da Gupshup": o app vem
  // da credencial da conta, então duas contas no mesmo processo não se
  // confundem.
  const a = fetchFalso(200, { messageId: 'gs-a' });
  const b = fetchFalso(200, { messageId: 'gs-b' });
  await new WhatsAppGupshupAdapter(a.buscar).send(pedidoGupshup());
  await new WhatsAppGupshupAdapter(b.buscar).send(pedidoGupshup({
    credenciais: { ...CRED_GUP, app_name: 'afinix-retencao', source: '5511990000002' },
  }));

  assert.equal(new URLSearchParams(String(a.chamadas[0].init!.body)).get('src.name'),
               'afinix-comercial');
  assert.equal(new URLSearchParams(String(b.chamadas[0].init!.body)).get('src.name'),
               'afinix-retencao');
});

test('gupshup respeita base_url próprio', async () => {
  const { buscar, chamadas } = fetchFalso(200, { messageId: 'gs-3' });
  await new WhatsAppGupshupAdapter(buscar).send(pedidoGupshup({
    credenciais: { ...CRED_GUP, base_url: 'https://gw.interno/wa/v1' },
  }));
  assert.equal(chamadas[0].url, 'https://gw.interno/wa/v1/msg');
});

test('gupshup sem app_name é culpa do remetente, não do destino', async () => {
  const { buscar } = fetchFalso(200, {});
  const r = await new WhatsAppGupshupAdapter(buscar).send(pedidoGupshup({
    credenciais: { api_key: 'x' },
  }));
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'remetente');
});

test('gupshup: apikey inválida derruba a conta; número ruim não', async () => {
  const ad = new WhatsAppGupshupAdapter(fetchFalso(401, { message: 'Authentication Failed' }).buscar);
  assert.equal((await ad.send(pedidoGupshup())).culpa, 'remetente');

  const ad2 = new WhatsAppGupshupAdapter(
    fetchFalso(400, { message: 'Number is not a valid WhatsApp user' }).buscar);
  assert.equal((await ad2.send(pedidoGupshup())).culpa, 'destino');
});

test('gupshup: 429 é transitório, não culpa da conta', async () => {
  const ad = new WhatsAppGupshupAdapter(fetchFalso(429, { message: 'rate limited' }).buscar);
  assert.equal((await ad.send(pedidoGupshup())).culpa, 'transitorio');
});

test('gupshup: 200 sem messageId não conta como enviado', async () => {
  // Sem id do provedor não há como ligar o webhook de volta à mensagem.
  const ad = new WhatsAppGupshupAdapter(fetchFalso(200, { status: 'submitted' }).buscar);
  const r = await ad.send(pedidoGupshup());
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'transitorio');
});

test('gupshup: queda de rede é transitória', async () => {
  const ad = new WhatsAppGupshupAdapter(fetchQueExplode('ECONNRESET'));
  const r = await ad.send(pedidoGupshup());
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'transitorio');
});

test('gupshup normaliza confirmação de entrega', () => {
  const evs = new WhatsAppGupshupAdapter().normalizeWebhook({
    type: 'message-event',
    payload: { type: 'delivered', gsId: 'gs-1', ts: 1758000000000, destination: '5511900000001' },
  });
  assert.equal(evs.length, 1);
  assert.equal(evs[0].tipo, 'entregue');
  assert.equal(evs[0].providerMessageId, 'gs-1');
});

test('gupshup normaliza resposta pelo context', () => {
  const evs = new WhatsAppGupshupAdapter().normalizeWebhook({
    type: 'message',
    payload: { type: 'text', source: '5511900000001', timestamp: 1758000000,
               context: { gsId: 'gs-1' } },
  });
  assert.equal(evs.length, 1);
  assert.equal(evs[0].tipo, 'respondido');
  assert.equal(evs[0].providerMessageId, 'gs-1');
});

test('gupshup: mensagem sem context não vira resposta', () => {
  // Sem o vínculo, encerrar cadência seria encerrar a da pessoa errada.
  const evs = new WhatsAppGupshupAdapter().normalizeWebhook({
    type: 'message',
    payload: { type: 'text', source: '5511900000001' },
  });
  assert.deepEqual(evs, []);
});

test('gupshup entende epoch em segundo e em milissegundo', () => {
  const ad = new WhatsAppGupshupAdapter();
  const ms = ad.normalizeWebhook({ type:'message-event',
    payload:{ type:'sent', gsId:'a', ts: 1758000000000 } })[0].ocorridoEm;
  const seg = ad.normalizeWebhook({ type:'message',
    payload:{ type:'text', timestamp: 1758000000, context:{ gsId:'a' } } })[0].ocorridoEm;
  assert.equal(ms, seg);
});

test('gupshup ignora evento que não conhece', () => {
  const ad = new WhatsAppGupshupAdapter();
  assert.deepEqual(ad.normalizeWebhook({ type: 'user-event', payload: { type: 'opted-in' } }), []);
  assert.deepEqual(ad.normalizeWebhook({ type: 'message-event', payload: { type: 'inventado', gsId: 'x' } }), []);
  assert.deepEqual(ad.normalizeWebhook({}), []);
});

// ---------------------------------------------------------------------------
// WhatsApp não oficial via UAZAPI — o caminho frio da operação
// ---------------------------------------------------------------------------

const CRED_UAZ = { base_url: 'https://afinix.uazapi.com/', token: 'tok-instancia' };

function pedidoUazapi(extra: Partial<PedidoEnvio> = {}): PedidoEnvio {
  return {
    messageId: 'm-uaz', destino: '+55 11 90000-0001', conteudo: 'Oi Ana',
    remetente: 'chip-frio-sp', credenciais: CRED_UAZ, ...extra,
  };
}

test('uazapi envia JSON em /send/text com header token', async () => {
  const { buscar, chamadas } = fetchFalso(200, { id: 'uaz-1' });
  const r = await new WhatsAppUazapiAdapter(buscar).send(pedidoUazapi());

  assert.equal(r.ok, true);
  assert.equal(r.providerMessageId, 'uaz-1');
  assert.equal(chamadas[0].url, 'https://afinix.uazapi.com/send/text');

  const h = chamadas[0].init!.headers as Record<string, string>;
  assert.equal(h.token, 'tok-instancia');
  // adminToken dá poder administrativo; enviar não precisa dele.
  assert.equal(h.adminToken, undefined);

  const corpo = JSON.parse(String(chamadas[0].init!.body));
  assert.equal(corpo.number, '5511900000001');
  assert.equal(corpo.text, 'Oi Ana');
});

test('uazapi aceita as grafias de id que a API já usou', async () => {
  // Tolerância deliberada: sem id não há como casar o webhook de volta.
  for (const corpo of [{ id: 'x' }, { messageid: 'x' }, { messageId: 'x' },
                       { key: { id: 'x' } }, { message: { id: 'x' } }]) {
    const { buscar } = fetchFalso(200, corpo);
    const r = await new WhatsAppUazapiAdapter(buscar).send(pedidoUazapi());
    assert.equal(r.providerMessageId, 'x', JSON.stringify(corpo));
  }
});

test('uazapi: 200 sem id nenhum não conta como enviado', async () => {
  const { buscar } = fetchFalso(200, { status: 'ok' });
  const r = await new WhatsAppUazapiAdapter(buscar).send(pedidoUazapi());
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'transitorio');
});

test('uazapi: token e instância caída derrubam a conta; número ruim não', async () => {
  const token = new WhatsAppUazapiAdapter(fetchFalso(401, { error: 'invalid token' }).buscar);
  assert.equal((await token.send(pedidoUazapi())).culpa, 'remetente');

  const caida = new WhatsAppUazapiAdapter(
    fetchFalso(500, { error: 'instance not connected' }).buscar);
  assert.equal((await caida.send(pedidoUazapi())).culpa, 'remetente');

  const numero = new WhatsAppUazapiAdapter(
    fetchFalso(400, { error: 'number does not exist on WhatsApp' }).buscar);
  assert.equal((await numero.send(pedidoUazapi())).culpa, 'destino');
});

test('uazapi sem base_url é culpa do remetente', async () => {
  const { buscar } = fetchFalso(200, {});
  const r = await new WhatsAppUazapiAdapter(buscar).send(
    pedidoUazapi({ credenciais: { token: 'x' } }));
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'remetente');
});

test('uazapi: queda de rede é transitória', async () => {
  const r = await new WhatsAppUazapiAdapter(fetchQueExplode('ETIMEDOUT')).send(pedidoUazapi());
  assert.equal(r.culpa, 'transitorio');
});

test('uazapi normaliza mudança de status da nossa mensagem', () => {
  const evs = new WhatsAppUazapiAdapter().normalizeWebhook({
    event: 'messages_update',
    message: { id: 'uaz-1', status: 'DELIVERED', messageTimestamp: 1758000000 },
  });
  assert.equal(evs.length, 1);
  assert.equal(evs[0].tipo, 'entregue');
  assert.equal(evs[0].providerMessageId, 'uaz-1');
});

test('uazapi liga a resposta pela citação da nossa mensagem', () => {
  const evs = new WhatsAppUazapiAdapter().normalizeWebhook({
    event: 'messages',
    message: { id: 'dele-9', fromMe: false, messageType: 'conversation',
               sender: '5511900000001@s.whatsapp.net',
               quoted: { id: 'uaz-1' }, messageTimestamp: 1758000000 },
  });
  assert.equal(evs.length, 1);
  assert.equal(evs[0].tipo, 'respondido');
  // O id é o da NOSSA mensagem citada, não o da mensagem dele.
  assert.equal(evs[0].providerMessageId, 'uaz-1');
});

test('uazapi: resposta sem citação casa pelo número, não por id inventado', () => {
  // É o caso comum nas não oficiais. O id do payload é o da mensagem DELE e
  // não existe em `messages`; quem resolve é o banco, pelo número e pelo chip
  // que recebeu o webhook (D23).
  const evs = new WhatsAppUazapiAdapter().normalizeWebhook({
    event: 'messages',
    message: { id: 'dele-9', fromMe: false, sender: '5511900000001@s.whatsapp.net' },
  });
  assert.equal(evs.length, 1);
  assert.equal(evs[0].tipo, 'respondido');
  assert.equal(evs[0].deNumero, '5511900000001');
  assert.equal(evs[0].providerMessageId, undefined);
});

test('uazapi: mensagem de grupo não é resposta de cadência', () => {
  // O motor nunca mandou para um grupo, então nada ali pode encerrar um
  // enrollment.
  const evs = new WhatsAppUazapiAdapter().normalizeWebhook({
    event: 'messages',
    message: { id: 'g-1', fromMe: false, sender: '120363000000000000@g.us' },
  });
  assert.deepEqual(evs, []);
});

test('uazapi: citação ganha do número quando as duas existem', () => {
  // Casar por id é mais preciso: aponta a mensagem exata.
  const evs = new WhatsAppUazapiAdapter().normalizeWebhook({
    event: 'messages',
    message: { id: 'dele-9', fromMe: false, sender: '5511900000001@s.whatsapp.net',
               quoted: { id: 'uaz-1' } },
  });
  assert.equal(evs[0].providerMessageId, 'uaz-1');
  assert.equal(evs[0].deNumero, undefined);
});

test('uazapi provisiona instância e devolve token e QR', async () => {
  const chamadas: { url: string; init?: RequestInit }[] = [];
  const buscar = (async (url: unknown, init?: RequestInit) => {
    chamadas.push({ url: String(url), init });
    const corpo = String(url).endsWith('/instance/init')
      ? { token: 'tok-nova', name: 'chip-02' }
      : { instance: { qrcode: 'data:image/png;base64,AAA' } };
    return new Response(JSON.stringify(corpo), { status: 200 });
  }) as unknown as Buscador;

  const r = await new WhatsAppUazapiAdapter(buscar).provisionar!({
    baseUrl: 'https://afinix.uazapi.com/',
    adminToken: 'admin-secreto',
    nome: 'chip-02',
    webhookUrl: 'https://proj.functions.supabase.co/canal-webhook/tok-abc',
  });

  assert.equal(r.ok, true);
  assert.equal(r.instancia, 'chip-02');
  assert.equal(r.credenciais!.token, 'tok-nova');
  assert.equal(r.credenciais!.base_url, 'https://afinix.uazapi.com');
  assert.equal(r.qrcode, 'data:image/png;base64,AAA');

  // Criar usa admintoken; conectar usa o token da instância recém-criada.
  assert.equal(chamadas[0].url, 'https://afinix.uazapi.com/instance/init');
  assert.equal((chamadas[0].init!.headers as Record<string,string>).admintoken, 'admin-secreto');
  assert.equal(JSON.parse(String(chamadas[0].init!.body)).webhook,
               'https://proj.functions.supabase.co/canal-webhook/tok-abc');
  assert.equal(chamadas[1].url, 'https://afinix.uazapi.com/instance/connect');
  assert.equal((chamadas[1].init!.headers as Record<string,string>).token, 'tok-nova');
});

test('uazapi: instância criada sem token é falha, não sucesso pela metade', async () => {
  const { buscar } = fetchFalso(200, { name: 'chip-03' });
  const r = await new WhatsAppUazapiAdapter(buscar).provisionar!({
    baseUrl: 'https://afinix.uazapi.com', adminToken: 'a', nome: 'chip-03',
  });
  assert.equal(r.ok, false);
  assert.match(r.erro!, /sem token/);
});

test('uazapi: QR que falha não derruba a instância criada', async () => {
  // A instância existe no provedor; pedir o QR de novo é barato, recriar não.
  let n = 0;
  const buscar = (async (url: unknown) => {
    n += 1;
    if (String(url).endsWith('/instance/connect')) throw new Error('timeout no QR');
    return new Response(JSON.stringify({ token: 'tok-nova' }), { status: 200 });
  }) as unknown as Buscador;

  const r = await new WhatsAppUazapiAdapter(buscar).provisionar!({
    baseUrl: 'https://afinix.uazapi.com', adminToken: 'a', nome: 'chip-04',
  });
  assert.equal(r.ok, true);
  assert.equal(r.credenciais!.token, 'tok-nova');
  assert.equal(r.qrcode, undefined);
  assert.equal(n, 2);
});

test('só quem hospeda instância sabe provisionar', () => {
  // A Meta e a Gupshup não criam número — quem cria é a operadora.
  assert.equal(typeof new WhatsAppUazapiAdapter().provisionar, 'function');
  assert.equal(new WhatsAppGupshupAdapter().provisionar, undefined);
  assert.equal(new WhatsAppMetaAdapter().provisionar, undefined);
});

test('uazapi descarta o próprio eco', () => {
  // Encerraria o enrollment no próprio disparo (invariante 4 ao contrário).
  const ad = new WhatsAppUazapiAdapter();
  assert.deepEqual(ad.normalizeWebhook({
    event: 'messages', message: { id: 'a', fromMe: true, quoted: { id: 'uaz-1' } } }), []);
  assert.deepEqual(ad.normalizeWebhook({
    event: 'messages', message: { id: 'a', wasSentByApi: true, quoted: { id: 'uaz-1' } } }), []);
});

test('uazapi aceita lote de eventos num POST só', () => {
  const evs = new WhatsAppUazapiAdapter().normalizeWebhook({
    event: 'messages_update',
    data: [{ id: 'a', status: 'sent' }, { id: 'b', status: 'read' }, { id: 'c' }],
  });
  assert.equal(evs.length, 2);
  assert.deepEqual(evs.map(e => e.tipo), ['enviado', 'lido']);
});

test('uazapi entende epoch em segundo e em milissegundo', () => {
  const ad = new WhatsAppUazapiAdapter();
  const seg = ad.normalizeWebhook({ event:'messages_update',
    data:{ id:'a', status:'read', messageTimestamp: 1758000000 } })[0].ocorridoEm;
  const ms = ad.normalizeWebhook({ event:'messages_update',
    data:{ id:'a', status:'read', messageTimestamp: 1758000000000 } })[0].ocorridoEm;
  assert.equal(seg, ms);
});

test('uazapi ignora o que não conhece', () => {
  const ad = new WhatsAppUazapiAdapter();
  assert.deepEqual(ad.normalizeWebhook({}), []);
  assert.deepEqual(ad.normalizeWebhook({ event: 'connection', data: { state: 'open' } }), []);
  assert.deepEqual(ad.normalizeWebhook({ event: 'messages_update', data: { status: 'read' } }), []);
});

test('uazapi checkHealth bate em /instance/status', async () => {
  const { buscar, chamadas } = fetchFalso(200, { connected: true });
  const s = await new WhatsAppUazapiAdapter(buscar).checkHealth(CRED_UAZ);
  assert.equal(s.ok, true);
  assert.equal(chamadas[0].url, 'https://afinix.uazapi.com/instance/status');
});

// ---------------------------------------------------------------------------
// E-mail — endereço, assunto e o adapter HTTP
// ---------------------------------------------------------------------------

test('normaliza endereço com nome de exibição', () => {
  assert.equal(normalizarEmail('Ana Castro <Ana.Castro@Exemplo.com.BR>'), 'ana.castro@exemplo.com.br');
});

test('endereço sem domínio com ponto não é endereço', () => {
  assert.equal(emailValido('ana@localhost'), false);
  assert.equal(emailValido('ana@exemplo.com.br'), true);
});

test('lista disfarçada de endereço é recusada', () => {
  // Vírgula e ponto-e-vírgula viram vários destinatários no provedor. Um
  // `destino` com vírgula é contato mal ingerido, não um envio para dois.
  assert.equal(emailValido('a@x.com,b@y.com'), false);
  assert.equal(emailValido('a@x.com; b@y.com'), false);
});

test('remetente leva nome de exibição quando há um', () => {
  assert.equal(montarRemetente('ana@x.com.br', 'Ana da Afinix'), 'Ana da Afinix <ana@x.com.br>');
  assert.equal(montarRemetente('ana@x.com.br'), 'ana@x.com.br');
});

test('nome de exibição não injeta cabeçalho', () => {
  assert.equal(montarRemetente('ana@x.com.br', 'Ana" <spam@mal.com>'), 'Ana spam@mal.com <ana@x.com.br>');
});

test('assunto sai da primeira linha marcada', () => {
  const r = separarAssunto('Assunto: Comparativo do plano\n\nAna, segue o que combinamos.', 'padrão');
  assert.equal(r.assunto, 'Comparativo do plano');
  assert.equal(r.corpo, 'Ana, segue o que combinamos.');
});

test('parágrafo curto de abertura não vira assunto sem marcador', () => {
  const r = separarAssunto('Ana, tudo bem?\n\nQueria te mostrar duas opções.', 'Plano de saúde');
  assert.equal(r.assunto, 'Plano de saúde');
  assert.equal(r.corpo, 'Ana, tudo bem?\n\nQueria te mostrar duas opções.');
});

test('marcador sem corpo não consome a única linha do template', () => {
  const r = separarAssunto('Assunto: só isso', 'Plano de saúde');
  assert.equal(r.assunto, 'Plano de saúde');
  assert.equal(r.corpo, 'Assunto: só isso');
});

const CRED_RESEND = {
  api_key: 're_123',
  assunto_padrao: 'Plano de saúde da sua empresa',
  nome_remetente: 'Ana da Afinix',
  responder_para: 'respostas@inbound.afinix.com.br',
};

const PEDIDO_EMAIL: PedidoEnvio = {
  messageId: 'aa000000-0000-0000-0000-000000000001',
  destino: 'Ana Castro <ANA@exemplo.com.br>',
  conteudo: 'Assunto: Comparativo\n\nAna, segue o comparativo.',
  remetente: 'comercial@frio.afinix.com.br',
  credenciais: CRED_RESEND,
};

test('resend: envia no formato da API, com assunto do próprio passo', async () => {
  const { buscar, chamadas } = fetchFalso(200, { id: 'em-1' });
  const r = await new EmailResendAdapter(buscar).send(PEDIDO_EMAIL);

  assert.equal(r.ok, true);
  assert.equal(r.providerMessageId, 'em-1');
  assert.equal(chamadas[0].url, 'https://api.resend.com/emails');

  const cab = chamadas[0].init!.headers as Record<string, string>;
  assert.equal(cab.Authorization, 'Bearer re_123');

  assert.deepEqual(JSON.parse(String(chamadas[0].init!.body)), {
    from: 'Ana da Afinix <comercial@frio.afinix.com.br>',
    to: ['ana@exemplo.com.br'],
    subject: 'Comparativo',
    text: 'Ana, segue o comparativo.',
    reply_to: 'respostas@inbound.afinix.com.br',
  });
});

test('resend: a invariante 1 atravessa a rede pela Idempotency-Key', () => {
  // O lease pode expirar e a mesma mensagem ser reivindicada de novo. A chave
  // única no banco não alcança o provedor; esta chave alcança.
  const { buscar, chamadas } = fetchFalso(200, { id: 'em-1' });
  return new EmailResendAdapter(buscar).send(PEDIDO_EMAIL).then(() => {
    const cab = chamadas[0].init!.headers as Record<string, string>;
    assert.equal(cab['Idempotency-Key'], PEDIDO_EMAIL.messageId);
  });
});

test('resend: sem assunto no passo, vale o assunto padrão da conta', async () => {
  const { buscar, chamadas } = fetchFalso(200, { id: 'em-2' });
  await new EmailResendAdapter(buscar).send({ ...PEDIDO_EMAIL, conteudo: 'Ana, tudo bem?' });

  const corpo = JSON.parse(String(chamadas[0].init!.body));
  assert.equal(corpo.subject, 'Plano de saúde da sua empresa');
  assert.equal(corpo.text, 'Ana, tudo bem?');
});

test('resend: conta sem assunto padrão é culpa do remetente, não do contato', async () => {
  // 'destino' invalidaria `contact_identities` e escreveria identidade_invalida
  // no CRM por um erro de configuração da conta.
  const { buscar } = fetchFalso(200, { id: 'em-3' });
  const r = await new EmailResendAdapter(buscar).send({
    ...PEDIDO_EMAIL,
    conteudo: 'Ana, tudo bem?',
    credenciais: { api_key: 're_123' },
  });

  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'remetente');
  assert.match(r.erro!, /assunto_padrao/);
});

test('resend: sem responder_para o campo não vai vazio', async () => {
  const { buscar, chamadas } = fetchFalso(200, { id: 'em-4' });
  await new EmailResendAdapter(buscar).send({
    ...PEDIDO_EMAIL,
    credenciais: { api_key: 're_123', assunto_padrao: 'Oi' },
  });

  assert.equal('reply_to' in JSON.parse(String(chamadas[0].init!.body)), false);
});

test('resend: endereço inválido é culpa do destino e nem chega a sair', async () => {
  const { buscar, chamadas } = fetchFalso(200, { id: 'nao-deveria' });
  const r = await new EmailResendAdapter(buscar).send({ ...PEDIDO_EMAIL, destino: 'ana@' });

  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'destino');
  assert.equal(chamadas.length, 0);
});

test('resend: 422 do provedor não invalida o e-mail do contato', async () => {
  // Domínio não verificado e chave sem permissão chegam como 4xx. Quem diz que
  // um endereço morreu é o `email.bounced`, não o retorno do POST.
  const { buscar } = fetchFalso(422, { name: 'validation_error', message: 'domínio não verificado' });
  const r = await new EmailResendAdapter(buscar).send(PEDIDO_EMAIL);

  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'remetente');
  assert.equal(r.erro, 'domínio não verificado');
});

test('resend: 429 e 5xx são transitórios, não derrubam a conta', async () => {
  for (const status of [429, 500, 503]) {
    const { buscar } = fetchFalso(status, { message: 'tente de novo' });
    const r = await new EmailResendAdapter(buscar).send(PEDIDO_EMAIL);
    assert.equal(r.culpa, 'transitorio', `status ${status}`);
  }
});

test('resend: 200 sem id é falha, não sucesso mudo', async () => {
  const { buscar } = fetchFalso(200, {});
  const r = await new EmailResendAdapter(buscar).send(PEDIDO_EMAIL);
  assert.equal(r.ok, false);
});

test('resend: rede caída é transitória', async () => {
  const r = await new EmailResendAdapter(fetchQueExplode('ECONNRESET')).send(PEDIDO_EMAIL);
  assert.equal(r.ok, false);
  assert.equal(r.culpa, 'transitorio');
});

test('resend: evento de entrega casa pelo id da mensagem', () => {
  const eventos = new EmailResendAdapter().normalizeWebhook({
    type: 'email.delivered',
    created_at: '2026-09-21T12:00:00.000Z',
    data: { email_id: 'em-1', to: ['ana@exemplo.com.br'] },
  });

  assert.equal(eventos.length, 1);
  assert.equal(eventos[0].providerMessageId, 'em-1');
  assert.equal(eventos[0].tipo, 'entregue');
  assert.equal(eventos[0].ocorridoEm, '2026-09-21T12:00:00.000Z');
});

test('resend: clique é engajamento, não resposta (D7)', () => {
  const [e] = new EmailResendAdapter().normalizeWebhook({
    type: 'email.clicked', created_at: '2026-09-21T12:00:00.000Z',
    data: { email_id: 'em-1' },
  });
  assert.equal(e.tipo, 'clique');
});

test('resend: bounce e denúncia de spam viram rejeitado', () => {
  for (const t of ['email.bounced', 'email.complained']) {
    const [e] = new EmailResendAdapter().normalizeWebhook({
      type: t, created_at: '2026-09-21T12:00:00.000Z', data: { email_id: 'em-1' },
    });
    assert.equal(e.tipo, 'rejeitado', t);
  }
});

test('resend: resposta casa pelo endereço, nunca pelo id do e-mail recebido', () => {
  // `data.email_id` no email.received é o id da mensagem DELA, que não existe
  // em `messages`. Emitir providerMessageId aqui gravaria evento que nunca casa.
  const [e] = new EmailResendAdapter().normalizeWebhook({
    type: 'email.received',
    created_at: '2026-09-21T12:05:00.000Z',
    data: { email_id: 'in-9', from: 'Ana Castro <ANA@exemplo.com.br>', subject: 'Re: Comparativo' },
  });

  assert.equal(e.providerMessageId, undefined);
  assert.equal(e.deNumero, 'ana@exemplo.com.br');
  assert.equal(e.tipo, 'respondido');
});

test('resend: evento sem tipo conhecido não vira evento vizinho', () => {
  // delivery_delayed ainda pode entregar; virar 'falha' estragaria o status
  // derivado de uma mensagem que está viva.
  const a = new EmailResendAdapter();
  assert.deepEqual(a.normalizeWebhook({ type: 'email.delivery_delayed', data: { email_id: 'em-1' } }), []);
  assert.deepEqual(a.normalizeWebhook({ type: 'email.scheduled', data: { email_id: 'em-1' } }), []);
  assert.deepEqual(a.normalizeWebhook({ nada: true }), []);
});

test('resend: evento sem id de mensagem é descartado', () => {
  assert.deepEqual(new EmailResendAdapter().normalizeWebhook({ type: 'email.delivered', data: {} }), []);
});

test('resend: saúde é a chave respondendo, não um ping qualquer', async () => {
  const { buscar, chamadas } = fetchFalso(200, { data: [] });
  const s = await new EmailResendAdapter(buscar).checkHealth({ api_key: 're_123' });

  assert.equal(s.ok, true);
  assert.equal(chamadas[0].url, 'https://api.resend.com/domains');
});

test('resend: chave recusada é saúde ruim', async () => {
  const { buscar } = fetchFalso(401, { name: 'missing_api_key' });
  assert.equal((await new EmailResendAdapter(buscar).checkHealth({ api_key: 'x' })).ok, false);
});

// ---------------------------------------------------------------------------
// Registro
// ---------------------------------------------------------------------------

test('registro devolve o adapter de cada provedor', () => {
  assert.equal(criarAdapter('evolution').provedor, 'evolution');
  assert.equal(criarAdapter('meta_cloud').canal, 'whatsapp');
  assert.equal(criarAdapter('comtele').canal, 'sms');
  assert.equal(criarAdapter('resend').canal, 'email');
});

test('provedor sem adapter falha alto, não silencioso', () => {
  assert.throws(() => criarAdapter('zapi'), /provedor sem adapter/);
});

test('canais sem adapter são declarados, não descobertos em produção', () => {
  assert.equal(canalTemAdapter('whatsapp'), true);
  assert.equal(canalTemAdapter('sms'), true);
  assert.equal(canalTemAdapter('email'), true);
  assert.equal(canalTemAdapter('instagram'), false);
});

test('smtp está no catálogo e fora do registro, de propósito (D30)', () => {
  assert.equal(PROVEDORES_POR_CANAL.email.includes('smtp' as never), false);
  assert.throws(() => criarAdapter('smtp'), /provedor sem adapter/);
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
