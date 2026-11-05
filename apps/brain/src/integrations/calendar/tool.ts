import { z } from 'zod';
import type { ToolDef } from '../../tools/registry.ts';
import { DAY, humanLocal } from '../../util/clock.ts';

const schema = z.object({
  from: z.string().optional().describe('ISO 8601 start (default: now)'),
  to: z.string().optional().describe('ISO 8601 end (default: from + days)'),
  days: z
    .number()
    .min(0.1)
    .max(60)
    .optional()
    .describe('Range length in days (default 1)'),
  nextOnly: z.boolean().optional().describe('Only the next event'),
});

export const calendarEventsTool: ToolDef = {
  name: 'calendar_events',
  description:
    "The user's calendar events (all connected calendars merged) in a time range, or just the next event. Each event has an {id: …}: pass it as eventRef to delete_calendar_event to remove that event.",
  inputSchema: schema,
  kind: 'server',
  status: { de: 'Schaue in den Kalender …', en: 'Checking the calendar …' },
  async handler(a: z.infer<typeof schema>, { app, run }) {
    const cal = app.integrations.calendar;
    if (!cal)
      return 'No calendar is connected. The user can add one in the app.';
    const now = app.clock.now();
    const from = a.from ? Date.parse(a.from) : now;
    if (Number.isNaN(from)) return 'Invalid "from" date.';
    const to = a.to ? Date.parse(a.to) : from + (a.days ?? 1) * DAY;
    if (Number.isNaN(to)) return 'Invalid "to" date.';
    const line = (e: {
      start: number;
      end: number;
      title: string;
      location?: string;
      allDay?: boolean;
      calendar?: string;
      ref?: string;
      recurring?: boolean;
    }) =>
      `- ${e.allDay ? humanLocal(e.start, run.locale).slice(0, -6) + ' (all day)' : `${humanLocal(e.start, run.locale, run.utcOffsetMin)}–${humanLocal(e.end, run.locale, run.utcOffsetMin).slice(-5)}`} ${e.title}${e.location ? ' @ ' + e.location : ''}${e.calendar ? ' [' + e.calendar + ']' : ''}${e.recurring ? ' (repeats)' : ''}${e.ref ? ' {id: ' + e.ref + '}' : ''}`;
    if (a.nextOnly && cal.next) {
      const e = await cal.next(from);
      return e
        ? 'Next event:\n' + line(e)
        : 'No upcoming events in the next 14 days.';
    }
    const events = await cal.events(from, to);
    return events.length
      ? `${events.length} event(s):\n` +
          events.slice(0, 50).map(line).join('\n')
      : 'No events in that range.';
  },
};
