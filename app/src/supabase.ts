import { createClient } from '@supabase/supabase-js';

// As duas são públicas por desenho: a chave publishable vai para o navegador e
// quem protege o dado é o RLS, não ela. Se o RLS estiver certo, vazar esta
// chave não dá acesso a nada; se estiver errado, escondê-la não salva.
const url = import.meta.env.VITE_SUPABASE_URL;
const chave = import.meta.env.VITE_SUPABASE_ANON_KEY;

/** Faltando variável, o app mostra o que fazer em vez de página em branco.
 *
 * Lançar aqui parecia certo — falhar cedo e alto. Mas isto é módulo de topo:
 * o throw acontece antes de qualquer React montar, e o resultado é tela branca
 * com o erro só no console. Num deploy novo, que é exatamente quando falta
 * variável, ninguém abre o console: conclui que "não funciona". */
export const configurado = Boolean(url && chave);

export const faltando = [
  !url && 'VITE_SUPABASE_URL',
  !chave && 'VITE_SUPABASE_ANON_KEY',
].filter(Boolean) as string[];

// Cliente com valores de fachada quando não há configuração: nada é chamado
// nesse caso, porque o App para antes — mas o import não pode explodir.
export const sb = createClient(url || 'https://exemplo.supabase.co', chave || 'sem-chave');

export const BASE_FUNCOES = String(url ?? '').replace('.supabase.co', '.functions.supabase.co');

/** Erro do PostgREST com a mensagem que o banco escreveu, não a genérica. */
export function mensagemDeErro(e: unknown): string {
  if (!e) return 'erro desconhecido';
  if (typeof e === 'string') return e;
  const o = e as { message?: string; hint?: string; details?: string };
  return o.message ?? o.details ?? o.hint ?? String(e);
}
