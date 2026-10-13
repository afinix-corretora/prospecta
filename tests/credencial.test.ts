// O que falta para salvar uma credencial: a regra da tela (D77b).
//
// Os casos são os de `tests/auditoria.sql`, que cobra o banco. Aqui a mesma
// lista cobra a tela: o botão habilitado onde o banco recusa é o "Credencial
// atualizada." que não atualizou nada.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { mesmoDestino, oQueFalta, textoDoSegredo, valoresGuardados } from '../app/src/credencial.ts';
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
