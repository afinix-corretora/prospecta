// Apagar no provedor a instância que o motor acabou de criar.
//
// Só tem um uso: `provisionar-instancia` cria a instância ANTES de gravar a
// conta (a ordem está explicada lá), e quando o banco recusa a conta a
// instância fica sem dono — foram 56 órfãs no painel da UAZAPI em 08/10 (D73).
// Desfazer na hora é o que torna essa ordem segura.
//
// Mora fora de `whatsapp-uazapi.ts` de propósito: aquele arquivo está no
// bundle do worker, do webhook e do verificador, e mexer nele pediria
// republicar os três por uma função que nenhum deles chama — o mesmo motivo
// de `motor/porta-crm.ts` (D64).
//
//   confirmado  DELETE {base}/instance, header `token` da instância — conferido
//               ao vivo em 08/10: 200 "Instance Deleted", 56 de 56

import type { Buscador } from './tipos.ts';

export interface Desfeito {
  readonly ok: boolean;
  readonly detalhe: string;
}

export async function desprovisionar(
  provedor: string, credenciais: Record<string, string>, buscar: Buscador = fetch,
): Promise<Desfeito> {
  if (provedor !== 'uazapi') return { ok: false, detalhe: `${provedor} não apaga instância pelo motor` };

  const base = (credenciais.base_url ?? '').replace(/\/$/, '');
  const token = credenciais.token ?? '';
  if (!base || !token) return { ok: false, detalhe: 'instância sem endereço ou token — apague pelo painel' };

  try {
    const r = await buscar(`${base}/instance`, { method: 'DELETE', headers: { token } });
    return r.ok
      ? { ok: true, detalhe: 'instância apagada' }
      : { ok: false, detalhe: `o provedor respondeu HTTP ${r.status} ao apagar` };
  } catch (e) {
    return { ok: false, detalhe: e instanceof Error ? e.message : String(e) };
  }
}
