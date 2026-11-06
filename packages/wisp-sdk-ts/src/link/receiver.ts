import {
  DEFAULT_MAX_FRAME,
  FrameDecoder,
  FrameFlag,
  seqDiff,
  type Frame,
} from '../protocol/frame.ts';

export type ReceiveEvent =
  /** The next frame in sequence. */
  | { kind: 'frame'; frame: Frame }
  /** A control frame (`fflags.CTRL`): outside the sequence, passed on in any state. */
  | { kind: 'control'; frame: Frame }
  /** A frame we already have. Answer with `CREDIT {lastGoodSeq}`: the sender may have lost ours. */
  | { kind: 'duplicate'; lastGoodSeq: number }
  /** A valid frame after a gap; dropped, it will be retransmitted. */
  | { kind: 'early'; frame: Frame }
  /** Send `RESYNC {lastGoodSeq}`. */
  | { kind: 'resync'; lastGoodSeq: number };

/**
 * The receive half of a link without timers or I/O: reassembles frames,
 * passes control frames through, reports duplicates, holds back frames after
 * a gap and decides when to ask for a `RESYNC`: once per run of discarded
 * bytes, and once per gap until a frame arrives in order again. A lost
 * `RESYNC` is covered by the sender's ack timeout.
 */
export class FrameReceiver {
  /** Seq of the last frame accepted in order; the peer starts at 0. */
  lastGoodSeq = 0xffff;
  duplicates = 0;
  corrupt = 0;
  /** `RESYNC` asked, waiting for `lastGoodSeq + 1`. */
  private recovering = false;
  /** Inside a run of discarded bytes. */
  private badRun = false;
  private readonly decoder: FrameDecoder;

  constructor(maxFrame = DEFAULT_MAX_FRAME) {
    this.decoder = new FrameDecoder({ maxFrame });
  }

  get resyncPending(): boolean {
    return this.recovering;
  }

  push(chunk: Uint8Array): ReceiveEvent[] {
    const out: ReceiveEvent[] = [];
    this.decoder.feed(
      chunk,
      (frame) => {
        this.badRun = false;
        if (frame.fflags & FrameFlag.ctrl) {
          out.push({ kind: 'control', frame });
          return;
        }
        const d = seqDiff(frame.seq, (this.lastGoodSeq + 1) & 0xffff);
        if (d === 0) {
          this.lastGoodSeq = frame.seq;
          this.recovering = false;
          out.push({ kind: 'frame', frame });
        } else if (d < 0) {
          this.duplicates++;
          out.push({ kind: 'duplicate', lastGoodSeq: this.lastGoodSeq });
        } else {
          out.push({ kind: 'early', frame });
          if (!this.recovering) {
            this.recovering = true;
            out.push({ kind: 'resync', lastGoodSeq: this.lastGoodSeq });
          }
        }
      },
      () => {
        this.corrupt++;
        if (this.badRun) return;
        this.badRun = this.recovering = true;
        out.push({ kind: 'resync', lastGoodSeq: this.lastGoodSeq });
      },
    );
    return out;
  }
}
