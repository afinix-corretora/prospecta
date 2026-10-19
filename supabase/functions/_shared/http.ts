// O que toda function chamada pela TELA precisa, e as do motor não.
//
// CORS: o app roda noutro domínio (Vercel), e o navegador manda um OPTIONS
// antes do POST. Function que responde 405 ao OPTIONS não é chamável da tela —
// o erro aparece como "Failed to fetch", sem status, e parece rede (D62).
//
// O cliente do usuário: a chave do serviço passa por cima do RLS, então uma
// function que só usa ela não sabe se QUEM PEDIU alcança o que pediu. Ler o
// alvo com o JWT do pedido é o jeito de deixar o RLS — que tem teste —
// responder essa pergunta, em vez de um `if` aqui dentro, que não tem.

import { createClient, type SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export function responder(corpo: unknown, status = 200): Response {
  return Response.json(corpo, { status, headers: CORS });
}

export function preflight(): Response {
  return new Response(null, { headers: CORS });
}

export function clienteDoUsuario(req: Request): SupabaseClient {
  const url = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  if (!url || !anon) throw new Error('SUPABASE_URL/SUPABASE_ANON_KEY ausentes');
  return createClient(url, anon, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  });
}
