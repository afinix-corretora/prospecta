// A leitura da situação do dreno (D46).
//
// Três estados produzem a MESMA ausência de sinal — "zero writebacks saindo" —
// e é a tela que os separa. O que se testa aqui é justamente a separação, não
// o desenho: cada caso abaixo é uma situação que, lida errado, some.
//
// O par mais importante é `nunca_saiu` vs `parado`. Na fase de hoje o dreno
// não tem adapter de CRM, então a fila crescendo é o comportamento CORRETO.
// Se isso aparecesse como alarme, o alarme viraria ruído — e o de verdade
// passaria despercebido.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  HORAS_DE_DEMORA, situacaoDoWriteback,
} from '../app/src/telas/situacao_do_writeback.ts';

test('nada aconteceu ainda não é o mesmo que nada saiu', () => {
  const e = situacaoDoWriteback({
    pendentes: 0, enviados: 0, falhados: 0, pendente_mais_antigo_em_horas: null,
  });
  assert.equal(e.tipo, 'vazio');
});

test('fatos empilhando sem nenhum entregue é "nunca saiu", não "parou"', () => {
  const e = situacaoDoWriteback({
    pendentes: 12, enviados: 0, falhados: 0, pendente_mais_antigo_em_horas: 40,
  });
  assert.equal(e.tipo, 'nunca_saiu');
  assert.equal(e.tipo === 'nunca_saiu' ? e.horas : null, 40);
});

test('e continua "nunca saiu" mesmo com desistências — nada chegou ao CRM', () => {
  const e = situacaoDoWriteback({
    pendentes: 3, enviados: 0, falhados: 9, pendente_mais_antigo_em_horas: 100,
  });
  assert.equal(e.tipo, 'nunca_saiu');
});

test('já saiu antes e agora o mais antigo passou do teto: parou', () => {
  const e = situacaoDoWriteback({
    pendentes: 2, enviados: 30, falhados: 0,
    pendente_mais_antigo_em_horas: HORAS_DE_DEMORA,
  });
  assert.equal(e.tipo, 'parado');
});

test('já saiu antes e o mais antigo ainda está dentro do teto: em dia', () => {
  const e = situacaoDoWriteback({
    pendentes: 2, enviados: 30, falhados: 0,
    pendente_mais_antigo_em_horas: HORAS_DE_DEMORA - 0.1,
  });
  assert.equal(e.tipo, 'ok');
});

test('fila vazia depois de ter saído coisa é "em dia", não "parado"', () => {
  // A idade nula é o que evita o falso alarme aqui: sem pendente não há
  // "mais antigo", e tratar nulo como zero OU como infinito erraria — um
  // silenciaria a parada de verdade, o outro alarmaria a fila vazia.
  const e = situacaoDoWriteback({
    pendentes: 0, enviados: 30, falhados: 0, pendente_mais_antigo_em_horas: null,
  });
  assert.equal(e.tipo, 'ok');
});

test('desistências antigas sozinhas não viram alarme de dreno parado', () => {
  // Falhado não é fila: ninguém vai tentar de novo. O alarme de "parado" é
  // sobre o que ESTÁ esperando, e confundir os dois deixaria a tela vermelha
  // para sempre depois da primeira desistência.
  const e = situacaoDoWriteback({
    pendentes: 0, enviados: 5, falhados: 7, pendente_mais_antigo_em_horas: null,
  });
  assert.equal(e.tipo, 'ok');
});
