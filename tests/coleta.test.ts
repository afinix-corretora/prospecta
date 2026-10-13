// Ler a empresa de fora (D78b), sem rede: o que entra como arquivo, que
// endereço de site se lê, como a página vira texto, e o pedido que vai ao
// modelo com os anexos — que é o MESMO de `ia.ts`, só com os blocos trocados.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ACEITA, bytesDoBase64, cabemJuntos, conferirArquivo, conferirEndereco, decodificarTexto, enderecoInterno,
  htmlParaTexto, lerInstagram, lerMaterial, lerSite, MAX_ARQUIVOS, paginasParaLer, POUCO_TEXTO, semInformacao,
  SEM_INFORMACAO, tamanhoDoBase64, TETO_DA_PAGINA, TETO_TEXTO_DO_ARQUIVO, TETO_TOTAL,
} from '../adapters/coleta.ts';
import type { RedeDoSite } from '../adapters/coleta.ts';
import { blocosDoClaude, criarLeitor, LEEM_ANEXOS, partesDoChat } from '../adapters/ia-leitura.ts';
import type { Parte } from '../adapters/ia-leitura.ts';
import { criarIa, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';

const MB = 1024 * 1024;
const b = (s: string | number[]) => (typeof s === 'string' ? new TextEncoder().encode(s) : new Uint8Array(s));
const b64 = (x: Uint8Array | string) => Buffer.from(typeof x === 'string' ? x : x).toString('base64');
const PDF = b('%PDF-1.7\n%âãÏÓ\n1 0 obj\n<<>>\nendobj\n');
const PNG = b([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]);
const JPG = b([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46]);

// ---------------------------------------------------------------------------
// Arquivos
// ---------------------------------------------------------------------------

test('arquivo: a extensão escolhe o formato e os primeiros bytes confirmam', () => {
  assert.equal(ACEITA, '.pdf,.jpg,.jpeg,.png,.html,.htm,.txt');
  const pdf = conferirArquivo('catalogo.PDF', 2 * MB, PDF);
  assert.ok(pdf.ok && pdf.formato.tipo === 'pdf');
  // O cabeçalho do PDF pode vir depois de lixo, dentro do primeiro KB.
  assert.ok(conferirArquivo('x.pdf', 100, b(`${'x'.repeat(300)}%PDF-1.4`)).ok);
  const falso = conferirArquivo('x.pdf', 100, b('<html>'));
  assert.ok(!falso.ok && /não é um PDF/.test(falso.motivo));
  // JPG que é PNG passa pelo que o conteúdo é.
  const troca = conferirArquivo('print.jpg', 1000, PNG);
  assert.ok(troca.ok && troca.formato.mime === 'image/png');
  assert.ok(conferirArquivo('foto.jpeg', 1000, JPG).ok);
  assert.ok(!conferirArquivo('foto.png', 1000, PDF).ok);
  const exe = conferirArquivo('setup.exe', 10, b('MZ'));
  assert.ok(!exe.ok && /só PDF, JPG, PNG, HTML e TXT/.test(exe.motivo));
  assert.ok(!conferirArquivo('sem-extensao', 10, b('oi')).ok);
  const vazio = conferirArquivo('a.txt', 0, b(''));
  assert.ok(!vazio.ok && /vazio/.test(vazio.motivo));
  const binario = conferirArquivo('a.txt', 10, b([0x61, 0, 0x62]));
  assert.ok(!binario.ok && /binário/.test(binario.motivo));
});

test('arquivo: o teto é por formato, e no teto exato ainda entra', () => {
  assert.ok(conferirArquivo('a.pdf', 10 * MB, PDF).ok);
  const pdf = conferirArquivo('a.pdf', 10 * MB + 1, PDF);
  assert.ok(!pdf.ok && /teto para PDF é 10 MB/.test(pdf.motivo), !pdf.ok ? pdf.motivo : '');
  assert.ok(conferirArquivo('a.png', 5 * MB, PNG).ok);
  assert.ok(!conferirArquivo('a.png', 5 * MB + 1, PNG).ok);
  assert.ok(!conferirArquivo('a.txt', MB + 1, b('oi')).ok);
  assert.ok(conferirArquivo('a.html', 2 * MB, b('<html>')).ok);
});

test('arquivos juntos: quantos e quanto', () => {
  assert.equal(cabemJuntos([]), null);
  assert.equal(cabemJuntos(Array(MAX_ARQUIVOS).fill(1)), null);
  assert.match(cabemJuntos(Array(MAX_ARQUIVOS + 1).fill(1))!, /até 10 arquivos/);
  assert.equal(cabemJuntos([TETO_TOTAL]), null);
  assert.match(cabemJuntos([TETO_TOTAL, 1])!, /teto de uma leitura é 15 MB/);
});

test('base64: tamanho sem decodificar, e os primeiros bytes', () => {
  assert.equal(tamanhoDoBase64(''), 0);
  assert.equal(tamanhoDoBase64('YQ=='), 1);
  assert.equal(tamanhoDoBase64('YWI='), 2);
  assert.equal(tamanhoDoBase64('YWJj'), 3);
  assert.equal(tamanhoDoBase64('abc'), null);
  assert.equal(tamanhoDoBase64('a b='), null);
  assert.equal(tamanhoDoBase64('YQ==YQ=='), null, 'padding no meio não é base64');
  const grande = b64(b('%PDF-' + 'x'.repeat(5000)));
  assert.deepEqual([...bytesDoBase64(grande, 5)], [...PDF.subarray(0, 5)]);
  assert.equal(tamanhoDoBase64(grande), 5005);
});

test('texto: UTF-8, e o que não é UTF-8 lido como Windows-1252', () => {
  assert.equal(decodificarTexto(b('ação')), 'ação');
  assert.equal(decodificarTexto(b([0xef, 0xbb, 0xbf, 0x6f, 0x69])), 'oi', 'o BOM sai');
  assert.equal(decodificarTexto(b([0x61, 0xe7, 0xe3, 0x6f])), 'ação');
  assert.equal(decodificarTexto(b([0x61, 0xe7, 0xe3, 0x6f]), 'iso-8859-1'), 'ação');
  assert.equal(decodificarTexto(b('ação'), 'rotulo-que-nao-existe'), 'ação');
});

// ---------------------------------------------------------------------------
// HTML
// ---------------------------------------------------------------------------

test('html: o texto que se lê, sem script, estilo e comentário', () => {
  const p = htmlParaTexto(`<!doctype html><html><head><title>Corretora &amp; Cia</title>
    <meta name="description" content="Planos de sa&uacute;de em Sorocaba">
    <style>.x{color:red}</style><script>var preco = "R$ 1,00";</script></head>
    <body><!-- R$ 2,00 escondido --><nav><a href="/sobre">Quem somos</a> <a href='/planos'>Planos</a></nav>
    <h1>Bem-vindo</h1><p>Atendemos&nbsp;empresas &#233; fam&iacute;lias &#x41;.</p>
    <ul><li>Plano Bronze</li><li>Plano Prata</li></ul><p>Atendemos&nbsp;empresas &#233; fam&iacute;lias &#x41;.</p>
    <svg><text>ícone</text></svg><noscript>ative o JS</noscript></body></html>`);
  assert.equal(p.titulo, 'Corretora & Cia');
  assert.equal(p.descricao, 'Planos de saúde em Sorocaba');
  assert.doesNotMatch(p.texto, /R\$|color|ícone|ative o JS/);
  assert.match(p.texto, /Atendemos empresas é famílias A\./);
  assert.match(p.texto, /- Plano Bronze\n- Plano Prata/);
  assert.deepEqual(p.links.map((l) => [l.href, l.texto]), [['/sobre', 'Quem somos'], ['/planos', 'Planos']]);
});

test('html: a página que repete a mesma linha seguida não a repete no texto', () => {
  const p = htmlParaTexto('<p>Ligue</p><p>Ligue</p><p>Agora</p><p>Ligue</p>');
  assert.equal(p.texto, 'Ligue\nAgora\nLigue');
});

test('html: as páginas do mesmo site que dizem o que a empresa é, nessa ordem', () => {
  const base = new URL('https://www.empresa.com.br/');
  const links = [
    { href: '/blog', texto: 'Blog' },
    { href: '/contato', texto: 'Fale com a gente' },
    { href: 'https://empresa.com.br/planos', texto: 'Planos' },
    { href: 'https://outra.com.br/sobre', texto: 'Sobre' },
    { href: '/tabela.pdf', texto: 'Tabela de preços' },
    { href: '/institucional/quem-somos#time', texto: 'A empresa' },
    { href: '/sobre?x=1', texto: 'Sobre' },
    { href: 'mailto:oi@empresa.com.br', texto: 'Contato' },
    { href: '/', texto: 'Início' },
    { href: '/servi%C3%A7os', texto: '' },
  ];
  assert.deepEqual(paginasParaLer(links, base).map((u) => u.href), [
    'https://www.empresa.com.br/institucional/quem-somos',
    'https://www.empresa.com.br/sobre?x=1',
    'https://empresa.com.br/planos',
  ]);
});

// ---------------------------------------------------------------------------
// O endereço
// ---------------------------------------------------------------------------

test('endereço: o que o texto já entrega como não público é recusado antes da rede', () => {
  const ok = (s: string) => { const r = conferirEndereco(s); assert.ok(r.ok, `${s}: ${r.ok ? '' : r.motivo}`); return r.url.href; };
  const nao = (s: string, re: RegExp) => { const r = conferirEndereco(s); assert.ok(!r.ok && re.test(r.motivo), `${s}: ${r.ok ? 'aceito' : r.motivo}`); };
  assert.equal(ok('www.empresa.com.br'), 'https://www.empresa.com.br/');
  assert.equal(ok(' http://empresa.com/planos#topo '), 'http://empresa.com/planos');
  assert.equal(ok('https://xn--caf-dma.com.br'), 'https://xn--caf-dma.com.br/');
  ok('https://café.com.br');
  nao('', /vazio/);
  nao('ftp://empresa.com.br', /http ou https/);
  nao('javascript:alert(1)', /não é o endereço de um site público|não é um endereço/);
  nao('https://eu:senha@empresa.com.br', /usuário e senha/);
  nao('https://empresa.com.br:8443/', /porta padrão/);
  nao('http://127.0.0.1/', /por IP/);
  nao('http://169.254.169.254/latest/meta-data', /por IP/);
  nao('http://2130706433/', /por IP/);
  nao('http://0x7f.1/', /por IP/);
  nao('http://[::1]/', /por IP/);
  nao('http://localhost:54321/', /porta padrão|site público/);
  nao('http://localhost/', /site público/);
  nao('http://intranet/', /site público/);
  nao('http://impressora.local/', /site público/);
  nao('http://metadata.google.internal/', /site público/);
  nao('http://kong.svc.cluster.local/', /site público/);
  nao('http://empresa.123/', /site público|não é um endereço/);
});

test('endereço: para onde o domínio aponta — rede interna, reservado ou ilegível é interno', () => {
  for (const ip of ['10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.0.10', '127.0.0.1', '0.0.0.0',
    '169.254.169.254', '100.64.0.1', '100.127.255.255', '198.18.0.1', '224.0.0.1', '255.255.255.255',
    '192.0.2.1', '203.0.113.9', '::', '::1', 'fe80::1', 'febf::1', 'fc00::1', 'fd12:3456::1', 'ff02::1',
    '::ffff:127.0.0.1', '::ffff:7f00:1', '::ffff:10.0.0.1', '64:ff9b::a9fe:a9fe', '2001:db8::1', '::2',
    'lixo', '1.2.3', '1.2.3.256', ':::1', '1::2::3']) {
    assert.equal(enderecoInterno(ip), true, ip);
  }
  for (const ip of ['8.8.8.8', '172.32.0.1', '100.128.0.1', '200.147.67.142', '2001:4860:4860::8888',
    '2606:4700::6810:84e5', '::ffff:8.8.8.8', '64:ff9b::808:808']) {
    assert.equal(enderecoInterno(ip), false, ip);
  }
});

// ---------------------------------------------------------------------------
// O site, com a rede de mentira
// ---------------------------------------------------------------------------

interface Pagina { status?: number; tipo?: string; corpo?: string | Uint8Array; destino?: string; lancar?: unknown }

function redeFalsa(paginas: Record<string, Pagina>, dns: Record<string, string[] | 'lança'> = {}) {
  const pedidos: { url: string; redirect: unknown; temPrazo: boolean }[] = [];
  const perguntas: string[] = [];
  const rede: RedeDoSite = {
    async resolver(host) {
      perguntas.push(host);
      const r = dns[host];
      if (r === 'lança') throw new Error('sem DNS');
      return r ?? ['93.184.216.34'];
    },
    buscar: (async (url: string, init?: RequestInit) => {
      pedidos.push({ url: String(url), redirect: init?.redirect, temPrazo: init?.signal instanceof AbortSignal });
      const p = paginas[String(url)];
      if (!p) return new Response('não achei', { status: 404, headers: { 'content-type': 'text/html' } });
      if (p.lancar) throw p.lancar;
      if (p.destino) return new Response(null, { status: p.status ?? 301, headers: { location: p.destino } });
      return new Response(p.corpo ?? '', { status: p.status ?? 200, headers: { 'content-type': p.tipo ?? 'text/html; charset=utf-8' } });
    }) as typeof fetch,
  };
  return { rede, pedidos, perguntas };
}

const TEXTO_LONGO = 'A Corretora Exemplo atende famílias e empresas em Sorocaba desde 2009, com planos de saúde e odontológicos. '.repeat(3);

test('site: a página e até três do mesmo site, cada uma com a sua linha', async () => {
  const { rede, pedidos } = redeFalsa({
    'https://www.empresa.com.br/': { corpo: `<title>Empresa</title><p>${TEXTO_LONGO}</p>
      <a href="/blog">Blog</a><a href="/contato">Contato</a><a href="/planos">Planos</a>
      <a href="/sobre">Quem somos</a><a href="/produtos">Produtos</a><a href="https://facebook.com/empresa">FB</a>` },
    'https://www.empresa.com.br/sobre': { corpo: `<p>${TEXTO_LONGO}</p>` },
    'https://www.empresa.com.br/planos': { corpo: '<p>Plano Bronze R$ 199,90 por mês.</p>' },
    'https://www.empresa.com.br/produtos': { status: 500 },
  });
  const r = await lerSite('www.empresa.com.br', rede);
  assert.deepEqual(pedidos.map((p) => p.url), [
    'https://www.empresa.com.br/', 'https://www.empresa.com.br/sobre',
    'https://www.empresa.com.br/planos', 'https://www.empresa.com.br/produtos',
  ]);
  assert.ok(pedidos.every((p) => p.redirect === 'manual' && p.temPrazo), 'redirecionamento é conferido à mão, com prazo');
  assert.deepEqual(r.fontes.map((f) => [f.rotulo, f.lida]), [
    ['https://www.empresa.com.br/', true], ['https://www.empresa.com.br/sobre', true],
    ['https://www.empresa.com.br/planos', true], ['https://www.empresa.com.br/produtos', false],
  ]);
  assert.match(r.fontes[3]!.detalhe, /HTTP 500/);
  assert.equal(r.partes.length, 3, 'uma parte por página lida');
  assert.ok(r.partes.every((p) => p.tipo === 'texto'));
  assert.match((r.partes[0] as { texto: string }).texto, /^\[Site\] https:\/\/www\.empresa\.com\.br\/\nTítulo: Empresa\n/);
  assert.match(r.fontes[2]!.detalhe, /quase não tem texto/, 'página curta diz que chegou curta');
});

test('site: redirecionamento é seguido, e cada salto é conferido de novo', async () => {
  const ida = redeFalsa({
    'http://empresa.com.br/': { destino: 'https://www.empresa.com.br/' },
    'https://www.empresa.com.br/': { corpo: `<p>${TEXTO_LONGO}</p>` },
  });
  const r = await lerSite('http://empresa.com.br', ida.rede);
  assert.equal(r.fontes[0]!.rotulo, 'https://www.empresa.com.br/');
  assert.equal(r.fontes[0]!.lida, true);

  // O salto para o IP de metadados é recusado SEM ser buscado.
  const meta = redeFalsa({ 'https://empresa.com.br/': { destino: 'http://169.254.169.254/latest/meta-data/' } });
  const m = await lerSite('empresa.com.br', meta.rede);
  assert.equal(m.fontes[0]!.lida, false);
  assert.match(m.fontes[0]!.detalhe, /redirecionou para um endereço que não se lê \(endereço por IP/);
  assert.deepEqual(meta.pedidos.map((p) => p.url), ['https://empresa.com.br/']);

  // O salto para um domínio que aponta para dentro: recusado antes do fetch.
  const dentro = redeFalsa({ 'https://empresa.com.br/': { destino: 'https://painel.empresa.com.br/' },
    'https://painel.empresa.com.br/': { corpo: 'segredo' } }, { 'painel.empresa.com.br': ['10.0.0.7'] });
  const d = await lerSite('empresa.com.br', dentro.rede);
  assert.match(d.fontes[0]!.detalhe, /painel\.empresa\.com\.br aponta para um endereço de rede interna/);
  assert.deepEqual(dentro.pedidos.map((p) => p.url), ['https://empresa.com.br/']);
  assert.deepEqual(dentro.perguntas, ['empresa.com.br', 'painel.empresa.com.br']);

  const laco = redeFalsa({ 'https://a.com.br/': { destino: 'https://a.com.br/x' }, 'https://a.com.br/x': { destino: 'https://a.com.br/' } });
  assert.match((await lerSite('a.com.br', laco.rede)).fontes[0]!.detalhe, /vezes demais/);
  const semDestino = redeFalsa({ 'https://a.com.br/': { status: 302, destino: '' } });
  semDestino.rede.buscar = (async () => new Response(null, { status: 302 })) as typeof fetch;
  assert.match((await lerSite('a.com.br', semDestino.rede)).fontes[0]!.detalhe, /sem dizer para onde/);
});

test('site: domínio que aponta para dentro, que não existe, ou sem DNS — e nada é buscado', async () => {
  const dentro = redeFalsa({}, { 'empresa.com.br': ['93.184.216.34', '127.0.0.1'] });
  const r = await lerSite('empresa.com.br', dentro.rede);
  assert.match(r.fontes[0]!.detalhe, /rede interna/, 'um endereço interno entre vários já recusa');
  assert.equal(dentro.pedidos.length, 0);

  const nada = redeFalsa({}, { 'naoexiste.com.br': [] });
  assert.match((await lerSite('naoexiste.com.br', nada.rede)).fontes[0]!.detalhe, /não foi encontrado/);
  const semDns = redeFalsa({}, { 'empresa.com.br': 'lança' });
  assert.match((await lerSite('empresa.com.br', semDns.rede)).fontes[0]!.detalhe, /não foi possível conferir/);
  assert.equal(nada.pedidos.length + semDns.pedidos.length, 0);

  const ip = redeFalsa({});
  assert.match((await lerSite('http://10.0.0.1', ip.rede)).fontes[0]!.detalhe, /por IP/);
  assert.equal(ip.perguntas.length + ip.pedidos.length, 0);
});

test('site: o que não é página, o que não responde e o que é grande demais', async () => {
  const pdf = redeFalsa({ 'https://a.com.br/tabela.pdf': { tipo: 'application/pdf', corpo: '%PDF-1.4' } });
  assert.match((await lerSite('a.com.br/tabela.pdf', pdf.rede)).fontes[0]!.detalhe, /arquivo \(application\/pdf\).*Materiais/);

  const lento = redeFalsa({ 'https://a.com.br/': { lancar: new DOMException('The operation was aborted due to timeout', 'TimeoutError') } });
  assert.match((await lerSite('a.com.br', lento.rede)).fontes[0]!.detalhe, /não respondeu em 10 s/);
  const caiu = redeFalsa({ 'https://a.com.br/': { lancar: new TypeError('fetch failed') } });
  assert.match((await lerSite('a.com.br', caiu.rede)).fontes[0]!.detalhe, /não foi possível conectar/);

  const grande = redeFalsa({ 'https://a.com.br/': { corpo: `<p>${'Texto da empresa. '.repeat(Math.ceil(TETO_DA_PAGINA * 1.3 / 18))}</p>` } });
  const g = await lerSite('a.com.br', grande.rede);
  assert.equal(g.fontes[0]!.lida, true);
  assert.match(g.fontes[0]!.detalhe, /lida até 20\.000 caracteres/);
  assert.ok((g.partes[0] as { texto: string }).texto.length < 21_000);

  const vazia = redeFalsa({ 'https://a.com.br/': { corpo: '<div id="root"></div><script src="/app.js"></script>' } });
  const v = await lerSite('a.com.br', vazia.rede);
  assert.equal(v.fontes[0]!.lida, false);
  assert.match(v.fontes[0]!.detalhe, /montar o conteúdo no navegador/);
  assert.equal(v.partes.length, 0);
  assert.ok(POUCO_TEXTO > 0);
});

test('site: o charset que o site declara', async () => {
  const latin = new Uint8Array([...b('<p>'), 0x61, 0xe7, 0xe3, 0x6f, 0x20, ...b(TEXTO_LONGO), ...b('</p>')]);
  const porCabecalho = redeFalsa({ 'https://a.com.br/': { tipo: 'text/html; charset=ISO-8859-1', corpo: latin } });
  assert.match((((await lerSite('a.com.br', porCabecalho.rede)).partes[0]) as { texto: string }).texto, /ação/);
  const porMeta = redeFalsa({ 'https://a.com.br/': { tipo: 'text/html', corpo: new Uint8Array([...b('<meta charset="windows-1252">'), ...latin]) } });
  assert.match((((await lerSite('a.com.br', porMeta.rede)).partes[0]) as { texto: string }).texto, /ação/);
});

// ---------------------------------------------------------------------------
// Materiais e Instagram, como chegam à function
// ---------------------------------------------------------------------------

test('material: PDF e imagem só vão a quem os lê; texto vai a todos', () => {
  const pdf = { nome: 'catalogo.pdf', origem: 'material' as const, base64: b64(PDF) };
  const lido = lerMaterial(pdf, 'anthropic', true);
  assert.deepEqual(lido.parte, { tipo: 'pdf', nome: 'catalogo.pdf', base64: b64(PDF) });
  assert.equal(lido.fonte.lida, true);
  const recusado = lerMaterial(pdf, 'deepseek', false);
  assert.equal(recusado.parte, null);
  assert.match(recusado.fonte.detalhe, /\(deepseek\) não lê PDF nem imagem.*Claude, OpenAI ou OpenRouter/);

  const print = lerMaterial({ nome: 'perfil.jpg', origem: 'instagram', base64: b64(PNG) }, 'openai', true);
  assert.deepEqual(print.parte, { tipo: 'imagem', nome: 'perfil.jpg', mime: 'image/png', base64: b64(PNG) });
  assert.equal(print.fonte.rotulo, 'print do Instagram (perfil.jpg)');

  const txt = lerMaterial({ nome: 'sobre.txt', origem: 'material', base64: b64(new Uint8Array([0x61, 0xe7, 0xe3, 0x6f, 0x0d, 0x0a, 0x6f, 0x6b])) }, 'deepseek', false);
  assert.deepEqual(txt.parte, { tipo: 'texto', texto: '[Arquivo] sobre.txt\nação\nok' });
  const html = lerMaterial({ nome: 'pagina.html', origem: 'material', base64: b64('<title>T</title><script>x()</script><p>Planos</p>') }, 'perplexity', false);
  assert.deepEqual(html.parte, { tipo: 'texto', texto: '[Arquivo] pagina.html\nT\nPlanos' });
});

test('material: o que chega errado é recusado com o nome do arquivo', () => {
  assert.match(lerMaterial({ nome: 'a.pdf', origem: 'material', base64: 'não é base64' }, 'anthropic', true).fonte.detalhe, /corrompido/);
  assert.match(lerMaterial({ nome: 'a.pdf', origem: 'material', base64: b64('<html>') }, 'anthropic', true).fonte.detalhe, /"a\.pdf" não é um PDF/);
  assert.match(lerMaterial({ nome: 'a.exe', origem: 'material', base64: b64('MZ') }, 'anthropic', true).fonte.detalhe, /só PDF/);
  assert.match(lerMaterial({ nome: 'a.txt', origem: 'material', base64: b64('   \n ') }, 'anthropic', true).fonte.detalhe, /não tem texto/);
  const longo = lerMaterial({ nome: 'a.txt', origem: 'material', base64: b64('x'.repeat(TETO_TEXTO_DO_ARQUIVO + 10)) }, 'anthropic', true);
  assert.match(longo.fonte.detalhe, /lido até 40\.000 caracteres/);
  assert.equal((longo.parte as { texto: string }).texto.length, '[Arquivo] a.txt\n'.length + TETO_TEXTO_DO_ARQUIVO);
});

test('instagram: o @ não se lê por robô; o que se lê é o que a pessoa colou', () => {
  assert.deepEqual(lerInstagram('', '  '), { parte: null, fonte: null, conteudo: false });
  const so = lerInstagram('@Corretora.Exemplo', '');
  assert.equal(so.conteudo, false, 'só o @ não vale uma chamada ao modelo');
  assert.deepEqual(so.parte, { tipo: 'texto', texto: '[Instagram] O perfil da empresa no Instagram é @corretora.exemplo.' });
  assert.match(so.fonte!.detalhe, /não deixa ler o perfil por robô/);
  const colado = lerInstagram('https://www.instagram.com/corretora/?hl=pt', 'Planos de saúde em Sorocaba');
  assert.equal(colado.conteudo, true);
  assert.match((colado.parte as { texto: string }).texto, /^\[Instagram\] Perfil @corretora — texto colado.*\nPlanos de saúde em Sorocaba$/s);
  const ruim = lerInstagram('não é um @!', '');
  assert.equal(ruim.fonte!.lida, false);
  assert.equal(ruim.parte, null);
  const ruimComTexto = lerInstagram('não é um @!', 'bio da empresa');
  assert.equal(ruimComTexto.conteudo, true, 'o @ errado não leva junto o texto colado');
  assert.match(ruimComTexto.fonte!.detalhe, /não é um @ do Instagram e ficou de fora/);
  assert.match(lerInstagram('x', 'a'.repeat(6000)).fonte!.detalhe, /lido até 5\.000/);
});

test('sem informação: só quando a resposta É a marca', () => {
  assert.equal(semInformacao(SEM_INFORMACAO), true);
  assert.equal(semInformacao(' [sem informacao]. '), true);
  assert.equal(semInformacao('A Corretora Exemplo vende planos. Sobre preços: [SEM INFORMAÇÃO] nos materiais.'), false);
});

// ---------------------------------------------------------------------------
// O pedido ao modelo, com anexos
// ---------------------------------------------------------------------------

function modeloFalso(respostas: (() => Response)[] = []) {
  const pedidos: { url: string; headers: Headers; corpo: Record<string, unknown>; temPrazo: boolean }[] = [];
  let i = 0;
  const buscar = (async (url: string, init?: RequestInit) => {
    pedidos.push({ url: String(url), headers: new Headers(init?.headers), corpo: JSON.parse(String(init?.body)),
      temPrazo: init?.signal instanceof AbortSignal });
    const r = respostas[i++];
    return r ? r() : new Response(JSON.stringify({ content: [{ type: 'text', text: 'ok' }],
      choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }] }), { status: 200 });
  }) as typeof fetch;
  return { buscar, pedidos };
}

const CRED = { api_key: 'sk-teste', base_url: '' };
const ANEXOS: Parte[] = [
  { tipo: 'texto', texto: 'A empresa se chama X.' },
  { tipo: 'pdf', nome: 'catalogo.pdf', base64: b64(PDF) },
  { tipo: 'imagem', nome: 'p.png', mime: 'image/png', base64: b64(PNG) },
];

test('leitura: quem lê anexo é subconjunto de quem tem adapter', () => {
  for (const p of LEEM_ANEXOS) assert.ok((PROVEDORES_IA_COM_ADAPTER as readonly string[]).includes(p), p);
});

test('leitura: no Claude, os blocos document e image no lugar do texto — o resto é o pedido de ia.ts', async () => {
  const m = modeloFalso();
  const r = await criarLeitor('anthropic', m.buscar).ler({ credenciais: CRED, modelo: 'claude-x', sistema: 'S', partes: ANEXOS, maxTokens: 3000 });
  assert.deepEqual(r, { ok: true, texto: 'ok' });
  const p = m.pedidos[0]!;
  assert.equal(p.url, 'https://api.anthropic.com/v1/messages');
  assert.equal(p.headers.get('x-api-key'), 'sk-teste');
  assert.ok(p.temPrazo);
  assert.deepEqual(p.corpo, {
    model: 'claude-x', max_tokens: 3000, system: 'S',
    messages: [{ role: 'user', content: [
      { type: 'text', text: 'A empresa se chama X.' },
      { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: b64(PDF) } },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: b64(PNG) } },
    ] }],
  });
  assert.deepEqual((p.corpo.messages as { content: unknown }[])[0]!.content, blocosDoClaude(ANEXOS));
});

test('leitura: na OpenAI e no OpenRouter, file e image_url — com o teto de tokens de ia.ts', async () => {
  for (const [provedor, url] of [['openai', 'https://api.openai.com/v1/chat/completions'],
    ['openrouter', 'https://openrouter.ai/api/v1/chat/completions']] as const) {
    const m = modeloFalso();
    await criarLeitor(provedor, m.buscar).ler({ credenciais: CRED, modelo: 'gpt-5.5', sistema: 'S', partes: ANEXOS, maxTokens: 3000 });
    const p = m.pedidos[0]!;
    assert.equal(p.url, url);
    const msgs = p.corpo.messages as { role: string; content: unknown }[];
    assert.deepEqual(msgs[0], { role: 'system', content: 'S' });
    assert.deepEqual(msgs[1]!.content, partesDoChat(ANEXOS));
    assert.deepEqual((msgs[1]!.content as unknown[])[1],
      { type: 'file', file: { filename: 'catalogo.pdf', file_data: `data:application/pdf;base64,${b64(PDF)}` } });
    assert.deepEqual((msgs[1]!.content as unknown[])[2], { type: 'image_url', image_url: { url: `data:image/png;base64,${b64(PNG)}` } });
    if (provedor === 'openai') {
      assert.equal(p.corpo.max_completion_tokens, 6000, 'gpt-5.5 raciocina: a folga de ia.ts vale aqui também');
      assert.equal(p.corpo.reasoning_effort, 'low');
    } else {
      assert.equal(p.corpo.max_tokens, 6000);
    }
  }
});

test('leitura: quem não lê anexo é recusado sem chamar nada; só texto, vai a todos', async () => {
  for (const provedor of ['deepseek', 'perplexity', 'compativel']) {
    const m = modeloFalso();
    const r = await criarLeitor(provedor, m.buscar).ler({ credenciais: { ...CRED, base_url: 'https://x.exemplo.com' },
      modelo: 'm', sistema: 'S', partes: ANEXOS, maxTokens: 100 });
    assert.ok(!r.ok && r.definitivo && /não lê PDF nem imagem/.test(r.erro), provedor);
    assert.equal(m.pedidos.length, 0);
  }
});

test('ponte: só texto, o pedido do leitor É o de criarIa — corpo, URL e cabeçalhos, nos seis provedores', async () => {
  const partes: Parte[] = [{ tipo: 'texto', texto: 'um' }, { tipo: 'texto', texto: 'dois' }];
  for (const provedor of PROVEDORES_IA_COM_ADAPTER) {
    const cred = { api_key: 'k', base_url: provedor === 'compativel' ? 'https://compat.exemplo.com/v1' : '', organizacao: 'org', referer: 'https://r' };
    const a = modeloFalso();
    const b2 = modeloFalso();
    await criarLeitor(provedor, a.buscar).ler({ credenciais: cred, modelo: 'gpt-4o', sistema: 'S', partes, maxTokens: 500 });
    await criarIa(provedor, b2.buscar).compor({ credenciais: cred, modelo: 'gpt-4o', sistema: 'S', mensagem: 'um\n\ndois', maxTokens: 500 });
    assert.equal(a.pedidos[0]!.url, b2.pedidos[0]!.url, provedor);
    assert.deepEqual(a.pedidos[0]!.corpo, b2.pedidos[0]!.corpo, provedor);
    assert.deepEqual([...a.pedidos[0]!.headers], [...b2.pedidos[0]!.headers], provedor);
  }
});

test('ponte: com anexo, o que volta do provedor se lê como em criarIa — erro definitivo é o mesmo', async () => {
  const json = (status: number, corpo: unknown) => () => new Response(JSON.stringify(corpo), { status });
  const casos: [string, () => Response][] = [
    ['401', json(401, { error: { message: 'chave recusada' } })],
    ['400', json(400, { error: { message: 'prompt is too long' } })],
    ['413', json(413, { error: { message: 'request_too_large' } })],
    ['429', json(429, { error: { message: 'devagar' } })],
    ['500', json(500, {})],
    ['recusa claude', json(200, { stop_reason: 'refusal', content: [] })],
    ['cortado claude', json(200, { stop_reason: 'max_tokens', content: [{ type: 'text', text: 'meio' }] })],
    ['vazio claude', json(200, { content: [] })],
    ['recusa chat', json(200, { choices: [{ message: { refusal: 'não' } }] })],
    ['cortado chat', json(200, { choices: [{ message: { content: 'meio' }, finish_reason: 'length' }] })],
    ['pensou chat', json(200, { choices: [{ message: { content: '' }, finish_reason: 'length' }] })],
    ['corpo quebrado', () => new Response('<html>', { status: 502 })],
  ];
  for (const provedor of ['anthropic', 'openai', 'openrouter']) {
    for (const [nome, resposta] of casos) {
      const comAnexo = await criarLeitor(provedor, modeloFalso([resposta]).buscar)
        .ler({ credenciais: CRED, modelo: 'm', sistema: 'S', partes: ANEXOS, maxTokens: 100 });
      const soTexto = await criarIa(provedor, modeloFalso([resposta]).buscar)
        .compor({ credenciais: CRED, modelo: 'm', sistema: 'S', mensagem: 'x', maxTokens: 100 });
      assert.deepEqual(comAnexo, soTexto, `${provedor} ${nome}`);
    }
  }
});

test('leitura: o modelo que não responde no prazo diz isso, e não "aborted"', async () => {
  const pendurado = ((_u: string, init?: RequestInit) => new Promise((_, falha) => {
    init?.signal?.addEventListener('abort', () => falha(init.signal!.reason));
  })) as typeof fetch;
  // O timer de `AbortSignal.timeout` não segura o processo do Node: este segura.
  const vivo = setTimeout(() => undefined, 5000);
  const r = await criarLeitor('anthropic', pendurado, 30).ler({ credenciais: CRED, modelo: 'm', sistema: 'S', partes: ANEXOS, maxTokens: 10 });
  clearTimeout(vivo);
  assert.ok(!r.ok);
  assert.equal(r.erro, 'o modelo não respondeu em 0 s');
  assert.equal(r.definitivo, false);
});
