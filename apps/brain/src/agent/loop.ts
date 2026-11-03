import { z } from 'zod';
import type { App } from '../app.ts';
import type { ProposedAction, UndoHandle } from '../actions.ts';
import type { ChatMessage } from '../providers/types.ts';
import { newRun, type RunState, type ToolDef } from '../tools/registry.ts';
import { extractJson } from '../util/text.ts';
import { buildSystemPrompt } from './prompt.ts';

export interface Answer {
  text: string;
  followUps: string[];
  actions: ProposedAction[];
  undo?: UndoHandle;
}

export class CancelledError extends Error {
  constructor() {
    super('cancelled');
    this.name = 'CancelledError';
  }
}

const answerSchema = z.object({
  text: z.string().describe('The final answer for the user'),
  followUps: z
    .array(z.string())
    .max(3)
    .optional()
    .describe('Up to 3 short follow-up questions the user might ask next'),
});

const answerTool: ToolDef = {
  name: 'answer',
  description:
    'Give the final answer to the user. Call this exactly once when you are done.',
  inputSchema: answerSchema,
  kind: 'server',
  async handler() {
    return 'ok';
  },
};

/** Final-answer convention: `answer` tool call > JSON object in text > plain text. */
export function parseFinal(text: string): {
  text: string;
  followUps: string[];
} {
  const j = extractJson(text);
  if (j && typeof j === 'object' && !Array.isArray(j)) {
    const o = j as Record<string, unknown>;
    const t = o.text ?? o.answer;
    if (typeof t === 'string' && t.trim()) {
      const f = o.followUps ?? o.follow_ups ?? o.followups;
      return {
        text: t.trim(),
        followUps: Array.isArray(f)
          ? f.filter((x): x is string => typeof x === 'string').slice(0, 3)
          : [],
      };
    }
  }
  return { text: text.trim(), followUps: [] };
}

export interface LoopInput {
  system: string;
  history: ChatMessage[];
  run: RunState;
  tools?: ToolDef[];
}

export function isNothing(text: string): boolean {
  return /^\W*nothing\W*$/i.test(text.trim());
}

const checkCancel = (run: RunState) => {
  if (run.signal?.aborted) throw new CancelledError();
};

/** The tool loop: round limit, silence timeout, cancel, status lines, final structured answer. */
export async function runLoop(app: App, input: LoopInput): Promise<Answer> {
  const { run } = input;
  const tools = input.tools ?? app.tools.all();
  const maxRounds = app.settings.num('agent.max_rounds');
  const silenceMs = app.settings.num('agent.silence_timeout_sec') * 1000;
  const messages: ChatMessage[] = [
    { role: 'system', content: input.system },
    ...input.history,
  ];
  const finish = (text: string, followUps: string[]): Answer => ({
    text,
    followUps: followUps.slice(0, 3),
    actions: run.actions.slice(0, 2),
    ...(run.undo ? { undo: run.undo } : {}),
  });

  for (let round = 1; round <= maxRounds; round++) {
    checkCancel(run);
    const last = round === maxRounds;
    let roundTools = [...tools, answerTool];
    if (last) {
      messages.push({
        role: 'user',
        content:
          'Step limit reached. Answer now with what you have, using the `answer` tool.',
      });
      roundTools = [answerTool];
    }
    let res;
    try {
      res = await app.providers.complete(
        messages,
        app.tools.specs(roundTools),
        { silenceMs, ...(run.signal ? { signal: run.signal } : {}) },
      );
    } catch (e) {
      if (run.signal?.aborted) throw new CancelledError();
      throw e;
    }
    checkCancel(run);
    if (!res.toolCalls.length) {
      const f = parseFinal(res.text);
      return finish(f.text || '…', f.followUps);
    }
    messages.push({
      role: 'assistant',
      content: res.text,
      toolCalls: res.toolCalls,
    });
    let final: { text: string; followUps: string[] } | undefined;
    for (const call of res.toolCalls) {
      if (call.name === 'answer') {
        const p = answerSchema.safeParse(call.args);
        final = p.success
          ? { text: p.data.text, followUps: p.data.followUps ?? [] }
          : parseFinal(res.text || JSON.stringify(call.args));
        continue;
      }
      const def = tools.find((t) => t.name === call.name);
      run.status(def?.status?.[run.locale] ?? `${call.name} …`);
      const r = await app.tools.call(call.name, call.args, { app, run });
      checkCancel(run);
      messages.push({
        role: 'tool',
        toolCallId: call.id,
        name: call.name,
        content: r.text,
      });
    }
    if (final) return finish(final.text, final.followUps);
  }
  return finish('Sorry, I ran out of steps before I could finish that.', []);
}

export interface AskInput {
  text: string;
  channel: 'glasses' | 'phone';
  locale: 'de' | 'en';
  now?: number;
  /** The phone's UTC offset in minutes (from `ask.now`). Default: the last one seen. */
  utcOffsetMin?: number | null;
  askId?: string;
  /** The socket that asked (phone tools go back to it). */
  connId?: string;
  signal?: AbortSignal;
  onStatus?: (line: string) => void;
}

/** One question in the shared conversation. */
export async function ask(
  app: App,
  input: AskInput,
): Promise<Answer & { conversationId: string }> {
  await app.conversations.maintainBounded();
  const conv = app.conversations.current();
  const history = app.conversations
    .turns(conv.id)
    .map<ChatMessage>((t) => ({ role: t.role, content: t.text }));
  app.conversations.addTurn(conv.id, 'user', input.text, input.channel);
  const utcOffsetMin =
    input.utcOffsetMin ?? app.settings.displayOffsetMin();
  const run = newRun({
    utcOffsetMin,
    channel: input.channel,
    locale: input.locale,
    ...(input.askId ? { askId: input.askId } : {}),
    ...(input.connId ? { connId: input.connId } : {}),
    ...(input.signal ? { signal: input.signal } : {}),
    status: (l) => input.onStatus?.(l),
  });
  input.onStatus?.(input.locale === 'de' ? 'Denke nach …' : 'Thinking …');
  const memories = app.memory.search(input.text, 8, { touch: true });
  const system = buildSystemPrompt({
    now: input.now ?? app.clock.now(),
    utcOffsetMin,
    locale: input.locale,
    channel: input.channel,
    userName: app.settings.str('user.name'),
    memories,
    skillIndex: app.skills.index(),
    conversationSummary: app.conversations.summaryOf(conv.id),
  });
  const answer = await runAgent(app, {
    system,
    history: [...history, { role: 'user', content: input.text }],
    run,
  });
  app.conversations.addTurn(conv.id, 'assistant', answer.text, input.channel);
  return { ...answer, conversationId: conv.id };
}

/** Chat loop, or the active agent-runtime provider (Codex / Claude Code) when one is selected. */
export async function runAgent(app: App, input: LoopInput): Promise<Answer> {
  const active = app.providers.active();
  if (active?.kind === 'agent-runtime') {
    // Unique per run (ask ids are only unique per socket); the runtime sends it back as X-Lotti-Ask.
    const key = `${input.run.askId ?? 'run'}_${Math.random().toString(36).slice(2)}`;
    app.runs.set(key, input.run);
    try {
      const prompt = input.history
        .map((m) =>
          m.role === 'user'
            ? `User: ${m.content}`
            : m.role === 'assistant'
              ? `Lotti: ${m.content}`
              : '',
        )
        .filter(Boolean)
        .join('\n');
      const r = await active.run({
        system: input.system,
        prompt,
        askId: key,
        mcpServers: [
          {
            name: 'lotti',
            url: `http://127.0.0.1:${app.config.port}/mcp/tools`,
            bearerToken: app.auth.internalToken(),
          },
        ],
        ...(input.run.signal ? { signal: input.run.signal } : {}),
        onStatus: input.run.status,
      });
      const f = parseFinal(r.text);
      return {
        text: f.text,
        followUps: f.followUps,
        actions: input.run.actions.slice(0, 2),
        ...(input.run.undo ? { undo: input.run.undo } : {}),
      };
    } catch (e) {
      if (input.run.signal?.aborted) throw new CancelledError();
      if (!app.providers.fallbackId()) throw e;
      app.log.warn(
        `runtime ${active.id} failed, using fallback`,
        e instanceof Error ? e.message : e,
      );
    } finally {
      app.runs.delete(key);
    }
  }
  return runLoop(app, input);
}

/** A scheduled/background run with a prompt. Returns null text when the agent reported NOTHING. */
export async function runJobPrompt(
  app: App,
  prompt: string,
  extra: { signal?: AbortSignal; context?: string; noInbox?: boolean } = {},
): Promise<{ text: string; nothing: boolean }> {
  const utcOffsetMin = app.settings.displayOffsetMin();
  const system = buildSystemPrompt({
    now: app.clock.now(),
    utcOffsetMin,
    ...(extra.noInbox ? { noInbox: true } : {}),
    locale: 'en',
    channel: 'job',
    userName: app.settings.str('user.name'),
    memories: app.memory.search(prompt, 6),
    skillIndex: app.skills.index(),
    conversationSummary: null,
    jobMode: true,
  });
  const run = newRun({
    utcOffsetMin,
    ...(extra.signal ? { signal: extra.signal } : {}),
  });
  const a = await runAgent(app, {
    system,
    history: [
      {
        role: 'user',
        content: (extra.context ? extra.context + '\n\n' : '') + prompt,
      },
    ],
    run,
  });
  return { text: a.text, nothing: isNothing(a.text) };
}
