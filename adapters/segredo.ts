// "Isto parece uma chave?" (D72) — uma regra só, para a tela e para o agente.
//
// A conversa do Setup rápido não é lugar de chave: ela iria para a OpenAI no
// meio do texto e ficaria guardada no navegador. A TELA pergunta isto antes
// de enviar e de guardar; o AGENTE pergunta de novo antes de chamar o modelo,
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

/** Onde a chave colada deveria ter entrado, pelo que o texto em volta sugere. */
export type LugarDaChave = 'ia' | 'crm' | 'whatsapp_nao_oficial' | 'whatsapp_oficial' | 'email' | 'sms';

export function lugarDaChave(texto: string): LugarDaChave {
  const t = texto.toLowerCase();
  if (/openai|anthropic|claude|gemini|deepseek|openrouter|\bia\b|sk-/.test(t)) return 'ia';
  if (/pipefy|hubspot|pipedrive|crm|salesforce|zoho|ploomes|rd station/.test(t)) return 'crm';
  if (/uazapi|evolution|chip|qr/.test(t)) return 'whatsapp_nao_oficial';
  if (/meta|gupshup|whatsapp/.test(t)) return 'whatsapp_oficial';
  if (/resend|locaweb|smtp|e-?mail/.test(t)) return 'email';
  if (/comtele|sms/.test(t)) return 'sms';
  return 'ia';
}

export const AVISO_DE_CHAVE =
  'Isso parece uma chave ou um token, e eu não leio chave na conversa: ela não foi enviada nem guardada. '
  + 'Por segurança, considere trocá-la no provedor. Cole-a no formulário que acabei de abrir — de lá ela vai direto para o cofre.';
