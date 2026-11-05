import type { CalendarEvent } from '../index.ts';
import {
  normalizeTz,
  parseDuration,
  type Props,
  readEvents,
  tzidParam,
  unescapeText,
  zonedToEpoch,
} from './ics.ts';

/**
 * Reads a whole iCalendar feed (an ICS subscription) and expands recurring events for a time window.
 * Supports RRULE FREQ=DAILY|WEEKLY|MONTHLY|YEARLY with INTERVAL, COUNT, UNTIL, WKST, BYDAY (with ordinals),
 * BYMONTHDAY, BYMONTH; EXDATE; RECURRENCE-ID overrides; TZID (IANA, Windows and Outlook display names);
 * floating, UTC and all-day values. Not supported: RDATE, BYSETPOS, BYWEEKNO/BYYEARDAY, sub-daily rules.
 */

const DAY = 86_400_000;
/** Instances near the window one series may produce. */
const MAX_NEAR = 20_000;
/** Instances before the window one series may step through (only COUNT series do, to count). */
const MAX_SKIPPED = 200_000;
const MAX_PERIODS = 60_000;
/** A feed cannot make one expansion return more than this many events. */
const MAX_EVENTS = 5_000;

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
  const raw = tzidParam(params);
  const tz = m[7] ? 'UTC' : raw ? normalizeTz(raw) : fallbackTz;
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

// ---- RRULE -----------------------------------------------------------------------------------------------

const WD = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];

interface Rule {
  freq: 'DAILY' | 'WEEKLY' | 'MONTHLY' | 'YEARLY';
  interval: number;
  count?: number;
  until?: string;
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
  const nums = (s: string | undefined, ok: (n: number) => boolean) => [
    ...new Set(
      (s ? s.split(',') : [])
        .map(Number)
        .filter((n) => Number.isInteger(n) && ok(n)),
    ),
  ];
  const byDay = (kv.BYDAY ? kv.BYDAY.split(',') : []).flatMap((x) => {
    const m = /^([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/.exec(x.trim());
    return m ? [{ n: m[1] ? Number(m[1]) : 0, wd: WD.indexOf(m[2]!) }] : [];
  });
  const wkst = WD.indexOf(kv.WKST ?? 'MO');
  return {
    freq: kv.FREQ as Rule['freq'],
    interval: Math.max(1, Number(kv.INTERVAL ?? 1) || 1),
    ...(kv.COUNT ? { count: Number(kv.COUNT) } : {}),
    ...(kv.UNTIL ? { until: kv.UNTIL } : {}),
    byDay,
    byMonthDay: nums(kv.BYMONTHDAY, (n) => n !== 0 && Math.abs(n) <= 31),
    byMonth: nums(kv.BYMONTH, (n) => n >= 1 && n <= 12).sort((a, b) => a - b),
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

/** Days `first`..`last` (day numbers) that fall on weekday `wd`: all of them (n = 0), the nth, or the nth from the end. */
function weekdaysIn(
  first: number,
  last: number,
  n: number,
  wd: number,
): number[] {
  const a = first + ((wd - weekday(first) + 7) % 7);
  if (n === 0) {
    const all: number[] = [];
    for (let d = a; d <= last; d += 7) all.push(d);
    return all;
  }
  const d =
    n > 0 ? a + 7 * (n - 1) : a + 7 * Math.floor((last - a) / 7) + 7 * (n + 1);
  return d >= first && d <= last ? [d] : [];
}

/** Days (day numbers) of one month selected by BYDAY (with ordinals) and BYMONTHDAY; `baseDay` = the DTSTART day of month when neither is given. */
function monthDays(y: number, mo: number, r: Rule, baseDay: number): number[] {
  const dim = daysInMonth(y, mo);
  const d1 = dayNum(y, mo, 1);
  let days: number[] | undefined;
  if (r.byMonthDay.length)
    days = r.byMonthDay
      .map((d) => (d < 0 ? dim + d + 1 : d))
      .filter((d) => d >= 1 && d <= dim)
      .map((d) => d1 + d - 1);
  if (r.byDay.length) {
    const sel = new Set<number>();
    for (const { n, wd } of r.byDay)
      for (const d of weekdaysIn(d1, d1 + dim - 1, n, wd)) sel.add(d);
    days = days ? days.filter((d) => sel.has(d)) : [...sel];
  }
  if (!days) days = baseDay <= dim ? [d1 + baseDay - 1] : [];
  return [...new Set(days)].sort((a, b) => a - b);
}

/**
 * Start days (day numbers, wall clock) of a rule after DTSTART, lazily and in order. Starts at the period that
 * holds `minDay` and stops once a period starts after `maxDay`.
 */
function* ruleDays(
  start: Dt,
  r: Rule,
  minDay: number,
  maxDay: number,
): Generator<number> {
  const startDay = dayNum(start.y, start.mo, start.d);
  const monthOk = (n: number) =>
    !r.byMonth.length || r.byMonth.includes(fromDayNum(n).mo);
  const dayOk = (n: number) => {
    if (!r.byMonthDay.length) return true;
    const f = fromDayNum(n);
    const dim = daysInMonth(f.y, f.mo);
    return r.byMonthDay.some((d) => (d < 0 ? dim + d + 1 : d) === f.d);
  };
  const week0 = startDay - ((weekday(startDay) - r.wkst + 7) % 7);
  const month0 = start.y * 12 + (start.mo - 1);
  const skip = Math.max(0, minDay - startDay);
  const min = fromDayNum(Math.max(minDay, startDay));
  const k0 = !skip
    ? 0
    : r.freq === 'DAILY'
      ? Math.floor(skip / r.interval)
      : r.freq === 'WEEKLY'
        ? Math.floor((minDay - week0) / (7 * r.interval))
        : r.freq === 'MONTHLY'
          ? Math.floor((min.y * 12 + min.mo - 1 - month0) / r.interval)
          : Math.floor((min.y - start.y) / r.interval);
  for (let k = Math.max(0, k0); k < k0 + MAX_PERIODS; k++) {
    let cands: number[] = [];
    let periodStart: number;
    if (r.freq === 'DAILY') {
      const n = startDay + k * r.interval;
      periodStart = n;
      if (
        n <= maxDay &&
        monthOk(n) &&
        dayOk(n) &&
        (!r.byDay.length || r.byDay.some((b) => b.wd === weekday(n)))
      )
        cands = [n];
    } else if (r.freq === 'WEEKLY') {
      const ws = week0 + k * 7 * r.interval;
      periodStart = ws;
      const wds = r.byDay.length
        ? r.byDay.map((b) => b.wd)
        : [weekday(startDay)];
      for (let i = 0; i < 7; i++) {
        const n = ws + i;
        if (wds.includes(weekday(n)) && monthOk(n) && dayOk(n)) cands.push(n);
      }
    } else if (r.freq === 'MONTHLY') {
      const m0 = month0 + k * r.interval;
      const y = Math.floor(m0 / 12);
      const mo = (m0 % 12) + 1;
      periodStart = dayNum(y, mo, 1);
      if (
        Number.isFinite(periodStart) &&
        (!r.byMonth.length || r.byMonth.includes(mo))
      )
        cands = monthDays(y, mo, r, start.d);
    } else {
      const y = start.y + k * r.interval;
      periodStart = dayNum(y, 1, 1);
      if (!Number.isFinite(periodStart)) return;
      if (
        r.byDay.some((b) => b.n !== 0) &&
        !r.byMonth.length &&
        !r.byMonthDay.length
      ) {
        // Ordinal weekday of the whole year, e.g. 20th Monday.
        const sel = new Set<number>();
        for (const { n, wd } of r.byDay)
          for (const d of weekdaysIn(periodStart, dayNum(y, 12, 31), n, wd))
            sel.add(d);
        cands = [...sel].sort((a, b) => a - b);
      } else {
        // BYMONTHDAY or BYDAY without BYMONTH: every month of the year.
        const months = r.byMonth.length
          ? r.byMonth
          : r.byMonthDay.length || r.byDay.length
            ? [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
            : [start.mo];
        for (const mo of months) cands.push(...monthDays(y, mo, r, start.d));
      }
    }
    // Past the window (or beyond the calendar's range, e.g. a huge INTERVAL): nothing more to find.
    if (!Number.isFinite(periodStart) || periodStart > maxDay) return;
    for (const n of cands) if (n > startDay) yield n;
  }
}

// ---- parsed feed ---------------------------------------------------------------------------------------

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

interface Instance {
  start: number;
  end: number;
  allDay: boolean;
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

interface Text {
  title: string;
  location?: string;
}
interface Single extends Text, Instance {
  id: string;
}
interface Series extends Text {
  uid: string;
  start: Dt;
  sp: Span;
  rule: Rule;
  exdates: Set<number>;
  /** Date-only UNTIL: the last day (wall clock of the event) that may hold an instance. */
  untilDay?: number;
  /** Date-time UNTIL: the latest instance start. */
  untilMs?: number;
}
/** A feed parsed once (zone conversions done), ready to expand for any window. */
export interface Feed {
  singles: Single[];
  series: Series[];
  /** `uid|original start` of instances an override replaces or cancels. */
  overrides: Set<string>;
  /** VEVENTs in the feed. */
  count: number;
}

const first = (p: Props, k: string) => p[k]?.[0];

export function parseFeed(ics: string): Feed {
  const events = readEvents(ics);
  const feed: Feed = {
    singles: [],
    series: [],
    overrides: new Set(),
    count: events.length,
  };
  const tzOf = (p: Props) =>
    parseDt(first(p, 'DTSTART')?.v ?? '', first(p, 'DTSTART')?.p ?? '')?.tz;
  const masterTz = new Map<string, string | undefined>();
  for (const p of events)
    if (!first(p, 'RECURRENCE-ID') && first(p, 'UID'))
      masterTz.set(first(p, 'UID')!.v, tzOf(p));

  for (const p of events) {
    const ds = first(p, 'DTSTART');
    const start = ds && parseDt(ds.v, ds.p);
    if (!ds || !start) continue;
    const uid = first(p, 'UID')?.v ?? `${toEpoch(start)}`;
    const de = first(p, 'DTEND') ?? first(p, 'DUE');
    const end = de ? parseDt(de.v, de.p, start.tz) : undefined;
    const du = first(p, 'DURATION');
    const sp = span(start, end, du ? parseDuration(du.v) : undefined);
    const loc = first(p, 'LOCATION')?.v;
    const text: Text = {
      title: unescapeText(first(p, 'SUMMARY')?.v ?? '(no title)'),
      ...(loc ? { location: unescapeText(loc) } : {}),
    };
    const cancelled = first(p, 'STATUS')?.v.toUpperCase() === 'CANCELLED';
    const rid = first(p, 'RECURRENCE-ID');
    if (rid) {
      const orig = toEpoch(parseDt(rid.v, rid.p, masterTz.get(uid)) ?? start);
      feed.overrides.add(`${uid}|${orig}`);
      if (!cancelled)
        feed.singles.push({
          ...text,
          ...instanceAt(start, sp),
          id: `${uid}#${orig}`,
        });
      continue;
    }
    if (cancelled) continue;
    const rr = first(p, 'RRULE');
    const rule = rr && parseRule(rr.v);
    if (!rule) {
      feed.singles.push({ ...text, ...instanceAt(start, sp), id: uid });
      continue;
    }
    const exdates = new Set<number>();
    for (const x of p.EXDATE ?? [])
      for (const v of x.v.split(',')) {
        const dt = parseDt(v, x.p, start.tz);
        if (dt) exdates.add(toEpoch(dt));
      }
    // A date-only UNTIL covers that whole day in the event's own zone (never the server's).
    const until = rule.until ? parseDt(rule.until, '', start.tz) : undefined;
    feed.series.push({
      ...text,
      uid,
      start,
      sp,
      rule,
      exdates,
      ...(until?.allDay
        ? { untilDay: dayNum(until.y, until.mo, until.d) }
        : until
          ? { untilMs: toEpoch(until) }
          : {}),
    });
  }
  return feed;
}

// ---- expansion -----------------------------------------------------------------------------------------

/** Events of a parsed feed that overlap [from, to), recurrences expanded, sorted by start. */
export function expandFeed(
  feed: Feed,
  from: number,
  to: number,
  calendar?: string,
): CalendarEvent[] {
  const out: CalendarEvent[] = [];
  const emit = (x: Text, inst: Instance, id: string) => {
    if (!Number.isFinite(inst.start) || !Number.isFinite(inst.end)) return;
    if (out.length >= MAX_EVENTS) return;
    if (inst.end <= from || inst.start >= to) return;
    out.push({
      id,
      title: x.title,
      start: inst.start,
      end: inst.end,
      ...(x.location ? { location: x.location } : {}),
      ...(inst.allDay ? { allDay: true } : {}),
      ...(calendar ? { calendar } : {}),
    });
  };
  for (const s of feed.singles) emit(s, s, s.id);

  // Wall-clock day numbers are within ±14 h of UTC days: compare days first, convert zones only near the window.
  const fromDay = Math.floor(from / DAY);
  const toDay = Math.floor(to / DAY) + 2;
  for (const s of feed.series) {
    if (out.length >= MAX_EVENTS) break;
    const { rule, sp } = s;
    const startDay = dayNum(s.start.y, s.start.mo, s.start.d);
    const lowDay =
      fromDay - ('days' in sp ? sp.days + 1 : Math.ceil(sp.ms / DAY)) - 2;
    let maxDay = toDay;
    if (s.untilDay !== undefined) maxDay = Math.min(maxDay, s.untilDay);
    if (s.untilMs !== undefined)
      maxDay = Math.min(maxDay, Math.floor(s.untilMs / DAY) + 2);
    let n = 0;
    let skipped = 0;
    let near = 0;
    /** One instance of the series; false = the series ends here. */
    const visit = (day: number): boolean => {
      if (rule.count !== undefined && n >= rule.count) return false;
      if (day > maxDay) return false;
      n++;
      if (day < lowDay) return ++skipped <= MAX_SKIPPED;
      if (++near > MAX_NEAR) return false;
      const inst = instanceAt({ ...s.start, ...fromDayNum(day) }, sp);
      if (!Number.isFinite(inst.start)) return false;
      if (s.untilMs !== undefined && inst.start > s.untilMs) return false;
      if (inst.start >= to) return false;
      if (
        !s.exdates.has(inst.start) &&
        !feed.overrides.has(`${s.uid}|${inst.start}`)
      )
        emit(s, inst, `${s.uid}#${inst.start}`);
      return true;
    };
    // DTSTART is always the first instance (and counts toward COUNT), even if the rule would not pick it.
    if (!visit(startDay)) continue;
    // Without COUNT nothing before the window matters: the rule starts at the window.
    const minDay = rule.count === undefined ? lowDay : startDay;
    for (const day of ruleDays(s.start, rule, minDay, maxDay))
      if (!visit(day)) break;
  }
  return out.sort((a, b) => a.start - b.start);
}

/** Events of an ICS feed that overlap [from, to), recurrences expanded, sorted by start. */
export const expandEvents = (
  ics: string,
  from: number,
  to: number,
  calendar?: string,
): CalendarEvent[] => expandFeed(parseFeed(ics), from, to, calendar);
