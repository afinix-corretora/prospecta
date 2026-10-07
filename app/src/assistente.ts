/**
 * O assistente de configuração (D67): pergunta, monta o plano, e não faz nada
 * sozinho.
 *
 * Três decisões moram aqui, e as três são de propósito:
 *
 * - **Roteiro, não modelo de linguagem.** No primeiro acesso o cliente ainda
 *   não tem credencial de IA — e a chave é dele (D59), não do produto. Um
 *   assistente que precisa de IA para existir não configura o produto que
 *   ainda não tem IA. As perguntas são fixas, as respostas viram ações
 *   concretas, e tudo isto é testável sem rede.
 *
 * - **O estado é o banco.** O que já está feito vem da `Foto` — contas,
 *   credenciais, conexões, campanhas, contatos — e não de uma tabela de
 *   "progresso do assistente". Uma coluna "configurado" seria um fato sem quem
 *   o produza, e mentiria no dia em que alguém configurasse pela tela (D31).
 *
 * - **Plano, não execução.** `montarPlano` devolve o que SERIA feito, com o
 *   efeito de cada passo dito em português. Quem executa é a tela, uma ação
 *   por clique de quem autorizou, com o JWT dessa pessoa — o RLS responde, não
 *   este arquivo.
 *
 * - **Chave só em Configurações (D68).** O assistente não tem campo de chave
 *   nenhum. Ele pergunta qual provedor, e então ESCOLHE entre as contas já
 *   conectadas; quando não há conta, o plano aponta a tela onde conectar, e a
 *   conversa segue sozinha quando a conta aparecer na `Foto`. Quem digita
 *   chave é quem administra, na tela de Configurações ou do canal — num lugar
 *   só, e não em cada fluxo que precise dela.
 *
 * - **O agente propõe, o roteiro decide (D72).** Desde o Setup rápido há um
 *   agente de IA na conversa — com a chave da PLATAFORMA, porque ele existe
 *   antes de o cliente ter qualquer conta. Ele lê o que a pessoa escreveu e
 *   devolve respostas sugeridas; `aplicarSugestao` as passa pelo mesmo
 *   `valida` de quem clica, na mesma ordem, e o que não passa não entra. O
 *   agente não escreve no banco e não autoriza cartão nenhum.
 *
 * Puro de propósito: nada de supabase aqui, para `tests/assistente.test.ts`
 * rodar no Node.
 */

export type CanalEnvio = 'whatsapp' | 'email' | 'sms';
export type Pool = 'morna' | 'fria';
export type Familia = 'oficial' | 'nao';

export const CANAIS_DE_ENVIO: readonly CanalEnvio[] = ['whatsapp', 'email', 'sms'];

const NOME: Record<string, string> = {
  whatsapp: 'WhatsApp', email: 'E-mail', sms: 'SMS', instagram: 'Instagram',
};

/** Resposta "agora não" / "configurar depois". */
export const NAO = 'nao';
/** Resposta "usar o que já tenho". Para credencial e conexão vem `usar:<id>`. */
export const USAR = 'usar';

// ---------------------------------------------------------------------------
// O que existe hoje
// ---------------------------------------------------------------------------

export interface CampoDeCatalogo {
  readonly chave: string;
  readonly rotulo: string;
  readonly tipo: 'texto' | 'senha';
  readonly obrigatorio: boolean;
  readonly segredo: boolean;
  readonly ajuda: string | null;
}

export interface Foto {
  readonly administra: boolean;
  readonly opera: boolean;
  readonly provedores: readonly {
    slug: string; canal: string; nome: string; descricao: string; oficial: boolean;
    tem_adapter: boolean; ativo: boolean; campos: CampoDeCatalogo[];
  }[];
  readonly remetentes: readonly {
    id: string; canal: string; provedor: string; tipo_permitido: Pool;
    quota_diaria: number; estado: string; apelido: string | null; identificador: string;
  }[];
  readonly provedoresIA: readonly {
    slug: string; nome: string; tem_adapter: boolean; modelos_sugeridos: string[]; campos: CampoDeCatalogo[];
  }[];
  readonly credenciaisIA: readonly { id: string; nome: string; provedor: string; modelo: string; ativo: boolean }[];
  readonly provedoresCRM: readonly { slug: string; nome: string; tem_adapter: boolean; campos: CampoDeCatalogo[] }[];
  readonly conexoesCRM: readonly { id: string; nome: string; provedor: string; ativo: boolean }[];
  readonly modelos: readonly { slug: string; nome: string; descricao: string; tipo: Pool; canais: string[] }[];
  readonly agentes: readonly { id: string; nome: string; canal: string; tenant_id: string | null }[];
  readonly campanhas: readonly { id: string; nome: string; ativa: boolean }[];
  readonly contatos: number;
}

const entregavel = (p: Foto['provedores'][number]) => p.tem_adapter && p.ativo;

/** Conta que conta: o mesmo canal e o mesmo pool, porque o roteador escolhe
 *  remetente por `tipo_permitido = tipo da campanha` e nada mais
 *  (`privado.remetentes_disponiveis`). Chip morno não atende campanha fria. */
function contasDe(f: Foto, canal: string, pool: Pool) {
  return f.remetentes.filter((r) => r.canal === canal && r.tipo_permitido === pool && r.estado !== 'desativado');
}

// ---------------------------------------------------------------------------
// Quanto cada conta aguenta
// ---------------------------------------------------------------------------

/**
 * Ponto de partida por conta e por dia. NÃO é limite de provedor — esse muda
 * com o tempo e com a conta, e o assistente não tem como saber. É o número
 * conservador com que uma conta nova começa, e que a pessoa edita no cartão
 * antes de autorizar. Quem impõe o teto de verdade é o banco, com a quota que
 * ficar gravada (invariante 3).
 *
 * Chip não oficial frio é o mais baixo de propósito: é o que é banido quando
 * começa alto.
 */
export function tetoPorConta(canal: CanalEnvio, familia: Familia, pool: Pool): number {
  if (canal === 'whatsapp') return familia === 'oficial' ? 250 : pool === 'fria' ? 40 : 80;
  if (canal === 'email') return 200;
  return 500;
}

/** O número que a pergunta "quantas por dia?" já traz preenchido. */
export function sugestaoDiaria(canal: CanalEnvio, pool: Pool): number {
  if (canal === 'whatsapp') return pool === 'fria' ? 40 : 80;
  if (canal === 'email') return 200;
  return 300;
}

// ---------------------------------------------------------------------------
// Perguntas
// ---------------------------------------------------------------------------

export type Resposta = string | readonly string[] | Readonly<Record<string, number>>;
export type Respostas = Readonly<Record<string, Resposta>>;

export interface Opcao {
  readonly valor: string;
  readonly rotulo: string;
  readonly detalhe?: string;
  /** Presente = não dá para escolher, e o texto diz por quê. */
  readonly indisponivel?: string;
  readonly recomendada?: boolean;
}

export interface Pergunta {
  /** A chave da resposta em `Respostas`. `provedor:email` é uma pergunta por canal. */
  readonly chave: string;
  readonly texto: string;
  readonly ajuda?: string;
  readonly forma: 'multipla' | 'unica' | 'numeros';
  readonly opcoes: readonly Opcao[];
  /** Só em `numeros`: um campo por canal, já com a sugestão. */
  readonly numeros?: readonly { chave: CanalEnvio; rotulo: string; sugestao: number; ajuda: string }[];
}

const lista = (r: Respostas, k: string): readonly string[] => {
  const v = r[k];
  return Array.isArray(v) ? (v as readonly string[]) : [];
};
const texto = (r: Respostas, k: string): string | undefined => {
  const v = r[k];
  return typeof v === 'string' ? v : undefined;
};
const numeros = (r: Respostas, k: string): Readonly<Record<string, number>> => {
  const v = r[k];
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Readonly<Record<string, number>>) : {};
};

export function canaisEscolhidos(r: Respostas): CanalEnvio[] {
  return CANAIS_DE_ENVIO.filter((c) => lista(r, 'canais').includes(c));
}

export function poolEscolhido(r: Respostas): Pool | undefined {
  const p = texto(r, 'pool');
  return p === 'morna' || p === 'fria' ? p : undefined;
}

/** As famílias que têm algum provedor que sabe enviar neste canal. */
function familiasEntregaveis(f: Foto, canal: string): Familia[] {
  const ps = f.provedores.filter((p) => p.canal === canal && entregavel(p));
  return (['oficial', 'nao'] as Familia[]).filter((x) => ps.some((p) => (p.oficial ? 'oficial' : 'nao') === x));
}

function familiaDoWhatsapp(f: Foto, r: Respostas): Familia | undefined {
  const fams = familiasEntregaveis(f, 'whatsapp');
  if (fams.length === 1) return fams[0];
  const x = texto(r, 'familia:whatsapp');
  return x === 'oficial' || x === 'nao' ? x : undefined;
}

function perguntaCanais(f: Foto): Pergunta {
  return {
    chave: 'canais', forma: 'multipla',
    texto: 'Por quais canais você quer enviar?',
    ajuda: 'Pode marcar mais de um. Cada canal precisa de pelo menos uma conta conectada para enviar.',
    opcoes: [...CANAIS_DE_ENVIO, 'instagram'].map((c) => {
      const pode = f.provedores.some((p) => p.canal === c && entregavel(p));
      // "Não dá" não é "ainda não" (D54): nenhuma tela resolve, e por isso a
      // opção aparece marcada em vez de sumir. E canal que ganhar adapter
      // antes de o assistente saber configurá-lo continua indisponível AQUI —
      // aceitá-lo seria uma resposta que nenhuma pergunta seguinte lê.
      const motivo = !pode
        ? 'nenhum provedor sabe enviar por este canal ainda — não é configuração que falta'
        : !(CANAIS_DE_ENVIO as readonly string[]).includes(c)
          ? 'o assistente ainda não configura este canal — use a tela dele, em Canais'
          : undefined;
      return { valor: c, rotulo: NOME[c] ?? c, ...(motivo ? { indisponivel: motivo } : {}) };
    }),
  };
}

function perguntaPool(): Pergunta {
  return {
    chave: 'pool', forma: 'unica',
    texto: 'Para quem você vai mandar?',
    ajuda: 'Isso decide quais contas a campanha pode usar: conta de base morna nunca atende lista fria, e o contrário também.',
    opcoes: [
      { valor: 'morna', rotulo: 'Minha própria base', detalhe: 'clientes e leads que já falaram com você e deram consentimento (opt-in)' },
      { valor: 'fria', rotulo: 'Uma lista nova', detalhe: 'gente sem relação prévia — prospecção fria, com contas separadas da operação' },
    ],
  };
}

function perguntaPorDia(r: Respostas): Pergunta {
  const pool = poolEscolhido(r) ?? 'morna';
  return {
    chave: 'porDia', forma: 'numeros', opcoes: [],
    texto: 'Quantas mensagens por dia, em cada canal?',
    ajuda: 'O total do canal, somando todas as contas. Começar baixo e subir é mais seguro do que o contrário — conta nova que envia muito no primeiro dia é a que cai.',
    numeros: canaisEscolhidos(r).map((c) => ({
      chave: c, rotulo: NOME[c]!, sugestao: sugestaoDiaria(c, pool),
      ajuda: c === 'whatsapp' && pool === 'fria'
        ? 'Chip frio começa em ~40 por dia. Para mais, o plano propõe mais chips em vez de um chip só no limite.'
        : 'Você ajusta conta por conta antes de autorizar.',
    })),
  };
}

function perguntaFamilia(r: Respostas): Pergunta {
  const fria = poolEscolhido(r) === 'fria';
  return {
    chave: 'familia:whatsapp', forma: 'unica',
    texto: 'WhatsApp oficial ou não oficial?',
    // Uma pergunta só para isto, e não as duas famílias numa lista: muda a
    // base contratual, o risco de banimento e o pool permitido (D27).
    ajuda: 'Não dá para misturar os dois na mesma decisão: mudam o contrato, o risco de bloqueio e o tipo de lista que cada um aceita.',
    opcoes: [
      { valor: 'oficial', rotulo: 'Oficial', recomendada: !fria,
        detalhe: 'API oficial (Meta ou parceiro): exige consentimento e modelos aprovados; o caminho para a sua própria base' },
      { valor: 'nao', rotulo: 'Não oficial', recomendada: fria,
        detalhe: 'chip conectado por QR: é o que roda prospecção fria, com risco de bloqueio do número' },
    ],
  };
}

function perguntaProvedor(f: Foto, r: Respostas, canal: CanalEnvio): Pergunta {
  const pool = poolEscolhido(r) ?? 'morna';
  const fam = canal === 'whatsapp' ? familiaDoWhatsapp(f, r) : undefined;
  const existentes = contasDe(f, canal, pool);
  const provs = f.provedores.filter((p) => p.canal === canal && entregavel(p)
    && (fam === undefined || (p.oficial ? 'oficial' : 'nao') === fam));

  const opcoes: Opcao[] = [];
  if (existentes.length) {
    opcoes.push({
      valor: USAR, recomendada: true,
      rotulo: `Usar ${existentes.length === 1 ? 'a conta' : `as ${existentes.length} contas`} que já tenho`,
      detalhe: existentes.map((x) => x.apelido || x.identificador).join(', '),
    });
  }
  // Com conta, a escolha é usar. Conectar mais uma é na tela do canal, onde
  // a chave é digitada (D68) — oferecer aqui seria um botão que só navega.
  if (!existentes.length) {
    for (const p of provs) opcoes.push({ valor: p.slug, rotulo: p.nome, detalhe: p.descricao });
  }
  opcoes.push({ valor: NAO, rotulo: 'Configurar depois', detalhe: 'os passos deste canal ficam esperando até existir uma conta' });

  return {
    chave: `provedor:${canal}`, forma: 'unica', opcoes,
    texto: existentes.length
      ? `Você já tem ${existentes.length === 1 ? 'uma conta' : `${existentes.length} contas`} de ${NOME[canal]} para ${pool === 'fria' ? 'lista fria' : 'base própria'}. Usar?`
      : `Qual provedor de ${NOME[canal]} você vai usar?`,
    ajuda: existentes.length
      ? 'Para conectar mais contas, use a tela do canal: é lá que a chave é digitada.'
      : 'Você conecta a conta e a chave na tela do canal — o plano leva até lá. Assim que a conta aparecer, o assistente continua daqui.',
  };
}

/** Conta de IA que compõe: ligada e de provedor com adapter (D66). */
function contasIA(f: Foto, provedor: string) {
  return f.credenciaisIA.filter((c) => c.ativo && c.provedor === provedor
    && f.provedoresIA.some((p) => p.slug === provedor && p.tem_adapter));
}

function perguntaIA(f: Foto): Pergunta {
  return {
    chave: 'ia', forma: 'unica',
    texto: 'Quer que um agente responda os contatos? Com qual IA?',
    ajuda: 'O agente responde sozinho pelo motor, com freios em código, e devolve para uma pessoa o que não puder mandar. Dá para deixá-lo só escrevendo rascunhos, em Configurações ▸ Agentes. Aqui você escolhe a IA; a conta, logo depois, entre as que já estão conectadas.',
    opcoes: [
      ...f.provedoresIA.map((p) => {
        const n = contasIA(f, p.slug).length;
        return {
          valor: p.slug, rotulo: p.nome,           detalhe: n ? `${n} conta${n > 1 ? 's' : ''} conectada${n > 1 ? 's' : ''}` : 'nenhuma conta conectada ainda',
          ...(p.tem_adapter ? {} : { indisponivel: 'o motor ainda não sabe compor com este provedor' }),
        };
      }),
      { valor: NAO, rotulo: 'Agora não' },
    ],
  };
}

function perguntaContaIA(f: Foto, provedor: string): Pergunta {
  const nome = f.provedoresIA.find((p) => p.slug === provedor)?.nome ?? provedor;
  return {
    chave: 'ia:conta', forma: 'unica',
    texto: `Qual conta de ${nome}?`,
    ajuda: 'As contas e as chaves vivem em Configurações ▸ Provedores de IA. A campanha só aponta para uma delas.',
    opcoes: contasIA(f, provedor).map((c, i) => ({
      valor: c.id, rotulo: c.nome, detalhe: c.modelo ? `modelo ${c.modelo}` : undefined, recomendada: i === 0,
    })),
  };
}

function perguntaCRM(f: Foto): Pergunta {
  return {
    chave: 'crm', forma: 'unica',
    texto: 'Você usa CRM? O motor pode devolver para ele o que descobre.',
    ajuda: 'Quem pediu para sair, quem respondeu, telefone inválido e cadência concluída voltam para o card. Só o Pipefy escreve hoje; os outros guardam a credencial para quando o adapter existir.',
    opcoes: [
      ...f.provedoresCRM.map((p) => {
        const con = f.conexoesCRM.some((c) => c.ativo && c.provedor === p.slug);
        return {
          valor: p.slug, rotulo: p.nome, recomendada: con,
          detalhe: (con ? 'já conectado · ' : '') + (p.tem_adapter ? 'escreve no CRM' : 'só guarda a credencial por enquanto'),
        };
      }),
      { valor: NAO, rotulo: 'Não uso CRM' },
    ],
  };
}

/** Modelos que servem a esta configuração: mesmo pool, e pelo menos um canal
 *  em comum. Cruzamento parcial é legítimo (D47) — o vazio, não. */
export function modelosCompativeis(f: Foto, r: Respostas) {
  const pool = poolEscolhido(r);
  const canais = canaisEscolhidos(r);
  return f.modelos.filter((m) => m.tipo === pool && m.canais.some((c) => (canais as string[]).includes(c)));
}

function perguntaCampanha(f: Foto, r: Respostas): Pergunta {
  const canais = canaisEscolhidos(r) as string[];
  const ms = modelosCompativeis(f, r);
  return {
    chave: 'campanha', forma: 'unica',
    texto: 'Quer já criar a primeira campanha?',
    ajuda: ms.length
      ? 'Cada modelo vem com cadência e base legal prontas. A campanha usa só os canais que você escolheu.'
      : 'Nenhum modelo pronto combina com os canais e o tipo de lista escolhidos. Dá para montar uma campanha em branco depois, em Campanhas.',
    opcoes: [
      ...ms.map((m, i) => ({
        valor: m.slug, rotulo: m.nome, recomendada: i === 0,
        detalhe: `${m.descricao} · ${m.canais.filter((c) => canais.includes(c)).map((c) => NOME[c] ?? c).join(', ')}`,
      })),
      { valor: NAO, rotulo: 'Agora não' },
    ],
  };
}

/** A pergunta que vem depois destas respostas, ou `null` quando acabou. */
function seguinte(f: Foto, r: Respostas): Pergunta | null {
  if (!canaisEscolhidos(r).length) return perguntaCanais(f);
  if (!poolEscolhido(r)) return perguntaPool();
  if (!('porDia' in r)) return perguntaPorDia(r);
  for (const c of canaisEscolhidos(r)) {
    if (c === 'whatsapp' && familiasEntregaveis(f, c).length > 1 && !familiaDoWhatsapp(f, r)) return perguntaFamilia(r);
    if (!texto(r, `provedor:${c}`)) return perguntaProvedor(f, r, c);
  }
  const ia = texto(r, 'ia');
  if (!ia) return perguntaIA(f);
  // A conta só é perguntada quando existe alguma para escolher. Sem conta, o
  // plano aponta Configurações — e quando ela aparecer, esta pergunta surge.
  if (ia !== NAO && contasIA(f, ia).length && !texto(r, 'ia:conta')) return perguntaContaIA(f, ia);
  if (!texto(r, 'crm')) return perguntaCRM(f);
  if (!texto(r, 'campanha')) return perguntaCampanha(f, r);
  return null;
}

export interface Passo { readonly pergunta: Pergunta; readonly resposta: Resposta }

/**
 * Refaz a conversa do começo, levando só as respostas que a conversa ainda
 * pergunta. É por isso que desmarcar SMS apaga o provedor de SMS: a pergunta
 * deixa de existir, e a resposta órfã não chega ao plano.
 */
export function roteiro(f: Foto, r: Respostas): { passos: Passo[]; atual: Pergunta | null; respostas: Respostas } {
  let feitas: Record<string, Resposta> = {};
  const passos: Passo[] = [];
  for (;;) {
    const p = seguinte(f, feitas);
    if (!p) return { passos, atual: null, respostas: feitas };
    // A mesma pergunta duas vezes é `valida` aceitando o que `seguinte` não lê
    // (um canal escolhível que não é canal de envio, por exemplo). Sem esta
    // trava, o laço gira para sempre e a tela congela; com ela, a pergunta
    // volta e a pessoa responde de novo.
    if (p.chave in feitas) return { passos, atual: p, respostas: feitas };
    const resp = r[p.chave];
    if (resp === undefined || !valida(p, resp)) return { passos, atual: p, respostas: feitas };
    feitas = { ...feitas, [p.chave]: resp };
    passos.push({ pergunta: p, resposta: resp });
  }
}

/** Resposta que a pergunta aceita. Escolher o indisponível não passa. */
export function valida(p: Pergunta, resp: Resposta): boolean {
  const pode = (v: string) => p.opcoes.some((o) => o.valor === v && !o.indisponivel);
  if (p.forma === 'multipla') return Array.isArray(resp) && resp.length > 0 && resp.every(pode);
  if (p.forma === 'unica') return typeof resp === 'string' && pode(resp);
  if (!resp || typeof resp !== 'object' || Array.isArray(resp)) return false;
  const n = resp as Readonly<Record<string, number>>;
  return (p.numeros ?? []).every((c) => Number.isInteger(n[c.chave]) && n[c.chave]! > 0);
}

/** Volta à pergunta `chave`: ela e todas as que vieram depois saem. */
export function voltarPara(f: Foto, r: Respostas, chave: string): Respostas {
  const { passos } = roteiro(f, r);
  const i = passos.findIndex((p) => p.pergunta.chave === chave);
  if (i < 0) return r;
  return Object.fromEntries(passos.slice(0, i).map((p) => [p.pergunta.chave, p.resposta]));
}

/** Como a resposta aparece de volta na conversa. */
export function legenda(p: Pergunta, resp: Resposta): string {
  if (p.forma === 'numeros') {
    const n = resp as Readonly<Record<string, number>>;
    return (p.numeros ?? []).map((c) => `${c.rotulo}: ${n[c.chave]} por dia`).join(' · ');
  }
  const vs = Array.isArray(resp) ? resp : [resp as string];
  return vs.map((v) => p.opcoes.find((o) => o.valor === v)?.rotulo ?? v).join(', ');
}

// ---------------------------------------------------------------------------
// O agente de configuração (D72)
// ---------------------------------------------------------------------------

/** O que o agente pode responder em cada chave, lido da foto e das respostas
 *  de agora. É o vocabulário que ele recebe; quem confere de verdade é
 *  `aplicarSugestao`, porque a lista que sai daqui passa pela rede e volta. */
export interface EntradaDoMapa {
  readonly forma: Pergunta['forma'];
  readonly pergunta: string;
  readonly valores: readonly { valor: string; rotulo: string; detalhe?: string }[];
}

export function mapaDeRespostas(f: Foto, r: Respostas): Record<string, EntradaDoMapa> {
  const entrada = (p: Pergunta): EntradaDoMapa => ({
    forma: p.forma, pergunta: p.texto,
    valores: p.forma === 'numeros'
      ? (p.numeros ?? []).map((n) => ({ valor: n.chave, rotulo: n.rotulo, detalhe: `sugestão: ${n.sugestao} por dia` }))
      : p.opcoes.filter((o) => !o.indisponivel)
          .map((o) => ({ valor: o.valor, rotulo: o.rotulo, ...(o.detalhe ? { detalhe: o.detalhe } : {}) })),
  });
  // As perguntas que dependem de respostas anteriores são feitas como se a
  // pessoa já tivesse escolhido tudo — inclusive o que o agente vai sugerir
  // agora. Sem pool escolhido, a de quantidade vale para "base própria".
  const comCanais: Respostas = canaisEscolhidos(r).length ? r : { ...r, canais: [...CANAIS_DE_ENVIO] };
  const m: Record<string, EntradaDoMapa> = {
    canais: entrada(perguntaCanais(f)),
    pool: entrada(perguntaPool()),
    porDia: entrada(perguntaPorDia(comCanais)),
  };
  if (familiasEntregaveis(f, 'whatsapp').length > 1) m['familia:whatsapp'] = entrada(perguntaFamilia(r));
  for (const c of canaisEscolhidos(comCanais)) m[`provedor:${c}`] = entrada(perguntaProvedor(f, r, c));
  m.ia = entrada(perguntaIA(f));
  const contas = f.credenciaisIA.filter((c) => c.ativo && f.provedoresIA.some((p) => p.slug === c.provedor && p.tem_adapter));
  if (contas.length) {
    m['ia:conta'] = {
      forma: 'unica', pergunta: 'Qual conta de IA a campanha usa?',
      valores: contas.map((c) => ({ valor: c.id, rotulo: c.nome, detalhe: `${c.provedor} · ${c.modelo}` })),
    };
  }
  m.crm = entrada(perguntaCRM(f));
  m.campanha = poolEscolhido(r)
    ? entrada(perguntaCampanha(f, comCanais))
    : { forma: 'unica', pergunta: 'Quer já criar a primeira campanha?',
        valores: [...f.modelos.map((x) => ({ valor: x.slug, rotulo: x.nome, detalhe: `${x.tipo} · ${x.canais.join(', ')}` })),
                  { valor: NAO, rotulo: 'Agora não' }] };
  return m;
}

/**
 * Junta as respostas que o agente sugeriu às que a pessoa já deu, e diz quais
 * entraram. Entrar = o roteiro chegou até a pergunta e `valida` aceitou —
 * exatamente o que vale para um clique. Sugestão para pergunta que ainda não
 * chegou fica guardada e só conta quando a conversa chegar lá; sugestão
 * inválida é descartada aqui, e nunca chega à memória.
 *
 * Resposta que a PESSOA já deu não é trocada pelo agente: ela muda clicando
 * em "mudar". Sem esta regra, uma frase ambígua desfaria uma escolha feita.
 */
export function aplicarSugestao(
  f: Foto, r: Respostas, sugestao: Readonly<Record<string, unknown>>,
): { respostas: Respostas; aceitas: string[]; recusadas: string[] } {
  const novas: Record<string, Resposta> = {};
  for (const [k, v] of Object.entries(sugestao)) {
    if (k in r) continue;
    if (typeof v === 'string') novas[k] = v;
    else if (Array.isArray(v) && v.every((x) => typeof x === 'string')) novas[k] = [...new Set(v as string[])];
    else if (v && typeof v === 'object' && !Array.isArray(v)
      && Object.values(v).every((x) => Number.isInteger(x) && (x as number) > 0 && (x as number) <= 100000)) {
      novas[k] = { ...(v as Record<string, number>) };
    }
  }
  const juntas: Respostas = { ...r, ...novas };
  const { respostas: aceitasNoRoteiro, atual } = roteiro(f, juntas);
  const aceitas = Object.keys(novas).filter((k) => k in aceitasNoRoteiro);
  // O que espera: chave que nenhuma pergunta até agora leu, e que o mapa
  // conhece. A que a pergunta de agora recusou sai.
  const mapa = mapaDeRespostas(f, aceitasNoRoteiro);
  const espera = Object.keys(novas).filter((k) => !aceitas.includes(k) && k in mapa && atual?.chave !== k);
  const recusadas = Object.keys(sugestao).filter((k) => !(k in r) && !aceitas.includes(k) && !espera.includes(k));
  const guardar = Object.fromEntries([...aceitas, ...espera].map((k) => [k, novas[k]!]));
  return { respostas: { ...r, ...guardar }, aceitas, recusadas };
}

// ---------------------------------------------------------------------------
// O plano
// ---------------------------------------------------------------------------

export type Exige = 'administra' | 'opera';

interface Base {
  readonly id: string;
  readonly titulo: string;
  /** O que acontece se a pessoa autorizar, em português, sem jargão de banco. */
  readonly efeitos: readonly string[];
  readonly exige: Exige;
  /** Ações que precisam ter rodado antes: o id que uma produz, a outra usa. */
  readonly dependeDe: readonly string[];
}

export type Acao =
  | Base & { readonly tipo: 'ajustar_quota'; readonly remetente: string; readonly de: number; readonly para: number }
  /**
   * O que o assistente não faz por desenho: conectar conta, chave ou CRM.
   * É um cartão que leva à tela onde isso se faz (D68). `pronto` é lido da
   * `Foto`, nunca marcado à mão: quem diz que a conta existe é o banco.
   */
  | Base & { readonly tipo: 'configurar'; readonly rota: string; readonly pronto: boolean }
  | Base & { readonly tipo: 'criar_campanha'; readonly modelo: string; readonly nome: string; readonly canais: readonly CanalEnvio[] }
  | Base & {
      readonly tipo: 'ligar_agentes';
      /** Agente do catálogo por canal; a cópia do cliente nasce em `atribuir_agente`. */
      readonly agentes: readonly { canal: CanalEnvio; agente: string; nome: string }[];
      /** A conta de IA que a campanha passa a usar, ou `null` enquanto ela não existe. */
      readonly credencial: string | null;
    }
  | Base & { readonly tipo: 'abrir'; readonly rota: string };

export interface Plano {
  readonly acoes: readonly Acao[];
  /** O que o plano não resolve e a pessoa precisa saber antes de autorizar. */
  readonly avisos: readonly string[];
}

/** Onde se conecta a conta de cada canal. E-mail mora em Configurações (D62). */
export function rotaDoCanal(canal: CanalEnvio, familia: Familia): { rota: string; onde: string } {
  if (canal === 'email') return { rota: '/config/email', onde: 'Configurações ▸ E-mail' };
  if (canal === 'whatsapp') {
    return { rota: `/canais/whatsapp/${familia}`, onde: `Canais ▸ WhatsApp ▸ ${familia === 'oficial' ? 'Oficial' : 'Não oficial'}` };
  }
  return { rota: '/canais/sms', onde: 'Canais ▸ SMS' };
}

const CHAVE_LA = 'a chave é digitada lá e vai direto para o cofre (Vault) — o assistente não a vê';

export function montarPlano(f: Foto, bruto: Respostas): Plano {
  // Só o que a conversa ainda pergunta entra no plano.
  const { respostas: r } = roteiro(f, bruto);
  const pool = poolEscolhido(r);
  const acoes: Acao[] = [];
  const avisos: string[] = [];
  if (!pool) return { acoes, avisos };
  const porDia = numeros(r, 'porDia');
  const nomePool = pool === 'fria' ? 'lista fria' : 'base própria';

  for (const canal of canaisEscolhidos(r)) {
    const escolha = texto(r, `provedor:${canal}`);
    if (!escolha) continue;
    const alvo = porDia[canal] ?? sugestaoDiaria(canal, pool);
    const existentes = contasDe(f, canal, pool);

    if (escolha === NAO) {
      if (!existentes.length) {
        avisos.push(`${NOME[canal]} ficou sem conta: a campanha cria os passos desse canal e o motor os adia até existir uma — nada se perde, mas nada sai.`);
      }
      continue;
    }

    if (escolha === USAR) {
      // Distribuir o total entre as contas que já existem. Só propõe mexer na
      // que muda — e cada mudança é um cartão próprio, que dá para pular.
      const cada = Math.max(1, Math.ceil(alvo / existentes.length));
      for (const x of existentes) {
        if (x.quota_diaria === cada) continue;
        acoes.push({
          id: `quota:${x.id}`, tipo: 'ajustar_quota', remetente: x.id, de: x.quota_diaria, para: cada,
          titulo: `Ajustar a quota de ${x.apelido || x.identificador}`,
          efeitos: [`a conta passa de ${x.quota_diaria} para ${cada} mensagens por dia`,
                    'o banco recusa enviar além disso, mesmo que a campanha peça'],
          exige: 'administra', dependeDe: [],
        });
      }
      const fam: Familia = canal === 'whatsapp'
        ? (f.provedores.find((p) => p.slug === existentes[0]!.provedor)?.oficial ? 'oficial' : 'nao') : 'oficial';
      const teto = tetoPorConta(canal, fam, pool);
      if (cada > teto) {
        avisos.push(`${NOME[canal]}: ${cada} por conta é mais do que o ponto de partida de ${teto}. Contas novas que começam alto são as que caem — considere conectar mais contas na tela do canal.`);
      }
      continue;
    }

    // Provedor escolhido e nenhuma conta ainda: com conta, a pergunta só
    // oferece usar. Conectar é na tela do canal, onde a chave é digitada.
    const prov = f.provedores.find((p) => p.slug === escolha);
    if (!prov) continue;
    const fam: Familia = prov.oficial ? 'oficial' : 'nao';
    const teto = tetoPorConta(canal, fam, pool);
    const quota = Math.max(1, Math.min(teto, alvo));
    const { rota, onde } = rotaDoCanal(canal, fam);

    acoes.push({
      id: `config:${canal}`, tipo: 'configurar', rota,
      pronto: existentes.some((x) => x.provedor === prov.slug),
      titulo: `Conectar uma conta ${prov.nome} (${NOME[canal]})`,
      efeitos: [
        `em ${onde}, cadastre a conta para ${nomePool}, com até ${quota} mensagens por dia`,
        CHAVE_LA,
        ...(pool === 'fria'
          ? ['lista fria nunca usa o número nem o domínio da operação institucional — use um separado'] : []),
        'quando a conta aparecer, o assistente continua daqui sozinho',
      ],
      exige: 'administra', dependeDe: [],
    });

    if (quota < alvo) {
      const mais = Math.ceil((alvo - quota) / teto);
      avisos.push(`${NOME[canal]}: uma conta começa em até ${quota} por dia, e você pediu ${alvo}. Para chegar lá, faltam ${mais === 1 ? 'mais uma conta' : `mais ${mais} contas`} de até ${teto} por dia.`);
    }
  }

  // IA: a conta é escolhida, nunca criada aqui (D68).
  const ia = texto(r, 'ia');
  let credencial: string | null | undefined;
  if (ia && ia !== NAO) {
    const conta = texto(r, 'ia:conta');
    if (conta) {
      credencial = conta;
    } else {
      const p = f.provedoresIA.find((x) => x.slug === ia);
      credencial = null;
      acoes.push({
        id: 'config:ia', tipo: 'configurar', rota: '/config/ia', pronto: false,
        titulo: `Conectar uma conta de ${p?.nome ?? ia}`,
        efeitos: [
          `em Configurações ▸ Provedores de IA, conecte uma conta de ${p?.nome ?? ia} — pode ser mais de uma`,
          CHAVE_LA,
          'quando a conta aparecer, o assistente pergunta qual delas a campanha usa',
        ],
        exige: 'administra', dependeDe: [],
      });
    }
  }

  // CRM
  const crm = texto(r, 'crm');
  if (crm && crm !== NAO) {
    const p = f.provedoresCRM.find((x) => x.slug === crm);
    if (p) {
      const con = f.conexoesCRM.find((c) => c.ativo && c.provedor === p.slug);
      acoes.push({
        id: 'config:crm', tipo: 'configurar', rota: '/config/vinculadas', pronto: !!con,
        titulo: con ? `${p.nome} conectado: ${con.nome}` : `Conectar o ${p.nome}`,
        efeitos: con ? ['a conexão já existe e está ligada'] : [
          `em Configurações ▸ Plataformas vinculadas, conecte o ${p.nome}`,
          CHAVE_LA,
          ...(p.tem_adapter ? [] : [`por enquanto só guarda: nenhum fato é escrito no ${p.nome} até o adapter existir`]),
        ],
        exige: 'administra', dependeDe: [],
      });
      if (con && p.tem_adapter) {
        acoes.push({
          id: 'crm:fatos', tipo: 'abrir', rota: `/config/vinculadas/${con.id}`,
          titulo: `Escolher o que cada fato faz no ${p.nome}`,
          efeitos: ['abre a tela da conexão: quem respondeu, quem pediu para sair e quem concluiu vão para a fase ou o campo que você escolher'],
          exige: 'administra', dependeDe: [],
        });
      }
    }
  }

  // Campanha e agentes
  const camp = texto(r, 'campanha');
  const modelo = camp && camp !== NAO ? f.modelos.find((m) => m.slug === camp) : undefined;
  if (modelo) {
    const canais = canaisEscolhidos(r).filter((c) => modelo.canais.includes(c));
    acoes.push({
      id: 'campanha', tipo: 'criar_campanha', modelo: modelo.slug, nome: modelo.nome, canais,
      titulo: `Criar a campanha "${modelo.nome}"`,
      efeitos: [
        `cria a campanha com a cadência do modelo, por ${canais.map((c) => NOME[c]).join(', ')}`,
        'ela nasce ligada, mas ninguém recebe nada até você inscrever contatos',
        'enquanto o motor estiver em modo simulado, ele monta as mensagens e não envia — você vê o texto na tela da campanha',
      ],
      exige: 'opera', dependeDe: [],
    });

    if (credencial !== undefined) {
      const agentes = canais.flatMap((c) => {
        const a = f.agentes.filter((x) => x.canal === c && x.tenant_id === null)
          .sort((x, y) => x.nome.localeCompare(y.nome))[0];
        return a ? [{ canal: c, agente: a.id, nome: a.nome }] : [];
      });
      const conta = credencial ? f.credenciaisIA.find((c) => c.id === credencial) : undefined;
      if (agentes.length) {
        acoes.push({
          id: 'agentes', tipo: 'ligar_agentes', agentes, credencial,
          titulo: 'Pôr um agente em cada canal da campanha',
          efeitos: [
            ...agentes.map((a) => `${NOME[a.canal]}: ${a.nome}`),
            conta ? `a campanha compõe com a conta "${conta.nome}"` : 'a campanha compõe com a conta de IA que você conectar',
            'o agente responde sozinho pelo motor (em simulado, nada sai); o que ele não puder mandar volta para uma pessoa, na tela de Respostas',
          ],
          exige: 'opera',
          dependeDe: ['campanha', ...(credencial === null ? ['config:ia'] : [])],
        });
      }
    }
  } else if (credencial !== undefined) {
    avisos.push('A conta de IA fica escolhida só quando houver campanha: escolha-a na tela da campanha, em "Quem responde".');
  }

  acoes.push({
    id: 'importar', tipo: 'abrir', rota: '/contatos/importar',
    titulo: f.contatos ? 'Importar mais contatos' : 'Importar os primeiros contatos',
    efeitos: ['abre a importação de planilha: ela mostra o que cada coluna virou e o que aconteceria, antes de gravar qualquer coisa'],
    exige: 'opera', dependeDe: [],
  });

  return { acoes, avisos };
}

/** Dependência cumprida: feita nesta conversa, ou pronta segundo o banco. */
export function cumprida(plano: readonly Acao[], feitos: Readonly<Record<string, string>>, id: string): boolean {
  if (feitos[id]) return true;
  const a = plano.find((x) => x.id === id);
  return !!a && a.tipo === 'configurar' && a.pronto;
}

/** `null` = pode. Texto = por que não, para o cartão dizer em vez de falhar. */
export function impedimento(f: Foto, a: Acao): string | null {
  if (a.exige === 'administra' && !f.administra) {
    return 'só quem administra o cliente (dono ou admin) pode autorizar este passo';
  }
  if (a.exige === 'opera' && !f.opera) return 'seu papel neste cliente é só de leitura';
  return null;
}

// ---------------------------------------------------------------------------
// O que já está feito
// ---------------------------------------------------------------------------

export interface Item {
  readonly id: string;
  readonly titulo: string;
  readonly feito: boolean;
  readonly detalhe: string;
}

/** A lista do topo da tela. Lida do banco, nunca guardada (ver o topo). */
export function situacao(f: Foto): Item[] {
  const contas = CANAIS_DE_ENVIO.map((c) => {
    const xs = f.remetentes.filter((r) => r.canal === c && r.estado !== 'desativado');
    return { c, n: xs.length, dia: xs.reduce((s, x) => s + x.quota_diaria, 0) };
  }).filter((x) => x.n);
  const ia = f.credenciaisIA.filter((c) => c.ativo);
  const crm = f.conexoesCRM.filter((c) => c.ativo);
  const camps = f.campanhas.filter((c) => c.ativa);
  return [
    { id: 'canais', titulo: 'Canais', feito: contas.length > 0,
      detalhe: contas.length
        ? contas.map((x) => `${NOME[x.c]}: ${x.n} conta${x.n > 1 ? 's' : ''}, até ${x.dia}/dia`).join(' · ')
        : 'nenhuma conta conectada — sem ela nada sai' },
    { id: 'ia', titulo: 'Inteligência artificial', feito: ia.length > 0,
      detalhe: ia.length
        ? f.provedoresIA.map((p) => ({ p, n: ia.filter((c) => c.provedor === p.slug).length }))
            .filter((x) => x.n).map((x) => `${x.p.nome}: ${x.n} conta${x.n > 1 ? 's' : ''}`).join(' · ')
        : 'opcional: sem ela, o agente não responde quem escreve de volta — as contas se conectam em Configurações' },
    { id: 'crm', titulo: 'CRM', feito: crm.length > 0,
      detalhe: crm.length ? crm.map((c) => c.nome).join(', ') : 'opcional: sem ele, os fatos ficam só aqui' },
    { id: 'campanha', titulo: 'Campanha', feito: camps.length > 0,
      detalhe: camps.length ? `${camps.length} ligada${camps.length > 1 ? 's' : ''}` : 'nenhuma ligada' },
    { id: 'contatos', titulo: 'Contatos', feito: f.contatos > 0,
      detalhe: f.contatos ? `${f.contatos} na base` : 'nenhum ainda' },
  ];
}
