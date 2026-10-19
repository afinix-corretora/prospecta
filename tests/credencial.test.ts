// O que falta para salvar uma credencial: a regra da tela (D77b).
//
// Os casos são os de `tests/auditoria.sql`, que cobra o banco. Aqui a mesma
// lista cobra a tela: o botão habilitado onde o banco recusa é o "Credencial
// atualizada." que não atualizou nada.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { mesmoDestino, oQueFalta, preencher, textoDoSegredo, valoresGuardados } from '../app/src/credencial.ts';
import type { CampoDaCredencial } from '../app/src/credencial.ts';

const c = (chave: string, extra: Partial<CampoDaCredencial> = {}): CampoDaCredencial =>
  ({ chave, rotulo: chave, obrigatorio: true, segredo: false, ...extra });

const OPENAI = [c('api_key', { segredo: true }), c('organizacao', { obrigatorio: false }),
                c('base_url', { obrigatorio: false, destino: true })];
const ANTHROPIC = [c('api_key', { segredo: true }), c('base_url', { obrigatorio: false, destino: true })];
const ZOHO = [c('client_id'), c('client_secret', { segredo: true }), c('refresh_token', { segredo: true }),
              c('data_center', { destino: true })];
const PIPEDRIVE = [c('api_token', { segredo: true }), c('dominio_empresa', { destino: true })];

const matriz = { provedor: 'openai', temSegredo: true, config: { organizacao: 'org-matriz' } };
const claude = { provedor: 'anthropic', temSegredo: true, config: { base_url: 'https://proxy.exemplo.com' } };
const zoho = { provedor: 'zoho_crm', temSegredo: true, config: { client_id: '1000.ABC', data_center: 'com' } };
const pipedrive = { provedor: 'pipedrive', temSegredo: true, config: { dominio_empresa: 'afinix' } };

const nomes = (r: ReturnType<typeof oQueFalta>) => r.faltam.map((x) => x.chave);

test('IA: editar só o modelo reaproveita a chave', () => {
  assert.deepEqual(nomes(oQueFalta(OPENAI, 'openai', {}, matriz)), []);
});

test('IA: trocar o provedor com a chave em branco falta a chave, e diz por quê', () => {
  const r = oQueFalta(ANTHROPIC, 'anthropic', {}, matriz);
  assert.deepEqual(nomes(r), ['api_key']);
  assert.equal(r.porQue, 'provedor');
});

test('IA: mudar o endereço com a chave em branco falta a chave', () => {
  const r = oQueFalta(ANTHROPIC, 'anthropic', { base_url: 'https://outro.exemplo.com' }, claude);
  assert.deepEqual(nomes(r), ['api_key']);
  assert.equal(r.porQue, 'endereco');
});

test('IA: o mesmo endereço escrito diferente continua reaproveitando', () => {
  assert.deepEqual(nomes(oQueFalta(ANTHROPIC, 'anthropic', { base_url: 'HTTPS://Proxy.Exemplo.com/' }, claude)), []);
  assert.ok(mesmoDestino(' https://a.com/ ', 'https://A.com'));
});

test('IA: com a chave nova, trocar o provedor não falta nada', () => {
  assert.deepEqual(nomes(oQueFalta(ANTHROPIC, 'anthropic', { api_key: 'nova' }, matriz)), []);
});

test('CRM: trocar uma das chaves pede as outras junto', () => {
  const r = oQueFalta(ZOHO, 'zoho_crm', { client_id: '1000.ABC', data_center: 'com', refresh_token: 'novo' }, zoho);
  assert.deepEqual(nomes(r), ['client_secret']);
  assert.equal(r.porQue, 'outra_chave');
  assert.match(textoDoSegredo(zoho, 'zoho_crm', r.porQue), /pede as outras junto/);
});

test('CRM: mudar o domínio com o token em branco falta o token', () => {
  const r = oQueFalta(PIPEDRIVE, 'pipedrive', { dominio_empresa: 'outra' }, pipedrive);
  assert.deepEqual(nomes(r), ['api_token']);
  assert.equal(r.porQue, 'endereco');
});

test('CRM: trocar a plataforma com o token em branco falta o token', () => {
  assert.equal(oQueFalta(PIPEDRIVE, 'pipedrive', { dominio_empresa: 'afinix' }, zoho).porQue, 'provedor');
});

test('CRM: salvar de novo sem campos reaproveita, e não falta o domínio guardado', () => {
  assert.deepEqual(nomes(oQueFalta(PIPEDRIVE, 'pipedrive', {}, pipedrive)), []);
});

test('nova: sem chave, falta a chave — e sem motivo, porque nada foi guardado', () => {
  const r = oQueFalta(PIPEDRIVE, 'pipedrive', { dominio_empresa: 'x' }, null);
  assert.deepEqual(nomes(r), ['api_token']);
  assert.equal(r.porQue, null);
});

test('o formulário abre com o que não é segredo, e só do mesmo provedor', () => {
  assert.deepEqual(valoresGuardados(OPENAI, matriz, 'openai'), { organizacao: 'org-matriz' });
  assert.deepEqual(valoresGuardados(ANTHROPIC, matriz, 'anthropic'), {});
  // Aberto preenchido, mandar a chave nova não faz faltar o que já estava lá.
  const pre = valoresGuardados(ZOHO, zoho, 'zoho_crm');
  assert.deepEqual(nomes(oQueFalta(ZOHO, 'zoho_crm', { ...pre, client_secret: 'a', refresh_token: 'b' }, zoho)), []);
});

test('com a chave nova, nada é herdado: o obrigatório não secreto em branco falta (D77b)', () => {
  // O banco só mescla a configuração quando a chave fica (`v_secreto = '{}'`).
  assert.deepEqual(nomes(oQueFalta(ZOHO, 'zoho_crm', { client_secret: 'a', refresh_token: 'b' }, zoho)),
    ['client_id', 'data_center']);
  const COMPATIVEL = [c('base_url', { destino: true }), c('api_key', { segredo: true })];
  const gw = { provedor: 'compativel', temSegredo: true, config: { base_url: 'https://gw.exemplo.com' } };
  assert.deepEqual(nomes(oQueFalta(COMPATIVEL, 'compativel', { api_key: 'nova' }, gw)), ['base_url']);
  // Sem chave nova, o guardado vale.
  assert.deepEqual(nomes(oQueFalta(COMPATIVEL, 'compativel', {}, gw)), []);
});

test('digitar o nome de uma credencial e seguir para outra não leva os valores da primeira (D77b)', () => {
  const PIPEFY = [c('client_id'), c('client_secret', { segredo: true }), c('organizacao_id', { obrigatorio: false })];
  const a = { provedor: 'pipefy', temSegredo: true, config: { client_id: 'CID-A', organizacao_id: '111' } };
  const b = { provedor: 'pipefy', temSegredo: true, config: { client_id: 'CID-B', organizacao_id: '222' } };
  const nada = new Set<string>();
  // "Pipefy" casa com A; continuar digitando chega em "Pipefy matriz", que é B.
  const emA = preencher(PIPEFY, a, 'pipefy', {}, nada);
  assert.deepEqual(emA, { client_id: 'CID-A', organizacao_id: '111' });
  assert.deepEqual(preencher(PIPEFY, b, 'pipefy', emA, nada), { client_id: 'CID-B', organizacao_id: '222' });
  // Nome que não casa com nenhuma: só o que a pessoa digitou fica.
  assert.deepEqual(preencher(PIPEFY, null, 'pipefy', { ...emA, client_secret: 's' }, new Set(['client_secret'])),
    { client_secret: 's' });
  // E o que a pessoa digitou vence o guardado.
  assert.deepEqual(preencher(PIPEFY, b, 'pipefy', { client_id: 'MEU' }, new Set(['client_id'])),
    { client_id: 'MEU', organizacao_id: '222' });
});
