import type { App } from '../app.ts';
import { MIN, humanLocal } from '../util/clock.ts';
import { extractJson } from '../util/text.ts';

export interface BuiltinJob {
  key: string;
  name: string;
  cron: string;
  scheduleText: string;
  /** What it does, shown in the app. */
  description: string;
  /** Does a run spend AI tokens? `conditional` = only when `aiNote` says so. */
  ai: 'none' | 'conditional' | 'always';
  aiNote: string;
  /** A setting of this job the app lets you edit next to schedule and enabled. */
  setting?: { key: string; label: string; unit: string };
  run(app: App): Promise<string>;
}

/**
 * Built-in jobs. Editable (schedule, enabled) but not deletable.
 * They use pluggable sources from `app.integrations` (calendar, mail): with none connected they do nothing.
 */
export const builtinJobs: BuiltinJob[] = [
  {
    key: 'meeting_soon',
    name: 'Meeting soon',
    cron: '* * * * *',
    scheduleText: 'every minute',
    description:
      'Looks at your calendar and puts events that start within the lead time into your inbox (once per event).',
    ai: 'none',
    aiNote: 'No AI tokens: it only reads the calendar.',
    setting: {
      key: 'jobs.meeting_soon.lead_min',
      label: 'Lead time',
      unit: 'minutes',
    },
    async run(app) {
      const cal = app.integrations.calendar;
      if (!cal) return 'No calendar connected.';
      const now = app.clock.now();
      const lead = Math.max(1, app.settings.num('jobs.meeting_soon.lead_min') || 10);
      const events = await cal.events(now, now + lead * MIN);
      for (const e of events) {
        const ref = `calendar:${e.id}:${e.start}`;
        app.inbox.create({
          kind: 'calendar',
          title: e.title,
          summary: `Starts ${humanLocal(e.start, 'en', app.settings.displayOffsetMin()).slice(-5)}${e.location ? ' · ' + e.location : ''}`,
          sourceRef: ref,
          startsAt: e.start,
          expiresInHours: Math.max(1, (e.end - now) / 3_600_000),
          dedupe: true,
        });
      }
      return events.length
        ? `${events.length} meeting(s) within ${lead} min.`
        : 'No meeting soon.';
    },
  },
  {
    key: 'important_mail',
    name: 'Important mail',
    cron: '*/10 * * * *',
    scheduleText: 'every 10 minutes',
    description:
      'Checks for new mail and lets the AI pick out what needs attention soon; those mails land in your inbox.',
    ai: 'conditional',
    aiNote: 'Spends AI tokens only when there is new mail since the last run.',
    async run(app) {
      const mail = app.integrations.mail;
      if (!mail) return 'No mail account connected.';
      const since = Number(
        app.settings.kvGet('important_mail.since') ??
          app.clock.now() - 10 * MIN,
      );
      const fetchedAt = app.clock.now();
      const msgs = await mail.unread(since);
      // `since` moves only after triage and the inbox items succeeded: a failed run retries the same mail.
      const done = () =>
        app.settings.kvSet('important_mail.since', String(fetchedAt));
      if (!msgs.length) {
        done();
        return 'No new mail.';
      }
      const raw = await app.providers.text(
        'You triage new mail for the user. Return ONLY JSON: [{"id": string, "important": boolean, "title": string, "summary": string}]. ' +
          'Important = needs attention soon (personal, deadlines, money, appointments, security). Not important = newsletters, promos, notifications.',
        msgs
          .map(
            (m) =>
              `id=${m.id}\nfrom=${m.from}\nsubject=${m.subject}\n${m.snippet}`,
          )
          .join('\n---\n'),
      );
      const j = extractJson(raw);
      let n = 0;
      if (Array.isArray(j)) {
        for (const r of j) {
          if (r?.important && typeof r.id === 'string') {
            const m = msgs.find((x) => x.id === r.id);
            app.inbox.create({
              kind: 'mail',
              title: String(r.title ?? m?.subject ?? 'Mail'),
              summary: String(r.summary ?? ''),
              body: m?.snippet ?? '',
              sourceRef: `mail:${r.id}`,
              dedupe: true,
            });
            n++;
          }
        }
      }
      done();
      return `${msgs.length} new mail(s), ${n} important.`;
    },
  },
  {
    key: 'dreaming',
    name: 'Dreaming',
    cron: '0 3 * * *',
    scheduleText: 'daily at 03:00',
    description:
      'Tidies up your memory overnight: merges duplicates, drops stale notes and writes a report.',
    ai: 'always',
    aiNote: 'Spends AI tokens on every run (when dreaming is on).',
    async run(app) {
      if (!app.settings.bool('dreaming.enabled'))
        return 'Dreaming is turned off.';
      const r = await app.dreaming.run();
      return r.report;
    },
  },
];
