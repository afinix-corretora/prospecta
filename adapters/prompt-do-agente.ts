// O prompt do agente de resposta, num lugar só (D76).
//
// O agente é um só para todos os canais: quem fala é a persona, o que ele faz
// é o objetivo, o que é da empresa é o contexto do cliente — e o que muda de um
// canal para outro é do PRODUTO, acrescentado aqui na hora de compor. "Variando
// apenas a funcionalidade de acordo com cada plataforma" é este arquivo.
//
// Mora em `adapters/` pelo motivo de `segredo.ts` e `leitura.ts`: o worker
// (`motor/agente.ts`) e a tela (a prévia do construtor) importam o MESMO
// `montarPedido`. Duas montagens seriam a tela mostrando um prompt e o motor
// mandando outro — o D55 com o modelo no lugar do template.
//
// Puro: nenhum `fetch`, nenhum ambiente. Mudou aqui, muda o bundle do
// `motor-worker` e do `agente-testar` — os dois precisam ser republicados, e
// `conferir-publicado.py` fica vermelho até isso acontecer (D51).
//
// Personas e objetivos são CATÁLOGO DO PRODUTO, e o agente guarda uma CÓPIA
// do texto — o catálogo não muda o agente de ninguém, a mesma regra dos
// modelos de campanha. Por isso eles moram aqui e não numa tabela: o worker
// nunca os lê; só a tela e o setup, para pré-preencher.

import type { Canal } from './tipos.ts';
import { separarAssunto } from './email.ts';

/** A palavra que o modelo devolve, sozinha, quando o caso é de uma pessoa. */
export const MARCA_ESCALAR = '[ESCALAR]';

/**
 * A palavra que o modelo devolve quando a pessoa pede para sair com palavras
 * que a blacklist não reconheceu. Quem a blacklist reconhece já foi suprimido
 * e nem chega aqui; quem ela não reconheceu NÃO está suprimido — e um agente
 * que respondesse "pronto, não vamos mais te contatar" estaria prometendo uma
 * supressão que ninguém gravou. A marca leva o caso a uma pessoa (D76).
 */
export const MARCA_SAIR = '[SAIR]';

/** Comparação sem acento e sem caixa: "Não posso" e "nao posso" são a mesma frase proibida. */
export function semAcento(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

/**
 * Pedidos de dado que nenhum rascunho faz, seja qual for a instrução do
 * cliente. Pedir CPF ou cartão por mensagem é o golpe que o contato aprendeu
 * a temer — e o primeiro passo para o chip ser denunciado.
 *
 * O freio olha FRASE A FRASE e só barra a frase que PEDE: pergunta, ou verbo
 * de pedido, e sem negação. "Por aqui não pedimos CPF nem senha" é o agente
 * tranquilizando a pessoa — barrar isso com o motivo "pede dado sensível" foi
 * o que a sonda ao vivo mostrou na primeira versão (D76).
 */
const DADO_SENSIVEL = /\b(cpf|rg|senha|cartao de credito|(numero|dados) d[oa] (seu |sua )?cartao|codigo de seguranca|cvv|dados bancarios|numero da (sua )?conta)\b/;
const PEDIDO = /\?|\b(me )?(manda|mande|envia|envie|passa|passe|informa|informe|digita|digite|confirma|confirme|diga|fala)\b|\b(preciso|precisamos|precisaria) d[oa]\b/;
const NEGACAO = /\b(nao|nunca|jamais|nem)\b/;

/**
 * Pergunta sobre a saúde DA PESSOA: dado sensível pela LGPD (art. 5º, II), e
 * conversa da equipe, não do agente. O que é COBERTURA do plano — internação,
 * acomodação, atendimento a gestante, tratamento odontológico — é produto, e a
 * frase que fala de plano não é barrada.
 */
const SAUDE_DA_PESSOA = /\b(doencas?|doente|problemas? de saude|condic(ao|oes) de saude|preexistentes?|cirurgias?|operad[oa]|gravida|gestante|gravidez|remedios?|medicamentos?|pressao alta|hipertens\w*|diabet\w*|fuma|fumante|tratamento medico|diagnosticos?|internad[oa]s?|seu peso|sua altura|peso e altura)\b/;
const FALA_DO_PLANO = /\b(cobertura|coberturas|cobre|cobrem|plano|planos|inclui|incluem|coparticipacao|acomodacao|enfermaria|apartamento|carencias?|rede)\b/;

/**
 * O agente confirmando uma remoção que ninguém gravou. Os agentes de antes do
 * D76 têm "confirme em uma frase e encerre" na instrução, e quem decide entre
 * isso e o [SAIR] da regra é só o cabeçalho. A confirmação vira escalada: a
 * pessoa vai continuar recebendo da próxima campanha se ninguém a suprimir.
 */
const CONFIRMA_SAIDA = /\b(nao (vamos|vou|iremos|vai) mais (te |lhe )?(contatar|contactar|mandar|enviar|incomodar|chamar|escrever|procurar)|remov(i|emos|ido|ida|endo)\b.{0,30}\b(lista|cadastro|numero|contato|base)|descadastr\w*|nao (recebera|vai receber|recebe) mais|nao vai mais receber|(seu|teu) (numero|contato|e-?mail) (foi|esta|sera) (removido|excluido|retirado))/;

/** Carência prometida — a promessa que mais vira reclamação em plano de saúde. */
const PROMESSA_DE_CARENCIA = /\b(sem carencias?|carencia zero|isencao de carencias?|isent[oa] de carencias?|zero de carencia|carencia reduzida|carencias? reduzidas?|carencia de \d+ (dias|meses))\b/g;

/**
 * Valores em dinheiro escritos no texto: "R$ 289,90", "289 reais", "1 mil
 * reais", "289,90", "189/mês". Devolve o valor, para comparar com o que o
 * cliente escreveu — não a presença de um valor qualquer.
 */
function valoresEmDinheiro(normal: string): number[] {
  const achados: number[] = [];
  const num = (t: string) => Number(t.replace(/\./g, '').replace(',', '.'));
  const padroes: [RegExp, (m: RegExpExecArray) => number][] = [
    [/r\$\s*(\d+(?:\.\d{3})*(?:,\d{1,2})?)(\s*mil\b)?/g, (m) => num(m[1]!) * (m[2] ? 1000 : 1)],
    [/\b(\d+(?:\.\d{3})*(?:,\d{1,2})?)\s*(mil\s+)?reais\b/g, (m) => num(m[1]!) * (m[2] ? 1000 : 1)],
    [/\bmil reais\b/g, () => 1000],
    [/(?<![\d.,$])\b(\d{1,3}(?:\.\d{3})*,\d{2})\b/g, (m) => num(m[1]!)],
    [/\b(\d{2,}(?:,\d{1,2})?)\s*(\/\s*mes|por mes|ao mes|mensais)\b/g, (m) => num(m[1]!)],
  ];
  for (const [re, valor] of padroes) {
    for (let m = re.exec(normal); m; m = re.exec(normal)) achados.push(valor(m));
  }
  return achados;
}

/** Todo número escrito numa fonte, para dizer se um valor está lá. */
function numerosEscritos(normal: string): Set<number> {
  const s = new Set<number>();
  for (const m of normal.matchAll(/\d+(?:\.\d{3})*(?:,\d{1,2})?/g)) {
    const v = Number(m[0].replace(/\./g, '').replace(',', '.'));
    s.add(v);
    if (/\bmil\b/.test(normal.slice(m.index! + m[0].length, m.index! + m[0].length + 5))) s.add(v * 1000);
  }
  return s;
}

/**
 * Metadado que não vai ao modelo: documento, cartão, banco, saúde, e o texto
 * livre de anotação ("obs" é onde corretora anota a condição de saúde). A
 * planilha vira metadado TODA coluna que o motor não entende — e o pedido ao
 * provedor de IA não é lugar para CPF nem diagnóstico (D76). Por palavra da
 * chave, e também pelo VALOR: CPF ou termo de saúde no meio do texto.
 */
const PALAVRA_SENSIVEL = /^(cpf|rg|cnh|documento|carteirinha|cartao|senha|banco|bancari|agencia|pix|saude|doenca|comorbid|condic|cid\d*$|diagnostic|tratament|medicament|cirurgi|peso|altura|gravid|gestant|nasc|renda|rendiment|salario|obs|observ|nota|notas|anotac|coment)/;
const VALOR_SENSIVEL = /\d{3}\.\d{3}\.\d{3}-\d{2}|\bcpf\b|\b(diabet\w*|hipertens\w*|cancer|hemodialise|gravida|gestante|doenca|cirurgia|internad[oa]|cid ?[a-z]\d|depress\w*|hiv|preexistente)\b/;

function chaveSensivel(k: string): boolean {
  return semAcento(k).split(/[^a-z0-9]+/).some((p) => p !== '' && PALAVRA_SENSIVEL.test(p));
}

/** O que do contato vai ao modelo: só texto, e sem o que é sensível. A tela mostra a mesma lista. */
export function metadadosParaOModelo(m: Record<string, unknown> | null | undefined): [string, string][] {
  return Object.entries(m ?? {})
    .filter((e): e is [string, string] => typeof e[1] === 'string' && e[1].trim() !== '')
    .filter(([k, v]) => !chaveSensivel(k) && !VALOR_SENSIVEL.test(semAcento(v)));
}

// ---------------------------------------------------------------------------
// O que muda de canal para canal
// ---------------------------------------------------------------------------

export interface ComportamentoDoCanal {
  readonly nome: string;
  /** O freio: acima disto o texto é barrado, não cortado. */
  readonly limite: number;
  /**
   * A resposta da pessoa chega ao produto por este canal? Sem isso, nenhum
   * agente responde por ele, e a tela não pode oferecê-lo como se respondesse.
   * Conferido contra os adapters em `tests/prompt_do_agente.test.ts`.
   */
  readonly recebeResposta: boolean;
  /** Quando `recebeResposta` é falso, por quê — dito na tela. */
  readonly porQueNao?: string;
  readonly regras: readonly string[];
}

export const CANAIS: Readonly<Record<Canal, ComportamentoDoCanal>> = {
  whatsapp: {
    nome: 'WhatsApp',
    limite: 700,
    recebeResposta: true,
    regras: [
      'É uma conversa de WhatsApp: mensagem curta, de uma a três frases.',
      'Uma pergunta por mensagem.',
      'No máximo um emoji, e só se combinar com o tom.',
      'Sem formatação: nada de títulos, listas com marcador, negrito ou link encurtado.',
    ],
  },
  email: {
    nome: 'E-mail',
    limite: 2000,
    recebeResposta: true,
    regras: [
      'É uma resposta por e-mail: comece cumprimentando a pessoa pelo nome, se souber.',
      'Até três parágrafos curtos; use lista só para comparar opções.',
      'Feche com um próximo passo concreto e assine com o seu nome e o seu papel.',
    ],
  },
  sms: {
    nome: 'SMS',
    limite: 160,
    recebeResposta: false,
    porQueNao: 'o SMS ainda não traz a resposta da pessoa para o produto: nenhum agente responde por SMS',
    regras: [
      'É um SMS: uma mensagem só, de uma ou duas frases curtas, sem emoji e sem link.',
      'O SMS confirma uma intenção e leva a conversa para o WhatsApp ou para uma ligação.',
    ],
  },
  instagram: {
    nome: 'Instagram',
    // O direct aceita menos de 1000 bytes; com acento, 800 caracteres cabem.
    limite: 800,
    recebeResposta: false,
    porQueNao: 'o Instagram ainda não tem provedor que receba ou envie mensagens',
    regras: [
      'É o direct do Instagram: tom leve, frases curtas, no máximo um emoji.',
      'A conversa só pode continuar até 24 horas depois da última mensagem da pessoa; se precisar seguir depois disso, peça o WhatsApp dela.',
    ],
  },
};

export function ehCanal(canal: string): canal is Canal {
  return Object.prototype.hasOwnProperty.call(CANAIS, canal);
}

/**
 * O teto que vale: o do canal, ou o do agente se ele pediu menos. Canal sem
 * comportamento declarado LANÇA — o freio não pode desligar por omissão
 * (`length > undefined` é falso, e o texto passaria de qualquer tamanho).
 */
export function limiteEfetivo(canal: string, tamanhoDoAgente: number | null): number {
  if (!ehCanal(canal)) throw new Error(`canal sem comportamento declarado: ${canal}`);
  const doCanal = CANAIS[canal].limite;
  return tamanhoDoAgente && tamanhoDoAgente > 0 ? Math.min(doCanal, tamanhoDoAgente) : doCanal;
}

/**
 * O que se PEDE ao modelo: três quartos do freio. Modelo não conta
 * caractere, e pedir o limite exato devolve com frequência um pouco acima —
 * barrado, e a pessoa sem resposta.
 */
export function alvoDeTamanho(limite: number): number {
  return Math.floor(limite * 0.75);
}

// ---------------------------------------------------------------------------
// Personas e objetivos (catálogo do produto)
// ---------------------------------------------------------------------------

export interface Persona {
  readonly slug: string;
  readonly nome: string;
  readonly resumo: string;
  /** Só a voz. Tamanho e formato são do canal — persona que dissesse
   *  "mensagens curtas" brigaria com o e-mail. */
  readonly tom: string;
}

export const PERSONAS: readonly Persona[] = [
  {
    slug: 'consultiva', nome: 'Consultiva',
    resumo: 'Entende a necessidade antes de sugerir qualquer coisa.',
    tom: 'Fale como um consultor que quer entender antes de sugerir. Faça uma pergunta de cada vez e mostre que '
      + 'ouviu: retome em poucas palavras o que a pessoa disse antes de seguir. Quando uma pergunta não for óbvia, '
      + 'diga por que está perguntando. Seja cordial sem ser íntimo e trate a pessoa por "você". Nada de pressão, '
      + 'urgência inventada ou frase de vendedor, como "última chance" ou "imperdível".',
  },
  {
    slug: 'proxima', nome: 'Próxima',
    resumo: 'Leve e calorosa, como alguém da equipe que já conhece a pessoa.',
    tom: 'Fale de um jeito leve e caloroso, como alguém da equipe que já conhece a pessoa. Use o primeiro nome '
      + 'dela quando souber, palavras do dia a dia e frases simples. Um emoji pode entrar quando combinar com o '
      + 'momento e o canal permitir. Simpatia não é intimidade: sem apelido, sem gíria forte e sem brincadeira com '
      + 'saúde, dinheiro ou família.',
  },
  {
    slug: 'executiva', nome: 'Executiva',
    resumo: 'Formal e objetiva, para empresas e para quem decide.',
    tom: 'Fale com a formalidade de quem conversa com quem decide: sócios, diretores, gestores de RH e de compras. '
      + 'Vá ao ponto, sem cumprimento longo nem rodeio, e com respeito. Trate por "você", ou por "o senhor" e '
      + '"a senhora" se a pessoa se tratar assim. Sem emoji, sem gíria e sem exclamação. Prefira fato a adjetivo e '
      + 'termine com uma pergunta clara ou um próximo passo.',
  },
  {
    slug: 'objetiva', nome: 'Objetiva',
    resumo: 'Simples e sem rodeio, para quem tem pouco tempo.',
    tom: 'Fale de forma simples e objetiva, como quem respeita o tempo da pessoa. Diga primeiro o que importa, '
      + 'faça uma pergunta por mensagem e não repita o que já foi dito. Linguagem do dia a dia, sem formalidade '
      + 'demais e sem floreio. Se a pessoa disser que não tem interesse, agradeça e não argumente.',
  },
  {
    slug: 'acolhedora', nome: 'Acolhedora',
    resumo: 'Paciente e empática, para quem está inseguro ou num momento delicado.',
    tom: 'Fale com paciência e empatia: a pessoa pode estar insegura, cansada ou passando por um momento difícil. '
      + 'Reconheça o que ela disse antes de responder ("entendo", "faz sentido a sua dúvida"), explique sem termo '
      + 'técnico e nunca apresse a decisão. Seja calorosa sem exagero e sem frase pronta. Se ela mencionar doença, '
      + 'perda ou dificuldade, responda com respeito, não faça perguntas sobre isso e ofereça a conversa com uma '
      + 'pessoa da equipe.',
  },
];

export type TipoDeCampanha = 'morna' | 'fria';

export interface Objetivo {
  readonly slug: string;
  readonly nome: string;
  readonly resumo: string;
  /** Entra em "Você é {nome}, {papel}." */
  readonly papel: string;
  /** O que o agente faz, nesta ordem, e o que nunca faz. Vira `instrucoes`. */
  readonly roteiro: string;
  readonly escalar_quando: string;
  readonly limite_trocas: number;
  /** Com que tipo de campanha este objetivo combina (o de Resgate numa lista
   *  fria inventaria um relacionamento que não existe). */
  readonly combina: readonly TipoDeCampanha[];
}

// O princípio que vale para todos: TODO "sim" termina em escalar. O agente
// não tem agenda nem ferramenta; ele qualifica, e quem marca e fecha é gente.
// Um roteiro que dissesse "vou agendar" seria promessa que ninguém recebe.
export const OBJETIVOS: readonly Objetivo[] = [
  {
    slug: 'prospeccao_fria', nome: 'Prospecção fria',
    resumo: 'Primeira conversa com quem nunca falou com a empresa.',
    papel: 'assistente de primeiro contato',
    roteiro: 'Esta pessoa nunca falou com a empresa e não pediu este contato. Cada mensagem precisa justificar a '
      + 'próxima.\n\nO que fazer, nesta ordem:\n'
      + '1. Se perguntarem quem é, diga em uma frase quem você é, em nome de qual empresa fala e por que escreveu.\n'
      + '2. Descubra se há encaixe, uma pergunta por vez: se já tem esse tipo de produto hoje, para quem seria (só '
      + 'para ela, para a família ou para a empresa) e se faz sentido ouvir uma proposta.\n'
      + '3. Se houver interesse, pergunte qual o melhor período para um especialista falar com ela.\n\n'
      + 'O que nunca fazer: fingir que já houve conversa antes, insistir depois de uma negativa, dizer que fala em '
      + 'nome de outra empresa, ou prometer preço, desconto ou condição.',
    escalar_quando: 'A pessoa quer proposta ou aceitou falar com um especialista; perguntou como conseguimos o '
      + 'contato dela; ou fez reclamação, pergunta jurídica ou ameaça de denúncia.',
    limite_trocas: 6, combina: ['fria'],
  },
  {
    slug: 'resgate', nome: 'Resgate',
    resumo: 'Retoma uma oportunidade antiga que esfriou.',
    papel: 'assistente de relacionamento',
    roteiro: 'Esta pessoa já conversou com a empresa, mostrou interesse e a conversa parou. Ela pode não lembrar '
      + 'dos detalhes.\n\nO que fazer, nesta ordem:\n'
      + '1. Lembre em uma frase de onde vocês se conhecem, sem cobrar a pessoa por ter sumido.\n'
      + '2. Pergunte se o assunto ainda faz sentido hoje e o que mudou desde a última conversa.\n'
      + '3. Se fizer sentido, confirme o essencial, uma pergunta por vez, e pergunte o melhor período para um '
      + 'especialista retomar com ela.\n\n'
      + 'O que nunca fazer: inventar detalhe da conversa anterior que não esteja no histórico, dizer que a proposta '
      + 'antiga continua valendo ou que existe condição especial, ou pressionar com prazo.',
    escalar_quando: 'Pergunta sobre valor, proposta anterior ou condição especial; dúvida sobre cobertura, carência '
      + 'ou contrato; reclamação; ou a pessoa aceitou falar com um especialista.',
    limite_trocas: 8, combina: ['morna'],
  },
  {
    slug: 'follow_up', nome: 'Follow-up',
    resumo: 'Retoma uma conversa recente que parou antes da decisão.',
    papel: 'assistente de acompanhamento',
    roteiro: 'Esta pessoa conversou com a empresa há pouco tempo, talvez já tenha recebido proposta ou cotação, e '
      + 'ainda não decidiu.\n\nO que fazer, nesta ordem:\n'
      + '1. Retome do ponto em que a conversa parou, pelo histórico; se houve proposta ou cotação, pergunte se ela '
      + 'conseguiu ver e se ficou alguma dúvida.\n'
      + '2. Se houver dúvida, entenda qual é, uma pergunta por vez, sem responder você mesmo o que for de valor, '
      + 'cobertura, prazo ou contrato.\n'
      + '3. Pergunte o que falta para ela decidir e se prefere conversar com o especialista.\n\n'
      + 'O que nunca fazer: afirmar que algo foi enviado se o histórico não mostrar, reabrir a negociação por conta '
      + 'própria, oferecer desconto, dizer que a proposta vence para apressar a decisão, ou repetir números da '
      + 'proposta.',
    escalar_quando: 'Dúvida sobre valor, cobertura, carência, prazo ou cláusula; pedido de mudança na proposta; a '
      + 'pessoa quer fechar ou falar com o especialista; ou disse que escolheu outra empresa.',
    limite_trocas: 6, combina: ['morna'],
  },
  {
    slug: 'renovacao', nome: 'Renovação',
    resumo: 'Cliente com contrato perto do vencimento.',
    papel: 'assistente de renovação',
    roteiro: 'Esta pessoa já é cliente e o contrato dela está perto de vencer. O objetivo é que ela renove com '
      + 'acompanhamento e sem surpresa.\n\nO que fazer, nesta ordem:\n'
      + '1. Confirme que está falando com a pessoa certa e lembre que o vencimento está próximo, sem citar valores.\n'
      + '2. Pergunte se algo mudou desde a contratação: pessoas incluídas, endereço, uso ou necessidade.\n'
      + '3. Ofereça que o especialista revise as condições antes do vencimento e pergunte o melhor período para o '
      + 'contato.\n\n'
      + 'O que nunca fazer: informar valor, reajuste ou condição de renovação que não estejam nas informações do '
      + 'contato; dizer que a renovação é automática ou que nada muda; tratar de pagamento ou sinistro.',
    escalar_quando: 'Pedido de valor ou de reajuste; vontade de cancelar ou de trocar de empresa; assunto de '
      + 'pagamento, atraso ou sinistro; reclamação; ou a pessoa aceitou a revisão com o especialista.',
    limite_trocas: 6, combina: ['morna'],
  },
  {
    slug: 'agendamento', nome: 'Agendamento',
    resumo: 'Leva a conversa até um horário com o especialista.',
    papel: 'assistente de agenda',
    roteiro: 'O objetivo desta conversa é levar a pessoa até uma conversa com um especialista. Você não tem acesso '
      + 'à agenda e não marca horário: quem confirma é a equipe.\n\nO que fazer, nesta ordem:\n'
      + '1. Responda em poucas palavras o que a pessoa perguntou, sem entrar em valor ou condição.\n'
      + '2. Pergunte se ela prefere ligação, chamada de vídeo ou mensagem.\n'
      + '3. Pergunte qual dia e período são melhores para ela.\n\n'
      + 'O que nunca fazer: confirmar um horário como se estivesse marcado, prometer que alguém liga em seguida, ou '
      + 'insistir se ela não quiser marcar agora; nesse caso, agradeça e deixe a porta aberta.',
    escalar_quando: 'A pessoa indicou dia ou período, pediu que liguem agora, quer remarcar ou cancelar um horário, '
      + 'ou perguntou valor, cobertura ou condição.',
    limite_trocas: 6, combina: ['morna', 'fria'],
  },
  {
    slug: 'atendimento', nome: 'Atendimento',
    resumo: 'Responde com o que a empresa informou e passa o resto para a equipe.',
    papel: 'assistente de atendimento',
    roteiro: 'A pessoa respondeu com uma dúvida ou um pedido. O objetivo é responder o que estiver nas informações '
      + 'da empresa e deixar o resto para a equipe, sem inventar.\n\nO que fazer, nesta ordem:\n'
      + '1. Entenda o que ela quer; se não ficou claro, faça uma pergunta só.\n'
      + '2. Responda usando apenas o que está em SOBRE A EMPRESA E A OFERTA, em linguagem simples.\n'
      + '3. Pergunte se ficou claro ou se ela quer falar com um especialista.\n\n'
      + 'O que nunca fazer: responder sobre contrato, pagamento, sinistro ou reembolso de um cliente específico; '
      + 'prometer prazo de solução; ou dizer que vai encaminhar. Quando a resposta não estiver nas informações, é '
      + 'caso de passar para uma pessoa.',
    escalar_quando: 'A resposta não está nas informações da empresa; assunto de contrato, pagamento, sinistro ou '
      + 'reembolso; reclamação ou insatisfação; ou pedido para falar com uma pessoa.',
    limite_trocas: 8, combina: ['morna', 'fria'],
  },
  {
    slug: 'pos_venda', nome: 'Pós-venda',
    resumo: 'Boas-vindas, satisfação e indicação para quem já é cliente.',
    papel: 'assistente de relacionamento com clientes',
    roteiro: 'Esta pessoa já é cliente. O objetivo é que ela se sinta acompanhada: boas-vindas, saber se está tudo '
      + 'bem e, se estiver satisfeita, abrir espaço para uma indicação.\n\nO que fazer, nesta ordem:\n'
      + '1. Agradeça a confiança e pergunte como está a experiência até aqui.\n'
      + '2. Se houver dúvida simples e a resposta estiver nas informações da empresa, responda; se não estiver, é '
      + 'caso para a equipe.\n'
      + '3. Se ela estiver satisfeita, pergunte se conhece alguém que também poderia se beneficiar, sem insistir e '
      + 'sem pedir por mensagem nome ou telefone de outra pessoa.\n\n'
      + 'O que nunca fazer: oferecer outro produto antes de saber se ela está satisfeita, discutir reclamação por '
      + 'conta própria, ou tratar de pagamento, sinistro e contrato.',
    escalar_quando: 'Insatisfação ou reclamação; pedido de cancelamento; assunto de pagamento, sinistro, reembolso '
      + 'ou contrato; ou a pessoa quer indicar alguém.',
    limite_trocas: 5, combina: ['morna'],
  },
];

export function persona(slug: string | null | undefined): Persona | undefined {
  return PERSONAS.find((p) => p.slug === slug);
}

export function objetivo(slug: string | null | undefined): Objetivo | undefined {
  return OBJETIVOS.find((o) => o.slug === slug);
}

/**
 * Qual objetivo um modelo de campanha pede — para o setup criar o agente
 * certo. Pelo slug do modelo quando ele diz; senão, pelo tipo da campanha.
 */
export function objetivoDoModelo(slugDoModelo: string | null | undefined, tipo: TipoDeCampanha): string {
  const s = slugDoModelo ?? '';
  if (s.startsWith('prospeccao-fria')) return 'prospeccao_fria';
  if (s.startsWith('resgate')) return 'resgate';
  if (s.startsWith('renovacao')) return 'renovacao';
  if (s.startsWith('reengajamento')) return 'follow_up';
  return tipo === 'fria' ? 'prospeccao_fria' : 'resgate';
}

/**
 * O agente combina com a campanha? `conflito` é o caso que inventa
 * relacionamento (objetivo de base própria numa lista fria) ou trata como
 * estranho quem já é da casa (prospecção fria numa base morna). Agente antigo,
 * sem objetivo, não é julgado.
 */
export function objetivoCombina(tipo: TipoDeCampanha, slugDoObjetivo: string | null | undefined): 'ok' | 'conflito' {
  const o = objetivo(slugDoObjetivo);
  if (!o) return 'ok';
  return o.combina.includes(tipo) ? 'ok' : 'conflito';
}

/** O mínimo que "Sobre a empresa e a oferta" precisa ter num agente novo. */
export const CONTEXTO_MINIMO = 40;

/** Os campos de um agente novo, pré-preenchidos pela persona e pelo objetivo. */
export function agenteNovo(e: { persona: string; objetivo: string; empresa: string }) {
  const p = persona(e.persona) ?? PERSONAS[0]!;
  const o = objetivo(e.objetivo) ?? OBJETIVOS[0]!;
  return {
    persona: p.slug,
    objetivo: o.slug,
    papel: o.papel,
    descricao: o.resumo,
    tom: p.tom,
    instrucoes: o.roteiro,
    contexto: e.empresa.trim() ? `Falamos em nome de ${e.empresa.trim()}.` : '',
    escalar_quando: o.escalar_quando,
    limite_trocas: o.limite_trocas,
  };
}

// ---------------------------------------------------------------------------
// O pedido ao modelo
// ---------------------------------------------------------------------------

/** O que `montarPedido` precisa saber. A fila do motor e a prévia da tela dão isto. */
export interface EntradaDoPrompt {
  readonly canal: string;
  readonly texto: string;
  readonly agente_nome: string;
  readonly papel: string;
  readonly descricao: string;
  /** Como fala (persona). Vazio nos agentes de antes do D76. */
  readonly tom: string;
  /** O que faz (objetivo), ou a instrução inteira nos agentes de antes do D76. */
  readonly instrucoes: string;
  /** Sobre a empresa e a oferta. Vazio nos agentes de antes do D76. */
  readonly contexto: string;
  /** Nulo nos agentes de antes do D76 — é o que decide o título da instrução. */
  readonly objetivo: string | null;
  readonly escalar_quando: string;
  readonly proibido: readonly string[];
  readonly tamanho_maximo: number | null;
  readonly contato_nome: string | null;
  readonly metadados: Record<string, unknown> | null;
  readonly campanha: string;
  readonly historico: readonly { de: 'nos' | 'pessoa'; texto: string }[];
}

export interface Pedido {
  readonly sistema: string;
  readonly mensagem: string;
  /** O freio que vale para este pedido — o mesmo que `aplicarFreios` usa. */
  readonly limite: number;
}

/** "Ana — resgate no WhatsApp" é rótulo de lista; o agente se apresenta como "Ana". */
export function nomeDeApresentacao(nome: string): string {
  return nome.split(/\s+[—–-]\s+/)[0]!.trim() || nome.trim();
}

/** O assunto da nossa última mensagem de e-mail na conversa, para a resposta seguir nele. */
export function assuntoDaConversa(historico: EntradaDoPrompt['historico']): string | null {
  for (let i = historico.length - 1; i >= 0; i--) {
    const h = historico[i]!;
    if (h.de !== 'nos') continue;
    const { assunto } = separarAssunto(h.texto, '');
    if (assunto) return /^re:/i.test(assunto) ? assunto : `Re: ${assunto}`;
  }
  return null;
}

function secao(titulo: string, corpo: string): string[] {
  const t = corpo.trim();
  return t ? ['', titulo, t] : [];
}

export function montarPedido(r: EntradaDoPrompt): Pedido {
  const limite = limiteEfetivo(r.canal, r.tamanho_maximo);
  const canal = CANAIS[r.canal as Canal];
  const nome = nomeDeApresentacao(r.agente_nome);

  const regrasDoCanal = [...canal.regras];
  if (r.canal === 'email') {
    const assunto = assuntoDaConversa(r.historico);
    regrasDoCanal.push(assunto
      ? `A primeira linha da resposta é exatamente "Assunto: ${assunto}"; depois dela, uma linha em branco e o texto.`
      : 'Não escreva linha de assunto: o e-mail sai com o assunto da conta.');
  }

  const sistema = [
    `Você é ${nome}, ${r.papel}. ${r.descricao}`.trim(),
    ...secao('COMO VOCÊ FALA', r.tom),
    // Os agentes de antes do D76 têm a instrução inteira num texto só, que o
    // cliente escreveu — e o título continua dizendo isso.
    ...secao(r.objetivo ? 'O QUE VOCÊ FAZ' : 'INSTRUÇÕES DO CLIENTE', r.instrucoes),
    ...secao('SOBRE A EMPRESA E A OFERTA', r.contexto),
    '',
    `COMO ESTE CANAL FUNCIONA (${canal.nome})`,
    ...regrasDoCanal.map((x) => `- ${x}`),
    '',
    'REGRAS QUE VALEM SEMPRE (se algo acima disser o contrário, valem estas e as do canal)',
    `- Escreva só a próxima mensagem para a pessoa, em português do Brasil, com até ${alvoDeTamanho(limite)} `
      + `caracteres (nunca mais de ${limite}).`,
    '- Não invente preço, cobertura, prazo, carência, nome de empresa, produto nem condição que não esteja escrito acima.',
    '- Não peça CPF, senha nem dado de cartão.',
    '- Não pergunte sobre doença, tratamento ou condição de saúde; se a pessoa contar, não comente nem repita.',
    '- Não diga que é uma pessoa se perguntarem; diga que é o assistente virtual da equipe.',
    `- Se a pessoa pedir para não receber mais mensagens, responda exatamente ${MARCA_SAIR} e nada mais.`,
    `- Se a mensagem da pessoa se encaixar em: "${r.escalar_quando.trim()}", responda exatamente ${MARCA_ESCALAR} e nada mais.`,
    ...(r.proibido.length ? ['- Nunca use estas expressões: ' + r.proibido.map((p) => `"${p}"`).join(', ') + '.'] : []),
  ].join('\n');

  const variaveis = metadadosParaOModelo(r.metadados).map(([k, v]) => `- ${k}: ${v}`);
  const conversa = r.historico.map((h) => `${h.de === 'nos' ? 'Nós' : 'Pessoa'}: ${h.texto}`);
  const mensagem = [
    // O nome da campanha é rótulo interno: dito sem aviso, o modelo o trata
    // como produto ("o resgate multicanal funciona assim…").
    `Campanha (nome interno, não cite para a pessoa): ${r.campanha}. Canal: ${canal.nome}.`,
    `Contato: ${r.contato_nome ?? '(sem nome)'}.`,
    ...(variaveis.length ? ['O que sabemos dele:', ...variaveis] : []),
    '',
    'Conversa até aqui, da mais antiga para a mais recente:',
    ...(conversa.length ? conversa : [`Pessoa: ${r.texto}`]),
    '',
    'Escreva a próxima mensagem.',
  ].join('\n');

  return { sistema, mensagem, limite };
}

// ---------------------------------------------------------------------------
// Os freios
// ---------------------------------------------------------------------------

export type Freio =
  | { readonly situacao: 'pronto'; readonly texto: string }
  | { readonly situacao: 'escalar' | 'bloqueado'; readonly motivo: string };

/**
 * O e-mail sai com o assunto que o adapter reconhece: "Assunto: X" na primeira
 * linha. O modelo às vezes a escreve em Markdown ("**Assunto: X**"), e aí ela
 * ia parar no corpo, com os asteriscos, e o assunto virava o padrão da conta.
 */
export function normalizarSaida(texto: string, canal: string): string {
  const limpo = texto.trim();
  if (canal !== 'email') return limpo;
  const [primeira = '', ...resto] = limpo.split('\n');
  const m = primeira.match(/^[\s*_#>]*assunto\s*:\s*(.+?)[\s*_]*$/i);
  return m ? [`Assunto: ${m[1]!.replace(/^[*_]+|[*_]+$/g, '').trim()}`, ...resto].join('\n') : limpo;
}

/** O texto em frases: é na frase que se decide se há pedido, pergunta ou negação. */
function frases(texto: string): string[] {
  return texto.split(/(?<=[.!?\n])/).map((x) => x.trim()).filter(Boolean);
}

/**
 * O que vale conferir no texto que o modelo devolveu. A instrução diz ao
 * modelo o que não fazer; o freio confere que ele não fez (D66).
 *
 * Valor e carência: o que o CLIENTE escreveu sobre a oferta (o contexto, e o
 * que se sabe do contato) o agente pode repetir — o MESMO valor, a mesma
 * condição. O que não está lá, ele inventou. Nos agentes de antes do D76 a
 * instrução inteira é do cliente e conta também; nos novos, a instrução é o
 * roteiro do produto, cheio de "nunca cite valor", e não conta.
 */
export function aplicarFreios(
  texto: string, r: Pick<EntradaDoPrompt, 'proibido' | 'tamanho_maximo' | 'canal'>
    & Partial<Pick<EntradaDoPrompt, 'instrucoes' | 'contexto' | 'objetivo' | 'metadados'>>,
): Freio {
  const limpo = normalizarSaida(texto, r.canal);
  // A marca escrita sem colchetes ("ESCALAR") também é marca: sairia para a pessoa como texto.
  const soPalavra = limpo.replace(/[^a-z]/gi, '').toUpperCase();
  if (limpo.includes(MARCA_SAIR) || soPalavra === 'SAIR') {
    return { situacao: 'escalar', motivo: 'a pessoa pediu para não receber mais mensagens com palavras que a '
      + 'blacklist não reconhece: suprima o contato em Supressão e acrescente o termo em Configurações ▸ Blacklist' };
  }
  if (limpo.includes(MARCA_ESCALAR) || soPalavra === 'ESCALAR') {
    return { situacao: 'escalar', motivo: 'o agente reconheceu um caso para uma pessoa' };
  }
  if (!limpo) return { situacao: 'bloqueado', motivo: 'o modelo devolveu um texto vazio' };
  const limite = limiteEfetivo(r.canal, r.tamanho_maximo);
  if (limpo.length > limite) {
    return { situacao: 'bloqueado', motivo: `passou do tamanho máximo (${limpo.length} de ${limite} caracteres)` };
  }
  const normal = semAcento(limpo);
  if (CONFIRMA_SAIDA.test(normal)) {
    return { situacao: 'escalar', motivo: 'o agente ia confirmar uma remoção que ninguém gravou: se a pessoa pediu '
      + 'para sair, suprima o contato em Supressão e acrescente o termo em Configurações ▸ Blacklist' };
  }
  const proibida = r.proibido.find((p) => p.trim() && normal.includes(semAcento(p.trim())));
  if (proibida) return { situacao: 'bloqueado', motivo: `contém uma expressão proibida: "${proibida}"` };
  const fs = frases(normal);
  if (fs.some((f) => DADO_SENSIVEL.test(f) && PEDIDO.test(f) && !NEGACAO.test(f))) {
    return { situacao: 'bloqueado', motivo: 'pede dado sensível (CPF, RG, senha, cartão ou dados bancários)' };
  }
  if (fs.some((f) => f.endsWith('?') && SAUDE_DA_PESSOA.test(f) && !FALA_DO_PLANO.test(f))) {
    return { situacao: 'bloqueado', motivo: 'pergunta sobre a saúde da pessoa — isso é conversa da equipe com ela, não do agente' };
  }
  const fonte = semAcento([
    r.contexto ?? '',
    ...(r.objetivo ? [] : [r.instrucoes ?? '']),
    ...Object.values(r.metadados ?? {}).filter((v): v is string => typeof v === 'string'),
  ].join('\n'));
  const escritos = numerosEscritos(fonte);
  const inventado = valoresEmDinheiro(normal).find((v) => !escritos.has(v));
  if (inventado !== undefined) {
    return { situacao: 'bloqueado', motivo: `cita um valor (${inventado.toLocaleString('pt-BR')}) que não está no que o cliente escreveu sobre a oferta` };
  }
  const linhasAfirmadas = fonte.split('\n').filter((l) => !NEGACAO.test(l)).join('\n');
  const carencia = [...normal.matchAll(PROMESSA_DE_CARENCIA)].map((m) => m[0])
    .find((frase) => !linhasAfirmadas.includes(frase));
  if (carencia) {
    return { situacao: 'bloqueado', motivo: `promete carência ("${carencia}") que não está no que o cliente escreveu sobre a oferta` };
  }
  return { situacao: 'pronto', texto: limpo };
}

/** Tokens para o modelo: folga para o texto caber, sem deixar divagar — com piso, para o
 *  modelo de raciocínio não gastar tudo pensando e devolver vazio. */
export function tokensParaCompor(limite: number): number {
  return Math.max(400, Math.min(2000, Math.ceil(limite / 2) + 200));
}
