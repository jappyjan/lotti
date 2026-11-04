import type { App } from './app.ts';
import { decrypt, encrypt } from './util/crypto.ts';

/** Encrypted key/value store. Values can be written and used server-side, never read via an op. */
export class SecretsStore {
  constructor(private app: App) {}
  set(name: string, value: string): void {
    this.app.db.run(
      `INSERT INTO secrets(name, value, updated_at) VALUES(?,?,?)
       ON CONFLICT(name) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
      name,
      encrypt(this.app.key, value),
      this.app.clock.now(),
    );
  }
  /** Server-side use only. Not exposed through any op or tool. */
  get(name: string): string | undefined {
    const r = this.app.db.get<{ value: string }>(
      'SELECT value FROM secrets WHERE name=?',
      name,
    );
    return r ? decrypt(this.app.key, r.value) : undefined;
  }
  has(name: string): boolean {
    return !!this.app.db.get('SELECT 1 AS x FROM secrets WHERE name=?', name);
  }
  delete(name: string): boolean {
    return (
      this.app.db.run('DELETE FROM secrets WHERE name=?', name).changes > 0
    );
  }
  /** Names and status only. */
  list(prefix = ''): { name: string; updatedAt: number }[] {
    return this.app.db
      .all<{ name: string; updated_at: number }>(
        'SELECT name, updated_at FROM secrets WHERE name LIKE ? ORDER BY name',
        prefix + '%',
      )
      .map((r) => ({ name: r.name, updatedAt: r.updated_at }));
  }
}
