// Registro de adapters.
//
// O motor conhece canal e provedor; não conhece classe. Canal novo entra aqui
// e em lugar nenhum mais — é isto que a convenção "canal novo = classe nova,
// zero mudança no motor" quer dizer na prática.

import type { Buscador, Canal, ChannelAdapter } from './tipos.ts';
import { WhatsAppGupshupAdapter } from './whatsapp-gupshup.ts';
import { WhatsAppEvolutionAdapter } from './whatsapp-evolution.ts';
import { WhatsAppMetaAdapter } from './whatsapp-meta.ts';
import { SmsComteleAdapter } from './sms-comtele.ts';

export type Provedor = 'gupshup' | 'evolution' | 'meta_cloud' | 'comtele';

export function criarAdapter(provedor: string, buscar: Buscador = fetch): ChannelAdapter {
  switch (provedor) {
    case 'gupshup':    return new WhatsAppGupshupAdapter(buscar);
    case 'evolution':  return new WhatsAppEvolutionAdapter(buscar);
    case 'meta_cloud': return new WhatsAppMetaAdapter(buscar);
    case 'comtele':    return new SmsComteleAdapter(buscar);
    default:
      throw new Error(`provedor sem adapter: ${provedor}`);
  }
}

/**
 * Provedores implementados por canal. Os quatro canais do enum existem no
 * schema; e-mail e Instagram ainda não têm adapter, e dizer isso em voz alta
 * é melhor do que a chamada falhar em produção com "provedor sem adapter".
 */
export const PROVEDORES_POR_CANAL: Record<Canal, Provedor[]> = {
  whatsapp: ['gupshup', 'meta_cloud', 'evolution'],
  sms: ['comtele'],
  email: [],
  instagram: [],
};

export function canalTemAdapter(canal: Canal): boolean {
  return PROVEDORES_POR_CANAL[canal].length > 0;
}
