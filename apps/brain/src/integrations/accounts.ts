import type { App } from '../app.ts';
import { accountRow } from '../ops/integration-ops.ts';
import type { AccountRow } from './index.ts';

export type Service = 'calendar' | 'mail';

const DEFAULT_SERVICES: Record<string, Service[]> = {
  google: ['calendar', 'mail'],
  icloud: ['calendar', 'mail'],
  caldav: ['calendar'],
  imap: ['mail'],
};

/** Accounts that provide a service (config.calendar / config.mail override the per-kind default; config.enabled=false switches off). */
export function accountsFor(app: App, service: Service): AccountRow[] {
  return app.db
    .all<{ id: string }>('SELECT id FROM accounts ORDER BY created_at')
    .map((r) => accountRow(app, r.id)!)
    .filter((a) => {
      if (a.config.enabled === false) return false;
      const v = a.config[service];
      return typeof v === 'boolean'
        ? v
        : (DEFAULT_SERVICES[a.kind] ?? []).includes(service);
    });
}

export function touchSync(app: App, accountId: string): void {
  app.db.run(
    "UPDATE accounts SET last_sync_at=?, status='ok', last_error=NULL WHERE id=?",
    app.clock.now(),
    accountId,
  );
}

export function noteAccountError(
  app: App,
  accountId: string,
  e: unknown,
): void {
  app.db.run(
    "UPDATE accounts SET status='error', last_error=? WHERE id=?",
    e instanceof Error ? e.message : String(e),
    accountId,
  );
}

export const strList = (v: unknown): string[] =>
  Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [];

export const errText = (e: unknown): string =>
  e instanceof Error ? e.message : String(e);
