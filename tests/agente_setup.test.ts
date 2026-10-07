// O agente do Setup rápido sem rede (D72).
//
// O que importa conferir:
//
//   - o que o modelo devolve fora do vocabulário some antes de voltar à tela;
//   - chave colada na conversa não sai para a OpenAI, nem pela mensagem nem
//     pelo histórico — e a pessoa é levada ao lugar da chave;
//   - a chave da plataforma vira cabeçalho e não aparece em resposta nenhuma;
//   - o modelo é escolhido do que a chave alcança, barato primeiro, e a lista
//     não é pedida a cada mensagem;
//   - pedido grande demais é recusado antes de custar nada.

import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import {
  conversar, corpoDoPedido, escolherModelo, esquecerModelo, lerPedido, lerSaida, pareceSegredo,
} from '../motor/agente-setup.ts';
import type { EntradaDoMapa, PedidoSetup } from '../motor/agente-setup.ts';

const MAPA: Record<string, EntradaDoMapa> = {
  canais: { forma: 'multipla', pergunta: 'canais?', valores: [
    { valor: 'whatsapp', rotulo: 'WhatsApp' }, { valor: 'email', rotulo: 'E-mail' },
  ] },
  pool: { forma: 'unica', pergunta: 'para quem?', valores: [{ valor: 'morna', rotulo: 'base' }, { valor: 'fria', rotulo: 'nova' }] },
  porDia: { forma: 'numeros', pergunta: 'quantas?', valores: [{ valor: 'whatsapp', rotulo: 'WhatsApp' }] },
};

const PEDIDO = lerPedido({ mensagem: 'quero prospectar lista fria no whatsapp, 80 por dia', mapa: MAPA }) as PedidoSetup;
const CHAVE_PLATAFORMA = 'sk-plataforma-0000000000000000000000';

beforeEach(() => esquecerModelo());

function openai(conteudo: unknown, modelos = ['gpt-4o', 'gpt-5-mini', 'text-embedding-3-small', 'gpt-4o-mini']) {
  const chamadas: { url: string; auth: string | null; corpo: Record<string, unknown> | null }[] = [];
  const buscar = (async (url: string | URL | Request, init?: RequestInit) => {
    const h = new Headers(init?.headers);
    chamadas.push({ url: String(url), auth: h.get('Authorization'), corpo: init?.body ? JSON.parse(String(init.body)) : null });
    if (String(url).endsWith('/models')) return Response.json({ data: modelos.map((id) => ({ id })) });
    return Response.json({ choices: [{ message: { content: JSON.stringify(conteudo) } }] });
  }) as typeof fetch;
  return { buscar, chamadas };
}

test('pedido: as chaves de verdade do assistente chegam ao modelo, inclusive porDia', () => {
  // Achado no teste ao vivo: o filtro de chave era só minúsculas, e "porDia"
  // sumia do vocabulário sem erro — o agente nunca preencheria o volume.
  assert.deepEqual(Object.keys(PEDIDO.mapa), ['canais', 'pool', 'porDia']);
  const corpo = JSON.stringify(corpoDoPedido('gpt-5-mini', PEDIDO));
  assert.match(corpo, /- porDia \(número inteiro por canal\)/);
});

test('saída: só chave e valor do vocabulário passam', () => {
  const s = lerSaida(JSON.stringify({
    mensagem: 'Entendi: WhatsApp, lista fria.', campos: [],
    respostas: [
      { chave: 'canais', valores: ['whatsapp', 'instagram', 'whatsapp'], numeros: [] },
      { chave: 'pool', valores: ['gelada', 'fria'], numeros: [] },
      { chave: 'porDia', valores: [], numeros: [{ canal: 'whatsapp', quantidade: 80 }, { canal: 'email', quantidade: 9 }, { canal: 'whatsapp', quantidade: 1.5 }] },
      { chave: 'campanha', valores: ['qualquer'], numeros: [] },
    ],
  }), MAPA);
  assert.deepEqual(s.respostas, { canais: ['whatsapp'], pool: 'fria', porDia: { whatsapp: 80 } });
});

test('campos: só os do passo, e nunca um valor com cara de chave (D73)', () => {
  const PODE = [{ chave: 'identificador', rotulo: 'número' }, { chave: 'assunto_padrao', rotulo: 'assunto' }];
  const s = lerSaida(JSON.stringify({
    mensagem: 'ok', respostas: [],
    campos: [
      { chave: 'identificador', valor: ' 5511988887777 ' },
      { chave: 'api_key', valor: 'qualquer' },                                   // não está no passo
      { chave: 'assunto_padrao', valor: 'sk-proj-AbCdEfGhIjKlMnOpQrStUv123456' }, // parece chave
    ],
  }), MAPA, PODE);
  assert.deepEqual(s.campos, { identificador: '5511988887777' });
});

test('pedido: campo que se declara segredo não é preenchível pelo agente', () => {
  const p = lerPedido({ mensagem: 'oi', passo: { tipo: 'campo', descricao: 'x', campos: [
    { chave: 'identificador', rotulo: 'n' }, { chave: 'api_key', rotulo: 'k', segredo: true },
  ] } }) as PedidoSetup;
  assert.deepEqual(p.passo.campos.map((c) => c.chave), ['identificador']);
});

test('saída fora do formato vira pergunta de volta, sem resposta nem campo', () => {
  const a = lerSaida('isto não é json', MAPA);
  assert.deepEqual(a.respostas, {});
  assert.deepEqual(a.campos, {});
  assert.match(a.mensagem, /Pode dizer/);
});

test('conversa: chave da plataforma no cabeçalho, modelo barato, formato estrito, e a lista pedida uma vez', async () => {
  const { buscar, chamadas } = openai({ mensagem: 'Certo.', campos: [], respostas: [{ chave: 'pool', valores: ['fria'], numeros: [] }] });
  const r = await conversar(PEDIDO, CHAVE_PLATAFORMA, buscar, 1000);
  assert.ok(r.ok);
  assert.equal(r.ok && r.modelo, 'gpt-5-mini');
  assert.deepEqual(r.ok && r.saida.respostas, { pool: 'fria' });
  assert.equal(chamadas[0]!.url, 'https://api.openai.com/v1/models');
  assert.ok(chamadas.every((c) => c.auth === `Bearer ${CHAVE_PLATAFORMA}`));
  const corpo = chamadas[1]!.corpo!;
  assert.equal((corpo.response_format as { type: string }).type, 'json_schema');
  assert.ok(!JSON.stringify(r).includes(CHAVE_PLATAFORMA), 'a chave não volta');

  await conversar(PEDIDO, CHAVE_PLATAFORMA, buscar, 2000);
  assert.equal(chamadas.filter((c) => c.url.endsWith('/models')).length, 1);
});

test('chave colada no texto livre não sai para a OpenAI', async () => {
  const { buscar, chamadas } = openai({ mensagem: 'x', campos: [], respostas: [] });
  const p = lerPedido({ mensagem: 'minha chave da openai é sk-proj-AbCdEfGhIjKlMnOpQrStUv123456', mapa: MAPA }) as PedidoSetup;
  const r = await conversar(p, CHAVE_PLATAFORMA, buscar);
  assert.equal(chamadas.length, 0);
  assert.ok(r.ok && Object.keys(r.saida.campos).length === 0);
  assert.ok(r.ok && !r.saida.mensagem.includes('sk-proj'));
});

test('histórico com chave é descartado antes de ir para o modelo', () => {
  const p = lerPedido({
    mensagem: 'e agora?', mapa: MAPA,
    historico: [{ papel: 'pessoa', texto: 'toma: sk-ant-api03-abcdefghijklmnopqrstuvwxyz' }, { papel: 'agente', texto: 'ok' }],
  }) as PedidoSetup;
  assert.deepEqual(p.historico.map((h) => h.texto), ['ok']);
  const corpo = JSON.stringify(corpoDoPedido('gpt-4o-mini', p));
  assert.ok(!corpo.includes('sk-ant'));
});

test('pareceSegredo: pega chave e token, deixa conversa e endereço passarem', () => {
  assert.ok(pareceSegredo('sk-proj-1234567890abcdefghij'));
  assert.ok(pareceSegredo('AIzaSyA1234567890abcdefghijklmnopqrstuv'));
  assert.ok(pareceSegredo('token 9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a3928'));
  assert.ok(!pareceSegredo('quero mandar 300 mensagens por dia no whatsapp e e-mail'));
  assert.ok(!pareceSegredo('a documentação está em https://developers.pipefy.com/reference/graphql-endpoint-and-authentication'));
});

test('pedido: vazio, longo ou malformado é recusado sem custo', () => {
  assert.equal(typeof lerPedido(null), 'string');
  assert.equal(typeof lerPedido({ mensagem: '   ' }), 'string');
  assert.equal(typeof lerPedido({ mensagem: 'x'.repeat(2001) }), 'string');
  const p = lerPedido({ mensagem: 'oi', mapa: { 'DROP;': { forma: 'unica', valores: [] }, pool: { forma: 'qualquer' } }, respostas: { a: 'x'.repeat(5000) } }) as PedidoSetup;
  assert.deepEqual(p.mapa, {});
  assert.deepEqual(p.respostas, {});
});

test('modelo: o mais barato que a chave alcança; sem nenhum de conversa, nenhum', () => {
  assert.equal(escolherModelo(['gpt-4o', 'gpt-4.1-mini', 'gpt-5.1-mini', 'gpt-5-mini']), 'gpt-5.1-mini');
  assert.equal(escolherModelo(['gpt-4o', 'o3']), 'gpt-4o');
  assert.equal(escolherModelo(['text-embedding-3-small', 'whisper-1']), null);
});

test('chave da plataforma recusada: erro que diz onde trocar, sem a chave', async () => {
  const buscar = (async () => new Response('{}', { status: 401 })) as typeof fetch;
  const r = await conversar(PEDIDO, CHAVE_PLATAFORMA, buscar);
  assert.ok(!r.ok);
  assert.match(!r.ok ? r.erro : '', /trocada no backend/);
  assert.ok(!JSON.stringify(r).includes(CHAVE_PLATAFORMA));
});
