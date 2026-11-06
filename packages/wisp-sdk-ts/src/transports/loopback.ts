import type { Transport, TransportReceiver } from '../link/transport.ts';

export interface LoopbackOptions {
  /** Largest write. Default 244 (a GATT link with MTU 247). */
  mtu?: number;
  /**
   * Sees every chunk on its way; return it (changed or not) to deliver it or
   * `undefined` to drop it. For fault injection in tests.
   */
  tamper?: (chunk: Uint8Array, from: 'a' | 'b') => Uint8Array | undefined;
}

class LoopbackEnd implements Transport {
  receiver: TransportReceiver | undefined;
  peer!: LoopbackEnd;
  closed = false;
  private delivery = Promise.resolve();

  constructor(
    readonly mtu: number,
    private readonly side: 'a' | 'b',
    private readonly tamper: LoopbackOptions['tamper'],
  ) {}

  attach(receiver: TransportReceiver) {
    this.receiver = receiver;
  }

  async write(chunk: Uint8Array) {
    if (this.closed) throw new Error('loopback closed');
    if (chunk.length > this.mtu)
      throw new RangeError(`write of ${chunk.length} > mtu ${this.mtu}`);
    const copy = chunk.slice();
    // Deliver asynchronously and in order, like a real link.
    this.delivery = this.delivery.then(() => {
      if (this.peer.closed) return;
      const out = this.tamper ? this.tamper(copy, this.side) : copy;
      if (out) this.peer.receiver?.onData(out);
    });
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    await this.delivery;
    this.receiver?.onClose();
    this.peer.closed = true;
    this.peer.receiver?.onClose();
  }
}

/** Two connected in-memory transports. */
export function createLoopbackPair(
  opts: LoopbackOptions = {},
): [Transport, Transport] {
  const mtu = opts.mtu ?? 244;
  const a = new LoopbackEnd(mtu, 'a', opts.tamper);
  const b = new LoopbackEnd(mtu, 'b', opts.tamper);
  a.peer = b;
  b.peer = a;
  return [a, b];
}
