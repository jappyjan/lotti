import type { App } from '../app.ts';
import { runJobPrompt } from '../agent/loop.ts';
import { DAY, MIN, isoLocal } from '../util/clock.ts';
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
  /** Shown in the app: what the job does and whether it spends AI tokens. */
  description: string | null;
  ai: 'none' | 'conditional' | 'always';
  aiNote: string;
  /** Built-in jobs with an extra editable setting (key into settings.*). */
  setting: { key: string; label: string; unit: string } | null;
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

const toJob = (r: Row): Job => {
  const b =
    r.kind === 'builtin'
      ? builtinJobs.find((x) => x.key === r.builtin_key)
      : undefined;
  return {
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
  description: b?.description ?? null,
  ai: b?.ai ?? 'always',
  aiNote: b?.aiNote ?? 'Spends AI tokens on every run.',
  setting: b?.setting ?? null,
  };
};

export interface JobRun {
  id: string;
  jobId: string;
  startedAt: string;
  finishedAt: string | null;
  status: 'running' | 'ok' | 'error' | 'nothing';
  output: string | null;
}

/** SQLite-backed jobs. `tick()` is called every 30 s by main.ts (and directly by tests with a fake clock). */
/** Run history kept per job (the meeting-soon check alone runs ~1440 times a day). */
export const RUNS_KEPT_PER_JOB = 50;
/** Logs and handled items older than this are deleted by the daily retention sweep. */
export const RETENTION_DAYS = 30;

export class Scheduler {
  private running = new Set<string>();
  private ticking = false;
  private lastMaintenance = 0;
  private lastRetention = 0;
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

  /** Successful user-job runs with output since `since` (for the catch-up brief), newest first. */
  recentUserRuns(
    since: number,
    limit = 10,
  ): { name: string; output: string; startedAt: number }[] {
    return this.app.db
      .all<{ name: string; output: string; started_at: number }>(
        `SELECT j.name, r.output, r.started_at FROM job_runs r JOIN jobs j ON j.id = r.job_id
         WHERE j.kind='user' AND r.status='ok' AND r.output IS NOT NULL AND r.output != '' AND r.started_at > ?
         ORDER BY r.started_at DESC LIMIT ?`,
        since,
        limit,
      )
      .map((r) => ({
        name: r.name,
        output: r.output,
        startedAt: r.started_at,
      }));
  }

  /** Delete old logs and handled items (daily). */
  sweepRetention(): void {
    const cut = this.app.clock.now() - RETENTION_DAYS * DAY;
    const db = this.app.db;
    db.run('DELETE FROM shell_log WHERE at < ?', cut);
    db.run('DELETE FROM location_log WHERE at < ?', cut);
    db.run('DELETE FROM actions WHERE created_at < ?', cut);
    db.run('DELETE FROM undos WHERE created_at < ?', cut);
    db.run(
      "DELETE FROM inbox WHERE status IN ('dismissed','expired') AND updated_at < ?",
      cut,
    );
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
    this.app.db.run(
      `DELETE FROM job_runs WHERE job_id=? AND id NOT IN
         (SELECT id FROM job_runs WHERE job_id=? ORDER BY started_at DESC, rowid DESC LIMIT ?)`,
      id,
      id,
      RUNS_KEPT_PER_JOB,
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

  /**
   * Run everything that is due, expire inbox items, maintain conversations (every minute), retention (daily).
   * A tick that starts while the previous one still runs is skipped (a slow job must not run twice).
   */
  async tick(): Promise<void> {
    if (this.ticking) return;
    this.ticking = true;
    try {
      await this.doTick();
    } finally {
      this.ticking = false;
    }
  }

  private async doTick(): Promise<void> {
    const now = this.app.clock.now();
    this.app.inbox.sweepExpired();
    const due = this.app.db.all<{ id: string }>(
      'SELECT id FROM jobs WHERE enabled=1 AND next_run_at IS NOT NULL AND next_run_at <= ? ORDER BY next_run_at',
      now,
    );
    for (const d of due) {
      // Re-check: an earlier job of this tick may have taken long, and the job may have been run/edited meanwhile.
      const cur = this.app.db.get<Row>('SELECT * FROM jobs WHERE id=?', d.id);
      if (
        !cur?.enabled ||
        cur.next_run_at === null ||
        cur.next_run_at > this.app.clock.now()
      )
        continue;
      // push next_run_at forward first so a slow job is not re-picked
      this.app.db.run(
        'UPDATE jobs SET next_run_at=? WHERE id=?',
        nextRun(cur.cron, this.app.clock.now()),
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
    if (now - this.lastRetention >= DAY) {
      this.lastRetention = now;
      this.sweepRetention();
    }
  }
}
