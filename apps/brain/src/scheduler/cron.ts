/** Small cron parser (5 fields, local time): `m h dom mon dow` with *, lists, ranges, steps. dow 0-7 (0 and 7 = Sunday). */
interface Parsed {
  min: Set<number>;
  hour: Set<number>;
  dom: Set<number>;
  mon: Set<number>;
  dow: Set<number>;
  domStar: boolean;
  dowStar: boolean;
}

function field(s: string, lo: number, hi: number): Set<number> {
  const out = new Set<number>();
  for (const part of s.split(',')) {
    const [range, stepStr] = part.split('/');
    const step = stepStr ? Number(stepStr) : 1;
    if (!Number.isInteger(step) || step < 1)
      throw new Error(`Bad cron step in "${s}"`);
    let a: number;
    let b: number;
    if (range === '*') {
      a = lo;
      b = hi;
    } else if (range!.includes('-')) {
      const [x, y] = range!.split('-');
      a = Number(x);
      b = Number(y);
    } else {
      a = Number(range);
      b = stepStr ? hi : a;
    }
    if (
      !Number.isInteger(a) ||
      !Number.isInteger(b) ||
      a < lo ||
      b > hi ||
      a > b
    )
      throw new Error(`Bad cron field "${s}"`);
    for (let v = a; v <= b; v += step) out.add(v);
  }
  return out;
}

export function parseCron(expr: string): Parsed {
  const f = expr.trim().split(/\s+/);
  if (f.length !== 5) throw new Error(`Cron needs 5 fields, got "${expr}"`);
  const dow = field(f[4]!, 0, 7);
  if (dow.has(7)) dow.add(0);
  return {
    min: field(f[0]!, 0, 59),
    hour: field(f[1]!, 0, 23),
    dom: field(f[2]!, 1, 31),
    mon: field(f[3]!, 1, 12),
    dow,
    domStar: f[2] === '*',
    dowStar: f[4] === '*',
  };
}

export function isValidCron(expr: string): boolean {
  try {
    parseCron(expr);
    return true;
  } catch {
    return false;
  }
}

function matches(p: Parsed, d: Date): boolean {
  if (
    !p.min.has(d.getMinutes()) ||
    !p.hour.has(d.getHours()) ||
    !p.mon.has(d.getMonth() + 1)
  )
    return false;
  const domOk = p.dom.has(d.getDate());
  const dowOk = p.dow.has(d.getDay());
  if (p.domStar && p.dowStar) return true;
  if (p.domStar) return dowOk;
  if (p.dowStar) return domOk;
  return domOk || dowOk; // classic cron: either matches
}

/** Next fire time strictly after `after` (epoch ms). */
export function nextRun(expr: string, after: number): number {
  const p = parseCron(expr);
  const d = new Date(after);
  d.setSeconds(0, 0);
  d.setMinutes(d.getMinutes() + 1);
  for (let i = 0; i < 366 * 24 * 60; i++) {
    if (matches(p, d)) return d.getTime();
    d.setMinutes(d.getMinutes() + 1);
  }
  throw new Error(`Cron "${expr}" never fires`);
}

const DAYS: Record<string, number> = {
  sunday: 0,
  sun: 0,
  sonntag: 0,
  monday: 1,
  mon: 1,
  montag: 1,
  tuesday: 2,
  tue: 2,
  dienstag: 2,
  wednesday: 3,
  wed: 3,
  mittwoch: 3,
  thursday: 4,
  thu: 4,
  donnerstag: 4,
  friday: 5,
  fri: 5,
  freitag: 5,
  saturday: 6,
  sat: 6,
  samstag: 6,
};

function timeOf(s: string): { h: number; m: number } | null {
  const m = /(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/i.exec(s);
  if (!m) return null;
  let h = Number(m[1]);
  const min = Number(m[2] ?? 0);
  if (m[3]) {
    if (/pm/i.test(m[3]) && h < 12) h += 12;
    if (/am/i.test(m[3]) && h === 12) h = 0;
  }
  return h > 23 || min > 59 ? null : { h, m: min };
}

/**
 * Friendly schedule -> cron. Examples: "every 10 minutes", "hourly", "daily at 08:00", "täglich um 7:30",
 * "weekdays at 07:30", "every monday at 9:00", "weekly on friday at 17:00", "monthly at 09:00".
 */
export function friendlyToCron(text: string): string | null {
  const t = text.trim().toLowerCase();
  if (isValidCron(t)) return t;
  let m = /^(?:every|alle|jede[nr]?)\s+(\d+)\s*(?:min(?:ute)?s?|minuten)$/.exec(
    t,
  );
  if (m) return `*/${Number(m[1])} * * * *`;
  m = /^(?:every|alle)\s+(\d+)\s*(?:h|hours?|stunden?)$/.exec(t);
  if (m) return `0 */${Number(m[1])} * * *`;
  if (/^(hourly|stündlich|every hour|jede stunde)$/.test(t)) return '0 * * * *';
  const at = /(?:at|um)\s+(.+)$/.exec(t);
  const time = at ? timeOf(at[1]!) : null;
  const hm = time ? `${time.m} ${time.h}` : null;
  if (hm && /^(daily|every day|täglich|jeden tag)/.test(t))
    return `${hm} * * *`;
  if (
    hm &&
    /^(weekdays|werktags|every weekday|montags? (?:bis|-) freitags?)/.test(t)
  )
    return `${hm} * * 1-5`;
  if (hm && /^(weekends|am wochenende)/.test(t)) return `${hm} * * 0,6`;
  if (hm && /^(monthly|monatlich|jeden monat)/.test(t)) return `${hm} 1 * *`;
  if (hm) {
    for (const [name, n] of Object.entries(DAYS)) {
      if (
        new RegExp(`\\b${name}s?\\b`).test(t) &&
        /(every|weekly|on|jeden|wöchentlich|am)/.test(t)
      )
        return `${hm} * * ${n}`;
    }
  }
  return null;
}

/** Cron or friendly text -> {cron, text}. Throws on garbage. */
export function resolveSchedule(input: string): { cron: string; text: string } {
  const cron = friendlyToCron(input);
  if (!cron)
    throw new Error(
      `Could not understand schedule "${input}". Use cron ("0 8 * * *") or e.g. "daily at 08:00", "every 30 minutes", "weekdays at 07:30".`,
    );
  return {
    cron,
    text: isValidCron(input.trim()) ? input.trim() : input.trim(),
  };
}
