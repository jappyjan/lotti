import { randomUUID } from 'node:crypto';
import type { CalendarEvent } from '../index.ts';

/** Minimal iCalendar (RFC 5545) reading of VEVENTs and writing of a simple VEVENT. No recurrence rules: ask the server to expand. */

export function unfold(ics: string): string[] {
  return ics.replace(/\r?\n[ \t]/g, '').split(/\r?\n/);
}

export const unescapeText = (s: string) =>
  s.replace(/\\n/gi, '\n').replace(/\\([,;\\])/g, '$1');

export function parseDuration(d: string): number | undefined {
  const m =
    /^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(d);
  if (!m) return undefined;
  const n = (i: number) => Number(m[i] ?? 0);
  return ((n(1) * 7 + n(2)) * 86400 + n(3) * 3600 + n(4) * 60 + n(5)) * 1000;
}

export type Props = Record<string, { v: string; p: string }[]>;

/** Index of the ':' that ends a property's name and parameters (a quoted parameter may contain ':'). */
function valueColon(line: string): number {
  const i = line.indexOf(':');
  const q = line.indexOf('"');
  if (q < 0 || i < q) return i;
  let quoted = false;
  for (let k = 0; k < line.length; k++) {
    const c = line[k];
    if (c === '"') quoted = !quoted;
    else if (c === ':' && !quoted) return k;
  }
  return -1;
}

/**
 * Every VEVENT as property lists (a property may repeat, e.g. EXDATE). The VEVENT's own components (VALARM)
 * are skipped: their UID / SUMMARY / DESCRIPTION are not the event's (iCloud alarms have both).
 */
export function readEvents(ics: string): Props[] {
  const out: Props[] = [];
  let cur: Props | undefined;
  let nested = 0;
  for (const line of unfold(ics)) {
    if (line === 'BEGIN:VEVENT') ((cur = {}), (nested = 0));
    else if (!cur) continue;
    else if (/^BEGIN:/i.test(line)) nested++;
    else if (nested) {
      if (/^END:/i.test(line)) nested--;
    } else if (line === 'END:VEVENT') {
      out.push(cur);
      cur = undefined;
    } else {
      const i = valueColon(line);
      if (i < 0) continue;
      const head = line.slice(0, i);
      const j = head.indexOf(';');
      const name = (j < 0 ? head : head.slice(0, j)).toUpperCase();
      (cur[name] ??= []).push({
        v: line.slice(i + 1),
        p: j < 0 ? '' : head.slice(j + 1),
      });
    }
  }
  return out;
}

/** The TZID parameter, quotes removed. */
export const tzidParam = (params: string): string | undefined => {
  const m = /(?:^|;)TZID=(?:"([^"]*)"|([^;]*))/i.exec(params);
  const v = (m?.[1] ?? m?.[2])?.trim();
  return v || undefined;
};

/** Windows zone names (Exchange / Outlook feeds) -> IANA. */
const WINDOWS_ZONES: Record<string, string> = {
  'W. Europe Standard Time': 'Europe/Berlin',
  'Central Europe Standard Time': 'Europe/Budapest',
  'Central European Standard Time': 'Europe/Warsaw',
  'Romance Standard Time': 'Europe/Paris',
  'GMT Standard Time': 'Europe/London',
  'GTB Standard Time': 'Europe/Bucharest',
  'E. Europe Standard Time': 'Europe/Chisinau',
  'FLE Standard Time': 'Europe/Helsinki',
  'Russian Standard Time': 'Europe/Moscow',
  'Turkey Standard Time': 'Europe/Istanbul',
  'Eastern Standard Time': 'America/New_York',
  'Central Standard Time': 'America/Chicago',
  'Mountain Standard Time': 'America/Denver',
  'Pacific Standard Time': 'America/Los_Angeles',
  'US Eastern Standard Time': 'America/Indianapolis',
  'Alaskan Standard Time': 'America/Anchorage',
  'India Standard Time': 'Asia/Kolkata',
  'China Standard Time': 'Asia/Shanghai',
  'Tokyo Standard Time': 'Asia/Tokyo',
  'Singapore Standard Time': 'Asia/Singapore',
  'AUS Eastern Standard Time': 'Australia/Sydney',
  'New Zealand Standard Time': 'Pacific/Auckland',
  'South Africa Standard Time': 'Africa/Johannesburg',
  UTC: 'UTC',
};

/** First place in Outlook's display names ("(UTC+01:00) Amsterdam, Berlin, ...") -> IANA. */
const DISPLAY_ZONES: Record<string, string> = {
  amsterdam: 'Europe/Berlin',
  brussels: 'Europe/Paris',
  belgrade: 'Europe/Budapest',
  sarajevo: 'Europe/Warsaw',
  dublin: 'Europe/London',
  athens: 'Europe/Bucharest',
  helsinki: 'Europe/Helsinki',
  moscow: 'Europe/Moscow',
  istanbul: 'Europe/Istanbul',
  'eastern time (us & canada)': 'America/New_York',
  'central time (us & canada)': 'America/Chicago',
  'mountain time (us & canada)': 'America/Denver',
  'pacific time (us & canada)': 'America/Los_Angeles',
  chennai: 'Asia/Kolkata',
  beijing: 'Asia/Shanghai',
  osaka: 'Asia/Tokyo',
  'kuala lumpur': 'Asia/Singapore',
  canberra: 'Australia/Sydney',
  auckland: 'Pacific/Auckland',
  'coordinated universal time': 'UTC',
};

/** An IANA name for a feed's TZID: IANA as is, Windows names, Outlook display names (else a fixed offset). */
export function normalizeTz(raw: string): string {
  const tz = raw.replace(/"/g, '').trim();
  const win = WINDOWS_ZONES[tz];
  if (win) return win;
  const m = /^\(UTC(?:([+-])(\d{2}):?(\d{2}))?\)\s*([^,]*)/i.exec(tz);
  if (!m) return tz;
  const known = DISPLAY_ZONES[m[4]!.trim().toLowerCase()];
  if (known) return known;
  // Unknown place: its offset without DST is closer than the server's zone.
  return m[1] ? `${m[1]}${m[2]}:${m[3]}` : 'UTC';
}

/** One formatter per zone (building one costs ~50 µs); null = unknown zone. */
const formatters = new Map<string, Intl.DateTimeFormat | null>();
function formatterFor(tz: string): Intl.DateTimeFormat | null {
  let f = formatters.get(tz);
  if (f !== undefined) return f;
  try {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: normalizeTz(tz),
      hourCycle: 'h23',
      year: 'numeric',
      month: 'numeric',
      day: 'numeric',
      hour: 'numeric',
      minute: 'numeric',
      second: 'numeric',
    });
  } catch {
    f = null;
  }
  if (formatters.size > 500) formatters.clear();
  formatters.set(tz, f);
  return f;
}

/** Wall-clock time in a zone (IANA, Windows or Outlook name) -> epoch ms. Unknown zone: server local. */
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
  const f = formatterFor(tz);
  if (!f || !Number.isFinite(asUtc))
    return new Date(y, mo - 1, d, h, mi, s).getTime();
  // Zone offset at an instant.
  const offset = (t: number) => {
    const parts = f.formatToParts(new Date(t));
    const g = (k: string) => Number(parts.find((p) => p.type === k)!.value);
    return (
      Date.UTC(
        g('year'),
        g('month') - 1,
        g('day'),
        g('hour'),
        g('minute'),
        g('second'),
      ) - t
    );
  };
  // Two passes: the offset at the first guess can differ on DST-change days.
  const o1 = offset(asUtc);
  const o2 = offset(asUtc - o1);
  if (o1 === o2) return asUtc - o1;
  const t2 = asUtc - o2;
  if (offset(t2) === o2) return t2;
  // A wall time skipped by the switch: read it with the offset from before (RFC 5545).
  return asUtc - Math.min(o1, o2);
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
  const tz = tzidParam(params);
  return {
    t: tz
      ? zonedToEpoch(y, mo, d, h, mi, s, tz)
      : new Date(y, mo - 1, d, h, mi, s).getTime(),
    allDay: false,
  };
}

export function parseEvents(ics: string, calendar?: string): CalendarEvent[] {
  const out: CalendarEvent[] = [];
  for (const p of readEvents(ics)) {
    const one = (k: string) => p[k]?.[0];
    const ds = one('DTSTART');
    const s = ds && parseDate(ds.v, ds.p);
    if (!s || one('STATUS')?.v === 'CANCELLED') continue;
    const de = one('DTEND');
    const e = de && parseDate(de.v, de.p);
    const du = one('DURATION');
    const dur = du ? parseDuration(du.v) : undefined;
    const end = e
      ? e.t
      : s.allDay
        ? s.t + 86_400_000
        : s.t + (dur ?? 3_600_000);
    const rid = one('RECURRENCE-ID')?.v;
    const loc = one('LOCATION')?.v;
    out.push({
      id: (one('UID')?.v ?? randomUUID()) + (rid ? `#${rid}` : ''),
      title: unescapeText(one('SUMMARY')?.v ?? '(no title)'),
      start: s.t,
      end,
      ...(loc ? { location: unescapeText(loc) } : {}),
      ...(s.allDay ? { allDay: true } : {}),
      ...(rid || p.RRULE || p.RDATE ? { recurring: true } : {}),
      ...(calendar ? { calendar } : {}),
    });
  }
  return out;
}

/**
 * The UIDs in a calendar resource, and whether it is a series: a repeat rule, a moved occurrence or several
 * VEVENTs. Only VEVENT lines count: a VTIMEZONE's daylight-saving RRULE does not make an event repeat.
 */
export function seriesInfo(ics: string): { uids: string[]; repeats: boolean } {
  const uids: string[] = [];
  let events = 0;
  let repeats = false;
  let inEvent = false;
  let nested = 0;
  for (const line of unfold(ics)) {
    if (line === 'BEGIN:VEVENT') ((inEvent = true), (nested = 0), events++);
    else if (inEvent && /^BEGIN:/i.test(line)) nested++;
    else if (inEvent && nested && /^END:/i.test(line)) nested--;
    else if (nested) continue;
    else if (line === 'END:VEVENT') inEvent = false;
    else if (inEvent && /^(RRULE|RDATE|RECURRENCE-ID)[:;]/i.test(line))
      repeats = true;
    else if (inEvent && /^UID[:;]/i.test(line))
      uids.push(line.replace(/^[^:]*:/, '').trim());
  }
  return { uids, repeats: repeats || events > 1 };
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
