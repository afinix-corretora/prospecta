// O agente compõe; uma pessoa decide (D66).
//
// Para cada resposta que espera rascunho, uma de sete saídas, e só uma delas
// tem texto:
//
//   recusa          a blacklist do cliente diz que é recusa: não se insiste
//   limite          a conversa já passou de `limite_trocas`: é hora de gente
//   sem_credencial  o agente não tem com que compor, e isso é dito
//   escalar        o modelo reconheceu um caso de `escalar_quando`
//   bloqueado       o texto saiu, e um freio o barrou
//   erro            o provedor recusou de vez (chave, modelo, recusa)
//   pronto          o rascunho, para uma pessoa ler e mandar
//
// Os freios moram AQUI, em código, e não só na instrução: o modelo pode
// desobedecer a instrução, o freio não. A instrução diz ao modelo o que não
// fazer; o freio confere que ele não fez.
//
// Quem está suprimido nem chega: `respostas_para_rascunhar` já o exclui.

import type { Buscador } from '../adapters/tipos.ts';
import type { ModeloIA } from '../adapters/ia.ts';
import { criarIa } from '../adapters/ia.ts';
import type { BancoAgente, RespostaParaRascunhar, Situacao } from './porta-agente.ts';

/** A palavra que o modelo devolve, sozinha, quando o caso é de uma pessoa. */
export const MARCA_ESCALAR = '[ESCALAR]';

/** Comparação sem acento e sem caixa: "Não posso" e "nao posso" são a mesma frase proibida. */
export function semAcento(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

/**
 * Pedidos de dado que nenhum rascunho faz, seja qual for a instrução do
 * cliente. Pedir CPF ou cartão por mensagem é o golpe que o contato aprendeu
 * a temer — e o primeiro passo para o chip ser denunciado.
 */
const DADO_SENSIVEL = /\b(cpf|senha|cartao de credito|numero do cartao|codigo de seguranca|cvv)\b/;

export interface Pedido {
  readonly sistema: string;
  readonly mensagem: string;
}

export function montarPedido(r: RespostaParaRascunhar): Pedido {
  const variaveis = Object.entries(r.metadados ?? {})
    .filter(([, v]) => typeof v === 'string' && v.trim())
    .map(([k, v]) => `- ${k}: ${v as string}`);

  const sistema = [
    `Você é ${r.agente_nome}, ${r.papel}. ${r.descricao}`.trim(),
    '',
    'INSTRUÇÕES DO CLIENTE',
    r.instrucoes.trim(),
    '',
    'REGRAS QUE VALEM SEMPRE',
    `- Escreva só a próxima mensagem para a pessoa, em português do Brasil, com no máximo ${r.tamanho_maximo} caracteres.`,
    '- Não invente preço, cobertura, prazo, carência nem condição que não esteja nas instruções.',
    '- Não peça CPF, senha nem dado de cartão.',
    '- Não diga que é uma pessoa se perguntarem; diga que é o assistente da equipe.',
    `- Se a mensagem da pessoa se encaixar em: "${r.escalar_quando.trim()}", responda exatamente ${MARCA_ESCALAR} e nada mais.`,
    ...(r.proibido.length ? ['- Nunca use estas expressões: ' + r.proibido.map((p) => `"${p}"`).join(', ') + '.'] : []),
  ].join('\n');

  const conversa = r.historico.map((h) => `${h.de === 'nos' ? 'Nós' : 'Pessoa'}: ${h.texto}`);
  const mensagem = [
    `Campanha: ${r.campanha}. Canal: ${r.canal}.`,
    `Contato: ${r.contato_nome ?? '(sem nome)'}.`,
    ...(variaveis.length ? ['O que sabemos dele:', ...variaveis] : []),
    '',
    'Conversa até aqui, da mais antiga para a mais recente:',
    ...(conversa.length ? conversa : [`Pessoa: ${r.texto}`]),
    '',
    'Escreva a próxima mensagem.',
  ].join('\n');

  return { sistema, mensagem };
}

export type Freio =
  | { readonly situacao: 'pronto'; readonly texto: string }
  | { readonly situacao: 'escalar' | 'bloqueado'; readonly motivo: string };

/** O que vale conferir no texto que o modelo devolveu. */
export function aplicarFreios(texto: string, r: Pick<RespostaParaRascunhar, 'proibido' | 'tamanho_maximo'>): Freio {
  const limpo = texto.trim();
  if (limpo.includes(MARCA_ESCALAR)) {
    return { situacao: 'escalar', motivo: 'o agente reconheceu um caso para uma pessoa' };
  }
  if (limpo.length > r.tamanho_maximo) {
    return { situacao: 'bloqueado', motivo: `passou do tamanho máximo (${limpo.length} de ${r.tamanho_maximo} caracteres)` };
  }
  const normal = semAcento(limpo);
  const proibida = r.proibido.find((p) => p.trim() && normal.includes(semAcento(p.trim())));
  if (proibida) return { situacao: 'bloqueado', motivo: `contém uma expressão proibida: "${proibida}"` };
  if (DADO_SENSIVEL.test(normal)) return { situacao: 'bloqueado', motivo: 'pede dado sensível (CPF, senha ou cartão)' };
  return { situacao: 'pronto', texto: limpo };
}

export interface ResumoRascunhos {
  readonly lidas: number;
  readonly porSituacao: Partial<Record<Situacao, number>>;
  readonly adiadas: number;
}

export interface OpcoesAgente {
  readonly buscar?: Buscador;
  readonly criar?: (provedor: string, buscar?: Buscador) => ModeloIA;
}

export async function rascunharRespostas(
  banco: BancoAgente, limite: number, opcoes: OpcoesAgente = {},
): Promise<ResumoRascunhos> {
  const criar = opcoes.criar ?? criarIa;
  const respostas = await banco.respostasParaRascunhar(limite);
  const porSituacao: Partial<Record<Situacao, number>> = {};
  let adiadas = 0;

  const registrar = async (r: RespostaParaRascunhar, s: Situacao, texto: string | null, motivo: string | null) => {
    await banco.registrarRascunho(r.message_event_id, r.agent_id, s, texto, motivo, r.modelo);
    porSituacao[s] = (porSituacao[s] ?? 0) + 1;
  };

  for (const r of respostas) {
    // Os três primeiros não chamam modelo nenhum: custam zero e não dependem
    // de o provedor obedecer.
    if (r.regra === 'recusa') {
      await registrar(r, 'recusa', null, 'a blacklist do cliente lê esta resposta como recusa da oferta');
      continue;
    }
    if (r.rascunhos_anteriores >= r.limite_trocas) {
      await registrar(r, 'limite', null,
        `a conversa já teve ${r.rascunhos_anteriores} rascunhos, e o limite do agente é ${r.limite_trocas}: é hora de uma pessoa`);
      continue;
    }
    if (!r.credencial_id || !r.provedor || !r.modelo) {
      await registrar(r, 'sem_credencial', null, `o agente ${r.agente_nome} não tem credencial de IA escolhida`);
      continue;
    }
    if (!r.provedor_compoe) {
      await registrar(r, 'sem_credencial', null,
        `a credencial do agente está desligada, ou ${r.provedor} ainda não tem adapter de rascunho`);
      continue;
    }

    let resultado;
    try {
      const credenciais = await banco.credenciaisDaIa(r.credencial_id);
      const pedido = montarPedido(r);
      resultado = await criar(r.provedor, opcoes.buscar).compor({
        credenciais, modelo: r.modelo, sistema: pedido.sistema, mensagem: pedido.mensagem,
        // Folga para o texto em português caber, sem deixar o modelo divagar.
        maxTokens: Math.min(2000, Math.ceil(r.tamanho_maximo / 2) + 200),
      });
    } catch (e) {
      resultado = { ok: false as const, erro: e instanceof Error ? e.message : String(e), definitivo: false };
    }

    if (!resultado.ok) {
      // Transitório não vira linha: a próxima passada tenta de novo. Só o que
      // não melhora sozinho fica gravado, com o motivo para a tela.
      if (resultado.definitivo) await registrar(r, 'erro', null, resultado.erro);
      else adiadas += 1;
      continue;
    }

    const freio = aplicarFreios(resultado.texto, r);
    if (freio.situacao === 'pronto') await registrar(r, 'pronto', freio.texto, null);
    else await registrar(r, freio.situacao, null, freio.motivo);
  }

  return { lidas: respostas.length, porSituacao, adiadas };
}
