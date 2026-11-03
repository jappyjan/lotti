import { z } from 'zod';
import type { App } from '../app.ts';
import type { ProposedAction, UndoHandle } from '../actions.ts';
import type { ToolSpec } from '../providers/types.ts';
import { jsonSchemaOf } from '../ops/registry.ts';
import { clip } from '../util/text.ts';

/** State of one agent run (ask or job). Tools read it and append proposals / undo handles. */
export interface RunState {
  askId?: string;
  channel: 'glasses' | 'phone' | 'job';
  locale: 'de' | 'en';
  signal?: AbortSignal;
  actions: ProposedAction[];
  undo?: UndoHandle;
  status(line: string): void;
}

export function newRun(partial: Partial<RunState> = {}): RunState {
  return { channel: 'job', locale: 'en', actions: [], status() {}, ...partial };
}

export interface ToolContext {
  app: App;
  run: RunState;
}

export interface ToolDef {
  name: string;
  description: string;
  inputSchema: z.ZodType;
  /** Use instead of the schema derived from `inputSchema` (remote MCP tools bring their own JSON Schema). */
  jsonSchema?: Record<string, unknown>;
  /** server: runs here. phone: proxied to the phone over the WebSocket (10 s). */
  kind: 'server' | 'phone';
  /** The tool only PROPOSES an action; the user must tap (perform) before anything happens. Informational. */
  needsConfirmation?: boolean;
  /** One-line status shown while the tool runs. */
  status?: { de: string; en: string };
  handler(args: any, ctx: ToolContext): Promise<string>;
}

/**
 * The ONE tool registry. Exposed to the internal agent loop (agentTools) and as an MCP server
 * (`/mcp/tools`, internal token) for subscription runtimes. Integrations add tools with `register`.
 */
export class ToolRegistry {
  private tools = new Map<string, ToolDef>();
  constructor(private app: App) {}

  register(t: ToolDef): void {
    this.tools.set(t.name, t);
  }
  unregister(name: string): void {
    this.tools.delete(name);
  }
  get(name: string): ToolDef | undefined {
    return this.tools.get(name);
  }
  native(): ToolDef[] {
    return [...this.tools.values()];
  }

  /** Admin ops exposed as tools (`jobs.create` -> `jobs_create`), never app_only. */
  opTools(groups?: string[]): ToolDef[] {
    const ops = this.app.ops
      .visibleTo('agent')
      .filter((o) => !groups || groups.includes(o.group));
    return ops.map<ToolDef>((o) => ({
      name: o.name.replace('.', '_'),
      description: `${o.description}${o.risk === 'tap' ? " (needs the user's confirmation: proposes an action)" : ''}`,
      inputSchema: o.inputSchema,
      kind: 'server',
      needsConfirmation: o.risk === 'tap',
      async handler(args, ctx) {
        const r = await ctx.app.ops.invoke(o.name, args, 'agent');
        if (!r.ok) return `Error: ${r.error}`;
        if (r.proposed) ctx.run.actions.push(r.proposed);
        if (r.undoHandle) ctx.run.undo = r.undoHandle;
        return r.text;
      },
    }));
  }

  /** Everything the agent (and `/mcp/tools`) can use right now. */
  all(): ToolDef[] {
    const groups = this.app.settings.get<string[]>('agent.op_tool_groups');
    const taken = new Set(this.native().map((t) => t.name));
    return [
      ...this.native(),
      ...this.opTools(groups).filter((t) => !taken.has(t.name)),
    ];
  }

  specs(tools: ToolDef[]): ToolSpec[] {
    return tools.map((t) => ({
      name: t.name,
      description: t.description,
      parameters: t.jsonSchema ?? jsonSchemaOf(t.inputSchema),
    }));
  }

  /** Validate + run. Never throws: errors become the tool result text. */
  async call(
    name: string,
    rawArgs: unknown,
    ctx: ToolContext,
  ): Promise<{ ok: boolean; text: string }> {
    const t = this.all().find((x) => x.name === name);
    if (!t) return { ok: false, text: `Unknown tool: ${name}` };
    const parsed = t.inputSchema.safeParse(rawArgs ?? {});
    if (!parsed.success) {
      return {
        ok: false,
        text:
          'Invalid arguments: ' +
          parsed.error.issues
            .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
            .join('; '),
      };
    }
    try {
      return {
        ok: true,
        text: clip(await t.handler(parsed.data, ctx), 30_000),
      };
    } catch (e) {
      return {
        ok: false,
        text: `Error: ${e instanceof Error ? e.message : String(e)}`,
      };
    }
  }
}
