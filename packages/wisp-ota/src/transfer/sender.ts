// Stock OTA sender: phone → one temple, over the stock 0xC0/0xC1 import
// protocol (protocol.ts), as a transport-agnostic state machine over a
// StockLink. This is the rung-1 path of docs/wisp/safety.md: it only ever sends
// a bundle that verifyBundle() reports sendable (main-only, every guard green).
// There is no option to skip that check and none will be added.
//
//   idle → start → information → file → result-check → notify → staged
//                      ↑___________ restart _________|        (≤ 3 component runs)
//   any state before result-check → failed | aborted, stock intact
//
// Why an interrupted transfer leaves stock intact (openCFW
// `ota_service_file_parse.c`, docs/wisp/hardware.md "Boot and update chain"):
// the stock app writes the main image only into the littlefs staging file
// `ota/s200_firmware_ota.bin` on the external NOR, never into MRAM. The
// bootloader installs that file only when the update flag at 0x7FE000 reads
// 0x55555555, and the app writes the flag in exactly one place: RESULT_CHECK,
// after the closed file's size and CRC-32C match the header. Until RESULT_CHECK
// is sent the flag cannot be set, so a disconnect, an abort or a failed block
// leaves a partial staging file that nothing reads; the next START / INFORMATION
// deletes and re-creates it. A CRC mismatch at RESULT_CHECK deletes the file.

import { verifyBundle, type VerifyReport } from '../guards.ts';
import { mainComponents, parseBundle } from '../parse.ts';
import { COMPONENT_HEADER_SIZE } from '../constants.ts';
import {
  BLOCK_RETRYABLE_STATUSES,
  DEFAULT_TIMING,
  HEARTBEAT_PAYLOAD,
  LIMITS,
  OTA_BLOCK_SIZE,
  OTA_HEADER_SIZE,
  OtaStatus,
  OtaSubcommand,
  SID_DEV_CONFIG,
  SID_OTA_CONTROL,
  SID_OTA_DATA,
  otaStatusName,
  type StockOtaTiming,
} from './protocol.ts';
import {
  systemScheduler,
  TEMPLES,
  type Scheduler,
  type StockChannel,
  type StockLink,
  type Temple,
} from './link.ts';
import { encodeTpl, TPL_FROM_GLASSES, TplAssembler } from './tpl.ts';

export type StockOtaPhase =
  'start' | 'information' | 'file' | 'result-check' | 'notify';

export type StockOtaState =
  'idle' | StockOtaPhase | 'staged' | 'failed' | 'aborted';

export type StockOtaErrorCode =
  /** Refused before touching the link: the bundle is not sendable. */
  | 'not-sendable'
  /** Refused before touching the link: temple is not exactly "left" or "right". */
  | 'bad-temple'
  /** Refused before touching the link: the link is connected to the other temple. */
  | 'temple-mismatch'
  /** `run()` called twice. */
  | 'busy'
  | 'start-timeout'
  | 'start-rejected'
  | 'information-rejected'
  /** Every component run ended in a restartable failure. */
  | 'component-failed'
  /** RESULT_CHECK went out but no verdict came back: the flag may or may not be set. */
  | 'result-unknown'
  | 'unexpected-reply'
  | 'disconnected'
  | 'write-failed'
  | 'aborted';

/**
 * `true`: the running image is untouched and no install is pending (the update
 * flag was never set). `'unknown'`: RESULT_CHECK was sent and its verdict was
 * lost; reconnect and read the version before doing anything else.
 */
export type StockIntact = true | 'unknown';

export class StockOtaError extends Error {
  override name = 'StockOtaError';
  constructor(
    readonly code: StockOtaErrorCode,
    message: string,
    readonly stockIntact: StockIntact,
    readonly phase: StockOtaState,
    readonly status?: number,
  ) {
    super(message);
  }
}

export interface StockOtaProgress {
  temple: Temple;
  state: StockOtaState;
  /** Payload bytes the glasses acknowledged in the current component run. */
  bytesAcked: number;
  totalBytes: number;
  /** Next block to send (0-based) and the block count. */
  block: number;
  blocks: number;
  componentAttempt: number;
}

export interface StockOtaStats {
  componentAttempts: number;
  startAttempts: number;
  /** Blocks sent again after an explicit transport NAK. */
  blockResends: number;
  /** Replies with a bad CRC-16, dropped. */
  badReplies: number;
  heartbeats: number;
}

export interface StockOtaResult {
  temple: Temple;
  /**
   * `staged`: the glasses accepted the image (RESULT_CHECK → UPDATING), so the
   * update flag is set and the Even bootloader installs it on the reset that
   * follows. Whether it booted is for the caller to check after reconnecting.
   */
  outcome: 'staged';
  /** NOTIFY `{4, SYS_RESTART}` arrived. */
  restartNotified: boolean;
  /** The link dropped after staging (the expected reset). */
  disconnectedAfterStaging: boolean;
  version: string;
  payloadBytes: number;
  blocks: number;
  stats: StockOtaStats;
}

export interface StockOtaOptions {
  /** Required, and must match `link.temple`. One temple per transfer. */
  temple: Temple;
  bundle: Uint8Array;
  link: StockLink;
  onProgress?: (progress: StockOtaProgress) => void;
  timing?: Partial<StockOtaTiming>;
  scheduler?: Scheduler;
}

interface Reply {
  sid: number;
  seq: number;
  subcommand: number;
  status: number;
}

/** A failure that ends one component run; the next run starts again at INFORMATION. */
class Restart extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
  }
}

class ReplyTimeout extends Error {}

function assertTemple(temple: unknown): asserts temple is Temple {
  if (typeof temple !== 'string' || !TEMPLES.includes(temple as Temple)) {
    throw new StockOtaError(
      'bad-temple',
      `temple must be "left" or "right" (one temple per transfer), got ${JSON.stringify(temple)}`,
      true,
      'idle',
    );
  }
}

/** Checks everything that can be checked offline. Throws `StockOtaError`; never touches a link. */
export function prepareStockOta(
  temple: unknown,
  bundle: Uint8Array,
): { report: VerifyReport; header: Uint8Array; payload: Uint8Array } {
  assertTemple(temple);
  const report = verifyBundle(bundle);
  if (!report.sendable) {
    throw new StockOtaError(
      'not-sendable',
      `bundle is not sendable (${report.failed.join(', ') || 'incomplete guard report'}); only main-only bundles that pass every guard are sent`,
      true,
      'idle',
    );
  }
  const parsed = parseBundle(bundle);
  const mains = mainComponents(parsed);
  if (parsed.components.length !== 1 || mains.length !== 1) {
    // verifyBundle already guarantees this; checked again because it is the brick rule.
    throw new StockOtaError(
      'not-sendable',
      'bundle is not main-only',
      true,
      'idle',
    );
  }
  const main = mains[0]!;
  const header = bundle.slice(
    main.toc.offset,
    main.toc.offset + COMPONENT_HEADER_SIZE,
  );
  if (header.length !== OTA_HEADER_SIZE) {
    throw new StockOtaError(
      'not-sendable',
      'component header is not 128 bytes',
      true,
      'idle',
    );
  }
  return { report, header, payload: main.payload.slice() };
}

export class StockOtaTransfer {
  readonly temple: Temple;
  private readonly link: StockLink;
  private readonly timing: StockOtaTiming;
  private readonly scheduler: Scheduler;
  private readonly onProgress?: (progress: StockOtaProgress) => void;
  private readonly header: Uint8Array;
  private readonly payload: Uint8Array;
  private readonly version: string;
  private readonly blocks: number;

  private _state: StockOtaState = 'idle';
  private started = false;
  private seq = 0;
  private controlSeq = 0;
  private writeTail: Promise<void> = Promise.resolve();
  private readonly assembler = new TplAssembler();
  private replies: Reply[] = [];
  private waiter: {
    match: (r: Reply) => boolean;
    resolve: (r: Reply) => void;
  } | null = null;
  private readonly cancels = new Set<(error: Error) => void>();
  private interrupt: StockOtaError | null = null;
  private disconnected: string | null = null;
  /** UPDATING or NOTIFY seen: the glasses set the flag; a disconnect from here on is the reset. */
  private stagedSeen = false;
  private heartbeatTimer: unknown = null;
  private bytesAcked = 0;
  private block = 0;
  private componentAttempt = 0;
  private readonly stats: StockOtaStats = {
    componentAttempts: 0,
    startAttempts: 0,
    blockResends: 0,
    badReplies: 0,
    heartbeats: 0,
  };

  constructor(options: StockOtaOptions) {
    const { header, payload, report } = prepareStockOta(
      options.temple,
      options.bundle,
    );
    if (options.link.temple !== options.temple) {
      throw new StockOtaError(
        'temple-mismatch',
        `asked to flash the ${options.temple} temple but the link is connected to the ${String(options.link.temple)} temple`,
        true,
        'idle',
      );
    }
    this.temple = options.temple;
    this.link = options.link;
    this.timing = { ...DEFAULT_TIMING, ...options.timing };
    this.scheduler = options.scheduler ?? systemScheduler;
    this.onProgress = options.onProgress;
    this.header = header;
    this.payload = payload;
    this.version = report.bundle?.version ?? '';
    this.blocks = Math.ceil(payload.length / OTA_BLOCK_SIZE);
  }

  get state(): StockOtaState {
    return this._state;
  }

  /**
   * Stops the transfer at the next step. Allowed only before RESULT_CHECK is
   * sent (returns false afterwards: the decisive command is already out, and
   * walking away then would only lose its verdict). An aborted transfer leaves
   * stock intact.
   */
  abort(): boolean {
    if (
      this.interrupt ||
      ['result-check', 'notify', 'staged', 'failed', 'aborted'].includes(
        this._state,
      )
    ) {
      return false;
    }
    this.fail(
      new StockOtaError(
        'aborted',
        `${this.temple}: transfer aborted`,
        true,
        this._state,
      ),
    );
    return true;
  }

  async run(): Promise<StockOtaResult> {
    if (this.started) {
      throw new StockOtaError(
        'busy',
        'a StockOtaTransfer runs once',
        true,
        this._state,
      );
    }
    this.started = true;
    const unsubscribe = this.link.subscribe({
      packet: (channel, bytes) => this.onPacket(channel, bytes),
      disconnect: (reason) => this.onDisconnect(reason),
    });
    this.startHeartbeat();
    try {
      await this.sendStart();
      await this.sendComponent();
      return await this.awaitNotify();
    } catch (error) {
      const failure = this.asFailure(error);
      this._state = failure.code === 'aborted' ? 'aborted' : 'failed';
      this.emit();
      throw failure;
    } finally {
      this.stopHeartbeat();
      for (const cancel of this.cancels) cancel(new Error('transfer finished'));
      this.cancels.clear();
      unsubscribe();
    }
  }

  // --- phases ---------------------------------------------------------------

  private async sendStart(): Promise<void> {
    this.enter('start');
    for (let attempt = 1; ; attempt++) {
      this.stats.startAttempts = attempt;
      try {
        // START is idempotent on the glasses (it resets the import state), so
        // a lost reply may be answered by sending it again.
        const reply = await this.control(
          OtaSubcommand.start,
          [],
          this.timing.controlAckTimeoutMs,
        );
        if (reply.status !== OtaStatus.success) {
          throw new StockOtaError(
            'start-rejected',
            `${this.temple}: START refused with ${otaStatusName(reply.status)} (stock filesystem check failed or a stale file could not be closed)`,
            true,
            'start',
            reply.status,
          );
        }
        return;
      } catch (error) {
        if (error instanceof ReplyTimeout && attempt < LIMITS.startAttempts)
          continue;
        if (error instanceof ReplyTimeout) {
          throw new StockOtaError(
            'start-timeout',
            `${this.temple}: no reply to START after ${attempt} attempts; no firmware byte was sent`,
            true,
            'start',
          );
        }
        throw error;
      }
    }
  }

  private async sendComponent(): Promise<void> {
    let last: Restart | null = null;
    for (let attempt = 1; attempt <= LIMITS.componentAttempts; attempt++) {
      this.componentAttempt = attempt;
      this.stats.componentAttempts = attempt;
      if (attempt > 1) {
        // Let the receiver's 1500 ms reassembly timeout pass and stale replies
        // arrive, so they are drained instead of matched to the next request.
        await this.sleep(this.timing.restartSettleMs);
      }
      try {
        await this.sendInformation();
        await this.sendBlocks();
        await this.sendResultCheck();
        return;
      } catch (error) {
        if (!(error instanceof Restart)) throw error;
        last = error;
      }
    }
    throw new StockOtaError(
      'component-failed',
      `${this.temple}: gave up after ${LIMITS.componentAttempts} component runs: ${last?.message ?? 'unknown'}`,
      true,
      this._state,
      last?.status,
    );
  }

  private async sendInformation(): Promise<void> {
    this.enter('information');
    this.bytesAcked = 0;
    this.block = 0;
    let reply: Reply;
    try {
      reply = await this.control(
        OtaSubcommand.information,
        this.header,
        this.timing.controlAckTimeoutMs,
      );
    } catch (error) {
      if (error instanceof ReplyTimeout)
        throw new Restart('no reply to INFORMATION');
      throw error;
    }
    if (reply.status === OtaStatus.success) return;
    if (reply.status === OtaStatus.flashWriteError) {
      throw new Restart(
        'INFORMATION: staging file could not be created',
        reply.status,
      );
    }
    throw new StockOtaError(
      'information-rejected',
      `${this.temple}: INFORMATION refused with ${otaStatusName(reply.status)}`,
      true,
      'information',
      reply.status,
    );
  }

  private async sendBlocks(): Promise<void> {
    this.enter('file');
    for (this.block = 0; this.block < this.blocks; this.block++) {
      const data = this.payload.subarray(
        this.block * OTA_BLOCK_SIZE,
        (this.block + 1) * OTA_BLOCK_SIZE,
      );
      let accepted = false;
      for (let attempt = 1; attempt <= LIMITS.blockAttempts; attempt++) {
        if (attempt > 1) this.stats.blockResends++;
        let reply: Reply;
        try {
          reply = await this.sendBlock(data);
        } catch (error) {
          // The block may or may not have been written: resending it could
          // append it twice, so the whole component starts over.
          if (error instanceof ReplyTimeout)
            throw new Restart(`no reply to block ${this.block}`);
          throw error;
        }
        if (reply.status === OtaStatus.success) {
          accepted = true;
          break;
        }
        if (BLOCK_RETRYABLE_STATUSES.has(reply.status)) continue;
        // FLASH_WRITE_ERR: stock deleted the staging file. Anything else is unknown.
        throw new Restart(
          `block ${this.block} refused with ${otaStatusName(reply.status)}`,
          reply.status,
        );
      }
      if (!accepted) {
        throw new Restart(
          `block ${this.block} rejected ${LIMITS.blockAttempts} times`,
        );
      }
      this.bytesAcked += data.length;
      this.emit();
    }
  }

  private async sendResultCheck(): Promise<void> {
    this.enter('result-check');
    let reply: Reply;
    try {
      reply = await this.control(
        OtaSubcommand.resultCheck,
        [],
        this.timing.controlAckTimeoutMs,
        [OtaSubcommand.resultCheck, OtaSubcommand.notify],
      );
    } catch (error) {
      if (error instanceof ReplyTimeout) {
        throw new StockOtaError(
          'result-unknown',
          `${this.temple}: no verdict for RESULT_CHECK; the update flag may be set. Reconnect and read the firmware version before anything else`,
          'unknown',
          'result-check',
        );
      }
      throw error;
    }
    // {4, SYS_RESTART} is only sent after the flag write, so it proves UPDATING too.
    if (
      reply.subcommand === OtaSubcommand.notify ||
      reply.status === OtaStatus.updating
    ) {
      if (reply.subcommand === OtaSubcommand.notify)
        this.replies.unshift(reply);
      return;
    }
    if (reply.status === OtaStatus.checkFail) {
      // Stock deleted the staging file and left the flag alone.
      throw new Restart('RESULT_CHECK: size or CRC-32C mismatch', reply.status);
    }
    throw new StockOtaError(
      'unexpected-reply',
      `${this.temple}: RESULT_CHECK answered ${otaStatusName(reply.status)}, expected UPDATING`,
      'unknown',
      'result-check',
      reply.status,
    );
  }

  private async awaitNotify(): Promise<StockOtaResult> {
    this.enter('notify');
    let restartNotified = false;
    try {
      const reply = await this.waitReply(
        [OtaSubcommand.notify],
        this.timing.notifyTimeoutMs,
      );
      restartNotified = reply.status === OtaStatus.sysRestart;
    } catch (error) {
      // The image is staged either way; a reset may simply have beaten the notify.
      if (!(error instanceof ReplyTimeout) && !this.disconnected) throw error;
    }
    this.enter('staged');
    return {
      temple: this.temple,
      outcome: 'staged',
      restartNotified,
      disconnectedAfterStaging: this.disconnected !== null,
      version: this.version,
      payloadBytes: this.payload.length,
      blocks: this.blocks,
      stats: { ...this.stats },
    };
  }

  // --- messages -------------------------------------------------------------

  private nextSeq(): number {
    this.seq = (this.seq + 1) & 0xff;
    return this.seq;
  }

  private async control(
    subcommand: number,
    data: ArrayLike<number>,
    timeoutMs: number,
    accept: number[] = [subcommand],
  ): Promise<Reply> {
    const payload = new Uint8Array(1 + data.length);
    payload[0] = subcommand;
    payload.set(data, 1);
    const packets = encodeTpl({
      sid: SID_OTA_CONTROL,
      seq: this.nextSeq(),
      payload,
    });
    // The stock receiver takes 0xC0 only as a single packet.
    if (packets.length !== 1)
      throw new Error(
        `0xC0 message of ${payload.length} bytes does not fit one packet`,
      );
    this.replies = [];
    await this.send('ota', packets);
    return this.waitReply(accept, timeoutMs);
  }

  private async sendBlock(block: Uint8Array): Promise<Reply> {
    const seq = this.nextSeq();
    const packets = [
      ...encodeTpl({
        sid: SID_OTA_CONTROL,
        seq,
        payload: Uint8Array.of(OtaSubcommand.file),
      }),
      ...encodeTpl({ sid: SID_OTA_DATA, seq, payload: block }),
    ];
    this.replies = [];
    await this.send('ota', packets);
    return this.waitReply([OtaSubcommand.file], this.timing.blockAckTimeoutMs);
  }

  /** Writes one message's packets back to back; messages never interleave on the link. */
  private send(channel: StockChannel, packets: Uint8Array[]): Promise<void> {
    const run = this.writeTail.then(async () => {
      for (const packet of packets) {
        this.throwIfInterrupted();
        await this.link.write(channel, packet);
      }
    });
    this.writeTail = run.catch(() => {});
    return run.catch((error: unknown) => {
      this.throwIfInterrupted();
      throw new StockOtaError(
        'write-failed',
        `${this.temple}: write failed: ${error instanceof Error ? error.message : String(error)}`,
        this.intactNow(),
        this._state,
      );
    });
  }

  private waitReply(accept: number[], timeoutMs: number): Promise<Reply> {
    this.throwIfInterrupted();
    const queued = this.replies.findIndex((r) => accept.includes(r.subcommand));
    if (queued >= 0) return Promise.resolve(this.replies.splice(queued, 1)[0]!);
    if (this.disconnected !== null)
      return Promise.reject(new Error('disconnected'));
    return new Promise<Reply>((resolve, reject) => {
      const timer = this.scheduler.setTimeout(() => {
        done();
        reject(new ReplyTimeout(`no reply within ${timeoutMs} ms`));
      }, timeoutMs);
      const cancel = (error: Error) => {
        done();
        reject(error);
      };
      const done = () => {
        this.scheduler.clearTimeout(timer);
        this.cancels.delete(cancel);
        this.waiter = null;
      };
      this.cancels.add(cancel);
      this.waiter = {
        match: (r) => accept.includes(r.subcommand),
        resolve: (r) => {
          done();
          resolve(r);
        },
      };
    });
  }

  private sleep(ms: number): Promise<void> {
    this.throwIfInterrupted();
    return new Promise<void>((resolve, reject) => {
      const timer = this.scheduler.setTimeout(() => {
        this.cancels.delete(cancel);
        resolve();
      }, ms);
      const cancel = (error: Error) => {
        this.scheduler.clearTimeout(timer);
        this.cancels.delete(cancel);
        reject(error);
      };
      this.cancels.add(cancel);
    });
  }

  // --- link events ----------------------------------------------------------

  private onPacket(channel: StockChannel, bytes: Uint8Array): void {
    if (channel !== 'ota') return; // heartbeat acks and stock events are not ours
    const fed = this.assembler.feed(bytes);
    if (fed.kind === 'crc-error') {
      this.stats.badReplies++;
      return;
    }
    if (fed.kind !== 'message') return;
    const { message } = fed;
    if (message.dir !== TPL_FROM_GLASSES) return;
    if (message.sid !== SID_OTA_CONTROL && message.sid !== SID_OTA_DATA) return;
    if (message.payload.length < 2) return;
    const reply: Reply = {
      sid: message.sid,
      seq: message.seq,
      subcommand: message.payload[0]!,
      status: message.payload[1]!,
    };
    if (
      this._state === 'result-check' &&
      ((reply.subcommand === OtaSubcommand.resultCheck &&
        reply.status === OtaStatus.updating) ||
        reply.subcommand === OtaSubcommand.notify)
    ) {
      this.stagedSeen = true;
    }
    if (this.waiter?.match(reply)) this.waiter.resolve(reply);
    else this.replies.push(reply);
  }

  private onDisconnect(reason: string): void {
    if (this.disconnected !== null) return;
    this.disconnected = reason;
    if (
      this.stagedSeen ||
      this._state === 'notify' ||
      this._state === 'staged'
    ) {
      // The expected reset after staging.
      for (const cancel of this.cancels)
        cancel(new Error('disconnected after staging'));
      return;
    }
    const resultSent = this._state === 'result-check';
    this.fail(
      new StockOtaError(
        resultSent ? 'result-unknown' : 'disconnected',
        resultSent
          ? `${this.temple}: disconnected while waiting for the RESULT_CHECK verdict (${reason}); the update flag may be set. Reconnect and read the firmware version before anything else`
          : `${this.temple}: disconnected during ${this._state} (${reason}); the update flag was never set, stock is intact`,
        resultSent ? 'unknown' : true,
        this._state,
      ),
    );
  }

  private fail(error: StockOtaError): void {
    if (this.interrupt) return;
    this.interrupt = error;
    for (const cancel of [...this.cancels]) cancel(error);
  }

  private throwIfInterrupted(): void {
    if (this.interrupt) throw this.interrupt;
  }

  private asFailure(error: unknown): StockOtaError {
    if (this.interrupt) return this.interrupt;
    if (error instanceof StockOtaError) return error;
    return new StockOtaError(
      'unexpected-reply',
      `${this.temple}: ${error instanceof Error ? error.message : String(error)}`,
      this.intactNow(),
      this._state,
    );
  }

  /** Stock is provably intact until RESULT_CHECK has been sent. */
  private intactNow(): StockIntact {
    return this._state === 'result-check' ||
      this._state === 'notify' ||
      this._state === 'staged'
      ? 'unknown'
      : true;
  }

  // --- heartbeat, progress ----------------------------------------------------

  private startHeartbeat(): void {
    const beat = () => {
      this.heartbeatTimer = this.scheduler.setTimeout(
        beat,
        this.timing.heartbeatIntervalMs,
      );
      if (this.interrupt || this.disconnected) return;
      this.controlSeq = (this.controlSeq + 1) & 0xff;
      const packets = encodeTpl({
        sid: SID_DEV_CONFIG,
        seq: this.controlSeq,
        payload: Uint8Array.from(HEARTBEAT_PAYLOAD),
      });
      this.stats.heartbeats++;
      // A failed heartbeat write is harmless here; a dead link reports itself through disconnect.
      this.send('control', packets).catch(() => {});
    };
    this.heartbeatTimer = this.scheduler.setTimeout(
      beat,
      this.timing.heartbeatIntervalMs,
    );
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== null)
      this.scheduler.clearTimeout(this.heartbeatTimer);
    this.heartbeatTimer = null;
  }

  private enter(state: StockOtaState): void {
    this.throwIfInterrupted();
    this._state = state;
    this.emit();
  }

  private emit(): void {
    this.onProgress?.({
      temple: this.temple,
      state: this._state,
      bytesAcked: this.bytesAcked,
      totalBytes: this.payload.length,
      block: this.block,
      blocks: this.blocks,
      componentAttempt: this.componentAttempt,
    });
  }
}

/** Sends a sendable main-only bundle to one temple. See StockOtaTransfer for abort(). */
export async function sendStockOta(
  options: StockOtaOptions,
): Promise<StockOtaResult> {
  return new StockOtaTransfer(options).run();
}
