import { z } from 'zod';
import type { App } from '../app.ts';
import type { ProposedAction } from '../actions.ts';
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
  minutes: z.number().int().min(1).max(720).describe('length in minutes, 1 to 720'),
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

const tool = (
  t: Pick<ToolDef, 'name' | 'description' | 'inputSchema' | 'status'> & {
    target: 'phone' | 'server';
    title: (a: any) => string;
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
      title: clip(t.title(args), 140),
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
    title: (a) => `Navigate to ${a.destination}${a.mode === 'bike' ? ' by bike' : ''}`,
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
    title: (a) =>
      `Add "${a.title}" ${a.start}–${a.end}${a.attendees?.length ? ' with ' + a.attendees.join(', ') : ''} to calendar`,
  }),
];

/** Server-side execution of the two server actions: delegated to the integrations (stubs say "not connected"). */
export function registerServerActions(app: App): void {
  app.actions.register('send_mail_reply', async (args, a) =>
    a.integrations.mail?.sendReply
      ? a.integrations.mail.sendReply(args)
      : { ok: false, text: 'No mail account is connected yet.' },
  );
  app.actions.register('create_calendar_event', async (args, a) =>
    a.integrations.calendar?.createEvent
      ? a.integrations.calendar.createEvent(args)
      : { ok: false, text: 'No calendar is connected yet.' },
  );
}
