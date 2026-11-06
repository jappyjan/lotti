// Test-only bundle: the wisp-ota fake stock temple and synthetic bundles,
// driven by a host (Swift tests, the iOS Simulator's "simulated temple").
// Never shipped in a device build (apps/ios/scripts/xcode.sh copies it for
// Simulator builds only).

import { OtaSubcommand, SID_OTA_DATA } from '../../wisp-ota/src/index.ts';
import {
  FakeStockGlasses,
  type FakeFaults,
} from '../../wisp-ota/src/testing/fake-stock-glasses.ts';
import {
  syntheticApp,
  syntheticStock,
} from '../../wisp-ota/src/testing/synthetic.ts';
import { hostScheduler } from './host.ts';

export interface FakeTempleHost {
  setTimeout(timerId: number, ms: number): void;
  clearTimeout(timerId: number): void;
  now(): number;
  /** A notification from the fake temple to the phone. */
  emit(templeId: number, channel: string, bytes: Uint8Array): void;
  disconnect(templeId: number, reason: string): void;
}

/** One-shot faults, as plain JSON (each fires once). */
export interface FaultSpec {
  /** Drop the reply to this 0-based block once (the sender restarts the component). */
  dropBlockReply?: number;
  /** Drop the link right after this block's first packet arrived (mid-block). */
  disconnectAfterBlock?: number;
  /** The flash write of this block fails once (stock deletes the file, FLASH_WRITE_ERR). */
  failFlashWriteBlock?: number;
  /** Drop the RESULT_CHECK verdict and the NOTIFY (flag set, phone never hears it). */
  dropVerdict?: boolean;
  /** Status START answers with (10 = filesystem heal failed). */
  startStatus?: number;
}

function faultsFrom(spec: FaultSpec): FakeFaults {
  const fired = new Set<string>();
  const once = (key: string, hit: boolean): boolean => {
    if (!hit || fired.has(key)) return false;
    fired.add(key);
    return true;
  };
  return {
    dropReply: (r) =>
      once(
        'dropBlockReply',
        spec.dropBlockReply !== undefined &&
          r.sid === SID_OTA_DATA &&
          r.block === spec.dropBlockReply,
      ) ||
      (spec.dropVerdict === true &&
        (r.subcommand === OtaSubcommand.resultCheck ||
          r.subcommand === OtaSubcommand.notify)),
    failFlashWrite: (block) =>
      once('failFlashWriteBlock', block === spec.failFlashWriteBlock),
    disconnectAfter: (i) =>
      spec.disconnectAfterBlock !== undefined &&
      i.sid === SID_OTA_DATA &&
      i.block === spec.disconnectAfterBlock &&
      i.packet === 1 &&
      once('disconnectAfterBlock', true),
    startStatus:
      spec.startStatus === undefined ? undefined : () => spec.startStatus!,
  };
}

export function createFakeTemples(host: FakeTempleHost) {
  const timers = hostScheduler(host);
  let next = 1;
  const temples = new Map<number, FakeStockGlasses>();
  return {
    /**
     * A fake stock temple; `installed` names what MRAM holds. Options JSON:
     * `{ faults?: FaultSpec, restartDelayMs?: number }` (restart delay after NOTIFY, stock 3000).
     */
    create(temple: string, installed: string, optionsJson: string): number {
      if (temple !== 'left' && temple !== 'right')
        throw new Error('bad temple');
      const id = next++;
      const options = JSON.parse(optionsJson || '{}') as {
        faults?: FaultSpec;
        restartDelayMs?: number;
      };
      const fake = new FakeStockGlasses({
        temple,
        installed,
        scheduler: timers.scheduler,
        faults: faultsFrom(options.faults ?? {}),
        restartDelayMs: options.restartDelayMs,
      });
      fake.subscribe({
        packet: (channel, bytes) => host.emit(id, channel, bytes.slice()),
        disconnect: (reason) => host.disconnect(id, reason),
      });
      temples.set(id, fake);
      return id;
    },
    /** Phone → temple. False when the fake is not connected. */
    write(id: number, channel: string, bytes: Uint8Array): boolean {
      const fake = temples.get(id);
      if (!fake || (channel !== 'ota' && channel !== 'control')) return false;
      if (!isConnected(fake)) return false;
      // Processes the packet synchronously (no await inside); replies go out through `emit`.
      fake.write(channel, bytes.slice()).catch(() => {});
      return true;
    },
    disconnect(id: number, reason: string): void {
      temples.get(id)?.disconnect(reason);
    },
    reset(id: number): void {
      temples.get(id)?.reset();
    },
    state(id: number): string {
      const fake = temples.get(id);
      if (!fake) return 'null';
      return JSON.stringify({
        flag: fake.flag,
        installPending: fake.installPending,
        installed: fake.installed,
        stagingFileBytes: fake.stagingFile?.length ?? null,
        resets: fake.resets,
        heartbeats: fake.heartbeats,
        packetsWritten: fake.written.length,
      });
    },
    timerFired(timerId: number): void {
      timers.fire(timerId);
    },
    /** A stock-shaped synthetic bundle (codec, EM9305, touch, case, bootloader, main). */
    syntheticStock(version: string, appSize: number): Uint8Array {
      return syntheticStock(version, syntheticApp({ version, size: appSize }));
    },
  };
}

function isConnected(fake: FakeStockGlasses): boolean {
  // FakeStockGlasses keeps `connected` private (its write() rejects when false).
  return (fake as unknown as { connected: boolean }).connected;
}

export type FakeTemplesApi = ReturnType<typeof createFakeTemples>;
