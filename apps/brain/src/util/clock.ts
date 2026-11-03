/** Injectable clock. Everything time-dependent reads `app.clock`, tests use FakeClock. */
export interface Clock {
  now(): number; // epoch ms
}

export const systemClock: Clock = { now: () => Date.now() };

export class FakeClock implements Clock {
  private t: number;
  constructor(start: number | Date = new Date(2026, 10, 3, 8, 0, 0)) {
    this.t = typeof start === 'number' ? start : start.getTime();
  }
  now(): number {
    return this.t;
  }
  set(t: number | Date): void {
    this.t = typeof t === 'number' ? t : t.getTime();
  }
  advance(ms: number): void {
    this.t += ms;
  }
  advanceMinutes(m: number): void {
    this.t += m * 60_000;
  }
}

export const MIN = 60_000;
export const HOUR = 3_600_000;
export const DAY = 86_400_000;

/** ISO 8601 with local UTC offset: 2026-11-03T08:15:00+01:00 */
export function isoLocal(ms: number): string {
  const d = new Date(ms);
  const p = (n: number, l = 2) => String(n).padStart(l, '0');
  const off = -d.getTimezoneOffset();
  const sign = off >= 0 ? '+' : '-';
  const a = Math.abs(off);
  return (
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}` +
    `${sign}${p(Math.floor(a / 60))}:${p(a % 60)}`
  );
}

export function parseIso(s: string | undefined | null): number | null {
  if (!s) return null;
  const t = Date.parse(s);
  return Number.isNaN(t) ? null : t;
}

/** "2026-11-03 Tuesday 08:15" style, 24 h, for prompts. */
export function humanLocal(ms: number, locale: 'de' | 'en' = 'en'): string {
  const d = new Date(ms);
  const day = d.toLocaleDateString(locale === 'de' ? 'de-DE' : 'en-GB', {
    weekday: 'long',
  });
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${day} ${p(d.getHours())}:${p(d.getMinutes())}`;
}
