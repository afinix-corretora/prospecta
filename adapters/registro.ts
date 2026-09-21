// Registro de adapters.
//
// O motor conhece canal e provedor; não conhece classe. Canal novo entra aqui
// e em lugar nenhum mais — é isto que a convenção "canal novo = classe nova,
// zero mudança no motor" quer dizer na prática.

import type { Buscador, Canal, ChannelAdapter } from './tipos.ts';
import { WhatsAppGupshupAdapter } from './whatsapp-gupshup.ts';
import { WhatsAppUazapiAdapter } from './whatsapp-uazapi.ts';
import { WhatsAppEvolutionAdapter } from './whatsapp-evolution.ts';
import { WhatsAppMetaAdapter } from './whatsapp-meta.ts';
import { SmsComteleAdapter } from './sms-comtele.ts';
import { EmailResendAdapter } from './email-resend.ts';

export type Provedor =
  | 'gupshup' | 'meta_cloud' | 'uazapi' | 'evolution' | 'comtele' | 'resend';

export function criarAdapter(provedor: string, buscar: Buscador = fetch): ChannelAdapter {
  switch (provedor) {
    case 'gupshup':    return new WhatsAppGupshupAdapter(buscar);
    case 'uazapi':     return new WhatsAppUazapiAdapter(buscar);
    case 'evolution':  return new WhatsAppEvolutionAdapter(buscar);
    case 'meta_cloud': return new WhatsAppMetaAdapter(buscar);
    case 'comtele':    return new SmsComteleAdapter(buscar);
    case 'resend':     return new EmailResendAdapter(buscar);
    default:
      throw new Error(`provedor sem adapter: ${provedor}`);
  }
}

/**
 * Provedores implementados por canal. Os quatro canais do enum existem no
 * schema; o Instagram ainda não tem adapter, e dizer isso em voz alta é melhor
 * do que a chamada falhar em produção com "provedor sem adapter".
 *
 * `smtp` está no catálogo e não está aqui: é provedor sem adapter de propósito
 * (D30), porque socket não cabe num diretório que só usa `fetch`.
 */
export const PROVEDORES_POR_CANAL: Record<Canal, Provedor[]> = {
  whatsapp: ['gupshup', 'meta_cloud', 'uazapi', 'evolution'],
  sms: ['comtele'],
  email: ['resend'],
  instagram: [],
};

export function canalTemAdapter(canal: Canal): boolean {
  return PROVEDORES_POR_CANAL[canal].length > 0;
}
