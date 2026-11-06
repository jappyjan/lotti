import type { App } from '../app.ts';
import { MIN, humanLocal } from '../util/clock.ts';
import type { MailMessage } from '../integrations/index.ts';
import { clip, extractJson, mailGist, stripHtml } from '../util/text.ts';

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
      const verdicts = await triageMail(app, msgs);
      let n = 0;
      for (const v of verdicts) {
        const m = msgs.find((x) => x.id === v.id);
        if (!v.important || !m) continue;
        app.inbox.create({
          kind: 'mail',
          title: v.title || m.subject || 'Mail',
          summary: v.summary,
          body: mailOriginal(m),
          sourceRef: `mail:${m.id}`,
          dedupe: true,
        });
        n++;
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

/** Words that find what the user told Lotti about mail (senders to skip, topics that matter). */
const MAIL_MEMORY_QUERY =
  'mail email e-mail newsletter inbox posteingang absender sender wichtig unwichtig ignore ignorieren';

export interface MailVerdict {
  id: string;
  important: boolean;
  title: string;
  summary: string;
}

/** AI text for a one-line screen: plain text only, even when the model echoes markup. */
const plain = (v: unknown, max: number): string =>
  clip(stripHtml(String(v ?? '')).replace(/\s+/g, ' ').trim(), max);

/** One AI call: which new mail matters, with a short title and a readable summary for each. */
export async function triageMail(
  app: App,
  msgs: MailMessage[],
): Promise<MailVerdict[]> {
  const lang = app.settings.lastLocale() === 'de' ? 'German' : 'English';
  const notes = app.memory.search(MAIL_MEMORY_QUERY, 8);
  const raw = await app.providers.text(
    'You triage new mail for the user and write what they see on their glasses. ' +
      'Return ONLY JSON, one entry per mail: [{"id": string, "important": boolean, "title": string, "summary": string}].\n' +
      'important = true only when the user should see it soon: a person writing to them personally, a deadline, ' +
      'a bill or payment that needs action, an appointment or travel change, a security alert, something they must reply to or do. ' +
      'important = false for newsletters, marketing, promotions, social media, digests, mailing lists, surveys, ' +
      'automatic notifications, receipts, order or shipping confirmations that need no action, and anything the user said they do not want.\n' +
      `title: who and what, at most 40 characters (e.g. "Anna: dinner Friday?"). summary: at most 2 short sentences, at most 160 characters, in ${lang}: ` +
      'what it is about and what the user should do, with the key facts (dates, times, amounts). ' +
      'Plain text only: no HTML, markdown, links, greetings or quoted text. Never copy the mail; say it in your own words.' +
      (notes.length
        ? '\nWhat the user told you before (use what is about mail, ignore the rest):\n' +
          notes.map((m) => `- ${m.text}`).join('\n')
        : ''),
    msgs
      .map(
        (m) =>
          `id=${m.id}\nfrom=${m.from}\nsubject=${m.subject}\n${mailGist(m.text || m.snippet, 1500)}`,
      )
      .join('\n---\n'),
  );
  const j = extractJson(raw);
  if (!Array.isArray(j)) {
    app.log.warn('mail triage: no JSON list in the answer', clip(raw, 200));
    return [];
  }
  return j
    .filter((r) => r && typeof r.id === 'string')
    .map((r) => ({
      id: r.id,
      important: r.important === true,
      title: plain(r.title, 60),
      summary: plain(r.summary, 240),
    }));
}

/** The "Original" of a mail item: sender and the readable text, without links and quoted replies. */
export function mailOriginal(m: MailMessage): string {
  const text = mailGist(m.text || m.snippet, 2000);
  return [`From: ${m.from}`, m.subject && `Subject: ${m.subject}`, text]
    .filter(Boolean)
    .join('\n');
}
