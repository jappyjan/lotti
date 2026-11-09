// SPDX-License-Identifier: MIT
//
// The Mac-side session tool (rung4.md G14, W25): the TypeScript SDK opens a Wisp session with a
// temple and runs HELLO, TIME_SYNC, an idle stretch longer than the session timeout that only the
// SDK's keepalive PINGs bridge, TIME_SYNC again and BYE. Prints one JSON report; exit 0 when every
// step passed.
//
//   On the Mac (the real radio, bleak), from the repository root, after
//   `pnpm nx run wisp-sdk-ts:build`:
//     node apps/wisp-fw/tests/ble/session.mts --bridge \
//       "uv run --with bleak==0.22.3 python -I apps/wisp-fw/tests/ble/bleak_bridge.py"
//
//   In emulation (scripts/test.sh): the Bumble bridge and the native_sim firmware:
//     node apps/wisp-fw/tests/ble/session.mts --bridge "python3 -I .../bumble_bridge.py" \
//       --firmware .../zephyr.exe
//
// Read-only towards the temple's storage: HELLO, TIME_SYNC, PING and BYE change nothing but the
// session (native-1's observe-only Wisp Boot counts the confirm and writes nothing).

import { spawn } from 'node:child_process';
import { parseArgs } from 'node:util';
import { WispGlasses } from '../../../../packages/wisp-sdk-ts/dist/index.js';
import { Bridge, BridgeTransport } from './bridge.mts';

const { values: opt } = parseArgs({
  options: {
    bridge: { type: 'string' },
    firmware: { type: 'string' },
    'idle-s': { type: 'string', default: '12' },
    'connect-s': { type: 'string', default: '30' },
  },
});
if (!opt.bridge) {
  console.error('usage: session.mts --bridge "<bridge command>" [--firmware <native_sim exe>] [--idle-s 12]');
  process.exit(2);
}

const report: Record<string, unknown> = { steps: [] as unknown[] };
const steps = report.steps as { step: string; ok: boolean; ms: number; detail?: unknown }[];
async function step<T>(name: string, fn: () => Promise<T>, detail?: (out: T) => unknown): Promise<T> {
  const t0 = Date.now();
  try {
    const out = await fn();
    steps.push({ step: name, ok: true, ms: Date.now() - t0, detail: detail ? detail(out) : out });
    return out;
  } catch (err) {
    steps.push({ step: name, ok: false, ms: Date.now() - t0, detail: String(err) });
    throw err;
  }
}

const proc = spawn('/bin/sh', ['-c', opt.bridge], { stdio: ['pipe', 'pipe', 'inherit'] });
const bridge = new Bridge(proc);
let firmware: ReturnType<typeof spawn> | undefined;
let code = 1;
try {
  if (opt.firmware) {
    const { port } = await bridge.next('listening', 0, 30_000);
    firmware = spawn(opt.firmware, [`--bt-dev=127.0.0.1:${port as number}`], { stdio: 'ignore' });
  }
  const c = await step('connect', async () => {
    const from = bridge.events.length;
    bridge.send({ cmd: 'connect' });
    const e = await bridge.next('connected', from, Number(opt['connect-s']) * 1000);
    return { mtu: e.mtu, name: e.name, address: e.address };
  });
  const glasses = await step('hello', async () =>
    WispGlasses.connect(new BridgeTransport(bridge, (c.mtu as number) - 3), {
      appId: 'dev.wisp.session',
      clientName: 'w25-session',
    }),
    () => 'HELLO done',
  );
  const caps = glasses.capabilities;
  report.hello = {
    protocol: caps.protocol,
    firmware: caps.firmware,
    maxFrame: caps.maxFrame,
    sessionTimeoutMs: caps.sessionTimeoutMs,
    canvas: caps.canvas,
  };
  await step('time-sync', async () => {
    await glasses.syncClock(3);
    return 'ok';
  });
  const idle = Number(opt['idle-s']);
  await step(`idle ${idle} s on keepalive PINGs`, async () => {
    await new Promise((resolve) => setTimeout(resolve, idle * 1000));
    await glasses.syncClock(1); // fails if the session timed out meanwhile
    return 'session alive';
  });
  await step('bye', async () => {
    const from = bridge.events.length;
    await glasses.close();
    await bridge.next('disconnected', from, 10_000).catch(() => undefined);
    return 'closed';
  });
  code = 0;
} catch {
  code = 1;
} finally {
  report.ok = code === 0;
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  firmware?.kill('SIGKILL');
  proc.kill('SIGKILL');
  process.exit(code);
}
