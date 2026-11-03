import { z } from 'zod';
import type { ToolDef } from '../../tools/registry.ts';
import { humanLocal } from '../../util/clock.ts';

const NONE = 'No mail account is connected. The user can add one in the app.';

const searchSchema = z.object({
  query: z
    .string()
    .optional()
    .describe(
      'Search words (Gmail syntax works for Gmail, e.g. from:anna is:unread). Empty = most recent mail.',
    ),
  limit: z.number().int().min(1).max(25).optional(),
});

export const mailSearchTool: ToolDef = {
  name: 'mail_search',
  description:
    'Search the mail of all connected accounts (or list the most recent). Returns ids for mail_read and send_mail_reply.',
  inputSchema: searchSchema,
  kind: 'server',
  status: { de: 'Suche Mails …', en: 'Searching mail …' },
  async handler(a: z.infer<typeof searchSchema>, { app, run }) {
    const mail = app.integrations.mail;
    if (!mail?.search) return NONE;
    const r = await mail.search(a.query ?? '', a.limit ?? 10);
    return r.length
      ? r
          .map(
            (m) =>
              `- id=${m.id} | ${humanLocal(m.receivedAt, run.locale)} | ${m.unread ? 'UNREAD | ' : ''}${m.from} | ${m.subject}\n  ${m.snippet.slice(0, 160)}`,
          )
          .join('\n')
      : 'No mail found.';
  },
};

const readSchema = z.object({
  id: z.string().min(1).describe('Mail id from mail_search'),
});

export const mailReadTool: ToolDef = {
  name: 'mail_read',
  description: 'Read one mail completely (sender, date, subject, text).',
  inputSchema: readSchema,
  kind: 'server',
  status: { de: 'Lese Mail …', en: 'Reading mail …' },
  async handler(a: z.infer<typeof readSchema>, { app, run }) {
    const mail = app.integrations.mail;
    if (!mail?.read) return NONE;
    const m = await mail.read(a.id);
    return `From: ${m.from}\nTo: ${m.to}\nDate: ${humanLocal(m.receivedAt, run.locale)}\nSubject: ${m.subject}\n\n${m.body.slice(0, 12_000)}`;
  },
};
