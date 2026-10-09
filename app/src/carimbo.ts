// Carimbo do build: de quando, de qual commit, de qual branch.
//
// `VITE_*` entra no bundle na hora do build, não na hora que a página abre.
// Adicionar a variável na Vercel não muda um deploy que já passou — e sem
// saber de QUANDO é o build que está no ar, "a variável não foi salva" e "o
// build é velho" parecem exatamente a mesma coisa. A segunda é a comum, e é
// invisível: a tela de erro fica idêntica por mais vezes que a pessoa salve.
//
// Só metadado. Nenhum valor de variável entra aqui, nem mascarado.

declare const __CARIMBO__: {
  readonly em: string;
  readonly commit: string;
  readonly ref: string;
  readonly ambiente: string;
};

export const CARIMBO = __CARIMBO__;

/** "22/09 09:41 · 677336d · claude/new-session-k9qau7 · production" */
export function carimboLegivel(): string {
  const partes: string[] = [];

  const d = new Date(CARIMBO.em);
  if (!Number.isNaN(d.getTime())) {
    partes.push(d.toLocaleString('pt-BR', {
      day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
    }));
  }

  if (CARIMBO.commit) partes.push(CARIMBO.commit);
  if (CARIMBO.ref) partes.push(CARIMBO.ref);
  partes.push(CARIMBO.ambiente);

  return partes.join(' · ');
}
