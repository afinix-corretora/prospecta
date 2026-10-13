// Ler a empresa por site, Instagram e materiais (D78b): o que a edge function
// `agente-contexto` decide.
//
// Mesmo desenho do "Testar" (`teste-de-agente.ts`): a conta de IA precisa ser
// VISÍVEL para quem pede — lida com o JWT dele, o RLS de `ai_credentials`
// responde (só quem administra a enxerga) —, e só depois a chave do serviço
// lê o segredo, que não volta. Nada é gravado: o material vai ao modelo da
// conta do próprio cliente e o rascunho volta para a tela, que o mostra antes
// de qualquer coisa entrar no agente.
//
// A ordem é a de quem paga cada passo: o que se confere no pedido vem antes da
// conta; a conta, antes de ir ao site de alguém; o site e os arquivos, antes
// do segredo; e o modelo só é chamado quando há o que ler.

import type { Buscador } from '../adapters/tipos.ts';
import { juntarCredenciais, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';
import type { Leitor, Parte } from '../adapters/ia-leitura.ts';
import { criarLeitor, leAnexos } from '../adapters/ia-leitura.ts';
import {
  cabecalhoDaLeitura, cabemJuntos, lerInstagram, lerMaterial, lerSite, MAX_ARQUIVOS, semInformacao,
  SISTEMA_DA_COLETA, tamanhoDoBase64,
} from '../adapters/coleta.ts';
import type { Fonte, MaterialDoPedido } from '../adapters/coleta.ts';
import { TETOS_DO_AGENTE } from '../adapters/prompt-do-agente.ts';

export interface ContaDaColeta {
  readonly tenant_id: string;
  readonly provedor: string;
  readonly modelo: string;
  readonly ativo: boolean;
  readonly config: Record<string, unknown>;
}

export interface PortaDaColeta {
  /** Há uma pessoa logada? A chave anon também é JWT, e ela não pode usar a porta. */
  pessoaLogada(): Promise<boolean>;
  /** A conta como quem pediu a enxerga; `null` quando não alcança. */
  credencialVisivel(id: string): Promise<ContaDaColeta | null>;
  /** O blob do Vault (JSON), pela chave do serviço. */
  segredo(id: string): Promise<string | null>;
}

export interface RedeDaColeta {
  /** Para o site da empresa. A conta de IA usa o `buscar` do leitor. */
  readonly buscar: Buscador;
  readonly resolver: (host: string) => Promise<string[]>;
}

export type PedidoDaColeta = {
  credencial_id?: unknown; empresa?: unknown; site?: unknown; instagram?: unknown; materiais?: unknown;
};

export type ResultadoDaColeta =
  | { ok: true; situacao: 'pronto'; texto: string; fontes: Fonte[]; modelo: string }
  | { ok: true; situacao: 'nada_lido' | 'sem_informacao' | 'erro'; motivo: string; fontes: Fonte[]; modelo: string };

export type RespostaDaColeta =
  | { status: 200; corpo: ResultadoDaColeta }
  | { status: 400 | 401 | 404 | 409 | 413; corpo: { ok: false; erro: string } };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** O rascunho: um resumo, não o material inteiro. A tela tem o teto do campo (20 000). */
export const TOKENS_DA_LEITURA = 3000;

/**
 * Teto do texto que vai ao modelo, somando site, perfil e arquivos — fora o
 * que vai como PDF e imagem, que o provedor mede. Sem ele, dez arquivos de
 * texto e quatro páginas passariam do contexto dos modelos menores e a
 * leitura inteira voltaria como erro.
 */
export const TETO_DO_TEXTO_LIDO = 160_000;

function recusa(status: 400 | 401 | 404 | 409 | 413, erro: string): RespostaDaColeta {
  return { status, corpo: { ok: false, erro } };
}

function texto(v: unknown, max: number): string {
  return typeof v === 'string' ? v.trim().slice(0, max) : '';
}

type Leitura = { site: string; handle: string; perfil: string; materiais: MaterialDoPedido[] };

/** O pedido, só com o tipo e o tamanho conferidos. O conteúdo é conferido por quem o lê. */
function lerPedido(p: PedidoDaColeta): Leitura | string {
  const site = texto(p.site, 2000);
  const ig = p.instagram && typeof p.instagram === 'object' && !Array.isArray(p.instagram)
    ? p.instagram as Record<string, unknown> : {};
  const handle = texto(ig.handle, 200);
  // O texto colado vai ao modelo como está: cortar aqui seria o teto do
  // perfil passando em silêncio. `lerInstagram` corta e diz que cortou.
  const perfil = typeof ig.texto === 'string' ? ig.texto.slice(0, 50_000) : '';
  if (p.materiais !== undefined && !Array.isArray(p.materiais)) return 'materiais inválidos';
  const brutos = (p.materiais ?? []) as unknown[];
  if (brutos.length > MAX_ARQUIVOS) return `até ${MAX_ARQUIVOS} arquivos por leitura`;
  const materiais: MaterialDoPedido[] = [];
  for (const m of brutos) {
    const o = m && typeof m === 'object' && !Array.isArray(m) ? m as Record<string, unknown> : null;
    const nome = o ? texto(o.nome, 200) : '';
    if (!o || !nome || typeof o.base64 !== 'string') return 'cada arquivo precisa de nome e conteúdo';
    materiais.push({ nome, origem: o.origem === 'instagram' ? 'instagram' : 'material', base64: o.base64 });
  }
  if (!site && !handle && !perfil.trim() && !materiais.length) {
    return 'marque e preencha pelo menos uma fonte: site, Instagram ou materiais';
  }
  return { site, handle, perfil, materiais };
}

/**
 * O texto lido entra até o teto, em ordem; o que passa é cortado na fonte que
 * o passou, e a linha dela diz isso. O que vem depois do teto não entra, e
 * também diz.
 */
function noTeto(partes: { parte: Parte; fonte: number }[], fontes: Fonte[]): Parte[] {
  let resta = TETO_DO_TEXTO_LIDO;
  const saida: Parte[] = [];
  for (const { parte, fonte } of partes) {
    if (parte.tipo !== 'texto') { saida.push(parte); continue; }
    const f = fontes[fonte]!;
    if (resta <= 0) {
      fontes[fonte] = { ...f, lida: false, detalhe: `${f.detalhe}; ficou de fora: o texto das outras fontes já enche a leitura` };
      continue;
    }
    if (parte.texto.length > resta) {
      fontes[fonte] = { ...f, detalhe: `${f.detalhe}; cortado no teto da leitura (${TETO_DO_TEXTO_LIDO.toLocaleString('pt-BR')} caracteres somando tudo)` };
      saida.push({ tipo: 'texto', texto: parte.texto.slice(0, resta) });
      resta = 0;
      continue;
    }
    resta -= parte.texto.length;
    saida.push(parte);
  }
  return saida;
}

export async function colherDoPedido(
  porta: PortaDaColeta, pedido: PedidoDaColeta, rede: RedeDaColeta,
  criar: (provedor: string) => Leitor = (provedor) => criarLeitor(provedor),
): Promise<RespostaDaColeta> {
  if (!(await porta.pessoaLogada())) return recusa(401, 'entre com a sua conta');

  const id = typeof pedido.credencial_id === 'string' ? pedido.credencial_id : '';
  if (!UUID.test(id)) return recusa(400, 'escolha a conta de IA que vai ler');
  const lido = lerPedido(pedido);
  if (typeof lido === 'string') return recusa(400, lido);
  const tamanhos = lido.materiais.map((m) => tamanhoDoBase64(m.base64) ?? 0);
  const demais = cabemJuntos(tamanhos);
  if (demais) return recusa(413, demais);

  const conta = await porta.credencialVisivel(id);
  if (!conta) return recusa(404, 'conta de IA não encontrada');
  if (!conta.ativo) return recusa(409, 'esta conta de IA está desligada');
  if (!(PROVEDORES_IA_COM_ADAPTER as readonly string[]).includes(conta.provedor)) {
    return recusa(409, `${conta.provedor} ainda não tem adapter de leitura`);
  }

  const fontes: Fonte[] = [];
  const partes: { parte: Parte; fonte: number }[] = [];
  let conteudo = false;
  // `material`: a parte é o que ler, e não só um dado ao lado (o @ sozinho).
  const juntar = (parte: Parte | null, fonte: Fonte | null, material = true) => {
    if (fonte) fontes.push(fonte);
    if (parte) { partes.push({ parte, fonte: fontes.length - 1 }); conteudo ||= material; }
  };

  if (lido.site) {
    const s = await lerSite(lido.site, rede);
    // Uma página e a linha dela andam juntas; a página que não foi lida tem só a linha.
    let i = 0;
    for (const f of s.fontes) juntar(f.lida ? s.partes[i++] ?? null : null, f);
  }
  const ig = lerInstagram(lido.handle, lido.perfil);
  juntar(ig.parte, ig.fonte, ig.conteudo);
  const anexos = leAnexos(conta.provedor);
  for (const m of lido.materiais) {
    const r = lerMaterial(m, conta.provedor, anexos);
    juntar(r.parte, r.fonte);
  }

  const modelo = conta.modelo;
  if (!conteudo) {
    return { status: 200, corpo: { ok: true, situacao: 'nada_lido', modelo, fontes,
      motivo: 'nada do que foi marcado pôde ser lido — o motivo de cada fonte está na lista' } };
  }

  let credenciais: Record<string, string>;
  try {
    credenciais = juntarCredenciais(conta.config, await porta.segredo(id));
  } catch {
    return { status: 200, corpo: { ok: true, situacao: 'erro', modelo, fontes,
      motivo: 'o segredo desta conta não pôde ser lido — salve a chave de novo em Configurações' } };
  }

  const r = await criar(conta.provedor).ler({
    credenciais, modelo, sistema: SISTEMA_DA_COLETA, maxTokens: TOKENS_DA_LEITURA,
    partes: [cabecalhoDaLeitura(texto(pedido.empresa, 120)), ...noTeto(partes, fontes)],
  });
  if (!r.ok) return { status: 200, corpo: { ok: true, situacao: 'erro', modelo, fontes, motivo: r.erro } };
  if (semInformacao(r.texto)) {
    return { status: 200, corpo: { ok: true, situacao: 'sem_informacao', modelo, fontes,
      motivo: 'o modelo leu e não achou nada sobre a empresa nos materiais' } };
  }
  const rascunho = r.texto.trim();
  if (rascunho.length > TETOS_DO_AGENTE.contexto) {
    return { status: 200, corpo: { ok: true, situacao: 'erro', modelo, fontes,
      motivo: `o rascunho passou de ${TETOS_DO_AGENTE.contexto.toLocaleString('pt-BR')} caracteres; leia menos material de uma vez` } };
  }
  return { status: 200, corpo: { ok: true, situacao: 'pronto', texto: rascunho, modelo, fontes } };
}
