// @wisp/ota inside JavaScriptCore (the Lotti iOS app's "Wisp update" screen).
//
// The guards, the repacker and the stock OTA sender stay single-source: this
// file only adapts them to a host that has no timers, no fetch, no crypto and
// no Promise-returning I/O of its own. The host (Swift) provides:
//   - timers (setTimeout / clearTimeout / now),
//   - one StockLink per transfer: `write` hands a packet to the radio and is
//     answered later with `writeDone`; notifications come in through `packet`
//     and `disconnected`,
//   - progress and the final outcome through `progress` / `finished`.
// Bytes cross the boundary as Uint8Array; everything else as JSON strings.
// Nothing here weakens a guard: every bundle a transfer gets is checked again
// by the sender itself (verifyBundle → sendable) before it touches the link.

import {
  diffRepack,
  formatDiff,
  formatInspect,
  formatVerify,
  mainComponents,
  parseBundle,
  parseMainImage,
  repackMain,
  STOCK_RELEASES,
  stockMainOnly,
  stockReleaseUrl,
  stockVersionFromHeader,
  StockOtaError,
  StockOtaTransfer,
  TEMPLES,
  verifyBundle,
  type RepackDiff,
  type Scheduler,
  type StockChannel,
  type StockLink,
  type StockLinkEvents,
  type StockOtaTiming,
  type StockRelease,
  type Temple,
  type VerifyReport,
} from '../../wisp-ota/src/index.ts';

/** What Swift provides. Every method is synchronous; answers come back through the API. */
export interface JscHost {
  setTimeout(timerId: number, ms: number): void;
  clearTimeout(timerId: number): void;
  now(): number;
  /** Hand `bytes` to the radio for `transferId`; answer with `api.writeDone(writeId, error)`. */
  write(
    transferId: number,
    channel: StockChannel,
    bytes: Uint8Array,
    writeId: number,
  ): void;
  progress(transferId: number, json: string): void;
  finished(transferId: number, json: string): void;
}

export interface BytesResult {
  json: string;
  bytes: Uint8Array;
}

/** A host-driven Scheduler: the sender and the fake temple both run on it. */
export function hostScheduler(host: {
  setTimeout(timerId: number, ms: number): void;
  clearTimeout(timerId: number): void;
  now(): number;
}): { scheduler: Scheduler; fire(timerId: number): void } {
  let next = 1;
  const callbacks = new Map<number, () => void>();
  return {
    scheduler: {
      setTimeout(callback, ms) {
        const id = next++;
        callbacks.set(id, callback);
        host.setTimeout(id, Math.max(0, ms));
        return id;
      },
      clearTimeout(handle) {
        const id = handle as number;
        if (callbacks.delete(id)) host.clearTimeout(id);
      },
      now: () => host.now(),
    },
    fire(timerId) {
      const callback = callbacks.get(timerId);
      if (!callback) return;
      callbacks.delete(timerId);
      callback();
    },
  };
}

/** Rung-1 default: same length, last digit changed (2.2.6.10 → 2.2.6.19), so the version shows the repack. */
export function defaultRung1Version(stockVersion: string): string {
  const last = stockVersion.at(-1);
  if (last === undefined || !/\d/.test(last)) {
    throw new Error(`"${stockVersion}" is not a stock version`);
  }
  return stockVersion.slice(0, -1) + (last === '9' ? '8' : '9');
}

function isRelease(value: unknown): value is StockRelease {
  const r = value as StockRelease;
  return (
    typeof r === 'object' &&
    r !== null &&
    typeof r.version === 'string' &&
    typeof r.md5 === 'string' &&
    typeof r.sha256 === 'string' &&
    Number.isInteger(r.size) &&
    Number.isInteger(r.mainAppEnd)
  );
}

/**
 * The checks `wisp-ota fetch` runs on a download (node/stock-cache.ts), for a
 * host that computed the SHA-256 itself: pinned size, pinned SHA-256, the main
 * app end webflasher computed, the header version, and every integrity guard.
 * `pinnedOfficial` says whether `release` is byte-for-byte a catalog entry.
 */
export function checkStock(
  release: StockRelease,
  bytes: Uint8Array,
  sha256Hex: string,
): string {
  if (!isRelease(release)) throw new Error('malformed release record');
  if (bytes.length !== release.size) {
    throw new Error(
      `${bytes.length} bytes, pinned size is ${release.size}; not using it`,
    );
  }
  const digest = sha256Hex.toLowerCase();
  if (digest !== release.sha256) {
    throw new Error(
      `SHA-256 ${digest} does not match the pinned ${release.sha256}; not using it`,
    );
  }
  const report = verifyBundle(bytes);
  if (!report.ok) {
    throw new Error(
      `bundle fails verification (${report.failed.join(', ')}); not using it`,
    );
  }
  const parsed = parseBundle(bytes);
  const header = stockVersionFromHeader(parsed.version.text);
  if (header !== release.version) {
    throw new Error(
      `bundle header says ${header}, expected ${release.version}`,
    );
  }
  const main = mainComponents(parsed)[0];
  if (!main) throw new Error('bundle has no main component');
  const end = parseMainImage(main.payload).appEnd;
  if (end !== release.mainAppEnd) {
    throw new Error(
      `main app end 0x${end.toString(16)} differs from the catalog's 0x${release.mainAppEnd.toString(16)}`,
    );
  }
  const pinned = STOCK_RELEASES.find((r) => r.version === release.version);
  const pinnedOfficial =
    pinned !== undefined &&
    pinned.sha256 === release.sha256 &&
    pinned.size === release.size &&
    pinned.md5 === release.md5 &&
    pinned.mainAppEnd === release.mainAppEnd;
  return JSON.stringify({
    version: header,
    size: bytes.length,
    sha256: digest,
    pinnedOfficial,
    sendable: report.sendable,
    failed: report.failed,
    inspect: formatInspect(bytes),
  });
}

export type PreparedKind = 'rung1' | 'stock';

export interface Prepared {
  kind: PreparedKind;
  fromVersion: string;
  toVersion: string;
  /** verifyBundle on a fresh copy of the output; must be sendable. */
  report: VerifyReport;
  /** diffRepack(stock, output), run again here; must be ok. */
  diff: RepackDiff;
  versionSites: number[];
  verifyText: string;
  diffText: string;
  /** What the screen shows as the guard report. */
  sendable: boolean;
  /** CRC-32C of the main payload (what the temple will hold after the install). */
  mainCrc32c: string;
}

function prepared(
  kind: PreparedKind,
  stock: Uint8Array,
  bytes: Uint8Array,
  fromVersion: string,
  toVersion: string,
  versionSites: number[],
): BytesResult {
  // Independent of what the packer already checked: from scratch, on a copy.
  const report = verifyBundle(bytes.slice());
  const diff = diffRepack(stock, bytes);
  const onlyAllowed =
    diff.ok &&
    (kind === 'rung1'
      ? diff.payloadChanges.every((c) => c.kind !== 'unexplained')
      : diff.payloadBytesChanged === 0 &&
        diff.componentHeaderChanges.length === 0);
  const result: Prepared = {
    kind,
    fromVersion,
    toVersion,
    report,
    diff,
    versionSites,
    verifyText: formatVerify(report),
    diffText: formatDiff(diff),
    sendable: report.sendable && onlyAllowed,
    mainCrc32c: diff.crc32c.to,
  };
  return { json: JSON.stringify(result), bytes };
}

/** Rung 1: `repack-main`, then verify + structural diff again. Throws on any refusal. */
export function prepareRung1(
  stock: Uint8Array,
  newVersion: string,
): BytesResult {
  const r = repackMain(stock, newVersion);
  return prepared(
    'rung1',
    stock,
    r.bytes,
    r.fromVersion,
    r.toVersion,
    r.versionSites,
  );
}

/** The round trip back: the unchanged stock main as a main-only bundle. */
export function prepareStockBack(stock: Uint8Array): BytesResult {
  const r = stockMainOnly(stock);
  return prepared('stock', stock, r.bytes, r.version, r.version, []);
}

export interface FinishedJson {
  outcome: 'staged' | 'failed' | 'aborted';
  /** `true` or `'unknown'` (staged: not applicable). */
  stockIntact?: true | 'unknown';
  code?: string;
  phase?: string;
  status?: number;
  message?: string;
  result?: unknown;
}

function errorJson(error: unknown): FinishedJson {
  if (error instanceof StockOtaError) {
    return {
      outcome: error.code === 'aborted' ? 'aborted' : 'failed',
      stockIntact: error.stockIntact,
      code: error.code,
      phase: error.phase,
      status: error.status,
      message: error.message,
    };
  }
  // Not a sender error: we cannot prove anything about the temple.
  return {
    outcome: 'failed',
    stockIntact: 'unknown',
    code: 'internal',
    message: error instanceof Error ? error.message : String(error),
  };
}

export function createWispOta(host: JscHost) {
  const timers = hostScheduler(host);
  let nextTransfer = 1;
  let nextWrite = 1;
  const writes = new Map<
    number,
    { resolve: () => void; reject: (e: Error) => void }
  >();
  const transfers = new Map<
    number,
    {
      transfer: StockOtaTransfer;
      events: StockLinkEvents[];
      started: boolean;
      done: boolean;
    }
  >();

  return {
    apiVersion: 1,

    catalog(): string {
      return JSON.stringify(
        STOCK_RELEASES.map((r) => ({ ...r, url: stockReleaseUrl(r) })),
      );
    },

    checkStock(
      releaseJson: string,
      bytes: Uint8Array,
      sha256Hex: string,
    ): string {
      return checkStock(JSON.parse(releaseJson), bytes, sha256Hex);
    },

    verify(bytes: Uint8Array): string {
      const report = verifyBundle(bytes);
      return JSON.stringify({ report, text: formatVerify(report) });
    },

    defaultRung1Version,
    prepareRung1,
    prepareStockBack,

    /**
     * Creates one transfer to one temple; `run(id)` starts it. Throws
     * (StockOtaError JSON in the message) when the sender refuses before
     * touching the link.
     */
    startTransfer(
      temple: string,
      linkTemple: string,
      bundle: Uint8Array,
      timingJson: string,
    ): number {
      if (!TEMPLES.includes(linkTemple as Temple)) {
        throw new Error(
          `link temple must be "left" or "right", got ${linkTemple}`,
        );
      }
      const id = nextTransfer++;
      const events: StockLinkEvents[] = [];
      const link: StockLink = {
        temple: linkTemple as Temple,
        write(channel, packet) {
          return new Promise<void>((resolve, reject) => {
            const writeId = nextWrite++;
            writes.set(writeId, { resolve, reject });
            host.write(id, channel, packet, writeId);
          });
        },
        subscribe(handlers) {
          events.push(handlers);
          return () => {
            const at = events.indexOf(handlers);
            if (at >= 0) events.splice(at, 1);
          };
        },
      };
      let transfer: StockOtaTransfer;
      try {
        transfer = new StockOtaTransfer({
          temple: temple as Temple,
          bundle,
          link,
          scheduler: timers.scheduler,
          timing: JSON.parse(timingJson || '{}') as Partial<StockOtaTiming>,
          onProgress: (p) => host.progress(id, JSON.stringify(p)),
        });
      } catch (error) {
        throw new Error(JSON.stringify(errorJson(error)));
      }
      transfers.set(id, { transfer, events, started: false, done: false });
      return id;
    },

    /**
     * Runs a transfer created by `startTransfer`. Separate so the host can
     * register the id before the first `write` arrives.
     */
    run(transferId: number): void {
      const entry = transfers.get(transferId);
      if (!entry || entry.started) return;
      entry.started = true;
      entry.transfer.run().then(
        (result) => {
          entry.done = true;
          const json: FinishedJson = { outcome: 'staged', result };
          host.finished(transferId, JSON.stringify(json));
        },
        (error: unknown) => {
          entry.done = true;
          host.finished(transferId, JSON.stringify(errorJson(error)));
        },
      );
    },

    /** Only before RESULT_CHECK (the sender decides); false afterwards. */
    abort(transferId: number): boolean {
      return transfers.get(transferId)?.transfer.abort() ?? false;
    },

    state(transferId: number): string {
      return transfers.get(transferId)?.transfer.state ?? 'unknown';
    },

    packet(transferId: number, channel: string, bytes: Uint8Array): void {
      const entry = transfers.get(transferId);
      if (!entry || (channel !== 'ota' && channel !== 'control')) return;
      for (const e of [...entry.events]) e.packet(channel, bytes);
    },

    disconnected(transferId: number, reason: string): void {
      const entry = transfers.get(transferId);
      if (!entry) return;
      for (const e of [...entry.events]) e.disconnect(reason);
    },

    writeDone(writeId: number, error: string | null): void {
      const pending = writes.get(writeId);
      if (!pending) return;
      writes.delete(writeId);
      if (error === null || error === undefined) pending.resolve();
      else pending.reject(new Error(error));
    },

    timerFired(timerId: number): void {
      timers.fire(timerId);
    },

    /** Forget a finished transfer. */
    release(transferId: number): void {
      const entry = transfers.get(transferId);
      if (entry?.done) transfers.delete(transferId);
    },
  };
}

export type WispOtaApi = ReturnType<typeof createWispOta>;
