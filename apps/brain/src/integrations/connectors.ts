import type { App } from '../app.ts';
import { accountsFor, errText, strList, type Service } from './accounts.ts';
import { defaultBackend, type BackendFactory } from './calendar/source.ts';
import { googleFetch } from './google/oauth.ts';
import type { AccountConnector, AccountRow } from './index.ts';
import { imapMailboxes, realImapDeps, type ImapDeps } from './mail/imap.ts';

export interface ConnectorDeps {
  calendar: BackendFactory;
  imap: ImapDeps;
}
/** Live dependencies (tests swap these for fakes). */
export const connectorDeps: ConnectorDeps = {
  calendar: defaultBackend,
  imap: realImapDeps,
};

const has = (app: App, acc: AccountRow, s: Service) =>
  accountsFor(app, s).some((a) => a.id === acc.id);

/** List the calendars of an account (live). */
export async function accountCalendars(
  app: App,
  acc: AccountRow,
  d: ConnectorDeps = connectorDeps,
) {
  const sel = strList(acc.config.calendars);
  return (await d.calendar(app, acc).calendars()).map((c) => ({
    ...c,
    selected: sel.length ? sel.includes(c.id) : true,
  }));
}

/** List the mailboxes of an account (live). Gmail searches all mail, so it has none to choose. */
export async function accountMailboxes(
  app: App,
  acc: AccountRow,
  d: ConnectorDeps = connectorDeps,
) {
  if (acc.kind === 'google') return [];
  const sel = strList(acc.config.mailboxes);
  const all = acc.config.allMailboxes === true;
  return (await imapMailboxes(app, acc, d.imap)).map((b) => ({
    ...b,
    selected: all
      ? !b.excluded
      : sel.length
        ? sel.includes(b.id)
        : b.id.toUpperCase() === 'INBOX',
  }));
}

export function makeConnector(
  kind: string,
  dd: Partial<ConnectorDeps> = {},
): AccountConnector {
  return {
    kind,
    async check(acc, app) {
      const d = { ...connectorDeps, ...dd };
      try {
        const parts: string[] = [];
        if (has(app, acc, 'calendar')) {
          const n = (await d.calendar(app, acc).calendars()).length;
          parts.push(`${n} calendar(s)`);
        }
        if (has(app, acc, 'mail')) {
          if (kind === 'google') {
            await googleFetch(
              app,
              acc.id,
              'https://gmail.googleapis.com/gmail/v1/users/me/profile',
            );
            parts.push('Gmail');
          } else {
            await imapMailboxes(app, acc, d.imap);
            parts.push('IMAP');
          }
        }
        if (!parts.length) {
          return {
            ok: false,
            status: 'error',
            error: 'No service (calendar or mail) is enabled for this account.',
          };
        }
        app.db.run(
          'UPDATE accounts SET last_sync_at=? WHERE id=?',
          app.clock.now(),
          acc.id,
        );
        return { ok: true, status: 'ok' };
      } catch (e) {
        return { ok: false, status: 'error', error: errText(e) };
      }
    },
  };
}

export const connectorKinds = ['google', 'icloud', 'caldav', 'imap'];
