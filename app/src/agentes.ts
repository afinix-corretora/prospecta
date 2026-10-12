/**
 * O construtor de agentes (D76), sem tela: o que muda quando a pessoa troca a
 * persona ou o objetivo, o que falta para salvar, onde cada agente responde e
 * a conversa de exemplo da prévia.
 *
 * Puro de propósito, como `assistente.ts`: a regra precisa de teste, e a tela
 * só desenha. O catálogo e o prompt vêm de `@adapters/prompt-do-agente.ts` —
 * o MESMO módulo que o worker usa, para a prévia nunca discordar do envio.
 */

import {
  CANAIS, CONTEXTO_MINIMO, objetivo as objetivoDe, persona as personaDe, PERSONAS,
} from '../../adapters/prompt-do-agente.ts';
import type { EntradaDoPrompt } from '../../adapters/prompt-do-agente.ts';

export const CANAIS_DO_AGENTE = ['whatsapp', 'email', 'sms', 'instagram'] as const;
export type CanalDoAgente = typeof CANAIS_DO_AGENTE[number];

/** O que o construtor edita. Números como texto: é o que o campo devolve. */
export interface Rascunho {
  nome: string;
  persona: string | null;
  objetivo: string | null;
  papel: string;
  descricao: string;
  tom: string;
  instrucoes: string;
  contexto: string;
  escalar_quando: string;
  limite_trocas: string;
  /** Em branco = o do canal. */
  tamanho_maximo: string;
  proibido: string;
  ai_credential_id: string;
  autonomo: boolean;
}

/**
 * Um agente novo. A persona vem marcada (Consultiva); o objetivo só quando quem
 * chama sabe qual é — vindo de uma campanha, por exemplo. Vindo de
 * Configurações, a pessoa escolhe: objetivo pré-marcado é escolha que ninguém
 * fez, e o de Resgate numa lista fria inventa um relacionamento.
 */
export function rascunhoNovo(empresa: string, objetivo: string | null = null, persona = 'consultiva'): Rascunho {
  const p = personaDe(persona) ?? PERSONAS[0]!;
  const o = objetivoDe(objetivo);
  return {
    nome: '', persona: p.slug, objetivo: o?.slug ?? null, papel: o?.papel ?? '', descricao: o?.resumo ?? '',
    tom: p.tom, instrucoes: o?.roteiro ?? '',
    contexto: empresa.trim() ? `Falamos em nome de ${empresa.trim()}.` : '',
    escalar_quando: o?.escalar_quando ?? '', limite_trocas: String(o?.limite_trocas ?? 6),
    tamanho_maximo: '', proibido: '', ai_credential_id: '', autonomo: true,
  };
}

/** Os agentes de antes do D76 e os novos, no formato do construtor. */
export function rascunhoDe(a: {
  nome: string; persona: string | null; objetivo: string | null; papel: string; descricao: string; tom: string;
  instrucoes: string; contexto: string; escalar_quando: string; limite_trocas: number;
  tamanho_maximo: number | null; proibido: string[]; ai_credential_id: string | null; autonomo: boolean;
}): Rascunho {
  return {
    nome: a.nome, persona: a.persona, objetivo: a.objetivo, papel: a.papel, descricao: a.descricao, tom: a.tom,
    instrucoes: a.instrucoes, contexto: a.contexto, escalar_quando: a.escalar_quando,
    limite_trocas: String(a.limite_trocas), tamanho_maximo: a.tamanho_maximo == null ? '' : String(a.tamanho_maximo),
    proibido: a.proibido.join('\n'), ai_credential_id: a.ai_credential_id ?? '', autonomo: a.autonomo,
  };
}

/** O que a troca substituiu, para a tela oferecer "desfazer" em vez de perguntar antes. */
export interface Troca {
  readonly rascunho: Rascunho;
  /** Campos que a pessoa tinha mudado e que a troca substituiu. */
  readonly perdidos: readonly (keyof Rascunho)[];
}

/** Troca a persona: só o "como fala" muda. */
export function trocarPersona(r: Rascunho, slug: string): Troca {
  const nova = personaDe(slug);
  if (!nova) return { rascunho: r, perdidos: [] };
  const antiga = personaDe(r.persona);
  const editado = r.tom.trim() !== '' && r.tom !== antiga?.tom;
  return { rascunho: { ...r, persona: nova.slug, tom: nova.tom }, perdidos: editado ? ['tom'] : [] };
}

/** Troca o objetivo: o que faz, o papel, quando passa para uma pessoa e o limite de trocas. */
export function trocarObjetivo(r: Rascunho, slug: string): Troca {
  const novo = objetivoDe(slug);
  if (!novo) return { rascunho: r, perdidos: [] };
  const antigo = objetivoDe(r.objetivo);
  const perdidos: (keyof Rascunho)[] = [];
  if (r.instrucoes.trim() && r.instrucoes !== antigo?.roteiro) perdidos.push('instrucoes');
  if (r.escalar_quando.trim() && r.escalar_quando !== antigo?.escalar_quando) perdidos.push('escalar_quando');
  return {
    rascunho: {
      ...r, objetivo: novo.slug, papel: novo.papel, descricao: novo.resumo, instrucoes: novo.roteiro,
      escalar_quando: novo.escalar_quando, limite_trocas: String(novo.limite_trocas),
    },
    perdidos,
  };
}

/** O que impede salvar, dito em português. Vazio = pode salvar. */
export function oQueFalta(r: Rascunho, opcoes: { novo: boolean }): string[] {
  const falta: string[] = [];
  if (!r.nome.trim()) falta.push('o nome com que ele se apresenta');
  if (opcoes.novo && (!r.persona || !r.objetivo)) falta.push('a persona e o objetivo');
  if (r.objetivo && r.contexto.trim().length < CONTEXTO_MINIMO) {
    falta.push(`"Sobre a empresa e a oferta" com pelo menos ${CONTEXTO_MINIMO} caracteres — sem isso ele não sabe em nome de quem fala`);
  }
  if (r.instrucoes.trim().length < 120) falta.push('"O que ele faz" com pelo menos 120 caracteres');
  const limite = Number(r.limite_trocas);
  if (!Number.isInteger(limite) || limite < 1 || limite > 100) falta.push('o limite de trocas, entre 1 e 100');
  if (r.tamanho_maximo.trim()) {
    const t = Number(r.tamanho_maximo);
    if (!Number.isInteger(t) || t < 80 || t > 4000) falta.push('o tamanho máximo, entre 80 e 4000 (ou em branco)');
  }
  return falta;
}

/** O rascunho no formato que o banco grava. */
export function camposParaGravar(r: Rascunho) {
  return {
    nome: r.nome.trim(), persona: r.persona, objetivo: r.objetivo, papel: r.papel.trim(),
    descricao: r.descricao.trim(), tom: r.tom.trim(), instrucoes: r.instrucoes.trim(), contexto: r.contexto.trim(),
    escalar_quando: r.escalar_quando.trim(), limite_trocas: Number(r.limite_trocas),
    tamanho_maximo: r.tamanho_maximo.trim() ? Number(r.tamanho_maximo) : null,
    proibido: r.proibido.split('\n').map((x) => x.trim()).filter(Boolean),
    ai_credential_id: r.ai_credential_id || null, autonomo: r.autonomo,
  };
}

/** Os canais em que um agente PODE responder: todos, ou só o dele (agente de antes do D76). */
export function canaisQueServe(a: { canal: string | null }): CanalDoAgente[] {
  return a.canal ? CANAIS_DO_AGENTE.filter((c) => c === a.canal) : [...CANAIS_DO_AGENTE];
}

/** "Consultiva · Resgate", ou o que dá para dizer de um agente de antes do D76. */
export function rotulo(a: { persona: string | null; objetivo: string | null; papel: string; canal: string | null }): string {
  const p = personaDe(a.persona)?.nome;
  const o = objetivoDe(a.objetivo)?.nome;
  if (p || o) return [p, o].filter(Boolean).join(' · ');
  return a.canal ? `${a.papel} · criado antes do construtor` : a.papel;
}

/** Uma troca plausível para a prévia mostrar o prompt inteiro, por objetivo. */
export function conversaDeExemplo(objetivo: string | null): EntradaDoPrompt['historico'] {
  const nos: Record<string, string> = {
    prospeccao_fria: 'Oi, Marina! Sou da equipe comercial. Vocês já têm plano de saúde para os funcionários?',
    resgate: 'Oi, Marina! Conversamos há alguns meses sobre o seu plano. Ainda faz sentido retomar?',
    follow_up: 'Oi, Marina! Conseguiu ver a proposta que te mandamos na semana passada?',
    renovacao: 'Oi, Marina! O seu contrato vence no mês que vem. Podemos revisar antes?',
    agendamento: 'Oi, Marina! Quer conversar com um especialista sobre o plano?',
    atendimento: 'Oi, Marina! Recebemos a sua mensagem. Como podemos ajudar?',
    pos_venda: 'Oi, Marina! Faz um mês que você é nossa cliente. Como está sendo?',
  };
  return [
    { de: 'nos', texto: nos[objetivo ?? ''] ?? nos.resgate! },
    { de: 'pessoa', texto: 'Tenho interesse, como funciona?' },
  ];
}

/** O que a prévia monta: o rascunho como o worker o leria, numa conversa de exemplo. */
export function entradaDaPrevia(r: Rascunho, canal: CanalDoAgente): EntradaDoPrompt {
  const c = camposParaGravar(r);
  const historico = conversaDeExemplo(r.objetivo);
  return {
    canal, texto: historico[historico.length - 1]!.texto,
    agente_nome: c.nome || 'Ana', papel: c.papel, descricao: c.descricao,
    tom: c.tom, instrucoes: c.instrucoes, contexto: c.contexto, objetivo: c.objetivo,
    escalar_quando: c.escalar_quando, proibido: c.proibido,
    tamanho_maximo: Number.isFinite(c.tamanho_maximo) ? c.tamanho_maximo : null,
    contato_nome: 'Marina', metadados: { cidade: 'São José do Rio Preto' }, campanha: 'Campanha de exemplo',
    historico,
  };
}

/** O que a plataforma acrescenta em cada canal, em português, para a tela listar. */
export function oQueMudaNoCanal(canal: CanalDoAgente, tamanho: number | null) {
  const c = CANAIS[canal];
  const limite = tamanho && tamanho > 0 ? Math.min(c.limite, tamanho) : c.limite;
  return { nome: c.nome, limite, regras: c.regras, recebeResposta: c.recebeResposta, porQueNao: c.porQueNao };
}
