// Runs the *built* bundles the way the iOS app does: each in its own bare
// context (vm, no timers, no console, no Node APIs — like a fresh JSContext),
// with a host object standing in for Swift. The sender lives in one context,
// the fake stock temple in another; packets cross through the host only, and
// notifications are delivered asynchronously like CoreBluetooth does.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import vm from 'node:vm';
import {
  mainComponents,
  parseBundle,
  parseMainImage,
  STOCK_RELEASES,
} from '../../wisp-ota/src/index.ts';
import type { FakeTemplesApi } from './fake-temple.ts';
import type { JscHost, WispOtaApi } from './host.ts';

const DIST = new URL('../dist/', import.meta.url);
const OTA_JS = readFileSync(new URL('wisp-ota.js', DIST), 'utf8');
const FAKE_JS = readFileSync(new URL('wisp-ota-fake-temple.js', DIST), 'utf8');

const TIMING = JSON.stringify({
  controlAckTimeoutMs: 80,
  blockAckTimeoutMs: 80,
  notifyTimeoutMs: 80,
  heartbeatIntervalMs: 1000,
  restartSettleMs: 5,
});

function bareContext(source: string): vm.Context {
  const context = vm.createContext({});
  vm.runInContext(source, context, { filename: 'bundle.js' });
  return context;
}

/** Bytes from another context: copy into this realm's Uint8Array. */
function own(bytes: Uint8Array): Uint8Array {
  return Uint8Array.from(bytes);
}

function sha256(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

interface Finished {
  outcome: string;
  stockIntact?: true | 'unknown';
  code?: string;
  phase?: string;
  result?: { version: string; restartNotified: boolean };
}

/** Sender context + fake-temple context, wired like the Swift side wires them. */
function rig(
  options: {
    installed?: string;
    faults?: object;
    templeSide?: string;
    /** Calls abort() from the progress callback once this many bytes are acked. */
    abortAfterBytes?: number;
  } = {},
) {
  const otaContext = bareContext(OTA_JS);
  const fakeContext = bareContext(FAKE_JS);
  const progress: { state: string; bytesAcked: number }[] = [];
  const finished = new Map<number, Finished>();
  const aborts = new Map<number, boolean>();
  let ota!: WispOtaApi;
  let fake!: FakeTemplesApi;
  let link = { transfer: 0, temple: 0 };

  const otaHost: JscHost = {
    setTimeout: (id, ms) => void setTimeout(() => ota.timerFired(id), ms),
    clearTimeout: () => {},
    now: () => Date.now(),
    write(transfer, channel, bytes, writeId) {
      const ok = fake.write(link.temple, channel, own(bytes));
      setImmediate(() => ota.writeDone(writeId, ok ? null : 'not connected'));
    },
    progress: (id, json) => {
      const p = JSON.parse(json);
      progress.push(p);
      if (
        options.abortAfterBytes !== undefined &&
        p.bytesAcked >= options.abortAfterBytes &&
        !aborts.has(id)
      ) {
        aborts.set(id, ota.abort(id));
      }
    },
    finished: (id, json) => finished.set(id, JSON.parse(json)),
  };
  ota = (otaContext.WispOta as { create(h: JscHost): WispOtaApi }).create(
    otaHost,
  );
  fake = (
    fakeContext.WispFakeTemple as { create(h: object): FakeTemplesApi }
  ).create({
    setTimeout: (id: number, ms: number) =>
      void setTimeout(() => fake.timerFired(id), ms),
    clearTimeout: () => {},
    now: () => Date.now(),
    emit: (_id: number, channel: string, bytes: Uint8Array) => {
      const copy = own(bytes);
      setImmediate(() => ota.packet(link.transfer, channel, copy));
    },
    disconnect: (_id: number, reason: string) =>
      setImmediate(() => ota.disconnected(link.transfer, reason)),
  });
  link.temple = fake.create(
    options.templeSide ?? 'left',
    options.installed ?? 'stock 2.2.6.10',
    JSON.stringify({ faults: options.faults ?? {}, restartDelayMs: 20 }),
  );

  return {
    ota,
    fake,
    progress,
    templeState: () => JSON.parse(fake.state(link.temple)),
    resetTemple: () => fake.reset(link.temple),
    stock: (version = '2.2.6.10') =>
      own(fake.syntheticStock(version, 3 * 4096 + 0x321)),
    async send(
      bundle: Uint8Array,
      temple = 'left',
      linkTemple = 'left',
    ): Promise<Finished> {
      const id = ota.startTransfer(temple, linkTemple, bundle, TIMING);
      link = { ...link, transfer: id };
      ota.run(id);
      for (let i = 0; i < 500 && !finished.has(id); i++) {
        await new Promise((r) => setTimeout(r, 10));
      }
      const result = finished.get(id);
      assert.ok(result, 'transfer did not finish');
      return result;
    },
    startOnly(bundle: Uint8Array): number {
      const id = ota.startTransfer('left', 'left', bundle, TIMING);
      link = { ...link, transfer: id };
      ota.run(id);
      return id;
    },
    finished,
    aborts,
  };
}

function releaseFor(version: string, bytes: Uint8Array) {
  const main = mainComponents(parseBundle(bytes))[0]!;
  return {
    version,
    md5: createHash('md5').update(bytes).digest('hex'),
    size: bytes.length,
    sha256: sha256(bytes),
    mainAppEnd: parseMainImage(main.payload).appEnd,
  };
}

describe('bundles in a bare context', () => {
  it('load with no timers, no console and no Node APIs', () => {
    const context = bareContext(OTA_JS);
    assert.equal(
      typeof (context.WispOta as { create: unknown }).create,
      'function',
    );
    assert.equal(vm.runInContext('typeof setTimeout', context), 'undefined');
    assert.equal(vm.runInContext('typeof process', context), 'undefined');
    const fake = bareContext(FAKE_JS);
    assert.equal(
      typeof (fake.WispFakeTemple as { create: unknown }).create,
      'function',
    );
  });

  it('the app bundle carries no fake temple', () => {
    assert.ok(!OTA_JS.includes('FakeStockGlasses'));
    assert.ok(!OTA_JS.includes('syntheticStock'));
  });

  it('exposes the pinned catalog with CDN URLs', () => {
    const { ota } = rig();
    const catalog = JSON.parse(ota.catalog()) as {
      version: string;
      sha256: string;
      url: string;
    }[];
    assert.equal(catalog.length, STOCK_RELEASES.length);
    const r = catalog.find((c) => c.version === '2.2.6.10')!;
    assert.equal(
      r.sha256,
      'f4dfb0b49ad3de3c2daf17f8a27a157c3dc98411d6a0d3ab2cfd0918f41b9afa',
    );
    assert.equal(
      r.url,
      'https://cdn.evenreal.co/firmware/e28738432d7b612d625331b00383149b.bin',
    );
  });

  it('picks a same-length rung-1 version that differs', () => {
    const { ota } = rig();
    assert.equal(ota.defaultRung1Version('2.2.6.10'), '2.2.6.19');
    assert.equal(ota.defaultRung1Version('2.3.2.19'), '2.3.2.18');
    assert.throws(() => ota.defaultRung1Version('x'));
  });
});

describe('checkStock (the `wisp-ota fetch` checks)', () => {
  const { ota, stock } = rig();
  const bytes = stock();
  const release = releaseFor('2.2.6.10', bytes);

  it('accepts a matching download and says it is not an official pin', () => {
    const out = JSON.parse(
      ota.checkStock(JSON.stringify(release), bytes, release.sha256),
    );
    assert.equal(out.version, '2.2.6.10');
    assert.equal(out.pinnedOfficial, false);
    assert.equal(out.sendable, false); // a stock bundle carries co-processor images
    assert.ok(out.failed.includes('main-only'));
  });

  it('refuses a wrong size, SHA-256, header version or app end', () => {
    const json = (r: object) => JSON.stringify({ ...release, ...r });
    assert.throws(
      () =>
        ota.checkStock(json({ size: release.size + 1 }), bytes, release.sha256),
      /pinned size/,
    );
    assert.throws(
      () => ota.checkStock(json({}), bytes, '00'.repeat(32)),
      /SHA-256/,
    );
    assert.throws(
      () =>
        ota.checkStock(json({ version: '2.2.6.11' }), bytes, release.sha256),
      /header says/,
    );
    assert.throws(
      () =>
        ota.checkStock(json({ mainAppEnd: 0x700000 }), bytes, release.sha256),
      /app end/,
    );
  });

  it('refuses synthetic bytes against a real pin', () => {
    const pinned = STOCK_RELEASES.find((r) => r.version === '2.2.6.10')!;
    assert.throws(
      () => ota.checkStock(JSON.stringify(pinned), bytes, sha256(bytes)),
      /pinned size/,
    );
  });

  it('refuses a corrupted bundle even with matching size and hash', () => {
    const broken = bytes.slice();
    broken[broken.length - 50]! ^= 1;
    const r = releaseFor('2.2.6.10', bytes);
    assert.throws(
      () =>
        ota.checkStock(
          JSON.stringify({ ...r, sha256: sha256(broken) }),
          broken,
          sha256(broken),
        ),
      /fails verification/,
    );
  });
});

describe('prepare (repack + verify + diff)', () => {
  const { ota, stock } = rig();

  it('rung 1: sendable, only version strings and CRCs changed', () => {
    const out = ota.prepareRung1(stock(), '2.2.6.19');
    const p = JSON.parse(out.json);
    assert.equal(p.kind, 'rung1');
    assert.equal(p.sendable, true);
    assert.equal(p.report.sendable, true);
    assert.equal(p.diff.ok, true);
    assert.equal(p.toVersion, '2.2.6.19');
    assert.equal(p.versionSites.length, 3);
    assert.match(p.verifyText, /sendable/i);
    assert.ok(
      p.diff.payloadChanges.every(
        (c: { kind: string }) => c.kind !== 'unexplained',
      ),
    );
    assert.equal(parseBundle(own(out.bytes)).componentCount, 1);
  });

  it('stock back: sendable, zero changed bytes', () => {
    const p = JSON.parse(ota.prepareStockBack(stock()).json);
    assert.equal(p.kind, 'stock');
    assert.equal(p.sendable, true);
    assert.equal(p.diff.payloadBytesChanged, 0);
    assert.equal(p.toVersion, '2.2.6.10');
  });

  it('refuses versions the repacker refuses', () => {
    assert.throws(
      () => ota.prepareRung1(stock(), '2.2.6.10'),
      /equals the stock version/,
    );
    assert.throws(() => ota.prepareRung1(stock(), '2.2.6.1'), /same length/);
  });
});

describe('transfer across two contexts (sender ↔ host ↔ fake temple)', () => {
  it('rung 1 then pure stock back: both staged and installed', async () => {
    const r = rig();
    const stock = r.stock();
    const rung1 = own(r.ota.prepareRung1(stock, '2.2.6.19').bytes);
    const first = await r.send(rung1);
    assert.equal(first.outcome, 'staged', JSON.stringify(first));
    assert.equal(first.result?.version, 's200_v2.2.6.19');
    await new Promise((res) => setTimeout(res, 50));
    const afterFirst = r.templeState();
    assert.equal(afterFirst.installed.name, 'staged image');
    assert.ok(r.progress.some((p) => p.state === 'file' && p.bytesAcked > 0));

    const back = own(r.ota.prepareStockBack(stock).bytes);
    const second = await r.send(back);
    assert.equal(second.outcome, 'staged');
    assert.equal(second.result?.version, 's200_v2.2.6.10');
    await new Promise((res) => setTimeout(res, 50));
    const main = mainComponents(parseBundle(stock)).at(0)!;
    assert.equal(r.templeState().installed.crc32c, main.toc.crc32c);
  });

  it('abort before RESULT_CHECK: aborted, stock intact, boots stock', async () => {
    const r = rig({ abortAfterBytes: 4096 });
    const f = await r.send(
      own(r.ota.prepareRung1(r.stock(), '2.2.6.19').bytes),
    );
    assert.deepEqual([...r.aborts.values()], [true]);
    assert.equal(f.outcome, 'aborted');
    assert.equal(f.stockIntact, true);
    r.resetTemple();
    const s = r.templeState();
    assert.equal(s.installPending, false);
    assert.equal(s.installed.name, 'stock 2.2.6.10');
  });

  it('abort is refused once RESULT_CHECK is out', async () => {
    const r = rig({ faults: { dropVerdict: true } });
    let refused: boolean | undefined;
    const bundle = own(r.ota.prepareRung1(r.stock(), '2.2.6.19').bytes);
    const id = r.startOnly(bundle);
    // Time-bounded, not tick-bounded: slow CI runners need many more ticks to send the file.
    const deadline = Date.now() + 10_000;
    while (r.ota.state(id) !== 'result-check' && Date.now() < deadline) {
      await new Promise((res) => setImmediate(res));
    }
    assert.equal(r.ota.state(id), 'result-check');
    refused = r.ota.abort(id);
    assert.equal(refused, false);
    for (let i = 0; i < 100 && !r.finished.has(id); i++)
      await new Promise((res) => setTimeout(res, 10));
    assert.equal(r.finished.get(id)?.stockIntact, 'unknown');
  });

  it('disconnect mid-block: failed, stock intact', async () => {
    const r = rig({ faults: { disconnectAfterBlock: 1 } });
    const f = await r.send(
      own(r.ota.prepareRung1(r.stock(), '2.2.6.19').bytes),
    );
    assert.equal(f.outcome, 'failed');
    assert.equal(f.code, 'disconnected');
    assert.equal(f.stockIntact, true);
    r.resetTemple();
    assert.equal(r.templeState().installed.name, 'stock 2.2.6.10');
  });

  it('lost block reply: the component restarts and still stages', async () => {
    const r = rig({ faults: { dropBlockReply: 2 } });
    const f = await r.send(
      own(r.ota.prepareRung1(r.stock(), '2.2.6.19').bytes),
    );
    assert.equal(f.outcome, 'staged');
  });

  it('lost RESULT_CHECK verdict: result unknown (never "success" or "intact")', async () => {
    const r = rig({ faults: { dropVerdict: true } });
    const f = await r.send(
      own(r.ota.prepareRung1(r.stock(), '2.2.6.19').bytes),
    );
    assert.equal(f.outcome, 'failed');
    assert.equal(f.code, 'result-unknown');
    assert.equal(f.stockIntact, 'unknown');
  });

  it('refuses a full stock bundle before touching the link', () => {
    const r = rig();
    assert.throws(
      () => r.startOnly(r.stock()),
      (e: Error) => {
        const j = JSON.parse(e.message);
        return j.code === 'not-sendable' && j.stockIntact === true;
      },
    );
    assert.equal(r.templeState().packetsWritten, 0);
  });

  it('refuses a temple mismatch and "both"', () => {
    const r = rig();
    const bundle = own(r.ota.prepareRung1(r.stock(), '2.2.6.19').bytes);
    assert.throws(
      () => r.ota.startTransfer('right', 'left', bundle, TIMING),
      /temple-mismatch/,
    );
    assert.throws(
      () => r.ota.startTransfer('both', 'left', bundle, TIMING),
      /bad-temple/,
    );
    assert.throws(
      () => r.ota.startTransfer('left', 'both', bundle, TIMING),
      /link temple/,
    );
    assert.equal(r.templeState().packetsWritten, 0);
  });
});
