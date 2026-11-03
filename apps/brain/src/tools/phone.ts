import { z } from 'zod';
import type { ToolDef } from './registry.ts';

export const locationTool: ToolDef = {
  name: 'location',
  description:
    "The phone's current position (lat/lon, place name if known). Ask for it only when the question needs where Jan is. The user sees a location indicator while it runs.",
  inputSchema: z.object({}),
  kind: 'phone',
  status: { de: 'Frage Standort ab …', en: 'Getting your location …' },
  async handler(_args, { app, run }) {
    const r = await app.hub.readLocation('agent', run.askId, run.signal);
    return r.ok ? r.text : `Could not get the location: ${r.text}`;
  },
};

const remindersSchema = z.object({
  list: z.string().optional().describe('Reminder list name (default: all)'),
  includeCompleted: z.boolean().optional(),
});

export const remindersTool: ToolDef = {
  name: 'reminders',
  description: "Read the user's reminders from the phone.",
  inputSchema: remindersSchema,
  kind: 'phone',
  status: { de: 'Lese Erinnerungen …', en: 'Reading reminders …' },
  async handler(args: z.infer<typeof remindersSchema>, { app, run }) {
    const r = await app.hub.callPhone('reminders', args, {
      ...(run.askId ? { askId: run.askId } : {}),
      ...(run.signal ? { signal: run.signal } : {}),
    });
    return r.ok ? r.text : `Could not read reminders: ${r.text}`;
  },
};
