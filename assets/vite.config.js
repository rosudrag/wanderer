import path from 'path';

import react from '@vitejs/plugin-react';

export default {
  publicDir: './static',
  plugins: [react()],
  build: {
    target: 'es2018',
    format: 'esm',
    minify: false,
    outDir: '../priv/static',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    rollupOptions: {
      input: ['app.tsx'],
      output: {
        entryFileNames: 'assets/[name].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name][extname]',
      },
      onwarn(warning, warn) {
        if (warning.code === 'MODULE_LEVEL_DIRECTIVE') {
          return;
        }
        warn(warning);
      },
    },
  },
  // CHEWY PATCH: the map beautifier's layout engine now runs in a module
  // worker (assets/js/hooks/Mapper/components/map/layout/beautify.worker.ts)
  // so a large synthetic-map solve does not block the main thread. The
  // worker's own module graph is code-split (the engine dynamically
  // imports its regionLayouts.json dataset), which Vite's default worker
  // output format ('iife') refuses to bundle at all — 'es' is required.
  worker: {
    format: 'es',
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'js'),
    },
  },
};
