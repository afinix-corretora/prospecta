// Ler a empresa por site, Instagram e materiais, no construtor de agentes
// (D78b). Devolve um RASCUNHO de "Sobre a empresa e a oferta"; nada é gravado.
//
// Mesmo desenho de `agente-testar`: a chave do usuário responde "ele alcança
// esta conta de IA?" (RLS), a do serviço lê o segredo. Toda decisão está em
// `motor/contexto-da-empresa.ts`, e a leitura do site e dos arquivos em
// `adapters/coleta.ts` — os dois têm teste. Aqui fica só o que não existe no
// Node: o cliente do Supabase, o DNS do Deno e a leitura do corpo.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { colherDoPedido } from '../../../motor/contexto-da-empresa.ts';
import type { PedidoDaColeta, PortaDaColeta } from '../../../motor/contexto-da-empresa.ts';
import { TETO_TOTAL } from '../../../adapters/coleta.ts';

// Os arquivos chegam em base64 (um terço maior) dentro do JSON, com o texto do
// site e do perfil ao lado. Corpo maior que isto não veio da tela, que barra
// antes no mesmo `TETO_TOTAL`.
const TETO_DO_CORPO = Math.ceil(TETO_TOTAL * 4 / 3) + 512 * 1024;

/**
 * Os IPs do domínio. Só "não existe" vira vazio: qualquer outro erro do DNS é
 * "não sei", e sem saber para onde o domínio aponta o site não é lido — um A
 * que falha com o AAAA respondendo deixaria a conferência olhar só metade.
 */
async function resolver(host: string, sinal?: AbortSignal): Promise<string[]> {
  const um = (tipo: 'A' | 'AAAA') => Deno.resolveDns(host, tipo, { signal: sinal })
    .catch((e) => { if (e instanceof Deno.errors.NotFound) return [] as string[]; throw e; });
  const [v4, v6] = await Promise.all([um('A'), um('AAAA')]);
  return [...v4, ...v6];
}

/** O corpo, contado enquanto chega: sem `content-length`, `req.text()` guardaria tudo antes de medir. */
async function lerCorpo(req: Request, teto: number): Promise<string | null> {
  const leitor = req.body?.getReader();
  if (!leitor) return '';
  const pedacos: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await leitor.read();
    if (done) break;
    total += value.length;
    if (total > teto) { await leitor.cancel().catch(() => undefined); return null; }
    pedacos.push(value);
  }
  const tudo = new Uint8Array(total);
  let i = 0;
  for (const p of pedacos) { tudo.set(p, i); i += p.length; }
  return new TextDecoder().decode(tudo);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    const doUsuario = clienteDoUsuario(req);
    // Quem pede, antes de ler o corpo: a chave anon passa pelo gateway, e um
    // corpo de 15 MB não é lido para quem não entrou.
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    // Sem o token explícito, `getUser()` procura sessão guardada — e aqui não
    // há nenhuma: a pessoa logada viraria "ninguém".
    const logado = jwt ? Boolean((await doUsuario.auth.getUser(jwt)).data?.user) : false;
    if (!logado) return responder({ ok: false, erro: 'entre com a sua conta' }, 401);

    if (Number(req.headers.get('content-length') ?? '0') > TETO_DO_CORPO) {
      return responder({ ok: false, erro: 'os arquivos passam do teto de uma leitura' }, 413);
    }
    const bruto = await lerCorpo(req, TETO_DO_CORPO);
    if (bruto === null) return responder({ ok: false, erro: 'os arquivos passam do teto de uma leitura' }, 413);
    let pedido: PedidoDaColeta;
    try { pedido = JSON.parse(bruto || '{}') as PedidoDaColeta; } catch { pedido = {}; }
    const admin = clienteAdmin();

    const porta: PortaDaColeta = {
      async pessoaLogada() { return logado; },
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
    // A mensagem fica no log; a tela recebe uma frase que não carrega nada interno.
    console.error('[agente-contexto]', e instanceof Error ? e.message : String(e));
    return responder({ ok: false, erro: 'a leitura falhou do nosso lado; tente de novo' }, 500);
  }
});
