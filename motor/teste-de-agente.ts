// "Testar" o agente antes de ligá-lo (D76): o que a edge function
// `agente-testar` decide.
//
// Em simulado ninguém responde, então a primeira vez que alguém leria o que o
// agente escreve seria com um contato de verdade — e, autônomo, o texto já
// teria saído. É o D42 no agente: o prompt é o template, a resposta é a
// mensagem. Aqui ele compõe com o texto que está NA TELA (salvo ou não), pelo
// MESMO `montarPedido` e pelos MESMOS freios do worker, e nada é gravado nem
// enviado.
//
// A conta de IA precisa ser VISÍVEL para quem pede — lida com o JWT dele, o
// RLS de `ai_credentials` responde (só quem administra a enxerga), como em
// `modelos-ia.ts`. Só depois a chave do serviço lê o segredo, que não volta.

import type { Buscador } from '../adapters/tipos.ts';
import type { ModeloIA } from '../adapters/ia.ts';
import { criarIa, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';
import { aplicarFreios, ehCanal, montarPedido, tokensParaCompor } from '../adapters/prompt-do-agente.ts';
import type { EntradaDoPrompt } from '../adapters/prompt-do-agente.ts';

export interface ContaParaTeste {
  readonly provedor: string;
  readonly modelo: string;
  readonly ativo: boolean;
  readonly config: Record<string, unknown>;
}

export interface PortaTeste {
  /** Há uma pessoa logada? A chave anon também é JWT, e ela não pode usar a porta. */
  pessoaLogada(): Promise<boolean>;
  /** A conta como quem pediu a enxerga; `null` quando não alcança. */
  credencialVisivel(id: string): Promise<ContaParaTeste | null>;
  /** O blob do Vault (JSON), pela chave do serviço. */
  segredo(id: string): Promise<string | null>;
}

export type PedidoTeste = {
  credencial_id?: unknown; canal?: unknown; texto?: unknown; agente?: unknown;
};

export type ResultadoTeste =
  | { ok: true; situacao: 'pronto'; texto: string; modelo: string }
  | { ok: true; situacao: 'escalar' | 'bloqueado' | 'erro'; motivo: string; modelo: string };

export type RespostaTeste =
  | { status: 200; corpo: ResultadoTeste }
  | { status: 400 | 401 | 404 | 409; corpo: { ok: false; erro: string } };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function recusa(status: 400 | 401 | 404 | 409, erro: string): RespostaTeste {
  return { status, corpo: { ok: false, erro } };
}

/** Texto do pedido, aparado e com teto: o que não é string vira vazio (o D48 aqui). */
function texto(v: unknown, max: number): string {
  return typeof v === 'string' ? v.trim().slice(0, max) : '';
}

function textos(v: unknown): Record<string, string> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
  const r: Record<string, string> = {};
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) if (typeof x === 'string' && x.trim()) r[k] = x.trim();
  return r;
}

/**
 * O rascunho do agente como veio da tela, reduzido ao que o prompt lê. Nada
 * aqui é confiado além do tipo e do tamanho: é texto que vai ao modelo da
 * conta do próprio cliente, e só volta para ele.
 */
export function entradaDoPedido(agente: unknown, canal: string, fala: string): EntradaDoPrompt | null {
  if (!agente || typeof agente !== 'object' || Array.isArray(agente)) return null;
  const a = agente as Record<string, unknown>;
  const instrucoes = texto(a.instrucoes, 8000);
  if (instrucoes.length < 20) return null;
  const historico = (Array.isArray(a.historico) ? a.historico : [])
    .slice(-6)
    .filter((h): h is { de: 'nos' | 'pessoa'; texto: string } => !!h && typeof h === 'object'
      && ((h as { de?: unknown }).de === 'nos' || (h as { de?: unknown }).de === 'pessoa')
      && typeof (h as { texto?: unknown }).texto === 'string')
    .map((h) => ({ de: h.de, texto: h.texto.slice(0, 1000) }));
  // A fala de teste é a ÚLTIMA mensagem da pessoa: troca a do exemplo, se houver.
  if (historico.length && historico[historico.length - 1]!.de === 'pessoa') historico.pop();
  historico.push({ de: 'pessoa', texto: fala });
  const tam = typeof a.tamanho_maximo === 'number' && Number.isInteger(a.tamanho_maximo)
    && a.tamanho_maximo >= 80 && a.tamanho_maximo <= 4000 ? a.tamanho_maximo : null;
  return {
    canal, texto: fala,
    agente_nome: texto(a.agente_nome, 80) || 'Agente',
    papel: texto(a.papel, 200), descricao: texto(a.descricao, 400),
    tom: texto(a.tom, 4000), instrucoes, contexto: texto(a.contexto, 4000),
    objetivo: typeof a.objetivo === 'string' && /^[a-z_]{1,40}$/.test(a.objetivo) ? a.objetivo : null,
    escalar_quando: texto(a.escalar_quando, 1000),
    proibido: (Array.isArray(a.proibido) ? a.proibido : []).filter((p): p is string => typeof p === 'string')
      .map((p) => p.trim().slice(0, 200)).filter(Boolean).slice(0, 50),
    tamanho_maximo: tam,
    contato_nome: texto(a.contato_nome, 80) || null,
    metadados: textos(a.metadados),
    campanha: texto(a.campanha, 120) || 'Teste',
    historico,
  };
}

export async function testarDoPedido(
  porta: PortaTeste, pedido: PedidoTeste, buscar?: Buscador,
  criar: (provedor: string, buscar?: Buscador) => ModeloIA = criarIa,
): Promise<RespostaTeste> {
  if (!(await porta.pessoaLogada())) return recusa(401, 'entre com a sua conta');

  const id = typeof pedido.credencial_id === 'string' ? pedido.credencial_id : '';
  if (!UUID.test(id)) return recusa(400, 'escolha a conta de IA');
  const canal = typeof pedido.canal === 'string' ? pedido.canal : '';
  if (!ehCanal(canal)) return recusa(400, 'canal inválido');
  const fala = texto(pedido.texto, 1000);
  if (!fala) return recusa(400, 'escreva o que a pessoa disse');
  const entrada = entradaDoPedido(pedido.agente, canal, fala);
  if (!entrada) return recusa(400, 'o agente precisa ter o que faz escrito');

  const conta = await porta.credencialVisivel(id);
  if (!conta) return recusa(404, 'conta de IA não encontrada — só quem administra escolhe a conta');
  if (!conta.ativo) return recusa(409, 'esta conta de IA está desligada');
  if (!(PROVEDORES_IA_COM_ADAPTER as readonly string[]).includes(conta.provedor)) {
    return recusa(409, `${conta.provedor} ainda não tem adapter de composição`);
  }

  const credenciais = textos(conta.config);
  const blob = await porta.segredo(id);
  if (blob) {
    try { Object.assign(credenciais, textos(JSON.parse(blob))); } catch { /* ilegível: o provedor recusa e a tela diz */ }
  }

  const pedidoAoModelo = montarPedido(entrada);
  const r = await criar(conta.provedor, buscar).compor({
    credenciais, modelo: conta.modelo, sistema: pedidoAoModelo.sistema, mensagem: pedidoAoModelo.mensagem,
    maxTokens: tokensParaCompor(pedidoAoModelo.limite),
  });
  if (!r.ok) return { status: 200, corpo: { ok: true, situacao: 'erro', motivo: r.erro, modelo: conta.modelo } };

  const freio = aplicarFreios(r.texto, entrada);
  return {
    status: 200,
    corpo: freio.situacao === 'pronto'
      ? { ok: true, situacao: 'pronto', texto: freio.texto, modelo: conta.modelo }
      : { ok: true, situacao: freio.situacao, motivo: freio.motivo, modelo: conta.modelo },
  };
}
