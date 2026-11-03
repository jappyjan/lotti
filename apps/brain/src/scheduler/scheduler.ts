import type { App } from '../app.ts';
import { runJobPrompt } from '../agent/loop.ts';
import { MIN, isoLocal } from '../util/clock.ts';
import { newId } from '../util/crypto.ts';
import { clip } from '../util/text.ts';
import { builtinJobs } from './builtin.ts';
import { nextRun, resolveSchedule } from './cron.ts';

export interface Job {
  id: string;
  name: string;
  kind: 'builtin' | 'user';
  builtinKey: string | null;
  prompt: string | null;
  cron: string;
  scheduleText: string | null;
  enabled: boolean;
  nextRunAt: string | null;
  lastRunAt: string | null;
}

interface Row {
  id: string;
  name: string;
  kind: 'builtin' | 'user';
  builtin_key: string | null;
  prompt: string | null;
  cron: string;
  schedule_text: string | null;
  enabled: number;
  next_run_at: number | null;
  last_run_at: number | null;
}

const toJob = (r: Row): Job => ({
  id: r.id,
  name: r.name,
  kind: r.kind,
  builtinKey: r.builtin_key,
  prompt: r.prompt,
  cron: r.cron,
  scheduleText: r.schedule_text,
  enabled: !!r.enabled,
  nextRunAt: r.next_run_at ? isoLocal(r.next_run_at) : null,
  lastRunAt: r.last_run_at ? isoLocal(r.last_run_at) : null,
});

export interface JobRun {
  id: string;
  jobId: string;
  startedAt: string;
  finishedAt: string | null;
  status: 'running' | 'ok' | 'error' | 'nothing';
  output: string | null;
}

/** SQLite-backed jobs. `tick()` is called every 30 s by main.ts (and directly by tests with a fake clock). */
export class Scheduler {
  private running = new Set<string>();
  private lastMaintenance = 0;
  private timer?: ReturnType<typeof setInterval>;
  constructor(private app: App) {}

  start(intervalMs = 30_000): void {
    this.timer = setInterval(
      () =>
        void this.tick().catch((e) =>
          this.app.log.error('tick failed', String(e)),
        ),
      intervalMs,
    );
    this.timer.unref?.();
  }
  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  /** Insert missing built-in jobs. Existing ones (maybe edited) are left alone. */
  seedBuiltins(): void {
    for (const b of builtinJobs) {
      if (this.app.db.get('SELECT 1 AS x FROM jobs WHERE builtin_key=?', b.key))
        continue;
      const now = this.app.clock.now();
      this.app.db.run(
        `INSERT INTO jobs(id,name,kind,builtin_key,cron,schedule_text,enabled,next_run_at,created_at) VALUES(?,?, 'builtin', ?,?,?,1,?,?)`,
        newId('job_'),
        b.name,
        b.key,
        b.cron,
        b.scheduleText,
        nextRun(b.cron, now),
        now,
      );
    }
  }

  list(): Job[] {
    return this.app.db
      .all<Row>('SELECT * FROM jobs ORDER BY kind DESC, created_at, rowid')
      .map(toJob);
  }
  get(id: string): Job | undefined {
    const r = this.app.db.get<Row>('SELECT * FROM jobs WHERE id=?', id);
    return r ? toJob(r) : undefined;
  }

  create(input: {
    name: string;
    prompt: string;
    schedule: string;
    enabled?: boolean;
    id?: string;
  }): Job {
    const s = resolveSchedule(input.schedule);
    const id = input.id ?? newId('job_');
    const now = this.app.clock.now();
    this.app.db.run(
      `INSERT INTO jobs(id,name,kind,prompt,cron,schedule_text,enabled,next_run_at,created_at) VALUES(?,?, 'user', ?,?,?,?,?,?)`,
      id,
      input.name,
      input.prompt,
      s.cron,
      s.text,
      input.enabled === false ? 0 : 1,
      nextRun(s.cron, now),
      now,
    );
    return this.get(id)!;
  }

  update(
    id: string,
    patch: {
      name?: string;
      prompt?: string;
      schedule?: string;
      enabled?: boolean;
    },
  ): Job | undefined {
    const cur = this.get(id);
    if (!cur) return undefined;
    if (patch.name !== undefined)
      this.app.db.run('UPDATE jobs SET name=? WHERE id=?', patch.name, id);
    if (patch.prompt !== undefined && cur.kind === 'user')
      this.app.db.run('UPDATE jobs SET prompt=? WHERE id=?', patch.prompt, id);
    if (patch.enabled !== undefined)
      this.app.db.run(
        'UPDATE jobs SET enabled=? WHERE id=?',
        patch.enabled ? 1 : 0,
        id,
      );
    if (patch.schedule !== undefined) {
      const s = resolveSchedule(patch.schedule);
      this.app.db.run(
        'UPDATE jobs SET cron=?, schedule_text=?, next_run_at=? WHERE id=?',
        s.cron,
        s.text,
        nextRun(s.cron, this.app.clock.now()),
        id,
      );
    }
    return this.get(id);
  }

  delete(id: string): Job | undefined {
    const cur = this.get(id);
    if (!cur) return undefined;
    if (cur.kind === 'builtin')
      throw new Error('Built-in jobs cannot be deleted. Disable them instead.');
    this.app.db.run('DELETE FROM jobs WHERE id=?', id);
    this.app.db.run('DELETE FROM job_runs WHERE job_id=?', id);
    return cur;
  }

  history(jobId?: string, limit = 30): JobRun[] {
    const rows = this.app.db.all<{
      id: string;
      job_id: string;
      started_at: number;
      finished_at: number | null;
      status: JobRun['status'];
      output: string | null;
    }>(
      `SELECT * FROM job_runs WHERE (? IS NULL OR job_id=?) ORDER BY started_at DESC, rowid DESC LIMIT ?`,
      jobId ?? null,
      jobId ?? null,
      limit,
    );
    return rows.map((r) => ({
      id: r.id,
      jobId: r.job_id,
      startedAt: isoLocal(r.started_at),
      finishedAt: r.finished_at ? isoLocal(r.finished_at) : null,
      status: r.status,
      output: r.output,
    }));
  }

  /** Run a job now (also used by the scheduler). Overlapping runs of the same job are skipped. */
  async runNow(id: string): Promise<JobRun> {
    const job = this.get(id);
    if (!job) throw new Error('No such job.');
    if (this.running.has(id)) throw new Error('This job is already running.');
    this.running.add(id);
    const runId = newId('run_');
    const started = this.app.clock.now();
    this.app.db.run(
      "INSERT INTO job_runs(id,job_id,started_at,status) VALUES(?,?,?, 'running')",
      runId,
      id,
      started,
    );
    let status: JobRun['status'] = 'ok';
    let output = '';
    try {
      if (job.kind === 'builtin') {
        const b = builtinJobs.find((x) => x.key === job.builtinKey);
        output = b ? await b.run(this.app) : 'Unknown built-in job.';
      } else {
        const r = await runJobPrompt(this.app, job.prompt ?? '');
        output = r.text;
        if (r.nothing) status = 'nothing';
      }
    } catch (e) {
      status = 'error';
      output = e instanceof Error ? e.message : String(e);
    } finally {
      this.running.delete(id);
    }
    const now = this.app.clock.now();
    this.app.db.run(
      'UPDATE job_runs SET finished_at=?, status=?, output=? WHERE id=?',
      now,
      status,
      clip(output, 4000),
      runId,
    );
    this.app.db.run(
      'UPDATE jobs SET last_run_at=?, next_run_at=? WHERE id=?',
      started,
      nextRun(job.cron, now),
      id,
    );
    return this.history(id, 1)[0]!;
  }

  /** Run everything that is due, expire inbox items, maintain conversations (hourly-ish). */
  async tick(): Promise<void> {
    const now = this.app.clock.now();
    this.app.inbox.sweepExpired();
    const due = this.app.db.all<{ id: string }>(
      'SELECT id FROM jobs WHERE enabled=1 AND next_run_at IS NOT NULL AND next_run_at <= ?',
      now,
    );
    for (const d of due) {
      // push next_run_at forward first so a slow job is not re-picked
      const job = this.get(d.id)!;
      this.app.db.run(
        'UPDATE jobs SET next_run_at=? WHERE id=?',
        nextRun(job.cron, now),
        d.id,
      );
      await this.runNow(d.id).catch((e) =>
        this.app.log.warn('job failed to start', String(e)),
      );
    }
    if (now - this.lastMaintenance >= MIN) {
      this.lastMaintenance = now;
      await this.app.conversations.maintain();
    }
  }
}
