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

const DUP_THRESHOLD = 0.8;
/** Memories per contradiction prompt (grouped by kind). */
export const CONTRADICTION_BATCH = 150;
const yieldNow = () => new Promise<void>((r) => setImmediate(r));

function jaccard(x: Set<string>, y: Set<string>): number {
  let inter = 0;
  for (const w of x) if (y.has(w)) inter++;
  const uni = x.size + y.size - inter;
  return uni ? inter / uni : 0;
}

/**
 * Near-duplicate pairs (Jaccard >= 0.8 on normalised words, same kind) without comparing all pairs:
 * prefix filtering. Words are ordered by rarity; two sets that reach the threshold must share a word among
 * the first |x| - ceil(t*|x|) + 1 of either set, so only those are compared. Exact, not a heuristic.
 * Calls `onDup(keep, drop)` with keep = the earlier item in `items` (newest first).
 */
export async function findNearDuplicates<T extends { id: string; kind: string; text: string }>(
  items: T[],
  onDup: (keep: T, drop: T) => void,
): Promise<void> {
  const sets = items.map(
    (m) => new Set(norm(m.text).split(' ').filter(Boolean)),
  );
  const freq = new Map<string, number>();
  for (const s of sets) for (const w of s) freq.set(w, (freq.get(w) ?? 0) + 1);
  const index = new Map<string, number[]>(); // kind + word -> item indexes
  const prefixes = sets.map((s, i) => {
    const words = [...s].sort(
      (a, b) => freq.get(a)! - freq.get(b)! || (a < b ? -1 : 1),
    );
    const p = words.slice(
      0,
      words.length - Math.ceil(DUP_THRESHOLD * words.length) + 1,
    );
    for (const w of p) {
      const k = `${items[i]!.kind}\u0000${w}`;
      const l = index.get(k);
      if (l) l.push(i);
      else index.set(k, [i]);
    }
    return p;
  });
  const gone = new Set<number>();
  for (let i = 0; i < items.length; i++) {
    if (i % 500 === 499) await yieldNow();
    if (gone.has(i)) continue;
    const cands = new Set<number>();
    for (const w of prefixes[i]!)
      for (const j of index.get(`${items[i]!.kind}\u0000${w}`) ?? [])
        if (j > i && !gone.has(j)) cands.add(j);
    for (const j of [...cands].sort((a, b) => a - b)) {
      if (jaccard(sets[i]!, sets[j]!) >= DUP_THRESHOLD) {
        gone.add(j);
        onDup(items[i]!, items[j]!);
      }
    }
  }
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
    await findNearDuplicates(active, (a, b) => {
      app.memory.supersede(b.id);
      gone.add(b.id);
      stats.merged++;
      lines.push(`Merged duplicate: "${b.text}" -> "${a.text}"`);
    });

    // 2. contradictions: ask the LLM per kind, at most CONTRADICTION_BATCH memories a call; newest wins
    const rest = active.filter((m) => !gone.has(m.id));
    const byKind = new Map<string, typeof rest>();
    for (const m of rest) byKind.set(m.kind, [...(byKind.get(m.kind) ?? []), m]);
    const batches: (typeof rest)[] = [];
    for (const group of byKind.values())
      for (let i = 0; i < group.length; i += CONTRADICTION_BATCH)
        batches.push(group.slice(i, i + CONTRADICTION_BATCH));
    for (const batch of batches.filter((b) => b.length >= 2)) {
      await yieldNow();
      try {
        const raw = await app.providers.text(
          'You review a list of memories about one user. Find pairs that CONTRADICT each other (e.g. two different home towns). ' +
            'Return ONLY JSON: [{"a":"<id>","b":"<id>"}] (empty array if none). Do not list mere duplicates or compatible facts.',
          batch.map((m) => `${m.id} [${m.createdAt}] ${m.text}`).join('\n'),
        );
        const j = extractJson(raw);
        if (Array.isArray(j)) {
          for (const p of j) {
            const x = batch.find((m) => m.id === p?.a);
            const y = batch.find((m) => m.id === p?.b);
            if (!x || !y || x === y || gone.has(x.id) || gone.has(y.id))
              continue;
            const [newer, older] =
              Date.parse(x.createdAt) >= Date.parse(y.createdAt)
                ? [x, y]
                : [y, x];
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
    for (const c of missing)
      if (await app.conversations.refreshSummary(c.id)) stats.summaries++;

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
