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
const adapters = fileURLToPath(new URL('../adapters', import.meta.url));

export default defineConfig({
  plugins: [react()],
  define: { __CARIMBO__: JSON.stringify(carimbo) },
  resolve: { alias: { '@adapters': adapters } },
  // Sem isto o dev server recusa servir arquivo acima da raiz do projeto.
  server: { fs: { allow: ['..'] } },
  build: { outDir: 'dist', sourcemap: true },
});
