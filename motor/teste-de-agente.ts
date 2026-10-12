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
import { criarIa, juntarCredenciais, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';
import { aplicarFreios, ehCanal, montarPedido, TETOS_DO_AGENTE, tokensParaCompor } from '../adapters/prompt-do-agente.ts';
import type { EntradaDoPrompt } from '../adapters/prompt-do-agente.ts';

export interface ContaParaTeste {
  /** De que cliente é a conta: é a blacklist DELE que o teste consulta. */
  readonly tenant_id: string;
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
  /** O que a blacklist do cliente faz com este texto (`testar_blacklist`, com o JWT de quem pede). */
  regraDaBlacklist(tenantId: string, texto: string): Promise<{ termo: string; acao: string } | null>;
}

export type PedidoTeste = {
  credencial_id?: unknown; canal?: unknown; texto?: unknown; agente?: unknown;
};

export type ResultadoTeste =
  | { ok: true; situacao: 'pronto'; texto: string; modelo: string }
  | { ok: true; situacao: 'escalar' | 'bloqueado' | 'erro' | 'blacklist' | 'recusa'; motivo: string; modelo: string };

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

/**
 * Os tetos do texto do agente. Acima deles o teste é RECUSADO, dizendo o
 * campo — cortar em silêncio faria o Testar compor e frear sobre um prompt
 * diferente do que o worker manda (o preço no fim de um contexto longo
 * sumiria só aqui, e o freio barraria o valor como inventado). A tela tem o
 * mesmo teto (`maxLength`), então quem chega aqui acima dele não veio da tela.
 * Os tetos moram em `adapters/prompt-do-agente.ts`, que a tela também lê.
 */

class CampoGrande extends Error {}

function campo(a: Record<string, unknown>, nome: keyof typeof TETOS_DO_AGENTE, rotulo: string): string {
  const v = typeof a[nome] === 'string' ? (a[nome] as string).trim() : '';
  if (v.length > TETOS_DO_AGENTE[nome]) {
    throw new CampoGrande(`"${rotulo}" passa de ${TETOS_DO_AGENTE[nome]} caracteres: grande demais para testar`);
  }
  return v;
}

function textos(v: unknown, limites?: { chaves: number; chave: number; valor: number }): Record<string, string> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
  const r: Record<string, string> = {};
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    if (limites && Object.keys(r).length >= limites.chaves) break;
    if (typeof x === 'string' && x.trim()) {
      r[limites ? k.slice(0, limites.chave) : k] = limites ? x.trim().slice(0, limites.valor) : x.trim();
    }
  }
  return r;
}

/**
 * O rascunho do agente como veio da tela, reduzido ao que o prompt lê. Nada
 * aqui é confiado além do tipo e do tamanho: é texto que vai ao modelo da
 * conta do próprio cliente, e só volta para ele.
 */
export function entradaDoPedido(agente: unknown, canal: string, fala: string): EntradaDoPrompt | string | null {
  if (!agente || typeof agente !== 'object' || Array.isArray(agente)) return null;
  const a = agente as Record<string, unknown>;
  try {
    return montarEntrada(a, canal, fala);
  } catch (e) {
    if (e instanceof CampoGrande) return e.message;
    throw e;
  }
}

function montarEntrada(a: Record<string, unknown>, canal: string, fala: string): EntradaDoPrompt | null {
  const instrucoes = campo(a, 'instrucoes', 'O que faz');
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
    agente_nome: campo(a, 'agente_nome', 'Nome') || 'Agente',
    papel: campo(a, 'papel', 'Papel'), descricao: campo(a, 'descricao', 'Descrição'),
    tom: campo(a, 'tom', 'Como fala'), instrucoes, contexto: campo(a, 'contexto', 'Sobre a empresa e a oferta'),
    objetivo: typeof a.objetivo === 'string' && /^[a-z_]{1,40}$/.test(a.objetivo) ? a.objetivo : null,
    escalar_quando: campo(a, 'escalar_quando', 'Passa para uma pessoa quando'),
    proibido: proibidoDoPedido(a.proibido),
    tamanho_maximo: tam,
    contato_nome: texto(a.contato_nome, 80) || null,
    metadados: textos(a.metadados, { chaves: 30, chave: 60, valor: 500 }),
    campanha: texto(a.campanha, 120) || 'Teste',
    historico,
  };
}

function proibidoDoPedido(v: unknown): string[] {
  const linhas = (Array.isArray(v) ? v : []).filter((p): p is string => typeof p === 'string')
    .map((p) => p.trim()).filter(Boolean);
  if (linhas.length > TETOS_DO_AGENTE.proibido || linhas.some((p) => p.length > 300)) {
    throw new CampoGrande(`"Nunca escrever" passa de ${TETOS_DO_AGENTE.proibido} expressões de até 300 caracteres: grande demais para testar`);
  }
  return linhas;
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
  if (typeof entrada === 'string') return recusa(400, entrada);
  if (!entrada) return recusa(400, 'o agente precisa ter o que faz escrito');

  const conta = await porta.credencialVisivel(id);
  if (!conta) return recusa(404, 'conta de IA não encontrada — só quem administra escolhe a conta');
  if (!conta.ativo) return recusa(409, 'esta conta de IA está desligada');
  if (!(PROVEDORES_IA_COM_ADAPTER as readonly string[]).includes(conta.provedor)) {
    return recusa(409, `${conta.provedor} ainda não tem adapter de composição`);
  }

  // Antes do modelo, o que o worker faz antes dele: a blacklist do cliente lê
  // a resposta. Pedido de saída que ela reconhece suprime a pessoa no webhook,
  // e o agente nem chega a vê-la; recusa não chama modelo. Sem isto, o teste
  // mostraria o agente respondendo — ou o motivo falso "palavras que a
  // blacklist não reconhece" — para uma fala que em produção nunca chega a ele.
  const regra = await porta.regraDaBlacklist(conta.tenant_id, fala);
  if (regra && regra.acao === 'suprimir') {
    return { status: 200, corpo: { ok: true, situacao: 'blacklist', modelo: conta.modelo,
      motivo: `em produção esta resposta suprime a pessoa pela blacklist (termo "${regra.termo}"): o agente nem chega a vê-la` } };
  }
  // Endereço errado é fato sobre o ENDEREÇO, não vontade da pessoa (D49): ela
  // continua nos outros canais. Dizer "suprime a pessoa" seria a fusão que o
  // D49 proíbe, na tela.
  if (regra && regra.acao === 'identidade_invalida') {
    return { status: 200, corpo: { ok: true, situacao: 'blacklist', modelo: conta.modelo,
      motivo: `em produção esta resposta marca este endereço como errado (termo "${regra.termo}"): a conversa por ele para, `
        + 'o agente não a vê, e a pessoa continua nos outros canais' } };
  }
  if (regra && regra.acao === 'recusa') {
    return { status: 200, corpo: { ok: true, situacao: 'recusa', modelo: conta.modelo,
      motivo: `a blacklist lê esta resposta como recusa da oferta (termo "${regra.termo}"): o agente não insiste` } };
  }

  // As credenciais como o worker as monta, sem aparar: com `base_url` sujo o
  // Testar erra como a produção erraria, em vez de passar verde.
  let credenciais: Record<string, string>;
  try { credenciais = juntarCredenciais(conta.config, await porta.segredo(id)); }
  catch {
    return { status: 200, corpo: { ok: true, situacao: 'erro', modelo: conta.modelo,
      motivo: 'o segredo desta conta está ilegível no cofre: conecte a conta de novo em Configurações ▸ Provedores de IA' } };
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
