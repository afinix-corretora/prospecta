// Pipefy (D64).
//
// A única fonte de verdade do OAuth do Pipefy. O token NUNCA é gravado: nasce
// por `client_credentials` na primeira chamada de cada execução, vive na
// instância e morre com ela. A credencial que o gera é do cliente (D59) e mora
// no Vault; o que chega aqui é o par já resolvido pelo worker.
//
// Antes o lugar previsto era `_shared/pipefy.ts`. Mudou para `adapters/`
// porque aqui só entra `fetch`, e é isso que deixa testar a conversa inteira
// com o Pipefy no Node, sem rede (D30). O token continua tendo um lugar só.
//
// O que se aprendeu no SDR legado e está pago aqui:
//
//   - campo de fase só é editável com o card NA fase dele
//     (FIELD_EDITABLE_ONLY_ON_ITS_ORIGINAL_PHASE): mover vem antes, e quem
//     ordena é `plano_de_writeback`;
//   - campo de responsável e de conexão volta como texto de array JSON
//     (`["Fulano"]`), e select volta em `array_value`;
//   - mover para a fase em que o card já está não pode ser erro, porque o
//     dreno repete.

import type { Buscador } from './tipos.ts';
import type { AcaoCrm, CampoCrm, CardCrm, CredenciaisCrm, CrmAdapter, EstruturaCrm, PipeCrm } from './crm.ts';

const TOKEN_URL = 'https://app.pipefy.com/oauth/token';
const GRAPHQL_URL = 'https://api.pipefy.com/graphql';
const POR_PAGINA = 50;

interface CampoBruto {
  id?: unknown; label?: unknown; type?: unknown; options?: unknown;
}

export class PipefyAdapter implements CrmAdapter {
  readonly provedor = 'pipefy';
  private readonly buscar: Buscador;
  private token: string | null = null;
  private tokenDe: string | null = null;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async descobrir(cred: CredenciaisCrm): Promise<EstruturaCrm> {
    const org = (cred.organizacao_id ?? '').trim();
    let ids: string[];

    if (org) {
      const d = await this.consultar<{ organization: { pipes?: { id: string }[] } | null }>(cred,
        'query ($id: ID!) { organization(id: $id) { id name pipes { id name } } }', { id: org });
      if (!d.organization) throw new Error(`organização ${org} não encontrada ou sem acesso`);
      ids = (d.organization.pipes ?? []).map((p) => String(p.id));
    } else {
      const d = await this.consultar<{ organizations: { pipes?: { id: string }[] }[] | null }>(cred,
        'query { organizations { id name pipes { id name } } }', {});
      ids = (d.organizations ?? []).flatMap((o) => (o.pipes ?? []).map((p) => String(p.id)));
    }

    const pipes: PipeCrm[] = [];
    for (const id of ids) {
      const d = await this.consultar<{ pipe: PipeBruto | null }>(cred,
        `query ($id: ID!) { pipe(id: $id) {
           id name
           start_form_fields { id label type options }
           phases { id name fields { id label type options } }
         } }`, { id });
      if (d.pipe) pipes.push(traduzirPipe(d.pipe));
    }
    return { pipes };
  }

  async listarCards(cred: CredenciaisCrm, fases: readonly string[], limite: number): Promise<CardCrm[]> {
    const cards: CardCrm[] = [];
    for (const fase of fases) {
      let depois: string | null = null;
      while (cards.length < limite) {
        const d: { phase: FaseComCards | null } = await this.consultar(cred,
          `query ($id: ID!, $depois: String) { phase(id: $id) {
             id
             cards(first: ${POR_PAGINA}, after: $depois) {
               edges { node {
                 id title current_phase { id }
                 fields { name field { id } value array_value }
               } }
               pageInfo { hasNextPage endCursor }
             }
           } }`, { id: fase, depois });
        if (!d.phase) throw new Error(`fase ${fase} não encontrada ou sem acesso`);

        for (const e of d.phase.cards?.edges ?? []) {
          if (cards.length >= limite) break;
          cards.push(traduzirCard(e.node, fase));
        }
        const pag = d.phase.cards?.pageInfo;
        if (!pag?.hasNextPage || !pag.endCursor) break;
        depois = pag.endCursor;
      }
    }
    return cards;
  }

  async executar(cred: CredenciaisCrm, acao: AcaoCrm): Promise<string> {
    if (acao.tipo === 'mover_fase') {
      const d = await this.consultar<{ card: { current_phase?: { id?: unknown; name?: unknown } } | null }>(cred,
        'query ($id: ID!) { card(id: $id) { id current_phase { id name } } }', { id: acao.ref });
      if (!d.card) throw new Error(`card ${acao.ref} não encontrado ou sem acesso`);
      if (String(d.card.current_phase?.id ?? '') === acao.alvoId) {
        return `card ${acao.ref} já estava na fase ${acao.alvoId}`;
      }
      await this.consultar(cred,
        `mutation ($card: ID!, $fase: ID!) {
           moveCardToPhase(input: { card_id: $card, destination_phase_id: $fase }) { card { id } }
         }`, { card: acao.ref, fase: acao.alvoId });
      return `card ${acao.ref} movido para a fase ${acao.alvoId}`;
    }

    // Sobrescreve, não acrescenta. Acrescentar a um texto longo é o que o
    // legado fazia, e repetido pelo dreno vira o mesmo parágrafo duas vezes.
    // `String!` como no legado, que é o formato que já rodou em produção.
    await this.consultar(cred,
      `mutation ($card: ID!, $campo: ID!, $valor: String!) {
         updateCardField(input: { card_id: $card, field_id: $campo, new_value: $valor }) { card { id } }
       }`, { card: acao.ref, campo: acao.alvoId, valor: acao.valor });
    return `campo ${acao.alvoId} do card ${acao.ref} preenchido`;
  }

  // -------------------------------------------------------------------------

  private async obterToken(cred: CredenciaisCrm): Promise<string> {
    const id = (cred.client_id ?? '').trim();
    const segredo = cred.client_secret ?? '';
    if (!id || !segredo) throw new Error('conexão sem client_id ou client_secret');

    // Uma instância pode atender duas conexões numa passada; o token de uma
    // não serve para a outra.
    if (this.token && this.tokenDe === id) return this.token;

    const corpo = new URLSearchParams({
      grant_type: 'client_credentials', client_id: id, client_secret: segredo,
    });
    const r = await this.buscar(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: corpo.toString(),
    });
    const texto = await r.text();
    if (!r.ok) {
      throw new Error(`Pipefy recusou a credencial (HTTP ${r.status})${r.status === 401 ? ': confira client_id e client_secret' : ''}`);
    }
    let token: unknown;
    try { token = (JSON.parse(texto) as { access_token?: unknown }).access_token; } catch { token = null; }
    if (typeof token !== 'string' || !token) throw new Error('Pipefy não devolveu access_token');

    this.token = token;
    this.tokenDe = id;
    return token;
  }

  private async consultar<T>(cred: CredenciaisCrm, query: string, variables: Record<string, unknown>): Promise<T> {
    const token = await this.obterToken(cred);
    const r = await this.buscar(GRAPHQL_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ query, variables }),
    });
    const texto = await r.text();
    if (r.status === 401) {
      this.token = null;
      throw new Error('Pipefy recusou o token (HTTP 401)');
    }
    if (!r.ok) throw new Error(`Pipefy respondeu HTTP ${r.status}`);

    let corpo: { data?: T; errors?: { message?: unknown }[] };
    try { corpo = JSON.parse(texto); } catch { throw new Error('Pipefy respondeu algo que não é JSON'); }
    // GraphQL responde 200 com erro dentro. Ignorar `errors` é tratar "sem
    // permissão" como "não há cards" — a fonte pareceria vazia.
    if (corpo.errors && corpo.errors.length > 0) {
      const msgs = corpo.errors.map((e) => String(e.message ?? 'erro')).join('; ');
      throw new Error(`Pipefy: ${msgs}`);
    }
    if (!corpo.data) throw new Error('Pipefy respondeu sem data');
    return corpo.data;
  }
}

// ---------------------------------------------------------------------------
// Tradução
// ---------------------------------------------------------------------------

interface PipeBruto {
  id: unknown; name: unknown;
  start_form_fields?: CampoBruto[] | null;
  phases?: { id: unknown; name: unknown; fields?: CampoBruto[] | null }[] | null;
}

interface FaseComCards {
  cards?: {
    edges?: { node: CardBruto }[];
    pageInfo?: { hasNextPage?: boolean; endCursor?: string | null };
  } | null;
}

interface CardBruto {
  id: unknown; title?: unknown;
  current_phase?: { id?: unknown } | null;
  fields?: { name?: unknown; field?: { id?: unknown } | null; value?: unknown; array_value?: unknown }[] | null;
}

function traduzirCampo(c: CampoBruto): CampoCrm {
  return {
    id: String(c.id ?? ''),
    rotulo: String(c.label ?? c.id ?? ''),
    tipo: String(c.type ?? ''),
    opcoes: Array.isArray(c.options) ? c.options.map(String) : [],
  };
}

function traduzirPipe(p: PipeBruto): PipeCrm {
  return {
    id: String(p.id),
    nome: String(p.name ?? p.id),
    camposIniciais: (p.start_form_fields ?? []).map(traduzirCampo),
    fases: (p.phases ?? []).map((f) => ({
      id: String(f.id),
      nome: String(f.name ?? f.id),
      campos: (f.fields ?? []).map(traduzirCampo),
    })),
  };
}

/**
 * O valor de um campo de card como texto.
 *
 * Select e checklist vêm em `array_value`; responsável e conexão vêm em
 * `value` como texto de array JSON. Os dois viram "a, b" — a leitura que
 * decide se é telefone é a de `adapters/leitura.ts`, não esta.
 */
export function valorDoCampo(value: unknown, arrayValue: unknown): string {
  if (Array.isArray(arrayValue) && arrayValue.length > 0) {
    return arrayValue.map((v) => String(v)).join(', ');
  }
  if (typeof value !== 'string') return value == null ? '' : String(value);
  const t = value.trim();
  if (t.startsWith('[') && t.endsWith(']')) {
    try {
      const lista: unknown = JSON.parse(t);
      if (Array.isArray(lista)) return lista.map((v) => String(v)).join(', ');
    } catch { /* texto que só parece array */ }
  }
  return value;
}

function traduzirCard(c: CardBruto, fase: string): CardCrm {
  return {
    id: String(c.id),
    titulo: typeof c.title === 'string' ? c.title : '',
    faseId: String(c.current_phase?.id ?? fase),
    campos: (c.fields ?? [])
      .filter((f) => f.field && f.field.id != null)
      .map((f) => ({
        id: String(f.field?.id),
        rotulo: String(f.name ?? f.field?.id),
        valor: valorDoCampo(f.value, f.array_value),
      })),
  };
}
