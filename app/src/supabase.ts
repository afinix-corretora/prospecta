import { createClient } from '@supabase/supabase-js';

// As duas são públicas por desenho: a chave publishable vai para o navegador e
// quem protege o dado é o RLS, não ela. Se o RLS estiver certo, vazar esta
// chave não dá acesso a nada; se estiver errado, escondê-la não salva.
const url = import.meta.env.VITE_SUPABASE_URL;
const chave = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !chave) {
  throw new Error(
    'VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY são obrigatórias. ' +
    'Local: copie app/.env.example para app/.env.local. Vercel: Settings → Environment Variables.',
  );
}

export const sb = createClient(url, chave);

export const BASE_FUNCOES = `${String(url).replace('.supabase.co', '.functions.supabase.co')}`;

/** Erro do PostgREST com a mensagem que o banco escreveu, não a genérica. */
export function mensagemDeErro(e: unknown): string {
  if (!e) return 'erro desconhecido';
  if (typeof e === 'string') return e;
  const o = e as { message?: string; hint?: string; details?: string };
  return o.message ?? o.details ?? o.hint ?? String(e);
}
