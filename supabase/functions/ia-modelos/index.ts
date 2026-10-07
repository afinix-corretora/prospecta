// "Buscar modelos" da tela de IA (D72): a pessoa cola a chave e escolhe o
// modelo de uma lista que o próprio provedor devolveu.
//
// Mesmo desenho de `verificar-remetente`: a chave do usuário responde "ele
// alcança esta conta?" (RLS), a do serviço lê o segredo. Toda decisão está em
// `motor/modelos-ia.ts`, que tem teste.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { modelosDoPedido } from '../../../motor/modelos-ia.ts';
import type { PedidoModelos, PortaModelos } from '../../../motor/modelos-ia.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    const pedido = (await req.json().catch(() => ({}))) as PedidoModelos;
    const doUsuario = clienteDoUsuario(req);
    const admin = clienteAdmin();

    const porta: PortaModelos = {
      async pessoaLogada() {
        // Sem o token explícito, `getUser()` procura sessão guardada — e aqui
        // não há nenhuma: a pessoa logada viraria "ninguém".
        const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
        if (!jwt) return false;
        const { data } = await doUsuario.auth.getUser(jwt);
        return Boolean(data?.user);
      },
      async credencialVisivel(id) {
        const { data, error } = await doUsuario
          .from('ai_credentials').select('provedor, config').eq('id', id).maybeSingle();
        if (error) throw new Error(`conta de IA ${id}: ${error.message}`);
        return data ? { provedor: data.provedor, config: (data.config ?? {}) as Record<string, unknown> } : null;
      },
      async segredo(id) {
        const { data, error } = await admin.rpc('segredo_da_credencial_ia', { p_credencial_id: id });
        if (error) throw new Error(`segredo_da_credencial_ia: ${error.message}`);
        return data ? String(data) : null;
      },
    };

    const r = await modelosDoPedido(porta, pedido);
    return responder(r.corpo, r.status);
  } catch (e) {
    console.error('[ia-modelos]', e);
    return responder({ ok: false, erro: e instanceof Error ? e.message : String(e) }, 500);
  }
});
