// Dialeto do Instagram: o handle.
//
// Existe antes do adapter de propósito. A ingestão já precisa guardar handle
// hoje, e `instagram_oficial` está no catálogo com `tem_adapter = false` — o
// que não pode acontecer é a normalização nascer dentro da tela de importação
// e depois divergir da que o adapter usar quando existir. Endereço normalizado
// é chave de dedup e de supressão; ter duas é como a supressão fica furada.

/**
 * Sem arroba, sem URL, minúsculo.
 *
 * O `@` é enfeite de tela, não parte do identificador: guardá-lo às vezes com
 * e às vezes sem é dedup furado. E quem exporta planilha cola o perfil inteiro
 * com frequência suficiente para valer o tratamento.
 */
export function normalizarHandle(bruto: string): string {
  let s = (bruto ?? '').trim();
  if (!s) return '';
  // `https://instagram.com/fulano/?hl=pt` e `instagram.com/fulano` são o mesmo.
  const url = s.match(/(?:^|[/.])instagram[.]com\/([^/?#]+)/i)?.[1];
  if (url) s = url;
  return s.replace(/^@+/, '').replace(/\/+$/, '').trim().toLowerCase();
}

/** O que o Instagram aceita como nome de usuário. */
export function handleValido(bruto: string): boolean {
  return /^[a-z0-9._]{1,30}$/.test(normalizarHandle(bruto));
}
