// SPDX-License-Identifier: MIT
//
// A GATT central driven through JSON lines (bumble_bridge.py in emulation, bleak_bridge.py with
// the Mac's real radio), and the SDK Transport over it. Shared by the end-to-end test
// (e2e.test.mts) and the session tool (session.mts).

import assert from 'node:assert/strict';
import type { ChildProcess } from 'node:child_process';
import { createInterface } from 'node:readline';
import type {
  Transport,
  TransportReceiver,
} from '../../../../packages/wisp-sdk-ts/dist/index.js';

export type BridgeEvent = { ev: string; [k: string]: unknown };

/** The Bumble central, driven through JSON lines. */
export class Bridge {
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
export class BridgeTransport implements Transport {
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

