// ProfitCare (D70).
//
// O CRM do grupo. Até o D70 ele não tinha porta para sistema de fora: só
// recebia lead. A API de integração (`crm-integracao`, no repositório
// `project-cb5d08`) foi construída para este adapter: chave por cliente,
// guardada lá como hash, e quatro ações — estrutura, cards, mover, preencher.
//
// A chave é do cliente (D59) e mora no Vault; chega aqui já resolvida pelo
// worker, junto do endereço do CRM dele (`base_url`). Só `fetch` (D30).
//
// O que muda em relação ao Pipefy:
//
//   - não há OAuth: a chave vai direto no Bearer;
//   - mover para a fase em que o card já está é tratado do lado de lá
//     (`ja_estava`), e repetir continua inofensivo, que é o que o dreno exige;
//   - o contato é um registro à parte, e vira três campos do card ("Nome do
//     contato", "WhatsApp do contato", "E-mail do contato"), para a MESMA
//     leitura da planilha reconhecer telefone e e-mail (`adapters/leitura.ts`).
//     Eles entram na estrutura marcados `somenteLeitura`: a fonte os mapeia,
//     a ação não os oferece.

import type { Buscador } from './tipos.ts';
import type { AcaoCrm, CampoCrm, CardCrm, CredenciaisCrm, CrmAdapter, EstruturaCrm } from './crm.ts';

/**
 * Campo lido do card que a plataforma não deixa preencher: o contato. A tela
 * (`ConfigCRM.tsx`) o oferece para a fonte e não para a ação, senão o dreno
 * queimaria tentativas numa escrita recusada. A marca sobe para `CampoCrm`
 * quando este adapter for registrado em `criarCrm` — mexer em `crm.ts` antes
 * muda o bundle de duas functions publicadas sem mudar o que elas fazem.
 */
export interface CampoProfitCare extends CampoCrm {
  readonly somenteLeitura?: boolean;
}

const POR_PAGINA = 100;

/** O contato do card, como campos com id próprio e rótulo que a leitura entende. */
export const CAMPOS_DO_CONTATO = [
  { chave: 'nome', id: 'contato.nome', rotulo: 'Nome do contato' },
  { chave: 'whatsapp', id: 'contato.whatsapp', rotulo: 'WhatsApp do contato' },
  { chave: 'email', id: 'contato.email', rotulo: 'E-mail do contato' },
] as const;

interface CampoBruto {
  id?: unknown; label?: unknown; tipo?: unknown; opcoes?: unknown;
  escopo_tipo?: unknown; fase_id?: unknown;
}

interface FunilBruto {
  id?: unknown; nome?: unknown;
  fases?: { id?: unknown; nome?: unknown }[] | null;
  campos?: CampoBruto[] | null;
}

interface CardBruto {
  id?: unknown; titulo?: unknown; fase_id?: unknown;
  contato?: Record<string, unknown> | null;
  campos?: { id?: unknown; rotulo?: unknown; valor?: unknown }[] | null;
}

export class ProfitCareAdapter implements CrmAdapter {
  readonly provedor = 'profitcare';
  private readonly buscar: Buscador;

  constructor(buscar: Buscador = fetch) {
    this.buscar = buscar;
  }

  async descobrir(cred: CredenciaisCrm): Promise<EstruturaCrm> {
    const d = await this.chamar<{ funis?: FunilBruto[] }>(cred, { acao: 'estrutura' });
    return {
      pipes: (d.funis ?? []).map((f) => {
        const campos = f.campos ?? [];
        return {
          id: String(f.id),
          nome: String(f.nome ?? f.id),
          camposIniciais: [
            ...CAMPOS_DO_CONTATO.map((k): CampoProfitCare => ({
              id: k.id, rotulo: k.rotulo, tipo: 'contato', opcoes: [], somenteLeitura: true,
            })),
            ...campos.filter((c) => c.escopo_tipo !== 'fase').map(traduzirCampo),
          ],
          fases: (f.fases ?? []).map((fa) => ({
            id: String(fa.id),
            nome: String(fa.nome ?? fa.id),
            campos: campos.filter((c) => c.escopo_tipo === 'fase' && String(c.fase_id) === String(fa.id))
              .map(traduzirCampo),
          })),
        };
      }),
    };
  }

  async listarCards(cred: CredenciaisCrm, fases: readonly string[], limite: number): Promise<CardCrm[]> {
    if (!fases.length || limite <= 0) return [];
    const cards: CardCrm[] = [];
    let depois: string | null = null;
    while (cards.length < limite) {
      const d: { cards?: CardBruto[]; proximo?: string | null } = await this.chamar(cred, {
        acao: 'cards', fase_ids: fases, limite: Math.min(POR_PAGINA, limite - cards.length),
        ...(depois ? { depois_de: depois } : {}),
      });
      for (const c of d.cards ?? []) {
        if (cards.length >= limite) break;
        cards.push(traduzirCard(c));
      }
      if (!d.proximo) break;
      depois = d.proximo;
    }
    return cards;
  }

  async executar(cred: CredenciaisCrm, acao: AcaoCrm): Promise<string> {
    if (acao.tipo === 'mover_fase') {
      const d = await this.chamar<{ ja_estava?: boolean }>(cred,
        { acao: 'mover', card_id: acao.ref, fase_id: acao.alvoId });
      return d.ja_estava
        ? `card ${acao.ref} já estava na fase ${acao.alvoId}`
        : `card ${acao.ref} movido para a fase ${acao.alvoId}`;
    }
    // O contato é lido, não escrito por aqui: a API só preenche campo do funil.
    if (CAMPOS_DO_CONTATO.some((k) => k.id === acao.alvoId)) {
      throw new Error(`${acao.alvoId} é do contato e não se preenche pela integração: escolha um campo do funil`);
    }
    // Sobrescreve, como no Pipefy: repetido pelo dreno, não vira texto dobrado.
    await this.chamar(cred, { acao: 'preencher', card_id: acao.ref, campo_id: acao.alvoId, valor: acao.valor });
    return `campo ${acao.alvoId} do card ${acao.ref} preenchido`;
  }

  // -------------------------------------------------------------------------

  private async chamar<T>(cred: CredenciaisCrm, corpo: Record<string, unknown>): Promise<T> {
    const base = (cred.base_url ?? '').trim().replace(/\/+$/, '');
    const chave = (cred.chave ?? '').trim();
    if (!base || !chave) {
      throw new Error('credencial do ProfitCare incompleta: endereço do CRM e chave de integração são obrigatórios');
    }
    if (!/^https:\/\//.test(base)) throw new Error('o endereço do ProfitCare precisa começar com https://');

    const r = await this.buscar(`${base}/functions/v1/crm-integracao`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${chave}` },
      body: JSON.stringify(corpo),
    });
    const texto = await r.text();
    let json: unknown = null;
    try { json = texto ? JSON.parse(texto) : null; } catch { /* corpo que não é JSON */ }
    const erro = (json as { error?: unknown } | null)?.error;

    if (r.status === 401) {
      throw new Error('o ProfitCare recusou a chave: confira se ela foi revogada ou gere outra em Configurações ▸ Integrações');
    }
    if (!r.ok) {
      throw new Error(`ProfitCare respondeu ${r.status}${erro ? `: ${String(erro)}` : ''}`);
    }
    if (json === null || typeof json !== 'object') throw new Error('ProfitCare respondeu sem JSON');
    return json as T;
  }
}

// ---------------------------------------------------------------------------
// Tradução
// ---------------------------------------------------------------------------

function traduzirCampo(c: CampoBruto): CampoCrm {
  return {
    id: String(c.id ?? ''),
    rotulo: String(c.label ?? c.id ?? ''),
    tipo: String(c.tipo ?? ''),
    opcoes: Array.isArray(c.opcoes)
      ? c.opcoes.map((o) => (o && typeof o === 'object' && 'label' in o ? String((o as { label: unknown }).label) : String(o)))
      : [],
  };
}

/**
 * O valor de um campo como texto. O ProfitCare guarda `jsonb`: lista vira
 * "a, b", objeto com `label` vira o rótulo, número e booleano viram texto.
 * Quem decide se é telefone é `adapters/leitura.ts`, não esta função.
 */
export function valorProfitCare(v: unknown): string {
  if (v == null) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (Array.isArray(v)) return v.map(valorProfitCare).filter(Boolean).join(', ');
  if (typeof v === 'object' && 'label' in v) return valorProfitCare((v as { label: unknown }).label);
  return JSON.stringify(v);
}

function traduzirCard(c: CardBruto): CardCrm {
  const contato = c.contato ?? {};
  const doContato = CAMPOS_DO_CONTATO
    .map((k) => ({ id: k.id, rotulo: k.rotulo, valor: valorProfitCare(contato[k.chave]) }))
    .filter((k) => k.valor);
  return {
    id: String(c.id),
    titulo: typeof c.titulo === 'string' ? c.titulo : '',
    faseId: String(c.fase_id ?? ''),
    campos: [
      ...doContato,
      ...(c.campos ?? []).filter((f) => f.id != null).map((f) => ({
        id: String(f.id),
        rotulo: String(f.rotulo ?? f.id),
        valor: valorProfitCare(f.valor),
      })),
    ],
  };
}
