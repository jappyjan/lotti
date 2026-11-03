import type { App } from './app.ts';
import { runJobPrompt } from './agent/loop.ts';
import { DAY, HOUR, humanLocal, isoLocal } from './util/clock.ts';
import { newId } from './util/crypto.ts';

export const PRESENCE_EVENTS = [
  'glasses_worn',
  'glasses_removed',
  'glasses_connected',
  'glasses_disconnected',
  'gesture',
  'head_up',
  'phone_unlock',
  'app_open',
  'phone_charging',
  'phone_unplugged',
  'phone_still',
  'phone_moving',
] as const;
export type PresenceEvent = (typeof PRESENCE_EVENTS)[number];

/** Signs that Jan is around (any surface). Passive phone signals and removal events are not activity. */
const ACTIVITY = new Set<string>([
  'glasses_worn',
  'glasses_connected',
  'gesture',
  'head_up',
  'phone_unlock',
  'app_open',
]);
/** Phone use: breaks "slept". */
const PHONE_USE = new Set<string>(['phone_unlock', 'app_open']);

export type ReturnReason = 'away' | 'slept';

export interface PresenceDecision {
  triggered: boolean;
  reason?: ReturnReason;
  awayMs?: number;
}

const toMin = (s: string) => {
  const [h, m] = s.split(':').map(Number);
  return (h ?? 0) * 60 + (m ?? 0);
};

/** Milliseconds of [start,end] that lie inside the daily night window (e.g. 22:00-09:00). */
export function nightOverlapMs(
  start: number,
  end: number,
  nightStart: string,
  nightEnd: string,
): number {
  let total = 0;
  const day0 = new Date(start);
  day0.setHours(0, 0, 0, 0);
  for (let d = day0.getTime() - DAY; d <= end; d += DAY) {
    const base = new Date(d);
    const a = new Date(base);
    a.setHours(0, toMin(nightStart), 0, 0);
    const b = new Date(base);
    b.setHours(0, toMin(nightEnd), 0, 0);
    let wStart = a.getTime();
    let wEnd = b.getTime();
    if (wEnd <= wStart) wEnd += DAY; // wraps over midnight
    total += Math.max(0, Math.min(end, wEnd) - Math.max(start, wStart));
  }
  return total;
}

/**
 * Presence signals -> return detection -> one short brief.
 *  - away: no activity for catchup.away_hours (default 2 h), then activity again.
 *  - slept: no phone use across >= catchup.sleep_min_hours of the night window (22:00-09:00) while the phone was
 *    quiet: charging (a state: phone_charging .. phone_unplugged) for >= 1 h of that night, or reported still.
 *    Works without wear events.
 * Once per return: a brief resets the reference point (lastCatchup).
 */
export class CatchupService {
  constructor(private app: App) {}

  private kv(key: string): number | null {
    const v = this.app.settings.kvGet('presence.' + key);
    return v === undefined ? null : Number(v);
  }
  private setKv(key: string, v: number): void {
    this.app.settings.kvSet('presence.' + key, String(v));
  }

  /** Record a presence event, evaluate the rules. Returns the decision (a brief is generated asynchronously if triggered). */
  async onPresence(
    event: string,
    at: number,
    detail?: string,
  ): Promise<PresenceDecision> {
    const app = this.app;
    const now = app.clock.now();
    const prevActivity = this.kv('last_activity');
    const prevPhoneUse = this.kv('last_phone_use');
    const lastCatchup = this.kv('last_catchup');
    app.db.run(
      'INSERT INTO presence_events(event,at,detail) VALUES(?,?,?)',
      event,
      at,
      detail ?? null,
    );
    app.db.run(
      'DELETE FROM presence_events WHERE id < (SELECT MAX(id) - 2000 FROM presence_events)',
    );
    if (event === 'phone_still') this.setKv('last_still', at);

    let decision: PresenceDecision = { triggered: false };
    if (ACTIVITY.has(event)) {
      decision = this.evaluate(at, prevActivity, prevPhoneUse, lastCatchup);
      this.setKv('last_activity', at);
    }
    if (PHONE_USE.has(event)) this.setKv('last_phone_use', at);

    if (decision.triggered && app.settings.bool('catchup.enabled')) {
      this.setKv('last_catchup', now);
      await this.generate(decision.reason!).catch((e) =>
        app.log.warn('catch-up failed', String(e)),
      );
    }
    return decision;
  }

  /** Pure rule evaluation. */
  evaluate(
    at: number,
    prevActivity: number | null,
    prevPhoneUse: number | null,
    lastCatchup: number | null,
  ): PresenceDecision {
    const s = this.app.settings;
    const sinceAfterCatchup = (t: number | null) =>
      t === null
        ? lastCatchup
        : lastCatchup === null
          ? t
          : Math.max(t, lastCatchup);
    // slept: phone-use-free span overlapping the night window, phone quiet
    const spanStart = sinceAfterCatchup(prevPhoneUse ?? prevActivity);
    if (spanStart !== null) {
      const overlap = nightOverlapMs(
        spanStart,
        at,
        s.str('catchup.night_start'),
        s.str('catchup.night_end'),
      );
      const stillAt = this.kv('last_still');
      const quiet =
        this.chargingNightMs(spanStart, at) >= HOUR ||
        (stillAt !== null && stillAt >= spanStart);
      if (overlap >= s.num('catchup.sleep_min_hours') * HOUR && quiet) {
        return { triggered: true, reason: 'slept', awayMs: at - spanStart };
      }
    }
    // away: gap since the last activity (or since the last brief, whichever is later)
    const ref = sinceAfterCatchup(prevActivity);
    if (
      prevActivity !== null &&
      ref !== null &&
      at - ref >= s.num('catchup.away_hours') * HOUR
    ) {
      return { triggered: true, reason: 'away', awayMs: at - ref };
    }
    return { triggered: false };
  }

  /**
   * How long the phone was charging inside [from, to] AND the night window. Charging is a state: from a
   * phone_charging event until the next phone_unplugged (or until `to`).
   */
  chargingNightMs(from: number, to: number): number {
    const s = this.app.settings;
    const rows = this.app.db.all<{ event: string; at: number }>(
      "SELECT event, at FROM presence_events WHERE event IN ('phone_charging','phone_unplugged') AND at <= ? ORDER BY at, id",
      to,
    );
    let since: number | null = null;
    let total = 0;
    const add = (a: number, b: number) => {
      const x = Math.max(a, from);
      const y = Math.min(b, to);
      if (y > x)
        total += nightOverlapMs(
          x,
          y,
          s.str('catchup.night_start'),
          s.str('catchup.night_end'),
        );
    };
    for (const r of rows) {
      if (r.event === 'phone_charging') since ??= r.at;
      else if (since !== null) {
        add(since, r.at);
        since = null;
      }
    }
    if (since !== null) add(since, to);
    return total;
  }

  /** Build one short brief via the agent, or nothing if irrelevant. Stores and sends it. */
  async generate(
    reason: ReturnReason | 'manual' = 'manual',
  ): Promise<{ id: string; text: string } | null> {
    const app = this.app;
    const now = app.clock.now();
    const off = app.settings.displayOffsetMin();
    const parts: string[] = [
      `Now: ${humanLocal(now, 'en', off)}. Reason for this brief: ${reason === 'slept' ? 'the user just woke up' : reason === 'away' ? 'the user is back after being away' : 'requested'}.`,
    ];
    const pending = app.inbox.pending();
    parts.push(
      pending.length
        ? 'Pending inbox:\n' +
            pending
              .slice(0, 10)
              .map((i) => `- [${i.kind}] ${i.title}: ${i.summary}`)
              .join('\n')
        : 'Pending inbox: empty.',
    );
    const userRuns = app.scheduler.recentUserRuns(now - DAY, 10);
    if (userRuns.length)
      parts.push(
        'Recent job results:\n' +
          userRuns.map((r) => `- ${r.name}: ${r.output}`).join('\n'),
      );
    if (app.integrations.calendar) {
      const ev = await app.integrations.calendar
        .events(now, now + 12 * HOUR)
        .catch(() => []);
      if (ev.length)
        parts.push(
          'Next calendar events:\n' +
            ev
              .slice(0, 4)
              .map(
                (e) =>
                  `- ${humanLocal(e.start, 'en', off).slice(-5)} ${e.title}${e.location ? ' @ ' + e.location : ''}`,
              )
              .join('\n'),
        );
    }
    if (app.settings.bool('catchup.use_weather') && app.hub.hasConnections()) {
      const loc = await app.hub.readLocation('catchup');
      if (loc.ok)
        parts.push(
          `Current location (from the phone): ${loc.text}\nUse the weather tool with this location if the weather matters today.`,
        );
    }
    const r = await runJobPrompt(
      app,
      'Write ONE short catch-up brief (max 2 sentences, same tone as usual, no greeting fluff) from the context. Only mention what matters now. If nothing is relevant, answer exactly NOTHING. Do not create inbox items.',
      { context: parts.join('\n\n'), noInbox: true },
    );
    if (r.nothing || !r.text.trim()) return null;
    const id = newId('brief_');
    app.db.run(
      'INSERT INTO briefs(id,text,reason,at) VALUES(?,?,?,?)',
      id,
      r.text,
      reason,
      now,
    );
    app.hub.broadcast({ type: 'catchup', id, text: r.text, at: isoLocal(now) });
    return { id, text: r.text };
  }

  recent(
    limit = 10,
  ): { id: string; text: string; reason: string | null; at: string }[] {
    return this.app.db
      .all<{ id: string; text: string; reason: string | null; at: number }>(
        'SELECT * FROM briefs ORDER BY at DESC, rowid DESC LIMIT ?',
        limit,
      )
      .map((b) => ({
        id: b.id,
        text: b.text,
        reason: b.reason,
        at: isoLocal(b.at),
      }));
  }
}
