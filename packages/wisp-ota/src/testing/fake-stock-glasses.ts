// A fake stock temple for the OTA sender tests: the receiving side of the
// stock 0xC0/0xC1 import protocol, written from the documented behaviour of
// stock 2.2.6.10 (openCFW `ota_transport.c` OTA_ReceivePacket and
// `ota_service_file_parse.c` _fileCmdParse / _fileRawDataParse, MIT; facts
// only, the code is ours) plus a model of what matters for brick safety: the
// littlefs staging file, the update flag, and what the bootloader would install
// on the next reset. Faults are injected through `faults`.

import { readU32 } from '../bytes.ts';
import { MAIN_PATH } from '../constants.ts';
import { crc32cMsb } from '../crc.ts';
import {
  systemScheduler,
  type Scheduler,
  type StockChannel,
  type StockLink,
  type StockLinkEvents,
  type Temple,
} from '../transfer/link.ts';
import {
  OTA_HEADER_SIZE,
  OTA_INTERPACKET_TIMEOUT_MS,
  OTA_RESTART_DELAY_MS,
  OtaStatus,
  OtaSubcommand,
  SID_DEV_CONFIG,
  SID_OTA_CONTROL,
  SID_OTA_DATA,
} from '../transfer/protocol.ts';
import {
  crc16CcittFalse,
  encodeTpl,
  TPL_FROM_GLASSES,
  TPL_HEADER_SIZE,
  TPL_MAGIC,
} from '../transfer/tpl.ts';

export const UPDATE_FLAG_INSTALL = 0x55555555;

/** What a reply looks like before it goes out; the faults decide its fate. */
export interface FakeReply {
  sid: number;
  subcommand: number;
  status: number;
  /** For block replies: the 0-based block index within the current INFORMATION run. */
  block?: number;
}

export interface FakeIncoming {
  sid: number;
  /** 0xC0 subcommand, if known. */
  subcommand?: number;
  /** For 0xC1 packets: block index and 1-based packet number. */
  block?: number;
  packet?: number;
}

export interface FakeFaults {
  /** The reply is never sent (a lost notification). */
  dropReply?: (reply: FakeReply) => boolean;
  /** The reply is sent with a broken CRC-16. */
  corruptReplyCrc?: (reply: FakeReply) => boolean;
  /** One byte of this incoming packet is flipped on the air (the stock CRC-16 check catches it). */
  corruptIncoming?: (incoming: FakeIncoming) => boolean;
  /** The incoming packet is lost. */
  dropIncoming?: (incoming: FakeIncoming) => boolean;
  /** The file write of this block fails (stock deletes the staging file, FLASH_WRITE_ERR). */
  failFlashWrite?: (block: number) => boolean;
  /** This block is stored with one flipped byte (read-back passes, CRC-32C at RESULT_CHECK fails). */
  corruptStorage?: (block: number) => boolean;
  /** The link drops right after this incoming packet was processed. */
  disconnectAfter?: (incoming: FakeIncoming) => boolean;
  /** Status START answers with (10 = filesystem heal failed). */
  startStatus?: () => number;
}

export interface FakeStockGlassesOptions {
  temple: Temple;
  /** What MRAM holds at the start, e.g. "stock 2.2.6.10". */
  installed?: string;
  faults?: FakeFaults;
  scheduler?: Scheduler;
  interPacketTimeoutMs?: number;
  restartDelayMs?: number;
}

/** A sent packet, as the tests see it. */
export interface WrittenPacket {
  channel: StockChannel;
  bytes: Uint8Array;
}

export class FakeStockGlasses implements StockLink {
  readonly temple: Temple;
  faults: FakeFaults;
  readonly written: WrittenPacket[] = [];

  // Persistent state (survives a reset).
  /** The bootloader-owned update flag word at 0x7FE000. */
  flag = 0;
  /** littlefs `ota/s200_firmware_ota.bin`, or null when absent. */
  stagingFile: Uint8Array | null = null;
  /** What MRAM holds: the image the temple boots. */
  installed: { name: string; crc32c: number | null };
  resets = 0;
  heartbeats = 0;

  // Volatile state (the stock app's RAM).
  private connected = true;
  private listeners: StockLinkEvents[] = [];
  private readonly scheduler: Scheduler;
  private readonly interPacketTimeoutMs: number;
  private readonly restartDelayMs: number;
  private fileOpen = false;
  private fileChunks: Uint8Array[] = [];
  private sessionState = 0;
  private started = false;
  private header: Uint8Array | null = null;
  private block = 0;
  private rx: { seq: number; chunks: Uint8Array[]; size: number } | null = null;
  private rxErrorPending = false;
  private rxErrorSeq = 0;
  private rxTimer: unknown = null;
  private syncId = 0;

  constructor(options: FakeStockGlassesOptions) {
    this.temple = options.temple;
    this.faults = options.faults ?? {};
    this.scheduler = options.scheduler ?? systemScheduler;
    this.interPacketTimeoutMs =
      options.interPacketTimeoutMs ?? OTA_INTERPACKET_TIMEOUT_MS;
    this.restartDelayMs = options.restartDelayMs ?? OTA_RESTART_DELAY_MS;
    this.installed = { name: options.installed ?? 'stock', crc32c: null };
  }

  // --- StockLink -------------------------------------------------------------

  subscribe(events: StockLinkEvents): () => void {
    this.listeners.push(events);
    return () => {
      this.listeners = this.listeners.filter((l) => l !== events);
    };
  }

  async write(channel: StockChannel, packet: Uint8Array): Promise<void> {
    if (!this.connected) throw new Error('not connected');
    const bytes = packet.slice();
    this.written.push({ channel, bytes });
    if (channel === 'control') {
      if (bytes[6] === SID_DEV_CONFIG) this.heartbeats++;
      return;
    }
    this.receive(bytes);
  }

  // --- test controls ---------------------------------------------------------

  /** Drops the link (radio loss). The open file stays as written, like stock. */
  disconnect(reason = 'link lost'): void {
    if (!this.connected) return;
    this.connected = false;
    this.clearRxTimer();
    for (const l of [...this.listeners]) l.disconnect(reason);
  }

  /**
   * A reset into the Even bootloader, then the app: installs the staging file
   * only when the flag says so and the staged image's own CRC holds, exactly
   * the stock chain (hardware.md "Boot and update chain"). RAM state is lost.
   */
  reset(): void {
    this.resets++;
    this.disconnect('reset');
    if (this.flag === UPDATE_FLAG_INSTALL && this.stagingFile && this.header) {
      const expected = readU32(this.header, 0x0c);
      const crc = crc32cMsb(this.stagingFile);
      if (crc === expected)
        this.installed = { name: 'staged image', crc32c: crc };
      this.flag = 0;
    }
    this.fileOpen = false;
    this.sessionState = 0;
    this.started = false;
    this.rx = null;
    this.rxErrorPending = false;
    this.connected = true;
  }

  /** True when the flag is clear: whatever happened, the next boot runs what MRAM holds. */
  get installPending(): boolean {
    return this.flag === UPDATE_FLAG_INSTALL;
  }

  // --- transport (OTA_ReceivePacket) -----------------------------------------

  private receive(input: Uint8Array): void {
    const packet = input;
    if (packet.length < TPL_HEADER_SIZE || packet[0] !== TPL_MAGIC) return;
    const sid = packet[6]!;
    const incoming: FakeIncoming = { sid };
    if (sid === SID_OTA_CONTROL) incoming.subcommand = packet[TPL_HEADER_SIZE];
    if (sid === SID_OTA_DATA) {
      incoming.block = this.block;
      incoming.packet = packet[5];
    }
    if (this.faults.dropIncoming?.(incoming)) return;
    if (
      this.faults.corruptIncoming?.(incoming) &&
      packet.length > TPL_HEADER_SIZE
    ) {
      packet[TPL_HEADER_SIZE] = packet[TPL_HEADER_SIZE]! ^ 0x5a;
    }
    this.transport(packet);
    if (this.faults.disconnectAfter?.(incoming))
      this.disconnect('injected disconnect');
  }

  private transport(packet: Uint8Array): void {
    const seq = packet[2]!;
    const len = packet[3]!;
    const total = packet[4]!;
    const num = packet[5]!;
    const sid = packet[6]!;
    this.syncId = seq;
    if (this.rxErrorPending && num >= 2 && seq === this.rxErrorSeq) return; // rest of a failed message

    if (sid === SID_OTA_CONTROL) {
      const data = packet.subarray(TPL_HEADER_SIZE, TPL_HEADER_SIZE + len - 2);
      const crc =
        packet[TPL_HEADER_SIZE + len - 2]! |
        (packet[TPL_HEADER_SIZE + len - 1]! << 8);
      if (total !== 1 || crc !== crc16CcittFalse(data)) {
        this.rxFail(sid, seq, OtaStatus.crcError);
        return;
      }
      this.cmdParse(data[0]!, data.subarray(1));
      if (data[0] === OtaSubcommand.file) {
        this.rx = { seq, chunks: [], size: 0 };
        this.rxErrorPending = false;
      }
      return;
    }
    if (sid !== SID_OTA_DATA) return;

    this.clearRxTimer();
    this.rxErrorPending = false;
    if (!this.rx) {
      if (num < total) {
        this.rxFail(sid, seq, OtaStatus.noResources);
        return;
      }
      return;
    }
    const chunk = packet.slice(TPL_HEADER_SIZE, TPL_HEADER_SIZE + len);
    if (this.rx.size + chunk.length > 0x1020) {
      this.rx = null;
      this.rxFail(sid, seq, OtaStatus.crcError);
      return;
    }
    this.rx.chunks.push(chunk);
    this.rx.size += chunk.length;
    if (num < total) {
      this.rxTimer = this.scheduler.setTimeout(() => {
        this.rxTimer = null;
        this.rx = null;
        this.rxErrorPending = true;
        this.reply(SID_OTA_DATA, OtaSubcommand.file, OtaStatus.timeout);
      }, this.interPacketTimeoutMs);
      return;
    }
    const body = concat(this.rx.chunks);
    this.rx = null;
    const data = body.subarray(0, body.length - 2);
    const crc = body[body.length - 2]! | (body[body.length - 1]! << 8);
    if (crc !== crc16CcittFalse(data)) {
      this.rxFail(sid, seq, OtaStatus.crcError);
      return;
    }
    this.rawDataParse(data);
  }

  private rxFail(sid: number, seq: number, status: number): void {
    this.rxErrorPending = true;
    this.rxErrorSeq = seq;
    // Fixed transport notifications: payload {2, status} (protocols.md §5: LE 0x0302 / 0x0402 / 0x0502).
    this.reply(sid, OtaSubcommand.file, status);
  }

  private clearRxTimer(): void {
    if (this.rxTimer !== null) this.scheduler.clearTimeout(this.rxTimer);
    this.rxTimer = null;
  }

  // --- OTA service (_fileCmdParse / _fileRawDataParse) ------------------------

  private cmdParse(cid: number, data: Uint8Array): void {
    switch (cid) {
      case OtaSubcommand.start: {
        this.fileOpen = false;
        this.header = null;
        this.started = false;
        this.sessionState = 0;
        const status = this.faults.startStatus?.() ?? OtaStatus.success;
        this.reply(SID_OTA_CONTROL, OtaSubcommand.start, status);
        return;
      }
      case OtaSubcommand.information: {
        if (data.length !== OTA_HEADER_SIZE) {
          this.reply(
            SID_OTA_CONTROL,
            OtaSubcommand.information,
            OtaStatus.headerError,
          );
          return;
        }
        const path = asciiz(data.subarray(0x30));
        if (
          readU32(data, 0x24) !== 0 ||
          readU32(data, 0x28) !== 3 ||
          !path.startsWith(MAIN_PATH)
        ) {
          this.reply(
            SID_OTA_CONTROL,
            OtaSubcommand.information,
            OtaStatus.headerError,
          );
          return;
        }
        this.header = data.slice();
        this.block = 0;
        // file_remove + create/truncate + reopen read/write.
        this.stagingFile = new Uint8Array(0);
        this.fileChunks = [];
        this.fileOpen = true;
        this.sessionState = 1;
        this.reply(
          SID_OTA_CONTROL,
          OtaSubcommand.information,
          OtaStatus.success,
        );
        return;
      }
      case OtaSubcommand.file:
        this.started = true;
        return;
      case OtaSubcommand.resultCheck: {
        if (!this.fileOpen || !this.header) {
          this.reply(
            SID_OTA_CONTROL,
            OtaSubcommand.resultCheck,
            OtaStatus.checkFail,
          );
          return;
        }
        this.fileOpen = false;
        this.flushFile();
        const file = this.stagingFile!;
        if (
          crc32cMsb(file) === readU32(this.header, 0x0c) &&
          file.length === readU32(this.header, 0x08)
        ) {
          this.reply(
            SID_OTA_CONTROL,
            OtaSubcommand.resultCheck,
            OtaStatus.updating,
          );
          this.flag = UPDATE_FLAG_INSTALL;
          this.reply(
            SID_OTA_CONTROL,
            OtaSubcommand.notify,
            OtaStatus.sysRestart,
          );
          this.scheduler.setTimeout(() => this.reset(), this.restartDelayMs);
        } else {
          this.stagingFile = null;
          this.reply(
            SID_OTA_CONTROL,
            OtaSubcommand.resultCheck,
            OtaStatus.checkFail,
          );
        }
        this.sessionState = 0;
        this.started = false;
        return;
      }
      default:
        return;
    }
  }

  private rawDataParse(data: Uint8Array): void {
    if (!this.started) return; // stock: no reply at all
    const block = this.block;
    if (
      this.sessionState !== 1 ||
      !this.fileOpen ||
      this.faults.failFlashWrite?.(block)
    ) {
      // Write or read-back failed: close, delete, reset the session.
      this.fileOpen = false;
      this.stagingFile = null;
      this.fileChunks = [];
      this.sessionState = 0;
      this.reply(
        SID_OTA_DATA,
        OtaSubcommand.file,
        OtaStatus.flashWriteError,
        block,
      );
      return;
    }
    const stored = data.slice();
    if (this.faults.corruptStorage?.(block)) stored[0] = stored[0]! ^ 0xff;
    this.fileChunks.push(stored);
    this.flushFile();
    this.block++;
    this.reply(SID_OTA_DATA, OtaSubcommand.file, OtaStatus.success, block);
  }

  private flushFile(): void {
    if (this.stagingFile !== null) this.stagingFile = concat(this.fileChunks);
  }

  // --- replies (_evenOtaReplyToAPP) -------------------------------------------

  private reply(
    sid: number,
    subcommand: number,
    status: number,
    block?: number,
  ): void {
    const info: FakeReply = { sid, subcommand, status, block };
    if (this.faults.dropReply?.(info)) return;
    const packets = encodeTpl(
      { sid, seq: this.syncId, payload: Uint8Array.of(subcommand, status) },
      TPL_FROM_GLASSES,
    );
    if (this.faults.corruptReplyCrc?.(info)) {
      const last = packets[packets.length - 1]!;
      last[last.length - 1] = last[last.length - 1]! ^ 0xff;
    }
    for (const p of packets) {
      this.scheduler.setTimeout(() => {
        if (!this.connected) return;
        for (const l of [...this.listeners]) l.packet('ota', p);
      }, 0);
    }
  }
}

function concat(chunks: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

function asciiz(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) {
    if (b === 0) break;
    s += String.fromCharCode(b);
  }
  return s;
}
