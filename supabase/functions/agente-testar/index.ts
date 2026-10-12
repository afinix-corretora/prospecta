// "Testar" o agente na tela (D76): ele escreve uma resposta de verdade com o
// texto da tela, passa pelos freios do worker, e nada é gravado nem enviado.
//
// Mesmo desenho de `ia-modelos`: a chave do usuário responde "ele alcança esta
// conta de IA?" (RLS), a do serviço lê o segredo. Toda decisão está em
// `motor/teste-de-agente.ts`, que tem teste.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { testarDoPedido } from '../../../motor/teste-de-agente.ts';
import type { PedidoTeste, PortaTeste } from '../../../motor/teste-de-agente.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    // O pedido vem da tela, com o texto do agente: com os tetos de cada campo
    // (TETOS_DO_AGENTE) ele fica abaixo de 128 KB, e corpo maior não é tela, é
    // alguém mandando lixo ao modelo do cliente.
    const bruto = await req.text();
    if (bruto.length > 256_000) return responder({ ok: false, erro: 'pedido grande demais' }, 413);
    let pedido: PedidoTeste;
    try { pedido = JSON.parse(bruto || '{}') as PedidoTeste; } catch { pedido = {}; }
    const doUsuario = clienteDoUsuario(req);
    const admin = clienteAdmin();

    const porta: PortaTeste = {
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
          .from('ai_credentials').select('tenant_id, provedor, modelo, ativo, config').eq('id', id).maybeSingle();
        if (error) throw new Error(`conta de IA ${id}: ${error.message}`);
        return data ? {
          tenant_id: data.tenant_id, provedor: data.provedor, modelo: data.modelo, ativo: data.ativo,
          config: (data.config ?? {}) as Record<string, unknown>,
        } : null;
      },
      async regraDaBlacklist(tenantId, texto) {
        // Com o JWT de quem pede: `testar_blacklist` confere que ele pertence ao cliente.
        const { data, error } = await doUsuario.rpc('testar_blacklist', { p_tenant: tenantId, p_texto: texto });
        if (error) throw new Error(`testar_blacklist: ${error.message}`);
        const linha = ((data ?? []) as { termo: string; acao: string }[])[0];
        return linha ? { termo: linha.termo, acao: linha.acao } : null;
      },
      async segredo(id) {
        const { data, error } = await admin.rpc('segredo_da_credencial_ia', { p_credencial_id: id });
        if (error) throw new Error(`segredo_da_credencial_ia: ${error.message}`);
        return data ? String(data) : null;
      },
    };

    const r = await testarDoPedido(porta, pedido);
    return responder(r.corpo, r.status);
  } catch (e) {
    console.error('[agente-testar]', e);
    return responder({ ok: false, erro: e instanceof Error ? e.message : String(e) }, 500);
  }
});
