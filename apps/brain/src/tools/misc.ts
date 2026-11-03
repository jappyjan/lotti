import { z } from 'zod';
import { clip } from '../util/text.ts';
import type { ToolDef } from './registry.ts';

const search = z.object({
  query: z.string().min(1),
  limit: z.number().int().min(1).max(20).optional(),
});
const read = z.object({
  conversationId: z.string(),
  maxTurns: z.number().int().min(1).max(200).optional(),
});
const load = z.object({
  name: z.string().describe('Skill name from the skill index'),
});

export const conversationSearchTool: ToolDef = {
  name: 'conversation_search',
  description:
    'Full-text search over earlier conversations (titles, summaries, turns). Returns conversation ids to read with conversation_read.',
  inputSchema: search,
  kind: 'server',
  status: {
    de: 'Durchsuche frühere Gespräche …',
    en: 'Searching earlier conversations …',
  },
  async handler(args: z.infer<typeof search>, { app }) {
    const r = app.conversations.search(args.query, args.limit ?? 8);
    return r.length
      ? r
          .map(
            (x) =>
              `${x.conversationId} | ${x.title ?? '(untitled)'} | ${x.kind}: ${x.snippet}`,
          )
          .join('\n')
      : 'No matches.';
  },
};

export const conversationReadTool: ToolDef = {
  name: 'conversation_read',
  description: 'Read an earlier conversation (summary + turns).',
  inputSchema: read,
  kind: 'server',
  async handler(args: z.infer<typeof read>, { app }) {
    const c = app.conversations.get(args.conversationId);
    if (!c) return 'No such conversation.';
    const turns = c.turns.slice(-(args.maxTurns ?? 40));
    return [
      `Title: ${c.conversation.title ?? '(untitled)'} (${c.conversation.startedAt})`,
      c.conversation.summary ? `Summary: ${c.conversation.summary}` : '',
      ...turns.map(
        (t) =>
          `${t.role === 'user' ? 'User' : 'Lotti'} [${t.at}]: ${clip(t.text, 1500)}`,
      ),
    ]
      .filter(Boolean)
      .join('\n');
  },
};

export const skillLoadTool: ToolDef = {
  name: 'skill_load',
  description:
    'Load a skill (how-to markdown) by name from the skill index in your instructions, and follow it.',
  inputSchema: load,
  kind: 'server',
  async handler(args: z.infer<typeof load>, { app }) {
    const c = app.skills.get('skill', args.name, { markUsed: true });
    return c ?? `No skill named "${args.name}".`;
  },
};
