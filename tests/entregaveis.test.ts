// O que o produto oferece precisa ser o que ele consegue enviar (D54).
//
// O Hub oferecia "Resgate por Direct" — modelo só de Instagram — num catálogo
// onde nenhum provedor de Instagram tem adapter. Criar a campanha funcionava,
// inscrever funcionava, e o motor adiava passo a passo para sempre. Zero erro,
// zero mensagem: o silêncio do D35 uma camada acima.
//
// O que este arquivo sustenta é a SEPARAÇÃO dos dois "não". Um deles se
// resolve cadastrando um chip; o outro não se resolve por tela nenhuma. Fundir
// os dois manda a pessoa procurar uma configuração que não existe.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { cruzarEntregaveis } from '../app/src/entregaveis.ts';

const CATALOGO = [
  { slug: 'uazapi', canal: 'whatsapp', tem_adapter: true, ativo: true },
  { slug: 'meta_cloud', canal: 'whatsapp', tem_adapter: true, ativo: true },
  { slug: 'resend', canal: 'email', tem_adapter: true, ativo: true },
  // No catálogo de propósito e sem adapter de propósito: socket não cabe num
  // diretório que só usa fetch (D30).
  { slug: 'smtp', canal: 'email', tem_adapter: false, ativo: true },
  { slug: 'comtele', canal: 'sms', tem_adapter: true, ativo: true },
  { slug: 'instagram_oficial', canal: 'instagram', tem_adapter: false, ativo: true },
];

const motivo = (lista: ReturnType<typeof cruzarEntregaveis>, canal: string) =>
  lista.find((e) => e.canal === canal)?.motivo;

test('canal sem nenhum provedor com adapter é "não dá", não "falta conta"', () => {
  const r = cruzarEntregaveis(CATALOGO, []);
  assert.equal(motivo(r, 'instagram'), 'sem_adapter');
});

test('canal que sabe enviar mas não tem conta é "ainda não"', () => {
  const r = cruzarEntregaveis(CATALOGO, []);
  assert.equal(motivo(r, 'whatsapp'), 'sem_remetente');
  assert.equal(motivo(r, 'email'), 'sem_remetente');
  assert.equal(motivo(r, 'sms'), 'sem_remetente');
});

test('uma conta ativa de provedor com adapter torna o canal entregável', () => {
  const r = cruzarEntregaveis(CATALOGO, [
    { canal: 'whatsapp', provedor: 'uazapi', estado: 'ativo' },
  ]);
  assert.equal(motivo(r, 'whatsapp'), 'entrega');
  // E só aquele canal: a conta de WhatsApp não fala por e-mail.
  assert.equal(motivo(r, 'email'), 'sem_remetente');
});

test('conta de provedor SEM adapter não torna o canal entregável', () => {
  // Esta é a asserção que o `tem_adapter` do D31 existe para sustentar: a
  // conta existe, está ativa, e mesmo assim o pool não a ofereceria. Contá-la
  // aqui faria a tela prometer o que o despachante recusaria depois.
  const r = cruzarEntregaveis(CATALOGO, [
    { canal: 'email', provedor: 'smtp', estado: 'ativo' },
  ]);
  assert.equal(motivo(r, 'email'), 'sem_remetente');
});

test('conta desativada à mão sai da conta, como sai do pool', () => {
  const r = cruzarEntregaveis(CATALOGO, [
    { canal: 'whatsapp', provedor: 'uazapi', estado: 'desativado' },
  ]);
  assert.equal(motivo(r, 'whatsapp'), 'sem_remetente');
});

test('conta com circuito aberto também não conta', () => {
  // O breaker tirou a conta do pool; a tela concorda com ele em vez de
  // prometer um envio que seria adiado.
  const r = cruzarEntregaveis(CATALOGO, [
    { canal: 'whatsapp', provedor: 'uazapi', estado: 'circuito_aberto' },
  ]);
  assert.equal(motivo(r, 'whatsapp'), 'sem_remetente');
});

test('provedor desligado no catálogo deixa de contar como adapter', () => {
  // `remetentes_disponiveis` pergunta `tem_adapter AND ativo`, as duas. Ler só
  // a primeira era o jeito de a tela discordar do pool.
  const so_um_desligado = CATALOGO.map(
    (p) => (p.canal === 'sms' ? { ...p, ativo: false } : p));
  const r = cruzarEntregaveis(so_um_desligado, [
    { canal: 'sms', provedor: 'comtele', estado: 'ativo' },
  ]);
  assert.equal(motivo(r, 'sms'), 'sem_adapter');
});

test('todo canal do catálogo aparece na resposta, nenhum a mais', () => {
  const r = cruzarEntregaveis(CATALOGO, []);
  assert.deepEqual(
    [...r.map((e) => e.canal)].sort(),
    ['email', 'instagram', 'sms', 'whatsapp'],
  );
});
