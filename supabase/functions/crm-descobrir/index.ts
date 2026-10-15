// Descobrir o que a plataforma tem: o botão "ler pipes e campos" da tela (D64).
//
// O desenho do `verificar-remetente` (D62), pelo mesmo motivo: a chave do
// usuário pergunta "ele alcança esta conexão?" — quem responde é o RLS de
// `crm_connections`, que só deixa ver quem administra o cliente —, e a do
// serviço lê o segredo e grava a estrutura, porque nenhuma das duas coisas é
// da tela. Credencial errada também é gravada: a tela mostra o erro ao lado
// da última estrutura boa, em vez de uma lista vazia que parece pipe sem campo.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { bancoCrmSupabase } from '../_shared/banco-crm.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { criarCrm } from '../../../adapters/crm.ts';
import type { CrmAdapter } from '../../../adapters/crm.ts';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    const { conexao_id: id } = (await req.json().catch(() => ({}))) as { conexao_id?: string };
    if (!id || !UUID.test(id)) return responder({ ok: false, erro: 'conexao_id inválido' }, 400);

    const { data: conexao, error } = await clienteDoUsuario(req)
      .from('crm_connections').select('provedor').eq('id', id).maybeSingle();
    if (error) throw new Error(`conexão ${id}: ${error.message}`);
    if (!conexao) return responder({ ok: false, erro: 'conexão não encontrada' }, 404);

    const admin = clienteAdmin();
    const gravar = async (estrutura: unknown, erro: string | null) => {
      const { error: e } = await admin.rpc('registrar_estrutura_crm', {
        p_conexao_id: id, p_estrutura: estrutura, p_erro: erro,
      });
      if (e) throw new Error(`registrar_estrutura_crm: ${e.message}`);
    };

    let adapter: CrmAdapter;
    try {
      adapter = criarCrm(conexao.provedor);
    } catch {
      return responder({ ok: false, erro: `${conexao.provedor} ainda não tem adapter: não há o que ler` }, 422);
    }

    try {
      const cred = await bancoCrmSupabase(admin).credenciaisDaConexao(id);
      const estrutura = await adapter.descobrir(cred);
      await gravar(estrutura, null);
      return responder({ ok: true, estrutura });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      await gravar(null, msg);
      return responder({ ok: false, erro: msg });
    }
  } catch (e) {
    console.error('[crm-descobrir]', e);
    return responder({ ok: false, erro: e instanceof Error ? e.message : String(e) }, 500);
  }
});
