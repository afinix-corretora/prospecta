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
// Erra para o lado de recusar: qualquer sequência longa sem espaço, do jeito
// que chave e token são. Endereço web não conta — documentação tem URL longa.

export function pareceSegredo(texto: string): boolean {
  return /\b(sk-[A-Za-z0-9_-]{16,}|sk_[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+)/.test(texto)
    || /[A-Za-z0-9_\-.+/=]{40,}/.test(texto.replace(/https?:\/\/\S+/g, ''));
}

export const AVISO_DE_CHAVE =
  'Isso parece uma chave ou um token, e por isso não foi enviado nem guardado: chave não vai no texto da conversa. '
  + 'Quando eu pedir uma chave, aparece um campo protegido no lugar da caixa de mensagem — cole lá, e ela vai direto para o cofre.';
