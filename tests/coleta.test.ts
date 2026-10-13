// Ler a empresa de fora (D78b), sem rede: o que entra como arquivo, que
// endereço de site se lê, como a página vira texto, e o pedido que vai ao
// modelo com os anexos — que é o MESMO de `ia.ts`, só com os blocos trocados.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ACEITA, bytesDoBase64, cabemJuntos, chaveDaPagina, conferirArquivo, conferirEndereco, cortar, decodificarTexto,
  emMb, enderecoInterno, htmlParaTexto, lerInstagram, lerMaterial, lerSite, MAX_ARQUIVOS, paginasParaLer,
  perfilDoInstagram, POUCO_TEXTO, semInformacao, SEM_INFORMACAO, separarConferir, SISTEMA_DA_COLETA,
  tamanhoDoBase64, TETO_DA_PAGINA, TETO_TEXTO_DO_ARQUIVO, TETO_TOTAL, tirarCarenciaSemEscopo,
} from '../adapters/coleta.ts';
import type { RedeDoSite } from '../adapters/coleta.ts';
import { blocosDoClaude, criarLeitor, LEEM_ANEXOS, partesDoChat } from '../adapters/ia-leitura.ts';
import type { Parte } from '../adapters/ia-leitura.ts';
import { criarIa, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';
import { aplicarFreios } from '../adapters/prompt-do-agente.ts';

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
  assert.ok(!binario.ok && /salve como UTF-8/.test(binario.motivo));
});

test('arquivo: o "Texto Unicode" do Excel (UTF-16 com marca) é texto, e se lê', () => {
  const utf16 = new Uint8Array([0xff, 0xfe, ...[...'Ação'].flatMap((c) => [c.charCodeAt(0), 0])]);
  assert.ok(conferirArquivo('tabela.txt', utf16.length, utf16).ok);
  const lido = lerMaterial({ nome: 'tabela.txt', origem: 'material', base64: b64(utf16) }, 'deepseek', false, 'Arquivo A');
  assert.deepEqual(lido.parte, { tipo: 'texto', texto: '[Arquivo A]\nAção' });
});

test('arquivo: o teto é por formato, no teto exato ainda entra, e a recusa nunca diz o tamanho igual ao teto', () => {
  assert.ok(conferirArquivo('a.pdf', 10 * MB, PDF).ok);
  const pdf = conferirArquivo('a.pdf', 10 * MB + 1, PDF);
  assert.ok(!pdf.ok && /tem 10,01 MB; o teto para PDF é 10 MB/.test(pdf.motivo), !pdf.ok ? pdf.motivo : '');
  const pdf2 = conferirArquivo('a.pdf', Math.round(10.04 * MB), PDF);
  assert.ok(!pdf2.ok && /tem 10,04 MB/.test(pdf2.motivo), !pdf2.ok ? pdf2.motivo : '');
  assert.ok(conferirArquivo('a.png', 5 * MB, PNG).ok);
  assert.ok(!conferirArquivo('a.png', 5 * MB + 1, PNG).ok);
  assert.ok(!conferirArquivo('a.txt', MB + 1, b('oi')).ok);
  assert.ok(conferirArquivo('a.html', 2 * MB, b('<html>')).ok);
  assert.equal(emMb(1500), '2 KB');
  assert.equal(emMb(12.5 * MB), '12,5 MB');
});

test('arquivo: nome longo demais é recusado dizendo isso, e não "não é PDF"', () => {
  const nome = `${'Tabela de preços dos planos empresariais '.repeat(6)}.pdf`;
  const r = conferirArquivo(nome, 1000, PDF);
  assert.ok(!r.ok && /nome de arquivo longo demais \(\d+ caracteres; até 200\)/.test(r.motivo), !r.ok ? r.motivo : '');
  assert.ok(conferirArquivo(`${'a'.repeat(196)}.pdf`, 1000, PDF).ok);
});

test('arquivos juntos: quantos e quanto', () => {
  assert.equal(cabemJuntos([]), null);
  assert.equal(cabemJuntos(Array(MAX_ARQUIVOS).fill(1)), null);
  assert.match(cabemJuntos(Array(MAX_ARQUIVOS + 1).fill(1))!, /até 10 arquivos/);
  assert.equal(cabemJuntos([TETO_TOTAL]), null);
  assert.match(cabemJuntos([TETO_TOTAL, 1])!, /somam 15,01 MB; o teto de uma leitura é 15 MB/);
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

test('texto: a marca, depois o rótulo declarado, depois UTF-8 e Windows-1252', () => {
  assert.equal(decodificarTexto(b('ação')), 'ação');
  assert.equal(decodificarTexto(b([0xef, 0xbb, 0xbf, 0x6f, 0x69])), 'oi', 'o BOM sai');
  assert.equal(decodificarTexto(b([0x61, 0xe7, 0xe3, 0x6f])), 'ação');
  // Bytes que SÃO UTF-8 válido, declarados em outro charset: o rótulo manda.
  assert.equal(decodificarTexto(b('ç'), 'windows-1252'), 'Ã§');
  assert.equal(decodificarTexto(b([0xe3]), 'iso-8859-2'), 'ă');
  assert.equal(decodificarTexto(b('ação'), 'rotulo-que-nao-existe'), 'ação');
  // A marca manda mais que o rótulo, como no navegador.
  assert.equal(decodificarTexto(b([0xef, 0xbb, 0xbf, ...b('ação')]), 'iso-8859-1'), 'ação');
  // Página UTF-8 com um byte solto não vira mojibake inteira.
  assert.equal(decodificarTexto(b([...b('São Paulo '), 0xa9]), 'utf-8'), 'São Paulo �');
  // Cortada no meio de um caractere: o pedaço sai, o resto continua UTF-8.
  const cortada = b('carência ç').subarray(0, b('carência ç').length - 1);
  assert.equal(decodificarTexto(cortada, null, true), 'carência ');
  assert.equal(decodificarTexto(cortada, 'utf-8', true), 'carência ');
});

test('cortar: nunca deixa metade de um emoji no fim', () => {
  const s = 'a'.repeat(4999) + '😀 resto';
  assert.equal(cortar(s, 5000), 'a'.repeat(4999));
  assert.equal(cortar(s, 5001), 'a'.repeat(4999) + '😀');
  assert.equal(cortar('curto', 10), 'curto');
  const ig = lerInstagram('empresa', 'a'.repeat(4999) + '😀 resto');
  const texto = (ig.parte as { texto: string }).texto;
  assert.ok(texto.isWellFormed(), 'o texto que vai ao modelo é JSON válido');
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
  assert.doesNotMatch(p.texto, /R\$|color|ícone|ative o JS|Corretora & Cia/);
  assert.match(p.texto, /Atendemos empresas é famílias A\./);
  assert.match(p.texto, /- Plano Bronze\n- Plano Prata/);
  assert.deepEqual(p.links.map((l) => [l.href, l.texto]), [['/sobre', 'Quem somos'], ['/planos', 'Planos']]);
});

test('html: tag de texto não parte o preço — "R$ 189,90" continua inteiro, e o freio lê o valor certo', () => {
  const p = htmlParaTexto('<p>Plano Bronze por R$ <strong>189</strong><sup>,90</sup>/mês</p><p>Ligue<br>agora</p><table><tr><td>A</td><td>B</td></tr></table>');
  assert.equal(p.texto, 'Plano Bronze por R$ 189,90/mês\nLigue\nagora\nA B');
  const contexto = `A Corretora Exemplo vende planos de saúde.\n- ${p.texto.split('\n')[0]}`;
  const base = { proibido: [], tamanho_maximo: null, canal: 'whatsapp', contexto, objetivo: 'resgate' };
  assert.equal(aplicarFreios('O Plano Bronze sai por R$ 189,90 por mês.', base).situacao, 'pronto');
  assert.equal(aplicarFreios('O Plano Bronze sai por R$ 90 por mês.', base).situacao, 'bloqueado');
});

test('html: a fronteira de uma tag de texto separa letra de letra e dígito de dígito — nada de "R$ 8990"', () => {
  const t = (h: string) => htmlParaTexto(h).texto;
  assert.equal(t('<p class="preco">R$ 89<sup>90</sup><small>/mês</small></p>'), 'R$ 89 90/mês');
  assert.equal(t('<p><strong>R$ 99</strong><span>2 vidas</span></p>'), 'R$ 99 2 vidas');
  assert.equal(t('<p>Plano Ouro: R$ 189,90<sup>1</sup> por mês</p>'), 'Plano Ouro: R$ 189,90 1 por mês');
  assert.equal(t('<div><span>Plano 2</span><span>4 vidas</span></div>'), 'Plano 2 4 vidas');
  assert.equal(t('<nav><a href="/">Início</a><a href="/sobre">Sobre</a></nav>'), 'Início Sobre');
  assert.equal(t('<p><a href="tel:1">(11) 4000-1234</a><a href="tel:2">(11) 4000-5678</a></p>'), '(11) 4000-1234 (11) 4000-5678');
  assert.equal(t('<p><b>Planos</b>: a partir de R$<b>99</b>,<sup>90</sup>.</p>'), 'Planos: a partir de R$ 99,90.');
  // O que a página junta continua junto: <wbr>, e-mail, endereço, telefone com hífen.
  assert.equal(t('<p>R$ 15<wbr>0,00</p>'), 'R$ 150,00');
  assert.equal(t('<p>contato@<wbr>corretora.com.br</p>'), 'contato@corretora.com.br');
  assert.equal(t('<p>contato<span>@</span>corretora.com.br</p>'), 'contato@corretora.com.br');
  assert.equal(t('<p>www.<b>corretora</b>.com.br</p>'), 'www.corretora.com.br');
  assert.equal(t('<p><b>0800</b>-<b>777</b>-<b>1234</b></p>'), '0800-777-1234');
  assert.equal(t('<p>Pós</b>-venda</p>'), 'Pós-venda');
  assert.equal(t('<p>Fim.<b>Novo</b> parágrafo</p>'), 'Fim. Novo parágrafo');
  const contexto = `A Corretora Exemplo vende planos.\n- ${t('<p><strong>R$ 99</strong><span>2 vidas</span></p>')}`;
  const base = { proibido: [], tamanho_maximo: null, canal: 'whatsapp', contexto, objetivo: 'resgate' };
  assert.equal(aplicarFreios('O plano custa R$ 992 por mês.', base).situacao, 'bloqueado', 'número que a página não escreve');
});

test('html: o svg que não fecha não leva o resto da página; o script que não fecha, sim — como no navegador', () => {
  assert.equal(htmlParaTexto('<body><svg class="i"/><h1>Plano Ouro</h1><p>R$ 189,90 por mês</p></body>').texto, 'Plano Ouro\nR$ 189,90 por mês');
  assert.match(htmlParaTexto('<p>Antes</p><svg class="i"><path d="M0"><p>Depois do svg aberto</p>').texto, /Depois do svg aberto/);
  assert.equal(htmlParaTexto('<title>Só título').titulo, '');
  // A página cortada no teto termina dentro do JSON de hidratação: ele não é texto do site.
  const cortada = '<h1>Corretora Exemplo</h1><p>Plano Bronze a partir de R$ 189,90 por mês.</p>'
    + '<script type="application/json" id="wix-warmup-data">{"planos":[{"nome":"Ouro (fora do ar)","preco":"R$ 99,90","carencia":"sem carência"';
  const t = htmlParaTexto(cortada).texto;
  assert.equal(t, 'Corretora Exemplo\nPlano Bronze a partir de R$ 189,90 por mês.');
  for (const tag of ['style', 'noscript', 'iframe', 'template']) {
    assert.doesNotMatch(htmlParaTexto(`<p>Antes</p><${tag}>escondido`).texto, /escondido/, tag);
  }
});

test('html: a página que repete a mesma linha seguida não a repete no texto', () => {
  const p = htmlParaTexto('<p>Ligue</p><p>Ligue</p><p>Agora</p><p>Ligue</p>');
  assert.equal(p.texto, 'Ligue\nAgora\nLigue');
});

test('html: HTML hostil de 2 MB custa o mesmo que HTML comum do mesmo tamanho — medido na mesma execução', () => {
  const melhor = (html: string) => {
    let m = Infinity;
    for (let k = 0; k < 3; k++) { const t0 = performance.now(); htmlParaTexto(html); m = Math.min(m, performance.now() - t0); }
    return m;
  };
  const comum = melhor(`<html><body>${'<div class="x"><p>Planos de saúde para famílias e <b>empresas</b>.</p><a href="/sobre">Sobre</a></div>'.repeat(2 * MB / 90)}</body></html>`);
  const casos: [string, string][] = [
    ['meta com atributo sem =', `<meta ${'a'.repeat(2 * MB)}>`],
    ['link com atributo sem =', `<a ${'x'.repeat(2 * MB)}>sobre</a>`],
    ['comentários sem fechar', '<!--'.repeat(MB / 2)],
    ['estilos sem fechar', '<style>'.repeat(MB / 4)],
    ['links sem fechar', '<a href="/x">'.repeat(MB / 8)],
    ['muitos meta', '<meta name="description" content="x">'.repeat(MB / 20)],
    ['entidade sem ponto e vírgula', `&${'a'.repeat(2 * MB)}`],
    ['muitos <', '<'.repeat(2 * MB)],
    ['< com espaço', '< '.repeat(MB)],
    ['< com dígito', '<1'.repeat(MB)],
    ['parágrafos vazios', '<p>'.repeat(2 * MB / 3)],
  ];
  // O quadrático de antes custava 10 a 100 vezes o comum; a varredura linear fica perto dele.
  for (const [nome, html] of casos) {
    const ms = melhor(html);
    assert.ok(ms < Math.max(6 * comum, 60), `${nome}: ${Math.round(ms)} ms, contra ${Math.round(comum)} ms do comum`);
  }
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
    { href: '/#sobre', texto: 'Sobre nós' },
    { href: 'http://www.empresa.com.br/#planos', texto: 'Planos' },
    { href: '/servi%C3%A7os', texto: '' },
  ];
  assert.deepEqual(paginasParaLer(links, base).map((u) => u.href), [
    'https://www.empresa.com.br/institucional/quem-somos',
    'https://www.empresa.com.br/sobre?x=1',
    'https://empresa.com.br/planos',
  ], 'a âncora da própria inicial (/#sobre, http://www…/#planos) não é página nova');
});

test('html: rótulo de várias palavras sobre caminho neutro, e post de blog não é "sobre"', () => {
  const base = new URL('https://empresa.com.br/');
  const wp = paginasParaLer([
    { href: '/?page_id=12', texto: 'Quem Somos' }, { href: '/empresa', texto: 'A Empresa' },
    { href: '/?page_id=20', texto: 'Fale conosco' }, { href: '/historia', texto: 'Nossa história' },
  ], base, 4).map((u) => u.href);
  assert.deepEqual(wp, ['https://empresa.com.br/?page_id=12', 'https://empresa.com.br/empresa',
    'https://empresa.com.br/historia', 'https://empresa.com.br/?page_id=20']);
  const blog = paginasParaLer([
    { href: '/blog/tudo-sobre-o-plano-x', texto: 'Tudo sobre o plano X' },
    { href: '/noticias/sobre-a-ans', texto: 'Sobre a ANS' },
    { href: '/planos', texto: 'Planos' }, { href: '/contato', texto: 'Contato' },
  ], base).map((u) => u.href);
  assert.deepEqual(blog, ['https://empresa.com.br/planos', 'https://empresa.com.br/contato']);
});

test('html: o slug da página conta pedaço a pedaço, com plural, extensão e "sobre-…"', () => {
  const base = new URL('https://www.empresa.com.br/');
  for (const [href, texto] of [['/contatos', 'Contatos'], ['/nossa-empresa', 'Nossa Empresa'], ['/sobre-a-escola/', 'A Escola'],
    ['/sobre-o-escritorio/', 'O Escritório'], ['/contatos/', 'Fale com a gente'], ['/quemsomos.php', ''],
    ['/sobre.php', 'Conheça a Clínica'], ['/nossosservicos.html', ''], ['/?page_id=13', 'Contatos'], ['/planos-de-saude', ''],
    ['/?page_id=13', 'Entre em contato'], ['/?page_id=7', 'Conheça nossos planos'], ['/?page_id=9', 'Nossas soluções'],
    ['/?page_id=5', 'Conheça a empresa'], ['/?page_id=4', 'Saiba mais sobre nós'], ['/conheca-nossos-planos/', 'Ver todos'],
    ['/fale-com-a-gente/', 'Entre em contato'], ['/nossas-solucoes/', 'Nossas Soluções'], ['/planos2025', 'Clique aqui']]) {
    assert.equal(paginasParaLer([{ href: href!, texto: texto! }], base).length, 1, href);
  }
});

test('html: post de blog na raiz não toma a vaga da página de planos — título tem palavras demais para ser página', () => {
  const base = new URL('https://www.corretora.com.br/');
  // O permalink padrão do WordPress é /%postname%/, fora de /blog/, e a página inicial lista os recentes.
  const menu = [
    { href: '/', texto: 'Início' }, { href: '/quem-somos/', texto: 'Quem Somos' },
    { href: '/planos-de-saude/', texto: 'Planos de Saúde' }, { href: '/seguros/', texto: 'Seguros' }, { href: '/contato/', texto: 'Contato' },
  ];
  const posts = [
    { href: '/plano-de-saude-empresarial-o-que-a-empresa-precisa-saber/', texto: 'Plano de saúde empresarial: o que a empresa precisa saber' },
    { href: '/quanto-custa-um-plano-de-saude-para-a-empresa/', texto: 'Leia mais' },
    { href: '/a-historia-dos-planos-de-saude-no-brasil/', texto: 'A história dos planos de saúde no Brasil' },
    { href: '/como-escolher-a-empresa-do-seu-plano/', texto: 'Leia mais' },
    { href: '/seguro-de-vida-vale-a-pena/', texto: 'Seguro de vida: vale a pena?' },
  ];
  assert.deepEqual(paginasParaLer([...menu, ...posts], base).map((u) => u.pathname), ['/quem-somos/', '/planos-de-saude/', '/seguros/']);
  // Com um menu curto, o título que fala de planos não passa a página de contato — nem antes dela na página.
  assert.deepEqual(paginasParaLer([
    { href: '/a-historia-dos-planos-de-saude-no-brasil/', texto: 'Leia mais' },
    { href: '/plano-de-saude-empresarial-o-que-a-empresa-precisa-saber/', texto: 'Leia mais' },
    { href: '/planos/', texto: 'Planos' }, { href: '/quem-somos/', texto: 'Quem Somos' }, { href: '/contato/', texto: 'Contato' },
  ], base).map((u) => u.pathname), ['/quem-somos/', '/planos/', '/contato/']);
  // A página de plano com slug longo é página: no menu (<nav>) conta inteira, e fora dele só fica abaixo de
  // contato — ocupa a vaga que sobrou, em vez de sumir.
  const home = htmlParaTexto(`<header><nav><ul>
    <li><a href="/quem-somos/">Quem Somos</a></li>
    <li><a href="/plano-de-saude-individual-e-familiar/">Individual e Familiar</a></li>
    <li><a href="/plano-de-saude-para-pequenas-empresas/">Plano de Saúde para Pequenas Empresas</a></li>
    <li><a href="/contato/">Contato</a></li></ul></nav></header>
    <main><article><header><h2><a href="/plano-de-saude-empresarial-o-que-a-empresa-precisa-saber/">Plano de saúde empresarial: o que a empresa precisa saber</a></h2></header></article></main>`);
  assert.deepEqual(home.links.map((l) => Boolean(l.menu)), [true, true, true, true, false]);
  // O widget "Posts recentes" do WordPress (5.5+) também é um <nav>: dentro de <aside>, rotulado de posts ou com
  // título longo demais para item de menu, ele não é menu — e o post não toma a vaga de planos nem de contato.
  const menuPrincipal = `<header><nav aria-label="Menu principal"><ul><li><a href="/quem-somos/">Quem Somos</a></li>
    <li><a href="/planos/">Planos</a></li><li><a href="/contato/">Contato</a></li></ul></nav></header>`;
  const doBlog = `<ul>
    <li><a href="/a-empresa-pode-cancelar-o-plano-de-saude-do-funcionario/">A empresa pode cancelar o plano de saúde do funcionário?</a></li>
    <li><a href="/historia-dos-planos-de-saude-no-brasil-o-que-mudou/">História dos planos de saúde no Brasil: o que mudou</a></li>
    <li><a href="/quanto-custa-um-plano-de-saude-para-a-empresa/">Quanto custa um plano de saúde para a empresa</a></li></ul>`;
  for (const widget of [
    `<aside class="widget-area"><section class="widget widget_recent_entries"><nav aria-label="Menu">${doBlog}</nav></section></aside>`,
    // O título do widget é o rótulo, e quem o escreveu não precisa dizer "posts".
    `<aside><section class="widget widget_recent_entries"><nav aria-label="Leia também"><ul>
      <li><a href="/seguro-de-vida-vale-a-pena/">Seguro de vida: vale a pena?</a></li></ul></nav></section></aside>`,
    // Título curto e slug longo: só o rótulo do <nav> separa o widget do menu.
    `<footer><nav aria-label="Posts recentes"><ul><li><a href="/seguro-de-vida-vale-a-pena/">Seguro de vida: vale a pena?</a></li></ul></nav></footer>`,
    `<footer><nav>${doBlog}</nav></footer>`,
  ]) {
    assert.deepEqual(paginasParaLer(htmlParaTexto(menuPrincipal + widget).links, base).map((u) => u.pathname),
      ['/quem-somos/', '/planos/', '/contato/'], widget);
  }
  // O menu de páginas também mora em <aside> (o widget "Menu de navegação" e o bloco Navegação), depois dos
  // posts do <main> — e continua menu, com o slug que tiver.
  for (const rodape of [
    `<aside class="widget-area"><section class="widget widget_nav_menu"><nav aria-label="Planos"><ul>`,
    `<aside class="widget-area"><nav class="wp-block-navigation" aria-label="Navegação"><ul>`,
  ]) {
    const pagina = htmlParaTexto(`<header><nav aria-label="Menu principal"><a href="/">Início</a><a href="/quem-somos/">Quem Somos</a>
      <a href="/blog/">Blog</a><a href="/contato/">Contato</a></nav></header>
      <main><a href="/plano-de-saude-empresarial-o-que-a-empresa-precisa-saber/">Plano de saúde empresarial: o que a empresa precisa saber</a>
      <a href="/quanto-custa-um-plano-de-saude-para-a-empresa/">Quanto custa um plano de saúde para a empresa</a></main>
      ${rodape}<li><a href="/plano-de-saude-individual-e-familiar/">Individual e Familiar</a></li>
      <li><a href="/plano-de-saude-para-pequenas-empresas/">Pequenas Empresas</a></li></ul></nav></aside>`);
    assert.deepEqual(paginasParaLer(pagina.links, base).map((u) => u.pathname),
      ['/quem-somos/', '/plano-de-saude-individual-e-familiar/', '/plano-de-saude-para-pequenas-empresas/'], rodape);
  }
  // Nome de produto de 7 e 8 palavras, sob um "Planos" que não leva a lugar nenhum, ainda é item de menu.
  const submenu = htmlParaTexto(`<nav aria-label="Menu principal"><a href="/quem-somos/">Quem Somos</a><a href="#">Planos</a>
    <a href="/plano-de-saude-para-pequenas-e-medias-empresas/">Plano de Saúde para Pequenas e Médias Empresas</a>
    <a href="/seguro-de-vida-em-grupo-para-empresas/">Seguro de Vida em Grupo para Empresas</a><a href="/contato/">Contato</a></nav>`);
  assert.deepEqual(paginasParaLer(submenu.links, base).map((u) => u.pathname),
    ['/quem-somos/', '/plano-de-saude-para-pequenas-e-medias-empresas/', '/seguro-de-vida-em-grupo-para-empresas/']);
  // E o menu continua menu depois do <aside> e do <nav> de widget fecharem.
  const depois = htmlParaTexto(`<aside><nav aria-label="Arquivos">${doBlog}</nav></aside><nav><a href="/x">X</a></nav>`).links;
  assert.deepEqual(depois.map((l) => Boolean(l.menu)), [false, false, false, true]);
  assert.deepEqual(paginasParaLer(home.links, base).map((u) => u.pathname),
    ['/quem-somos/', '/plano-de-saude-individual-e-familiar/', '/plano-de-saude-para-pequenas-empresas/']);
  assert.deepEqual(paginasParaLer([
    { href: '/quem-somos/', texto: 'Quem Somos' }, { href: '/seguro-de-vida-em-grupo-para-empresas/', texto: 'Saiba mais' },
    { href: '/fale-conosco/', texto: 'Fale conosco' },
  ], base).map((u) => u.pathname), ['/quem-somos/', '/fale-conosco/', '/seguro-de-vida-em-grupo-para-empresas/']);
  // Os ambíguos valem só no começo: "a empresa" e "história" no meio de um nome curto também não são a página sobre.
  for (const href of ['/dicas-para-a-empresa/', '/a-historia-do-sus/', '/video-institucional/']) {
    assert.deepEqual(paginasParaLer([{ href, texto: 'Leia mais' }], base), [], href);
  }
  for (const href of ['/a-empresa/', '/historia/', '/institucional/', '/conheca-a-empresa/', '/conheca-quem-somos/']) {
    assert.equal(paginasParaLer([{ href, texto: 'Leia mais' }], base).length, 1, href);
  }
});

test('html: link com porta, usuário e senha ou rede social não vira página extra', () => {
  const base = new URL('https://empresa.com.br/');
  const r = paginasParaLer([
    { href: 'https://empresa.com.br:6379/sobre', texto: 'Sobre' },
    { href: 'http://empresa.com.br:22/planos', texto: 'Planos' },
    { href: 'https://u:p@empresa.com.br/contato', texto: 'Contato' },
    { href: 'https://instagram.com/empresa', texto: 'Sobre nós no Instagram' },
  ], base);
  assert.deepEqual(r, []);
});

test('html: a chave de uma página ignora www, esquema, barra do fim e rastreio', () => {
  const k = (s: string) => chaveDaPagina(new URL(s));
  assert.equal(k('http://www.empresa.com.br/contato/'), k('https://empresa.com.br/contato'));
  assert.equal(k('https://empresa.com.br/planos?utm_source=ig&fbclid=x'), k('https://empresa.com.br/planos'));
  assert.notEqual(k('https://empresa.com.br/?page_id=12'), k('https://empresa.com.br/?page_id=20'));
});

// ---------------------------------------------------------------------------
// O endereço
// ---------------------------------------------------------------------------

test('endereço: só https, e o que o texto já entrega como não público é recusado antes da rede', () => {
  const ok = (s: string) => { const r = conferirEndereco(s); assert.ok(r.ok, `${s}: ${r.ok ? '' : r.motivo}`); return r.url.href; };
  const nao = (s: string, re: RegExp, promover = true) => {
    const r = conferirEndereco(s, promover);
    assert.ok(!r.ok && re.test(r.motivo), `${s}: ${r.ok ? 'aceito' : r.motivo}`);
  };
  assert.equal(ok('www.empresa.com.br'), 'https://www.empresa.com.br/');
  assert.equal(ok(' http://empresa.com/planos#topo '), 'https://empresa.com/planos', 'o http digitado vira https');
  nao('http://empresa.com/planos', /só se lê site por https/, false);
  assert.equal(ok('https://xn--caf-dma.com.br'), 'https://xn--caf-dma.com.br/');
  ok('https://café.com.br');
  nao('', /vazio/);
  nao(`https://empresa.com.br/${'x'.repeat(2001)}`, /longo demais/);
  nao('ftp://empresa.com.br', /só se lê endereço de site/);
  nao('javascript:alert(1)', /não é o endereço de um site público|não é um endereço|só se lê/);
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

test('endereço: Instagram e Facebook não se leem por robô, nem digitados no campo do site', () => {
  for (const s of ['instagram.com/corretoraexemplo', 'https://www.instagram.com/corretora/', 'instagr.am/x']) {
    const r = conferirEndereco(s);
    assert.ok(!r.ok && /Instagram não se lê por robô/.test(r.motivo), s);
  }
  const fb = conferirEndereco('https://m.facebook.com/corretora');
  assert.ok(!fb.ok && /Facebook não se lê por robô/.test(fb.motivo));
});

test('endereço: para onde o domínio aponta — no IPv6, público é só o unicast global', () => {
  for (const ip of ['10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.0.10', '127.0.0.1', '0.0.0.0',
    '169.254.169.254', '100.64.0.1', '100.127.255.255', '198.18.0.1', '224.0.0.1', '255.255.255.255',
    '192.0.2.1', '203.0.113.9', '::', '::1', 'fe80::1', 'febf::1', 'fc00::1', 'fd12:3456::1', 'ff02::1',
    '::ffff:127.0.0.1', '::ffff:7f00:1', '::ffff:10.0.0.1', '64:ff9b::a9fe:a9fe', '2001:db8::1', '::2',
    '::ffff:0:7f00:1', '64:ff9b:1::7f00:1', '2002:a9fe:a9fe::1', '2002:0a00:0001::1', 'fec0::1',
    '2001:0:4136:e378:8000:63bf:3fff:fdd2', '100::1',
    'lixo', '1.2.3', '1.2.3.256', ':::1', '1::2::3']) {
    assert.equal(enderecoInterno(ip), true, ip);
  }
  for (const ip of ['8.8.8.8', '172.32.0.1', '100.128.0.1', '200.147.67.142', '2001:4860:4860::8888',
    '2606:4700::6810:84e5', '::ffff:8.8.8.8', '64:ff9b::808:808', '2002:0808:0808::1']) {
    assert.equal(enderecoInterno(ip), false, ip);
  }
});

// ---------------------------------------------------------------------------
// O site, com a rede de mentira
// ---------------------------------------------------------------------------

interface Pagina { status?: number; tipo?: string; corpo?: string | Uint8Array; destino?: string; lancar?: unknown; demoraMs?: number }

function redeFalsa(paginas: Record<string, Pagina>, dns: Record<string, string[] | 'lança'> = {}, extra: Partial<RedeDoSite> = {}) {
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
      if (p?.demoraMs) {
        await new Promise((ok, falha) => {
          const t = setTimeout(ok, p.demoraMs);
          init?.signal?.addEventListener('abort', () => { clearTimeout(t); falha(init.signal!.reason); });
        });
      }
      if (!p) return new Response('não achei', { status: 404, headers: { 'content-type': 'text/html' } });
      if (p.lancar) throw p.lancar;
      if (p.destino !== undefined) return new Response(null, { status: p.status ?? 301, headers: p.destino ? { location: p.destino } : {} });
      return new Response(p.corpo ?? '', { status: p.status ?? 200, headers: { 'content-type': p.tipo ?? 'text/html; charset=utf-8' } });
    }) as typeof fetch,
    ...extra,
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
  assert.match((r.partes[0] as { texto: string }).texto, /^\[Site A\]\nTítulo: Empresa\n/);
  assert.deepEqual(r.fontes.map((f) => f.apelido), ['Site A', 'Site B', 'Site C', undefined]);
  assert.match(r.fontes[2]!.detalhe, /quase não tem texto/, 'página curta diz que chegou curta');
});

test('site: redirecionamento é seguido, e cada salto é conferido de novo — inclusive o https', async () => {
  const ida = redeFalsa({
    'https://empresa.com.br/': { destino: 'https://www.empresa.com.br/' },
    'https://www.empresa.com.br/': { corpo: `<p>${TEXTO_LONGO}</p>` },
  });
  const r = await lerSite('http://empresa.com.br', ida.rede);
  assert.deepEqual(ida.pedidos.map((p) => p.url), ['https://empresa.com.br/', 'https://www.empresa.com.br/'],
    'o http digitado é lido por https');
  assert.equal(r.fontes[0]!.rotulo, 'https://www.empresa.com.br/');
  assert.equal(r.fontes[0]!.lida, true);

  // O site que manda para http: o rebinding passaria por aí sem certificado nenhum.
  const http = redeFalsa({ 'https://empresa.com.br/': { destino: 'http://empresa.com.br/home' } });
  const h = await lerSite('empresa.com.br', http.rede);
  assert.match(h.fontes[0]!.detalhe, /redirecionou para um endereço que não se lê \(só se lê site por https\)/);
  assert.equal(http.pedidos.length, 1);

  // O salto para o IP de metadados é recusado SEM ser buscado.
  const meta = redeFalsa({ 'https://empresa.com.br/': { destino: 'https://169.254.169.254/latest/meta-data/' } });
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

  // O domínio que manda para o Instagram: não se lê.
  const ig = redeFalsa({ 'https://corretora.com.br/': { destino: 'https://www.instagram.com/corretoraexemplo/' } });
  const i = await lerSite('corretora.com.br', ig.rede);
  assert.match(i.fontes[0]!.detalhe, /Instagram não se lê por robô/);
  assert.equal(ig.pedidos.length, 1);

  const laco = redeFalsa({ 'https://a.com.br/': { destino: 'https://a.com.br/x' }, 'https://a.com.br/x': { destino: 'https://a.com.br/' } });
  assert.match((await lerSite('a.com.br', laco.rede)).fontes[0]!.detalhe, /vezes demais/);
  const semDestino = redeFalsa({ 'https://a.com.br/': { status: 302, destino: '' } });
  assert.match((await lerSite('a.com.br', semDestino.rede)).fontes[0]!.detalhe, /sem dizer para onde/);
});

test('site: a página extra que redireciona para uma já lida não é lida de novo', async () => {
  const { rede, pedidos } = redeFalsa({
    'https://empresa.com.br/': { corpo: `<p>${TEXTO_LONGO}</p><a href="/sobre">Sobre</a><a href="/planos">Planos</a>` },
    'https://empresa.com.br/sobre': { destino: 'https://empresa.com.br/' },
    'https://empresa.com.br/planos': { corpo: `<p>${TEXTO_LONGO}</p>` },
  });
  const r = await lerSite('empresa.com.br', rede);
  assert.equal(pedidos.length, 4);
  assert.deepEqual(r.fontes.map((f) => f.rotulo), ['https://empresa.com.br/', 'https://empresa.com.br/planos']);
  assert.equal(r.partes.length, 2);
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
  assert.match((await lerSite('a.com.br', caiu.rede)).fontes[0]!.detalhe, /não foi possível conectar ao site por https/);

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

  // Título e descrição longos não fazem de uma página vazia uma página lida sem aviso.
  const titulada = redeFalsa({ 'https://a.com.br/': { corpo: `<title>${'Corretora Exemplo — planos '.repeat(3)}</title>`
    + `<meta name="description" content="${'Planos de saúde em Sorocaba. '.repeat(6)}"><div id="root"></div>` } });
  const t = await lerSite('a.com.br', titulada.rede);
  assert.equal(t.fontes[0]!.lida, true);
  assert.match(t.fontes[0]!.detalhe, /^0 caracteres; a página quase não tem texto/);
});

test('site: os bytes da página param no teto — o que vem depois nunca é lido', async () => {
  const antes = '<p>Começo da página, com carência explicada.</p>';
  const recheio = ' '.repeat(TETO_DA_PAGINA - b(antes).length - 1);
  // O "ç" (2 bytes) começa no último byte do teto: fica partido no corte.
  const corpo = `${antes}${recheio}ç<p>DEPOIS DO TETO</p>`;
  const { rede } = redeFalsa({ 'https://a.com.br/': { corpo } });
  const r = await lerSite('a.com.br', rede);
  const texto = (r.partes[0] as { texto: string }).texto;
  assert.doesNotMatch(texto, /DEPOIS DO TETO/);
  assert.match(texto, /carência explicada/, 'UTF-8 cortado no meio de um caractere não vira mojibake');
  assert.match(r.fontes[0]!.detalhe, /lida até/);
});

test('site: a leitura inteira tem prazo, somando saltos e páginas extras', async () => {
  const { rede } = redeFalsa({
    'https://a.com.br/': { corpo: `<p>${TEXTO_LONGO}</p><a href="/sobre">Sobre</a>` },
    'https://a.com.br/sobre': { corpo: `<p>${TEXTO_LONGO}</p>`, demoraMs: 2000 },
  }, {}, { prazoTotalMs: 150 });
  const vivo = setTimeout(() => undefined, 5000);
  const t0 = performance.now();
  const r = await lerSite('a.com.br', rede);
  clearTimeout(vivo);
  assert.ok(performance.now() - t0 < 1500);
  assert.equal(r.fontes[0]!.lida, true);
  assert.match(r.fontes[1]!.detalhe, /a leitura do site passou de 0 s e parou aqui/);
});

test('site: o charset que o site declara', async () => {
  const latin = new Uint8Array([...b('<p>'), 0x61, 0xe7, 0xe3, 0x6f, 0x20, ...b(TEXTO_LONGO), ...b('</p>')]);
  const porCabecalho = redeFalsa({ 'https://a.com.br/': { tipo: 'text/html; charset=ISO-8859-1', corpo: latin } });
  assert.match((((await lerSite('a.com.br', porCabecalho.rede)).partes[0]) as { texto: string }).texto, /ação/);
  const porMeta = redeFalsa({ 'https://a.com.br/': { tipo: 'text/html', corpo: new Uint8Array([...b('<meta charset="windows-1252">'), ...latin]) } });
  assert.match((((await lerSite('a.com.br', porMeta.rede)).partes[0]) as { texto: string }).texto, /ação/);
  // O rótulo tem de MANDAR: UTF-8 válido declarado como iso-8859-2 é lido como iso-8859-2.
  const declarado = new Uint8Array([...b('<p>'), 0xe3, 0x20, ...b(TEXTO_LONGO), ...b('</p>')]);
  const l2 = redeFalsa({ 'https://a.com.br/': { tipo: 'text/html; charset=iso-8859-2', corpo: declarado } });
  assert.match((((await lerSite('a.com.br', l2.rede)).partes[0]) as { texto: string }).texto, /^\[Site A\]\nă /m);
  const m2 = redeFalsa({ 'https://a.com.br/': { tipo: 'text/html', corpo: new Uint8Array([...b('<meta charset="iso-8859-2">'), ...declarado]) } });
  assert.match((((await lerSite('a.com.br', m2.rede)).partes[0]) as { texto: string }).texto, /\nă /);
});

// ---------------------------------------------------------------------------
// Materiais e Instagram, como chegam à function
// ---------------------------------------------------------------------------

test('material: PDF e imagem só vão a quem os lê, com um apelido sem dígito que o modelo cita; texto vai a todos', () => {
  const pdf = { nome: 'Tabela_Precos_2025_v350.pdf', origem: 'material' as const, base64: b64(PDF) };
  const lido = lerMaterial(pdf, 'anthropic', true, 'Arquivo B');
  assert.deepEqual(lido.parte, { tipo: 'pdf', nome: 'Arquivo B.pdf', rotulo: '[Arquivo B]', base64: b64(PDF) });
  assert.equal(lido.fonte.lida, true);
  assert.equal(lido.fonte.apelido, 'Arquivo B');
  assert.equal(lido.fonte.rotulo, 'Tabela_Precos_2025_v350.pdf', 'a tela mostra o nome de verdade');
  const recusado = lerMaterial(pdf, 'deepseek', false, 'Arquivo B');
  assert.equal(recusado.parte, null);
  assert.match(recusado.fonte.detalhe, /\(deepseek\) não lê PDF nem imagem.*Claude, OpenAI ou OpenRouter/);

  const print = lerMaterial({ nome: 'IMG_4521.jpg', origem: 'instagram', base64: b64(PNG) }, 'openai', true, 'Print A');
  assert.deepEqual(print.parte, { tipo: 'imagem', nome: 'Print A', rotulo: '[Print A]', mime: 'image/png', base64: b64(PNG) });
  assert.equal(print.fonte.rotulo, 'print do Instagram (IMG_4521.jpg)');

  const txt = lerMaterial({ nome: 'sobre_2025.txt', origem: 'material', base64: b64(new Uint8Array([0x61, 0xe7, 0xe3, 0x6f, 0x0d, 0x0a, 0x6f, 0x6b])) }, 'deepseek', false, 'Arquivo A');
  assert.deepEqual(txt.parte, { tipo: 'texto', texto: '[Arquivo A]\nação\nok' });
  const html = lerMaterial({ nome: 'pagina.html', origem: 'material', base64: b64('<title>T</title><script>x()</script><p>Planos</p>') }, 'perplexity', false, 'Arquivo C');
  assert.deepEqual(html.parte, { tipo: 'texto', texto: '[Arquivo C]\nT\nPlanos' });
  // O número do nome do arquivo nunca chega ao modelo: na linha do preço, o freio o aceitaria como valor.
  for (const r of [lido, print, txt]) {
    const p = r.parte as { nome?: string; rotulo?: string; texto?: string };
    assert.doesNotMatch(`${p.nome ?? ''} ${p.rotulo ?? ''} ${p.texto ?? ''}`, /\d/);
  }
});

test('material: o que chega errado é recusado com o nome do arquivo', () => {
  const ler = (nome: string, base64: string) => lerMaterial({ nome, origem: 'material', base64 }, 'anthropic', true, 'Arquivo A');
  assert.match(ler('a.pdf', 'não é base64').fonte.detalhe, /corrompido/);
  assert.match(ler('a.pdf', b64('<html>')).fonte.detalhe, /"a\.pdf" não é um PDF/);
  assert.match(ler('a.exe', b64('MZ')).fonte.detalhe, /só PDF/);
  assert.match(ler('a.txt', b64('   \n ')).fonte.detalhe, /não tem texto/);
  const longo = ler('a.txt', b64('x'.repeat(TETO_TEXTO_DO_ARQUIVO + 10)));
  assert.match(longo.fonte.detalhe, /lido até 40\.000 caracteres/);
  assert.equal((longo.parte as { texto: string }).texto.length, '[Arquivo A]\n'.length + TETO_TEXTO_DO_ARQUIVO);
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

test('instagram: link de publicação no campo do perfil não vira "@p"', () => {
  for (const s of ['https://www.instagram.com/p/C8xYz12AbC/?igsh=abc', 'instagram.com/reel/X/', 'https://instagram.com/stories/x/1']) {
    const p = perfilDoInstagram(s);
    assert.match(p.motivo ?? '', /link de uma publicação/, s);
    const r = lerInstagram(s, '');
    assert.equal(r.parte, null);
    assert.equal(r.fonte!.lida, false);
  }
  for (const s2 of ['https://www.instagram.com/s/aGlnaGxpZ2h0OjE4MDQ1?story_media_id=123&igsh=abc',
    'https://www.instagram.com/share/BAm3XyZ12/', 'https://www.instagram.com/corretora/p/C8x/']) {
    assert.match(perfilDoInstagram(s2).motivo ?? '', /link de uma publicação/, s2);
  }
  assert.deepEqual(perfilDoInstagram('https://www.instagram.com/corretora/reels/'), { handle: 'corretora', motivo: null });
  // O "Compartilhar perfil" do próprio app: é o perfil.
  assert.deepEqual(perfilDoInstagram('https://www.instagram.com/corretoraexemplo/profilecard/?igsh=MWZtOXpzcjZkMWVoMg=='),
    { handle: 'corretoraexemplo', motivo: null });
  assert.deepEqual(perfilDoInstagram('https://www.instagram.com/corretora/ nosso perfil'), { handle: 'corretora', motivo: null });
  assert.deepEqual(perfilDoInstagram('@corretora'), { handle: 'corretora', motivo: null });
  assert.deepEqual(perfilDoInstagram(''), { handle: '', motivo: null });
  const comTexto = lerInstagram('https://www.instagram.com/reel/X/', 'bio');
  assert.equal(comTexto.fonte!.rotulo, 'perfil do Instagram');
});

// ---------------------------------------------------------------------------
// O que se pede, e o que volta
// ---------------------------------------------------------------------------

test('sem informação: só quando a resposta É a marca', () => {
  assert.equal(semInformacao(SEM_INFORMACAO), true);
  assert.equal(semInformacao(' [sem informacao]. '), true);
  assert.equal(semInformacao('A Corretora Exemplo vende planos. Sobre preços: [SEM INFORMAÇÃO] nos materiais.'), false);
});

test('divergência sai do texto: o que vem depois de PARA CONFERIR não entra no agente, escrito como for', () => {
  const corpo = 'A Corretora Exemplo vende planos.\n- Plano Bronze (Site A).';
  const div = '- Essencial: R$ 289,90 (Site A) e R$ 249,90 (Arquivo B)';
  for (const marca of ['PARA CONFERIR:', '**PARA CONFERIR:**', '**PARA CONFERIR**:', '5. PARA CONFERIR:', 'PARA CONFERIR (divergências):',
    'PARA CONFERIR', 'PARA CONFERIR：', '### PARA CONFERIR', 'PARA CONFERIR —', '**Para conferir**:', 'Para conferir:']) {
    const r = separarConferir(`${corpo}\n\n${marca}\n${div}`);
    assert.equal(r.texto, corpo, marca);
    assert.equal(r.conferir, div, marca);
  }
  // O marcador no fim de uma linha leva a linha INTEIRA: o que vinha antes é a versão disputada.
  const meio = separarConferir('A Corretora vende planos.\n- Plano Essencial: R$ 289,90 por mês (Site A) PARA CONFERIR: o Arquivo B diz R$ 249,90.\n- Plano Bronze: R$ 99,90 por mês (Site A).');
  assert.equal(meio.texto, 'A Corretora vende planos.');
  assert.doesNotMatch(meio.texto, /289|249/);
  assert.match(meio.conferir, /^- Plano Essencial: R\$ 289,90 por mês \(Site A\) o Arquivo B diz R\$ 249,90\./);
  for (const marca of ['Divergências para conferir:', 'Itens a conferir:']) {
    assert.deepEqual(separarConferir(`${corpo}\n\n${marca}\n${div}`), { texto: corpo, conferir: div }, marca);
  }
  assert.deepEqual(separarConferir('Texto.\nPARA CONFERIR (coparticipação: Site A x Arquivo B)'),
    { texto: 'Texto.', conferir: '(coparticipação: Site A x Arquivo B)' }, 'parêntese com conteúdo não é cabeçalho');
  assert.deepEqual(separarConferir('Texto.\n**PARA CONFERIR:** o prazo de carência diverge'), { texto: 'Texto.', conferir: 'o prazo de carência diverge' });
  for (const nada of ['nenhuma.', 'Nenhuma divergência encontrada.', '\n- Nenhuma divergência.', '\nNão há divergências.', 'Sem divergências encontradas.', '(nenhuma)',
    'Nenhuma divergência encontrada entre os materiais.', 'Não há divergências entre as fontes.',
    'Nenhuma divergência encontrada nos materiais analisados.', 'Não foram encontradas divergências entre os materiais.',
    'Nenhuma divergência relevante.', 'Sem divergências entre os materiais.', 'Não há divergências a relatar.',
    'Nenhuma divergência foi identificada entre as fontes.', 'Nada a conferir.', 'Não identifiquei divergências.',
    'Nenhuma — os materiais concordam.', 'Não há.', 'Nenhuma divergência encontrada; todas as informações são consistentes.']) {
    assert.deepEqual(separarConferir(`Texto.\nPARA CONFERIR: ${nada}`), { texto: 'Texto.', conferir: '' }, nada);
  }
  // Divergência que COMEÇA por "sem" ou "não há" continua sendo divergência.
  for (const algo of ['Sem divergência de preço. Taxa de adesão: Site A isenta, Arquivo B cobra.',
    'Não há consenso sobre reembolso: Site A oferece, Arquivo B não.', '\nNenhuma sobre preço.\n- Taxa de adesão: Site A isenta, Arquivo B cobra.',
    'Nenhuma divergência de preço; a carência do Odonto diverge (Site A x Arquivo B).',
    'Nenhuma divergência entre os materiais. A taxa de adesão diverge.']) {
    assert.notEqual(separarConferir(`Texto.\nPARA CONFERIR: ${algo}`).conferir, '', algo);
  }
  assert.deepEqual(separarConferir('Só texto.'), { texto: 'Só texto.', conferir: '' });
  // "para conferir" de frase não é marcador.
  const frase = 'A Corretora Exemplo vende planos.\n- Ligue para conferir a cobertura da sua região.\n- Plano Bronze (Site A).';
  assert.deepEqual(separarConferir(frase), { texto: frase, conferir: '' });
});

test('o formato que o prompt pede é o que o freio lê — dos dois lados', () => {
  assert.match(SISTEMA_DA_COLETA, /Uma condição por linha/);
  assert.match(SISTEMA_DA_COLETA, /se\s+escreve SEMPRE "não há carência para consultas no Plano X"/);
  assert.match(SISTEMA_DA_COLETA, /nunca "sem carência", "carência zero"/);
  assert.match(SISTEMA_DA_COLETA, /Telefone, endereço, horário e site ficam numa linha própria/);
  const freio = (contexto: string, t: string) =>
    aplicarFreios(t, { proibido: [], tamanho_maximo: null, canal: 'whatsapp', contexto, objetivo: 'resgate' }).situacao;
  const base = [
    'A Corretora Exemplo vende planos de saúde em Sorocaba.',
    '- Plano Empresarial: R$ 150,00 por vida (Site A).',
    '- Sem taxa de adesão no Plano Empresarial (Site A).',
    '- Carência de 180 dias para internação no Plano Empresarial (Site A).',
    '- Atendimento: (11) 4004-1234, das 8h às 20h.',
  ];
  // Preço escrito passa; telefone e horário não viram preço.
  assert.equal(freio(base.join('\n'), 'O Empresarial custa R$ 150,00 por vida.'), 'pronto');
  assert.equal(freio(base.join('\n'), 'O plano custa R$ 20,00.'), 'bloqueado', 'o horário do atendimento não vira preço');
  assert.equal(freio(base.join('\n'), 'O plano custa R$ 1.234,00.'), 'bloqueado', 'o telefone não vira preço');
  // A ausência de carência na forma do prompt ("não há") sai da fonte: o agente
  // que promete carência zero — do plano que for — é barrado, o lado do erro do D76.
  const comOdonto = [...base, '- Não há carência no Plano Odonto Clínico (Site A).', '- Não há carência para consultas no Plano Empresarial (Site A).'].join('\n');
  for (const promessa of ['O Empresarial não tem carência, pode internar desde o primeiro dia.', 'No plano de saúde não tem carência para parto.',
    'Pode contratar tranquila: zero carência para tudo.', 'O Odonto não tem carência.']) {
    assert.equal(freio(comOdonto, promessa), 'bloqueado', promessa);
  }
  // As formas que o prompt PROÍBE são as que liberariam isso — e, se o modelo as
  // escrever mesmo assim, o código as tira do texto antes que virem contexto.
  for (const proibida of ['- Plano Odonto Clínico: sem carência (Site A).', '- Consultas sem carência no Plano Empresarial (Site A).',
    '- Carência zero para consultas (Site A).', '- Isenção de carência para consultas (Site A).',
    '- Não tem carência para consultas no Plano Empresarial (Site A).', '- Nenhuma carência para consultas eletivas (Site A).']) {
    const solta = [...base, proibida].join('\n');
    assert.equal(freio(solta, 'O Empresarial não tem carência, pode internar desde o primeiro dia.'), 'pronto', `sem a conferência: ${proibida}`);
    const { texto, tiradas } = tirarCarenciaSemEscopo(solta);
    assert.deepEqual(tiradas, [proibida], proibida);
    assert.equal(freio(texto, 'O Empresarial não tem carência, pode internar desde o primeiro dia.'), 'bloqueado', `com a conferência: ${proibida}`);
  }
  // Frase a frase, como o freio corta: o "não há" de OUTRA frase da linha não
  // tira da fonte do freio a frase com "sem carência".
  for (const duas of ['- Plano Odonto: sem carência (Site A). Não há limite de consultas.',
    '- Não há fidelidade no Plano Odonto. Sem carência para limpeza (Site A).',
    '- Não há carência para consultas no Plano Odonto. Urgência sem carência (Site A).',
    '- Plano Odonto: carência zero (Arquivo B)! Não existe taxa de adesão.']) {
    const solta = [...base, duas].join('\n');
    assert.equal(freio(solta, 'O Empresarial não tem carência, pode internar desde o primeiro dia.'), 'pronto', `sem a conferência: ${duas}`);
    const { texto, tiradas } = tirarCarenciaSemEscopo(solta);
    assert.deepEqual(tiradas, [duas], duas);
    assert.equal(freio(texto, 'O Empresarial não tem carência, pode internar desde o primeiro dia.'), 'bloqueado', `com a conferência: ${duas}`);
  }
  // E o que fala de carência sem negar fica — inclusive com "não há" na mesma frase.
  assert.deepEqual(tirarCarenciaSemEscopo(comOdonto), { texto: comOdonto, tiradas: [] });
  const ficam = '- Não há carência para consultas no Plano Odonto. Sem taxa de adesão (Site A).';
  assert.deepEqual(tirarCarenciaSemEscopo(ficam), { texto: ficam, tiradas: [] });
});

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
  { tipo: 'pdf', nome: 'catalogo.pdf', rotulo: '[Arquivo] catalogo.pdf', base64: b64(PDF) },
  { tipo: 'imagem', nome: 'p.png', rotulo: '[Instagram] print p.png', mime: 'image/png', base64: b64(PNG) },
];

test('leitura: quem lê anexo é subconjunto de quem tem adapter', () => {
  for (const p of LEEM_ANEXOS) assert.ok((PROVEDORES_IA_COM_ADAPTER as readonly string[]).includes(p), p);
});

test('leitura: no Claude, cada anexo com o rótulo antes e o documento com o nome — o resto é o pedido de ia.ts', async () => {
  const m = modeloFalso();
  const r = await criarLeitor('anthropic', m.buscar).ler({ credenciais: CRED, modelo: 'claude-x', sistema: 'S', partes: ANEXOS, maxTokens: 16000 });
  assert.deepEqual(r, { ok: true, texto: 'ok' });
  const p = m.pedidos[0]!;
  assert.equal(p.url, 'https://api.anthropic.com/v1/messages');
  assert.equal(p.headers.get('x-api-key'), 'sk-teste');
  assert.ok(p.temPrazo);
  assert.deepEqual(p.corpo, {
    model: 'claude-x', max_tokens: 16000, system: 'S',
    messages: [{ role: 'user', content: [
      { type: 'text', text: 'A empresa se chama X.' },
      { type: 'text', text: '[Arquivo] catalogo.pdf' },
      { type: 'document', title: 'catalogo.pdf', source: { type: 'base64', media_type: 'application/pdf', data: b64(PDF) } },
      { type: 'text', text: '[Instagram] print p.png' },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: b64(PNG) } },
    ] }],
  });
  assert.deepEqual((p.corpo.messages as { content: unknown }[])[0]!.content, blocosDoClaude(ANEXOS));
});

test('leitura: na OpenAI e no OpenRouter, file e image_url com o rótulo antes — e o teto de tokens de ia.ts', async () => {
  for (const [provedor, url] of [['openai', 'https://api.openai.com/v1/chat/completions'],
    ['openrouter', 'https://openrouter.ai/api/v1/chat/completions']] as const) {
    const m = modeloFalso();
    await criarLeitor(provedor, m.buscar).ler({ credenciais: CRED, modelo: 'gpt-5.5', sistema: 'S', partes: ANEXOS, maxTokens: 3000 });
    const p = m.pedidos[0]!;
    assert.equal(p.url, url);
    const msgs = p.corpo.messages as { role: string; content: unknown }[];
    assert.deepEqual(msgs[0], { role: 'system', content: 'S' });
    assert.deepEqual(msgs[1]!.content, partesDoChat(ANEXOS));
    assert.deepEqual(msgs[1]!.content, [
      { type: 'text', text: 'A empresa se chama X.' },
      { type: 'text', text: '[Arquivo] catalogo.pdf' },
      { type: 'file', file: { filename: 'catalogo.pdf', file_data: `data:application/pdf;base64,${b64(PDF)}` } },
      { type: 'text', text: '[Instagram] print p.png' },
      { type: 'image_url', image_url: { url: `data:image/png;base64,${b64(PNG)}` } },
    ]);
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
