// The seam between the transport-agnostic OTA sender and a real BLE stack
// (Web Bluetooth, CoreBluetooth, noble, …) or a test fake. Nothing in this
// package implements it for real hardware.

/** One temple. There is deliberately no "both": each transfer names one temple. */
export type Temple = 'left' | 'right';

export const TEMPLES: readonly Temple[] = ['left', 'right'];

/**
 * Which characteristic a packet goes to / came from.
 * - `ota`: OTA write `…0001` / notify `…0002` (service `…1001`): every 0xC0/0xC1 packet and reply.
 * - `control`: control write `…5401` / notify `…5402`: the sid 0x80 heartbeat.
 */
export type StockChannel = 'ota' | 'control';

export interface StockLinkEvents {
  /** One notification, exactly as received (one TPL packet). */
  packet(channel: StockChannel, bytes: Uint8Array): void;
  /** The connection is gone. Called at most once. */
  disconnect(reason: string): void;
}

/**
 * A connected link to exactly one temple. Preconditions the implementation
 * guarantees before handing it to the sender (see README "Stock OTA sender"):
 * connected, services discovered, notifications enabled on `…0002` **and**
 * `…5402`, the phone already bonded with the temple (stock never prompts; the
 * Even app's bond is reused), the Even app not connected at the same time.
 */
export interface StockLink {
  /**
   * The temple this link is connected to, from the advertised name
   * (`Even G2_<pair>_<L|R>_<mac>`). The sender refuses to run when it differs
   * from the temple the caller named.
   */
  readonly temple: Temple;
  /** Write without response. Resolves when the packet is handed to the stack; rejects on a dead link. */
  write(channel: StockChannel, packet: Uint8Array): Promise<void>;
  /** Registers the handlers; returns an unsubscribe function. */
  subscribe(events: StockLinkEvents): () => void;
}

/** Timers, injected so the library needs no DOM or Node types. */
export interface Scheduler {
  setTimeout(callback: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
  now(): number;
}

interface GlobalTimers {
  setTimeout(callback: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const systemScheduler: Scheduler = {
  setTimeout: (callback, ms) =>
    (globalThis as unknown as GlobalTimers).setTimeout(callback, ms),
  clearTimeout: (handle) =>
    (globalThis as unknown as GlobalTimers).clearTimeout(handle),
  now: () => Date.now(),
};
