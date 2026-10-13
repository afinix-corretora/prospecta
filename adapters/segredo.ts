// "Isto parece uma chave?" (D72) — uma regra só, para a tela e para o agente.
//
// O texto livre da conversa do Setup rápido não é lugar de chave: ela iria
// para a OpenAI no meio da frase e ficaria guardada no navegador. Chave entra
// pelo campo protegido que a conversa mostra quando pede uma (D73), e esse vai
// direto para o Vault. A TELA pergunta isto antes de mandar texto livre e de
// guardá-lo; o AGENTE pergunta de novo antes de chamar o modelo,
// porque a tela é do cliente e pode ser outra. Duas cópias da regra seriam a
// segunda normalização do D32: a tela deixaria passar o que o agente barra,
// ou o contrário, e o furo apareceria como chave do cliente num log alheio.
//
// Erra para o lado de recusar. A primeira versão só pegava os prefixos sk-,
// AIza e eyJ, ou 40 caracteres seguidos — e as chaves reais do catálogo têm
// 24 a 39: o token da UAZAPI e a chave da Comtele são UUID, a Gupshup, a
// Evolution e a Locaweb usam 32 alfanuméricos, a RD Station 24 hex e a Resend
// `re_` com 32. Todas passavam, e a chave do CLIENTE ia para a OpenAI pela
// chave da PLATAFORMA (D77). `tests/agente_setup.test.ts` tem uma amostra no
// formato de cada segredo do catálogo, e o outro lado: nome de modelo,
// endereço, telefone e conversa, que não podem ser barrados.

/** Prefixos que só chave usa, seguidos do corpo dela. */
const PREFIXO = new RegExp(
  '(?:^|[^A-Za-z0-9])(?:sk-|sk_|rk_|pk_live_|pk_test_|re_|pplx-|gsk_|xai-|hf_|ghp_|gho_|ghs_|github_pat_|glpat-'
  + '|xox[abprs]-|SG\\.)[A-Za-z0-9_\\-.]{16,}',
);
const GOOGLE = /AIza[0-9A-Za-z_-]{30,}/;
const JWT = /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/;
// Token de instância UAZAPI, chave Comtele, app token HubSpot (`pat-na1-` + UUID).
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

/**
 * As "corridas" do texto: o que fica entre separadores. Hífen e ponto
 * separam, e é isso que deixa passar `claude-sonnet-4-5-20250929` e
 * `free-1234.uazapi.com` — chave com hífen é pega pelo prefixo ou pelo UUID.
 * Dentro de endereço web, barra e parâmetro também separam: documentação tem
 * caminho longo, e o token que vem no meio da URL fica sendo uma corrida só.
 */
function corridas(texto: string): string[] {
  const semUrl = texto.replace(/https?:\/\/\S+/gi, (u) => u.replace(/[/?&#=:%]/g, ' '));
  return semUrl.split(/[^A-Za-z0-9_+/=]+/).filter(Boolean);
}

function corridaDeChave(c: string): boolean {
  if (c.length >= 40) return true;
  if (c.length >= 20 && /[A-Za-z]/.test(c) && /\d/.test(c)) return true;
  // Sem dígito, só passa se for palavra: chave aleatória mistura caixas.
  const maiusculas = c.replace(/[^A-Z]/g, '').length;
  const minusculas = c.replace(/[^a-z]/g, '').length;
  return c.length >= 24 && maiusculas >= 3 && minusculas >= 3;
}

export function pareceSegredo(texto: string): boolean {
  if (PREFIXO.test(texto) || GOOGLE.test(texto) || JWT.test(texto) || UUID.test(texto)) return true;
  return corridas(texto).some(corridaDeChave);
}

export const AVISO_DE_CHAVE =
  'Isso parece uma chave ou um token, e por isso não foi enviado nem guardado: chave não vai no texto da conversa. '
  + 'Quando eu pedir uma chave, aparece um campo protegido no lugar da caixa de mensagem — cole lá, e ela vai direto para o cofre.';
