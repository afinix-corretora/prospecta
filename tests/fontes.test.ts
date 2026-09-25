// Testes das fontes de contato: leitor de CSV, dialetos e `PlanilhaSource`.
//
// Sem banco e sem rede: colher é puro, e é por isso que a prévia da tela de
// importação consegue existir. O que `ingerir_contato` faz com o resultado
// tem teste próprio em tests/ingestao.sql.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { chaveDeColuna, lerCsv, separadorDe, vazia } from '../adapters/csv.ts';
import { celularBrasileiro, normalizarTelefone } from '../adapters/telefone.ts';
import { handleValido, normalizarHandle } from '../adapters/instagram.ts';
import { PlanilhaSource } from '../adapters/planilha.ts';
import { identidadesParaJson } from '../adapters/fonte.ts';
import type { ContatoLido } from '../adapters/fonte.ts';

// ---------------------------------------------------------------------------
// CSV
// ---------------------------------------------------------------------------

test('separador: Excel em português exporta com ponto e vírgula', () => {
  assert.equal(separadorDe('nome;telefone;email\na;b;c'), ';');
  assert.equal(separadorDe('nome,telefone,email\na,b,c'), ',');
  assert.equal(separadorDe('nome\ttelefone\temail'), '\t');
  // Uma coluna só não tem separador nenhum; a vírgula é o padrão inofensivo.
  assert.equal(separadorDe('email\na@b.com'), ',');
});

test('separador: vírgula dentro de aspas não conta como separador', () => {
  // Sem contar fora das aspas, "Silva, João" faria a vírgula ganhar.
  assert.equal(separadorDe('"Silva, João";telefone'), ';');
});

test('csv: aspas seguram separador, quebra de linha e aspas duplas', () => {
  assert.deepEqual(lerCsv('nome,cidade\n"Silva, João",SP'), [
    ['nome', 'cidade'], ['Silva, João', 'SP'],
  ]);
  assert.deepEqual(lerCsv('a\n"diz ""oi"""'), [['a'], ['diz "oi"']]);
  assert.deepEqual(lerCsv('a,b\n"linha 1\nlinha 2",x'), [
    ['a', 'b'], ['linha 1\nlinha 2', 'x'],
  ]);
});

test('csv: BOM do Excel não entra no nome da primeira coluna', () => {
  // Medir por `chaveDeColuna` não provaria nada: ela troca o BOM por `_` e
  // apara as pontas, então o BOM some mesmo quando o leitor não o tirou.
  // Quem paga é quem usa o cabeçalho cru — e a linha recusada usa.
  assert.equal(lerCsv('﻿E-mail,nome')[0][0], 'E-mail');
});

test('planilha: linha recusada é indexada pelo cabeçalho sem BOM', () => {
  const { recusadas } = colher('﻿Nome;Celular\nSó Nome;\n');
  assert.equal(recusadas.length, 1);
  assert.equal(recusadas[0].valores['Nome'], 'Só Nome');
});

test('csv: campo vazio é preservado e CRLF não vira célula', () => {
  assert.deepEqual(lerCsv('a,b,c\r\n1,,3\r\n'), [['a', 'b', 'c'], ['1', '', '3']]);
});

test('csv: linha em branco fica na lista para o número da linha não andar', () => {
  const linhas = lerCsv('a\n1\n\n2\n');
  assert.equal(linhas.length, 4);
  assert.ok(vazia(linhas[2]));
});

test('chaveDeColuna: acento, espaço e pontuação viram a mesma chave', () => {
  assert.equal(chaveDeColuna('  Razão Social '), 'razao_social');
  assert.equal(chaveDeColuna('E-mail'), 'e_mail');
  assert.equal(chaveDeColuna('Telefone (DDD)'), 'telefone_ddd');
});

// ---------------------------------------------------------------------------
// Dialetos
// ---------------------------------------------------------------------------

test('celular: nove dígitos começando em 9 é celular, oito é fixo', () => {
  assert.equal(celularBrasileiro('(15) 99123-4567'), true);
  assert.equal(celularBrasileiro('1533221100'), false);
  assert.equal(celularBrasileiro('abc'), false);
  // Fora do DDI 55 não se adivinha: quem recusa é o provedor, não a ingestão.
  assert.equal(celularBrasileiro('+351 912 345 678'), true);
});

test('instagram: arroba e URL de perfil dão o mesmo handle', () => {
  assert.equal(normalizarHandle('@Marina.Souza'), 'marina.souza');
  assert.equal(normalizarHandle('https://instagram.com/Marina.Souza/?hl=pt'), 'marina.souza');
  assert.equal(normalizarHandle('  Marina_Souza  '), 'marina_souza');
  assert.equal(handleValido('nome com espaco'), false);
  assert.equal(handleValido('a'.repeat(31)), false);
});

test('instagram: o normalizador daqui satisfaz a trava do banco', () => {
  // Mesma expressão de `privado.normalizada` na migration da ingestão. Se as
  // duas divergirem, a ingestão recusa o que a fonte produziu.
  const travaDoBanco = /^[a-z0-9._]{1,30}$/;
  for (const bruto of ['@Ana', 'instagram.com/ana.paula/', 'ANA_PAULA']) {
    assert.ok(travaDoBanco.test(normalizarHandle(bruto)), bruto);
  }
});

// ---------------------------------------------------------------------------
// PlanilhaSource
// ---------------------------------------------------------------------------

function colher(csv: string) {
  return new PlanilhaSource(csv).colherAgora();
}

function porNome(contatos: ContatoLido[], nome: string): ContatoLido {
  const c = contatos.find((x) => x.nome === nome);
  assert.ok(c, `esperava contato ${nome}`);
  return c;
}

function canais(c: ContatoLido): string[] {
  return c.identidades.map((i) => i.canal).sort();
}

test('planilha: colhe nome, telefone e e-mail de cabeçalho em português', () => {
  const { contatos, recusadas } = colher(
    'Nome;Telefone;E-mail\nMarina Souza;(15) 99123-4567;MARINA <M@Ex.Com.BR>\n',
  );
  assert.equal(recusadas.length, 0);
  assert.equal(contatos.length, 1);

  const m = porNome(contatos, 'Marina Souza');
  assert.deepEqual(canais(m), ['email', 'sms', 'whatsapp']);
  // O bruto viaja junto para a tela devolver o que a pessoa digitou.
  assert.equal(m.identidades[0].valor, '(15) 99123-4567');
  assert.equal(m.identidades[0].valorNorm, '5515991234567');
  assert.equal(m.identidades[2].valorNorm, 'm@ex.com.br');
});

test('planilha: coluna que declara o canal não inventa o outro', () => {
  const { contatos } = colher('Nome,WhatsApp\nAna,15991110000\n');
  assert.deepEqual(canais(porNome(contatos, 'Ana')), ['whatsapp']);
});

test('planilha: telefone fixo não vira promessa de WhatsApp', () => {
  // A coluna genérica não declara canal, e o motor não fala com fixo. Entrar
  // como whatsapp faria o roteador escolher um destino que não existe.
  const { contatos, recusadas, ignorados } = colher('Nome;Telefone\nJoão;1533221100\n');
  assert.equal(contatos.length, 0);
  assert.equal(recusadas.length, 1);
  assert.match(ignorados[0].motivo, /fixo/);
  assert.equal(ignorados[0].linha, 2);
});

test('planilha: telefone ruim numa linha com e-mail bom avisa em vez de sumir', () => {
  const { contatos, ignorados } = colher('Nome;Telefone;E-mail\nAna;abc;ana@x.com.br\n');
  assert.equal(contatos.length, 1);
  assert.deepEqual(canais(contatos[0]), ['email']);
  assert.equal(ignorados.length, 1);
  assert.equal(ignorados[0].coluna, 'Telefone');
  assert.equal(ignorados[0].valor, 'abc');
});

test('planilha: colunas numeradas são a mesma coluna repetida', () => {
  const { contatos } = colher('Nome;Telefone 1;Telefone 2\nAna;15991110000;15992220000\n');
  const a = porNome(contatos, 'Ana');
  // Dois celulares, cada um nos dois canais.
  assert.equal(a.identidades.length, 4);
  assert.equal(new Set(a.identidades.map((i) => i.valorNorm)).size, 2);
  assert.equal(Object.keys(a.metadados).length, 0);
});

test('planilha: mesmo número em duas colunas não duplica identidade', () => {
  // `Telefone` e `WhatsApp` preenchidos iguais é o caso normal, e o índice
  // único `(tenant_id, canal, valor_norm)` recusaria a segunda linha.
  const { contatos } = colher('Nome;Telefone;WhatsApp\nAna;15991110000;(15) 99111-0000\n');
  assert.deepEqual(canais(contatos[0]), ['sms', 'whatsapp']);
});

test('planilha: coluna desconhecida vira metadado, não some', () => {
  const { contatos } = colher('Nome;Celular;Plano atual;Corretor\nAna;15991110000;Amil;Rita\n');
  assert.deepEqual(porNome(contatos, 'Ana').metadados, { plano_atual: 'Amil', corretor: 'Rita' });
});

test('planilha: célula vazia não vira metadado vazio', () => {
  const { contatos } = colher('Nome;Celular;Plano atual\nAna;15991110000;\n');
  assert.deepEqual(contatos[0].metadados, {});
});

test('planilha: linha sem identidade nenhuma é recusada com o motivo certo', () => {
  const { contatos, recusadas } = colher('Nome;Celular;E-mail\nAna;15991110000;\nSó Nome;;\n');
  assert.equal(contatos.length, 1);
  assert.equal(recusadas.length, 1);
  assert.equal(recusadas[0].linha, 3);
  assert.match(recusadas[0].motivo, /sem telefone/);
  // A linha recusada volta inteira para a pessoa achá-la na planilha.
  assert.equal(recusadas[0].valores['Nome'], 'Só Nome');
});

test('planilha: número da linha é o do Excel, mesmo com linha em branco no meio', () => {
  const { contatos } = colher('Nome;Celular\nMarina;15991110000\n\nAna;15992220000\n');
  assert.deepEqual(contatos.map((c) => [c.nome, c.linha]), [['Marina', 2], ['Ana', 4]]);
});

test('planilha: id da fonte vira origem_ref', () => {
  const { contatos } = colher('Código;Nome;Celular\nABC-1;Ana;15991110000\n');
  assert.equal(contatos[0].origemRef, 'ABC-1');
});

test('planilha: instagram entra sem arroba', () => {
  const { contatos } = colher('Nome,Instagram\nAna,@Ana.Paula\n');
  assert.deepEqual(contatos[0].identidades[0], {
    canal: 'instagram', valor: '@Ana.Paula', valorNorm: 'ana.paula',
  });
});

test('planilha: arquivo sem coluna de contato falha alto, não 500 vezes', () => {
  assert.throws(
    () => colher('Nome;Plano;Cidade\nAna;Amil;Sorocaba\n'),
    /nenhuma coluna de contato reconhecida/,
  );
  assert.throws(() => colher(''), /planilha vazia/);
});

test('planilha: origem é declarada e chega na colheita', () => {
  const c = new PlanilhaSource('Nome,Celular\nAna,15991110000\n', { origem: 'pipefy-export' });
  assert.equal(c.colherAgora().origem, 'pipefy-export');
  assert.equal(colher('Nome,Celular\nAna,15991110000\n').origem, 'planilha');
});

test('planilha: colher() assíncrono devolve o mesmo que o síncrono', async () => {
  const fonte = new PlanilhaSource('Nome,Celular\nAna,15991110000\n');
  assert.deepEqual(await fonte.colher(), fonte.colherAgora());
});

test('identidadesParaJson: chaves no formato que ingerir_contato espera', () => {
  const { contatos } = colher('Nome,Celular\nAna,15991110000\n');
  assert.deepEqual(identidadesParaJson(contatos[0]), [
    { canal: 'whatsapp', valor: '15991110000', valor_norm: '5515991110000' },
    { canal: 'sms', valor: '15991110000', valor_norm: '5515991110000' },
  ]);
});

test('o que a fonte produz passa na trava do banco', () => {
  // `privado.normalizada` recusa identidade não normalizada, e a recusa é uma
  // exceção — uma importação inteira morre. As expressões são as da migration
  // da ingestão, copiadas de propósito: se a fonte divergir, isto fica
  // vermelho aqui e não em produção.
  const travas: Record<string, RegExp> = {
    whatsapp: /^[0-9]{10,15}$/,
    sms: /^[0-9]{10,15}$/,
    email: /^[^\s@,;<>]+@[^\s@,;<>.]+([.][^\s@,;<>.]+)+$/,
    instagram: /^[a-z0-9._]{1,30}$/,
  };

  const { contatos } = colher(
    'Nome;Telefone;WhatsApp;E-mail;Instagram\n'
    + 'Marina;(15) 99123-4567;+55 15 99999-8888;MARINA SOUZA <M.Souza@Exemplo.Com.BR>;'
    + 'https://instagram.com/Marina.Souza/\n',
  );

  // whatsapp+sms do telefone genérico, whatsapp do segundo número, e-mail e @.
  const ids = contatos[0].identidades;
  assert.equal(ids.length, 5);
  for (const i of ids) {
    assert.equal(i.valorNorm, i.valorNorm.toLowerCase().trim(), i.valorNorm);
    assert.ok(travas[i.canal].test(i.valorNorm), `${i.canal}: ${i.valorNorm}`);
  }
});
