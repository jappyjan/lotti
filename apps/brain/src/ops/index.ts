import type { App } from '../app.ts';
import { coreOps } from './core.ts';
import { dataOps } from './data.ts';
import { integrationOps } from './integration-ops.ts';

export function registerAllOps(app: App): void {
  for (const op of [...coreOps, ...dataOps, ...integrationOps])
    app.ops.register(op);
}
