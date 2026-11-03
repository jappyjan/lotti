import type { App } from './app.ts';
import { MIN, isoLocal } from './util/clock.ts';
import { newId } from './util/crypto.ts';
import { clip, extractJson, ftsQuery } from './util/text.ts';

export interface Turn {
  id: number;
  role: 'user' | 'assistant';
  text: string;
  channel: string | null;
  at: string;
  /** Summarised away: no longer part of the model's context, still shown in the history. */
  compacted?: boolean;
}

export interface ConversationInfo {
  id: string;
  title: string | null;
  summary: string | null;
  status: 'open' | 'closed';
  startedAt: string;
  lastActiveAt: string;
}

interface CRow {
  id: string;
  title: string | null;
  summary: string | null;
  status: 'open' | 'closed';
  started_at: number;
  last_active_at: number;
  compacted_at: number | null;
}

const toInfo = (r: CRow): ConversationInfo => ({
  id: r.id,
  title: r.title,
  summary: r.summary,
  status: r.status,
  startedAt: isoLocal(r.started_at),
  lastActiveAt: isoLocal(r.last_active_at),
});

const renderTurns = (turns: { role: string; text: string }[]) =>
  turns
    .map((t) => `${t.role === 'user' ? 'User' : 'Lotti'}: ${t.text}`)
    .join('\n');

/** How long `hello` / `ask` wait for conversation maintenance before going on. */
export const MAINTAIN_WAIT_MS = 3000;

/**
 * One shared "current conversation" across glasses and phone.
 *  - idle >= compact_idle_min (10): LLM summary replaces old turns, recent turns kept.
 *  - idle >= new_idle_min (60): conversation is closed (title + summary, memory extraction) and a new one starts.
 * `maintain()` is called before every ask and by the scheduler tick.
 */
export class ConversationService {
  constructor(private app: App) {}

  openRow(): CRow | undefined {
    return this.app.db.get<CRow>(
      "SELECT * FROM conversations WHERE status='open' ORDER BY last_active_at DESC LIMIT 1",
    );
  }

  private maintaining?: Promise<void>;

  /**
   * Close/compact if idle thresholds passed. Never throws (LLM failures are logged). Single-flight: callers
   * that arrive while a run is in progress share it (no double compaction / close).
   */
  maintain(): Promise<void> {
    if (!this.maintaining)
      this.maintaining = this.doMaintain()
        .catch((e) =>
          this.app.log.warn(
            'conversation maintenance failed',
            e instanceof Error ? e.message : e,
          ),
        )
        .finally(() => (this.maintaining = undefined));
    return this.maintaining;
  }

  /**
   * `maintain()`, but wait at most `ms` (default MAINTAIN_WAIT_MS): a slow compaction (LLM) must not hold up a
   * welcome or an ask; it finishes in the background.
   */
  async maintainBounded(ms = MAINTAIN_WAIT_MS): Promise<void> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    await Promise.race([
      this.maintain(),
      new Promise<void>((r) => (timer = setTimeout(r, ms))),
    ]).finally(() => clearTimeout(timer));
  }

  private async doMaintain(): Promise<void> {
    const c = this.openRow();
    if (!c) return;
    const idle = this.app.clock.now() - c.last_active_at;
    const s = this.app.settings;
    if (idle >= s.num('conversation.new_idle_min') * MIN) {
      await this.close(c.id);
    } else if (
      idle >= s.num('conversation.compact_idle_min') * MIN &&
      (!c.compacted_at || c.compacted_at < c.last_active_at)
    ) {
      await this.compact(c.id);
    }
  }

  /** The current open conversation (created if none). Call `maintain()` first. */
  current(): ConversationInfo {
    const c = this.openRow();
    if (c) return toInfo(c);
    const id = newId('conv_');
    const now = this.app.clock.now();
    this.app.db.run(
      "INSERT INTO conversations(id,status,started_at,last_active_at) VALUES(?, 'open', ?, ?)",
      id,
      now,
      now,
    );
    this.app.hub.broadcast({
      type: 'conversation',
      conversationId: id,
      event: 'new',
    });
    return toInfo(this.openRow()!);
  }

  addTurn(
    conversationId: string,
    role: 'user' | 'assistant',
    text: string,
    channel?: string | null,
  ): void {
    const now = this.app.clock.now();
    this.app.db.tx(() => {
      const r = this.app.db.raw
        .prepare(
          'INSERT INTO turns(conversation_id,role,text,channel,at) VALUES(?,?,?,?,?)',
        )
        .run(conversationId, role, text, channel ?? null, now);
      this.app.db.run(
        'INSERT INTO turns_fts(text, turn_id, conversation_id) VALUES(?,?,?)',
        text,
        String(r.lastInsertRowid),
        conversationId,
      );
      this.app.db.run(
        'UPDATE conversations SET last_active_at=? WHERE id=?',
        now,
        conversationId,
      );
    });
  }

  /** Live turns (the model's context). `all` also returns the compacted ones, flagged. */
  turns(conversationId: string, limit = 1000, all = false): Turn[] {
    return this.app.db
      .all<{
        id: number;
        role: 'user' | 'assistant';
        text: string;
        channel: string | null;
        at: number;
        compacted: number;
      }>(
        `SELECT * FROM turns WHERE conversation_id=? ${all ? '' : 'AND compacted=0'} ORDER BY id LIMIT ?`,
        conversationId,
        limit,
      )
      .map((t) => ({
        id: t.id,
        role: t.role,
        text: t.text,
        channel: t.channel,
        at: isoLocal(t.at),
        ...(t.compacted ? { compacted: true } : {}),
      }));
  }

  private indexConv(id: string): void {
    const c = this.app.db.get<CRow>(
      'SELECT * FROM conversations WHERE id=?',
      id,
    );
    if (!c) return;
    this.app.db.run('DELETE FROM conv_fts WHERE conversation_id=?', id);
    this.app.db.run(
      'INSERT INTO conv_fts(title, summary, conversation_id) VALUES(?,?,?)',
      c.title ?? '',
      c.summary ?? '',
      id,
    );
  }

  async compact(id: string): Promise<boolean> {
    const keep = this.app.settings.num('conversation.keep_recent_turns');
    const all = this.app.db.all<{ id: number; role: string; text: string }>(
      'SELECT id, role, text FROM turns WHERE conversation_id=? AND compacted=0 ORDER BY id',
      id,
    );
    if (all.length <= keep) return false;
    const old = all.slice(0, all.length - keep);
    const c = this.app.db.get<CRow>(
      'SELECT * FROM conversations WHERE id=?',
      id,
    )!;
    let summary: string;
    try {
      summary = await this.app.providers.text(
        'Summarise this conversation so far in at most 6 short sentences (same language as the conversation). ' +
          'Keep names, numbers, decisions and open questions. No preamble.',
        (c.summary ? `Earlier summary: ${c.summary}\n\n` : '') +
          renderTurns(old),
      );
    } catch (e) {
      this.app.log.warn(
        'compaction failed',
        e instanceof Error ? e.message : e,
      );
      return false;
    }
    this.app.db.tx(() => {
      for (const t of old)
        this.app.db.run('UPDATE turns SET compacted=1 WHERE id=?', t.id);
      this.app.db.run(
        'UPDATE conversations SET summary=?, compacted_at=? WHERE id=?',
        summary,
        this.app.clock.now(),
        id,
      );
    });
    this.indexConv(id);
    await this.app.memory.extractFrom(renderTurns(old), id);
    this.app.hub.broadcast({
      type: 'conversation',
      conversationId: id,
      event: 'compacted',
    });
    return true;
  }

  /** End a conversation: title + summary, memory extraction. A new one starts at the next turn. */
  async close(id: string): Promise<void> {
    const c = this.app.db.get<CRow>(
      'SELECT * FROM conversations WHERE id=?',
      id,
    );
    if (!c || c.status === 'closed') return;
    const { title, summary, body } = await this.titleAndSummary(c);
    if (body) await this.app.memory.extractFrom(body, id);
    this.app.db.run(
      "UPDATE conversations SET status='closed', title=?, summary=? WHERE id=?",
      title,
      summary,
      id,
    );
    this.indexConv(id);
  }

  /** Dreaming: (re)write title + summary of a closed conversation. It stays closed (never the open one). */
  async refreshSummary(id: string): Promise<boolean> {
    const c = this.app.db.get<CRow>(
      'SELECT * FROM conversations WHERE id=?',
      id,
    );
    if (!c || c.status !== 'closed') return false;
    const { title, summary } = await this.titleAndSummary(c);
    this.app.db.run(
      'UPDATE conversations SET title=?, summary=? WHERE id=?',
      title,
      summary,
      id,
    );
    this.indexConv(id);
    return true;
  }

  private async titleAndSummary(
    c: CRow,
  ): Promise<{ title: string; summary: string; body: string | null }> {
    const turns = this.turns(c.id);
    const body =
      (c.summary ? `Summary so far: ${c.summary}\n\n` : '') +
      renderTurns(turns);
    let title = clip(
      turns.find((t) => t.role === 'user')?.text ?? 'Conversation',
      60,
    );
    let summary = c.summary ?? clip(renderTurns(turns), 400);
    if (!turns.length && !c.summary) return { title, summary, body: null };
    try {
      const raw = await this.app.providers.text(
        'Return ONLY JSON {"title": string (max 6 words), "summary": string (max 5 short sentences)} for this conversation, in its language.',
        body,
      );
      const j = extractJson(raw) as
        { title?: string; summary?: string } | undefined;
      if (j?.title) title = String(j.title);
      if (j?.summary) summary = String(j.summary);
    } catch (e) {
      this.app.log.warn(
        'conversation summary failed',
        e instanceof Error ? e.message : e,
      );
    }
    return { title, summary, body };
  }

  list(limit = 30): ConversationInfo[] {
    return this.app.db
      .all<CRow>(
        'SELECT * FROM conversations ORDER BY last_active_at DESC LIMIT ?',
        limit,
      )
      .map(toInfo);
  }

  get(
    id: string,
  ): { conversation: ConversationInfo; turns: Turn[] } | undefined {
    const c = this.app.db.get<CRow>(
      'SELECT * FROM conversations WHERE id=?',
      id,
    );
    return c
      ? { conversation: toInfo(c), turns: this.turns(id, 5000, true) }
      : undefined;
  }

  /** FTS5 over titles, summaries and turns. */
  search(
    query: string,
    limit = 10,
  ): {
    conversationId: string;
    title: string | null;
    kind: 'title' | 'summary' | 'turn';
    snippet: string;
  }[] {
    const q = ftsQuery(query);
    if (!q) return [];
    const res: {
      conversationId: string;
      title: string | null;
      kind: 'title' | 'summary' | 'turn';
      snippet: string;
    }[] = [];
    const seen = new Set<string>();
    const convs = this.app.db.all<{
      conversation_id: string;
      title: string;
      summary: string;
    }>(
      'SELECT conversation_id, title, summary FROM conv_fts WHERE conv_fts MATCH ? ORDER BY bm25(conv_fts) LIMIT ?',
      q,
      limit,
    );
    for (const c of convs) {
      seen.add(c.conversation_id);
      res.push({
        conversationId: c.conversation_id,
        title: c.title || null,
        kind: 'summary',
        snippet: clip(c.summary || c.title, 200),
      });
    }
    const turns = this.app.db.all<{ conversation_id: string; text: string }>(
      'SELECT conversation_id, text FROM turns_fts WHERE turns_fts MATCH ? ORDER BY bm25(turns_fts) LIMIT ?',
      q,
      limit,
    );
    for (const t of turns) {
      if (res.length >= limit) break;
      const title =
        this.app.db.get<{ title: string | null }>(
          'SELECT title FROM conversations WHERE id=?',
          t.conversation_id,
        )?.title ?? null;
      res.push({
        conversationId: t.conversation_id,
        title,
        kind: 'turn',
        snippet: clip(t.text, 200),
      });
    }
    return res.slice(0, limit);
  }

  /** Text block for the model: summary + recent turns are passed as messages by the agent. */
  summaryOf(id: string): string | null {
    return (
      this.app.db.get<{ summary: string | null }>(
        'SELECT summary FROM conversations WHERE id=?',
        id,
      )?.summary ?? null
    );
  }
}
