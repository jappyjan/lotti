// The stock OTA sender against a fake stock temple (testing/fake-stock-glasses.ts),
// including every failure the rung-1 flash must survive: aborts, disconnects,
// lost and corrupted replies, CRC rejections, write failures.

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { crc32cMsb } from '../crc.ts';
import {
  FakeStockGlasses,
  type FakeFaults,
} from '../testing/fake-stock-glasses.ts';
import {
  mainOnly,
  syntheticApp,
  syntheticMainPayload,
  syntheticStock,
} from '../testing/synthetic.ts';
import type { StockLink, Temple } from './link.ts';
import {
  OTA_BLOCK_SIZE,
  OtaStatus,
  OtaSubcommand,
  SID_DEV_CONFIG,
  SID_OTA_DATA,
} from './protocol.ts';
import {
  sendStockOta,
  StockOtaError,
  StockOtaTransfer,
  type StockOtaOptions,
  type StockOtaProgress,
} from './sender.ts';

// Fast timings so failure paths finish in milliseconds; the logic is the same.
const TIMING = {
  controlAckTimeoutMs: 60,
  blockAckTimeoutMs: 60,
  notifyTimeoutMs: 60,
  heartbeatIntervalMs: 1000,
  restartSettleMs: 5,
};

/** 4 blocks: three full ones and a partial last one. */
const PAYLOAD = syntheticMainPayload(
  syntheticApp({ size: 3 * OTA_BLOCK_SIZE + 0x123 }),
);
const BUNDLE = mainOnly(PAYLOAD);
const BLOCKS = Math.ceil(PAYLOAD.length / OTA_BLOCK_SIZE);

function glasses(
  faults: FakeFaults = {},
  temple: Temple = 'left',
): FakeStockGlasses {
  return new FakeStockGlasses({
    temple,
    faults,
    interPacketTimeoutMs: 30,
    restartDelayMs: 20,
  });
}

function send(
  link: StockLink,
  extra: Partial<StockOtaOptions> = {},
): Promise<Awaited<ReturnType<typeof sendStockOta>>> {
  return sendStockOta({
    temple: link.temple,
    bundle: BUNDLE,
    link,
    timing: TIMING,
    ...extra,
  });
}

async function rejects(
  promise: Promise<unknown>,
  code: string,
): Promise<StockOtaError> {
  try {
    await promise;
  } catch (error) {
    assert.ok(
      error instanceof StockOtaError,
      `expected StockOtaError, got ${String(error)}`,
    );
    assert.equal(error.code, code, error.message);
    return error;
  }
  assert.fail(`expected ${code}`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** After a failure: no install pending, a reset boots what was there before. */
function assertStockIntact(g: FakeStockGlasses): void {
  assert.equal(g.installPending, false, 'update flag must stay clear');
  g.reset();
  assert.equal(g.installed.name, 'stock', 'MRAM must still hold stock');
}

async function assertStagedAndInstalls(g: FakeStockGlasses): Promise<void> {
  assert.deepEqual(
    g.stagingFile,
    PAYLOAD,
    'staging file must equal the payload, byte for byte',
  );
  await sleep(40); // the fake resets restartDelayMs after NOTIFY
  assert.equal(g.installed.name, 'staged image');
  assert.equal(g.installed.crc32c, crc32cMsb(PAYLOAD));
}

describe('stock OTA sender: refusals (nothing is written)', () => {
  it('refuses a stock six-component bundle', async () => {
    const g = glasses();
    await rejects(send(g, { bundle: syntheticStock() }), 'not-sendable');
    assert.equal(g.written.length, 0);
  });

  it('refuses a main-only bundle with a broken CRC', async () => {
    const g = glasses();
    const broken = BUNDLE.slice();
    broken[broken.length - 100] ^= 1;
    await rejects(send(g, { bundle: broken }), 'not-sendable');
    assert.equal(g.written.length, 0);
  });

  it('refuses garbage', async () => {
    const g = glasses();
    await rejects(send(g, { bundle: new Uint8Array(1000) }), 'not-sendable');
    assert.equal(g.written.length, 0);
  });

  it('requires an explicit temple, and no "both"', async () => {
    const g = glasses();
    for (const temple of ['both', undefined, 'LEFT', '', 1]) {
      await rejects(
        sendStockOta({
          temple: temple as Temple,
          bundle: BUNDLE,
          link: g,
          timing: TIMING,
        }),
        'bad-temple',
      );
    }
    assert.equal(g.written.length, 0);
  });

  it('refuses when the link is connected to the other temple', async () => {
    const g = glasses({}, 'right');
    await rejects(
      sendStockOta({ temple: 'left', bundle: BUNDLE, link: g, timing: TIMING }),
      'temple-mismatch',
    );
    assert.equal(g.written.length, 0);
  });
});

describe('stock OTA sender: happy path', () => {
  it('runs START → INFORMATION → FILE → RESULT_CHECK → NOTIFY and stages the image', async () => {
    const g = glasses();
    const states: string[] = [];
    const result = await send(g, { onProgress: (p) => states.push(p.state) });
    assert.equal(result.outcome, 'staged');
    assert.equal(result.restartNotified, true);
    assert.equal(result.temple, 'left');
    assert.equal(result.blocks, BLOCKS);
    assert.equal(result.stats.componentAttempts, 1);
    assert.equal(result.stats.blockResends, 0);
    assert.deepEqual(
      [...new Set(states)],
      ['start', 'information', 'file', 'result-check', 'notify', 'staged'],
    );
    assert.equal(g.installPending, true);
    await assertStagedAndInstalls(g);
  });

  it('frames as stock expects: single-packet 0xC0, ≤ 240-byte packets, 0xC0 {2} before each block', async () => {
    const g = glasses();
    await send(g);
    const ota = g.written
      .filter((w) => w.channel === 'ota')
      .map((w) => w.bytes);
    assert.ok(
      ota.every(
        (p) => p.length <= 240 && p[0] === 0xaa && p[1] === 0x21 && p[7] === 0,
      ),
    );
    const control = ota.filter((p) => p[6] === 0xc0);
    assert.deepEqual(
      control.map((p) => p[8]),
      [0, 1, ...Array(BLOCKS).fill(2), 3],
    );
    assert.ok(
      control.every((p) => p[4] === 1 && p[5] === 1),
      '0xC0 is always one packet',
    );
    // INFORMATION carries the 128-byte component header.
    const info = control[1]!;
    assert.equal(info[3], 1 + 128 + 2);
    // Every block's 0xC0 {2} shares its seq with the 0xC1 packets after it.
    for (let i = 0; i < ota.length; i++) {
      if (ota[i]![6] === 0xc0 && ota[i]![8] === 2)
        assert.equal(ota[i + 1]![6], SID_OTA_DATA);
      if (ota[i]![6] === SID_OTA_DATA) assert.equal(ota[i]![2], ota[i - 1]![2]);
    }
  });

  it('progress reaches every byte', async () => {
    const g = glasses();
    let last: StockOtaProgress | null = null;
    await send(g, {
      onProgress: (p) => (last = p.state === 'file' ? p : last),
    });
    assert.equal(last!.bytesAcked, PAYLOAD.length);
    assert.equal(last!.totalBytes, PAYLOAD.length);
  });

  it('sends heartbeats on the control channel during a long transfer', async () => {
    // Every block reply is slowed down so the transfer outlasts a few heartbeat periods.
    const g = glasses();
    const slow: StockLink = {
      temple: g.temple,
      write: async (channel, packet) => {
        if (channel === 'ota' && packet[6] === SID_OTA_DATA) await sleep(8);
        return g.write(channel, packet);
      },
      subscribe: (events) => g.subscribe(events),
    };
    const result = await send(slow, {
      timing: { ...TIMING, heartbeatIntervalMs: 10 },
    });
    assert.ok(
      result.stats.heartbeats >= 2,
      `heartbeats: ${result.stats.heartbeats}`,
    );
    const beats = g.written.filter((w) => w.channel === 'control');
    assert.ok(beats.length >= 2);
    assert.ok(beats.every((b) => b.bytes[6] === SID_DEV_CONFIG));
  });

  it('a second transfer after a successful one works (START resets the session)', async () => {
    const g = glasses();
    await send(g);
    await sleep(40);
    await send(g);
    assert.equal(g.installPending, true);
  });
});

describe('stock OTA sender: aborts and disconnects leave stock intact', () => {
  it('abort mid-transfer: no flag, stock boots, a fresh transfer then succeeds', async () => {
    const g = glasses();
    const transfer = new StockOtaTransfer({
      temple: 'left',
      bundle: BUNDLE,
      link: g,
      timing: TIMING,
      onProgress: (p) => {
        if (p.state === 'file' && p.block === 2 && p.bytesAcked > 0)
          transfer.abort();
      },
    });
    const error = await rejects(transfer.run(), 'aborted');
    assert.equal(error.stockIntact, true);
    assert.equal(transfer.state, 'aborted');
    assert.ok(
      g.stagingFile!.length < PAYLOAD.length,
      'a partial staging file is left behind',
    );
    assertStockIntact(g);
    // The partial file is harmless: the next run deletes and re-creates it.
    await send(g);
    await assertStagedAndInstalls(g);
  });

  it('abort is refused once RESULT_CHECK is out', async () => {
    const g = glasses();
    let refused: boolean | null = null;
    const transfer = new StockOtaTransfer({
      temple: 'left',
      bundle: BUNDLE,
      link: g,
      timing: TIMING,
      onProgress: (p) => {
        if (p.state === 'result-check' && refused === null)
          refused = !transfer.abort();
      },
    });
    const result = await transfer.run();
    assert.equal(refused, true);
    assert.equal(result.outcome, 'staged');
  });

  it('disconnect mid-transfer: fails with stockIntact, flag clear', async () => {
    const g = glasses({
      disconnectAfter: (i) =>
        i.sid === SID_OTA_DATA && i.block === 1 && i.packet === 5,
    });
    const error = await rejects(send(g), 'disconnected');
    assert.equal(error.stockIntact, true);
    assert.equal(error.phase, 'file');
    assertStockIntact(g);
  });

  it('disconnect right after INFORMATION: stock intact', async () => {
    const g = glasses({
      disconnectAfter: (i) => i.subcommand === OtaSubcommand.information,
    });
    const error = await rejects(send(g), 'disconnected');
    assert.equal(error.stockIntact, true);
    assertStockIntact(g);
  });

  it('disconnect while waiting for the RESULT_CHECK verdict: result-unknown', async () => {
    const g = glasses({
      dropReply: (r) => r.subcommand >= OtaSubcommand.resultCheck,
      disconnectAfter: (i) => i.subcommand === OtaSubcommand.resultCheck,
    });
    const error = await rejects(send(g), 'result-unknown');
    assert.equal(error.stockIntact, 'unknown');
  });

  it('disconnect after UPDATING is the expected reset, not a failure', async () => {
    const g = glasses({
      dropReply: (r) => r.subcommand === OtaSubcommand.notify,
    });
    const result = await send(g, {
      timing: { ...TIMING, notifyTimeoutMs: 500 },
    });
    assert.equal(result.outcome, 'staged');
    assert.equal(result.restartNotified, false);
    assert.equal(result.disconnectedAfterStaging, true);
  });
});

describe('stock OTA sender: lost and bad replies', () => {
  it('lost START reply: START is resent', async () => {
    let n = 0;
    const g = glasses({
      dropReply: (r) => r.subcommand === OtaSubcommand.start && n++ === 0,
    });
    const result = await send(g);
    assert.equal(result.stats.startAttempts, 2);
    await assertStagedAndInstalls(g);
  });

  it('START never answered: start-timeout, no firmware byte sent', async () => {
    const g = glasses({
      dropReply: (r) => r.subcommand === OtaSubcommand.start,
    });
    const error = await rejects(send(g), 'start-timeout');
    assert.equal(error.stockIntact, true);
    assert.equal(
      g.written.filter((w) => w.bytes[6] === SID_OTA_DATA).length,
      0,
    );
  });

  it('START refused (filesystem heal failed): start-rejected', async () => {
    const g = glasses({ startStatus: () => OtaStatus.fail });
    const error = await rejects(send(g), 'start-rejected');
    assert.equal(error.status, OtaStatus.fail);
    assertStockIntact(g);
  });

  it('lost block ack: the block is NOT replayed in place; the component restarts from INFORMATION', async () => {
    let n = 0;
    const g = glasses({
      dropReply: (r) =>
        r.subcommand === OtaSubcommand.file && r.block === 2 && n++ === 0,
    });
    const result = await send(g);
    assert.equal(result.stats.componentAttempts, 2);
    // No duplicated block in the staged file.
    await assertStagedAndInstalls(g);
  });

  it('block ack with a wrong CRC-16 is dropped, then treated like a lost ack', async () => {
    let n = 0;
    const g = glasses({
      corruptReplyCrc: (r) =>
        r.subcommand === OtaSubcommand.file && r.block === 1 && n++ === 0,
    });
    const result = await send(g);
    assert.equal(result.stats.badReplies, 1);
    assert.equal(result.stats.componentAttempts, 2);
    await assertStagedAndInstalls(g);
  });

  it('corrupted block on the air: glasses answer CRC_ERR, the block is resent in place', async () => {
    let n = 0;
    const g = glasses({
      corruptIncoming: (i) =>
        i.sid === SID_OTA_DATA && i.block === 1 && i.packet === 3 && n++ === 0,
    });
    const result = await send(g);
    assert.equal(result.stats.blockResends, 1);
    assert.equal(result.stats.componentAttempts, 1);
    await assertStagedAndInstalls(g);
  });

  it('a lost 0xC1 packet: glasses time out the block (TIMEOUT), the block is resent in place', async () => {
    let n = 0;
    const g = glasses({
      dropIncoming: (i) =>
        i.sid === SID_OTA_DATA && i.block === 0 && i.packet === 4 && n++ === 0,
    });
    const result = await send(g);
    assert.equal(result.stats.blockResends, 1);
    await assertStagedAndInstalls(g);
  });

  it('a block rejected every time: component-failed after 3 runs, stock intact', async () => {
    const g = glasses({
      corruptIncoming: (i) =>
        i.sid === SID_OTA_DATA && i.block === 2 && i.packet === 1,
    });
    const error = await rejects(send(g), 'component-failed');
    assert.equal(error.stockIntact, true);
    assertStockIntact(g);
  });

  it('flash write error: stock deleted the file, the component restarts', async () => {
    let n = 0;
    const g = glasses({ failFlashWrite: (block) => block === 3 && n++ === 0 });
    const result = await send(g);
    assert.equal(result.stats.componentAttempts, 2);
    await assertStagedAndInstalls(g);
  });

  it('RESULT_CHECK CHECK_FAIL (CRC-32C mismatch): file deleted, flag clear, component restarts', async () => {
    let n = 0;
    const g = glasses({ corruptStorage: (block) => block === 0 && n++ === 0 });
    const flags: number[] = [];
    const result = await send(g, {
      onProgress: (p) => {
        if (p.state === 'information' && p.componentAttempt === 2)
          flags.push(g.flag);
      },
    });
    assert.deepEqual(flags, [0], 'flag stayed clear after the failed check');
    assert.equal(result.stats.componentAttempts, 2);
    await assertStagedAndInstalls(g);
  });

  it('RESULT_CHECK verdict lost but NOTIFY arrives: staged (NOTIFY follows the flag write)', async () => {
    const g = glasses({
      dropReply: (r) => r.subcommand === OtaSubcommand.resultCheck,
    });
    const result = await send(g);
    assert.equal(result.outcome, 'staged');
    assert.equal(result.restartNotified, true);
  });

  it('RESULT_CHECK verdict and NOTIFY both lost: result-unknown, never resent', async () => {
    const g = glasses({
      dropReply: (r) => r.subcommand >= OtaSubcommand.resultCheck,
    });
    const error = await rejects(send(g), 'result-unknown');
    assert.equal(error.stockIntact, 'unknown');
    const checks = g.written.filter(
      (w) => w.bytes[6] === 0xc0 && w.bytes[8] === OtaSubcommand.resultCheck,
    );
    assert.equal(checks.length, 1, 'RESULT_CHECK is sent exactly once');
  });

  it('ignores unrelated notifications on both channels', async () => {
    const g = glasses();
    const noisy: StockLink = {
      temple: g.temple,
      write: (channel, packet) => g.write(channel, packet),
      subscribe: (events) => {
        const off = g.subscribe(events);
        // A stock event on the control channel and a non-OTA sid on the OTA channel.
        events.packet(
          'control',
          Uint8Array.of(0xaa, 0x12, 1, 4, 1, 1, 0x0d, 0, 3, 7, 0, 0),
        );
        events.packet(
          'ota',
          Uint8Array.of(0xaa, 0x12, 1, 4, 1, 1, 0x80, 0, 2, 0, 0, 0),
        );
        return off;
      },
    };
    const result = await send(noisy);
    assert.equal(result.outcome, 'staged');
  });
});
