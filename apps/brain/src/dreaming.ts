import type { App } from './app.ts';
import { DAY, isoLocal } from './util/clock.ts';
import { newId } from './util/crypto.ts';
import { extractJson } from './util/text.ts';
import { norm } from './memory.ts';

export interface DreamReport {
  id: string;
  at: string;
  report: string;
  stats: Record<string, number>;
}

function jaccard(a: string, b: string): number {
  const x = new Set(norm(a).split(' '));
  const y = new Set(norm(b).split(' '));
  let inter = 0;
  for (const w of x) if (y.has(w)) inter++;
  const uni = x.size + y.size - inter;
  return uni ? inter / uni : 0;
}

/** Nightly housekeeping: dedupe/merge, resolve contradictions (newest wins), drop stale, tidy skills, refresh summaries. */
export class DreamingService {
  constructor(private app: App) {}

  async run(): Promise<DreamReport> {
    const app = this.app;
    const lines: string[] = [];
    const stats = {
      merged: 0,
      contradictions: 0,
      stale: 0,
      summaries: 0,
      unusedSkills: 0,
      unusedScripts: 0,
    };

    // 1. dedupe: near-identical memories -> keep newest, supersede older
    const active = app.memory.list({ limit: 5000 }); // newest first
    const gone = new Set<string>();
    for (let i = 0; i < active.length; i++) {
      const a = active[i]!;
      if (gone.has(a.id)) continue;
      for (let j = i + 1; j < active.length; j++) {
        const b = active[j]!;
        if (gone.has(b.id) || a.kind !== b.kind) continue;
        if (jaccard(a.text, b.text) >= 0.8) {
          app.memory.supersede(b.id);
          gone.add(b.id);
          stats.merged++;
          lines.push(`Merged duplicate: "${b.text}" -> "${a.text}"`);
        }
      }
    }

    // 2. contradictions: ask the LLM; newest wins
    const rest = active.filter((m) => !gone.has(m.id));
    if (rest.length >= 2) {
      try {
        const raw = await app.providers.text(
          'You review a list of memories about one user. Find pairs that CONTRADICT each other (e.g. two different home towns). ' +
            'Return ONLY JSON: [{"a":"<id>","b":"<id>"}] (empty array if none). Do not list mere duplicates or compatible facts.',
          rest.map((m) => `${m.id} [${m.createdAt}] ${m.text}`).join('\n'),
        );
        const j = extractJson(raw);
        if (Array.isArray(j)) {
          for (const p of j) {
            const x = rest.find((m) => m.id === p?.a);
            const y = rest.find((m) => m.id === p?.b);
            if (!x || !y || gone.has(x.id) || gone.has(y.id)) continue;
            const [newer, older] = x.createdAt >= y.createdAt ? [x, y] : [y, x];
            app.db.run(
              'UPDATE memories SET supersedes=? WHERE id=?',
              older.id,
              newer.id,
            );
            app.memory.supersede(older.id);
            gone.add(older.id);
            stats.contradictions++;
            lines.push(
              `Contradiction: kept newer "${newer.text}", superseded "${older.text}"`,
            );
          }
        }
      } catch (e) {
        lines.push(
          'Contradiction check skipped: ' +
            (e instanceof Error ? e.message : String(e)),
        );
      }
    }

    // 3. stale: not used (and not created) within memory.stale_days
    const cutoff =
      app.clock.now() - app.settings.num('memory.stale_days') * DAY;
    for (const m of app.memory.list({ limit: 5000 })) {
      if (gone.has(m.id)) continue;
      const last = Date.parse(m.lastUsedAt ?? m.createdAt);
      if (last < cutoff && m.kind !== 'preference') {
        app.memory.delete(m.id);
        stats.stale++;
        lines.push(`Dropped stale: "${m.text}"`);
      }
    }

    // 4. tidy skills/scripts: report the unused ones (never deletes by itself)
    const unusedCut = app.clock.now() - 90 * DAY;
    for (const kind of ['skill', 'script'] as const) {
      for (const f of app.skills.list(kind)) {
        const last = f.lastUsedAt
          ? Date.parse(f.lastUsedAt)
          : Date.parse(f.updatedAt);
        if (last < unusedCut) {
          stats[kind === 'skill' ? 'unusedSkills' : 'unusedScripts']++;
          lines.push(
            `Unused ${kind} for 90+ days: ${f.name} (consider deleting)`,
          );
        }
      }
    }

    // 5. refresh summaries of closed conversations that have none
    const missing = app.db.all<{ id: string }>(
      "SELECT id FROM conversations WHERE status='closed' AND (summary IS NULL OR summary='') LIMIT 20",
    );
    for (const c of missing) {
      app.db.run("UPDATE conversations SET status='open' WHERE id=?", c.id);
      await app.conversations.close(c.id);
      stats.summaries++;
    }

    const report = lines.length ? lines.join('\n') : 'Nothing to tidy.';
    const id = newId('dream_');
    app.db.run(
      'INSERT INTO dream_reports(id,at,report,stats) VALUES(?,?,?,?)',
      id,
      app.clock.now(),
      report,
      JSON.stringify(stats),
    );
    return { id, at: isoLocal(app.clock.now()), report, stats };
  }

  reports(limit = 10): DreamReport[] {
    return this.app.db
      .all<{ id: string; at: number; report: string; stats: string }>(
        'SELECT * FROM dream_reports ORDER BY at DESC, rowid DESC LIMIT ?',
        limit,
      )
      .map((r) => ({
        id: r.id,
        at: isoLocal(r.at),
        report: r.report,
        stats: JSON.parse(r.stats),
      }));
  }
}
