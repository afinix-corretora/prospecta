// A coleta da empresa na tela (D78b): múltipla escolha, o que vai no pedido,
// o que falta para ler, que arquivo entra, e como o rascunho volta ao texto.
// E a ponte: o arquivo que a tela aceita é o que a edge function lê, e o que
// ela recusa a function também recusaria (D32).

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  alternar, anexosQueVao, aplicarRascunho, COLETA_VAZIA, contaPadraoDaLeitura, divergenciasDepoisDeUsar, oQueFaltaNaColeta,
  pedidoDaColeta, podeAnexar,
} from '../app/src/coleta.ts';
import type { Anexo, EstadoDaColeta } from '../app/src/coleta.ts';
import { CABECA, lerMaterial, TETO_TOTAL } from '../adapters/coleta.ts';
import { TETOS_DO_AGENTE } from '../adapters/prompt-do-agente.ts';
import { colherDoPedido } from '../motor/contexto-da-empresa.ts';
import type { PedidoDeLeitura } from '../adapters/ia-leitura.ts';

const MB = 1024 * 1024;
const b = (x: number[] | string) => (typeof x === 'string' ? new TextEncoder().encode(x) : new Uint8Array(x));
const PDF = b('%PDF-1.7\n');
const PNG = b([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const anexo = (nome: string, tipo: Anexo['tipo'], origem: Anexo['origem'], tamanho = 1000): Anexo =>
  ({ id: nome, nome, tamanho, tipo, origem, base64: 'AAAA' });

test('múltipla escolha: marcar uma não desmarca as outras', () => {
  let e = alternar(COLETA_VAZIA, 'site');
  e = alternar(e, 'materiais');
  e = alternar(e, 'instagram');
  assert.deepEqual([...e.marcadas].sort(), ['instagram', 'materiais', 'site']);
  e = alternar(e, 'materiais');
  assert.deepEqual([...e.marcadas].sort(), ['instagram', 'site']);
  assert.equal(COLETA_VAZIA.marcadas.size, 0, 'o estado vazio não é mexido');
});

test('o pedido leva só o que está marcado — o preenchido e desmarcado não vai', () => {
  const e: EstadoDaColeta = {
    marcadas: new Set(['site']), site: ' empresa.com.br ', handle: '@x', perfil: 'bio',
    anexos: [anexo('a.pdf', 'pdf', 'material'), anexo('p.png', 'imagem', 'instagram')],
  };
  assert.deepEqual(pedidoDaColeta(e, 'c1', ' Empresa '), { credencial_id: 'c1', empresa: 'Empresa', site: 'empresa.com.br' });
  const tudo = { ...e, marcadas: new Set(['site', 'instagram', 'materiais'] as const) };
  assert.deepEqual(pedidoDaColeta(tudo, 'c1', 'E'), {
    credencial_id: 'c1', empresa: 'E', site: 'empresa.com.br', instagram: { handle: '@x', texto: 'bio' },
    materiais: [{ nome: 'a.pdf', origem: 'material', base64: 'AAAA' }, { nome: 'p.png', origem: 'instagram', base64: 'AAAA' }],
  });
  const soIg = { ...e, marcadas: new Set(['instagram'] as const) };
  assert.deepEqual(anexosQueVao(soIg).map((a) => a.nome), ['p.png'], 'o print vai com o Instagram; o PDF, só com Materiais');
});

test('o que falta para ler, em palavras de quem preenche', () => {
  const vazio = COLETA_VAZIA;
  assert.deepEqual(oQueFaltaNaColeta(vazio, 'anthropic'), ['marcar de onde colher']);
  const site = alternar(vazio, 'site');
  assert.deepEqual(oQueFaltaNaColeta(site, 'anthropic'), ['o endereço do site']);
  assert.deepEqual(oQueFaltaNaColeta({ ...site, site: 'http://192.168.0.1' }, 'anthropic'),
    ['endereço por IP não é lido: use o domínio do site']);
  assert.match(oQueFaltaNaColeta({ ...site, site: 'instagram.com/corretora' }, 'anthropic')[0]!, /Instagram não se lê por robô/);
  assert.deepEqual(oQueFaltaNaColeta({ ...site, site: 'empresa.com.br' }, 'anthropic'), []);
  assert.deepEqual(oQueFaltaNaColeta({ ...site, site: 'empresa.com.br' }, null), ['a conta de IA que vai ler']);

  const ig = alternar(vazio, 'instagram');
  assert.match(oQueFaltaNaColeta(ig, 'anthropic')[0]!, /o @, o texto do perfil ou um print/);
  assert.match(oQueFaltaNaColeta({ ...ig, handle: '@corretora' }, 'anthropic')[0]!, /só o @ não dá o que ler/);
  assert.match(oQueFaltaNaColeta({ ...ig, handle: 'não é @!' }, 'anthropic')[0]!, /corrigir o @ do Instagram: "não é @!" não é um @/);
  assert.match(oQueFaltaNaColeta({ ...ig, handle: 'https://www.instagram.com/p/C8x/' }, 'anthropic')[0]!, /link de uma publicação/);
  // Com o site (ou um arquivo) indo junto, o @ vai como contato e não falta nada.
  const siteEIg = { ...alternar(ig, 'site'), site: 'corretora.com.br', handle: '@corretora' };
  assert.deepEqual(oQueFaltaNaColeta(siteEIg, 'anthropic'), []);
  const arquivoEIg = { ...alternar(ig, 'materiais'), handle: '@corretora', anexos: [anexo('a.txt', 'texto', 'material')] };
  assert.deepEqual(oQueFaltaNaColeta(arquivoEIg, 'anthropic'), []);
  // Site inválido não conta como "o que ler" ao lado do @.
  assert.equal(oQueFaltaNaColeta({ ...siteEIg, site: 'http://10.0.0.1' }, 'anthropic').length, 2);
  assert.deepEqual(oQueFaltaNaColeta({ ...ig, handle: '@corretora', perfil: 'bio' }, 'anthropic'), []);
  assert.deepEqual(oQueFaltaNaColeta({ ...ig, anexos: [anexo('p.png', 'imagem', 'instagram')] }, 'anthropic'), []);

  const mat = alternar(vazio, 'materiais');
  assert.deepEqual(oQueFaltaNaColeta(mat, 'anthropic'), ['pelo menos um arquivo']);
  // O print do Instagram não conta como material: ele vai com o Instagram.
  assert.deepEqual(oQueFaltaNaColeta({ ...mat, anexos: [anexo('p.png', 'imagem', 'instagram')] }, 'anthropic'), ['pelo menos um arquivo']);
  const comPdf = { ...mat, anexos: [anexo('a.pdf', 'pdf', 'material')] };
  assert.deepEqual(oQueFaltaNaColeta(comPdf, 'openai'), []);
  assert.match(oQueFaltaNaColeta(comPdf, 'deepseek')[0]!, /uma conta que leia PDF e imagem \(a escolhida é deepseek/);
  assert.deepEqual(oQueFaltaNaColeta({ ...mat, anexos: [anexo('a.txt', 'texto', 'material')] }, 'deepseek'), []);
  const pesado = { ...mat, anexos: [anexo('a.pdf', 'pdf', 'material', TETO_TOTAL), anexo('b.txt', 'texto', 'material', 1)] };
  assert.match(oQueFaltaNaColeta(pesado, 'anthropic')[0]!, /teto de uma leitura/);
});

test('anexar: o mesmo conferirArquivo da function, mais o conjunto e o lugar do print', () => {
  const mat = alternar(COLETA_VAZIA, 'materiais');
  assert.deepEqual(podeAnexar(mat, { nome: 'a.pdf', tamanho: 1000, cabeca: PDF }, 'material'), { ok: true, tipo: 'pdf' });
  const exe = podeAnexar(mat, { nome: 'a.exe', tamanho: 10, cabeca: b('MZ') }, 'material');
  assert.ok(!exe.ok && /só PDF/.test(exe.motivo));
  const pdfNoIg = podeAnexar(mat, { nome: 'a.pdf', tamanho: 10, cabeca: PDF }, 'instagram');
  assert.ok(!pdfNoIg.ok && /no Instagram entra print/.test(pdfNoIg.motivo));
  assert.deepEqual(podeAnexar(mat, { nome: 'p.jpg', tamanho: 10, cabeca: PNG }, 'instagram'), { ok: true, tipo: 'imagem' });
  const cheio = { ...mat, anexos: [anexo('a.pdf', 'pdf', 'material', 10 * MB), anexo('b.pdf', 'pdf', 'material', 4 * MB)] };
  const passa = podeAnexar(cheio, { nome: 'c.png', tamanho: 2 * MB, cabeca: PNG }, 'material');
  assert.ok(!passa.ok && /"c\.png" não entrou: os arquivos somam 16 MB/.test(passa.motivo));
  // O que está anexado mas DESMARCADO não vai, e não conta.
  const desmarcado = { ...cheio, marcadas: new Set(['instagram'] as const) };
  assert.ok(podeAnexar(desmarcado, { nome: 'p.png', tamanho: 2 * MB, cabeca: PNG }, 'instagram').ok);
  const dez = { ...mat, anexos: Array.from({ length: 10 }, (_, i) => anexo(`${i}.txt`, 'texto', 'material', 1)) };
  assert.ok(!podeAnexar(dez, { nome: 'x.txt', tamanho: 1, cabeca: b('oi') }, 'material').ok);
});

test('ponte: o arquivo que a tela aceita é o que a function lê, e o recusado também é recusado lá', () => {
  const arquivos: [string, Uint8Array, number][] = [
    ['a.pdf', PDF, 1000], ['a.pdf', b('<html>'), 1000], ['a.pdf', PDF, 10 * MB + 1],
    ['p.png', PNG, 1000], ['p.jpg', PNG, 1000], ['p.png', PDF, 1000], ['p.png', PNG, 5 * MB + 1],
    ['a.txt', b('oi'), 1000], ['a.txt', b([0x61, 0, 0x62]), 3], ['a.txt', b('oi'), MB + 1],
    ['a.html', b('<p>oi</p>'), 1000], ['a.exe', b('MZ'), 10], ['a.docx', b('PK'), 10], ['vazio.pdf', PDF, 0],
  ];
  const mat = alternar(COLETA_VAZIA, 'materiais');
  for (const [nome, cabeca, tamanho] of arquivos) {
    const tela = podeAnexar(mat, { nome, tamanho, cabeca: cabeca.subarray(0, CABECA) }, 'material');
    // O que a function recebe: os bytes de verdade, do tamanho declarado.
    const bytes = new Uint8Array(tamanho);
    bytes.set(cabeca.subarray(0, Math.min(cabeca.length, tamanho)));
    if (cabeca.every((x) => x !== 0) && !/\.(pdf|png|jpg)$/.test(nome)) bytes.fill(0x61, cabeca.length);
    const funcao = lerMaterial({ nome, origem: 'material', base64: Buffer.from(bytes).toString('base64') }, 'anthropic', true);
    assert.equal(tela.ok, funcao.fonte.lida, `${nome} (${tamanho} bytes): tela ${tela.ok ? 'aceita' : 'recusa'}, function ${funcao.fonte.lida ? 'lê' : 'recusa'}`);
  }
});

test('o rascunho volta pela mão da pessoa: no lugar, depois, e nunca acima do teto', () => {
  assert.deepEqual(aplicarRascunho('antigo', '  novo  ', 'usar'), { ok: true, texto: 'novo' });
  assert.deepEqual(aplicarRascunho('antigo  \n', 'novo', 'acrescentar'), { ok: true, texto: 'antigo\n\nnovo' });
  assert.deepEqual(aplicarRascunho('   ', 'novo', 'acrescentar'), { ok: true, texto: 'novo' });
  const teto = TETOS_DO_AGENTE.contexto;
  const cheio = aplicarRascunho('a'.repeat(teto - 5), 'bbbbbb', 'acrescentar');
  assert.ok(!cheio.ok && /ficaria com 20\.003 caracteres.*use no lugar/.test(cheio.motivo), !cheio.ok ? cheio.motivo : '');
  assert.ok(aplicarRascunho('a'.repeat(teto - 5), 'b'.repeat(teto), 'usar').ok);
  assert.ok(!aplicarRascunho('', 'b'.repeat(teto + 1), 'usar').ok);
});

test('a divergência depois de usar: a desta leitura no lugar; as duas, cada uma com a sua legenda, quando acrescenta', () => {
  const d1 = { texto: 'Essencial: R$ 289,90 (Arquivo A) x R$ 249,90 (Site A)', legenda: 'Site A = https://a.com.br/; Arquivo A = catalogo.pdf' };
  const d2 = { texto: 'Taxa: isenta (Arquivo A) x R$ 50 (Arquivo B)', legenda: 'Arquivo A = tabela.pdf; Arquivo B = folder.pdf' };
  assert.deepEqual(divergenciasDepoisDeUsar([d1], d2, 'texto de antes', 'usar'), [d2]);
  assert.deepEqual(divergenciasDepoisDeUsar([d1], null, 'texto de antes', 'usar'), [], 'no lugar, sem divergência nova, não fica nada');
  // Os apelidos recomeçam a cada leitura: "Arquivo A" é catalogo.pdf numa e tabela.pdf na outra — uma legenda por leitura.
  assert.deepEqual(divergenciasDepoisDeUsar([d1], d2, 'texto de antes', 'acrescentar'), [d1, d2]);
  assert.deepEqual(divergenciasDepoisDeUsar([d1], null, 'texto de antes', 'acrescentar'), [d1]);
  // Acrescentar a um campo vazio é usar (aplicarRascunho faz o mesmo): o texto de antes não está mais lá.
  assert.deepEqual(divergenciasDepoisDeUsar([d1], d2, '  ', 'acrescentar'), [d2]);
  assert.deepEqual(divergenciasDepoisDeUsar([], { texto: '  ', legenda: 'x' }, 'a', 'acrescentar'), []);
});

test('com que conta ler, de saída', () => {
  const contas = [
    { id: 'ds', provedor: 'deepseek', ativo: true },
    { id: 'off', provedor: 'anthropic', ativo: false },
    { id: 'gem', provedor: 'gemini', ativo: true },
    { id: 'oa', provedor: 'openai', ativo: true },
  ];
  const tem = (p: string) => p !== 'gemini';
  assert.equal(contaPadraoDaLeitura(contas, tem, 'ds')?.id, 'ds', 'a do agente, se serve');
  assert.equal(contaPadraoDaLeitura(contas, tem, 'off')?.id, 'oa', 'desligada não serve: a primeira que lê anexo');
  assert.equal(contaPadraoDaLeitura(contas, tem, 'gem')?.id, 'oa', 'sem adapter não serve');
  assert.equal(contaPadraoDaLeitura(contas.slice(0, 3), tem, null)?.id, 'ds', 'nenhuma lê anexo: a primeira que serve');
  assert.equal(contaPadraoDaLeitura([contas[1]!, contas[2]!], tem, null), null);
});

// ---------------------------------------------------------------------------
// A ponte inteira: o pedido que a TELA monta, pela function de verdade
// ---------------------------------------------------------------------------

const PDF64 = Buffer.from('%PDF-1.7\nconteudo').toString('base64');
const PNG64 = Buffer.from(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1])).toString('base64');
const TXT64 = Buffer.from('A Corretora Exemplo atende empresas e famílias em Sorocaba desde 2009.').toString('base64');

async function pelaFunction(e: EstadoDaColeta, provedor = 'anthropic') {
  const leituras: PedidoDeLeitura[] = [];
  const r = await colherDoPedido(
    {
      async pessoaLogada() { return true; },
      async credencialVisivel() { return { tenant_id: 't', provedor, modelo: 'm', ativo: true, config: {} }; },
      async segredo() { return '{"api_key":"k"}'; },
    },
    // O pedido passa por JSON, como passa pelo `functions.invoke`.
    JSON.parse(JSON.stringify(pedidoDaColeta(e, '11111111-2222-3333-4444-555555555555', 'Corretora Exemplo'))),
    {
      async resolver() { return ['93.184.216.34']; },
      buscar: (async () => new Response(`<p>${'A Corretora Exemplo vende planos de saúde. '.repeat(8)}</p>`,
        { headers: { 'content-type': 'text/html' } })) as typeof fetch,
    },
    { criar: (p) => ({ provedor: p, async ler(x) { leituras.push(x); return { ok: true, texto: 'rascunho' }; } }) },
  );
  return { r, leituras };
}

const comBase64 = (a: Anexo, base64: string): Anexo => ({ ...a, base64 });

test('ponte: o que a tela diz que pode ler, a function lê — e cada anexo aceito sai lido', async () => {
  const casos: [string, EstadoDaColeta][] = [
    ['site + @', { ...COLETA_VAZIA, marcadas: new Set(['site', 'instagram']), site: 'corretora.com.br', handle: '@corretora' }],
    ['só a bio', { ...COLETA_VAZIA, marcadas: new Set(['instagram']), perfil: 'Planos de saúde em Sorocaba' }],
    ['só prints', { ...COLETA_VAZIA, marcadas: new Set(['instagram']), anexos: [comBase64(anexo('p.png', 'imagem', 'instagram', 9), PNG64)] }],
    ['PDF e TXT', { ...COLETA_VAZIA, marcadas: new Set(['materiais']), anexos: [
      comBase64(anexo('a.pdf', 'pdf', 'material', 16), PDF64), comBase64(anexo('a.txt', 'texto', 'material', 72), TXT64)] }],
    ['site com fonte desmarcada', { ...COLETA_VAZIA, marcadas: new Set(['site']), site: 'corretora.com.br',
      anexos: [comBase64(anexo('a.pdf', 'pdf', 'material', 16), PDF64)] }],
  ];
  for (const [nome, e] of casos) {
    assert.deepEqual(oQueFaltaNaColeta(e, 'anthropic'), [], nome);
    const { r, leituras } = await pelaFunction(e);
    assert.equal(r.status, 200, nome);
    assert.ok(r.corpo.ok && r.corpo.situacao === 'pronto', `${nome}: ${JSON.stringify(r.corpo)}`);
    assert.equal(leituras.length, 1, nome);
    for (const a of anexosQueVao(e)) {
      const f = r.corpo.fontes.find((x) => x.rotulo.includes(a.nome));
      assert.ok(f?.lida, `${nome}: ${a.nome} aceito na tela e não lido na function`);
    }
  }
  // O desmarcado não vai: nem como fonte, nem como parte.
  const { r } = await pelaFunction(casos[4]![1]);
  assert.ok(r.corpo.ok && !r.corpo.fontes.some((f) => f.rotulo === 'a.pdf'));
});

test('ponte: nome longo que a tela recusa, a function também — pelo mesmo motivo', async () => {
  const nome = `${'Tabela de preços dos planos empresariais '.repeat(6)}.pdf`;
  const tela = podeAnexar(alternar(COLETA_VAZIA, 'materiais'), { nome, tamanho: 16, cabeca: PDF }, 'material');
  assert.ok(!tela.ok && /longo demais/.test(tela.motivo));
  const e = { ...COLETA_VAZIA, marcadas: new Set(['materiais'] as const), anexos: [comBase64(anexo(nome, 'pdf', 'material', 16), PDF64)] };
  const { r } = await pelaFunction(e);
  assert.ok(r.corpo.ok && /longo demais/.test(r.corpo.fontes[0]!.detalhe));
});
