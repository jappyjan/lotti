// SPDX-License-Identifier: MIT
//
// End to end, without hardware: the TypeScript SDK opens a Wisp session with the native
// firmware over BLE GATT.
//
//   @wisp/sdk ── Transport ── bumble_bridge.py ══ virtual link ══ virtual controller
//   (this file)   (below)     (a GATT central)                    │ H4 over TCP
//                                                                  zephyr.exe (native_sim):
//                                                                  Zephyr's BT host, the Wisp
//                                                                  GATT service, wisp-core
//
// The firmware is the same app as the wisp_g2 image, built for native_sim/native/64; only the
// HCI driver differs (user channel over TCP instead of the EM9305 on IOM6). Run by
// scripts/test.sh, which passes the paths in WISP_E2E_EXE and WISP_E2E_BRIDGE.

import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { createWriteStream, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { after, before, test } from 'node:test';
import {
  WispError,
  WispGlasses,
  type Transport,
  type TransportReceiver,
} from '../../../../packages/wisp-sdk-ts/dist/index.js';

const exe = process.env.WISP_E2E_EXE!;
const bridgePath = process.env.WISP_E2E_BRIDGE!;
const logPath = process.env.WISP_E2E_LOG ?? '/dev/null';
assert.ok(exe && bridgePath, 'WISP_E2E_EXE and WISP_E2E_BRIDGE must be set');

type BridgeEvent = { ev: string; [k: string]: unknown };

/** The Bumble central, driven through JSON lines. */
class Bridge {
  readonly events: BridgeEvent[] = [];
  private waiters: (() => void)[] = [];
  onNotify: ((data: Uint8Array) => void) | undefined;
  onDisconnect: (() => void) | undefined;
  readonly proc: ChildProcess;

  constructor(proc: ChildProcess) {
    this.proc = proc;
    createInterface({ input: proc.stdout! }).on('line', (line) => {
      const e = JSON.parse(line) as BridgeEvent;
      if (e.ev === 'notify') {
        this.onNotify?.(Buffer.from(e.data as string, 'hex'));
        return;
      }
      if (e.ev === 'disconnected') this.onDisconnect?.();
      this.events.push(e);
      for (const w of this.waiters.splice(0)) w();
    });
  }

  send(cmd: Record<string, unknown>) {
    this.proc.stdin!.write(JSON.stringify(cmd) + '\n');
  }

  /** The first event after `from` (an index into events) that matches. */
  async next(ev: string, from = 0, ms = 15_000): Promise<BridgeEvent> {
    const end = Date.now() + ms;
    for (;;) {
      const err = this.events.slice(from).find((e) => e.ev === 'error');
      if (err) throw new Error(`bridge: ${err.message as string}`);
      const hit = this.events.slice(from).find((e) => e.ev === ev);
      if (hit) return hit;
      const left = end - Date.now();
      if (left <= 0)
        throw new Error(`no '${ev}' from the bridge within ${ms} ms`);
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, left);
        this.waiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
  }

  async scan(ms: number): Promise<number> {
    const from = this.events.length;
    this.send({ cmd: 'scan', ms });
    return (await this.next('scanned', from, ms + 5000)).wisp as number;
  }
}

/** A Transport over the bridge's GATT central: what a Node BLE transport would do. */
class BridgeTransport implements Transport {
  private receiver: TransportReceiver | undefined;
  private readonly bridge: Bridge;
  readonly mtu: number;

  constructor(bridge: Bridge, mtu: number) {
    this.bridge = bridge;
    this.mtu = mtu;
    bridge.onNotify = (data) => this.receiver?.onData(data);
    bridge.onDisconnect = () => this.receiver?.onClose();
  }
  attach(receiver: TransportReceiver) {
    this.receiver = receiver;
  }
  async write(chunk: Uint8Array) {
    assert.ok(
      chunk.length <= this.mtu,
      `chunk of ${chunk.length} > mtu ${this.mtu}`,
    );
    this.bridge.send({
      cmd: 'write',
      data: Buffer.from(chunk).toString('hex'),
    });
  }
  async close() {
    this.bridge.send({ cmd: 'disconnect' });
  }
}

let bridge: Bridge;
let firmware: ChildProcess;
const firmwareLog = () =>
  readFileSync(logPath === '/dev/null' ? '/dev/null' : logPath, 'utf8');
// Zephyr logs from a deferred thread: a line can land just after the event it precedes.
async function logMatches(pattern: RegExp, timeoutMs = 2000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  while (!pattern.test(firmwareLog()) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return firmwareLog();
}

before(async () => {
  bridge = new Bridge(
    spawn('python3', ['-I', bridgePath], {
      stdio: ['pipe', 'pipe', 'inherit'],
    }),
  );
  const { port } = await bridge.next('listening');
  firmware = spawn(exe, [`--bt-dev=127.0.0.1:${port as number}`], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const log = createWriteStream(logPath);
  firmware.stdout!.pipe(log);
  firmware.stderr!.pipe(log);
});

after(() => {
  firmware?.kill('SIGKILL');
  bridge?.proc.kill('SIGKILL');
});

let glasses: WispGlasses;
let connectedAt = 0;

test('the firmware advertises the Wisp service; a central connects at ATT MTU 247', async () => {
  const from = bridge.events.length;
  bridge.send({ cmd: 'connect' });
  const c = await bridge.next('connected', from, 30_000);
  connectedAt = Date.now();
  assert.equal(c.mtu, 247);
  assert.equal(c.name, 'Wisp');
  const props = c.props as { rx: number; tx: number };
  assert.ok(props.rx & 0x04, 'RX: write without response');
  assert.ok(props.tx & 0x10, 'TX: notify');
});

test('the SDK completes HELLO against the native build', async () => {
  glasses = await WispGlasses.connect(new BridgeTransport(bridge, 247 - 3), {
    appId: 'com.example.e2e',
    clientName: 'native-e2e',
  });
  const caps = glasses.capabilities;
  assert.deepEqual(caps.protocol, { major: 0, minor: 2 });
  assert.equal(caps.firmware.name, 'wisp-native');
  assert.equal(caps.maxFrame, 4096);
  assert.equal(caps.sessionTimeoutMs, 10_000);
  assert.deepEqual(caps.canvas, { width: 640, height: 480, bpp: 4 });
  assert.equal(caps.bits, 0, 'no drivers behind the core yet');
});

test('session requests round-trip; services without drivers answer error 1', async () => {
  const clock = await glasses.syncClock(3);
  assert.ok(clock);
  await assert.rejects(glasses.system.info(), (e: unknown) => {
    assert.ok(e instanceof WispError);
    assert.equal((e as WispError).code, 1);
    return true;
  });
});

test('frames larger than one write, past the receive window, arrive whole and in order', async () => {
  // 12 × 3000-byte requests = 36 kB through 244-byte writes: twice the 16 KiB window, so the
  // SDK has to wait for the firmware's CREDITs. Each gets its own error response, in order.
  const blob = new Uint8Array(3000).map((_, i) => i & 0xff);
  const results = await Promise.allSettled(
    Array.from({ length: 12 }, () => glasses.link.request(0x80, 1, blob)),
  );
  for (const r of results) {
    assert.equal(r.status, 'rejected');
    assert.equal((r.reason as WispError).code, 1);
  }
  const s = glasses.link.stats;
  assert.equal(
    s.resyncsReceived + s.resyncsSent + s.corrupt,
    0,
    'a clean link needs no recovery',
  );
});

test('no advertising while the session is up', async () => {
  assert.equal(await bridge.scan(1500), 0);
});

test('the firmware asks for its connection parameters (30–50 ms, latency 0, 4 s)', async () => {
  const p = await bridge.next(
    'conn_params',
    0,
    Math.max(1000, connectedAt + 8000 - Date.now()),
  );
  assert.deepEqual(
    [p.interval_min, p.interval_max, p.latency, p.timeout],
    [24, 40, 0, 400],
  );
  // the keepalive PINGs kept the session through the update
  await glasses.syncClock(1);
});

test('PINGs alone keep the session past its 10 s timeout (native-1, W25: HELLO, PING, TIME_SYNC)', async () => {
  await new Promise((resolve) => setTimeout(resolve, 12_000));
  const clock = await glasses.syncClock(2);
  assert.ok(clock);
  assert.doesNotMatch(firmwareLog(), /session ended/);
});

test('BYE ends the session; advertising resumes', async () => {
  const from = bridge.events.length;
  await glasses.close();
  await bridge.next('disconnected', from);
  assert.ok((await bridge.scan(1500)) > 0, 'advertising again');
  assert.match(
    firmwareLog(),
    /session up: app 'com\.example\.e2e' \(native-e2e\)/,
  );
  assert.match(await logMatches(/session ended/), /session ended/);
});

test('a connection without a session is dropped after 10 s', async () => {
  const from = bridge.events.length;
  bridge.send({ cmd: 'connect' });
  await bridge.next('connected', from, 30_000);
  const t0 = Date.now();
  const d = await bridge.next('disconnected', from, 15_000);
  const waited = Date.now() - t0;
  assert.ok(waited > 8000 && waited < 13_000, `dropped after ${waited} ms`);
  assert.equal(d.reason, 0x13, 'remote user terminated');
  const without = /dropping a connection without a session/;
  assert.match(await logMatches(without), without);
});
