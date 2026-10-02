// O que a tela lê como variável precisa ser o que o motor lê (D55).
//
// `privado.renderizar` troca `{{chave}}` pelo valor e **apaga** a marcação que
// sobrou. A tela do editor lê o mesmo texto para dizer quais chaves ele pede —
// e se as duas leituras divergirem, a tela diz "todas existem na base" sobre
// uma chave que o motor vai apagar. É o D32 na camada do texto: duas
// interpretações da mesma marcação, e a divergência aparece na mensagem que
// chega ao contato, não em teste nenhum.
//
// A regexp de referência é a de APAGAR, em renderizar:
//
//     '\{\{\s*[\w\.]+\s*\}\}'
//
// porque é ela que define o que o motor considera uma marcação. Os casos
// abaixo são os que diferenciam uma reprodução fiel de uma parecida.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { variaveisDoTexto } from '../app/src/variaveis.ts';

test('a chave simples é encontrada', () => {
  assert.deepEqual(variaveisDoTexto('Oi {{nome}}, tudo bem?'), ['nome']);
});

test('espaço dentro das chaves é aceito, como no motor', () => {
  // `\s*` dos dois lados em renderizar. Uma reprodução sem isso deixaria
  // `{{ nome }}` passar por texto comum — e o motor o apagaria mesmo assim.
  assert.deepEqual(variaveisDoTexto('Oi {{ nome }}!'), ['nome']);
  assert.deepEqual(variaveisDoTexto('Oi {{  nome  }}!'), ['nome']);
});

test('ponto faz parte da chave', () => {
  // `[\w\.]+` — metadados aninhados são escritos assim.
  assert.deepEqual(variaveisDoTexto('Plano {{plano.atual}}'), ['plano.atual']);
});

test('sublinhado e dígito fazem parte da chave', () => {
  assert.deepEqual(variaveisDoTexto('{{plano_atual}} e {{campo2}}'),
    ['plano_atual', 'campo2']);
});

test('a mesma chave duas vezes conta uma', () => {
  assert.deepEqual(variaveisDoTexto('{{nome}}, {{nome}}, {{nome}}'), ['nome']);
});

test('várias chaves saem na ordem em que aparecem', () => {
  assert.deepEqual(variaveisDoTexto('{{b}} depois {{a}}'), ['b', 'a']);
});

test('texto sem marcação nenhuma devolve lista vazia', () => {
  assert.deepEqual(variaveisDoTexto('Oi, tudo bem?'), []);
});

test('chave vazia não é variável', () => {
  // `+` exige ao menos um caractere. `{{}}` não é marcação nem para o motor.
  assert.deepEqual(variaveisDoTexto('Oi {{}}'), []);
  assert.deepEqual(variaveisDoTexto('Oi {{   }}'), []);
});

test('caractere fora da classe não vira variável', () => {
  // Hífen e espaço no meio não estão em `[\w\.]`. O motor NÃO apagaria isto,
  // então a tela também não pode contá-lo como variável — contar a mais é
  // acusar de buraco um texto que vai sair inteiro.
  assert.deepEqual(variaveisDoTexto('{{plano-atual}}'), []);
  assert.deepEqual(variaveisDoTexto('{{plano atual}}'), []);
});

test('chave só de uma chaveta não é variável', () => {
  assert.deepEqual(variaveisDoTexto('{nome}'), []);
});

test('marcação colada no texto ainda é achada', () => {
  assert.deepEqual(variaveisDoTexto('Olá{{nome}}!'), ['nome']);
});

test('várias linhas são varridas inteiras', () => {
  // O texto do passo é escrito com quebra de linha, e é assim que ele sai.
  assert.deepEqual(variaveisDoTexto('Oi {{nome}},\n\nseu plano é {{plano_atual}}.'),
    ['nome', 'plano_atual']);
});
