// O agente do Setup rápido (D72; por chat desde o D73): lê o que a pessoa
// escreveu e devolve respostas e valores SUGERIDOS para o passo da conversa.
//
// Quem decide o próximo passo é o condutor da tela (`app/src/setupChat.ts`),
// e quem executa é a tela, com o JWT da pessoa. Daqui sai texto e sugestão.
//
// O que ele não faz, por desenho:
//
//   - não escreve no banco e não autoriza cartão nenhum: o que sai daqui é
//     texto e sugestão, e a tela passa a sugestão pelo `valida` do roteiro
//     (`aplicarSugestao`), o mesmo de quem clica;
//   - não vê nem pede chave: a conversa pede segredo num campo protegido que
//     vai da tela direto para o Vault, sem passar por aqui; e chave colada no
//     texto livre é barrada antes do modelo, pela MESMA regra que a tela usa
//     antes de enviar (`adapters/segredo.ts`);
//   - não escolhe fora do vocabulário: o mapa que a tela manda diz, chave por
//     chave, o que é escolhível agora, e `lerSaida` descarta o resto antes de
//     a sugestão voltar à rede.
//
// A chave que ele usa é a da PLATAFORMA (`segredo_do_agente_setup`), lida pela
// edge function com a chave do serviço. Chega aqui por parâmetro e vira
// cabeçalho; nunca vai para resposta nem para log.
//
// Só `fetch`, injetável: o arquivo roda no Deno da function e no Node do teste.

import type { Buscador } from '../adapters/tipos.ts';
import { AVISO_DE_CHAVE, pareceSegredo } from '../adapters/segredo.ts';

export { pareceSegredo };

export interface ValorDoMapa { valor: string; rotulo: string; detalhe?: string }
export interface EntradaDoMapa { forma: 'multipla' | 'unica' | 'numeros'; pergunta: string; valores: ValorDoMapa[] }

/** Campo que o agente pode preencher no passo atual. Nunca segredo: a tela
 *  não manda, e `lerPedido` não aceitaria um marcado assim. */
export interface CampoDoPasso { chave: string; rotulo: string }

export interface PedidoSetup {
  mensagem: string;
  historico: { papel: 'pessoa' | 'agente'; texto: string }[];
  /** O passo da conversa, como o condutor o descreve (`passoParaOAgente`). */
  passo: { tipo: string; descricao: string; campos: CampoDoPasso[] };
  /** O que já está feito, lido do banco pela tela (a lista "Onde você está"). */
  situacao: string[];
  respostas: Record<string, unknown>;
  mapa: Record<string, EntradaDoMapa>;
}

export interface SaidaSetup {
  mensagem: string;
  respostas: Record<string, string | string[] | Record<string, number>>;
  /** Valores para campos do passo atual. Só os que o pedido listou. */
  campos: Record<string, string>;
}

// Tetos de tamanho: a porta é de quem está logado, e a chave é da plataforma.
// Pedido maior que isto não é conversa de configuração.
const MAX_MENSAGEM = 2000;
const MAX_HISTORICO = 12;
const MAX_MAPA = 40;
const MAX_VALORES = 60;

const curto = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : '');

/** Valida e encolhe o pedido da tela. Texto = por que foi recusado. */
export function lerPedido(x: unknown): PedidoSetup | string {
  if (!x || typeof x !== 'object' || Array.isArray(x)) return 'pedido vazio';
  const o = x as Record<string, unknown>;
  const mensagem = curto(o.mensagem, MAX_MENSAGEM + 1).trim();
  if (!mensagem) return 'escreva o que você quer configurar';
  if (mensagem.length > MAX_MENSAGEM) return `mensagem longa demais (até ${MAX_MENSAGEM} caracteres)`;

  const historico = (Array.isArray(o.historico) ? o.historico : []).slice(-MAX_HISTORICO)
    .filter((h): h is Record<string, unknown> => !!h && typeof h === 'object')
    .map((h) => ({ papel: h.papel === 'agente' ? 'agente' as const : 'pessoa' as const, texto: curto(h.texto, MAX_MENSAGEM) }))
    .filter((h) => h.texto && !pareceSegredo(h.texto));

  const mapa: Record<string, EntradaDoMapa> = {};
  const brutoMapa = o.mapa && typeof o.mapa === 'object' && !Array.isArray(o.mapa) ? o.mapa as Record<string, unknown> : {};
  for (const [k, v] of Object.entries(brutoMapa).slice(0, MAX_MAPA)) {
    if (!/^[A-Za-z:_]{2,40}$/.test(k) || !v || typeof v !== 'object') continue;
    const e = v as Record<string, unknown>;
    const forma = e.forma === 'multipla' || e.forma === 'unica' || e.forma === 'numeros' ? e.forma : null;
    if (!forma) continue;
    const valores = (Array.isArray(e.valores) ? e.valores : []).slice(0, MAX_VALORES)
      .filter((y): y is Record<string, unknown> => !!y && typeof y === 'object' && typeof (y as Record<string, unknown>).valor === 'string')
      .map((y) => ({
        valor: curto(y.valor, 80), rotulo: curto(y.rotulo, 120),
        ...(typeof y.detalhe === 'string' ? { detalhe: curto(y.detalhe, 240) } : {}),
      }));
    mapa[k] = { forma, pergunta: curto(e.pergunta, 240), valores };
  }

  const situacao = (Array.isArray(o.situacao) ? o.situacao : []).slice(0, 12)
    .map((s) => curto(s, 300)).filter(Boolean);
  const brutoResp = o.respostas && typeof o.respostas === 'object' && !Array.isArray(o.respostas)
    ? o.respostas as Record<string, unknown> : {};
  const respostas = JSON.stringify(brutoResp).length <= 4000 ? brutoResp : {};
  const bp = o.passo && typeof o.passo === 'object' && !Array.isArray(o.passo) ? o.passo as Record<string, unknown> : {};
  const passo = {
    tipo: curto(bp.tipo, 40) || 'nenhum',
    descricao: curto(bp.descricao, 1500),
    campos: (Array.isArray(bp.campos) ? bp.campos : []).slice(0, 12)
      .filter((c): c is Record<string, unknown> => !!c && typeof c === 'object'
        && typeof (c as Record<string, unknown>).chave === 'string'
        // Campo que se declara segredo não é preenchível pelo agente, venha de
        // onde vier o pedido.
        && (c as Record<string, unknown>).segredo !== true)
      .map((c) => ({ chave: curto(c.chave, 40), rotulo: curto(c.rotulo, 160) }))
      .filter((c) => /^[A-Za-z_]{2,40}$/.test(c.chave)),
  };
  return { mensagem, historico, mapa, situacao, respostas, passo };
}

/** Dos modelos que a chave alcança, o primeiro desta ordem. Barato e rápido
 *  primeiro: a tarefa é extrair escolhas de uma frase, não raciocinar longe. */
const PREFERIDOS = [
  /^gpt-5(\.\d+)?-mini$/, /^gpt-4\.1-mini$/, /^gpt-4o-mini$/, /^gpt-5(\.\d+)?$/, /^gpt-4\.1$/, /^gpt-4o$/,
];

export function escolherModelo(ids: readonly string[]): string | null {
  for (const re of PREFERIDOS) {
    const achados = ids.filter((id) => re.test(id)).sort().reverse();
    if (achados.length) return achados[0]!;
  }
  return ids.find((id) => /^gpt-/.test(id) && !/realtime|audio|search|image|transcribe|tts/.test(id)) ?? null;
}

export function instrucoes(p: PedidoSetup): string {
  const mapa = Object.entries(p.mapa).map(([k, e]) =>
    `- ${k} (${e.forma === 'multipla' ? 'lista de valores' : e.forma === 'unica' ? 'um valor' : 'número inteiro por canal'}): ${e.pergunta}\n`
    + e.valores.map((v) => `    • ${v.valor} = ${v.rotulo}${v.detalhe ? ` — ${v.detalhe}` : ''}`).join('\n'),
  ).join('\n');
  return [
    'Você é o agente de configuração do Prospecta, um motor de prospecção multicanal (WhatsApp, e-mail, SMS).',
    'Seu trabalho: configurar canais, IA, CRM e a primeira campanha conversando — entender o que a pessoa quer e preencher por ela o que der, para ela não precisar clicar pergunta por pergunta.',
    '',
    'Regras:',
    '1. Você conduz uma conversa de configuração. O sistema decide qual é o próximo passo e o mostra à pessoa logo depois da sua mensagem; você entende o que ela escreveu e preenche o que der.',
    '2. Em "respostas", só use as chaves e os valores do VOCABULÁRIO abaixo, escritos exatamente como estão. Se a pessoa não disse algo, não invente: deixe de fora. Uma frase pode responder várias perguntas.',
    '3. Em "numeros", cada item é {canal, quantidade} com o total por dia daquele canal.',
    '4. Em "campos", só as chaves listadas em CAMPOS QUE VOCÊ PODE PREENCHER, com o valor que a pessoa deu (número, e-mail, nome). Nada inventado.',
    '5. Chave de API, token e senha NUNCA passam por você. Quando o passo pede um segredo, o sistema mostra um campo protegido que vai direto para o cofre; diga para colar ali. Nunca peça para digitar segredo na conversa e nunca repita um.',
    '6. Você não executa nada e não diz que algo foi feito: o sistema conecta cada conta e avisa o resultado ele mesmo.',
    '7. Lista fria ("fria") e base própria ("morna") usam contas separadas; WhatsApp não oficial é o que roda lista fria, o oficial é para base própria com consentimento.',
    '8. Se a pessoa perguntar algo, responda em poucas frases e volte ao passo. "mensagem": português do Brasil, curto (até 3 frases), sem markdown, sem repetir a pergunta do passo — o sistema já a mostra.',
    '',
    `PASSO ATUAL: ${p.passo.tipo} — ${p.passo.descricao || 'sem descrição'}`,
    `CAMPOS QUE VOCÊ PODE PREENCHER: ${p.passo.campos.length ? p.passo.campos.map((c) => `${c.chave} (${c.rotulo})`).join('; ') : 'nenhum'}`,
    `O que já está feito (lido do banco): ${p.situacao.length ? p.situacao.join(' | ') : 'nada informado'}`,
    `Respostas já dadas (não as troque): ${JSON.stringify(p.respostas)}`,
    '',
    'VOCABULÁRIO:',
    mapa,
  ].join('\n');
}

const ESQUEMA = {
  name: 'setup',
  strict: true,
  schema: {
    type: 'object',
    additionalProperties: false,
    required: ['mensagem', 'respostas', 'campos'],
    properties: {
      mensagem: { type: 'string' },
      campos: {
        type: 'array',
        items: {
          type: 'object', additionalProperties: false, required: ['chave', 'valor'],
          properties: { chave: { type: 'string' }, valor: { type: 'string' } },
        },
      },
      respostas: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['chave', 'valores', 'numeros'],
          properties: {
            chave: { type: 'string' },
            valores: { type: 'array', items: { type: 'string' } },
            numeros: {
              type: 'array',
              items: {
                type: 'object', additionalProperties: false, required: ['canal', 'quantidade'],
                properties: { canal: { type: 'string' }, quantidade: { type: 'integer' } },
              },
            },
          },
        },
      },
    },
  },
} as const;

export function corpoDoPedido(modelo: string, p: PedidoSetup): Record<string, unknown> {
  const raciocina = /^(gpt-5|o\d)/.test(modelo);
  return {
    model: modelo,
    // max_completion_tokens: o nome que os modelos de raciocínio aceitam, e
    // que os outros também entendem. Folga para o raciocínio caber.
    max_completion_tokens: raciocina ? 4000 : 1200,
    ...(raciocina ? { reasoning_effort: 'low' } : { temperature: 0.2 }),
    response_format: { type: 'json_schema', json_schema: ESQUEMA },
    messages: [
      { role: 'system', content: instrucoes(p) },
      ...p.historico.map((h) => ({ role: h.papel === 'agente' ? 'assistant' : 'user', content: h.texto })),
      { role: 'user', content: p.mensagem },
    ],
  };
}

/**
 * O que o modelo devolveu, já reduzido ao vocabulário. Chave fora do mapa,
 * valor fora da lista, número que não é inteiro positivo: some aqui, antes de
 * voltar para a tela — que confere de novo, pelo roteiro.
 */
export function lerSaida(
  conteudo: string, mapa: Record<string, EntradaDoMapa>, camposDoPasso: readonly CampoDoPasso[] = [],
): SaidaSetup {
  let o: Record<string, unknown> = {};
  try { o = JSON.parse(conteudo) as Record<string, unknown>; } catch { /* resposta fora do formato */ }
  const mensagem = typeof o.mensagem === 'string' && o.mensagem.trim()
    ? o.mensagem.trim().slice(0, 1200)
    : 'Não entendi bem. Pode dizer por quais canais quer enviar e para quem (sua base ou uma lista nova)?';
  // Campo fora do passo some, e valor que parece chave também: o agente não
  // tem por onde devolver segredo à tela, nem que o modelo tente.
  const podem = new Set(camposDoPasso.map((c) => c.chave));
  const campos: Record<string, string> = {};
  for (const c of Array.isArray(o.campos) ? o.campos : []) {
    const { chave, valor } = (c ?? {}) as Record<string, unknown>;
    if (typeof chave === 'string' && podem.has(chave) && typeof valor === 'string' && valor.trim()
      && valor.length <= 300 && !pareceSegredo(valor)) campos[chave] = valor.trim();
  }

  const respostas: SaidaSetup['respostas'] = {};
  for (const item of Array.isArray(o.respostas) ? o.respostas : []) {
    if (!item || typeof item !== 'object') continue;
    const { chave, valores, numeros } = item as Record<string, unknown>;
    const e = typeof chave === 'string' ? mapa[chave] : undefined;
    if (!e || typeof chave !== 'string') continue;
    const permitidos = new Set(e.valores.map((v) => v.valor));
    if (e.forma === 'numeros') {
      const n: Record<string, number> = {};
      for (const x of Array.isArray(numeros) ? numeros : []) {
        const { canal, quantidade } = (x ?? {}) as Record<string, unknown>;
        if (typeof canal === 'string' && permitidos.has(canal)
          && Number.isInteger(quantidade) && (quantidade as number) > 0 && (quantidade as number) <= 100000) {
          n[canal] = quantidade as number;
        }
      }
      if (Object.keys(n).length) respostas[chave] = n;
      continue;
    }
    const vs = (Array.isArray(valores) ? valores : []).filter((v): v is string => typeof v === 'string' && permitidos.has(v));
    if (!vs.length) continue;
    respostas[chave] = e.forma === 'multipla' ? [...new Set(vs)] : vs[0]!;
  }
  return { mensagem, respostas, campos };
}

export type Conversa =
  | { ok: true; saida: SaidaSetup; modelo: string }
  | { ok: false; erro: string; status: number };

/** Lista de modelos por instância da function: o catálogo não muda a cada mensagem. */
let modeloGuardado: { modelo: string; em: number } | null = null;

export async function conversar(
  pedido: PedidoSetup, chave: string, buscar: Buscador = fetch, agora = Date.now(),
): Promise<Conversa> {
  if (pareceSegredo(pedido.mensagem)) {
    return {
      ok: true, modelo: '',
      saida: {
        mensagem: AVISO_DE_CHAVE, respostas: {}, campos: {},
      },
    };
  }
  const cab = { Authorization: `Bearer ${chave}`, 'Content-Type': 'application/json' };
  try {
    let modelo = modeloGuardado && agora - modeloGuardado.em < 3_600_000 ? modeloGuardado.modelo : null;
    if (!modelo) {
      const r = await buscar('https://api.openai.com/v1/models', { headers: cab });
      if (!r.ok) return { ok: false, status: 502, erro: r.status === 401 ? 'a chave da plataforma foi recusada pela OpenAI — ela precisa ser trocada no backend' : `OpenAI respondeu ${r.status} ao listar modelos` };
      const c = await r.json().catch(() => ({})) as { data?: { id?: unknown }[] };
      modelo = escolherModelo((c.data ?? []).map((m) => String(m.id ?? '')));
      if (!modelo) return { ok: false, status: 502, erro: 'a chave da plataforma não alcança nenhum modelo de conversa' };
      modeloGuardado = { modelo, em: agora };
    }

    const r = await buscar('https://api.openai.com/v1/chat/completions', {
      method: 'POST', headers: cab, body: JSON.stringify(corpoDoPedido(modelo, pedido)),
    });
    const c = await r.json().catch(() => ({})) as {
      choices?: { message?: { content?: unknown; refusal?: unknown } }[]; error?: { message?: unknown };
    };
    if (!r.ok) {
      // Modelo que sumiu do catálogo: esquecer e escolher de novo na próxima.
      if (r.status === 404 || r.status === 400) modeloGuardado = null;
      const m = typeof c.error?.message === 'string' ? c.error.message : '';
      return { ok: false, status: r.status === 429 ? 429 : 502, erro: `OpenAI respondeu ${r.status}${m ? `: ${m}` : ''}` };
    }
    const msg = c.choices?.[0]?.message;
    if (typeof msg?.refusal === 'string' && msg.refusal) {
      return { ok: true, modelo, saida: { mensagem: 'Não consigo ajudar com isso aqui. Posso ajudar a configurar canais, IA, CRM e a primeira campanha.', respostas: {}, campos: {} } };
    }
    return { ok: true, modelo, saida: lerSaida(typeof msg?.content === 'string' ? msg.content : '', pedido.mapa, pedido.passo.campos) };
  } catch (e) {
    return { ok: false, status: 502, erro: `sem resposta da OpenAI: ${e instanceof Error ? e.message : String(e)}` };
  }
}

/** Para o teste: começar cada caso sem o modelo guardado do anterior. */
export function esquecerModelo(): void { modeloGuardado = null; }
