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

/** UTC offset in minutes of an ISO 8601 string ("…+01:00" -> 60, "…Z" -> 0), or null when it has none. */
export function parseOffsetMin(s: string | undefined | null): number | null {
  if (!s) return null;
  if (/T.*Z$/i.test(s)) return 0;
  const m = /T.*([+-])(\d{2}):?(\d{2})$/.exec(s);
  if (!m) return null;
  const v = Number(m[2]) * 60 + Number(m[3]);
  return m[1] === '-' ? -v : v;
}

/**
 * "2026-11-03 Tuesday 08:15" style, 24 h, for prompts. With `offsetMin` the time is shown at that UTC
 * offset (the phone's), otherwise in the server's local time zone.
 */
export function humanLocal(
  ms: number,
  locale: 'de' | 'en' = 'en',
  offsetMin?: number | null,
): string {
  const shifted = offsetMin !== undefined && offsetMin !== null;
  const d = new Date(shifted ? ms + offsetMin * MIN : ms);
  const day = d.toLocaleDateString(locale === 'de' ? 'de-DE' : 'en-GB', {
    weekday: 'long',
    ...(shifted ? { timeZone: 'UTC' } : {}),
  });
  const p = (n: number) => String(n).padStart(2, '0');
  const [y, mo, da, h, mi] = shifted
    ? [
        d.getUTCFullYear(),
        d.getUTCMonth(),
        d.getUTCDate(),
        d.getUTCHours(),
        d.getUTCMinutes(),
      ]
    : [
        d.getFullYear(),
        d.getMonth(),
        d.getDate(),
        d.getHours(),
        d.getMinutes(),
      ];
  return `${y}-${p(mo + 1)}-${p(da)} ${day} ${p(h)}:${p(mi)}`;
}

/** "+01:00" for prompts. */
export function offsetLabel(offsetMin: number): string {
  const a = Math.abs(offsetMin);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${offsetMin < 0 ? '-' : '+'}${p(Math.floor(a / 60))}:${p(a % 60)}`;
}

/**
 * "Tue 3 Nov 14:30–15:30" (24 h) for confirm buttons. Shown at `offsetMin` (the phone's UTC offset) or
 * the server's local zone; an end on another day gets its own date.
 */
export function shortWhen(
  start: number,
  end: number | null,
  locale: 'de' | 'en' = 'en',
  offsetMin?: number | null,
): string {
  const shifted = offsetMin !== undefined && offsetMin !== null;
  const zone = (ms: number) => new Date(shifted ? ms + offsetMin * MIN : ms);
  const day = (ms: number) =>
    zone(ms).toLocaleDateString(locale === 'de' ? 'de-DE' : 'en-GB', {
      weekday: 'short',
      day: 'numeric',
      month: 'short',
      ...(shifted ? { timeZone: 'UTC' } : {}),
    });
  const p = (n: number) => String(n).padStart(2, '0');
  const time = (ms: number) => {
    const d = zone(ms);
    return shifted
      ? `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`
      : `${p(d.getHours())}:${p(d.getMinutes())}`;
  };
  if (end === null || Number.isNaN(end)) return `${day(start)} ${time(start)}`;
  return day(start) === day(end)
    ? `${day(start)} ${time(start)}–${time(end)}`
    : `${day(start)} ${time(start)} – ${day(end)} ${time(end)}`;
}
