import { randomUUID } from 'node:crypto';
import type { CalendarEvent } from '../index.ts';

/** Minimal iCalendar (RFC 5545) reading of VEVENTs and writing of a simple VEVENT. No recurrence rules: ask the server to expand. */

function unfold(ics: string): string[] {
  return ics.replace(/\r?\n[ \t]/g, '').split(/\r?\n/);
}

const unescapeText = (s: string) =>
  s.replace(/\\n/gi, '\n').replace(/\\([,;\\])/g, '$1');

/** Wall-clock time in an IANA zone -> epoch ms. */
export function zonedToEpoch(
  y: number,
  mo: number,
  d: number,
  h: number,
  mi: number,
  s: number,
  tz: string,
): number {
  const asUtc = Date.UTC(y, mo - 1, d, h, mi, s);
  try {
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: tz,
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    }).formatToParts(new Date(asUtc));
    const g = (t: string) => Number(parts.find((p) => p.type === t)!.value);
    const shown = Date.UTC(
      g('year'),
      g('month') - 1,
      g('day'),
      g('hour'),
      g('minute'),
      g('second'),
    );
    return asUtc - (shown - asUtc);
  } catch {
    return new Date(y, mo - 1, d, h, mi, s).getTime(); // unknown zone: local
  }
}

function parseDate(
  value: string,
  params: string,
): { t: number; allDay: boolean } | undefined {
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(
    value.trim(),
  );
  if (!m) return undefined;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (m[4] === undefined)
    return { t: new Date(y, mo - 1, d).getTime(), allDay: true };
  const [h, mi, s] = [Number(m[4]), Number(m[5]), Number(m[6])];
  if (m[7]) return { t: Date.UTC(y, mo - 1, d, h, mi, s), allDay: false };
  const tz = /TZID=([^;:]+)/i.exec(params)?.[1];
  return {
    t: tz
      ? zonedToEpoch(y, mo, d, h, mi, s, tz.replace(/"/g, ''))
      : new Date(y, mo - 1, d, h, mi, s).getTime(),
    allDay: false,
  };
}

export function parseEvents(ics: string, calendar?: string): CalendarEvent[] {
  const out: CalendarEvent[] = [];
  let cur: Record<string, { v: string; p: string }> | undefined;
  for (const line of unfold(ics)) {
    if (line === 'BEGIN:VEVENT') cur = {};
    else if (line === 'END:VEVENT' && cur) {
      const s = cur.DTSTART && parseDate(cur.DTSTART.v, cur.DTSTART.p);
      if (s && cur.STATUS?.v !== 'CANCELLED') {
        const e = cur.DTEND && parseDate(cur.DTEND.v, cur.DTEND.p);
        const dur = cur.DURATION ? parseDuration(cur.DURATION.v) : undefined;
        const end = e
          ? e.t
          : s.allDay
            ? s.t + 86_400_000
            : s.t + (dur ?? 3_600_000);
        const rid = cur['RECURRENCE-ID']?.v;
        out.push({
          id: (cur.UID?.v ?? randomUUID()) + (rid ? `#${rid}` : ''),
          title: unescapeText(cur.SUMMARY?.v ?? '(no title)'),
          start: s.t,
          end,
          ...(cur.LOCATION?.v
            ? { location: unescapeText(cur.LOCATION.v) }
            : {}),
          ...(s.allDay ? { allDay: true } : {}),
          ...(rid || cur.RRULE ? { recurring: true } : {}),
          ...(calendar ? { calendar } : {}),
        });
      }
      cur = undefined;
    } else if (cur) {
      const i = line.indexOf(':');
      if (i < 0) continue;
      const head = line.slice(0, i);
      const [name = '', ...params] = head.split(';');
      cur[name.toUpperCase()] = { v: line.slice(i + 1), p: params.join(';') };
    }
  }
  return out;
}

function parseDuration(d: string): number | undefined {
  const m =
    /^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(d);
  if (!m) return undefined;
  const n = (i: number) => Number(m[i] ?? 0);
  return ((n(1) * 7 + n(2)) * 86400 + n(3) * 3600 + n(4) * 60 + n(5)) * 1000;
}

const utc = (t: number) =>
  new Date(t).toISOString().replace(/[-:]/g, '').replace(/\.\d+/, '');
const esc = (s: string) =>
  s
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');

export function buildEvent(
  now: number,
  e: {
    title: string;
    start: number;
    end: number;
    location?: string;
    notes?: string;
  },
): { uid: string; ics: string } {
  const uid = `${randomUUID()}@lotti`;
  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Lotti//Brain//EN',
    'BEGIN:VEVENT',
    `UID:${uid}`,
    `DTSTAMP:${utc(now)}`,
    `DTSTART:${utc(e.start)}`,
    `DTEND:${utc(e.end)}`,
    `SUMMARY:${esc(e.title)}`,
    ...(e.location ? [`LOCATION:${esc(e.location)}`] : []),
    ...(e.notes ? [`DESCRIPTION:${esc(e.notes)}`] : []),
    'END:VEVENT',
    'END:VCALENDAR',
  ];
  return { uid, ics: lines.join('\r\n') + '\r\n' };
}
