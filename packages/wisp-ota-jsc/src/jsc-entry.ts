// Bundle entry for the app: `globalThis.WispOta.create(host)`.
import { createWispOta } from './host.ts';

(globalThis as unknown as { WispOta: unknown }).WispOta = {
  create: createWispOta,
};
