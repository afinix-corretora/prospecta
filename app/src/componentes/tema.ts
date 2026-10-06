import { useCallback, useState } from 'react';

export type Tema = 'dark' | 'light';
const CHAVE = 'prospecta:tema';

/** O tema da pessoa. O `index.html` já aplicou o salvo antes da primeira
 *  pintura; aqui só se lê o que está no `<html>` e se troca. */
export function useTema(): [Tema, () => void] {
  const [tema, setTema] = useState<Tema>(() =>
    document.documentElement.dataset.theme === 'light' ? 'light' : 'dark');

  const alternar = useCallback(() => {
    setTema((atual) => {
      const novo: Tema = atual === 'dark' ? 'light' : 'dark';
      document.documentElement.dataset.theme = novo;
      document.querySelector('meta[name="theme-color"]')
        ?.setAttribute('content', novo === 'dark' ? '#0D0D12' : '#F4F0FA');
      try { localStorage.setItem(CHAVE, novo); } catch { /* aba anônima: vale até fechar */ }
      return novo;
    });
  }, []);

  return [tema, alternar];
}
