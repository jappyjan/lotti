// Bundle entry for tests and the Simulator: `globalThis.WispFakeTemple.create(host)`.
import { createFakeTemples } from './fake-temple.ts';

(globalThis as unknown as { WispFakeTemple: unknown }).WispFakeTemple = {
  create: createFakeTemples,
};
