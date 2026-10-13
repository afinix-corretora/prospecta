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
  conversar, corpoDoPedido, escolherModelo, esquecerModelo, instrucoes, lerPedido, lerSaida, pareceSegredo,
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

test('canal e família do WhatsApp só entram se a pessoa os disse (D77)', () => {
  // Ao vivo: "quero telegram" voltou como WhatsApp, e-mail e SMS, e "lista que
  // comprei" voltou como "não oficial" — e a sugestão entra como clique.
  const mapa: Record<string, EntradaDoMapa> = {
    ...MAPA,
    canais: { forma: 'multipla', pergunta: 'canais?', valores: [
      { valor: 'whatsapp', rotulo: 'WhatsApp' }, { valor: 'email', rotulo: 'E-mail' }, { valor: 'sms', rotulo: 'SMS' }] },
    'familia:whatsapp': { forma: 'unica', pergunta: 'qual?', valores: [{ valor: 'oficial', rotulo: 'Oficial' }, { valor: 'nao', rotulo: 'Não oficial' }] },
  };
  const saida = (respostas: unknown[]) => JSON.stringify({ mensagem: 'ok', campos: [], respostas });
  const tudo = saida([
    { chave: 'canais', valores: ['whatsapp', 'email', 'sms'], numeros: [] },
    { chave: 'familia:whatsapp', valores: ['nao'], numeros: [] },
  ]);
  assert.deepEqual(lerSaida(tudo, mapa, [], 'quero telegram').respostas, {});
  assert.deepEqual(lerSaida(tudo, mapa, [], 'uns 50 por dia no zap, lista que comprei').respostas, { canais: ['whatsapp'] });
  assert.deepEqual(lerSaida(tudo, mapa, [], 'WhatsApp não oficial, num chip, e e-mail').respostas,
    { canais: ['whatsapp', 'email'], 'familia:whatsapp': 'nao' });
  assert.deepEqual(lerSaida(tudo, mapa, [], 'todos os canais').respostas, { canais: ['whatsapp', 'email', 'sms'] });
  // Sem a fala (quem chama sem ela), nada muda: o filtro de vocabulário segue.
  assert.deepEqual(lerSaida(tudo, mapa).respostas, { canais: ['whatsapp', 'email', 'sms'], 'familia:whatsapp': 'nao' });
});

test('conversa: a fala da pessoa chega ao freio de canal (D77)', async () => {
  const { buscar } = openai({ mensagem: 'Telegram ainda não existe aqui.', campos: [],
    respostas: [{ chave: 'canais', valores: ['whatsapp', 'email'], numeros: [] }] });
  const r = await conversar(lerPedido({ mensagem: 'quero telegram', mapa: MAPA }) as PedidoSetup, CHAVE_PLATAFORMA, buscar, 1000);
  assert.ok(r.ok);
  assert.deepEqual(r.ok && r.saida.respostas, {});
});

test('instrução: oficial ou não oficial é da pessoa, e canal fora do vocabulário não vira outro (D77)', () => {
  const t = instrucoes(PEDIDO);
  assert.match(t, /Nunca a deduza do tipo de lista/);
  assert.doesNotMatch(t, /não oficial é o que roda lista fria/);
  assert.match(t, /não vira outro canal/);
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

// D77: uma amostra SINTÉTICA no formato de cada segredo do catálogo. A regra
// antiga só pegava 40 caracteres seguidos, e as chaves reais têm 24 a 39 — o
// token UAZAPI de produção passava. Cada linha acende sozinha se a peça da
// regra que a pega sumir.
//
// As de prefixo de provedor são montadas na execução: no arquivo inteiras, o
// scanner do GitHub as lê como chave de verdade e recusa o push — o que é o
// comportamento certo dele, e o que esta lista imita de propósito.
const junto = (...partes: string[]) => partes.join('');
const SEGREDOS_DO_CATALOGO: [string, string][] = [
  ['UAZAPI, token da instância (UUID)', '3f2a9c4e-8b1d-4e7a-9c2f-5d6e7f8a9b0c'],
  ['Comtele, chave (UUID)', '0b7c6d5e-4f3a-2b1c-0d9e-8f7a6b5c4d3e'],
  ['Gupshup, API key (32 hex)', 'a1b2c3d4e5f60718293a4b5c6d7e8f90'],
  ['Evolution, apikey (32 maiúsculo)', 'B6D711FCDE4D4FD5936544120E713976'],
  ['SMTP Locaweb, token (32)', '7f3e9a2b1c4d5e6f7a8b9c0d1e2f3a4b'],
  ['RD Station CRM, token (24 hex)', '5f8a9b0c1d2e3f4a5b6c7d8e'],
  ['Resend, API key', 're_Ab12Cd34_EfGh56IjKl78MnOp90QrSt12'],
  ['Meta Cloud, access token', 'EAAGm0PX4ZCpsBAOb1k2ZBk3ZCeZBdZBZAeZCWZCkZAbZCcZD'],
  ['Anthropic', 'sk-ant-api03-AbCdEf123456_ghIJkl789012'],
  ['OpenAI', 'sk-proj-AbCdEfGh1234567890'],
  ['DeepSeek', junto('sk-', '0123456789abcdef'.repeat(2))],
  ['OpenRouter', junto('sk-or-', 'v1-', '0123456789abcdef'.repeat(4))],
  ['Perplexity', 'pplx-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d'],
  ['Google AI Studio', 'AIzaSyA1234567890abcdefghijklmnopqrstuv'],
  ['Google AI Studio, com hífen', 'AIzaSyB-1234567890abcdefgh-ijklmnopqrstu'],
  ['Pipefy, client secret', 'Xk9fT2mQ7pL4vB8nR1sW6yZ3cJ5hD0gA'],
  ['HubSpot, private app token', junto('pat-', 'na1-', '1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d')],
  ['Pipedrive, API token (40 hex)', 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'],
  ['Salesforce, consumer secret', '1A2B3C4D5E6F7A8B9C0D1E2F3A4B5C6D7E8F9A0B1C2D3E4F5A6B7C8D9E0F1A2B'],
  ['Zoho, refresh token', '1000.0123456789abcdef0123456789abcdef.fedcba9876543210fedcba9876543210'],
  ['chave só de letras, caixas misturadas', 'AbCdEfGhIjKlMnOpQrStUvWxYzAbCdEf'],
  ['JWT', 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc'],
  ['JWT em pedaços curtos', 'eyJhbGci-OiJIUzI1.eyJzdWIi-OiIxMjM0.sig'],
  ['token de admin só minúsculas', 'qwhzrtkplmnbvcxjsdfgylkjhgfdsapoiuytrewqzxcv'],
];

test('pareceSegredo: a chave de cada provedor do catálogo, sozinha e no meio da frase', () => {
  for (const [onde, chave] of SEGREDOS_DO_CATALOGO) {
    assert.ok(pareceSegredo(chave), `${onde} passou sozinha`);
    assert.ok(pareceSegredo(`pode usar essa, a chave é ${chave}, obrigado`), `${onde} passou no meio da frase`);
  }
  assert.ok(pareceSegredo('lista fria no WhatsApp pela UAZAPI, o token é 3f2a9c4e-8b1d-4e7a-9c2f-5d6e7f8a9b0c'));
  // Token no meio de um endereço web não se esconde atrás da URL.
  assert.ok(pareceSegredo('https://free.uazapi.com/send?token=7f3e9a2b1c4d5e6f7a8b9c0d1e2f3a4b'));
});

test('pareceSegredo: nome de modelo, endereço, telefone, e-mail e conversa passam', () => {
  const passam = [
    // O passo "Qual modelo?" recebe isto digitado.
    'claude-sonnet-4-5-20250929', 'gpt-4o-mini-2024-07-18', 'llama-3.1-sonar-large-128k-online',
    'gemini-2.5-pro-preview-05-06', 'anthropic/claude-3.5-sonnet', 'meta-llama/llama-3.1-405b-instruct',
    'o4-mini-2025-04-16', 'sonar-reasoning-pro',
    // Servidor e documentação.
    'free-1234.uazapi.com', 'https://free-1234.uazapi.com', 'evolution.minhaempresa.com.br',
    'https://api.smtplw.com.br/v1', 'veja https://docs.github.com/en/rest/v3/repos',
    // Telefone, documento da empresa, e-mail.
    '+55 (11) 99999-0000', '5511999990000', '12.345.678/0001-90', '12345678000190',
    'contato.comercial2024@afinixcorretora.com.br',
    // Conversa.
    'Somos a Afinix Corretora de Seguros, em São José do Rio Preto, com 30 vidas no plano PME',
    'Inconstitucionalissimamente falando, prefiro a base própria',
    'o app da Gupshup se chama AfinixProspecta e o número é 5517999990000',
  ];
  for (const t of passam) assert.ok(!pareceSegredo(t), `barrou sem ser chave: ${t}`);
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
