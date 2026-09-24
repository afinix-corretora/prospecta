/**
 * Para onde o link de acesso deve trazer a pessoa de volta.
 *
 * Num lugar só, e não inline na tela, porque este valor precisa ser mostrado
 * ao usuário além de ser enviado ao Supabase — e duas respostas para a mesma
 * pergunta é como a tela passa a mentir sobre o que o motor pediu.
 *
 * ## O defeito que isto existe para tornar visível
 *
 * O Supabase só honra o `emailRedirectTo` se a URL estiver na lista de
 * permitidas (Authentication ▸ URL Configuration ▸ Redirect URLs). Quando não
 * está, ele **não recusa e não avisa**: cai em silêncio no Site URL, que vem
 * de fábrica como `http://localhost:3000`.
 *
 * O sintoma é o link do e-mail apontar para localhost. E, do lado de cá, a
 * requisição foi bem-sucedida — `error` é nulo, a tela diz "link enviado", e
 * não há nada para suspeitar. É a mesma forma do D44: uma configuração errada
 * cujo sintoma é indistinguível do funcionamento normal.
 *
 * O app não consegue saber o que está na lista do Supabase. O que ele pode
 * fazer é dizer **o que pediu** — e aí a pessoa que recebe um link diferente
 * disso sabe, em cinco segundos, que o problema é a lista, e não a caixa de
 * entrada, o filtro de spam ou o navegador.
 *
 * A barra no fim não é enfeite: o glob `.../**` da lista do Supabase casa
 * caminhos abaixo da raiz, e mandar a origem sem barra deixa o casamento na
 * dependência de detalhe de implementação do glob.
 */
export function urlDeRetorno(origem?: string): string {
  const base = origem ?? window.location.origin;
  return base.endsWith('/') ? base : `${base}/`;
}

/** É um endereço local? Só para a tela saber se vale a pena avisar. */
export function ehLocal(url: string): boolean {
  return /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:|\/)/.test(url);
}
