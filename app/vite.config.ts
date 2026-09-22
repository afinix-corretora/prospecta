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

export default defineConfig({
  plugins: [react()],
  define: { __CARIMBO__: JSON.stringify(carimbo) },
  build: { outDir: 'dist', sourcemap: true },
});
