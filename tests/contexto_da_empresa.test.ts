// O que a edge function `agente-contexto` decide (D78b), com porta, rede e
// modelo de mentira: quem pode, em que ordem cada coisa é paga, o que volta
// e o que nunca volta.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { colherDoPedido, TETO_DO_TEXTO_LIDO, TOKENS_DA_LEITURA } from '../motor/contexto-da-empresa.ts';
import type { ContaDaColeta, PedidoDaColeta, PortaDaColeta, RedeDaColeta } from '../motor/contexto-da-empresa.ts';
import { SISTEMA_DA_COLETA, TETO_TOTAL } from '../adapters/coleta.ts';
import type { Composicao } from '../adapters/ia.ts';
import type { Leitor, PedidoDeLeitura } from '../adapters/ia-leitura.ts';

const ID = '11111111-2222-3333-4444-555555555555';
const SEGREDO = '{"api_key":"sk-ant-segredo-que-nao-volta"}';
const b64 = (s: string | Uint8Array) => Buffer.from(s).toString('base64');
const PDF = b64('%PDF-1.7\nconteudo');
const TEXTO_LONGO = 'A Corretora Exemplo atende famílias e empresas em Sorocaba desde 2009. '.repeat(4);

function montar(o: {
  logado?: boolean; conta?: Partial<ContaDaColeta> | null; segredo?: string | null;
  paginas?: Record<string, string>; resposta?: Composicao;
} = {}) {
  const conta: ContaDaColeta | null = o.conta === null ? null
    : { tenant_id: 't', provedor: 'anthropic', modelo: 'claude-x', ativo: true, config: {}, ...o.conta };
  const chamadas = { contas: 0, segredos: 0, buscas: [] as string[], leituras: [] as PedidoDeLeitura[], leitores: [] as string[] };
  const porta: PortaDaColeta = {
    async pessoaLogada() { return o.logado ?? true; },
    async credencialVisivel() { chamadas.contas++; return conta; },
    async segredo() { chamadas.segredos++; return o.segredo === undefined ? SEGREDO : o.segredo; },
  };
  const rede: RedeDaColeta = {
    async resolver() { return ['93.184.216.34']; },
    buscar: (async (url: string) => {
      chamadas.buscas.push(String(url));
      const html = o.paginas?.[String(url)];
      return html === undefined ? new Response('', { status: 404 }) : new Response(html, { headers: { 'content-type': 'text/html' } });
    }) as typeof fetch,
  };
  const criar = (provedor: string): Leitor => {
    chamadas.leitores.push(provedor);
    return { provedor, async ler(p) { chamadas.leituras.push(p); return o.resposta ?? { ok: true, texto: 'A Corretora Exemplo vende planos.' }; } };
  };
  return { porta, rede, criar, chamadas };
}

const pedir = (m: ReturnType<typeof montar>, p: PedidoDaColeta) => colherDoPedido(m.porta, p, m.rede, m.criar);

test('sem pessoa logada, nada acontece', async () => {
  const m = montar({ logado: false });
  const r = await pedir(m, { credencial_id: ID, site: 'empresa.com.br' });
  assert.equal(r.status, 401);
  assert.deepEqual([m.chamadas.contas, m.chamadas.segredos, m.chamadas.buscas.length, m.chamadas.leituras.length], [0, 0, 0, 0]);
});

test('o pedido malformado é recusado antes de ler a conta', async () => {
  const casos: [PedidoDaColeta, number, RegExp][] = [
    [{ credencial_id: 'x', site: 'a.com.br' }, 400, /conta de IA/],
    [{ credencial_id: ID }, 400, /pelo menos uma fonte/],
    [{ credencial_id: ID, site: '  ', instagram: { handle: '', texto: '  ' }, materiais: [] }, 400, /pelo menos uma fonte/],
    [{ credencial_id: ID, materiais: 'x' }, 400, /materiais inválidos/],
    [{ credencial_id: ID, materiais: Array(11).fill({ nome: 'a.pdf', base64: PDF }) }, 400, /até 10 arquivos/],
    [{ credencial_id: ID, materiais: [{ nome: 'a.pdf' }] }, 400, /nome e conteúdo/],
    [{ credencial_id: ID, materiais: [{ nome: 'a.pdf', base64: 'A'.repeat(Math.ceil(TETO_TOTAL / 3) * 4 + 4) }] }, 413, /teto de uma leitura/],
  ];
  for (const [p, status, re] of casos) {
    const m = montar();
    const r = await pedir(m, p);
    assert.equal(r.status, status, JSON.stringify(p).slice(0, 80));
    assert.ok(!r.corpo.ok && re.test(r.corpo.erro), !r.corpo.ok ? r.corpo.erro : '');
    assert.equal(m.chamadas.contas, 0);
  }
});

test('a conta que a pessoa não alcança, desligada ou sem adapter — e o site de ninguém é buscado', async () => {
  for (const [conta, status, re] of [
    [null, 404, /não encontrada/],
    [{ ativo: false }, 409, /desligada/],
    [{ provedor: 'gemini' }, 409, /gemini ainda não tem adapter/],
  ] as const) {
    const m = montar({ conta, paginas: { 'https://empresa.com.br/': `<p>${TEXTO_LONGO}</p>` } });
    const r = await pedir(m, { credencial_id: ID, site: 'empresa.com.br' });
    assert.equal(r.status, status);
    assert.ok(!r.corpo.ok && re.test(r.corpo.erro));
    assert.deepEqual([m.chamadas.buscas.length, m.chamadas.segredos, m.chamadas.leituras.length], [0, 0, 0]);
  }
});

test('nada que se leia: o modelo não é chamado e o segredo não é lido', async () => {
  for (const p of [
    { instagram: { handle: '@corretora', texto: '' } },
    { site: 'naoexiste.com.br' },
    { materiais: [{ nome: 'a.pdf', base64: b64('<html>') }] },
  ] as PedidoDaColeta[]) {
    const m = montar();
    const r = await pedir(m, { credencial_id: ID, ...p });
    assert.equal(r.status, 200);
    assert.ok(r.corpo.ok && r.corpo.situacao === 'nada_lido', JSON.stringify(r.corpo));
    assert.ok(r.corpo.fontes.length >= 1, 'cada fonte diz por quê');
    assert.deepEqual([m.chamadas.segredos, m.chamadas.leituras.length], [0, 0]);
  }
});

test('o caminho inteiro: site, perfil colado e PDF viram um pedido, e o rascunho volta sem o segredo', async () => {
  const m = montar({ paginas: { 'https://empresa.com.br/': `<title>Empresa</title><p>${TEXTO_LONGO}</p>` } });
  const r = await pedir(m, {
    credencial_id: ID, empresa: '  Corretora Exemplo ', site: 'empresa.com.br',
    instagram: { handle: '@corretora', texto: 'Planos de saúde em Sorocaba' },
    materiais: [{ nome: 'catalogo.pdf', origem: 'material', base64: PDF }, { nome: 'perfil.png', origem: 'instagram',
      base64: b64(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1])) }],
  });
  assert.equal(r.status, 200);
  assert.ok(r.corpo.ok && r.corpo.situacao === 'pronto');
  assert.equal(r.corpo.texto, 'A Corretora Exemplo vende planos.');
  assert.equal(r.corpo.modelo, 'claude-x');
  assert.deepEqual(r.corpo.fontes.map((f) => [f.origem, f.rotulo, f.lida]), [
    ['site', 'https://empresa.com.br/', true],
    ['instagram', '@corretora', true],
    ['material', 'catalogo.pdf', true],
    ['instagram', 'print do Instagram (perfil.png)', true],
  ]);
  assert.equal(m.chamadas.segredos, 1);
  const p = m.chamadas.leituras[0]!;
  assert.equal(p.sistema, SISTEMA_DA_COLETA);
  assert.equal(p.maxTokens, TOKENS_DA_LEITURA);
  assert.equal(p.modelo, 'claude-x');
  assert.deepEqual(p.credenciais, { api_key: 'sk-ant-segredo-que-nao-volta' });
  assert.deepEqual(p.partes.map((x) => x.tipo), ['texto', 'texto', 'texto', 'pdf', 'imagem']);
  assert.match((p.partes[0] as { texto: string }).texto, /^A empresa se chama Corretora Exemplo\./);
  assert.ok(!JSON.stringify(r.corpo).includes('segredo-que-nao-volta'), 'o segredo nunca volta');
});

test('a conta que não lê anexo: o PDF é recusado com o motivo, e o texto segue', async () => {
  const m = montar({ conta: { provedor: 'deepseek', modelo: 'deepseek-chat' } });
  const r = await pedir(m, { credencial_id: ID, materiais: [
    { nome: 'catalogo.pdf', base64: PDF }, { nome: 'sobre.txt', base64: b64(TEXTO_LONGO) }] });
  assert.ok(r.corpo.ok && r.corpo.situacao === 'pronto');
  assert.equal(r.corpo.fontes[0]!.lida, false);
  assert.match(r.corpo.fontes[0]!.detalhe, /deepseek\) não lê PDF/);
  assert.deepEqual(m.chamadas.leituras[0]!.partes.map((x) => x.tipo), ['texto', 'texto']);
});

test('o que o modelo devolve: erro, nada a dizer e texto grande demais têm nome', async () => {
  const pedido = { credencial_id: ID, materiais: [{ nome: 'sobre.txt', base64: b64(TEXTO_LONGO) }] };
  const erro = await pedir(montar({ resposta: { ok: false, erro: 'HTTP 401: chave recusada', definitivo: true } }), pedido);
  assert.ok(erro.corpo.ok && erro.corpo.situacao === 'erro' && erro.corpo.motivo === 'HTTP 401: chave recusada');
  const nada = await pedir(montar({ resposta: { ok: true, texto: '[SEM INFORMAÇÃO]' } }), pedido);
  assert.ok(nada.corpo.ok && nada.corpo.situacao === 'sem_informacao');
  const grande = await pedir(montar({ resposta: { ok: true, texto: 'x'.repeat(20_001) } }), pedido);
  assert.ok(grande.corpo.ok && grande.corpo.situacao === 'erro' && /passou de 20\.000/.test(grande.corpo.motivo));
  const segredoRuim = montar({ segredo: '{não é json' });
  const s = await pedir(segredoRuim, pedido);
  assert.ok(s.corpo.ok && s.corpo.situacao === 'erro' && /salve a chave de novo/.test(s.corpo.motivo));
  assert.equal(segredoRuim.chamadas.leituras.length, 0);
});

test('as credenciais vão como o worker as monta: config por baixo, segredo por cima, sem aparar', async () => {
  const m = montar({ conta: { provedor: 'compativel', config: { base_url: ' https://ia.exemplo.com/v1 ', organizacao: 'o' } } });
  await pedir(m, { credencial_id: ID, materiais: [{ nome: 'a.txt', base64: b64(TEXTO_LONGO) }] });
  assert.deepEqual(m.chamadas.leituras[0]!.credenciais,
    { base_url: ' https://ia.exemplo.com/v1 ', organizacao: 'o', api_key: 'sk-ant-segredo-que-nao-volta' });
  assert.deepEqual(m.chamadas.leitores, ['compativel']);
});

test('o texto lido tem teto somando tudo, e a fonte que passou dele diz', async () => {
  const pedaco = b64('y'.repeat(40_000));
  const m = montar();
  const r = await pedir(m, { credencial_id: ID, materiais: Array.from({ length: 6 }, (_, i) => ({ nome: `p${i}.txt`, base64: pedaco })) });
  assert.ok(r.corpo.ok);
  const textos = m.chamadas.leituras[0]!.partes.slice(1).map((x) => (x as { texto: string }).texto.length);
  assert.ok(textos.reduce((a, c) => a + c, 0) <= TETO_DO_TEXTO_LIDO);
  // Cada parte leva o rótulo do arquivo além dos 40 000: o quarto já passa do teto.
  assert.equal(textos.length, 4, 'o quarto é cortado no teto; o quinto e o sexto ficam de fora');
  assert.equal(r.corpo.fontes[3]!.lida, true);
  assert.match(r.corpo.fontes[3]!.detalhe, /cortado no teto da leitura/);
  for (const f of r.corpo.fontes.slice(4)) {
    assert.equal(f.lida, false);
    assert.match(f.detalhe, /ficou de fora/);
  }
});
