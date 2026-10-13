// Ler a empresa por site, Instagram e materiais, no construtor de agentes
// (D78b). Devolve um RASCUNHO de "Sobre a empresa e a oferta"; nada é gravado.
//
// Mesmo desenho de `agente-testar`: a chave do usuário responde "ele alcança
// esta conta de IA?" (RLS), a do serviço lê o segredo. Toda decisão está em
// `motor/contexto-da-empresa.ts`, e a leitura do site e dos arquivos em
// `adapters/coleta.ts` — os dois têm teste. Aqui fica só o que não existe no
// Node: o cliente do Supabase e o DNS do Deno.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { colherDoPedido } from '../../../motor/contexto-da-empresa.ts';
import type { PedidoDaColeta, PortaDaColeta } from '../../../motor/contexto-da-empresa.ts';
import { TETO_TOTAL } from '../../../adapters/coleta.ts';

// Os arquivos chegam em base64 (um terço maior) dentro do JSON, com o texto do
// site e do perfil ao lado. Corpo maior que isto não veio da tela, que barra
// antes no mesmo `TETO_TOTAL`.
const TETO_DO_CORPO = Math.ceil(TETO_TOTAL * 4 / 3) + 512 * 1024;

async function resolver(host: string): Promise<string[]> {
  const [v4, v6] = await Promise.all([
    Deno.resolveDns(host, 'A').catch(() => [] as string[]),
    Deno.resolveDns(host, 'AAAA').catch(() => [] as string[]),
  ]);
  return [...v4, ...v6];
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    const declarado = Number(req.headers.get('content-length') ?? '0');
    if (declarado > TETO_DO_CORPO) return responder({ ok: false, erro: 'os arquivos passam do teto de uma leitura' }, 413);
    const bruto = await req.text();
    if (bruto.length > TETO_DO_CORPO) return responder({ ok: false, erro: 'os arquivos passam do teto de uma leitura' }, 413);
    let pedido: PedidoDaColeta;
    try { pedido = JSON.parse(bruto || '{}') as PedidoDaColeta; } catch { pedido = {}; }
    const doUsuario = clienteDoUsuario(req);
    const admin = clienteAdmin();

    const porta: PortaDaColeta = {
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
      async segredo(id) {
        const { data, error } = await admin.rpc('segredo_da_credencial_ia', { p_credencial_id: id });
        if (error) throw new Error(`segredo_da_credencial_ia: ${error.message}`);
        return data ? String(data) : null;
      },
    };

    const r = await colherDoPedido(porta, pedido, { buscar: fetch, resolver });
    return responder(r.corpo, r.status);
  } catch (e) {
    console.error('[agente-contexto]', e);
    return responder({ ok: false, erro: 'a leitura falhou do nosso lado; tente de novo' }, 500);
  }
});
