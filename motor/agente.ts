// O agente compõe (D66) e, desde o D69, responde sozinho.
//
// Para cada resposta que espera rascunho, uma de sete saídas, e só uma delas
// tem texto:
//
//   recusa          a blacklist do cliente diz que é recusa: não se insiste
//   limite          a conversa já passou de `limite_trocas`, ou o cliente já
//                   passou do teto diário de composições: é hora de gente
//   sem_credencial  o agente não tem com que compor, e isso é dito
//   escalar        o modelo reconheceu um caso de `escalar_quando`
//   bloqueado       o texto saiu, e um freio o barrou
//   erro            o provedor recusou de vez (chave, modelo, recusa)
//   pronto          o texto, que passou por todos os freios
//
// O pronto de agente autônomo vai para a fila do motor (`enfileirarResposta`),
// e é o banco quem decide se sai: supressão, janela de 24h, a conta que
// conversa, a quota. O que ele não manda volta para uma pessoa com o motivo.
// O de agente não autônomo fica para uma pessoa, como no D66.
//
// Os freios moram em código, e não só na instrução: o modelo pode
// desobedecer a instrução, o freio não. A instrução diz ao modelo o que não
// fazer; o freio confere que ele não fez. Desde o D76 os dois — o pedido e o
// freio — estão em `adapters/prompt-do-agente.ts`, com o que muda por canal.
//
// Quem está suprimido nem chega: `fila_do_agente` já o exclui.

import type { Buscador } from '../adapters/tipos.ts';
import type { ModeloIA } from '../adapters/ia.ts';
import { criarIa } from '../adapters/ia.ts';
import { aplicarFreios, ehCanal, montarPedido, tokensParaCompor } from '../adapters/prompt-do-agente.ts';
import type { BancoAgente, Envio, RespostaParaRascunhar, Situacao } from './porta-agente.ts';

// O prompt e os freios moram em `adapters/prompt-do-agente.ts` desde o D76,
// para a prévia da tela montar o MESMO pedido que o worker manda.
export {
  aplicarFreios, MARCA_ESCALAR, MARCA_SAIR, montarPedido, semAcento,
} from '../adapters/prompt-do-agente.ts';
export type { Freio, Pedido } from '../adapters/prompt-do-agente.ts';

export interface ResumoRascunhos {
  readonly lidas: number;
  readonly porSituacao: Partial<Record<Situacao, number>>;
  readonly adiadas: number;
  /** D69: para onde foi cada texto pronto. */
  readonly envio: Partial<Record<Envio, number>>;
  /** D69: prontos que não puderam ser enfileirados (erro do banco): ficam com uma pessoa. */
  readonly falhasNoEnvio: number;
}

export interface OpcoesAgente {
  readonly buscar?: Buscador;
  readonly criar?: (provedor: string, buscar?: Buscador) => ModeloIA;
  /** O modo da passada. Em `simulado` a resposta do agente nasce simulada, como a cadência (D36). */
  readonly modo?: 'simulado' | 'real';
}

export async function rascunharRespostas(
  banco: BancoAgente, limite: number, opcoes: OpcoesAgente = {},
): Promise<ResumoRascunhos> {
  const criar = opcoes.criar ?? criarIa;
  const modo = opcoes.modo ?? 'simulado';
  const respostas = await banco.respostasParaRascunhar(limite);
  const porSituacao: Partial<Record<Situacao, number>> = {};
  const envio: Partial<Record<Envio, number>> = {};
  let adiadas = 0;
  let falhasNoEnvio = 0;
  // O teto vem do banco como fotografia do começo da passada; o que esta
  // passada compõe soma por cima, senão um lote grande passaria do teto.
  const compostasAgora = new Map<string, number>();

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
      await registrar(r, 'sem_credencial', null,
        `nem a campanha nem o agente ${r.agente_nome} têm conta de IA escolhida`);
      continue;
    }
    if (!r.provedor_compoe) {
      await registrar(r, 'sem_credencial', null,
        `a conta de IA escolhida está desligada, ou ${r.provedor} ainda não tem adapter de rascunho`);
      continue;
    }
    // (d) O teto do cliente. Custa zero conferir, e passar dele é o modelo
    // sendo chamado sem ninguém ter decidido gastar.
    const jaCompostas = r.composicoes_hoje + (compostasAgora.get(r.tenant_id) ?? 0);
    if (jaCompostas >= r.teto) {
      await registrar(r, 'limite', null,
        `o cliente já fez ${jaCompostas} composições nas últimas 24h, e o teto é ${r.teto}: é hora de uma pessoa`);
      continue;
    }
    // Canal sem comportamento declarado não compõe: o freio de tamanho não
    // teria limite, e o texto passaria de qualquer tamanho (D76). Não custa
    // modelo, e não derruba o resto do lote.
    if (!ehCanal(r.canal)) {
      await registrar(r, 'bloqueado', null, `o canal ${r.canal} não tem comportamento declarado para o agente`);
      continue;
    }
    compostasAgora.set(r.tenant_id, (compostasAgora.get(r.tenant_id) ?? 0) + 1);

    let resultado;
    try {
      const credenciais = await banco.credenciaisDaIa(r.tenant_id, r.credencial_id);
      const pedido = montarPedido(r);
      resultado = await criar(r.provedor, opcoes.buscar).compor({
        credenciais, modelo: r.modelo, sistema: pedido.sistema, mensagem: pedido.mensagem,
        maxTokens: tokensParaCompor(pedido.limite),
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
    if (freio.situacao !== 'pronto') {
      await registrar(r, freio.situacao, null, freio.motivo);
      continue;
    }
    await registrar(r, 'pronto', freio.texto, null);

    // D69: o texto passou por todos os freios. Agente autônomo manda; o banco
    // tem a última palavra sobre o como.
    if (!r.autonomo) {
      envio.pessoa = (envio.pessoa ?? 0) + 1;
      continue;
    }
    try {
      const destino = await banco.enfileirarResposta(r.message_event_id, modo);
      envio[destino] = (envio[destino] ?? 0) + 1;
    } catch (e) {
      // O rascunho já está gravado e continua visível na tela de Respostas:
      // a falha deixa o texto com uma pessoa, e é contada para a passada dizer.
      console.error('[agente] enfileirar', r.message_event_id, e);
      falhasNoEnvio += 1;
    }
  }

  return { lidas: respostas.length, porSituacao, adiadas, envio, falhasNoEnvio };
}
