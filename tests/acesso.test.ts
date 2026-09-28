// A tela de entrada com e-mail e senha (D60).
//
// O que se testa aqui é o que a tela decide sem rede: se a URL veio do e-mail
// de "definir senha", se o link voltou com erro, e o que se diz à pessoa.
// Os dois primeiros são os que, errados, falham em silêncio — a pessoa entra
// sem trocar a senha, ou volta ao formulário sem saber que o link expirou.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  chegouParaDefinirSenha, erroDoLink, mensagemDeAcesso, problemaDaSenha, SENHA_MINIMA,
} from '../app/src/acesso.ts';

test('reconhece o retorno do e-mail de definir senha', () => {
  assert.equal(
    chegouParaDefinirSenha('#access_token=abc&expires_in=3600&refresh_token=def&token_type=bearer&type=recovery'),
    true,
  );
});

test('e não confunde com o retorno de um link de acesso comum', () => {
  // Mesmo formato, outro `type`: é entrada, não troca de senha.
  assert.equal(chegouParaDefinirSenha('#access_token=abc&type=magiclink'), false);
  assert.equal(chegouParaDefinirSenha('#access_token=abc&type=signup'), false);
});

test('nem com um fragmento que só diz "recovery" sem trazer sessão', () => {
  // Sem `access_token` não há sessão para gravar senha nova; mostrar o
  // formulário levaria a um erro de "não autenticado" depois de digitar.
  assert.equal(chegouParaDefinirSenha('#type=recovery'), false);
  assert.equal(chegouParaDefinirSenha(''), false);
  assert.equal(chegouParaDefinirSenha('#'), false);
});

test('o link expirado vira frase, não silêncio', () => {
  const m = erroDoLink('#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired');
  assert.ok(m && /expirou/.test(m), `mensagem: ${m}`);
});

test('outro erro do link usa a descrição que o Supabase mandou', () => {
  assert.equal(
    erroDoLink('#error=server_error&error_description=Algo+deu+errado'),
    'Algo deu errado',
  );
});

test('sem erro no fragmento, não há erro', () => {
  assert.equal(erroDoLink(''), null);
  assert.equal(erroDoLink('#access_token=abc&type=recovery'), null);
});

test('credencial errada é dita em português, pelo código', () => {
  assert.equal(
    mensagemDeAcesso({ code: 'invalid_credentials', message: 'Invalid login credentials' }),
    'E-mail ou senha incorretos.',
  );
});

test('código desconhecido cai na mensagem que veio, não em "erro desconhecido"', () => {
  assert.equal(mensagemDeAcesso({ code: 'algo_novo', message: 'texto do servidor' }), 'texto do servidor');
  assert.equal(mensagemDeAcesso(null), 'erro desconhecido');
});

test('senha curta é recusada antes de ir ao servidor', () => {
  const curta = 'a'.repeat(SENHA_MINIMA - 1);
  assert.match(problemaDaSenha(curta, curta) ?? '', /pelo menos/);
});

test('confirmação diferente é recusada', () => {
  assert.equal(problemaDaSenha('senha-boa-123', 'senha-boa-124'), 'As duas senhas não conferem.');
});

test('senha longa e confirmada passa', () => {
  const boa = 'a'.repeat(SENHA_MINIMA);
  assert.equal(problemaDaSenha(boa, boa), null);
});
