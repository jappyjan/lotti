import {
  DEFAULT_MAX_FRAME,
  FrameDecoder,
  seqDiff,
  type Frame,
} from '../protocol/frame.ts';

export type ReceiveEvent =
  /** The next frame in sequence. */
  | { kind: 'frame'; frame: Frame }
  /** A valid frame after a gap; dropped, it will be retransmitted. */
  | { kind: 'early'; frame: Frame }
  /** Send `RESYNC {lastGoodSeq}`. */
  | { kind: 'resync'; lastGoodSeq: number };

/**
 * The receive half of a link without timers or I/O: reassembles frames,
 * drops duplicates, holds back frames after a gap and decides when to ask
 * for a `RESYNC`: once per break, then not again until a frame arrives in
 * order (or `rearmResync` is called because the request may be lost).
 */
export class FrameReceiver {
  /** Seq of the last frame accepted in order; the peer starts at 0. */
  lastGoodSeq = 0xffff;
  duplicates = 0;
  corrupt = 0;
  private resyncAsked = false;
  private readonly decoder: FrameDecoder;

  constructor(maxFrame = DEFAULT_MAX_FRAME) {
    this.decoder = new FrameDecoder({ maxFrame });
  }

  get resyncPending(): boolean {
    return this.resyncAsked;
  }

  rearmResync() {
    this.resyncAsked = false;
  }

  push(chunk: Uint8Array): ReceiveEvent[] {
    const out: ReceiveEvent[] = [];
    const resync = () => {
      if (this.resyncAsked) return;
      this.resyncAsked = true;
      out.push({ kind: 'resync', lastGoodSeq: this.lastGoodSeq });
    };
    this.decoder.feed(
      chunk,
      (frame) => {
        const d = seqDiff(frame.seq, (this.lastGoodSeq + 1) & 0xffff);
        if (d < 0) this.duplicates++;
        else if (d > 0) {
          out.push({ kind: 'early', frame });
          resync();
        } else {
          this.lastGoodSeq = frame.seq;
          this.resyncAsked = false;
          out.push({ kind: 'frame', frame });
        }
      },
      () => {
        this.corrupt++;
        resync();
      },
    );
    return out;
  }
}
