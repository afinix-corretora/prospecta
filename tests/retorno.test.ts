// Para onde o link de acesso volta (D50).
//
// Parece pequeno demais para ter teste. Mas foi um defeito real em produção —
// o link chegava apontando para localhost — e o que o custou não foi a lógica
// e sim o silêncio: a requisição dá certo, a tela diz "enviado", e o problema
// mora numa lista dentro do painel do Supabase. Esta função é o que a tela
// mostra para que o mistério vire diagnóstico.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { ehLocal, urlDeRetorno } from '../app/src/retorno.ts';

test('a URL de retorno termina em barra', () => {
  // A barra não é enfeite: o glob `.../**` da lista do Supabase casa caminhos
  // ABAIXO da raiz, e mandar a origem pelada deixa o casamento na dependência
  // de detalhe do glob.
  assert.equal(urlDeRetorno('https://app.exemplo.com'), 'https://app.exemplo.com/');
});

test('e não duplica a barra quando já existe', () => {
  assert.equal(urlDeRetorno('https://app.exemplo.com/'), 'https://app.exemplo.com/');
});

test('reconhece endereço local, incluindo as formas que não são "localhost"', () => {
  assert.equal(ehLocal('http://localhost:5173/'), true);
  assert.equal(ehLocal('http://127.0.0.1:5173/'), true);
  assert.equal(ehLocal('http://[::1]:5173/'), true);
  assert.equal(ehLocal('http://localhost/'), true);
});

test('e não confunde endereço real que contém a palavra', () => {
  // O caso que um `includes("localhost")` erraria — e que mandaria a tela
  // esconder justamente o aviso de quem mais precisa dele.
  assert.equal(ehLocal('https://localhost.exemplo.com/'), false);
  assert.equal(ehLocal('https://app-eight-snowy-54.vercel.app/'), false);
  assert.equal(ehLocal('https://meu-localhost.com.br/'), false);
});
