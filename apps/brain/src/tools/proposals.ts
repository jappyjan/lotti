import { z } from 'zod';
import type { App } from '../app.ts';
import type { ProposedAction } from '../actions.ts';
import { isoLocal, parseOffsetMin, shortWhen } from '../util/clock.ts';
import { clip } from '../util/text.ts';
import type { ToolContext, ToolDef } from './registry.ts';

/** Create a proposed action, attach it to the run, tell the model it is only proposed. */
export function proposeAction(
  ctx: ToolContext,
  a: Omit<ProposedAction, 'id'>,
): string {
  const p = ctx.app.actions.propose(a);
  ctx.run.actions.push(p);
  ctx.app.log.info(
    `proposed ${p.id} ${p.tool ?? ''} "${p.title}" (ask ${ctx.run.askId ?? 'none'})`,
  );
  return `Proposed "${p.title}". Nothing has happened yet: the user must tap to confirm. Tell them briefly what you proposed.`;
}

/**
 * Phone actions run on the phone with the phone's own tool schemas (apps/ios/Lotti/PhoneTools.swift):
 * keep these EXACTLY in sync (pinned by a test).
 */
export const timerSchema = z.object({
  minutes: z
    .number()
    .int()
    .min(1)
    .max(720)
    .describe('length in minutes, 1 to 720'),
  label: z.string().optional().describe("what it's for, 1 to 3 words"),
});
export const reminderSchema = z.object({
  text: z.string().min(1).describe('what to remember, short'),
  due: z
    .string()
    .optional()
    .describe(
      'when, as free text the phone understands: a day and time like "tomorrow 09:00" or "monday 18:30", or just "18:30" for today',
    ),
});
export const navSchema = z.object({
  destination: z
    .string()
    .min(1)
    .describe('the place as said, e.g. "Mauerpark" or "Kastanienallee 12"'),
  mode: z.enum(['walk', 'bike']).optional().describe('default walk'),
});
const mail = z.object({
  mailId: z.string().describe('Id of the mail being answered'),
  body: z.string().min(1),
  to: z.string().optional(),
  subject: z.string().optional(),
});
const event = z.object({
  title: z.string().min(1),
  start: z.string().describe('ISO 8601 with offset'),
  end: z.string().describe('ISO 8601 with offset'),
  location: z.string().optional(),
  notes: z.string().optional(),
  attendees: z.array(z.string()).optional(),
});

const deleteEvent = z.object({
  eventRef: z
    .string()
    .describe('The {id: …} of the event, as listed by calendar_events'),
});

/**
 * "Tue 3 Nov 14:30–15:30" from ISO strings, at the start's own written offset ("+02:00" for a date after
 * the clocks change), else the phone's ("Z" is UTC, not a place); '' when the start does not parse.
 */
const when = (startIso: unknown, endIso: unknown, ctx: ToolContext): string => {
  const s = Date.parse(String(startIso));
  if (Number.isNaN(s)) return '';
  const e = endIso === undefined ? null : Date.parse(String(endIso));
  return shortWhen(
    s,
    e,
    ctx.run.locale,
    (/Z$/i.test(String(startIso)) ? null : parseOffsetMin(String(startIso))) ??
      ctx.run.utcOffsetMin,
  );
};

const tool = (
  t: Pick<ToolDef, 'name' | 'description' | 'inputSchema' | 'status'> & {
    target: 'phone' | 'server';
    title: (a: any, ctx: ToolContext) => string;
  },
): ToolDef => ({
  name: t.name,
  description:
    t.description +
    ' Only PROPOSES: the user must tap to confirm, then it runs.',
  inputSchema: t.inputSchema,
  kind: 'server',
  needsConfirmation: true,
  ...(t.status ? { status: t.status } : {}),
  async handler(args, ctx) {
    return proposeAction(ctx, {
      title: clip(t.title(args, ctx), 140),
      target: t.target,
      tool: t.name,
      args,
    });
  },
});

export const proposalTools: ToolDef[] = [
  tool({
    name: 'set_timer',
    description: 'Propose a timer on the phone.',
    inputSchema: timerSchema,
    target: 'phone',
    title: (a) => `Timer ${a.minutes} min${a.label ? ' · ' + a.label : ''}`,
  }),
  tool({
    name: 'create_reminder',
    description: 'Propose a new reminder on the phone.',
    inputSchema: reminderSchema,
    target: 'phone',
    title: (a) => `Reminder: ${a.text}${a.due ? ' · ' + a.due : ''}`,
  }),
  tool({
    name: 'start_navigation',
    description:
      'Propose turn-by-turn navigation on the glasses, walking or by bike.',
    inputSchema: navSchema,
    target: 'phone',
    title: (a) =>
      `Navigate to ${a.destination}${a.mode === 'bike' ? ' by bike' : ''}`,
  }),
  tool({
    name: 'send_mail_reply',
    description: 'Propose sending a reply to a mail.',
    inputSchema: mail,
    target: 'server',
    title: (a) =>
      `Send reply to ${a.to ?? 'the sender of mail ' + a.mailId}: "${clip(String(a.body).replace(/\s+/g, ' ').trim(), 80)}"`,
  }),
  tool({
    name: 'create_calendar_event',
    description: 'Propose a new calendar event.',
    inputSchema: event,
    target: 'server',
    title: (a, ctx) =>
      `Add "${a.title}" · ${when(a.start, a.end, ctx) || `${a.start}–${a.end}`}${a.attendees?.length ? ' with ' + a.attendees.join(', ') : ''}`,
  }),
  {
    name: 'delete_calendar_event',
    description:
      'Propose deleting one calendar event (use the {id: …} from calendar_events as eventRef). For a repeating Google event only that one occurrence is deleted; repeating CalDAV events cannot be deleted. There is no undo. Only PROPOSES: the user must tap to confirm, then it runs.',
    inputSchema: deleteEvent,
    kind: 'server',
    needsConfirmation: true,
    status: { de: 'Schaue in den Kalender …', en: 'Checking the calendar …' },
    // The card shows the event as the calendar has it, not as the model wrote it: what you confirm is what goes.
    async handler(args, ctx) {
      const cal = ctx.app.integrations.calendar;
      if (!cal?.deletable) return 'No calendar is connected yet.';
      const found = await cal.deletable(args.eventRef);
      if (!found.ok) return found.text;
      const e = found.event;
      // All-day events are local midnights on the server: shown without the phone offset, date only.
      const at = e.allDay
        ? shortWhen(e.start, null, ctx.run.locale).slice(0, -6)
        : shortWhen(e.start, e.end, ctx.run.locale, ctx.run.utcOffsetMin);
      return proposeAction(ctx, {
        title: clip(`Delete "${e.title}" · ${at}`, 140),
        target: 'server',
        tool: 'delete_calendar_event',
        args: {
          eventRef: args.eventRef,
          title: e.title,
          // All-day: the date itself (server-local), so no zone shifts it to the day before.
          start: e.allDay
            ? isoLocal(e.start).slice(0, 10)
            : new Date(e.start).toISOString(),
          end: new Date(e.end).toISOString(),
          ...(e.allDay ? { allDay: true } : {}),
          ...(e.recurring ? { occurrence: true } : {}),
        },
      });
    },
  },
];

/** Server-side execution of the server actions: delegated to the integrations (stubs say "not connected"). */
export function registerServerActions(app: App): void {
  app.actions.register('send_mail_reply', async (args, a) =>
    a.integrations.mail?.sendReply
      ? a.integrations.mail.sendReply(args)
      : { ok: false, text: 'No mail account is connected yet.' },
  );
  app.actions.register('delete_calendar_event', async (args, a) =>
    a.integrations.calendar?.deleteEvent
      ? a.integrations.calendar.deleteEvent(args)
      : { ok: false, text: 'No calendar is connected yet.' },
  );
  app.actions.register('create_calendar_event', async (args, a) =>
    a.integrations.calendar?.createEvent
      ? a.integrations.calendar.createEvent(args)
      : { ok: false, text: 'No calendar is connected yet.' },
  );
}
