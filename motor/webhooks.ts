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
  // `senderId` é obrigatório, não opcional. O D24 diz "nunca receber webhook
  // num endpoint que não identifique o chip", e o chip é quem diz o tenant
  // nas DUAS vias de casamento — por id do provedor e por número (D38). Como
  // obrigatório, quem cobra a regra é o compilador; como opcional, o efeito
  // de esquecê-lo era casar com a mensagem de outro cliente.
  opcoes: { senderId: string; buscar?: Buscador; criar?: typeof criarAdapter },
): Promise<ResumoWebhook> {
  // O tipo já exige, mas o Deno da edge function roda JavaScript: um chamador
  // sem tipos passaria `{}` e cairia no casamento entre clientes. Falhar alto
  // é o certo — o endpoint resolve o chip antes de chegar aqui (D24), então
  // chegar sem ele é bug, não caso de borda.
  if (!opcoes?.senderId) {
    throw new Error('webhook sem chip: o chip é quem diz o tenant (D24, D38)');
  }

  const criar = opcoes.criar ?? criarAdapter;
  const eventos = criar(provedor, opcoes.buscar).normalizeWebhook(corpo);

  let gravados = 0;
  for (const e of eventos) {
    let ok = false;

    // As duas vias exigem o chip pela mesma razão: ele é quem diz o tenant.
    // A de cima passou tempo sem exigir, e casava `provider_message_id` entre
    // clientes (D38).
    if (e.providerMessageId) {
      ok = await banco.registrarEventoProvedor(
        opcoes.senderId, e.providerMessageId, e.tipo, e.ocorridoEm, e.payload,
      );
    } else if (e.deNumero) {
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
