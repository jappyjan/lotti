import type { App } from './app.ts';
import { isoLocal } from './util/clock.ts';
import { newId } from './util/crypto.ts';
import { extractJson, ftsQuery } from './util/text.ts';

export interface Memory {
  id: string;
  text: string;
  kind: string;
  sourceConversation: string | null;
  createdAt: string;
  lastUsedAt: string | null;
  supersedes: string | null;
  status: 'active' | 'superseded';
}

interface Row {
  id: string;
  text: string;
  kind: string;
  source_conversation: string | null;
  created_at: number;
  last_used_at: number | null;
  supersedes: string | null;
  status: 'active' | 'superseded';
}

const toMemory = (r: Row): Memory => ({
  id: r.id,
  text: r.text,
  kind: r.kind,
  sourceConversation: r.source_conversation,
  createdAt: isoLocal(r.created_at),
  lastUsedAt: r.last_used_at ? isoLocal(r.last_used_at) : null,
  supersedes: r.supersedes,
  status: r.status,
});

export const norm = (t: string) =>
  t
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

/** Long-term memory: SQLite + FTS5. */
export class MemoryService {
  constructor(private app: App) {}

  remember(
    text: string,
    opts: {
      kind?: string;
      source?: string | null;
      supersedes?: string | null;
      id?: string;
      createdAt?: number;
    } = {},
  ): Memory {
    const t = text.trim();
    if (!t) throw new Error('Nothing to remember.');
    const dup = this.app.db
      .all<Row>("SELECT * FROM memories WHERE status='active'")
      .find((r) => norm(r.text) === norm(t));
    if (dup) {
      this.app.db.run(
        'UPDATE memories SET last_used_at=? WHERE id=?',
        this.app.clock.now(),
        dup.id,
      );
      return toMemory(dup);
    }
    const id = opts.id ?? newId('mem_');
    this.app.db.tx(() => {
      this.app.db.run(
        'INSERT INTO memories(id,text,kind,source_conversation,created_at,supersedes,status) VALUES(?,?,?,?,?,?,?)',
        id,
        t,
        opts.kind ?? 'fact',
        opts.source ?? null,
        opts.createdAt ?? this.app.clock.now(),
        opts.supersedes ?? null,
        'active',
      );
      this.app.db.run(
        'INSERT INTO memory_fts(text, memory_id) VALUES(?,?)',
        t,
        id,
      );
      if (opts.supersedes) this.supersede(opts.supersedes);
    });
    return this.get(id)!;
  }

  /** Mark superseded: kept for history, no longer searched or shown to the model. */
  supersede(id: string): void {
    this.app.db.run("UPDATE memories SET status='superseded' WHERE id=?", id);
    this.app.db.run('DELETE FROM memory_fts WHERE memory_id=?', id);
  }

  get(id: string): Memory | undefined {
    const r = this.app.db.get<Row>('SELECT * FROM memories WHERE id=?', id);
    return r ? toMemory(r) : undefined;
  }

  list(
    opts: { kind?: string; limit?: number; includeSuperseded?: boolean } = {},
  ): Memory[] {
    const rows = this.app.db.all<Row>(
      `SELECT * FROM memories WHERE (? OR status='active') AND (? IS NULL OR kind=?) ORDER BY created_at DESC, rowid DESC LIMIT ?`,
      opts.includeSuperseded ? 1 : 0,
      opts.kind ?? null,
      opts.kind ?? null,
      opts.limit ?? 200,
    );
    return rows.map(toMemory);
  }

  search(
    query: string,
    limit = 8,
    opts: { touch?: boolean; all?: boolean } = {},
  ): Memory[] {
    const q = ftsQuery(query);
    if (!q) return [];
    const fq = opts.all ? q.replace(/ OR /g, ' AND ') : q;
    const rows = this.app.db.all<Row>(
      `SELECT m.* FROM memory_fts f JOIN memories m ON m.id=f.memory_id
       WHERE memory_fts MATCH ? AND m.status='active' ORDER BY bm25(memory_fts) LIMIT ?`,
      fq,
      limit,
    );
    if (opts.touch) for (const r of rows) this.touch(r.id);
    return rows.map(toMemory);
  }

  touch(id: string): void {
    this.app.db.run(
      'UPDATE memories SET last_used_at=? WHERE id=?',
      this.app.clock.now(),
      id,
    );
  }

  update(
    id: string,
    patch: { text?: string; kind?: string },
  ): Memory | undefined {
    const cur = this.get(id);
    if (!cur) return undefined;
    this.app.db.tx(() => {
      if (patch.kind)
        this.app.db.run(
          'UPDATE memories SET kind=? WHERE id=?',
          patch.kind,
          id,
        );
      if (patch.text?.trim()) {
        this.app.db.run(
          'UPDATE memories SET text=? WHERE id=?',
          patch.text.trim(),
          id,
        );
        if (cur.status === 'active') {
          this.app.db.run('DELETE FROM memory_fts WHERE memory_id=?', id);
          this.app.db.run(
            'INSERT INTO memory_fts(text, memory_id) VALUES(?,?)',
            patch.text.trim(),
            id,
          );
        }
      }
    });
    return this.get(id);
  }

  delete(id: string): Memory | undefined {
    const cur = this.get(id);
    if (!cur) return undefined;
    this.app.db.tx(() => {
      this.app.db.run('DELETE FROM memories WHERE id=?', id);
      this.app.db.run('DELETE FROM memory_fts WHERE memory_id=?', id);
    });
    return cur;
  }

  count(): number {
    return this.app.db.get<{ n: number }>(
      "SELECT COUNT(*) AS n FROM memories WHERE status='active'",
    )!.n;
  }

  /** LLM extraction of durable facts from text (after compaction / conversation end). */
  async extractFrom(
    text: string,
    conversationId: string | null,
  ): Promise<Memory[]> {
    if (!text.trim()) return [];
    let raw: string;
    try {
      raw = await this.app.providers.text(
        'You extract durable memories about the user from a conversation. Return ONLY a JSON array of ' +
          '{"text": string, "kind": "fact"|"preference"|"person"|"place"|"todo"}. Only stable, useful facts ' +
          '(preferences, people, places, routines). No small talk, no one-off questions. Return [] if nothing.',
        text,
      );
    } catch (e) {
      this.app.log.warn(
        'memory extraction failed',
        e instanceof Error ? e.message : e,
      );
      return [];
    }
    const j = extractJson(raw);
    if (!Array.isArray(j)) return [];
    const out: Memory[] = [];
    for (const it of j.slice(0, 10)) {
      if (it && typeof it.text === 'string' && it.text.trim()) {
        out.push(
          this.remember(it.text, {
            kind: typeof it.kind === 'string' ? it.kind : 'fact',
            source: conversationId,
          }),
        );
      }
    }
    return out;
  }
}
