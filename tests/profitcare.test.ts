// O adapter do ProfitCare sem rede (D70).
//
// O `fetch` é falso e grava cada chamada. O que importa conferir:
//
//   - credencial incompleta ou sem https não chama ninguém — a chave não sai
//     por http, nem para um endereço vazio;
//   - o contato do card entra na estrutura como campo SÓ de leitura: a fonte
//     o mapeia, a ação não pode escrevê-lo;
//   - a paginação segue o `proximo` da API e para no limite pedido;
//   - o contato vira campo que a MESMA leitura da planilha reconhece;
//   - 401 vira a frase que manda revogar ou gerar outra chave, e não "erro".

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { CAMPOS_DO_CONTATO, ProfitCareAdapter, valorProfitCare } from '../adapters/profitcare.ts';
import type { CampoProfitCare } from '../adapters/profitcare.ts';
import { celulasDoCard } from '../motor/crm.ts';
import { lerRegistro } from '../adapters/leitura.ts';

interface Chamada { url: string; corpo: Record<string, unknown>; auth: string | null }

function buscador(responder: (c: Chamada) => { status?: number; json: unknown }) {
  const chamadas: Chamada[] = [];
  const buscar = (async (url: string | URL | Request, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const c = { url: String(url), corpo: JSON.parse(String(init?.body ?? '{}')), auth: headers.get('Authorization') };
    chamadas.push(c);
    const r = responder(c);
    return new Response(JSON.stringify(r.json), { status: r.status ?? 200 });
  }) as typeof fetch;
  return { buscar, chamadas };
}

const CHAVE = 'pc_' + 'a'.repeat(64);
const CRED = { base_url: 'https://crm.exemplo.com.br/', chave: CHAVE };

// ---------------------------------------------------------------------------
// Credencial
// ---------------------------------------------------------------------------

test('profitcare: credencial incompleta ou sem https não chama ninguém', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { funis: [] } }));
  const p = new ProfitCareAdapter(buscar);

  await assert.rejects(p.descobrir({ base_url: 'https://crm.exemplo.com.br' }), /incompleta/);
  await assert.rejects(p.descobrir({ chave: CHAVE }), /incompleta/);
  await assert.rejects(p.descobrir({ base_url: '   ', chave: CHAVE }), /incompleta/);
  await assert.rejects(p.descobrir({ base_url: 'http://crm.exemplo.com.br', chave: CHAVE }), /https/);
  assert.equal(chamadas.length, 0, 'nenhuma chamada sai com credencial ruim');
});

test('profitcare: chama crm-integracao com a chave no Bearer, sem barra dobrada', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { funis: [] } }));
  await new ProfitCareAdapter(buscar).descobrir(CRED);
  assert.equal(chamadas.length, 1);
  assert.equal(chamadas[0]!.url, 'https://crm.exemplo.com.br/functions/v1/crm-integracao');
  assert.equal(chamadas[0]!.auth, `Bearer ${CHAVE}`);
  assert.deepEqual(chamadas[0]!.corpo, { acao: 'estrutura' });
});

// ---------------------------------------------------------------------------
// Estrutura
// ---------------------------------------------------------------------------

test('profitcare: estrutura separa campo do funil, campo da fase e contato só de leitura', async () => {
  const { buscar } = buscador(() => ({
    json: {
      funis: [{
        id: 'FU1', nome: 'Vendas',
        fases: [{ id: 'FA1', nome: 'Novo' }, { id: 'FA2', nome: 'Proposta' }],
        campos: [
          { id: 'C1', label: 'Plano', tipo: 'select', escopo_tipo: 'funil', fase_id: null,
            opcoes: [{ label: 'Amil', value: 'amil' }, 'Bradesco'] },
          { id: 'C2', label: 'Valor da proposta', tipo: 'moeda', escopo_tipo: 'fase', fase_id: 'FA2' },
        ],
      }],
    },
  }));
  const e = await new ProfitCareAdapter(buscar).descobrir(CRED);
  const [pipe] = e.pipes;
  assert.ok(pipe);
  assert.equal(pipe.nome, 'Vendas');

  const contato = pipe.camposIniciais.filter((c: CampoProfitCare) => c.somenteLeitura);
  assert.deepEqual(contato.map((c) => c.id), CAMPOS_DO_CONTATO.map((k) => k.id),
    'o contato entra na estrutura, senão a tela da fonte não tem como mapeá-lo');

  const doFunil = pipe.camposIniciais.filter((c: CampoProfitCare) => !c.somenteLeitura);
  assert.deepEqual(doFunil, [{ id: 'C1', rotulo: 'Plano', tipo: 'select', opcoes: ['Amil', 'Bradesco'] }]);
  assert.deepEqual(pipe.fases.map((f) => [f.id, f.campos.map((c) => c.id)]), [['FA1', []], ['FA2', ['C2']]]);
});

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

test('profitcare: cards seguem o proximo e param no limite', async () => {
  const pagina = (ids: string[], proximo: string | null) => ({
    json: { cards: ids.map((id) => ({ id, titulo: `Card ${id}`, fase_id: 'FA1', contato: null, campos: [] })), proximo },
  });
  const { buscar, chamadas } = buscador((c) => c.corpo.depois_de === undefined
    ? pagina(['1', '2'], 'cur-1')
    : c.corpo.depois_de === 'cur-1' ? pagina(['3', '4'], 'cur-2') : pagina(['5'], null));

  const cards = await new ProfitCareAdapter(buscar).listarCards(CRED, ['FA1', 'FA2'], 3);
  assert.deepEqual(cards.map((c) => c.id), ['1', '2', '3']);
  assert.equal(chamadas.length, 2, 'atingido o limite, não pede a terceira página');
  assert.deepEqual(chamadas[0]!.corpo, { acao: 'cards', fase_ids: ['FA1', 'FA2'], limite: 3 });
  assert.deepEqual(chamadas[1]!.corpo, { acao: 'cards', fase_ids: ['FA1', 'FA2'], limite: 1, depois_de: 'cur-1' });
});

test('profitcare: sem fase pedida não lista nada, e não chama', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { cards: [] } }));
  assert.deepEqual(await new ProfitCareAdapter(buscar).listarCards(CRED, [], 10), []);
  assert.equal(chamadas.length, 0, 'sem fase seria o CRM inteiro');
});

test('profitcare: o contato do card passa pela MESMA leitura da planilha', async () => {
  const { buscar } = buscador(() => ({
    json: {
      cards: [{
        id: 'K1', titulo: 'Maria — PME', fase_id: 'FA1',
        contato: { nome: 'Maria Souza', whatsapp: '(11) 97000-0001', email: '' },
        campos: [{ id: 'C1', rotulo: 'Plano', valor: { label: 'Amil', value: 'amil' } }],
      }],
      proximo: null,
    },
  }));
  const [card] = await new ProfitCareAdapter(buscar).listarCards(CRED, ['FA1'], 10);
  assert.ok(card);
  assert.deepEqual(card.campos, [
    { id: 'contato.nome', rotulo: 'Nome do contato', valor: 'Maria Souza' },
    { id: 'contato.whatsapp', rotulo: 'WhatsApp do contato', valor: '(11) 97000-0001' },
    { id: 'C1', rotulo: 'Plano', valor: 'Amil' },
  ], 'e-mail vazio não vira campo');

  const leitura = lerRegistro(1, celulasDoCard(card, { 'contato.nome': 'nome', 'contato.whatsapp': 'whatsapp' }));
  assert.equal(leitura.tipo, 'contato');
  if (leitura.tipo !== 'contato') return;
  assert.equal(leitura.contato.nome, 'Maria Souza');
  assert.deepEqual(leitura.contato.identidades.map((i) => [i.canal, i.valorNorm]), [['whatsapp', '5511970000001']]);
});

// ---------------------------------------------------------------------------
// Ações
// ---------------------------------------------------------------------------

test('profitcare: mover diz se o card já estava, e repetir é inofensivo', async () => {
  let fase = 'FA1';
  const { buscar, chamadas } = buscador((c) => {
    const ja = fase === c.corpo.fase_id;
    fase = String(c.corpo.fase_id);
    return { json: { ok: true, ja_estava: ja } };
  });
  const p = new ProfitCareAdapter(buscar);
  const acao = { tipo: 'mover_fase', ref: 'K1', alvoId: 'FA2' } as const;
  assert.equal(await p.executar(CRED, acao), 'card K1 movido para a fase FA2');
  assert.equal(await p.executar(CRED, acao), 'card K1 já estava na fase FA2');
  assert.deepEqual(chamadas[0]!.corpo, { acao: 'mover', card_id: 'K1', fase_id: 'FA2' });
});

test('profitcare: preencher manda o valor; campo do contato é recusado sem chamar', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: { ok: true } }));
  const p = new ProfitCareAdapter(buscar);
  assert.equal(await p.executar(CRED, { tipo: 'preencher_campo', ref: 'K1', alvoId: 'C1', valor: 'respondeu' }),
    'campo C1 do card K1 preenchido');
  assert.deepEqual(chamadas[0]!.corpo, { acao: 'preencher', card_id: 'K1', campo_id: 'C1', valor: 'respondeu' });

  await assert.rejects(
    p.executar(CRED, { tipo: 'preencher_campo', ref: 'K1', alvoId: 'contato.whatsapp', valor: 'x' }),
    /do contato/);
  assert.equal(chamadas.length, 1, 'a escrita recusada não chega ao CRM');
});

// ---------------------------------------------------------------------------
// Erros
// ---------------------------------------------------------------------------

test('profitcare: 401 manda conferir a chave; outro erro traz o status e o motivo', async () => {
  const p401 = new ProfitCareAdapter(buscador(() => ({ status: 401, json: { error: 'chave revogada' } })).buscar);
  await assert.rejects(p401.descobrir(CRED), /recusou a chave.*Configurações ▸ Integrações/);

  const p422 = new ProfitCareAdapter(buscador(() => ({ status: 422, json: { error: 'a fase é de outro funil' } })).buscar);
  await assert.rejects(p422.executar(CRED, { tipo: 'mover_fase', ref: 'K1', alvoId: 'FX' }),
    /ProfitCare respondeu 422: a fase é de outro funil/);

  const pVazio = new ProfitCareAdapter(buscador(() => ({ json: null })).buscar);
  await assert.rejects(pVazio.descobrir(CRED), /sem JSON/);
});

test('profitcare: valor jsonb vira texto legível', () => {
  assert.equal(valorProfitCare(null), '');
  assert.equal(valorProfitCare('texto'), 'texto');
  assert.equal(valorProfitCare(42), '42');
  assert.equal(valorProfitCare(false), 'false');
  assert.equal(valorProfitCare(['a', null, 'b']), 'a, b');
  assert.equal(valorProfitCare({ label: 'Amil', value: 'amil' }), 'Amil');
  assert.equal(valorProfitCare([{ label: 'A' }, { label: 'B' }]), 'A, B');
  assert.equal(valorProfitCare({ x: 1 }), '{"x":1}');
});
