/**
 * O Setup rápido por chat (D73): quem conduz a conversa, passo a passo.
 *
 * O D72 pôs um agente para PREENCHER as perguntas do assistente, e a
 * configuração continuava em outras telas, autorizada cartão por cartão. O
 * usuário decidiu que o setup é a própria conversa: o agente pede o que falta,
 * e cada peça é configurada assim que a informação chega.
 *
 * Três papéis, e nenhum se confunde com o outro:
 *
 * - **O condutor (este arquivo) decide o que vem a seguir.** É puro e
 *   determinístico: lê a `Foto` (o banco) e o estado da conversa, e devolve
 *   UM passo — uma pergunta do roteiro, um campo a pedir, uma conta a
 *   conectar, uma ação do plano a executar, ou o fim. O modelo de linguagem
 *   não escolhe o próximo passo, e por isso a conversa não esquece campo
 *   obrigatório nem pula a pergunta do pool.
 *
 * - **O agente interpreta e conversa.** O texto livre da pessoa vai para ele
 *   com o passo atual; ele devolve respostas e valores SUGERIDOS, que entram
 *   pelo mesmo `valida` de um clique e pelo mesmo `aceitarValor` de quem
 *   digita no campo.
 *
 * - **A tela executa.** Com o JWT de quem está conversando: o RLS e as funções
 *   de banco (`salvar_credencial_ia`, `salvar_credencial_remetente`,
 *   `salvar_credencial_crm`) decidem se pode e o que é segredo, como em
 *   qualquer outra tela (D28).
 *
 * **O segredo não entra aqui.** `EstadoSetup.valores` guarda só o que não é
 * segredo — `aceitarValor` recusa campo marcado como segredo —, e o condutor
 * só sabe QUAIS segredos já foram digitados (`prontos`), nunca os valores. Os
 * valores moram num ref da tela, vão dele direto para a função de banco e
 * morrem com a página. Nada de segredo vai para o modelo, para a memória do
 * navegador nem para o histórico da conversa.
 */
import {
  CANAIS_DE_ENVIO, NAO, USAR, canaisEscolhidos, cumprida, impedimento, montarPlano, poolEscolhido,
  roteiro, sugestaoDiaria, tetoPorConta,
} from './assistente.ts';
import type { Acao, CanalEnvio, Familia, Foto, Pergunta, Pool, Respostas } from './assistente.ts';
import { normalizarTelefone, telefoneValido } from '../../adapters/telefone.ts';
import { emailValido, normalizarEmail } from '../../adapters/email.ts';

const NOME: Record<string, string> = { whatsapp: 'WhatsApp', email: 'e-mail', sms: 'SMS' };

export interface CampoSetup {
  readonly chave: string;
  readonly rotulo: string;
  readonly ajuda?: string;
  readonly segredo: boolean;
  /** `modelo`: a lista vem do provedor, com a chave que acabou de ser digitada. */
  readonly tipo: 'texto' | 'segredo' | 'modelo' | 'telefone' | 'email';
  readonly exemplo?: string;
}

export interface Coleta {
  /** `canal:whatsapp`, `ia`, `crm`. Uma por peça. */
  readonly id: string;
  readonly alvo: 'canal' | 'instancia' | 'ia' | 'crm';
  readonly canal?: CanalEnvio;
  readonly provedor: string;
  readonly nomeProvedor: string;
  readonly pool?: Pool;
  /** Para `instancia`: o servidor onde a instância nasce. */
  readonly servidor?: string;
  /** Quota com que a conta nasce: o pedido, até o ponto de partida do canal. */
  readonly quota?: number;
  readonly campos: readonly CampoSetup[];
}

export interface EstadoSetup {
  readonly respostas: Respostas;
  /** Por coleta, só o que NÃO é segredo. */
  readonly valores: Readonly<Record<string, Readonly<Record<string, string>>>>;
  /** Coleta ou ação → o que foi feito, dito na hora. */
  readonly feitos: Readonly<Record<string, string>>;
  readonly pulados: readonly string[];
  /** Ação → id que ela produziu (a campanha), para quem depende dela. */
  readonly produzidos: Readonly<Record<string, string>>;
  /**
   * Coleta → o erro da última tentativa de conectar. Enquanto houver, o passo
   * é `falhou` e a conversa ESPERA a pessoa decidir: tentar de novo, corrigir
   * ou pular. Sem isto, a coleta completa voltava a `conectar` sozinha depois
   * do erro — e cada volta criava uma instância no provedor antes de o banco
   * recusar: doze em dois minutos, na primeira conversa de verdade (D73).
   */
  readonly falhas?: Readonly<Record<string, string>>;
}

export const ESTADO_VAZIO: EstadoSetup = { respostas: {}, valores: {}, feitos: {}, pulados: [], produzidos: {}, falhas: {} };

/** Quais segredos de cada coleta já foram digitados. Só as chaves. */
export type Prontos = Readonly<Record<string, readonly string[]>>;

export type PassoSetup =
  | { readonly tipo: 'pergunta'; readonly pergunta: Pergunta }
  | { readonly tipo: 'campo'; readonly coleta: Coleta; readonly campo: CampoSetup }
  | { readonly tipo: 'conectar'; readonly coleta: Coleta; readonly valores: Readonly<Record<string, string>> }
  /** A última tentativa falhou: nada roda até a pessoa escolher o que fazer. */
  | { readonly tipo: 'falhou'; readonly coleta: Coleta; readonly erro: string }
  /** O número (ou endereço) já é de uma conta deste cliente: um chip é um número só. */
  | { readonly tipo: 'conflito'; readonly coleta: Coleta; readonly conta: { apelido: string; pool: Pool } }
  /** Coleta que a pessoa não pode fazer: o papel dela não administra o cliente. */
  | { readonly tipo: 'sem_permissao'; readonly coleta: Coleta }
  | { readonly tipo: 'acao'; readonly acao: Acao }
  | { readonly tipo: 'acao_impedida'; readonly acao: Acao; readonly motivo: string }
  | { readonly tipo: 'fim'; readonly links: readonly { rota: string; rotulo: string }[] };

// ---------------------------------------------------------------------------
// Que peça cada resposta pede
// ---------------------------------------------------------------------------

const ativa = (estado: string) => estado !== 'desativado';

function contas(f: Foto, canal: string, pool: Pool, provedor?: string) {
  return f.remetentes.filter((r) => r.canal === canal && r.tipo_permitido === pool && ativa(r.estado)
    && (provedor === undefined || r.provedor === provedor));
}

/** Campos do catálogo que a conversa pede: os obrigatórios, segredo por último.
 *  Opcional fica para a tela da conta — a conversa existe para chegar rápido
 *  ao que funciona, não para percorrer formulário. */
function doCatalogo(campos: Foto['provedores'][number]['campos'], fora: readonly string[] = []): CampoSetup[] {
  const pede = campos.filter((c) => c.obrigatorio && !fora.includes(c.chave));
  return [
    ...pede.filter((c) => !c.segredo),
    ...pede.filter((c) => c.segredo),
  ].map((c) => ({
    chave: c.chave, rotulo: c.rotulo, segredo: c.segredo, tipo: c.segredo ? 'segredo' : 'texto',
    ...(c.ajuda ? { ajuda: c.ajuda } : {}),
  }));
}

function campoIdentificador(canal: CanalEnvio): CampoSetup {
  if (canal === 'whatsapp') {
    return { chave: 'identificador', rotulo: 'Qual é o número do WhatsApp desta conta?', tipo: 'telefone', segredo: false,
             exemplo: '5511988887777', ajuda: 'Com DDD. O código do país (55) pode vir ou não.' };
  }
  if (canal === 'email') {
    return { chave: 'identificador', rotulo: 'De qual endereço os e-mails vão sair?', tipo: 'email', segredo: false,
             exemplo: 'contato@suaempresa.com.br', ajuda: 'O domínio precisa estar verificado no provedor.' };
  }
  return { chave: 'identificador', rotulo: 'Como você quer chamar esta conta de SMS?', tipo: 'texto', segredo: false,
           exemplo: 'SMS comercial' };
}

/** A coleta que a resposta `chave` abre, se abre alguma. */
export function coletaDa(f: Foto, r: Respostas, chave: string): Coleta | null {
  const valor = r[chave];
  if (typeof valor !== 'string' || valor === NAO || valor === USAR) return null;

  if (chave.startsWith('provedor:')) {
    const canal = chave.slice(9) as CanalEnvio;
    const pool = poolEscolhido(r);
    const prov = f.provedores.find((p) => p.slug === valor && p.canal === canal);
    if (!pool || !prov || contas(f, canal, pool, prov.slug).length) return null;
    const familia: Familia = prov.oficial ? 'oficial' : 'nao';
    const alvo = Number((r.porDia as Readonly<Record<string, number>> | undefined)?.[canal]) || sugestaoDiaria(canal, pool);
    const quota = Math.max(1, Math.min(tetoPorConta(canal, familia, pool), alvo));
    // Provedor que hospeda instância e já tem servidor: a conversa CRIA o chip,
    // e o QR aparece nela. Sem servidor, conecta uma instância que já existe.
    const servidor = (f.servidores ?? []).find((s) => s.provedor === prov.slug);
    if (servidor) {
      return {
        id: `canal:${canal}`, alvo: 'instancia', canal, provedor: prov.slug, nomeProvedor: prov.nome, pool,
        servidor: servidor.id, quota, campos: [campoIdentificador(canal)],
      };
    }
    return {
      id: `canal:${canal}`, alvo: 'canal', canal, provedor: prov.slug, nomeProvedor: prov.nome, pool, quota,
      campos: [campoIdentificador(canal), ...doCatalogo(prov.campos)],
    };
  }

  if (chave === 'ia') {
    const prov = f.provedoresIA.find((p) => p.slug === valor);
    if (!prov || !prov.tem_adapter) return null;
    if (f.credenciaisIA.some((c) => c.ativo && c.provedor === prov.slug)) return null;
    return {
      id: 'ia', alvo: 'ia', provedor: prov.slug, nomeProvedor: prov.nome,
      campos: [
        ...doCatalogo(prov.campos),
        { chave: 'modelo', rotulo: 'Qual modelo o agente usa para responder?', tipo: 'modelo', segredo: false,
          ajuda: 'A lista vem agora do provedor, com a sua chave: só aparece o que ela alcança.' },
      ],
    };
  }

  if (chave === 'crm') {
    const prov = f.provedoresCRM.find((p) => p.slug === valor);
    if (!prov || f.conexoesCRM.some((c) => c.ativo && c.provedor === prov.slug)) return null;
    return { id: 'crm', alvo: 'crm', provedor: prov.slug, nomeProvedor: prov.nome, campos: doCatalogo(prov.campos) };
  }
  return null;
}

// ---------------------------------------------------------------------------
// O próximo passo
// ---------------------------------------------------------------------------

/** Ações do plano que a conversa executa sozinha. `configurar` virou coleta;
 *  `abrir` é link no fim. */
const EXECUTAVEIS = new Set<Acao['tipo']>(['ajustar_quota', 'criar_campanha', 'ligar_agentes']);

export function proximoPasso(f: Foto, e: EstadoSetup, prontos: Prontos = {}): PassoSetup {
  const { passos, atual, respostas: r } = roteiro(f, e.respostas);

  // Cada peça é configurada logo depois da resposta que a pediu, antes da
  // pergunta seguinte: "configurar à medida que a informação chega".
  for (const p of passos) {
    const col = coletaDa(f, r, p.pergunta.chave);
    if (!col || e.feitos[col.id] || e.pulados.includes(col.id)) continue;
    if (!f.administra) return { tipo: 'sem_permissao', coleta: col };
    const valores = e.valores[col.id] ?? {};
    const erro = e.falhas?.[col.id];
    if (erro) return { tipo: 'falhou', coleta: col, erro };
    const dono = col.canal && valores.identificador ? contaComIdentificador(f, col.canal, valores.identificador) : null;
    if (dono) return { tipo: 'conflito', coleta: col, conta: dono };
    const falta = col.campos.find((c) => (c.segredo ? !(prontos[col.id] ?? []).includes(c.chave) : !valores[c.chave]));
    if (falta) return { tipo: 'campo', coleta: col, campo: falta };
    return { tipo: 'conectar', coleta: col, valores };
  }

  if (atual) return { tipo: 'pergunta', pergunta: atual };

  const plano = montarPlano(f, r).acoes;
  for (const a of plano) {
    if (!EXECUTAVEIS.has(a.tipo) || e.feitos[a.id] || e.pulados.includes(a.id)) continue;
    const motivo = impedimento(f, a)
      ?? (a.dependeDe.some((d) => !cumprida(plano, e.feitos, d)) ? 'falta um passo anterior que não foi feito' : null)
      ?? (a.tipo === 'ligar_agentes' && !a.credencial ? 'falta a conta de IA' : null);
    if (motivo) return { tipo: 'acao_impedida', acao: a, motivo };
    return { tipo: 'acao', acao: a };
  }

  const links = plano.filter((a) => a.tipo === 'abrir').map((a) => ({ rota: (a as { rota: string }).rota, rotulo: a.titulo }));
  const campanha = e.produzidos.campanha;
  return { tipo: 'fim', links: campanha ? [{ rota: `/campanhas/${campanha}`, rotulo: 'Abrir a campanha' }, ...links] : links };
}

// ---------------------------------------------------------------------------
// Valores que entram
// ---------------------------------------------------------------------------

/**
 * Um valor digitado, ou sugerido pelo agente, para um campo da coleta. Normaliza
 * pela MESMA regra do motor (D32) e recusa o que não serve, com o motivo.
 * Segredo não passa por aqui: ele não entra no estado.
 */
export function aceitarValor(
  e: EstadoSetup, coleta: Coleta, chave: string, bruto: string,
): { ok: true; estado: EstadoSetup } | { ok: false; erro: string } {
  const campo = coleta.campos.find((c) => c.chave === chave);
  if (!campo) return { ok: false, erro: 'campo desconhecido' };
  if (campo.segredo) return { ok: false, erro: 'segredo não é guardado na conversa' };
  let v = bruto.trim();
  if (!v) return { ok: false, erro: 'está vazio' };
  if (campo.tipo === 'telefone') {
    if (!telefoneValido(v)) return { ok: false, erro: 'não parece um número de telefone com DDD' };
    v = normalizarTelefone(v);
  }
  if (campo.tipo === 'email') {
    if (!emailValido(v)) return { ok: false, erro: 'não parece um endereço de e-mail' };
    v = normalizarEmail(v);
  }
  if (v.length > 300) return { ok: false, erro: 'longo demais' };
  return {
    ok: true,
    estado: { ...e, valores: { ...e.valores, [coleta.id]: { ...(e.valores[coleta.id] ?? {}), [chave]: v } } },
  };
}

/** Depois de conectar: a peça está feita, e a resposta que a pediu passa a
 *  ser "usar o que já tenho" — o roteiro, relendo a foto, já não ofereceria
 *  o provedor como opção, e a resposta antiga voltaria a ser perguntada. */
export function aposConectar(e: EstadoSetup, coleta: Coleta, texto: string, produzido?: string): EstadoSetup {
  const respostas: Record<string, unknown> = { ...e.respostas };
  if (coleta.alvo === 'canal' || coleta.alvo === 'instancia') respostas[`provedor:${coleta.canal}`] = USAR;
  if (coleta.alvo === 'ia' && produzido) respostas['ia:conta'] = produzido;
  return { ...e, respostas: respostas as Respostas, feitos: { ...e.feitos, [coleta.id]: texto } };
}

/**
 * A conta deste cliente que já usa este número ou endereço, em QUALQUER pool.
 * Um número de WhatsApp é um chip só: criar outra instância com ele não dá um
 * segundo chip, dá uma instância órfã no provedor e uma recusa no banco (o
 * segredo da conta é nomeado pelo número). A conversa pergunta antes de
 * chamar o provedor.
 */
export function contaComIdentificador(f: Foto, canal: string, identificador: string): { apelido: string; pool: Pool } | null {
  const alvo = identificador.trim().toLowerCase();
  const r = f.remetentes.find((x) => x.canal === canal && x.identificador.trim().toLowerCase() === alvo);
  return r ? { apelido: r.apelido || r.identificador, pool: r.tipo_permitido } : null;
}

/** Depois de um erro: guarda o motivo, e a conversa espera. */
export function aposFalhar(e: EstadoSetup, coleta: Coleta, erro: string): EstadoSetup {
  return { ...e, falhas: { ...(e.falhas ?? {}), [coleta.id]: erro } };
}

/**
 * O que a pessoa decidiu depois do erro. `tentar` só tira a falha (o segredo,
 * se havia, a tela já esqueceu, e o condutor o pede de novo); `corrigir` tira
 * também o que foi digitado, para a coleta recomeçar; `pular` deixa a peça.
 */
export function decidirFalha(e: EstadoSetup, coleta: Coleta, decisao: 'tentar' | 'corrigir' | 'pular'): EstadoSetup {
  const falhas = { ...(e.falhas ?? {}) };
  delete falhas[coleta.id];
  if (decisao === 'pular') return { ...e, falhas, pulados: [...e.pulados, coleta.id] };
  if (decisao === 'corrigir') {
    const valores = { ...e.valores };
    delete valores[coleta.id];
    return { ...e, falhas, valores };
  }
  return { ...e, falhas };
}

/** Número ou endereço que já é de outra conta: some, e o campo volta a ser pedido. */
export function esquecerIdentificador(e: EstadoSetup, coleta: Coleta): EstadoSetup {
  const v = { ...(e.valores[coleta.id] ?? {}) };
  delete v.identificador;
  return { ...e, valores: { ...e.valores, [coleta.id]: v } };
}

/** O nome com que a conta nasce. Não é perguntado: a tela da conta renomeia. */
export function nomeDaConta(coleta: Coleta, valores: Readonly<Record<string, string>>): string {
  if (coleta.alvo === 'ia' || coleta.alvo === 'crm') return `${coleta.nomeProvedor} principal`;
  const pool = coleta.pool === 'fria' ? 'lista fria' : 'base própria';
  return `${coleta.nomeProvedor} — ${pool}${valores.identificador ? ` (${valores.identificador})` : ''}`;
}

/** O que a conversa manda ao agente sobre o passo atual. Segredo vai só como
 *  rótulo: o agente sabe QUE a conversa pede uma chave, nunca qual é. */
export function passoParaOAgente(p: PassoSetup): Record<string, unknown> {
  if (p.tipo === 'pergunta') {
    return { tipo: 'pergunta', chave: p.pergunta.chave, texto: p.pergunta.texto,
             opcoes: p.pergunta.opcoes.filter((o) => !o.indisponivel).map((o) => ({ valor: o.valor, rotulo: o.rotulo })) };
  }
  if (p.tipo === 'campo') {
    return {
      tipo: 'campo', peca: `${p.coleta.nomeProvedor}${p.coleta.canal ? ` (${NOME[p.coleta.canal]})` : ''}`,
      rotulo: p.campo.rotulo, segredo: p.campo.segredo,
      campos_que_voce_pode_preencher: p.coleta.campos.filter((c) => !c.segredo && c.tipo !== 'modelo')
        .map((c) => ({ chave: c.chave, rotulo: c.rotulo })),
    };
  }
  return { tipo: p.tipo };
}

export { CANAIS_DE_ENVIO, canaisEscolhidos };
