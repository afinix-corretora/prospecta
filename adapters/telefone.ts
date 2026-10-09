// Normalização de telefone brasileiro.
//
// Migra do legado (`normalizePhone` do comtele-send-sms e `normalizeBrazilian
// Phone` do evolution-webhook, que faziam a mesma coisa em dois lugares).
// Aqui é um só, porque a identidade normalizada é a chave de dedup e de
// supressão — duas normalizações divergentes significam supressão furada.

/** Só dígitos, com DDI 55 na frente quando é número nacional. */
export function normalizarTelefone(bruto: string): string {
  const digitos = (bruto ?? '').replace(/\D/g, '');
  if (!digitos) return '';
  // 10 = fixo com DDD, 11 = celular com DDD e o nono dígito.
  if (digitos.length === 10 || digitos.length === 11) return `55${digitos}`;
  return digitos;
}

/** Aceita apenas o que tem cara de número discável com DDI. */
export function telefoneValido(bruto: string): boolean {
  const n = normalizarTelefone(bruto);
  return n.length >= 12 && n.length <= 15;
}

/**
 * Distingue celular de fixo, para a ingestão não prometer WhatsApp num número
 * que não tem WhatsApp.
 *
 * A regra vale só para o DDI 55, onde ela é confiável: depois do DDD, celular
 * tem nove dígitos e começa com 9; fixo tem oito. Fora do Brasil não se
 * adivinha — devolve `true` e deixa o provedor recusar, que é melhor do que
 * descartar em silêncio um número internacional bom.
 */
export function celularBrasileiro(bruto: string): boolean {
  const n = normalizarTelefone(bruto);
  if (!n.startsWith('55')) return telefoneValido(bruto);
  const assinante = n.slice(4);
  return assinante.length === 9 && assinante.startsWith('9');
}
