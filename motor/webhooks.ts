// Recepção de webhook de provedor.
//
// O adapter normaliza (função pura, sem I/O); aqui os eventos normalizados
// viram linhas em message_events. O descarte de eco acontece nos dois lados:
// o adapter joga fora o que a própria instância mandou, e o banco joga fora o
// que vier marcado com a nossa autoria.

import type { Banco } from './porta.ts';
import type { Buscador } from '../adapters/tipos.ts';
import { criarAdapter } from '../adapters/registro.ts';

export interface ResumoWebhook {
  readonly normalizados: number;
  readonly gravados: number;
  readonly descartados: number;
}

export async function receberWebhook(
  banco: Banco,
  provedor: string,
  corpo: unknown,
  opcoes: { buscar?: Buscador; criar?: typeof criarAdapter; senderId?: string } = {},
): Promise<ResumoWebhook> {
  const criar = opcoes.criar ?? criarAdapter;
  const eventos = criar(provedor, opcoes.buscar).normalizeWebhook(corpo);

  let gravados = 0;
  for (const e of eventos) {
    let ok = false;

    if (e.providerMessageId) {
      ok = await banco.registrarEventoProvedor(
        e.providerMessageId, e.tipo, e.ocorridoEm, e.payload,
      );
    } else if (e.deNumero && opcoes.senderId) {
      // Sem chip não há tenant, e sem tenant casar pelo número escolheria a
      // mensagem de outro cliente. Melhor descartar do que acertar o errado.
      ok = await banco.registrarRespostaPorNumero(
        opcoes.senderId, e.deNumero, e.ocorridoEm, e.payload,
      );
    }

    if (ok) gravados += 1;
  }

  return {
    normalizados: eventos.length,
    gravados,
    descartados: eventos.length - gravados,
  };
}
