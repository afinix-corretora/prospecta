// Criar chip pela plataforma sem rede (D73).
//
// O incidente que este arquivo existe para não repetir: o setup por chat pediu,
// a cada render, um chip com um número que já era chip. O provedor criava a
// instância, o banco recusava a conta, e sobrava uma instância sem dono no
// painel — 56 em 35 minutos.
//
// O que importa conferir:
//
//   - número que já é chip (do cliente, arquivado, ou de outro cliente no mesmo
//     provedor) é recusado SEM nenhuma chamada ao provedor;
//   - a recusa por outro cliente não conta o apelido dele;
//   - o número digitado com máscara é perguntado e gravado normalizado (D32);
//   - quando o banco recusa depois, a instância criada é apagada na hora, com
//     o token dela — e quando não dá para apagar, a resposta diz onde ela ficou.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { provisionarDoPedido, porQueONumeroNaoServe } from '../motor/provisionamento.ts';
import type { ContaComONumero, ContaNova, PortaProvisionamento } from '../motor/provisionamento.ts';

const SERVIDOR = '11111111-1111-4111-8111-111111111111';
const MEU = 'tenant-a';
const OUTRO = 'tenant-b';

const PEDIDO = {
  server_id: SERVIDOR, apelido: 'Chip novo', identificador: '(17) 98134-7908',
  tipo_permitido: 'morna', quota_diaria: 50,
};

interface Chamada { url: string; metodo: string; headers: Headers }

function provedor(apagar = 200) {
  const chamadas: Chamada[] = [];
  const buscar = (async (url: string | URL | Request, init?: RequestInit) => {
    const c = { url: String(url), metodo: init?.method ?? 'GET', headers: new Headers(init?.headers) };
    chamadas.push(c);
    if (c.url.endsWith('/instance/init')) return Response.json({ token: 'tok-da-instancia-nova', name: 'Chip novo' });
    if (c.url.endsWith('/instance/connect')) return Response.json({ qrcode: 'data:image/png;base64,QR' });
    if (c.url.endsWith('/instance') && c.metodo === 'DELETE') return new Response('{}', { status: apagar });
    return new Response('{}', { status: 404 });
  }) as typeof fetch;
  return { buscar, chamadas };
}

function porta(contas: ContaComONumero[], o: { visivel?: boolean; recusarConta?: string } = {}) {
  const perguntados: string[][] = [];
  const gravadas: ContaNova[] = [];
  const p: PortaProvisionamento = {
    async servidorVisivel() { return o.visivel ?? true; },
    async servidor(id) { return { id, tenant_id: MEU, provedor: 'uazapi', base_url: 'https://srv.uazapi.test', ativo: true }; },
    async contasComONumero(ids) { perguntados.push([...ids]); return contas; },
    async tokenDeAdmin() { return 'admin-do-servidor'; },
    urlDoWebhook(t) { return `https://projeto.test/functions/v1/canal-webhook/${t}`; },
    async criarConta(c) {
      if (o.recusarConta) throw new Error(o.recusarConta);
      gravadas.push(c);
      return { sender_id: 'sender-novo' };
    },
  };
  return { p, perguntados, gravadas };
}

const conta = (x: Partial<ContaComONumero>): ContaComONumero => ({
  tenant_id: MEU, canal: 'whatsapp', provedor: 'uazapi', apelido: 'Chip 1 -  Prospecta',
  tipo_permitido: 'fria', removido_em: null, ...x,
});

test('número que já é chip do cliente: recusa antes do provedor, dizendo qual chip', async () => {
  const { buscar, chamadas } = provedor();
  const { p, gravadas } = porta([conta({})]);
  const r = await provisionarDoPedido(p, PEDIDO, buscar);
  assert.equal(r.status, 409);
  assert.match(r.corpo.ok ? '' : r.corpo.erro, /5517981347908 já é o chip "Chip 1 -  Prospecta" \(lista fria\)/);
  assert.equal(chamadas.length, 0, 'o provedor não pode ser chamado');
  assert.equal(gravadas.length, 0);
});

test('chip arquivado do cliente no mesmo provedor: recusa — a credencial dele ainda ocupa o nome no Vault', async () => {
  const { buscar, chamadas } = provedor();
  const { p } = porta([conta({ removido_em: '2026-10-01T00:00:00Z' })]);
  const r = await provisionarDoPedido(p, PEDIDO, buscar);
  assert.equal(r.status, 409);
  assert.match(r.corpo.ok ? '' : r.corpo.erro, /removido/);
  assert.equal(chamadas.length, 0);
});

test('chip de outro cliente no mesmo provedor: recusa sem contar o apelido dele', async () => {
  const { buscar, chamadas } = provedor();
  const { p } = porta([conta({ tenant_id: OUTRO, apelido: 'Segredo do vizinho' })]);
  const r = await provisionarDoPedido(p, PEDIDO, buscar);
  assert.equal(r.status, 409);
  assert.ok(!JSON.stringify(r).includes('Segredo do vizinho'));
  assert.equal(chamadas.length, 0);
});

test('o mesmo número noutro provedor de outro cliente não é conflito', () => {
  const alvo = { tenant_id: MEU, provedor: 'uazapi', canal: 'whatsapp', numero: '5517981347908' };
  assert.equal(porQueONumeroNaoServe([conta({ tenant_id: OUTRO, provedor: 'evolution' })], alvo), null);
  // ...mas no MESMO cliente e canal é, qualquer que seja o provedor: a unicidade é por canal.
  assert.match(porQueONumeroNaoServe([conta({ provedor: 'evolution' })], alvo) ?? '', /já é o chip/);
});

test('número livre: pergunta pelos dois jeitos de escrever, cria, e grava normalizado', async () => {
  const { buscar, chamadas } = provedor();
  const { p, perguntados, gravadas } = porta([]);
  const r = await provisionarDoPedido(p, PEDIDO, buscar);
  assert.equal(r.status, 200);
  assert.deepEqual(perguntados, [['(17) 98134-7908', '5517981347908']]);
  assert.equal(gravadas[0]!.identificador, '5517981347908');
  assert.equal(chamadas[0]!.headers.get('admintoken'), 'admin-do-servidor');
  assert.ok(r.corpo.ok && r.corpo.qrcode);
  assert.ok(!JSON.stringify(r).includes('tok-da-instancia-nova'), 'o token da instância não volta à tela');
});

test('banco recusa depois de criada: a instância é apagada na hora, com o token dela', async () => {
  const { buscar, chamadas } = provedor();
  const { p } = porta([], { recusarConta: 'duplicate key value violates unique constraint "secrets_name_idx"' });
  const r = await provisionarDoPedido(p, PEDIDO, buscar);
  assert.equal(r.status, 500);
  const apagar = chamadas.find((c) => c.metodo === 'DELETE');
  assert.ok(apagar, 'a órfã precisa ser apagada');
  assert.equal(apagar.url, 'https://srv.uazapi.test/instance');
  assert.equal(apagar.headers.get('token'), 'tok-da-instancia-nova');
  assert.match(r.corpo.ok ? '' : r.corpo.erro, /foi apagada/);
});

test('quando nem apagar dá, a resposta diz que a instância ficou no painel', async () => {
  const { buscar } = provedor(500);
  const { p } = porta([], { recusarConta: 'Vault fora do ar' });
  const r = await provisionarDoPedido(p, PEDIDO, buscar);
  assert.match(r.corpo.ok ? '' : r.corpo.erro, /ficou no painel do provedor/);
});

test('pedido ruim ou servidor fora do alcance: nada chega ao provedor', async () => {
  for (const [pedido, visivel, status] of [
    [{ ...PEDIDO, identificador: '1234' }, true, 400],
    [{ ...PEDIDO, tipo_permitido: 'morna; drop' }, true, 400],
    [{ ...PEDIDO, quota_diaria: 0 }, true, 400],
    [{ ...PEDIDO, server_id: 'x' }, true, 400],
    [PEDIDO, false, 404],
  ] as const) {
    const { buscar, chamadas } = provedor();
    const { p, perguntados } = porta([], { visivel });
    const r = await provisionarDoPedido(p, pedido, buscar);
    assert.equal(r.status, status);
    assert.equal(chamadas.length + perguntados.length, 0);
  }
});
