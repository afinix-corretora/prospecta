// O assistente de configuração (D67): as perguntas, o plano e a permissão.
//
// O que este arquivo sustenta é que o assistente não promete o que o motor não
// faz: canal sem adapter não é escolhível, conta de outro pool não conta,
// resposta órfã não chega ao plano, e nenhum cartão anda sem o papel certo.
// E, desde o D68, que ele não pede chave nenhuma: escolhe entre as contas
// conectadas em Configurações, e aponta para lá quando não há.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  cumprida, impedimento, montarPlano, NAO, roteiro, situacao, USAR, voltarPara,
} from '../app/src/assistente.ts';
import type { Acao, Foto, Respostas } from '../app/src/assistente.ts';

const campo = (chave: string, segredo = false) =>
  ({ chave, rotulo: chave, tipo: segredo ? 'senha' as const : 'texto' as const, obrigatorio: true, segredo, ajuda: null });

const prov = (slug: string, canal: string, oficial: boolean, tem_adapter = true) =>
  ({ slug, canal, nome: slug, descricao: '', oficial, tem_adapter, ativo: true, campos: [campo('token', true), campo('base_url')] });

const FOTO: Foto = {
  administra: true, opera: true,
  provedores: [
    prov('meta_cloud', 'whatsapp', true), prov('uazapi', 'whatsapp', false),
    prov('resend', 'email', true), prov('smtp', 'email', true, false),
    prov('comtele', 'sms', true), prov('instagram_oficial', 'instagram', true, false),
  ],
  remetentes: [],
  provedoresIA: [
    { slug: 'anthropic', nome: 'Anthropic', tem_adapter: true, modelos_sugeridos: ['claude-sonnet-5'], campos: [campo('api_key', true)] },
    { slug: 'google', nome: 'Google', tem_adapter: false, modelos_sugeridos: [], campos: [campo('api_key', true)] },
  ],
  credenciaisIA: [],
  provedoresCRM: [
    { slug: 'pipefy', nome: 'Pipefy', tem_adapter: true, campos: [campo('client_id'), campo('client_secret', true)] },
    { slug: 'hubspot', nome: 'HubSpot', tem_adapter: false, campos: [campo('token', true)] },
  ],
  conexoesCRM: [],
  modelos: [
    { slug: 'prospeccao-fria', nome: 'Prospecção fria', descricao: '', tipo: 'fria', canais: ['whatsapp'] },
    { slug: 'prospeccao-fria-multicanal', nome: 'Fria multicanal', descricao: '', tipo: 'fria', canais: ['whatsapp', 'email'] },
    { slug: 'resgate-whatsapp', nome: 'Resgate', descricao: '', tipo: 'morna', canais: ['whatsapp'] },
  ],
  agentes: [
    { id: 'ag-wa', nome: 'Lia', canal: 'whatsapp', tenant_id: null },
    { id: 'ag-mail', nome: 'Rui', canal: 'email', tenant_id: null },
  ],
  campanhas: [],
  contatos: 0,
};

const chaves = (f: Foto, r: Respostas) => roteiro(f, r).passos.map((p) => p.pergunta.chave);
const atual = (f: Foto, r: Respostas) => roteiro(f, r).atual;
const doTipo = <T extends Acao['tipo']>(acoes: readonly Acao[], t: T) =>
  acoes.filter((a): a is Extract<Acao, { tipo: T }> => a.tipo === t);

const COMPLETO: Respostas = {
  canais: ['whatsapp', 'email'], pool: 'fria', porDia: { whatsapp: 200, email: 100 },
  'familia:whatsapp': 'nao', 'provedor:whatsapp': 'uazapi', 'provedor:email': 'resend',
  ia: 'anthropic', crm: 'pipefy', campanha: 'prospeccao-fria-multicanal',
};

// ---------------------------------------------------------------------------
// As perguntas
// ---------------------------------------------------------------------------

test('canais: o que nenhum provedor sabe enviar aparece marcado, e não passa', () => {
  const p = atual(FOTO, {})!;
  assert.equal(p.chave, 'canais');
  assert.match(p.opcoes.find((o) => o.valor === 'instagram')!.indisponivel ?? '', /não é configuração que falta/);
  assert.equal(p.opcoes.find((o) => o.valor === 'email')!.indisponivel, undefined);
  // Escolher o indisponível não avança a conversa.
  assert.equal(atual(FOTO, { canais: ['instagram'] })!.chave, 'canais');
});

test('canal com adapter que o assistente não configura: marcado, e a conversa não gira em falso', () => {
  // Se o Instagram ganhar adapter, a opção não pode virar uma resposta que
  // nenhuma pergunta lê: era um laço infinito em `roteiro`, achado sabotando.
  const f = { ...FOTO, provedores: FOTO.provedores.map((p) => (p.canal === 'instagram' ? { ...p, tem_adapter: true } : p)) };
  const p = atual(f, {})!;
  assert.match(p.opcoes.find((o) => o.valor === 'instagram')!.indisponivel ?? '', /tela dele/);
  assert.equal(atual(f, { canais: ['instagram'] })!.chave, 'canais');
});

test('a conversa inteira, na ordem, e acaba', () => {
  assert.deepEqual(chaves(FOTO, COMPLETO), [
    'canais', 'pool', 'porDia', 'familia:whatsapp', 'provedor:whatsapp', 'provedor:email', 'ia', 'crm', 'campanha',
  ]);
  assert.equal(atual(FOTO, COMPLETO), null);
});

test('oficial e não oficial nunca na mesma lista (D27)', () => {
  const r = { ...COMPLETO, 'provedor:whatsapp': undefined } as unknown as Respostas;
  const nao = atual(FOTO, Object.fromEntries(Object.entries(r).filter(([, v]) => v !== undefined)))!;
  assert.equal(nao.chave, 'provedor:whatsapp');
  assert.deepEqual(nao.opcoes.map((o) => o.valor), ['uazapi', NAO]);

  const ofi = atual(FOTO, { ...COMPLETO, 'familia:whatsapp': 'oficial', 'provedor:whatsapp': 'uazapi' })!;
  assert.equal(ofi.chave, 'provedor:whatsapp', 'uazapi não vale para quem escolheu oficial');
  assert.deepEqual(ofi.opcoes.map((o) => o.valor), ['meta_cloud', NAO]);
});

test('família só é perguntada quando as duas existem', () => {
  const so = { ...FOTO, provedores: FOTO.provedores.filter((p) => p.slug !== 'meta_cloud') };
  assert.ok(!chaves(so, COMPLETO).includes('familia:whatsapp'));
  assert.equal(atual(so, COMPLETO), null);
});

test('provedor sem adapter não é oferecido (D31)', () => {
  const p = atual(FOTO, { canais: ['email'], pool: 'morna', porDia: { email: 50 } })!;
  assert.equal(p.chave, 'provedor:email');
  assert.ok(!p.opcoes.some((o) => o.valor === 'smtp'));
});

test('conta de outro pool não conta como "já tenho"', () => {
  const morna = { ...FOTO, remetentes: [
    { id: 's1', canal: 'whatsapp', provedor: 'uazapi', tipo_permitido: 'morna' as const, quota_diaria: 80, estado: 'ativo', apelido: 'Chip morno', identificador: '5511' },
  ] };
  const fria = atual(morna, { canais: ['whatsapp'], pool: 'fria', porDia: { whatsapp: 40 }, 'familia:whatsapp': 'nao' })!;
  assert.ok(!fria.opcoes.some((o) => o.valor === USAR));
  const quente = atual(morna, { canais: ['whatsapp'], pool: 'morna', porDia: { whatsapp: 40 }, 'familia:whatsapp': 'nao' })!;
  // Com conta, a escolha é usar: conectar mais uma é na tela do canal (D68).
  assert.deepEqual(quente.opcoes.map((o) => o.valor), [USAR, NAO]);
});

test('voltar apaga a resposta e as que vieram depois', () => {
  const r = voltarPara(FOTO, COMPLETO, 'provedor:whatsapp');
  assert.deepEqual(Object.keys(r).sort(), ['canais', 'familia:whatsapp', 'pool', 'porDia'].sort());
  assert.equal(atual(FOTO, r)!.chave, 'provedor:whatsapp');
});

// ---------------------------------------------------------------------------
// O plano
// ---------------------------------------------------------------------------

test('desmarcar um canal tira dele o plano inteiro: resposta órfã não chega', () => {
  const r = { ...COMPLETO, canais: ['whatsapp'] };
  const plano = montarPlano(FOTO, r);
  assert.ok(!plano.acoes.some((a) => a.id === 'config:email'));
  assert.ok(plano.acoes.some((a) => a.id === 'config:whatsapp'), 'o canal que ficou continua no plano');
  const camp = doTipo(plano.acoes, 'criar_campanha')[0]!;
  assert.deepEqual(camp.canais, ['whatsapp'], 'campanha multicanal com um canal só: cruzamento parcial (D47)');
});

test('chip frio começa baixo, e o plano diz quantas contas faltam para o volume pedido', () => {
  const plano = montarPlano(FOTO, COMPLETO);
  const wa = doTipo(plano.acoes, 'configurar').find((a) => a.id === 'config:whatsapp')!;
  assert.equal(wa.rota, '/canais/whatsapp/nao');
  assert.ok(wa.efeitos.some((e) => /lista fria, com até 40 mensagens por dia/.test(e)), wa.efeitos.join('\n'));
  assert.ok(plano.avisos.some((x) => /até 40 por dia, e você pediu 200.*mais 4 contas/.test(x)), plano.avisos.join('\n'));
  // E-mail cabe numa conta só: sem aviso, e a conta se conecta em Configurações.
  const em = doTipo(plano.acoes, 'configurar').find((a) => a.id === 'config:email')!;
  assert.equal(em.rota, '/config/email');
  assert.ok(!plano.avisos.some((x) => x.startsWith('E-mail')));
});

test('usar as contas que existem distribui o total, e só propõe mexer na que muda', () => {
  const f = { ...FOTO, remetentes: [
    { id: 'a', canal: 'whatsapp', provedor: 'uazapi', tipo_permitido: 'fria' as const, quota_diaria: 50, estado: 'ativo', apelido: 'A', identificador: '1' },
    { id: 'b', canal: 'whatsapp', provedor: 'uazapi', tipo_permitido: 'fria' as const, quota_diaria: 30, estado: 'ativo', apelido: 'B', identificador: '2' },
  ] };
  const plano = montarPlano(f, { ...COMPLETO, canais: ['whatsapp'], porDia: { whatsapp: 60 }, 'provedor:whatsapp': USAR });
  const ajustes = doTipo(plano.acoes, 'ajustar_quota');
  assert.deepEqual(ajustes.map((a) => [a.remetente, a.de, a.para]), [['a', 50, 30]]);
  assert.ok(!doTipo(plano.acoes, 'configurar').some((a) => a.id === 'config:whatsapp'), 'quem usa o que tem não é mandado conectar');
});

test('"configurar depois" sem conta nenhuma avisa que o canal fica parado', () => {
  const plano = montarPlano(FOTO, { ...COMPLETO, 'provedor:email': NAO });
  assert.ok(plano.avisos.some((x) => /E-mail ficou sem conta.*nada sai/.test(x)));
});

test('nenhuma ação pede chave: conectar é sempre levar a Configurações (D68)', () => {
  const plano = montarPlano(FOTO, COMPLETO);
  assert.ok(plano.acoes.every((a) => !('campos' in a)), 'nenhum cartão tem campo de catálogo');
  const configurar = doTipo(plano.acoes, 'configurar');
  assert.deepEqual(configurar.map((a) => a.id).sort(), ['config:crm', 'config:email', 'config:ia', 'config:whatsapp']);
  assert.ok(configurar.every((a) => a.exige === 'administra' && a.efeitos.some((e) => /Vault/.test(e)) || a.pronto));
});

test('IA: escolhe o provedor; sem conta, o plano aponta Configurações e o agente espera', () => {
  const plano = montarPlano(FOTO, COMPLETO);
  const ia = doTipo(plano.acoes, 'configurar').find((a) => a.id === 'config:ia')!;
  assert.equal(ia.rota, '/config/ia');
  const ag = doTipo(plano.acoes, 'ligar_agentes')[0]!;
  assert.deepEqual([ag.credencial, ag.dependeDe], [null, ['campanha', 'config:ia']]);
  assert.deepEqual(ag.agentes.map((a) => [a.canal, a.agente]), [['whatsapp', 'ag-wa'], ['email', 'ag-mail']]);
});

test('IA: com contas conectadas, a pergunta seguinte é qual delas — só as do provedor, só as ligadas', () => {
  const f = { ...FOTO, credenciaisIA: [
    { id: 'k1', nome: 'Claude comercial', provedor: 'anthropic', modelo: 'claude-sonnet-5', ativo: true },
    { id: 'k2', nome: 'Claude desligado', provedor: 'anthropic', modelo: 'claude-sonnet-5', ativo: false },
    { id: 'k3', nome: 'Outra IA', provedor: 'openai', modelo: 'gpt-5', ativo: true },
  ] };
  const p = atual(f, COMPLETO)!;
  assert.equal(p.chave, 'ia:conta');
  assert.deepEqual(p.opcoes.map((o) => o.valor), ['k1']);
  const plano = montarPlano(f, { ...COMPLETO, 'ia:conta': 'k1' });
  assert.ok(!doTipo(plano.acoes, 'configurar').some((a) => a.id === 'config:ia'));
  const ag = doTipo(plano.acoes, 'ligar_agentes')[0]!;
  assert.deepEqual([ag.credencial, ag.dependeDe], ['k1', ['campanha']]);
  // Conta de outro provedor não serve de resposta.
  assert.equal(atual(f, { ...COMPLETO, 'ia:conta': 'k3' })!.chave, 'ia:conta');
});

test('sem IA não há agente; IA sem campanha avisa onde escolher o agente', () => {
  assert.ok(!doTipo(montarPlano(FOTO, { ...COMPLETO, ia: NAO }).acoes, 'ligar_agentes').length);
  const plano = montarPlano(FOTO, { ...COMPLETO, campanha: NAO });
  assert.ok(!doTipo(plano.acoes, 'ligar_agentes').length);
  assert.ok(plano.avisos.some((x) => /tela da campanha/.test(x)));
});

test('IA de provedor sem adapter não é escolhível', () => {
  const r = { ...COMPLETO, ia: 'google' };
  assert.equal(atual(FOTO, r)!.chave, 'ia');
  assert.ok(!doTipo(montarPlano(FOTO, r).acoes, 'configurar').some((a) => a.id === 'config:ia'));
});

test('CRM sem adapter diz que só guarda', () => {
  const crm = doTipo(montarPlano(FOTO, { ...COMPLETO, crm: 'hubspot' }).acoes, 'configurar').find((a) => a.id === 'config:crm')!;
  assert.ok(crm.efeitos.some((e) => /só guarda/.test(e)));
});

test('CRM já conectado: pronto lido do banco, e o próximo passo é escolher o que cada fato faz', () => {
  const f = { ...FOTO, conexoesCRM: [{ id: 'p1', nome: 'Pipefy Afinix', provedor: 'pipefy', ativo: true }] };
  const plano = montarPlano(f, COMPLETO);
  const crm = doTipo(plano.acoes, 'configurar').find((a) => a.id === 'config:crm')!;
  assert.equal(crm.pronto, true);
  assert.ok(cumprida(plano.acoes, {}, 'config:crm'), 'pronto no banco cumpre a dependência');
  assert.ok(!cumprida(plano.acoes, {}, 'config:ia'), 'o que não está no banco nem foi feito, não');
  assert.equal(doTipo(plano.acoes, 'abrir').find((a) => a.id === 'crm:fatos')!.rota, '/config/vinculadas/p1');
});

test('modelos: só o mesmo pool e com canal em comum', () => {
  const p = atual(FOTO, { ...COMPLETO, campanha: undefined as unknown as string, canais: ['email'], 'provedor:email': 'resend' })!;
  assert.equal(p.chave, 'campanha');
  assert.deepEqual(p.opcoes.map((o) => o.valor), ['prospeccao-fria-multicanal', NAO]);
});

// ---------------------------------------------------------------------------
// Permissão e situação
// ---------------------------------------------------------------------------

test('operador cria campanha e liga agente, mas o que é de Configurações fica com quem administra', () => {
  const op = { ...FOTO, administra: false };
  const plano = montarPlano(op, COMPLETO);
  for (const a of plano.acoes) {
    const deve = a.tipo === 'criar_campanha' || a.tipo === 'ligar_agentes' || a.tipo === 'abrir';
    assert.equal(impedimento(op, a) === null, deve, a.id);
  }
  const leitor = { ...FOTO, administra: false, opera: false };
  assert.ok(plano.acoes.every((a) => impedimento(leitor, a) !== null));
});

test('situação é lida da foto, e conta desligada não conta', () => {
  const f = { ...FOTO, remetentes: [
    { id: 'a', canal: 'whatsapp', provedor: 'uazapi', tipo_permitido: 'fria' as const, quota_diaria: 40, estado: 'ativo', apelido: 'A', identificador: '1' },
    { id: 'b', canal: 'whatsapp', provedor: 'uazapi', tipo_permitido: 'fria' as const, quota_diaria: 40, estado: 'desativado', apelido: 'B', identificador: '2' },
  ], contatos: 3 };
  const s = Object.fromEntries(situacao(f).map((i) => [i.id, i]));
  assert.equal(s.canais!.feito, true);
  assert.match(s.canais!.detalhe, /WhatsApp: 1 conta, até 40\/dia/);
  assert.equal(s.ia!.feito, false);
  assert.equal(s.contatos!.detalhe, '3 na base');
});
