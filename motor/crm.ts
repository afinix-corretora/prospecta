// O motor e o CRM (D64): os fatos saem, os contatos entram.
//
// Duas rotinas, as duas chamadas pelo worker a cada passada, as duas sem
// decidir nada que o SQL já decide:
//
//   drenarWritebacks  pega da `outbox` o que tem destino, pede o plano ao
//                     banco e o executa na plataforma. Quem escolhe card,
//                     ordem e valor é `plano_de_writeback`; aqui é fiação.
//   lerFontes         lê os cards novos das fontes vencidas, passa cada um
//                     pela MESMA leitura da planilha (`adapters/leitura.ts`)
//                     e entrega a `ingerir_do_crm`, que grava, liga e inscreve.
//
// Um writeback que explode não derruba o lote, e uma fonte que explode não
// derruba as outras: cada falha vira resultado gravado, não exceção que sobe.

import type { BancoCrm, FonteVencida, LinhaDoPlano } from './porta-crm.ts';
import type { Buscador } from '../adapters/tipos.ts';
import type { CardCrm, CrmAdapter } from '../adapters/crm.ts';
import { criarCrm } from '../adapters/crm.ts';
import { lerRegistro, type Celula, type Papel } from '../adapters/leitura.ts';
import { identidadesParaJson } from '../adapters/fonte.ts';
import { chaveDeColuna } from '../adapters/csv.ts';

export interface OpcoesCrm {
  readonly buscar?: Buscador;
  readonly criar?: typeof criarCrm;
}

// ---------------------------------------------------------------------------
// Dreno
// ---------------------------------------------------------------------------

export interface ResumoDreno {
  readonly reivindicados: number;
  readonly escritos: number;
  readonly sem_acao: number;
  readonly falhas: number;
}

export async function drenarWritebacks(
  banco: BancoCrm,
  limite: number,
  opcoes: OpcoesCrm = {},
): Promise<ResumoDreno> {
  const criar = opcoes.criar ?? criarCrm;
  const lote = await banco.reivindicarWritebacks(limite);
  const resumo = { reivindicados: lote.length, escritos: 0, sem_acao: 0, falhas: 0 };

  // Um adapter por conexão na passada inteira: o token nasce uma vez por
  // conexão e por execução, e morre com ela. Nunca é gravado.
  const sessoes = new Map<string, { adapter: CrmAdapter; cred: Record<string, string> }>();
  const sessao = async (l: LinhaDoPlano) => {
    let s = sessoes.get(l.conexao_id);
    if (!s) {
      s = { adapter: criar(l.provedor, opcoes.buscar), cred: await banco.credenciaisDaConexao(l.conexao_id) };
      sessoes.set(l.conexao_id, s);
    }
    return s;
  };

  for (const w of lote) {
    const feito: string[] = [];
    let erro: string | null = null;
    let escreveu = false;

    try {
      const plano = await banco.planoDeWriteback(w.writeback_id);
      for (const l of plano) {
        if (l.tipo === 'nada') {
          feito.push(l.motivo ?? 'nada a fazer');
          continue;
        }
        if (!l.ref_externa || !l.alvo_id) {
          // O plano nunca devolve isso; se devolver, é defeito do SQL, e
          // escrever em card nenhum é a resposta segura.
          throw new Error(`plano incompleto para ${l.tipo}`);
        }
        const s = await sessao(l);
        feito.push(await s.adapter.executar(s.cred, l.tipo === 'mover_fase'
          ? { tipo: 'mover_fase', ref: l.ref_externa, alvoId: l.alvo_id }
          : { tipo: 'preencher_campo', ref: l.ref_externa, alvoId: l.alvo_id, valor: l.valor ?? '' }));
        escreveu = true;
      }
      if (plano.length === 0) feito.push('nenhuma plataforma ativa recebe este fato');
    } catch (e) {
      // Parar na primeira falha: a ação seguinte pode depender desta (o campo
      // só é editável na fase nova). A tentativa seguinte repete tudo, e o
      // contrato do adapter é que repetir é inofensivo.
      erro = e instanceof Error ? e.message : String(e);
    }

    const texto = [...feito, ...(erro ? [`erro: ${erro}`] : [])].join('; ');
    await banco.concluirWriteback(w.writeback_id, erro === null, texto, erro ?? undefined);

    if (erro !== null) resumo.falhas += 1;
    else if (escreveu) resumo.escritos += 1;
    else resumo.sem_acao += 1;
  }

  return resumo;
}

// ---------------------------------------------------------------------------
// Fontes
// ---------------------------------------------------------------------------

/** Quantos cards uma fonte lê por passada, no máximo. */
export const CARDS_POR_PASSADA = 300;

const PAPEIS: readonly Papel[] = ['nome', 'origem_ref', 'whatsapp', 'sms', 'telefone', 'email', 'instagram', 'variavel'];

/**
 * Card → células da leitura comum. Campo mapeado ganha o papel; campo não
 * mapeado vira metadado com a chave do rótulo — "plano atual" no Pipefy é
 * `{{plano_atual}}` na cadência, como seria na planilha. `titulo` é o título
 * do card, que no Pipefy quase sempre é o nome da pessoa.
 */
export function celulasDoCard(card: CardCrm, mapa: Readonly<Record<string, string>>): Celula[] {
  const papelDe = (id: string): Papel | undefined => {
    const p = mapa[id];
    return p && (PAPEIS as readonly string[]).includes(p) ? (p as Papel) : undefined;
  };

  const celulas: Celula[] = [];
  const tituloPapel = papelDe('titulo');
  if (tituloPapel) {
    celulas.push({ coluna: 'Título do card', papel: tituloPapel, chave: 'titulo', valor: card.titulo });
  }
  for (const c of card.campos) {
    celulas.push({
      coluna: c.rotulo,
      papel: papelDe(c.id),
      chave: chaveDeColuna(c.rotulo) || c.id,
      valor: c.valor,
    });
  }
  return celulas;
}

export interface ResumoFonte {
  readonly fonte_id: string;
  readonly lidos: number;
  readonly novos: number;
  readonly criados: number;
  readonly atualizados: number;
  readonly inscricao: Record<string, number>;
  readonly recusados: number;
  readonly ignorados: number;
  readonly erros: string[];
  readonly erro?: string;
}

export async function lerFontes(banco: BancoCrm, opcoes: OpcoesCrm = {}): Promise<ResumoFonte[]> {
  const criar = opcoes.criar ?? criarCrm;
  const fontes = await banco.fontesVencidas();
  const resumos: ResumoFonte[] = [];
  const adapters = new Map<string, { adapter: CrmAdapter; cred: Record<string, string> }>();

  for (const f of fontes) {
    let r: ResumoFonte;
    try {
      let s = adapters.get(f.conexao_id);
      if (!s) {
        s = { adapter: criar(f.provedor, opcoes.buscar), cred: await banco.credenciaisDaConexao(f.conexao_id) };
        adapters.set(f.conexao_id, s);
      }
      r = await lerUma(banco, f, s.adapter, s.cred);
    } catch (e) {
      // Fonte que não lê grava o erro e a hora: sem isto, credencial errada
      // seria uma fonte "sem cards novos" para sempre.
      r = {
        fonte_id: f.fonte_id, lidos: 0, novos: 0, criados: 0, atualizados: 0,
        inscricao: {}, recusados: 0, ignorados: 0, erros: [],
        erro: e instanceof Error ? e.message : String(e),
      };
    }
    const { fonte_id: _ignorado, ...gravar } = r;
    await banco.registrarExecucaoFonte(f.fonte_id, gravar);
    resumos.push(r);
  }
  return resumos;
}

async function lerUma(
  banco: BancoCrm,
  f: FonteVencida,
  adapter: CrmAdapter,
  cred: Record<string, string>,
): Promise<ResumoFonte> {
  const cards = await adapter.listarCards(cred, f.fases, CARDS_POR_PASSADA);
  const conhecidos = await banco.refsVinculadas(f.conexao_id);
  const novos = cards.filter((c) => !conhecidos.has(c.id));

  let criados = 0, atualizados = 0, recusados = 0, ignorados = 0;
  const inscricao: Record<string, number> = {};
  const erros: string[] = [];

  for (const [i, card] of novos.entries()) {
    const leitura = lerRegistro(i + 1, celulasDoCard(card, f.mapa));
    ignorados += leitura.ignorados.length;
    if (leitura.tipo === 'recusa') {
      recusados += 1;
      if (erros.length < 5) erros.push(`card ${card.id}: ${leitura.recusa.motivo}`);
      continue;
    }
    try {
      const { acao, inscricao: insc } = await banco.ingerirDoCrm(
        f.fonte_id, card.id, identidadesParaJson(leitura.contato),
        leitura.contato.nome ?? null, leitura.contato.metadados);
      if (acao === 'criado') criados += 1; else atualizados += 1;
      inscricao[insc] = (inscricao[insc] ?? 0) + 1;
    } catch (e) {
      // Fusão de pessoas, card já ligado a outro contato: decisão de
      // operação. O card fica de fora e a próxima passada tenta de novo — e
      // o erro fica visível na fonte até alguém resolver.
      recusados += 1;
      if (erros.length < 5) erros.push(`card ${card.id}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  return {
    fonte_id: f.fonte_id, lidos: cards.length, novos: novos.length,
    criados, atualizados, inscricao, recusados, ignorados, erros,
  };
}
