import {
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';

/** A persisted resource: meta is the 24-byte LIST entry (res, type, flags, size, hash16). */
interface Entry {
  meta: Uint8Array;
  data: Uint8Array;
  used: number;
}

const key = (app: string, res: number) => `${app}\u0000${res}`;
const appDir = (app: string) => Buffer.from(app, 'utf8').toString('hex') || '_';

/**
 * The simulator's persistent storage: in memory, optionally mirrored to a
 * directory so resources survive restarts. LRU-evicts to stay within
 * `capacity` (persist_bytes in HELLO).
 */
export class SimStorage {
  private readonly entries = new Map<string, Entry>();
  private clock = 0;
  bytes = 0;

  constructor(
    readonly capacity = 8 << 20,
    private readonly dir?: string,
  ) {
    if (dir) this.load(dir);
  }

  write(app: string, meta: Uint8Array, data: Uint8Array): number {
    const res = meta[0]! | (meta[1]! << 8);
    if (data.length > this.capacity) return -1;
    this.remove(app, res);
    while (this.bytes + data.length > this.capacity) {
      let oldest: [string, Entry] | undefined;
      for (const e of this.entries)
        if (!oldest || e[1].used < oldest[1].used) oldest = e;
      if (!oldest) return -1;
      this.drop(oldest[0]);
    }
    this.entries.set(key(app, res), {
      meta: meta.slice(),
      data: data.slice(),
      used: ++this.clock,
    });
    this.bytes += data.length;
    if (this.dir) {
      const d = join(this.dir, appDir(app));
      mkdirSync(d, { recursive: true });
      writeFileSync(join(d, `${res}.res`), Buffer.concat([meta, data]));
    }
    return 0;
  }

  read(app: string, res: number): Entry | undefined {
    const e = this.entries.get(key(app, res));
    if (e) e.used = ++this.clock;
    return e;
  }

  remove(app: string, res: number): number {
    if (res === 0xffff) {
      let n = -1;
      for (const k of [...this.entries.keys()])
        if (k.startsWith(`${app}\u0000`)) {
          this.drop(k);
          n = 0;
        }
      return n;
    }
    const k = key(app, res);
    if (!this.entries.has(k)) return -1;
    this.drop(k);
    return 0;
  }

  list(app: string): Uint8Array[] {
    const out: Uint8Array[] = [];
    for (const [k, e] of this.entries)
      if (k.startsWith(`${app}\u0000`)) out.push(e.meta);
    return out;
  }

  private drop(k: string) {
    const e = this.entries.get(k);
    if (!e) return;
    this.entries.delete(k);
    this.bytes -= e.data.length;
    if (this.dir) {
      const [app, res] = k.split('\u0000') as [string, string];
      rmSync(join(this.dir, appDir(app), `${res}.res`), { force: true });
    }
  }

  private load(dir: string) {
    mkdirSync(dir, { recursive: true });
    for (const a of readdirSync(dir)) {
      const app = a === '_' ? '' : Buffer.from(a, 'hex').toString('utf8');
      for (const f of readdirSync(join(dir, a))) {
        if (!f.endsWith('.res')) continue;
        const b = new Uint8Array(readFileSync(join(dir, a, f)));
        if (b.length < 24) continue;
        const meta = b.slice(0, 24);
        const data = b.slice(24);
        this.entries.set(key(app, meta[0]! | (meta[1]! << 8)), {
          meta,
          data,
          used: ++this.clock,
        });
        this.bytes += data.length;
      }
    }
  }
}
