// Verificar a conexão de uma conta: o botão "testar" da tela (D62).
//
// Quem verifica é o worker, não a tela. A tela não tem o segredo e não deve
// ter — é por isso que existe o Vault. O caminho é: a conta precisa ser
// VISÍVEL para quem pediu (o RLS de `sender_accounts` decide, pelo JWT dele),
// o segredo é lido com a chave do serviço, o `checkHealth` do adapter pergunta
// ao provedor, e o resultado é gravado na conta para a tela ler.
//
// O que este arquivo NÃO faz: tirar a conta do pool. Uma verificação que
// falhou é informação para quem configura; quem tira conta do pool é o
// circuito, com base em envio de verdade. Duas fontes de "esta conta está
// fora" discordariam entre si — o D40 com outro nome.

import type { Buscador, Saude } from '../adapters/tipos.ts';
import { criarAdapter } from '../adapters/registro.ts';

export interface PortaVerificacao {
  /**
   * A conta como QUEM PEDIU a enxerga. `null` quando ele não alcança: conta de
   * outro cliente e conta inexistente dão a mesma resposta, de propósito.
   */
  contaVisivel(senderId: string): Promise<{ provedor: string; removida: boolean } | null>;
  /** O blob de credenciais do Vault, ou `null` quando a conta não tem. */
  segredo(senderId: string): Promise<string | null>;
  registrar(senderId: string, ok: boolean, detalhe: string): Promise<void>;
}

export type ResultadoVerificacao =
  | { readonly encontrada: false }
  | { readonly encontrada: true; readonly saude: Saude };

export async function verificarRemetente(
  porta: PortaVerificacao,
  senderId: string,
  opcoes: { buscar?: Buscador; criar?: typeof criarAdapter } = {},
): Promise<ResultadoVerificacao> {
  const conta = await porta.contaVisivel(senderId);
  if (!conta) return { encontrada: false };

  // Conta removida não é perguntada ao provedor: ninguém vai mandar por ela,
  // e gravar "ok" numa conta arquivada a faria parecer pronta na tela.
  if (conta.removida) {
    return { encontrada: true, saude: { ok: false, detalhe: 'conta removida' } };
  }

  const saude = await perguntar(porta, senderId, conta.provedor, opcoes);
  await porta.registrar(senderId, saude.ok, saude.detalhe);
  return { encontrada: true, saude };
}

async function perguntar(
  porta: PortaVerificacao,
  senderId: string,
  provedor: string,
  opcoes: { buscar?: Buscador; criar?: typeof criarAdapter },
): Promise<Saude> {
  let adapter;
  try {
    adapter = (opcoes.criar ?? criarAdapter)(provedor, opcoes.buscar);
  } catch {
    // Provedor sem adapter (o `smtp`, por exemplo): não há a quem perguntar,
    // e dizer isso é melhor do que "erro desconhecido".
    return { ok: false, detalhe: `${provedor} não tem adapter: a conta não envia` };
  }

  const bruto = await porta.segredo(senderId);
  if (!bruto) return { ok: false, detalhe: 'sem credencial guardada no Vault' };

  let credenciais: Record<string, string>;
  try {
    credenciais = JSON.parse(bruto) as Record<string, string>;
  } catch {
    return { ok: false, detalhe: 'credencial guardada ilegível — salve de novo pela tela' };
  }

  try {
    return await adapter.checkHealth(credenciais);
  } catch (e) {
    // `checkHealth` já devolve falha em vez de lançar; isto é a rede de baixo,
    // para uma exceção de adapter não virar 500 sem nada gravado.
    return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
  }
}
