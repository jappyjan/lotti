import type { App } from './app.ts';
import type { ActionOutcome } from './integrations/index.ts';
import { newId } from './util/crypto.ts';
import { clip } from './util/text.ts';

/** What the app sees in `answer.actions[]`. */
export interface ProposedAction {
  id: string;
  title: string;
  target: 'phone' | 'server';
  tool?: string;
  args?: Record<string, unknown>;
}

export interface UndoHandle {
  id: string;
  label: string;
}

export type ServerActionHandler = (
  args: Record<string, unknown>,
  app: App,
) => Promise<ActionOutcome>;

/** Proposed actions (run only after `perform`) and undo handles. */
export class ActionService {
  private handlers = new Map<string, ServerActionHandler>();
  constructor(private app: App) {}

  /** Register a server action by tool name (used by `perform`). */
  register(tool: string, h: ServerActionHandler): void {
    this.handlers.set(tool, h);
  }
  unregister(tool: string): void {
    this.handlers.delete(tool);
  }
  hasHandler(tool: string): boolean {
    return this.handlers.has(tool);
  }

  /** A proposal with nobody on the other end to tap: park it in the app's inbox so it never just vanishes. */
  toInbox(a: ProposedAction, summary: string): void {
    this.app.inbox.create({
      kind: 'info',
      title: a.title,
      summary,
      actions: [a],
      expiresInHours: 24,
    });
  }

  propose(a: Omit<ProposedAction, 'id'>): ProposedAction {
    const id = newId('act_');
    this.app.db.run(
      'INSERT INTO actions(id,title,target,tool,args,status,created_at) VALUES(?,?,?,?,?,?,?)',
      id,
      a.title,
      a.target,
      a.tool ?? '',
      JSON.stringify(a.args ?? {}),
      'proposed',
      this.app.clock.now(),
    );
    return { id, ...a };
  }

  get(id: string): (ProposedAction & { status: string }) | undefined {
    const r = this.app.db.get<{
      id: string;
      title: string;
      target: 'phone' | 'server';
      tool: string;
      args: string;
      status: string;
    }>('SELECT * FROM actions WHERE id=?', id);
    return r
      ? {
          id: r.id,
          title: r.title,
          target: r.target,
          tool: r.tool,
          args: JSON.parse(r.args),
          status: r.status,
        }
      : undefined;
  }

  /** `perform`: executes a server action exactly once. Phone actions are run by the app, not here. */
  async perform(
    actionId: string,
  ): Promise<ActionOutcome & { undoHandle?: UndoHandle }> {
    const a = this.get(actionId);
    if (!a) return { ok: false, text: 'Unknown action.' };
    if (a.status !== 'proposed')
      return { ok: false, text: 'This action was already handled.' };
    if (a.target === 'phone')
      return { ok: false, text: 'Phone actions are run by the app itself.' };
    this.app.db.run(
      "UPDATE actions SET status='performing' WHERE id=?",
      actionId,
    );
    let out: ActionOutcome;
    let opUndo: UndoHandle | undefined;
    try {
      if (a.tool!.startsWith('op:')) {
        const r = await this.app.ops.invoke(a.tool!.slice(3), a.args, 'app');
        out = r.ok
          ? { ok: true, text: r.text ?? 'Done.' }
          : { ok: false, text: r.error };
        if (r.ok && r.undoHandle) opUndo = r.undoHandle;
      } else {
        const h = this.handlers.get(a.tool!);
        out = h
          ? await h(a.args ?? {}, this.app)
          : { ok: false, text: `No handler for ${a.tool}.` };
      }
    } catch (e) {
      out = { ok: false, text: e instanceof Error ? e.message : String(e) };
    }
    this.app.db.run(
      'UPDATE actions SET status=? WHERE id=?',
      out.ok ? 'done' : 'failed',
      actionId,
    );
    this.app.log.info(
      `action ${actionId} ${a.tool} ${out.ok ? 'done' : 'FAILED'}: ${clip(out.text, 300)}`,
    );
    const undoHandle =
      opUndo ?? (out.undo ? this.createUndo(out.undo) : undefined);
    return { ...out, ...(undoHandle ? { undoHandle } : {}) };
  }

  createUndo(u: { label: string; op: string; input: unknown }): UndoHandle {
    const id = newId('undo_');
    this.app.db.run(
      'INSERT INTO undos(id,label,op,input,created_at) VALUES(?,?,?,?,?)',
      id,
      u.label,
      u.op,
      JSON.stringify(u.input ?? {}),
      this.app.clock.now(),
    );
    return { id, label: u.label };
  }

  async undo(undoId: string): Promise<{ ok: boolean; text: string }> {
    const r = this.app.db.get<{
      op: string;
      input: string;
      used_at: number | null;
      label: string;
    }>('SELECT * FROM undos WHERE id=?', undoId);
    if (!r) return { ok: false, text: 'Unknown undo.' };
    if (r.used_at) return { ok: false, text: 'Already undone.' };
    this.app.db.run(
      'UPDATE undos SET used_at=? WHERE id=?',
      this.app.clock.now(),
      undoId,
    );
    const out = await this.app.ops.invoke(r.op, JSON.parse(r.input), 'app', {
      noUndo: true,
    });
    return out.ok
      ? { ok: true, text: `Undone: ${r.label}` }
      : { ok: false, text: out.error };
  }
}
