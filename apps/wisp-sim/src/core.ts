import { readFileSync } from 'node:fs';
import { SimStorage } from './storage.ts';

/** Field order of `sim_stats` (src/c/sim.c). */
export const STATS_FIELDS = [
  'session',
  'frame',
  'layers',
  'resources',
  'resourceBytes',
  'resFree',
  'gfxFree',
  'animations',
  'tweens',
  'messages',
  'errors',
  'rxBytes',
  'txBytes',
  'resyncs',
  'resends',
  'ackTimeouts',
  'displayOn',
  'worn',
  'inputMask',
  'follower',
  'kpxComposed',
  'autoFrames',
] as const;
export type LensStats = Record<(typeof STATS_FIELDS)[number], number> & {
  appId: string;
};

export type Lens = 1 | 2;
export const LENS_W = 640;
export const LENS_H = 480;
export const FB_BYTES = (LENS_W / 2) * LENS_H;

export interface Damage {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface Exports {
  memory: WebAssembly.Memory;
  sim_io(): number;
  sim_io_size(): number;
  sim_init(): number;
  sim_link_open(lens: number, mirror: number): number;
  sim_link_close(id: number): void;
  sim_link_rx(id: number, len: number): void;
  sim_link_pull(id: number): number;
  sim_tick(nowUs: number): number;
  sim_touch(lens: number, phase: number, pos: number): void;
  sim_gesture(lens: number, kind: number): void;
  sim_wear(worn: number): void;
  sim_fb(lens: number): number;
  sim_out(lens: number): number;
  sim_out_clear(lens: number): void;
  sim_stats(lens: number): number;
}

const WASM = new URL('../wisp-sim.wasm', import.meta.url);

/** The Wisp core (both lenses) running in WebAssembly, with its sim HAL. */
export class SimCore {
  private readonly x: Exports;
  private readonly io: number;
  private readonly ioSize: number;
  private readonly t0 = performance.now();

  private constructor(
    instance: WebAssembly.Instance,
    readonly storage: SimStorage,
  ) {
    this.x = instance.exports as unknown as Exports;
    this.io = this.x.sim_io();
    this.ioSize = this.x.sim_io_size();
    const r = this.x.sim_init();
    if (r !== 0) throw new Error(`sim_init failed: ${r}`);
  }

  static async create(
    opts: { storage?: SimStorage; wasm?: Uint8Array } = {},
  ): Promise<SimCore> {
    const storage = opts.storage ?? new SimStorage();
    let core: SimCore | undefined;
    const mem = () => new Uint8Array(core!.x.memory.buffer);
    const cstr = (p: number) => {
      const m = mem();
      let e = p;
      while (m[e]) e++;
      return new TextDecoder().decode(m.subarray(p, e));
    };
    const env = {
      storage_capacity: () => storage.capacity,
      storage_write: (app: number, meta: number, data: number, len: number) =>
        storage.write(
          cstr(app),
          mem().slice(meta, meta + 24),
          mem().slice(data, data + len),
        ),
      storage_read: (
        app: number,
        res: number,
        meta: number,
        data: number,
        cap: number,
      ) => {
        const e = storage.read(cstr(app), res);
        if (!e) return -1;
        mem().set(e.meta, meta);
        if (data) mem().set(e.data.subarray(0, cap), data);
        return e.data.length;
      },
      storage_remove: (app: number, res: number) =>
        storage.remove(cstr(app), res),
      storage_list: (app: number, out: number, cap: number) => {
        const items = storage.list(cstr(app)).slice(0, cap);
        items.forEach((m, i) => mem().set(m, out + 24 * i));
        return items.length;
      },
    };
    const module = await WebAssembly.compile(
      (opts.wasm ??
        new Uint8Array(readFileSync(WASM))) as Uint8Array<ArrayBuffer>,
    );
    const instance = await WebAssembly.instantiate(module, { env });
    core = new SimCore(instance, storage);
    return core;
  }

  private get mem() {
    return new Uint8Array(this.x.memory.buffer);
  }

  /** Microseconds since the simulator started: the glasses' clock. */
  nowUs(): number {
    return Math.floor((performance.now() - this.t0) * 1000);
  }

  openLink(lens: Lens, mirror: boolean): number {
    const id = this.x.sim_link_open(lens, mirror ? 1 : 0);
    if (id < 0) throw new Error('too many links');
    return id;
  }

  closeLink(id: number) {
    this.x.sim_link_close(id);
  }

  /** Bytes from the phone. */
  receive(id: number, data: Uint8Array) {
    this.x.sim_tick(this.nowUs());
    for (let off = 0; off < data.length; off += this.ioSize) {
      const chunk = data.subarray(off, off + this.ioSize);
      this.mem.set(chunk, this.io);
      this.x.sim_link_rx(id, chunk.length);
    }
  }

  /** Bytes for the phone (empty when there are none). */
  pull(id: number): Uint8Array {
    const n = this.x.sim_link_pull(id);
    return this.mem.slice(this.io, this.io + n);
  }

  /** Advances animations, tweens, gestures and timeouts; returns lenses whose session timed out. */
  tick(): number {
    return this.x.sim_tick(this.nowUs());
  }

  touch(lens: Lens, phase: number, pos: number) {
    this.x.sim_tick(this.nowUs());
    this.x.sim_touch(lens, phase, pos);
  }

  gesture(lens: Lens, kind: number) {
    this.x.sim_tick(this.nowUs());
    this.x.sim_gesture(lens, kind);
  }

  setWorn(worn: boolean) {
    this.x.sim_wear(worn ? 1 : 0);
  }

  /** The lens' panel: RAW4, 640×480 (a copy). */
  frame(lens: Lens): Uint8Array {
    const p = this.x.sim_fb(lens);
    return this.mem.slice(p, p + FB_BYTES);
  }

  /** The damaged rect since the last call (and clears it), with presentation counters. */
  takeDamage(lens: Lens): {
    damage?: Damage;
    frame: number;
    displayOn: boolean;
    brightness: number;
  } {
    const p = this.x.sim_out(lens);
    const v = new Int32Array(this.x.memory.buffer, p, 9);
    const [x0, y0, x1, y1, frame] = v;
    const out = {
      damage:
        x1! > x0! && y1! > y0!
          ? { x: x0!, y: y0!, w: x1! - x0!, h: y1! - y0! }
          : undefined,
      frame: frame!,
      displayOn: v[7] !== 0,
      brightness: v[8]!,
    };
    this.x.sim_out_clear(lens);
    return out;
  }

  /** RAW4 rows of a rect (x, w even) from the panel. */
  region(lens: Lens, r: Damage): Uint8Array {
    const p = this.x.sim_fb(lens);
    const m = this.mem;
    const bw = r.w / 2;
    const out = new Uint8Array(bw * r.h);
    for (let y = 0; y < r.h; y++) {
      const s = p + (r.y + y) * (LENS_W / 2) + r.x / 2;
      out.set(m.subarray(s, s + bw), y * bw);
    }
    return out;
  }

  stats(lens: Lens): LensStats {
    const n = this.x.sim_stats(lens);
    const v = new Uint32Array(this.x.memory.buffer, this.io, n);
    const s = {} as LensStats;
    STATS_FIELDS.forEach((f, i) => (s[f] = v[i]!));
    const m = this.mem;
    let e = this.io + n * 4;
    const start = e;
    while (m[e] && e < start + 16) e++;
    s.appId = new TextDecoder().decode(m.subarray(start, e));
    return s;
  }
}
