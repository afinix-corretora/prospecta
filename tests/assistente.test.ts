// O assistente de configuração (D67): as perguntas, o plano e a permissão.
//
// O que este arquivo sustenta é que o assistente não promete o que o motor não
// faz: canal sem adapter não é escolhível, conta de outro pool não conta,
// resposta órfã não chega ao plano, e nenhum cartão anda sem o papel certo.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  impedimento, montarPlano, NAO, roteiro, situacao, USAR, voltarPara,
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
  assert.equal(quente.opcoes[0]!.valor, USAR);
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
  assert.ok(!plano.acoes.some((a) => a.tipo === 'conectar_conta' && a.canal === 'email'));
  const camp = doTipo(plano.acoes, 'criar_campanha')[0]!;
  assert.deepEqual(camp.canais, ['whatsapp'], 'campanha multicanal com um canal só: cruzamento parcial (D47)');
});

test('chip frio começa baixo, e o plano diz quantos faltam para o volume pedido', () => {
  const plano = montarPlano(FOTO, COMPLETO);
  const wa = doTipo(plano.acoes, 'conectar_conta').find((a) => a.canal === 'whatsapp')!;
  assert.equal(wa.quota, 40);
  assert.equal(wa.pool, 'fria');
  assert.ok(plano.avisos.some((x) => /chega a 40 por dia, e você pediu 200.*mais 4 contas/.test(x)), plano.avisos.join('\n'));
  // E-mail cabe numa conta só: sem aviso.
  assert.equal(doTipo(plano.acoes, 'conectar_conta').find((a) => a.canal === 'email')!.quota, 100);
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
  assert.ok(!doTipo(plano.acoes, 'conectar_conta').length);
});

test('"configurar depois" sem conta nenhuma avisa que o canal fica parado', () => {
  const plano = montarPlano(FOTO, { ...COMPLETO, 'provedor:email': NAO });
  assert.ok(plano.avisos.some((x) => /E-mail ficou sem conta.*nada sai/.test(x)));
});

test('nenhuma ação carrega segredo: só a definição do campo, com a marca', () => {
  const plano = montarPlano(FOTO, COMPLETO);
  const comCampos = plano.acoes.filter((a) => 'campos' in a) as Extract<Acao, { campos: unknown }>[];
  assert.equal(comCampos.length, 4);
  for (const a of comCampos) {
    assert.ok(a.campos.some((c) => c.segredo), `${a.id} marca o segredo para a tela dizer "Vault"`);
    assert.ok(a.campos.every((c) => !('valor' in c)));
  }
});

test('agentes dependem da campanha e da chave nova; com chave existente, só da campanha', () => {
  const nova = doTipo(montarPlano(FOTO, COMPLETO).acoes, 'ligar_agentes')[0]!;
  assert.deepEqual(nova.dependeDe, ['campanha', 'ia']);
  assert.equal(nova.credencial, null);
  assert.deepEqual(nova.agentes.map((a) => [a.canal, a.agente]), [['whatsapp', 'ag-wa'], ['email', 'ag-mail']]);

  const f = { ...FOTO, credenciaisIA: [{ id: 'k1', nome: 'Claude', provedor: 'anthropic', ativo: true }] };
  const plano = montarPlano(f, { ...COMPLETO, ia: `${USAR}:k1` });
  assert.ok(!doTipo(plano.acoes, 'credencial_ia').length);
  const usa = doTipo(plano.acoes, 'ligar_agentes')[0]!;
  assert.deepEqual([usa.credencial, usa.dependeDe], ['k1', ['campanha']]);
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
  assert.ok(!doTipo(montarPlano(FOTO, r).acoes, 'credencial_ia').length);
});

test('CRM sem adapter diz que só guarda', () => {
  const crm = doTipo(montarPlano(FOTO, { ...COMPLETO, crm: 'hubspot' }).acoes, 'conectar_crm')[0]!;
  assert.equal(crm.escreve, false);
  assert.ok(crm.efeitos.some((e) => /só guarda/.test(e)));
});

test('modelos: só o mesmo pool e com canal em comum', () => {
  const p = atual(FOTO, { ...COMPLETO, campanha: undefined as unknown as string, canais: ['email'], 'provedor:email': 'resend' })!;
  assert.equal(p.chave, 'campanha');
  assert.deepEqual(p.opcoes.map((o) => o.valor), ['prospeccao-fria-multicanal', NAO]);
});

// ---------------------------------------------------------------------------
// Permissão e situação
// ---------------------------------------------------------------------------

test('operador cria campanha, mas não conecta conta nem guarda chave', () => {
  const op = { ...FOTO, administra: false };
  const plano = montarPlano(op, COMPLETO);
  for (const a of plano.acoes) {
    const deve = a.tipo === 'criar_campanha' || a.tipo === 'ligar_agentes' || a.tipo === 'importar';
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
