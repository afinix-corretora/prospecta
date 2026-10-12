// O construtor de agentes, sem tela (D76): trocar persona ou objetivo, o que
// falta para salvar, onde cada agente responde, e a prévia — que é o MESMO
// pedido que o worker monta, porque usa o mesmo `montarPedido`.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  camposParaGravar, canaisQueServe, entradaDaPrevia, oQueFalta, PEDIDO_DE_SAIDA_DO_TESTE, rascunhoDe, rascunhoNovo,
  rotulo, trocarObjetivo, trocarPersona,
} from '../app/src/agentes.ts';
import { CANAIS, montarPedido, OBJETIVOS, PERSONAS } from '../adapters/prompt-do-agente.ts';

test('agente novo: persona marcada, objetivo NÃO — e o que falta é dito', () => {
  const r = rascunhoNovo('Afinix Corretora');
  assert.equal(r.persona, 'consultiva');
  assert.equal(r.objetivo, null, 'objetivo pré-marcado seria escolha que ninguém fez');
  assert.equal(r.contexto, 'Falamos em nome de Afinix Corretora.');
  const falta = oQueFalta(r, { novo: true });
  assert.ok(falta.some((f) => /nome/.test(f)));
  assert.ok(falta.some((f) => /persona e o objetivo/.test(f)));
  // Vindo da campanha, o objetivo vem marcado.
  assert.equal(rascunhoNovo('X', 'renovacao').objetivo, 'renovacao');
});

test('o caminho feliz: nome, objetivo, empresa — e salva', () => {
  let r = { ...rascunhoNovo('Afinix Corretora'), nome: 'Ana' };
  r = trocarObjetivo(r, 'resgate').rascunho;
  assert.ok(oQueFalta(r, { novo: true }).some((f) => /Sobre a empresa/.test(f)), 'só o nome da empresa não basta');
  r = { ...r, contexto: 'Falamos em nome da Afinix Corretora, em Rio Preto. Planos de saúde.' };
  assert.deepEqual(oQueFalta(r, { novo: true }), []);
  const c = camposParaGravar(r);
  assert.equal(c.tamanho_maximo, null, 'em branco é o do canal');
  assert.equal(c.instrucoes, OBJETIVOS.find((o) => o.slug === 'resgate')!.roteiro);
});

test('trocar a persona troca só o "como fala" — e diz quando apagou um ajuste', () => {
  const base = { ...trocarObjetivo(rascunhoNovo('X'), 'follow_up').rascunho, nome: 'Bia' };
  const limpa = trocarPersona(base, 'executiva');
  assert.equal(limpa.rascunho.tom, PERSONAS.find((p) => p.slug === 'executiva')!.tom);
  assert.equal(limpa.rascunho.instrucoes, base.instrucoes);
  assert.deepEqual(limpa.perdidos, [], 'o texto era o da persona: nada se perde');
  const ajustada = trocarPersona({ ...base, tom: 'Fale como eu falo.' }, 'proxima');
  assert.deepEqual(ajustada.perdidos, ['tom'], 'o ajuste perdido é avisado, para a tela oferecer desfazer');
});

test('trocar o objetivo troca o que faz, o papel, a escalada e o limite', () => {
  const r = trocarObjetivo(rascunhoNovo('X'), 'prospeccao_fria').rascunho;
  const t = trocarObjetivo({ ...r, instrucoes: r.instrucoes + ' E mais uma regra minha.' }, 'agendamento');
  const o = OBJETIVOS.find((x) => x.slug === 'agendamento')!;
  assert.equal(t.rascunho.papel, o.papel);
  assert.equal(t.rascunho.escalar_quando, o.escalar_quando);
  assert.equal(t.rascunho.limite_trocas, String(o.limite_trocas));
  assert.deepEqual(t.perdidos, ['instrucoes']);
});

test('números fora da faixa e texto curto impedem salvar', () => {
  const r = { ...trocarObjetivo(rascunhoNovo('X'), 'resgate').rascunho, nome: 'Ana',
    contexto: 'Falamos em nome da Afinix Corretora, em Rio Preto. Planos de saúde.' };
  assert.ok(oQueFalta({ ...r, limite_trocas: '0' }, { novo: true }).some((f) => /limite/.test(f)));
  assert.ok(oQueFalta({ ...r, tamanho_maximo: '50' }, { novo: true }).some((f) => /tamanho/.test(f)));
  assert.ok(oQueFalta({ ...r, instrucoes: 'curto' }, { novo: true }).some((f) => /120/.test(f)));
});

test('agente de antes do D76: só o canal dele, e o construtor o lê sem perder nada', () => {
  assert.deepEqual(canaisQueServe({ canal: 'whatsapp' }), ['whatsapp']);
  assert.deepEqual(canaisQueServe({ canal: null }), ['whatsapp', 'email', 'sms', 'instagram']);
  const antigo = {
    nome: 'Ana — resgate no WhatsApp', persona: null, objetivo: null, papel: 'Retomada de conversa',
    descricao: 'Responde quem reagiu.', tom: '', instrucoes: 'x'.repeat(200), contexto: '',
    escalar_quando: 'Pedido de proposta.', limite_trocas: 8, tamanho_maximo: 700, proibido: ['garantimos'],
    ai_credential_id: null, autonomo: true,
  };
  const r = rascunhoDe(antigo);
  assert.equal(r.tamanho_maximo, '700');
  assert.equal(r.proibido, 'garantimos');
  // Sem objetivo, o contexto não é exigido: o agente antigo continua salvável.
  assert.deepEqual(oQueFalta(r, { novo: false }), []);
  assert.equal(rotulo({ ...antigo, canal: 'whatsapp' }), 'Retomada de conversa · criado antes do construtor');
});

test('a prévia é o pedido do worker: o mesmo módulo, o mesmo limite por canal', () => {
  const r = { ...trocarObjetivo(rascunhoNovo('Afinix Corretora'), 'resgate').rascunho, nome: 'Ana',
    contexto: 'Falamos em nome da Afinix Corretora, em Rio Preto. Planos de saúde.' };
  for (const c of ['whatsapp', 'email', 'sms', 'instagram'] as const) {
    const p = montarPedido(entradaDaPrevia(r, c));
    assert.equal(p.limite, CANAIS[c].limite, c);
    assert.match(p.sistema, /^Você é Ana, assistente de relacionamento\./);
    assert.match(p.sistema, /Falamos em nome da Afinix Corretora/);
  }
  // Tamanho próprio menor que o do canal: vale o dele.
  assert.equal(montarPedido(entradaDaPrevia({ ...r, tamanho_maximo: '300' }, 'email')).limite, 300);
});

test('a frase de saída sugerida pelo Testar é a que o SQL confere contra a blacklist padrão', async () => {
  const { readFileSync } = await import('node:fs');
  const sql = readFileSync(new URL('./agente_do_canal.sql', import.meta.url), 'utf8');
  assert.ok(sql.includes(`regra_da_resposta(:ta, '${PEDIDO_DE_SAIDA_DO_TESTE}')`),
    'tests/agente_do_canal.sql precisa conferir a mesma frase que a tela sugere');
});
