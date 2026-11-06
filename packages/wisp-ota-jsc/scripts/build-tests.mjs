// Compiles the tests (and the wisp-ota sources they import) for node:test.
import { build } from 'esbuild';
import { readdirSync } from 'node:fs';

await build({
  entryPoints: readdirSync('src')
    .filter((f) => f.endsWith('.test.ts'))
    .map((f) => `src/${f}`),
  outdir: 'out-tsc',
  outExtension: { '.js': '.mjs' },
  bundle: true,
  format: 'esm',
  platform: 'node',
  target: 'node24',
  packages: 'external',
  logLevel: 'warning',
});
