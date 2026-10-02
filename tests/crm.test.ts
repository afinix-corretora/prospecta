// O CRM sem rede (D64): o adapter do Pipefy e as duas rotinas do motor.
//
// O `fetch` é falso e grava cada chamada. As asserções que importam não são
// "o feliz funciona", são as que o legado pagou em produção:
//
//   - o token nasce por client_credentials e não é pedido de novo na mesma
//     execução — nem reaproveitado entre duas credenciais diferentes;
//   - GraphQL responde 200 com erro dentro, e isso tem de virar erro;
//   - mover para a fase em que o card já está não chama a mutação (o dreno
//     repete);
//   - o dreno para na primeira falha e grava o que fez até ali.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { PipefyAdapter, valorDoCampo } from '../adapters/pipefy.ts';
import { criarCrm, PLATAFORMAS_COM_ADAPTER } from '../adapters/crm.ts';
import type { AcaoCrm, CardCrm, CrmAdapter } from '../adapters/crm.ts';
import { celulasDoCard, drenarWritebacks, lerFontes } from '../motor/crm.ts';
import type { BancoCrm, FonteVencida, LinhaDoPlano } from '../motor/porta-crm.ts';

interface Chamada { url: string; corpo: string; auth: string | null }

/** `fetch` falso: responde por uma função da chamada e guarda o histórico. */
function buscador(responder: (c: Chamada) => { status?: number; json: unknown }) {
  const chamadas: Chamada[] = [];
  const buscar = (async (url: string | URL | Request, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const c = { url: String(url), corpo: String(init?.body ?? ''), auth: headers.get('Authorization') };
    chamadas.push(c);
    const r = responder(c);
    return new Response(JSON.stringify(r.json), { status: r.status ?? 200 });
  }) as typeof fetch;
  return { buscar, chamadas };
}

const CRED = { client_id: 'cid', client_secret: 'segredo' };
const ehToken = (c: Chamada) => c.url === 'https://app.pipefy.com/oauth/token';
const query = (c: Chamada) => (JSON.parse(c.corpo) as { query: string }).query;
const vars = (c: Chamada) => (JSON.parse(c.corpo) as { variables: Record<string, unknown> }).variables;

// ---------------------------------------------------------------------------
// OAuth
// ---------------------------------------------------------------------------

test('pipefy: token por client_credentials, em formulário, e uma vez só por execução', async () => {
  const { buscar, chamadas } = buscador((c) => ehToken(c)
    ? { json: { access_token: 'tok-1', token_type: 'bearer', expires_in: 2592000 } }
    : { json: { data: { card: { id: '1', current_phase: { id: 'F1' } } } } });
  const p = new PipefyAdapter(buscar);

  await p.executar(CRED, { tipo: 'mover_fase', ref: '1', alvoId: 'F1' });
  await p.executar(CRED, { tipo: 'mover_fase', ref: '1', alvoId: 'F1' });

  const tokens = chamadas.filter(ehToken);
  assert.equal(tokens.length, 1, 'o token não é pedido de novo na mesma execução');
  const form = new URLSearchParams(tokens[0]!.corpo);
  assert.equal(form.get('grant_type'), 'client_credentials');
  assert.equal(form.get('client_id'), 'cid');
  assert.equal(form.get('client_secret'), 'segredo');
  assert.ok(chamadas.filter((c) => !ehToken(c)).every((c) => c.auth === 'Bearer tok-1'));
});

test('pipefy: o token de uma credencial não serve para outra', async () => {
  let n = 0;
  const { buscar, chamadas } = buscador((c) => ehToken(c)
    ? { json: { access_token: `tok-${++n}` } }
    : { json: { data: { card: { id: '1', current_phase: { id: 'F1' } } } } });
  const p = new PipefyAdapter(buscar);
  await p.executar(CRED, { tipo: 'mover_fase', ref: '1', alvoId: 'F1' });
  await p.executar({ client_id: 'outro', client_secret: 's2' }, { tipo: 'mover_fase', ref: '1', alvoId: 'F1' });
  assert.equal(chamadas.filter(ehToken).length, 2);
  assert.equal(chamadas.at(-1)!.auth, 'Bearer tok-2');
});

test('pipefy: credencial incompleta nem chega a chamar', async () => {
  const { buscar, chamadas } = buscador(() => ({ json: {} }));
  await assert.rejects(new PipefyAdapter(buscar).descobrir({ client_id: 'x' }), /client_secret/);
  assert.equal(chamadas.length, 0);
});

test('pipefy: credencial recusada diz o que conferir', async () => {
  const { buscar } = buscador(() => ({ status: 401, json: { error: 'invalid_client' } }));
  await assert.rejects(new PipefyAdapter(buscar).descobrir(CRED), /recusou a credencial.*client_id/);
});

test('pipefy: erro dentro de um 200 é erro, não "nenhum card"', async () => {
  const { buscar } = buscador((c) => ehToken(c)
    ? { json: { access_token: 't' } }
    : { json: { data: { phase: null }, errors: [{ message: 'Permission denied' }] } });
  await assert.rejects(new PipefyAdapter(buscar).listarCards(CRED, ['F1'], 10), /Permission denied/);
});

// ---------------------------------------------------------------------------
// Descoberta e leitura
// ---------------------------------------------------------------------------

test('pipefy: descobre pipes, fases e campos da organização indicada', async () => {
  const { buscar, chamadas } = buscador((c) => {
    if (ehToken(c)) return { json: { access_token: 't' } };
    if (query(c).includes('organization(')) {
      return { json: { data: { organization: { id: 'O1', pipes: [{ id: 'P1', name: 'Vendas' }] } } } };
    }
    return { json: { data: { pipe: {
      id: 'P1', name: 'Vendas',
      start_form_fields: [{ id: 'telefone', label: 'Telefone', type: 'phone', options: [] }],
      phases: [{ id: 'F1', name: 'Novo', fields: [{ id: 'status', label: 'Status', type: 'select', options: ['A', 'B'] }] }],
    } } } };
  });
  const e = await new PipefyAdapter(buscar).descobrir({ ...CRED, organizacao_id: 'O1' });
  assert.equal(vars(chamadas[1]!).id, 'O1');
  assert.deepEqual(e.pipes, [{
    id: 'P1', nome: 'Vendas',
    camposIniciais: [{ id: 'telefone', rotulo: 'Telefone', tipo: 'phone', opcoes: [] }],
    fases: [{ id: 'F1', nome: 'Novo', campos: [{ id: 'status', rotulo: 'Status', tipo: 'select', opcoes: ['A', 'B'] }] }],
  }]);
});

test('pipefy: lista cards paginando e para no limite', async () => {
  const pagina = (ids: string[], proxima: string | null) => ({ json: { data: { phase: { id: 'F1', cards: {
    edges: ids.map((id) => ({ node: { id, title: `Card ${id}`, current_phase: { id: 'F1' }, fields: [] } })),
    pageInfo: { hasNextPage: proxima !== null, endCursor: proxima },
  } } } } });
  const { buscar, chamadas } = buscador((c) => {
    if (ehToken(c)) return { json: { access_token: 't' } };
    return vars(c).depois === 'c2' ? pagina(['3', '4'], null) : pagina(['1', '2'], 'c2');
  });
  const p = new PipefyAdapter(buscar);
  assert.deepEqual((await p.listarCards(CRED, ['F1'], 10)).map((c) => c.id), ['1', '2', '3', '4']);
  assert.deepEqual((await p.listarCards(CRED, ['F1'], 3)).map((c) => c.id), ['1', '2', '3']);
  assert.equal(chamadas.filter((c) => !ehToken(c)).length, 4);
});

test('pipefy: select em array_value e responsável em texto de array viram "a, b"', () => {
  assert.equal(valorDoCampo(null, ['Ouro', 'Prata']), 'Ouro, Prata');
  assert.equal(valorDoCampo('["Fulano","Beltrana"]', []), 'Fulano, Beltrana');
  assert.equal(valorDoCampo('[nota solta', null), '[nota solta');
  assert.equal(valorDoCampo('+55 11 97000-0001', null), '+55 11 97000-0001');
  assert.equal(valorDoCampo(null, null), '');
});

// ---------------------------------------------------------------------------
// Ações
// ---------------------------------------------------------------------------

test('pipefy: mover para onde o card já está não chama a mutação', async () => {
  const { buscar, chamadas } = buscador((c) => ehToken(c)
    ? { json: { access_token: 't' } }
    : { json: { data: { card: { id: '9', current_phase: { id: 'F2', name: 'Conversa' } } } } });
  const r = await new PipefyAdapter(buscar).executar(CRED, { tipo: 'mover_fase', ref: '9', alvoId: 'F2' });
  assert.match(r, /já estava/);
  assert.ok(!chamadas.some((c) => !ehToken(c) && query(c).includes('moveCardToPhase')));
});

test('pipefy: mover de outra fase chama a mutação com card e destino', async () => {
  const { buscar, chamadas } = buscador((c) => {
    if (ehToken(c)) return { json: { access_token: 't' } };
    if (query(c).includes('moveCardToPhase')) return { json: { data: { moveCardToPhase: { card: { id: '9' } } } } };
    return { json: { data: { card: { id: '9', current_phase: { id: 'F1' } } } } };
  });
  await new PipefyAdapter(buscar).executar(CRED, { tipo: 'mover_fase', ref: '9', alvoId: 'F2' });
  const m = chamadas.find((c) => !ehToken(c) && query(c).includes('moveCardToPhase'))!;
  assert.deepEqual(vars(m), { card: '9', fase: 'F2' });
});

test('pipefy: card que não existe é erro, não "já estava"', async () => {
  const { buscar } = buscador((c) => ehToken(c) ? { json: { access_token: 't' } } : { json: { data: { card: null } } });
  await assert.rejects(new PipefyAdapter(buscar).executar(CRED, { tipo: 'mover_fase', ref: '9', alvoId: 'F2' }), /não encontrado/);
});

test('pipefy: preencher manda campo e valor como variáveis, não no texto da query', async () => {
  const { buscar, chamadas } = buscador((c) => ehToken(c)
    ? { json: { access_token: 't' } }
    : { json: { data: { updateCardField: { card: { id: '9' } } } } });
  const valor = 'Respondeu: "quero" } mutation { deleteCard';
  await new PipefyAdapter(buscar).executar(CRED, { tipo: 'preencher_campo', ref: '9', alvoId: 'status_sdr', valor });
  const m = chamadas.find((c) => !ehToken(c))!;
  assert.deepEqual(vars(m), { card: '9', campo: 'status_sdr', valor });
  assert.ok(!query(m).includes('deleteCard'), 'o valor não vai interpolado na query');
});

test('registro de CRM: toda plataforma declarada cria adapter, e a desconhecida não', () => {
  for (const p of PLATAFORMAS_COM_ADAPTER) assert.equal(criarCrm(p).provedor, p);
  assert.throws(() => criarCrm('hubspot'), /sem adapter/);
});

// ---------------------------------------------------------------------------
// O dreno
// ---------------------------------------------------------------------------

class CrmFalso implements CrmAdapter {
  readonly provedor = 'pipefy';
  feitas: AcaoCrm[] = [];
  falharEm: string | null = null;
  async descobrir() { return { pipes: [] }; }
  async listarCards(): Promise<CardCrm[]> { return []; }
  async executar(_c: Record<string, string>, a: AcaoCrm) {
    if (a.alvoId === this.falharEm) throw new Error(`falhou em ${a.alvoId}`);
    this.feitas.push(a);
    return `${a.tipo} ${a.alvoId}`;
  }
}

function bancoFalso(planos: Record<string, LinhaDoPlano[]>, fontes: FonteVencida[] = []) {
  const concluidos: { id: string; ok: boolean; resultado: string; erro?: string }[] = [];
  const execucoes: { id: string; r: Record<string, unknown> }[] = [];
  const ingeridos: { ref: string; identidades: unknown[]; nome: string | null; metadados: Record<string, string> }[] = [];
  let credenciais = 0;
  const banco: BancoCrm = {
    async reivindicarWritebacks() { return Object.keys(planos).map((id) => ({ writeback_id: id, fato: 'respondido' })); },
    async planoDeWriteback(id) { return planos[id] ?? []; },
    async credenciaisDaConexao() { credenciais += 1; return { ...CRED }; },
    async concluirWriteback(id, ok, resultado, erro) { concluidos.push({ id, ok, resultado, erro }); },
    async fontesVencidas() { return fontes; },
    async refsVinculadas() { return new Set(['ja-conhecido']); },
    async ingerirDoCrm(_f, ref, identidades, nome, metadados) {
      ingeridos.push({ ref, identidades, nome, metadados });
      return { acao: 'criado', inscricao: 'inscrito' };
    },
    async registrarExecucaoFonte(id, r) { execucoes.push({ id, r }); },
  };
  return { banco, concluidos, execucoes, ingeridos, credenciais: () => credenciais };
}

const linha = (tipo: LinhaDoPlano['tipo'], alvo: string | null, valor: string | null = null): LinhaDoPlano => ({
  conexao_id: 'C1', provedor: 'pipefy', ref_externa: tipo === 'nada' ? null : '900',
  tipo, alvo_id: alvo, valor, motivo: tipo === 'nada' ? 'contato sem card vinculado nesta plataforma' : null,
});

test('dreno: executa o plano na ordem dada e grava o que fez', async () => {
  const crm = new CrmFalso();
  const b = bancoFalso({
    w1: [linha('mover_fase', 'F_CONVERSA'), linha('preencher_campo', 'status', 'Respondeu')],
    w2: [linha('mover_fase', 'F_PERDIDO')],
  });
  const r = await drenarWritebacks(b.banco, 10, { criar: () => crm });
  assert.deepEqual(crm.feitas.map((a) => a.alvoId), ['F_CONVERSA', 'status', 'F_PERDIDO']);
  assert.deepEqual(r, { reivindicados: 2, escritos: 2, sem_acao: 0, falhas: 0 });
  assert.deepEqual(b.concluidos.map((c) => [c.id, c.ok, c.resultado]), [
    ['w1', true, 'mover_fase F_CONVERSA; preencher_campo status'],
    ['w2', true, 'mover_fase F_PERDIDO'],
  ]);
  assert.equal(b.credenciais(), 1, 'uma conexão, uma credencial, um token na passada');
});

test('dreno: para na primeira falha e diz o que chegou a fazer', async () => {
  const crm = new CrmFalso();
  crm.falharEm = 'F_CONVERSA';
  const b = bancoFalso({ w1: [linha('mover_fase', 'F_CONVERSA'), linha('preencher_campo', 'status', 'x')] });
  const r = await drenarWritebacks(b.banco, 10, { criar: () => crm });
  assert.equal(crm.feitas.length, 0, 'o campo da fase nova não é escrito com o card na fase velha');
  assert.equal(r.falhas, 1);
  assert.equal(b.concluidos[0]!.ok, false);
  assert.match(b.concluidos[0]!.erro!, /falhou em F_CONVERSA/);
});

test('dreno: "nada" tira o fato da fila dizendo por quê, sem chamar a plataforma', async () => {
  let criados = 0;
  const b = bancoFalso({ w1: [linha('nada', null)] });
  const r = await drenarWritebacks(b.banco, 10, { criar: () => { criados += 1; return new CrmFalso(); } });
  assert.deepEqual(r, { reivindicados: 1, escritos: 0, sem_acao: 1, falhas: 0 });
  assert.equal(b.concluidos[0]!.resultado, 'contato sem card vinculado nesta plataforma');
  assert.equal(criados, 0);
  assert.equal(b.credenciais(), 0, 'sem ação, o segredo nem é lido');
});

// ---------------------------------------------------------------------------
// As fontes
// ---------------------------------------------------------------------------

const FONTE: FonteVencida = {
  fonte_id: 'F', conexao_id: 'C1', provedor: 'pipefy', pipe_id: 'P1', fases: ['F_NOVO'],
  mapa: { titulo: 'nome', tel: 'telefone', mail: 'email' }, campaign_id: null,
};

const card = (id: string, campos: { id: string; rotulo: string; valor: string }[]): CardCrm =>
  ({ id, titulo: `Pessoa ${id}`, faseId: 'F_NOVO', campos });

test('fonte: card passa pela MESMA leitura da planilha', () => {
  const c = celulasDoCard(card('1', [
    { id: 'tel', rotulo: 'Telefone', valor: '(11) 97000-0001' },
    { id: 'plano', rotulo: 'Plano atual', valor: 'Amil' },
  ]), FONTE.mapa);
  assert.deepEqual(c, [
    { coluna: 'Título do card', papel: 'nome', chave: 'titulo', valor: 'Pessoa 1' },
    { coluna: 'Telefone', papel: 'telefone', chave: 'telefone', valor: '(11) 97000-0001' },
    { coluna: 'Plano atual', papel: undefined, chave: 'plano_atual', valor: 'Amil' },
  ]);
});

test('fonte: lê, pula o conhecido, ingere o novo e grava o resumo', async () => {
  const crm = new CrmFalso();
  crm.listarCards = async () => [
    card('ja-conhecido', [{ id: 'tel', rotulo: 'Telefone', valor: '11 97000-0009' }]),
    card('1', [{ id: 'tel', rotulo: 'Telefone', valor: '(11) 97000-0001' },
               { id: 'plano', rotulo: 'Plano atual', valor: 'Amil' }]),
    card('2', [{ id: 'tel', rotulo: 'Telefone', valor: '(11) 3333-4444' }]),
  ];
  const b = bancoFalso({}, [FONTE]);
  const [r] = await lerFontes(b.banco, { criar: () => crm });

  assert.equal(b.ingeridos.length, 1, 'o conhecido é pulado e o fixo sozinho é recusado');
  const i = b.ingeridos[0]!;
  assert.equal(i.ref, '1');
  assert.equal(i.nome, 'Pessoa 1');
  assert.deepEqual(i.identidades.map((x) => (x as { canal: string }).canal).sort(), ['sms', 'whatsapp'],
    'celular em coluna genérica vira os dois canais, como na planilha (D33)');
  assert.deepEqual(i.metadados, { plano_atual: 'Amil' });

  assert.equal(r!.lidos, 3);
  assert.equal(r!.novos, 2);
  assert.equal(r!.criados, 1);
  assert.equal(r!.recusados, 1);
  assert.deepEqual(r!.inscricao, { inscrito: 1 });
  assert.match(r!.erros[0]!, /card 2/);
  assert.equal(b.execucoes[0]!.id, 'F');
});

test('fonte: plataforma que não responde grava o erro na fonte, e as outras seguem', async () => {
  const quebrado = new CrmFalso();
  quebrado.listarCards = async () => { throw new Error('Pipefy recusou o token (HTTP 401)'); };
  const b = bancoFalso({}, [FONTE, { ...FONTE, fonte_id: 'G', conexao_id: 'C2' }]);
  const rs = await lerFontes(b.banco, { criar: () => quebrado });
  assert.equal(rs.length, 2);
  assert.match(String(b.execucoes[0]!.r.erro), /401/);
  assert.equal(b.execucoes[1]!.id, 'G');
});
