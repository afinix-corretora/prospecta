import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Carimbo do build — ver `src/carimbo.ts` para o porquê.
//
// Estas quatro a Vercel dá ao processo de build; nenhuma precisa do prefixo
// `VITE_` porque não são lidas pelo navegador, são coladas aqui na compilação.
const carimbo = {
  em: new Date().toISOString(),
  commit: (process.env.VERCEL_GIT_COMMIT_SHA ?? '').slice(0, 7),
  ref: process.env.VERCEL_GIT_COMMIT_REF ?? '',
  ambiente: process.env.VERCEL_ENV ?? 'local',
};

// `adapters/` mora fora de `app/` porque não é do app: é do motor, e o worker
// usa os mesmos arquivos. Importar de lá em vez de copiar é o que impede uma
// segunda normalização de telefone nascer dentro da tela (D32).
//
// Isto parece frágil porque a raiz do projeto na Vercel é `app/`, e a correção
// instintiva seria copiar os arquivos para cá — que é justamente o erro.
// Conferido: o build da Vercel enxerga acima da raiz, e o primeiro deploy que
// depende disso (4ed539e) ficou READY. Se um dia parar de enxergar, a saída é
// mudar a raiz do projeto, nunca duplicar o normalizador.
const adapters = fileURLToPath(new URL('../adapters', import.meta.url));

export default defineConfig({
  plugins: [react()],
  define: { __CARIMBO__: JSON.stringify(carimbo) },
  resolve: { alias: { '@adapters': adapters } },
  // Sem isto o dev server recusa servir arquivo acima da raiz do projeto.
  server: { fs: { allow: ['..'] } },
  build: { outDir: 'dist', sourcemap: true },
});
