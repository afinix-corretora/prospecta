// Verifica a conexão de uma conta com o provedor: o botão da tela (D62).
//
// Duas chaves, cada uma para uma pergunta. A do usuário, com o JWT que veio
// no pedido, responde "ele alcança esta conta?" — é o RLS de `sender_accounts`
// (quem administra o cliente) que decide, e não um `if` aqui dentro. A do
// serviço lê o segredo e grava o resultado, porque nenhuma das duas coisas é
// da tela. Toda decisão está em `motor/verificacao.ts`, que tem teste.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { verificarRemetente } from '../../../motor/verificacao.ts';
import type { PortaVerificacao } from '../../../motor/verificacao.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    const { sender_id: id } = (await req.json().catch(() => ({}))) as { sender_id?: string };
    if (!id || !UUID.test(id)) return responder({ ok: false, erro: 'sender_id inválido' }, 400);

    const doUsuario = clienteDoUsuario(req);
    const admin = clienteAdmin();

    const porta: PortaVerificacao = {
      async contaVisivel(senderId) {
        const { data, error } = await doUsuario
          .from('sender_accounts').select('provedor, removido_em').eq('id', senderId).maybeSingle();
        if (error) throw new Error(`conta ${senderId}: ${error.message}`);
        return data ? { provedor: data.provedor, removida: data.removido_em !== null } : null;
      },
      async segredo(senderId) {
        const { data, error } = await admin.rpc('segredo_do_remetente', { p_sender_id: senderId });
        if (error) throw new Error(`segredo_do_remetente: ${error.message}`);
        return data ? String(data) : null;
      },
      async registrar(senderId, ok, detalhe) {
        const { error } = await admin.rpc('registrar_verificacao_remetente', {
          p_sender_id: senderId, p_ok: ok, p_detalhe: detalhe,
        });
        if (error) throw new Error(`registrar_verificacao_remetente: ${error.message}`);
      },
    };

    const r = await verificarRemetente(porta, id);

    if (!r.encontrada) return responder({ ok: false, erro: 'conta não encontrada' }, 404);
    return responder({ ok: true, saude: r.saude });
  } catch (e) {
    console.error('[verificar-remetente]', e);
    return responder({ ok: false, erro: e instanceof Error ? e.message : String(e) }, 500);
  }
});
