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
// do segredo; e o modelo só é chamado quando há o que ler — e quando ainda há
// tempo para ele responder dentro dos 150 s da edge function.

import type { Buscador } from '../adapters/tipos.ts';
import { juntarCredenciais, PROVEDORES_IA_COM_ADAPTER } from '../adapters/ia.ts';
import type { Leitor, Parte } from '../adapters/ia-leitura.ts';
import { criarLeitor, leAnexos, PRAZO_DO_MODELO_MS } from '../adapters/ia-leitura.ts';
import {
  cabecalhoDaLeitura, cabemJuntos, cortar, lerInstagram, lerMaterial, lerSite, letra, MAX_ARQUIVOS, semInformacao,
  separarConferir, SISTEMA_DA_COLETA, tamanhoDoBase64, tirarCarenciaSemEscopo,
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
  readonly resolver: (host: string, sinal?: AbortSignal) => Promise<string[]>;
}

export interface OpcoesDaColeta {
  /** O leitor da conta, com o prazo que sobrou. Os testes trocam por um de mentira. */
  readonly criar?: (provedor: string, prazoMs: number) => Leitor;
  /** O relógio, em ms. */
  readonly agora?: () => number;
  /**
   * Quando o pedido CHEGOU, pelo mesmo relógio. O corpo de até 20 MB leva
   * tempo para subir, e esse tempo também conta nos 150 s do Supabase: medir
   * a partir daqui é medir o pedido inteiro.
   */
  readonly inicio?: number;
}

export type PedidoDaColeta = {
  credencial_id?: unknown; empresa?: unknown; site?: unknown; instagram?: unknown; materiais?: unknown;
};

export type ResultadoDaColeta =
  | { ok: true; situacao: 'pronto'; texto: string; conferir: string; fontes: Fonte[]; modelo: string }
  | { ok: true; situacao: 'nada_lido' | 'sem_informacao' | 'erro'; motivo: string; fontes: Fonte[]; modelo: string };

export type RespostaDaColeta =
  | { status: 200; corpo: ResultadoDaColeta }
  | { status: 400 | 401 | 404 | 409 | 413; corpo: { ok: false; erro: string } };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * O teto de tokens da resposta. No chat completions é o rascunho, e o que
 * raciocina ganha a folga de `ia.ts`. No Claude, o teto vale para o
 * raciocínio E o texto, e os modelos atuais raciocinam sem que se peça: com
 * 3000, um material grande acabava em "texto cortado". Na Anthropic o teto
 * não muda o custo — paga-se o que o modelo escreve —, mas no OpenRouter ele
 * muda o SALDO exigido: a conta com pouco crédito recebe 402 dizendo quanto
 * cabe, e a leitura é refeita uma vez com esse teto (`CABE_SO`). O tamanho do
 * rascunho é barrado adiante, no teto do campo.
 */
export const TOKENS_DA_LEITURA = 3000;
export const TOKENS_DA_LEITURA_CLAUDE = 16_000;

/**
 * Teto do texto que vai ao modelo, somando site, perfil e arquivos — fora o
 * que vai como PDF e imagem, que o provedor mede. Sem ele, dez arquivos de
 * texto e quatro páginas passariam do contexto dos modelos menores e a
 * leitura inteira voltaria como erro.
 */
export const TETO_DO_TEXTO_LIDO = 160_000;

/** O pedido inteiro, abaixo dos 150 s em que o Supabase devolve 504 sem corpo. */
export const PRAZO_TOTAL_MS = 140_000;
/** Menos que isto para o modelo, e a leitura é recusada antes de ser paga. */
export const PRAZO_MINIMO_DO_MODELO_MS = 20_000;

/**
 * O erro de quem não aceita o TIPO do anexo — o OpenRouter devolve 404 "No
 * endpoints found that support image input", a OpenAI 400. Palavra solta
 * ("pdf", "image") não basta: o limite de páginas de um PDF também fala em
 * PDF, e o diagnóstico seria o errado.
 */
const NAO_LE_ANEXO = /no endpoints? found that supports? (image|file|pdf)|(does not|doesn't|do not) support (image|file|pdf|document)|(image|file|pdf|document)s? (input|inputs|content|url)s? (is|are) not supported|not supported for this model|image_url is only supported|modalit|unsupported (content|file|image|mime)|invalid (content|image|file) type/i;
/** O erro de TAMANHO com anexo: o resto é lido de novo sem os anexos, que levam o motivo. */
const PASSOU_DO_LIMITE = /prompt is too long|too large|maximum context length|context[_ ]length[_ ]exceeded|pages? may be provided|image exceeds|dimensions exceed|request_too_large|request exceeds/i;
/** O que parece tamanho e não é: saldo, cota e limite por minuto não melhoram tirando arquivo. */
const NAO_E_TAMANHO = /HTTP (402|429)|quota|rate.?limit|max_tokens|credits?\b/i;
/** O arquivo que o provedor não conseguiu abrir: PDF truncado, imagem corrompida. */
const ILEGIVEL = /could not process image|pdf specified was not valid|invalid (file|image) data|does not represent a valid image|unable to determine image format|could not (be )?(read|parse|open)|corrupt/i;
/** O 402 do OpenRouter diz quanto cabe: "can only afford 5333". */
const CABE_SO = /can only afford (\d+)/i;

function recusa(status: 400 | 401 | 404 | 409 | 413, erro: string): RespostaDaColeta {
  return { status, corpo: { ok: false, erro } };
}

function texto(v: unknown, max: number): string {
  return typeof v === 'string' ? cortar(v.trim(), max) : '';
}

type Leitura = { site: string; handle: string; perfil: string; materiais: MaterialDoPedido[] };

/**
 * O pedido, só com o tipo e o tamanho conferidos. O conteúdo é conferido por
 * quem o lê. Nada que vai virar uma decisão é cortado aqui: o nome do arquivo
 * cortado perdia a extensão, e o PDF que a tela aceitou era recusado como "não
 * é PDF". Grande demais é recusa dita.
 */
function lerPedido(p: PedidoDaColeta): Leitura | string {
  if (typeof p.site === 'string' && p.site.trim().length > 2000) return 'o endereço do site é longo demais';
  const site = typeof p.site === 'string' ? p.site.trim() : '';
  const ig = p.instagram && typeof p.instagram === 'object' && !Array.isArray(p.instagram)
    ? p.instagram as Record<string, unknown> : {};
  if (typeof ig.handle === 'string' && ig.handle.trim().length > 200) return 'o @ do Instagram é longo demais';
  const handle = typeof ig.handle === 'string' ? ig.handle.trim() : '';
  // O texto colado vai ao modelo como está, até o teto do perfil, que
  // `lerInstagram` aplica dizendo que cortou.
  const perfil = typeof ig.texto === 'string' ? cortar(ig.texto, 50_000) : '';
  if (p.materiais !== undefined && !Array.isArray(p.materiais)) return 'materiais inválidos';
  const brutos = (p.materiais ?? []) as unknown[];
  if (brutos.length > MAX_ARQUIVOS) return `até ${MAX_ARQUIVOS} arquivos por leitura`;
  const materiais: MaterialDoPedido[] = [];
  for (const m of brutos) {
    const o = m && typeof m === 'object' && !Array.isArray(m) ? m as Record<string, unknown> : null;
    const nome = o && typeof o.nome === 'string' ? o.nome.trim() : '';
    if (!o || !nome || typeof o.base64 !== 'string') return 'cada arquivo precisa de nome e conteúdo';
    // O teto do nome de verdade (200) é de `conferirArquivo`, que recusa só o arquivo, dizendo por quê.
    if (nome.length > 1000) return 'nome de arquivo inválido';
    materiais.push({ nome, origem: o.origem === 'instagram' ? 'instagram' : 'material', base64: o.base64 });
  }
  if (!site && !handle && !perfil.trim() && !materiais.length) {
    return 'marque e preencha pelo menos uma fonte: site, Instagram ou materiais';
  }
  return { site, handle, perfil, materiais };
}

type Juntada = { parte: Parte; fonte: number };

/**
 * O texto lido entra até o teto, em ordem; o que passa é cortado na fonte que
 * o passou, e a linha dela diz isso. O que vem depois do teto não entra, e
 * também diz.
 */
function noTeto(partes: readonly Juntada[], fontes: Fonte[]): Juntada[] {
  let resta = TETO_DO_TEXTO_LIDO;
  const saida: Juntada[] = [];
  for (const j of partes) {
    const { parte, fonte } = j;
    if (parte.tipo !== 'texto') { saida.push(j); continue; }
    const f = fontes[fonte]!;
    if (resta <= 0) {
      fontes[fonte] = { ...f, lida: false, detalhe: `${f.detalhe}; ficou de fora: o texto das outras fontes já enche a leitura` };
      continue;
    }
    if (parte.texto.length > resta) {
      fontes[fonte] = { ...f, detalhe: `${f.detalhe}; cortado no teto da leitura (${TETO_DO_TEXTO_LIDO.toLocaleString('pt-BR')} caracteres somando tudo)` };
      saida.push({ parte: { tipo: 'texto', texto: cortar(parte.texto, resta) }, fonte });
      resta = 0;
      continue;
    }
    resta -= parte.texto.length;
    saida.push(j);
  }
  return saida;
}

export async function colherDoPedido(
  porta: PortaDaColeta, pedido: PedidoDaColeta, rede: RedeDaColeta, opcoes: OpcoesDaColeta = {},
): Promise<RespostaDaColeta> {
  const agora = opcoes.agora ?? Date.now;
  const criar = opcoes.criar ?? ((provedor: string, prazoMs: number) => criarLeitor(provedor, fetch, prazoMs));
  const inicio = opcoes.inicio ?? agora();
  if (!(await porta.pessoaLogada())) return recusa(401, 'entre com a sua conta');

  const id = typeof pedido.credencial_id === 'string' ? pedido.credencial_id : '';
  if (!UUID.test(id)) return recusa(400, 'escolha a conta de IA que vai ler');
  const lido = lerPedido(pedido);
  if (typeof lido === 'string') return recusa(400, lido);
  const tamanhos = lido.materiais.map((m) => tamanhoDoBase64(m.base64) ?? 0);
  const demais = cabemJuntos(tamanhos);
  if (demais) return recusa(413, demais);
  // O envio dos arquivos já gastou o que sobraria ao modelo: dizer isso antes de ler o site de alguém.
  if (PRAZO_TOTAL_MS - (agora() - inicio) < PRAZO_MINIMO_DO_MODELO_MS + 10_000) {
    return recusa(413, 'o envio dos arquivos levou tempo demais e não sobraria tempo para ler: anexe menos arquivos, ou menores');
  }

  const conta = await porta.credencialVisivel(id);
  if (!conta) return recusa(404, 'conta de IA não encontrada');
  if (!conta.ativo) return recusa(409, 'esta conta de IA está desligada');
  if (!(PROVEDORES_IA_COM_ADAPTER as readonly string[]).includes(conta.provedor)) {
    return recusa(409, `${conta.provedor} ainda não tem adapter de leitura`);
  }

  const fontes: Fonte[] = [];
  const juntadas: Juntada[] = [];
  let conteudo = false;
  let conteudoEmTexto = false;
  // `material`: a parte é o que ler, e não só um dado ao lado (o @ sozinho).
  const juntar = (parte: Parte | null, fonte: Fonte | null, material = true) => {
    if (fonte) fontes.push(fonte);
    if (!parte) return;
    juntadas.push({ parte, fonte: fontes.length - 1 });
    conteudo ||= material;
    conteudoEmTexto ||= material && parte.tipo === 'texto';
  };

  const antesDoSite = agora();
  if (lido.site) {
    const s = await lerSite(lido.site, rede);
    // Uma página e a linha dela andam juntas; a página que não foi lida tem só a linha.
    let i = 0;
    for (const f of s.fontes) juntar(f.lida ? s.partes[i++] ?? null : null, f);
  }
  const ig = lerInstagram(lido.handle, lido.perfil);
  juntar(ig.parte, ig.fonte, ig.conteudo);
  const anexos = leAnexos(conta.provedor);
  let arquivos = 0, prints = 0;
  for (const m of lido.materiais) {
    const apelido = m.origem === 'instagram' ? `Print ${letra(prints++)}` : `Arquivo ${letra(arquivos++)}`;
    const r = lerMaterial(m, conta.provedor, anexos, apelido);
    juntar(r.parte, r.fonte);
  }

  const modelo = conta.modelo;
  const erro = (motivo: string): RespostaDaColeta => ({ status: 200, corpo: { ok: true, situacao: 'erro', modelo, fontes, motivo } });
  if (!conteudo) {
    return { status: 200, corpo: { ok: true, situacao: 'nada_lido', modelo, fontes,
      motivo: 'nada do que foi marcado pôde ser lido — o motivo de cada fonte está na lista' } };
  }

  let credenciais: Record<string, string>;
  try {
    credenciais = juntarCredenciais(conta.config, await porta.segredo(id));
  } catch {
    return erro('o segredo desta conta não pôde ser lido — salve a chave de novo em Configurações');
  }

  const cabecalho = cabecalhoDaLeitura(texto(pedido.empresa, 120));
  // O Claude pelo OpenRouter ou por endpoint compatível raciocina igual.
  let maxTokens = conta.provedor === 'anthropic' || /(^|\/)claude/i.test(modelo) ? TOKENS_DA_LEITURA_CLAUDE : TOKENS_DA_LEITURA;
  const ler = (escolhidas: readonly Juntada[]) => {
    const prazo = Math.min(PRAZO_DO_MODELO_MS, PRAZO_TOTAL_MS - (agora() - inicio));
    if (prazo < PRAZO_MINIMO_DO_MODELO_MS) return null;
    return criar(conta.provedor, prazo).ler({
      credenciais, modelo, sistema: SISTEMA_DA_COLETA, maxTokens,
      partes: [cabecalho, ...escolhidas.map((j) => j.parte)],
    });
  };
  // Quem gastou o tempo: o site, se foi lido e demorou; senão, o envio dos arquivos.
  const SEM_TEMPO = lido.site && agora() - antesDoSite > 5_000
    ? 'a leitura do site levou tempo demais e não sobrou tempo para o modelo: tente de novo, ou sem o site'
    : 'o envio dos arquivos levou tempo demais e não sobrou tempo para o modelo: anexe menos arquivos, ou menores';

  const noLimite = noTeto(juntadas, fontes);
  let r = await ler(noLimite);
  if (!r) return erro(SEM_TEMPO);
  // Saldo curto no OpenRouter: o 402 diz quanto cabe, e o que cabe ainda é um rascunho.
  const cabe = !r.ok ? Number(CABE_SO.exec(r.erro)?.[1] ?? 0) : 0;
  if (!r.ok && /HTTP 402/.test(r.erro) && cabe >= TOKENS_DA_LEITURA && cabe < maxTokens) {
    maxTokens = cabe;
    r = await ler(noLimite);
    if (!r) return erro(SEM_TEMPO);
  }
  // O modelo que não lê imagem (no OpenRouter, quem lê é o modelo, não o
  // provedor) recusa o pedido INTEIRO, e o anexo grande demais também. O
  // anexo sai, dizendo por quê, e o resto é lido de novo — em vez de o site já
  // lido se perder junto.
  const deAnexo = noLimite.filter((j) => j.parte.tipo !== 'texto');
  const recusouAnexo = !r.ok && r.definitivo && deAnexo.length > 0 && NAO_LE_ANEXO.test(r.erro);
  const ilegivel = !r.ok && r.definitivo && deAnexo.length > 0 && !recusouAnexo && ILEGIVEL.test(r.erro);
  const passouDoLimite = !r.ok && deAnexo.length > 0 && !recusouAnexo && !ilegivel
    && PASSOU_DO_LIMITE.test(r.erro) && !NAO_E_TAMANHO.test(r.erro);
  if (!r.ok && (recusouAnexo || ilegivel || passouDoLimite)) {
    const motivo = recusouAnexo
      ? `o modelo ${modelo} não aceitou este tipo de anexo (${r.erro}): leia com um modelo que leia imagem e PDF, ou anexe o texto em .txt`
      : ilegivel
        ? `o provedor não conseguiu abrir o arquivo (${r.erro}): salve ou exporte de novo, e anexe outra vez`
        : `o pedido passou de um limite do modelo (${r.erro}): leia menos arquivos de uma vez, ou PDFs menores`;
    for (const j of deAnexo) fontes[j.fonte] = { ...fontes[j.fonte]!, lida: false, detalhe: motivo };
    if (!conteudoEmTexto) return erro(motivo);
    r = await ler(noLimite.filter((j) => j.parte.tipo === 'texto'));
    if (!r) return erro(SEM_TEMPO);
  }
  if (!r.ok) return erro(r.erro);
  // Separar antes de perguntar: "[SEM INFORMAÇÃO]" seguido de "PARA CONFERIR:
  // nenhuma" ainda é "nada a dizer", e não um rascunho com a marca dentro.
  const separado = separarConferir(r.texto);
  // A ausência de carência numa forma que o freio leria como carência zero para tudo vai para conferir.
  const { texto: rascunho, tiradas } = tirarCarenciaSemEscopo(separado.texto);
  const conferir = [separado.conferir, ...(tiradas.length ? [
    'Ausência de carência — fora do texto: escrita assim, o freio deixaria o agente dizer que não há carência '
      + 'para nada. Se vale, escreva "não há carência para … no Plano …":', ...tiradas] : [])].filter(Boolean).join('\n');
  if (semInformacao(rascunho)) {
    return { status: 200, corpo: { ok: true, situacao: 'sem_informacao', modelo, fontes,
      motivo: 'o modelo leu e não achou nada sobre a empresa nos materiais' } };
  }
  if (!rascunho) return erro('o modelo devolveu só divergências, sem texto sobre a empresa');
  if (rascunho.length > TETOS_DO_AGENTE.contexto) {
    return erro(`o rascunho passou de ${TETOS_DO_AGENTE.contexto.toLocaleString('pt-BR')} caracteres; leia menos material de uma vez`);
  }
  return { status: 200, corpo: { ok: true, situacao: 'pronto', texto: rascunho, conferir, modelo, fontes } };
}
