import { z } from 'zod';
import type { App } from '../app.ts';
import type { ProposedAction, UndoHandle } from '../actions.ts';
import { clip } from '../util/text.ts';

export type Risk = 'free' | 'tap' | 'app_only';
export type Caller = 'app' | 'mcp' | 'agent';

export interface UndoSpec {
  label: string;
  op: string;
  input: unknown;
}

/** Return `out(result, {text, undo})` from a handler to attach a model-readable text and/or an undo. */
export class OpOutput {
  constructor(
    public result: unknown,
    public text?: string,
    public undo?: UndoSpec,
  ) {}
}
export function out(
  result: unknown,
  extra: { text?: string; undo?: UndoSpec } = {},
): OpOutput {
  return new OpOutput(result, extra.text, extra.undo);
}

export interface OpContext {
  app: App;
  caller: Caller;
}

export interface Operation<S extends z.ZodType = z.ZodType> {
  name: string; // group.verb
  group: string;
  description: string;
  inputSchema: S;
  risk: Risk;
  /** Title of the proposed action when a `tap` op is called by the agent. */
  proposalTitle?: (input: z.infer<S>) => string;
  handler(
    input: z.infer<S>,
    ctx: OpContext,
  ): Promise<unknown | OpOutput> | unknown | OpOutput;
}

export type OpResponse =
  | {
      ok: true;
      result: unknown;
      text: string;
      undoHandle?: UndoHandle;
      proposed?: ProposedAction;
    }
  | { ok: false; error: string };

export function defineOp<S extends z.ZodType>(op: Operation<S>): Operation {
  return op as unknown as Operation;
}

export function jsonSchemaOf(schema: z.ZodType): Record<string, unknown> {
  const j = z.toJSONSchema(schema, {
    io: 'input',
    unrepresentable: 'any',
  }) as Record<string, unknown>;
  delete j.$schema;
  return j;
}

/**
 * The ONE registry of operations. Front doors:
 *   - HTTP: GET /api/v1/ops, POST /api/v1/ops/:name        (caller 'app', everything)
 *   - Admin MCP: /mcp/admin                                  (caller 'mcp', no app_only)
 *   - In-process agent tools (src/tools/registry.ts)         (caller 'agent', no app_only)
 */
export class OpRegistry {
  private ops = new Map<string, Operation>();
  constructor(private app: App) {}

  register(op: Operation): void {
    this.ops.set(op.name, op);
  }
  get(name: string): Operation | undefined {
    return this.ops.get(name);
  }
  all(): Operation[] {
    return [...this.ops.values()];
  }
  /** Ops a given caller may see. */
  visibleTo(caller: Caller): Operation[] {
    return this.all().filter((o) => caller === 'app' || o.risk !== 'app_only');
  }
  describe(caller: Caller = 'app') {
    return this.visibleTo(caller).map((o) => ({
      name: o.name,
      group: o.group,
      description: o.description,
      inputSchema: jsonSchemaOf(o.inputSchema),
      risk: o.risk,
    }));
  }

  async invoke(
    name: string,
    rawInput: unknown,
    caller: Caller,
    opts: { noUndo?: boolean } = {},
  ): Promise<OpResponse> {
    const op = this.ops.get(name);
    if (!op) return { ok: false, error: `Unknown operation: ${name}` };
    if (caller !== 'app' && op.risk === 'app_only') {
      return { ok: false, error: `${name} is only available in the app.` };
    }
    const parsed = op.inputSchema.safeParse(rawInput ?? {});
    if (!parsed.success) {
      return {
        ok: false,
        error:
          'Invalid input: ' +
          parsed.error.issues
            .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
            .join('; '),
      };
    }
    if (caller !== 'app' && op.risk === 'tap') {
      const title = op.proposalTitle
        ? op.proposalTitle(parsed.data)
        : clip(`${op.description}`, 60);
      const action = this.app.actions.propose({
        title,
        target: 'server',
        tool: `op:${name}`,
        args: parsed.data as Record<string, unknown>,
      });
      return {
        ok: true,
        result: { proposed: true, actionId: action.id },
        text: `Proposed "${title}". It runs only after the user confirms it in the app.`,
        proposed: action,
      };
    }
    try {
      const r = await op.handler(parsed.data, { app: this.app, caller });
      const o = r instanceof OpOutput ? r : new OpOutput(r);
      const undoHandle =
        o.undo && !opts.noUndo
          ? this.app.actions.createUndo(o.undo)
          : undefined;
      const text = o.text ?? clip(JSON.stringify(o.result ?? null), 8000);
      return {
        ok: true,
        result: o.result ?? null,
        text,
        ...(undoHandle ? { undoHandle } : {}),
      };
    } catch (e) {
      return { ok: false, error: e instanceof Error ? e.message : String(e) };
    }
  }
}

export const Id = z.string().min(1);
