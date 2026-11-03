import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

type Param = string | number | bigint | null | Uint8Array;

/** Thin wrapper over node:sqlite (built in, FTS5 included). */
export class Db {
  readonly raw: DatabaseSync;
  constructor(path: string) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.raw = new DatabaseSync(path);
    this.raw.exec(
      'PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;',
    );
  }
  exec(sql: string): void {
    this.raw.exec(sql);
  }
  all<T = Record<string, unknown>>(sql: string, ...p: Param[]): T[] {
    return this.raw.prepare(sql).all(...p) as T[];
  }
  get<T = Record<string, unknown>>(sql: string, ...p: Param[]): T | undefined {
    return this.raw.prepare(sql).get(...p) as T | undefined;
  }
  run(sql: string, ...p: Param[]): { changes: number } {
    const r = this.raw.prepare(sql).run(...p);
    return { changes: Number(r.changes) };
  }
  tx<T>(fn: () => T): T {
    this.raw.exec('BEGIN');
    try {
      const r = fn();
      this.raw.exec('COMMIT');
      return r;
    } catch (e) {
      this.raw.exec('ROLLBACK');
      throw e;
    }
  }
  close(): void {
    this.raw.close();
  }
}

/** Migrations in code. Append only; each runs once, in order. */
const MIGRATIONS: string[] = [
  /* 1: core */ `
  CREATE TABLE secrets (name TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL);
  CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE devices (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
    apns_token TEXT, created_at INTEGER NOT NULL, last_seen_at INTEGER, revoked_at INTEGER);
  CREATE TABLE admin_tokens (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL, last_used_at INTEGER, revoked_at INTEGER);
  CREATE TABLE pairing_codes (code TEXT PRIMARY KEY, created_at INTEGER NOT NULL, used_at INTEGER);
  CREATE TABLE actions (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, target TEXT NOT NULL, tool TEXT NOT NULL,
    args TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'proposed', created_at INTEGER NOT NULL);
  CREATE TABLE undos (
    id TEXT PRIMARY KEY, label TEXT NOT NULL, op TEXT NOT NULL, input TEXT NOT NULL,
    created_at INTEGER NOT NULL, used_at INTEGER);
  `,
  /* 2: conversations + memory */ `
  CREATE TABLE conversations (
    id TEXT PRIMARY KEY, title TEXT, summary TEXT, status TEXT NOT NULL DEFAULT 'open',
    started_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL, compacted_at INTEGER);
  CREATE TABLE turns (
    id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role TEXT NOT NULL, text TEXT NOT NULL, channel TEXT, at INTEGER NOT NULL);
  CREATE INDEX turns_conv ON turns(conversation_id, id);
  CREATE VIRTUAL TABLE conv_fts USING fts5(title, summary, conversation_id UNINDEXED, tokenize='unicode61 remove_diacritics 2');
  CREATE VIRTUAL TABLE turns_fts USING fts5(text, turn_id UNINDEXED, conversation_id UNINDEXED, tokenize='unicode61 remove_diacritics 2');
  CREATE TABLE memories (
    id TEXT PRIMARY KEY, text TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'fact',
    source_conversation TEXT, created_at INTEGER NOT NULL, last_used_at INTEGER,
    supersedes TEXT, status TEXT NOT NULL DEFAULT 'active');
  CREATE VIRTUAL TABLE memory_fts USING fts5(text, memory_id UNINDEXED, tokenize='unicode61 remove_diacritics 2');
  CREATE TABLE dream_reports (id TEXT PRIMARY KEY, at INTEGER NOT NULL, report TEXT NOT NULL, stats TEXT NOT NULL);
  `,
  /* 3: skills, shell, privacy */ `
  CREATE TABLE usage (kind TEXT NOT NULL, name TEXT NOT NULL, last_used_at INTEGER, count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind, name));
  CREATE TABLE shell_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, command TEXT NOT NULL, exit_code INTEGER,
    duration_ms INTEGER, timed_out INTEGER NOT NULL DEFAULT 0, truncated INTEGER NOT NULL DEFAULT 0, output TEXT);
  CREATE TABLE location_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, call_id TEXT NOT NULL, source TEXT NOT NULL,
    ask_id TEXT, ok INTEGER, detail TEXT);
  `,
  /* 4: jobs, inbox, catchup, presence, integrations config */ `
  CREATE TABLE jobs (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, builtin_key TEXT UNIQUE, prompt TEXT,
    cron TEXT NOT NULL, schedule_text TEXT, enabled INTEGER NOT NULL DEFAULT 1,
    next_run_at INTEGER, last_run_at INTEGER, created_at INTEGER NOT NULL);
  CREATE TABLE job_runs (
    id TEXT PRIMARY KEY, job_id TEXT NOT NULL, started_at INTEGER NOT NULL, finished_at INTEGER,
    status TEXT NOT NULL, output TEXT);
  CREATE INDEX job_runs_job ON job_runs(job_id, started_at);
  CREATE TABLE inbox (
    id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '',
    body TEXT NOT NULL DEFAULT '', source_ref TEXT, created_at INTEGER NOT NULL, expires_at INTEGER,
    status TEXT NOT NULL DEFAULT 'pending', updated_at INTEGER NOT NULL);
  CREATE TABLE push_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, item_id TEXT NOT NULL, created_at INTEGER NOT NULL);
  CREATE TABLE presence_events (id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, at INTEGER NOT NULL, detail TEXT);
  CREATE TABLE briefs (id TEXT PRIMARY KEY, text TEXT NOT NULL, reason TEXT, at INTEGER NOT NULL);
  CREATE TABLE accounts (
    id TEXT PRIMARY KEY, kind TEXT NOT NULL, label TEXT NOT NULL, config TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'not_connected', last_error TEXT, created_at INTEGER NOT NULL);
  CREATE TABLE mcp_servers (
    id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, transport TEXT NOT NULL, url TEXT, command TEXT,
    args TEXT NOT NULL DEFAULT '[]', enabled INTEGER NOT NULL DEFAULT 1,
    tool_flags TEXT NOT NULL DEFAULT '{}', status TEXT, last_error TEXT, created_at INTEGER NOT NULL);
  `,
  /* 5: account sync marker */ `
  ALTER TABLE accounts ADD COLUMN last_sync_at INTEGER;
  `,
  /* 6: actions an inbox item offers (JSON array of proposed actions) */ `
  ALTER TABLE inbox ADD COLUMN actions TEXT;
  `,
];

export function migrate(db: Db): void {
  db.exec(
    'CREATE TABLE IF NOT EXISTS migrations (version INTEGER PRIMARY KEY, at INTEGER NOT NULL)',
  );
  const done =
    db.get<{ v: number | null }>('SELECT MAX(version) AS v FROM migrations')
      ?.v ?? 0;
  for (let i = done; i < MIGRATIONS.length; i++) {
    db.tx(() => {
      db.exec(MIGRATIONS[i]!);
      db.run(
        'INSERT INTO migrations(version, at) VALUES(?, ?)',
        i + 1,
        Date.now(),
      );
    });
  }
}
