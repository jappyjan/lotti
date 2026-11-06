import { crc16 } from './crc.ts';

export const FRAME_MAGIC = 0x57;
export const FRAME_HEADER_SIZE = 8;
/** Header plus CRC. */
export const FRAME_OVERHEAD = 10;
export const DEFAULT_MAX_FRAME = 4096;

/** `fflags` bits. `ctrl`: an unsequenced control frame (`CREDIT`, `RESYNC`). */
export const FrameFlag = { ctrl: 1 } as const;
/** Reserved bits: nonzero makes a frame bad. */
export const FFLAGS_RESERVED = 0xfe;
export const ROUTE_RESERVED = 0xf0;

/** `route` lens values (bits 0–1 destination, bits 2–3 source). */
export const Lens = { connected: 0, left: 1, right: 2, both: 3 } as const;
export type LensValue = (typeof Lens)[keyof typeof Lens];

export interface Frame {
  svc: number;
  route: number;
  fflags: number;
  seq: number;
  body: Uint8Array;
}

export function routeByte(dest: number, source = 0): number {
  return (dest & 3) | ((source & 3) << 2);
}

export function encodeFrame(f: Omit<Frame, 'fflags'> & { fflags?: number }) {
  const len = f.body.length;
  if (len > 0xffff) throw new RangeError('frame body longer than 65535');
  if (f.route & ROUTE_RESERVED || (f.fflags ?? 0) & FFLAGS_RESERVED)
    throw new RangeError('reserved route or fflags bits set');
  const out = new Uint8Array(len + FRAME_OVERHEAD);
  const v = new DataView(out.buffer);
  out[0] = FRAME_MAGIC;
  out[1] = f.svc;
  out[2] = f.route;
  out[3] = f.fflags ?? 0;
  v.setUint16(4, len, true);
  v.setUint16(6, f.seq & 0xffff, true);
  out.set(f.body, FRAME_HEADER_SIZE);
  v.setUint16(
    FRAME_HEADER_SIZE + len,
    crc16(out, 0, FRAME_HEADER_SIZE + len),
    true,
  );
  return out;
}

export type FrameError = 'garbage' | 'crc' | 'length' | 'reserved';

export interface FrameDecoderOptions {
  /** Largest body accepted; longer `len` values count as corruption. */
  maxFrame?: number;
  /** Called once per corrupt region, with the number of bytes dropped so far. */
  onError?: (kind: FrameError, dropped: number) => void;
}

/**
 * Reassembles frames from a byte stream delivered in arbitrary chunks. On a
 * bad magic, a `len` above `maxFrame`, reserved bits set in `route` or
 * `fflags`, or a bad CRC it drops bytes until the next magic that starts a
 * frame with a valid CRC. A corrupted `len` that still fits waits for that
 * many bytes; the sender's ack timeout makes sure they come. Sequence
 * numbers are the link's business.
 */
export class FrameDecoder {
  private buf = new Uint8Array(0);
  private start = 0;
  private end = 0;
  private maxFrame: number;
  private readonly onError: FrameDecoderOptions['onError'];

  constructor(opts: FrameDecoderOptions = {}) {
    this.maxFrame = opts.maxFrame ?? 0xffff;
    this.onError = opts.onError;
  }

  setMaxFrame(maxFrame: number) {
    this.maxFrame = maxFrame;
  }

  /** Bytes waiting for the rest of a frame. */
  get buffered(): number {
    return this.end - this.start;
  }

  reset() {
    this.start = this.end = 0;
  }

  /** Feeds bytes; returns the complete frames, in order. */
  push(chunk: Uint8Array): Frame[] {
    const frames: Frame[] = [];
    this.feed(chunk, (f) => frames.push(f), this.onError);
    return frames;
  }

  /** Like `push`, but reports frames and errors interleaved, as they happen. */
  feed(
    chunk: Uint8Array,
    onFrame: (f: Frame) => void,
    onError?: (kind: FrameError, dropped: number) => void,
  ) {
    this.append(chunk);
    const b = this.buf;
    let dropped = 0;
    let firstError: FrameError | undefined;
    const drop = (kind: FrameError) => {
      firstError ??= kind;
      dropped++;
      this.start++;
    };
    while (this.end - this.start > 0) {
      const s = this.start;
      if (b[s] !== FRAME_MAGIC) {
        drop('garbage');
        continue;
      }
      if (this.end - s < FRAME_HEADER_SIZE) break;
      const len = b[s + 4]! | (b[s + 5]! << 8);
      if (len > this.maxFrame) {
        drop('length');
        continue;
      }
      if (b[s + 2]! & ROUTE_RESERVED || b[s + 3]! & FFLAGS_RESERVED) {
        drop('reserved');
        continue;
      }
      const total = len + FRAME_OVERHEAD;
      if (this.end - s < total) break;
      const want = b[s + 8 + len]! | (b[s + 9 + len]! << 8);
      if (crc16(b, s, s + 8 + len) !== want) {
        drop('crc');
        continue;
      }
      if (firstError) {
        onError?.(firstError, dropped);
        firstError = undefined;
        dropped = 0;
      }
      this.start += total;
      onFrame({
        svc: b[s + 1]!,
        route: b[s + 2]!,
        fflags: b[s + 3]!,
        seq: b[s + 6]! | (b[s + 7]! << 8),
        body: b.slice(s + 8, s + 8 + len),
      });
    }
    if (firstError) onError?.(firstError, dropped);
  }

  private append(chunk: Uint8Array) {
    const used = this.end - this.start;
    if (this.end + chunk.length > this.buf.length) {
      if (used + chunk.length > this.buf.length) {
        const next = new Uint8Array(Math.max(1024, (used + chunk.length) * 2));
        next.set(this.buf.subarray(this.start, this.end));
        this.buf = next;
      } else this.buf.copyWithin(0, this.start, this.end);
      this.start = 0;
      this.end = used;
    }
    this.buf.set(chunk, this.end);
    this.end += chunk.length;
  }
}

/** Signed distance from `b` to `a` on the 16-bit sequence circle. */
export function seqDiff(a: number, b: number): number {
  const d = (a - b) & 0xffff;
  return d >= 0x8000 ? d - 0x10000 : d;
}
