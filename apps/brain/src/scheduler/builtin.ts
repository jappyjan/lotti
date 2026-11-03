import type { App } from '../app.ts';
import { MIN, humanLocal } from '../util/clock.ts';
import { extractJson } from '../util/text.ts';

export interface BuiltinJob {
  key: string;
  name: string;
  cron: string;
  scheduleText: string;
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
    async run(app) {
      const cal = app.integrations.calendar;
      if (!cal) return 'No calendar connected.';
      const now = app.clock.now();
      const events = await cal.events(now, now + 10 * MIN);
      for (const e of events) {
        const ref = `calendar:${e.id}:${e.start}`;
        app.inbox.create({
          kind: 'calendar',
          title: e.title,
          summary: `Starts ${humanLocal(e.start).slice(-5)}${e.location ? ' · ' + e.location : ''}`,
          sourceRef: ref,
          startsAt: e.start,
          expiresInHours: Math.max(1, (e.end - now) / 3_600_000),
          dedupe: true,
        });
      }
      return events.length
        ? `${events.length} meeting(s) within 10 min.`
        : 'No meeting soon.';
    },
  },
  {
    key: 'important_mail',
    name: 'Important mail',
    cron: '*/10 * * * *',
    scheduleText: 'every 10 minutes',
    async run(app) {
      const mail = app.integrations.mail;
      if (!mail) return 'No mail account connected.';
      const since = Number(
        app.settings.kvGet('important_mail.since') ??
          app.clock.now() - 10 * MIN,
      );
      const msgs = await mail.unread(since);
      app.settings.kvSet('important_mail.since', String(app.clock.now()));
      if (!msgs.length) return 'No new mail.';
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
      return `${msgs.length} new mail(s), ${n} important.`;
    },
  },
  {
    key: 'dreaming',
    name: 'Dreaming',
    cron: '0 3 * * *',
    scheduleText: 'daily at 03:00',
    async run(app) {
      if (!app.settings.bool('dreaming.enabled'))
        return 'Dreaming is turned off.';
      const r = await app.dreaming.run();
      return r.report;
    },
  },
];
