import type { CalendarEvent } from '../index.ts';
import { zonedToEpoch } from './ics.ts';

/**
 * Reads a whole iCalendar feed (an ICS subscription) and expands recurring events for a time window.
 * Supports RRULE FREQ=DAILY|WEEKLY|MONTHLY|YEARLY with INTERVAL, COUNT, UNTIL, WKST, BYDAY (with ordinals),
 * BYMONTHDAY, BYMONTH; EXDATE; RECURRENCE-ID overrides; TZID (IANA and the common Windows names);
 * floating, UTC and all-day values. Not supported: RDATE, BYSETPOS, BYWEEKNO/BYYEARDAY, sub-daily rules.
 */

const DAY = 86_400_000;
const MAX_OCCURRENCES = 20_000;
const MAX_PERIODS = 60_000;
/** A feed cannot make one expansion return more than this many events. */
const MAX_EVENTS = 5_000;

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

/** Wall-clock fields plus the zone they are in. tz: IANA name, 'UTC', or undefined (floating = server local). */
interface Dt {
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
  tz?: string;
  allDay: boolean;
}

const toEpoch = (x: Dt): number =>
  x.allDay || !x.tz
    ? new Date(x.y, x.mo - 1, x.d, x.h, x.mi, x.s).getTime()
    : x.tz === 'UTC'
      ? Date.UTC(x.y, x.mo - 1, x.d, x.h, x.mi, x.s)
      : zonedToEpoch(x.y, x.mo, x.d, x.h, x.mi, x.s, x.tz);

function parseDt(
  value: string,
  params: string,
  fallbackTz?: string,
): Dt | undefined {
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(
    value.trim(),
  );
  if (!m) return undefined;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (m[4] === undefined) return { y, mo, d, h: 0, mi: 0, s: 0, allDay: true };
  const raw = /TZID=([^;:]+)/i.exec(params)?.[1]?.replace(/"/g, '');
  const tz = m[7] ? 'UTC' : raw ? (WINDOWS_ZONES[raw] ?? raw) : fallbackTz;
  return {
    y,
    mo,
    d,
    h: Number(m[4]),
    mi: Number(m[5]),
    s: Number(m[6]),
    allDay: false,
    ...(tz ? { tz } : {}),
  };
}

const unescapeText = (s: string) =>
  s.replace(/\\n/gi, '\n').replace(/\\([,;\\])/g, '$1');

type Props = Record<string, { v: string; p: string }[]>;

/** Every VEVENT of the feed as property lists (a property may repeat, e.g. EXDATE). */
function readEvents(ics: string): Props[] {
  const out: Props[] = [];
  let cur: Props | undefined;
  for (const line of ics.replace(/\r?\n[ \t]/g, '').split(/\r?\n/)) {
    if (line === 'BEGIN:VEVENT') cur = {};
    else if (line === 'END:VEVENT') {
      if (cur) out.push(cur);
      cur = undefined;
    } else if (cur) {
      const i = line.indexOf(':');
      if (i < 0) continue;
      const [name = '', ...params] = line.slice(0, i).split(';');
      (cur[name.toUpperCase()] ??= []).push({
        v: line.slice(i + 1),
        p: params.join(';'),
      });
    }
  }
  return out;
}

export const countEvents = (ics: string): number => readEvents(ics).length;

// ---- RRULE -----------------------------------------------------------------------------------------------

const WD = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

interface Rule {
  freq: 'DAILY' | 'WEEKLY' | 'MONTHLY' | 'YEARLY';
  interval: number;
  count?: number;
  until?: Dt;
  byDay: { n: number; wd: number }[];
  byMonthDay: number[];
  byMonth: number[];
  wkst: number;
}

function parseRule(v: string): Rule | undefined {
  const kv = Object.fromEntries(
    v.split(';').map((x) => {
      const i = x.indexOf('=');
      return [x.slice(0, i).toUpperCase(), x.slice(i + 1)];
    }),
  ) as Record<string, string>;
  if (!['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'].includes(kv.FREQ ?? ''))
    return undefined;
  // Parts we cannot evaluate: ignoring them would invent events, so the series is not expanded.
  if (kv.BYSETPOS || kv.BYWEEKNO || kv.BYYEARDAY) return undefined;
  const nums = (s?: string) =>
    (s ? s.split(',') : []).map(Number).filter((n) => Number.isInteger(n));
  const byDay = (kv.BYDAY ? kv.BYDAY.split(',') : []).flatMap((x) => {
    const m = /^([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/.exec(x.trim());
    return m ? [{ n: m[1] ? Number(m[1]) : 0, wd: WD.indexOf(m[2]!) }] : [];
  });
  const until = kv.UNTIL ? parseDt(kv.UNTIL, '') : undefined;
  const wkst = WD.indexOf(kv.WKST ?? 'MO');
  return {
    freq: kv.FREQ as Rule['freq'],
    interval: Math.max(1, Number(kv.INTERVAL ?? 1) || 1),
    ...(kv.COUNT ? { count: Number(kv.COUNT) } : {}),
    ...(until ? { until } : {}),
    byDay,
    byMonthDay: nums(kv.BYMONTHDAY),
    byMonth: nums(kv.BYMONTH),
    wkst: wkst < 0 ? 1 : wkst,
  };
}

const dayNum = (y: number, mo: number, d: number) =>
  Math.floor(Date.UTC(y, mo - 1, d) / DAY);
const fromDayNum = (n: number) => {
  const x = new Date(n * DAY);
  return { y: x.getUTCFullYear(), mo: x.getUTCMonth() + 1, d: x.getUTCDate() };
};
const weekday = (n: number) => (((n + 4) % 7) + 7) % 7; // 1970-01-01 was a Thursday
const daysInMonth = (y: number, mo: number) =>
  new Date(Date.UTC(y, mo, 0)).getUTCDate();

/** Days (day numbers) of one month selected by BYDAY (with ordinals) and BYMONTHDAY; `base` = the DTSTART day of month when neither is given. */
function monthDays(y: number, mo: number, r: Rule, baseDay: number): number[] {
  const dim = daysInMonth(y, mo);
  let days: number[] | undefined;
  if (r.byMonthDay.length)
    days = r.byMonthDay
      .map((d) => (d < 0 ? dim + d + 1 : d))
      .filter((d) => d >= 1 && d <= dim);
  if (r.byDay.length) {
    const sel = new Set<number>();
    for (const { n, wd } of r.byDay) {
      const all: number[] = [];
      for (let d = 1; d <= dim; d++)
        if (weekday(dayNum(y, mo, d)) === wd) all.push(d);
      if (n === 0) all.forEach((d) => sel.add(d));
      else {
        const pick = n > 0 ? all[n - 1] : all[all.length + n];
        if (pick !== undefined) sel.add(pick);
      }
    }
    days = days ? days.filter((d) => sel.has(d)) : [...sel];
  }
  if (!days) days = baseDay <= dim ? [baseDay] : [];
  return days.sort((a, b) => a - b).map((d) => dayNum(y, mo, d));
}

/** Start dates (wall clock) of a rule, lazily and in order. */
function* ruleDays(start: Dt, r: Rule): Generator<number> {
  const startDay = dayNum(start.y, start.mo, start.d);
  const monthOk = (n: number) =>
    !r.byMonth.length || r.byMonth.includes(fromDayNum(n).mo);
  for (let k = 0; k < MAX_PERIODS; k++) {
    let cands: number[] = [];
    if (r.freq === 'DAILY') {
      const n = startDay + k * r.interval;
      const f = fromDayNum(n);
      const dim = daysInMonth(f.y, f.mo);
      if (
        monthOk(n) &&
        (!r.byMonthDay.length ||
          r.byMonthDay.some((d) => (d < 0 ? dim + d + 1 : d) === f.d)) &&
        (!r.byDay.length || r.byDay.some((b) => b.wd === weekday(n)))
      )
        cands = [n];
    } else if (r.freq === 'WEEKLY') {
      const ws =
        startDay - ((weekday(startDay) - r.wkst + 7) % 7) + k * 7 * r.interval;
      const wds = r.byDay.length
        ? r.byDay.map((b) => b.wd)
        : [weekday(startDay)];
      cands = [...Array(7).keys()]
        .map((i) => ws + i)
        .filter((n) => wds.includes(weekday(n)) && monthOk(n))
        .filter((n) => {
          if (!r.byMonthDay.length) return true;
          const f = fromDayNum(n);
          const dim = daysInMonth(f.y, f.mo);
          return r.byMonthDay.some((d) => (d < 0 ? dim + d + 1 : d) === f.d);
        });
    } else if (r.freq === 'MONTHLY') {
      const m0 = start.y * 12 + (start.mo - 1) + k * r.interval;
      const y = Math.floor(m0 / 12);
      const mo = (m0 % 12) + 1;
      if (!r.byMonth.length || r.byMonth.includes(mo))
        cands = monthDays(y, mo, r, start.d);
    } else {
      const y = start.y + k * r.interval;
      const months = r.byMonth.length
        ? [...r.byMonth].sort((a, b) => a - b)
        : [start.mo];
      if (
        r.byDay.some((b) => b.n !== 0) &&
        !r.byMonth.length &&
        !r.byMonthDay.length
      ) {
        // Ordinal weekday of the whole year, e.g. 20th Monday.
        for (const { n, wd } of r.byDay) {
          const all: number[] = [];
          for (let d = dayNum(y, 1, 1); d <= dayNum(y, 12, 31); d++)
            if (weekday(d) === wd) all.push(d);
          const pick =
            n === 0 ? all : [n > 0 ? all[n - 1] : all[all.length + n]];
          cands.push(...pick.filter((x): x is number => x !== undefined));
        }
        cands.sort((a, b) => a - b);
      } else
        for (const mo of months) cands.push(...monthDays(y, mo, r, start.d));
    }
    for (const n of cands) if (n >= startDay) yield n;
    // Stop condition for runaway rules is the caller's (window end / COUNT / UNTIL / MAX_OCCURRENCES).
  }
}

// ---- expansion -----------------------------------------------------------------------------------------

interface Instance {
  start: number;
  end: number;
  allDay: boolean;
}

type Span = { days: number } | { ms: number };
function span(start: Dt, end: Dt | undefined, dur: number | undefined): Span {
  // Wall-clock length is kept for all-day events (days); timed events keep their absolute length.
  if (start.allDay) {
    const days = end
      ? Math.max(
          1,
          dayNum(end.y, end.mo, end.d) - dayNum(start.y, start.mo, start.d),
        )
      : 1;
    return { days };
  }
  const ms = end ? toEpoch(end) - toEpoch(start) : (dur ?? 3_600_000);
  return { ms: ms >= 0 ? ms : 0 };
}

function parseDuration(d: string): number | undefined {
  const m =
    /^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(d);
  if (!m) return undefined;
  const n = (i: number) => Number(m[i] ?? 0);
  return ((n(1) * 7 + n(2)) * 86400 + n(3) * 3600 + n(4) * 60 + n(5)) * 1000;
}

function instanceAt(start: Dt, sp: Span): Instance {
  const s = toEpoch(start);
  if ('days' in sp)
    return {
      start: s,
      end: new Date(start.y, start.mo - 1, start.d + sp.days).getTime(),
      allDay: true,
    };
  return { start: s, end: s + sp.ms, allDay: false };
}

const first = (p: Props, k: string) => p[k]?.[0];

/** Events of an ICS feed that overlap [from, to), recurrences expanded, sorted by start. */
export function expandEvents(
  ics: string,
  from: number,
  to: number,
  calendar?: string,
): CalendarEvent[] {
  const events = readEvents(ics);
  const out: CalendarEvent[] = [];
  const overrides = new Map<string, Props>();
  const overrideList: Props[] = [];
  const tzOf = (p: Props) =>
    parseDt(first(p, 'DTSTART')?.v ?? '', first(p, 'DTSTART')?.p ?? '')?.tz;
  for (const p of events) if (first(p, 'RECURRENCE-ID')) overrideList.push(p);
  // Overrides first, so overrideList can skip the instance they replace.
  const masterTz = new Map<string, string | undefined>();
  for (const p of events)
    if (!first(p, 'RECURRENCE-ID') && first(p, 'UID'))
      masterTz.set(first(p, 'UID')!.v, tzOf(p));
  for (const p of overrideList) {
    const rid = first(p, 'RECURRENCE-ID')!;
    const uid = first(p, 'UID')?.v ?? '';
    const dt = parseDt(rid.v, rid.p, masterTz.get(uid));
    if (dt) overrides.set(`${uid}|${toEpoch(dt)}`, p);
  }

  const emit = (p: Props, inst: Instance, id: string) => {
    if (!Number.isFinite(inst.start) || !Number.isFinite(inst.end)) return;
    if (out.length >= MAX_EVENTS) return;
    if (inst.end <= from || inst.start >= to) return;
    const loc = first(p, 'LOCATION')?.v;
    out.push({
      id,
      title: unescapeText(first(p, 'SUMMARY')?.v ?? '(no title)'),
      start: inst.start,
      end: inst.end,
      ...(loc ? { location: unescapeText(loc) } : {}),
      ...(inst.allDay ? { allDay: true } : {}),
      ...(calendar ? { calendar } : {}),
    });
  };

  for (const p of events) {
    if (out.length >= MAX_EVENTS) break;
    const ds = first(p, 'DTSTART');
    const start = ds && parseDt(ds.v, ds.p);
    if (!ds || !start) continue;
    const uid = first(p, 'UID')?.v ?? `${toEpoch(start)}`;
    const de = first(p, 'DTEND') ?? first(p, 'DUE');
    const end = de ? parseDt(de.v, de.p, start.tz) : undefined;
    const dur = first(p, 'DURATION')
      ? parseDuration(first(p, 'DURATION')!.v)
      : undefined;
    const sp = span(start, end, dur);
    const cancelled = first(p, 'STATUS')?.v.toUpperCase() === 'CANCELLED';
    const rid = first(p, 'RECURRENCE-ID');
    if (rid) {
      if (!cancelled)
        emit(
          p,
          instanceAt(start, sp),
          `${uid}#${toEpoch(parseDt(rid.v, rid.p, masterTz.get(uid)) ?? start)}`,
        );
      continue;
    }
    if (cancelled) continue;
    const rr = first(p, 'RRULE');
    const rule = rr && parseRule(rr.v);
    if (!rule) {
      emit(p, instanceAt(start, sp), uid);
      continue;
    }
    const exdates = new Set<number>();
    for (const x of p.EXDATE ?? [])
      for (const v of x.v.split(',')) {
        const dt = parseDt(v, x.p, start.tz);
        if (dt) exdates.add(toEpoch(dt));
      }
    const until = rule.until
      ? rule.until.allDay
        ? toEpoch(rule.until) + DAY
        : toEpoch(rule.until) + 1
      : Infinity;
    let n = 0;
    for (const day of ruleDays(start, rule)) {
      const f = fromDayNum(day);
      const occ: Dt = { ...start, ...f };
      const inst = instanceAt(occ, sp);
      // A date beyond the calendar's range (huge INTERVAL) ends the series.
      if (!Number.isFinite(inst.start)) break;
      if (inst.start >= until) break;
      if (rule.count !== undefined && n >= rule.count) break;
      if (++n > MAX_OCCURRENCES) break;
      if (inst.start >= to) break;
      if (exdates.has(inst.start) || overrides.has(`${uid}|${inst.start}`))
        continue;
      emit(p, inst, `${uid}#${inst.start}`);
    }
  }
  return out.sort((a, b) => a.start - b.start);
}
