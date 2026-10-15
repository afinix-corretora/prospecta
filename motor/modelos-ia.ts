// "Buscar modelos": o que a edge function `ia-modelos` decide (D72).
//
// Dois pedidos chegam da tela:
//
//   { provedor, campos }                 a pessoa acabou de colar a chave e
//                                        ainda não salvou — a chave vem no
//                                        corpo, como viria no salvar;
//   { credencial_id, campos? }           a conta já existe e a chave está no
//                                        Vault — editar sem redigitar.
//
// No segundo, a conta precisa ser VISÍVEL para quem pediu: lida com o JWT
// dele, o RLS de `ai_credentials` responde, e não um `if` aqui (D62). Só
// depois a chave do serviço lê o segredo. Campo digitado vale sobre o
// guardado, que é o que a pessoa está vendo na tela.
//
// Nos dois, a lista sai e a chave não: nada aqui grava nem devolve segredo.

import type { Buscador } from '../adapters/tipos.ts';
import { listarModelos, type ListaDeModelos } from '../adapters/ia-modelos.ts';

export interface PortaModelos {
  /** Há uma pessoa logada? A chave anon também é JWT, e ela não pode usar a porta. */
  pessoaLogada(): Promise<boolean>;
  /** A conta como quem pediu a enxerga; `null` quando não alcança. */
  credencialVisivel(id: string): Promise<{ provedor: string; config: Record<string, unknown> } | null>;
  /** O blob do Vault (JSON), pela chave do serviço. */
  segredo(id: string): Promise<string | null>;
}

export type PedidoModelos = {
  provedor?: unknown; campos?: unknown; credencial_id?: unknown;
};

export type RespostaModelos =
  | { status: 200; corpo: ListaDeModelos }
  | { status: 400 | 401 | 404; corpo: { ok: false; erro: string } };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function textos(v: unknown): Record<string, string> {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return {};
  const r: Record<string, string> = {};
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    // Só string: objeto viraria "[object Object]" no cabeçalho (o D48 aqui).
    if (typeof x === 'string' && x.trim()) r[k] = x.trim();
  }
  return r;
}

export async function modelosDoPedido(
  porta: PortaModelos, pedido: PedidoModelos, buscar?: Buscador,
): Promise<RespostaModelos> {
  if (!(await porta.pessoaLogada())) return { status: 401, corpo: { ok: false, erro: 'entre com a sua conta' } };

  const digitados = textos(pedido.campos);

  if (pedido.credencial_id !== undefined && pedido.credencial_id !== null && pedido.credencial_id !== '') {
    const id = String(pedido.credencial_id);
    if (!UUID.test(id)) return { status: 400, corpo: { ok: false, erro: 'credencial_id inválido' } };
    const conta = await porta.credencialVisivel(id);
    if (!conta) return { status: 404, corpo: { ok: false, erro: 'conta de IA não encontrada' } };
    const guardados: Record<string, string> = textos(conta.config);
    const blob = await porta.segredo(id);
    if (blob) {
      try { Object.assign(guardados, textos(JSON.parse(blob))); } catch { /* blob ilegível: segue sem ele */ }
    }
    return { status: 200, corpo: await listarModelos(conta.provedor, { ...guardados, ...digitados }, buscar) };
  }

  const provedor = typeof pedido.provedor === 'string' ? pedido.provedor.trim() : '';
  if (!/^[a-z0-9_-]{2,40}$/.test(provedor)) return { status: 400, corpo: { ok: false, erro: 'provedor inválido' } };
  return { status: 200, corpo: await listarModelos(provedor, digitados, buscar) };
}
