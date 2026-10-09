// O agente do Setup rápido (D72). Toda decisão está em `motor/agente-setup.ts`,
// que tem teste; aqui é a fiação.
//
// Três portões antes de gastar a chave da plataforma:
//   1. uma PESSOA logada — a chave anon também é JWT;
//   2. que pertença a algum cliente — lido com o JWT dela, pelo RLS de
//      `tenant_users`, e não por um `if` aqui;
//   3. um teto por pessoa nesta instância. É freio de abuso, não de cobrança:
//      instâncias novas começam do zero, e isso está dito em DECISOES (D72).
//
// A chave sai do Vault por `segredo_do_agente_setup`, que só o service_role
// chama, e vai direto para o cabeçalho. Não entra em resposta nem em log.

import { clienteAdmin } from '../_shared/banco-supabase.ts';
import { clienteDoUsuario, preflight, responder } from '../_shared/http.ts';
import { conversar, lerPedido } from '../../../motor/agente-setup.ts';

const TETO = 30;
const JANELA_MS = 10 * 60 * 1000;
const usos = new Map<string, number[]>();

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return preflight();
  if (req.method !== 'POST') return responder({ ok: false, erro: 'use POST' }, 405);

  try {
    const jwt = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const doUsuario = clienteDoUsuario(req);
    const { data: quem } = jwt ? await doUsuario.auth.getUser(jwt) : { data: null };
    const usuario = quem?.user?.id;
    if (!usuario) return responder({ ok: false, erro: 'entre com a sua conta' }, 401);

    const { data: vinculos, error: eVinc } = await doUsuario.from('tenant_users').select('tenant_id').limit(1);
    if (eVinc) throw new Error(`tenant_users: ${eVinc.message}`);
    if (!vinculos?.length) return responder({ ok: false, erro: 'sua conta não pertence a nenhum cliente' }, 403);

    const agora = Date.now();
    const recentes = (usos.get(usuario) ?? []).filter((t) => agora - t < JANELA_MS);
    if (recentes.length >= TETO) {
      return responder({ ok: false, erro: 'muitas mensagens em pouco tempo — espere alguns minutos' }, 429);
    }

    const pedido = lerPedido(await req.json().catch(() => null));
    if (typeof pedido === 'string') return responder({ ok: false, erro: pedido }, 400);

    const { data: chave, error: eChave } = await clienteAdmin().rpc('segredo_do_agente_setup');
    if (eChave) throw new Error(`segredo_do_agente_setup: ${eChave.message}`);
    if (!chave) return responder({ ok: false, erro: 'a chave da plataforma não está no cofre — o agente fica desligado até ela voltar' }, 503);

    usos.set(usuario, [...recentes, agora]);
    const r = await conversar(pedido, String(chave));
    if (!r.ok) {
      console.error('[agente-setup]', r.status, r.erro);
      return responder({ ok: false, erro: r.erro }, r.status);
    }
    return responder({ ok: true, ...r.saida });
  } catch (e) {
    console.error('[agente-setup]', e instanceof Error ? e.message : String(e));
    return responder({ ok: false, erro: 'o agente falhou ao responder' }, 500);
  }
});
