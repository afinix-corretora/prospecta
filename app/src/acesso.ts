/**
 * O que a tela de entrada precisa decidir sem falar com a rede (D60).
 *
 * Fica fora de `supabase.ts` porque aquele módulo cria o cliente e lê
 * `import.meta.env` — o teste em Node não conseguiria importá-lo. Aqui é só
 * regra, e por isso tem teste em `tests/acesso.test.ts`.
 */

/** Lê os parâmetros do fragmento (`#a=1&b=2`) — é por ali que o Supabase volta. */
function parametrosDoFragmento(hash: string): URLSearchParams {
  return new URLSearchParams(hash.startsWith('#') ? hash.slice(1) : hash);
}

/**
 * A pessoa chegou pelo link de "definir senha" do e-mail?
 *
 * Precisa ser lido **antes** de o cliente do Supabase existir: ao nascer, ele
 * consome o fragmento, grava a sessão e só então avisa `PASSWORD_RECOVERY` —
 * num `setTimeout`. Se a tela dependesse só do aviso, bastaria o React montar
 * depois dele para a pessoa cair direto no painel, logada, sem nunca ver o
 * campo de senha nova. Aí o link de "esqueci a senha" viraria um link de
 * acesso que não troca senha nenhuma — e ninguém perceberia até a próxima vez.
 */
export function chegouParaDefinirSenha(hash: string): boolean {
  const p = parametrosDoFragmento(hash);
  return p.get('type') === 'recovery' && p.has('access_token');
}

/**
 * O link do e-mail voltou com erro (expirado, já usado)?
 *
 * Sem isto, o erro fica no endereço e a tela mostra o formulário de entrada
 * como se nada tivesse acontecido — a pessoa clicou no link, voltou para o
 * começo, e não sabe por quê.
 */
export function erroDoLink(hash: string): string | null {
  const p = parametrosDoFragmento(hash);
  if (!p.has('error') && !p.has('error_code')) return null;
  const codigo = p.get('error_code') ?? '';
  if (codigo === 'otp_expired') {
    return 'Este link expirou ou já foi usado. Peça outro abaixo.';
  }
  return p.get('error_description') ?? 'O link não pôde ser usado. Peça outro abaixo.';
}

/** Erro de autenticação em português, pelo código — não pelo texto em inglês. */
export function mensagemDeAcesso(e: unknown): string {
  if (!e) return 'erro desconhecido';
  const o = e as { code?: string; message?: string };
  switch (o.code) {
    case 'invalid_credentials':
      return 'E-mail ou senha incorretos.';
    case 'email_not_confirmed':
      return 'Este e-mail ainda não foi confirmado. Use "Esqueci a senha" para receber um link.';
    case 'over_request_rate_limit':
    case 'over_email_send_rate_limit':
      return 'Muitas tentativas seguidas. Espere um minuto e tente de novo.';
    case 'weak_password':
      return 'Senha fraca demais para a política do projeto. Use uma mais longa.';
    case 'same_password':
      return 'A senha nova é igual à atual.';
    case 'user_banned':
      return 'Este acesso está bloqueado.';
    default:
      return o.message ?? String(e);
  }
}

export const SENHA_MINIMA = 8;

/** O que impede de gravar a senha nova, ou `null` se nada impede. */
export function problemaDaSenha(senha: string, confirmacao: string): string | null {
  if (senha.length < SENHA_MINIMA) return `A senha precisa de pelo menos ${SENHA_MINIMA} caracteres.`;
  if (senha !== confirmacao) return 'As duas senhas não conferem.';
  return null;
}
