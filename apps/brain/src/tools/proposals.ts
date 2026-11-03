import { z } from 'zod';
import type { App } from '../app.ts';
import type { ProposedAction } from '../actions.ts';
import type { ToolContext, ToolDef } from './registry.ts';

/** Create a proposed action, attach it to the run, tell the model it is only proposed. */
export function proposeAction(
  ctx: ToolContext,
  a: Omit<ProposedAction, 'id'>,
): string {
  const p = ctx.app.actions.propose(a);
  ctx.run.actions.push(p);
  return `Proposed "${p.title}". Nothing has happened yet: the user must tap to confirm. Tell them briefly what you proposed.`;
}

const timer = z.object({
  minutes: z.number().min(0.1).max(1440).optional(),
  seconds: z.number().int().min(1).max(86_400).optional(),
  label: z.string().optional(),
});
const reminder = z.object({
  title: z.string().min(1),
  due: z
    .string()
    .optional()
    .describe('ISO 8601 date-time with offset, e.g. 2026-11-03T18:00:00+01:00'),
  notes: z.string().optional(),
});
const nav = z.object({
  destination: z.string().min(1).describe('Address or place name'),
  mode: z.enum(['driving', 'walking', 'cycling', 'transit']).optional(),
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
      title: t.title(args),
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
    inputSchema: timer,
    target: 'phone',
    title: (a) =>
      `Timer ${a.minutes ? a.minutes + ' min' : (a.seconds ?? 0) + ' s'}${a.label ? ' · ' + a.label : ''}`,
  }),
  tool({
    name: 'create_reminder',
    description: 'Propose a new reminder on the phone.',
    inputSchema: reminder,
    target: 'phone',
    title: (a) => `Reminder: ${a.title}`,
  }),
  tool({
    name: 'start_navigation',
    description: 'Propose starting navigation on the phone/glasses.',
    inputSchema: nav,
    target: 'phone',
    title: (a) => `Navigate to ${a.destination}`,
  }),
  tool({
    name: 'send_mail_reply',
    description: 'Propose sending a reply to a mail.',
    inputSchema: mail,
    target: 'server',
    title: (a) => `Send reply${a.to ? ' to ' + a.to : ''}`,
  }),
  tool({
    name: 'create_calendar_event',
    description: 'Propose a new calendar event.',
    inputSchema: event,
    target: 'server',
    title: (a) => `Add "${a.title}" to calendar`,
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
