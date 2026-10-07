// O setup por chat (D73): o condutor que decide o próximo passo.
//
// O que este arquivo sustenta:
//
//   - cada peça é configurada logo depois da resposta que a pediu, antes da
//     pergunta seguinte — e a conversa não pula campo obrigatório;
//   - segredo é pedido por último e NUNCA entra no estado: `aceitarValor`
//     recusa, e o condutor só sabe QUE ele foi digitado;
//   - depois de conectar, a resposta vira "usar a que já tenho" e a conversa
//     segue, em vez de perguntar o provedor de novo;
//   - provedor com servidor cria o chip pela conversa; sem servidor, conecta
//     a instância que existe;
//   - quem não administra não configura conta, e a conversa diz isso;
//   - no fim do roteiro, as ações do plano saem uma de cada vez, uma vez só.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  ESTADO_VAZIO, aceitarValor, aposConectar, coletaDa, passoParaOAgente, proximoPasso,
} from '../app/src/setupChat.ts';
import type { EstadoSetup, PassoSetup } from '../app/src/setupChat.ts';
import { NAO, USAR } from '../app/src/assistente.ts';
import type { Foto, Respostas } from '../app/src/assistente.ts';

const campo = (chave: string, segredo = false, obrigatorio = true) =>
  ({ chave, rotulo: chave, tipo: segredo ? 'senha' as const : 'texto' as const, obrigatorio, segredo, ajuda: null });

const prov = (slug: string, canal: string, oficial: boolean, campos = [campo('token', true), campo('base_url')]) =>
  ({ slug, canal, nome: slug, descricao: '', oficial, tem_adapter: true, ativo: true, campos });

const FOTO: Foto = {
  administra: true, opera: true,
  provedores: [
    prov('meta_cloud', 'whatsapp', true), prov('uazapi', 'whatsapp', false),
    prov('resend', 'email', true, [campo('api_key', true), campo('assunto_padrao'), campo('responder_para', false, false)]),
    prov('comtele', 'sms', true, [campo('api_key', true)]),
  ],
  remetentes: [],
  provedoresIA: [
    { slug: 'openai', nome: 'OpenAI', tem_adapter: true, modelos_sugeridos: [], campos: [campo('api_key', true), campo('organizacao', false, false)] },
  ],
  credenciaisIA: [],
  provedoresCRM: [{ slug: 'pipefy', nome: 'Pipefy', tem_adapter: true, campos: [campo('client_id'), campo('client_secret', true)] }],
  conexoesCRM: [],
  modelos: [{ slug: 'fria-wa', nome: 'Fria WhatsApp', descricao: '', tipo: 'fria', canais: ['whatsapp'] }],
  agentes: [{ id: 'ag-wa', nome: 'Lia', canal: 'whatsapp', tenant_id: null }],
  campanhas: [],
  contatos: 0,
};

const R_EMAIL: Respostas = { canais: ['email'], pool: 'morna', porDia: { email: 150 }, 'provedor:email': 'resend' };
const est = (respostas: Respostas, extra: Partial<EstadoSetup> = {}): EstadoSetup => ({ ...ESTADO_VAZIO, respostas, ...extra });
const tipo = (p: PassoSetup) => p.tipo === 'campo' ? `campo:${p.campo.chave}` : p.tipo === 'pergunta' ? `pergunta:${p.pergunta.chave}` : p.tipo;

test('a conta é configurada logo depois da resposta, antes da pergunta seguinte', () => {
  const p = proximoPasso(FOTO, est(R_EMAIL));
  assert.equal(tipo(p), 'campo:identificador', 'o provedor foi escolhido: agora vêm os dados dele, não a pergunta da IA');
});

test('campos: identificador, depois o obrigatório não secreto, segredo por último; opcional não é pedido', () => {
  const col = coletaDa(FOTO, R_EMAIL, 'provedor:email')!;
  assert.deepEqual(col.campos.map((c) => c.chave), ['identificador', 'assunto_padrao', 'api_key']);
  assert.equal(col.campos.at(-1)!.segredo, true);
  assert.equal(col.quota, 150, 'nasce com o que foi pedido, até o ponto de partida do canal');
});

test('segredo não entra no estado: aceitarValor recusa, e o condutor só sabe QUE ele foi digitado', () => {
  const col = coletaDa(FOTO, R_EMAIL, 'provedor:email')!;
  let e = est(R_EMAIL);
  const r1 = aceitarValor(e, col, 'identificador', ' Vendas@Empresa.com.br ');
  assert.ok(r1.ok); e = r1.ok ? r1.estado : e;
  assert.equal(e.valores['canal:email']!.identificador, 'vendas@empresa.com.br', 'normalizado pela regra do motor');
  const r2 = aceitarValor(e, col, 'assunto_padrao', 'Proposta'); assert.ok(r2.ok); e = r2.ok ? r2.estado : e;

  assert.equal(aceitarValor(e, col, 'api_key', 're_123').ok, false);
  assert.equal(tipo(proximoPasso(FOTO, e)), 'campo:api_key');
  const p = proximoPasso(FOTO, e, { 'canal:email': ['api_key'] });
  assert.equal(p.tipo, 'conectar');
  assert.ok(!JSON.stringify(e).includes('re_123'));
  assert.ok(p.tipo === 'conectar' && !('api_key' in p.valores), 'o passo de conectar leva só o que não é segredo');
});

test('valor ruim é recusado com motivo, e o campo continua pedido', () => {
  const col = coletaDa(FOTO, R_EMAIL, 'provedor:email')!;
  const r = aceitarValor(est(R_EMAIL), col, 'identificador', 'não é email');
  assert.equal(r.ok, false);
  const wa = coletaDa(FOTO, { canais: ['whatsapp'], pool: 'fria', porDia: { whatsapp: 40 }, 'familia:whatsapp': 'nao', 'provedor:whatsapp': 'uazapi' }, 'provedor:whatsapp')!;
  assert.equal(aceitarValor(est({}), wa, 'identificador', '123').ok, false);
  const ok = aceitarValor(est({}), wa, 'identificador', '(11) 98888-7777');
  assert.ok(ok.ok && ok.estado.valores['canal:whatsapp']!.identificador === '5511988887777');
});

test('depois de conectar, a resposta vira "usar" e a conversa segue para a próxima pergunta', () => {
  const col = coletaDa(FOTO, R_EMAIL, 'provedor:email')!;
  const e = aposConectar(est(R_EMAIL), col, 'conectada');
  assert.equal(e.respostas['provedor:email'], USAR);
  const f = { ...FOTO, remetentes: [{ id: 'm1', canal: 'email', provedor: 'resend', tipo_permitido: 'morna' as const, quota_diaria: 150, estado: 'ativo', apelido: 'x', identificador: 'v@e.com' }] };
  assert.equal(tipo(proximoPasso(f, e)), 'pergunta:ia');
});

test('com servidor, o chip é CRIADO pela conversa e só o número é pedido; sem, conecta a instância existente', () => {
  const r: Respostas = { canais: ['whatsapp'], pool: 'fria', porDia: { whatsapp: 200 }, 'familia:whatsapp': 'nao', 'provedor:whatsapp': 'uazapi' };
  const sem = coletaDa(FOTO, r, 'provedor:whatsapp')!;
  assert.equal(sem.alvo, 'canal');
  assert.deepEqual(sem.campos.map((c) => c.chave), ['identificador', 'base_url', 'token']);
  const com = coletaDa({ ...FOTO, servidores: [{ id: 's1', provedor: 'uazapi', nome: 'UAZAPI' }] }, r, 'provedor:whatsapp')!;
  assert.equal(com.alvo, 'instancia');
  assert.equal(com.servidor, 's1');
  assert.deepEqual(com.campos.map((c) => c.chave), ['identificador']);
  assert.equal(com.quota, 40, 'chip frio começa no ponto de partida, não no pedido de 200');
});

test('IA: chave antes do modelo, e conectar devolve a conta escolhida para a campanha', () => {
  const r: Respostas = { ...R_EMAIL, 'provedor:email': USAR, ia: 'openai' };
  const col = coletaDa(FOTO, r, 'ia')!;
  assert.deepEqual(col.campos.map((c) => c.chave), ['api_key', 'modelo']);
  const e = aposConectar(est(r), col, 'ok', 'cred-1');
  assert.equal(e.respostas['ia:conta'], 'cred-1');
});

test('quem não administra não configura conta, e a conversa diz isso em vez de pedir a chave', () => {
  const p = proximoPasso({ ...FOTO, administra: false }, est(R_EMAIL));
  assert.equal(p.tipo, 'sem_permissao');
});

test('peça pulada não é pedida de novo', () => {
  const p = proximoPasso(FOTO, est(R_EMAIL, { pulados: ['canal:email'] }));
  assert.equal(tipo(p), 'pergunta:ia');
});

test('fim do roteiro: as ações do plano saem uma de cada vez, e a feita não volta', () => {
  const f: Foto = {
    ...FOTO,
    remetentes: [{ id: 'w1', canal: 'whatsapp', provedor: 'uazapi', tipo_permitido: 'fria', quota_diaria: 40, estado: 'ativo', apelido: 'Chip', identificador: '1' }],
    credenciaisIA: [{ id: 'cred-1', nome: 'OpenAI principal', provedor: 'openai', modelo: 'gpt-5-mini', ativo: true }],
  };
  const r: Respostas = {
    canais: ['whatsapp'], pool: 'fria', porDia: { whatsapp: 40 }, 'familia:whatsapp': 'nao', 'provedor:whatsapp': USAR,
    ia: 'openai', 'ia:conta': 'cred-1', crm: NAO, campanha: 'fria-wa',
  };
  const p1 = proximoPasso(f, est(r));
  assert.ok(p1.tipo === 'acao' && p1.acao.tipo === 'criar_campanha');
  const p2 = proximoPasso(f, est(r, { feitos: { campanha: 'criada' }, produzidos: { campanha: 'c1' } }));
  assert.ok(p2.tipo === 'acao' && p2.acao.tipo === 'ligar_agentes');
  const p3 = proximoPasso(f, est(r, { feitos: { campanha: 'criada', agentes: 'ok' }, produzidos: { campanha: 'c1' } }));
  assert.equal(p3.tipo, 'fim');
  assert.ok(p3.tipo === 'fim' && p3.links[0]!.rota === '/campanhas/c1');
});

test('o agente sabe QUE a conversa pede uma chave, nunca qual é, e só pode preencher o que não é segredo', () => {
  const col = coletaDa(FOTO, R_EMAIL, 'provedor:email')!;
  const p: PassoSetup = { tipo: 'campo', coleta: col, campo: col.campos.at(-1)! };
  const ctx = passoParaOAgente(p) as { segredo: boolean; campos_que_voce_pode_preencher: { chave: string }[] };
  assert.equal(ctx.segredo, true);
  assert.deepEqual(ctx.campos_que_voce_pode_preencher.map((c) => c.chave), ['identificador', 'assunto_padrao']);
});
