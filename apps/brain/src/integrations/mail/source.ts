import type { App } from '../../app.ts';
import {
  accountsFor,
  errText,
  noteAccountError,
  touchSync,
} from '../accounts.ts';
import type {
  AccountRow,
  ActionOutcome,
  MailFull,
  MailMessage,
  MailSource,
} from '../index.ts';
import { gmailBackend } from './gmail.ts';
import { imapBackend } from './imap.ts';

export interface ReplyArgs {
  body: string;
  to?: string;
  subject?: string;
}

/** One mail service of one account. Message ids it returns are `<accountId>:<native id>`. */
export interface MailBackend {
  unread(since: number): Promise<MailMessage[]>;
  search(query: string, limit: number): Promise<MailMessage[]>;
  read(nativeId: string): Promise<MailFull>;
  reply(
    nativeId: string,
    a: ReplyArgs,
  ): Promise<{ to: string; subject: string }>;
}

export type MailBackendFactory = (app: App, acc: AccountRow) => MailBackend;
export const defaultMailBackend: MailBackendFactory = (app, acc) =>
  acc.kind === 'google' ? gmailBackend(app, acc) : imapBackend(app, acc);

/** The account's own addresses, lower case: its email and a username that is one. */
export function ownAddresses(acc: AccountRow): Set<string> {
  return new Set(
    [acc.config.email, acc.config.username]
      .filter((x): x is string => typeof x === 'string' && x.includes('@'))
      .map((x) => x.trim().toLowerCase()),
  );
}

/** "Jan <jan@x.de>" → "jan@x.de". */
export const addressOf = (from: string): string =>
  (/<([^>]+)>/.exec(from)?.[1] ?? from).trim().toLowerCase();

export class MergedMail implements MailSource {
  constructor(
    private app: App,
    private backend: MailBackendFactory = defaultMailBackend,
  ) {}

  private async each<T>(
    f: (acc: AccountRow, b: MailBackend) => Promise<T[]>,
  ): Promise<T[]> {
    const out: T[] = [];
    const errors: string[] = [];
    let ok = 0;
    for (const acc of accountsFor(this.app, 'mail')) {
      try {
        out.push(...(await f(acc, this.backend(this.app, acc))));
        touchSync(this.app, acc.id);
        ok++;
      } catch (e) {
        noteAccountError(this.app, acc.id, e);
        errors.push(`${acc.label}: ${errText(e)}`);
      }
    }
    if (errors.length && !ok) throw new Error(errors.join('; '));
    if (errors.length)
      this.app.log.warn('mail partly failed', errors.join('; '));
    return out;
  }

  /** New mail from others: what you sent yourself (Sent, replies to all, a copy to you) is left out. */
  async unread(since: number): Promise<MailMessage[]> {
    return (
      await this.each(async (acc, b) => {
        const own = ownAddresses(acc);
        return (await b.unread(since)).filter(
          (m) => !own.has(addressOf(m.from)),
        );
      })
    ).sort((x, y) => y.receivedAt - x.receivedAt);
  }

  async search(query: string, limit = 10): Promise<MailMessage[]> {
    return (await this.each((_a, b) => b.search(query, limit)))
      .sort((x, y) => y.receivedAt - x.receivedAt)
      .slice(0, limit);
  }

  private locate(id: string): { acc: AccountRow; native: string } {
    const i = id.indexOf(':');
    const acc = accountsFor(this.app, 'mail').find(
      (a) => a.id === id.slice(0, i),
    );
    if (i < 0 || !acc)
      throw new Error('Unknown mail id (use an id from mail_search).');
    return { acc, native: id.slice(i + 1) };
  }

  async read(id: string): Promise<MailFull> {
    const { acc, native } = this.locate(id);
    const m = await this.backend(this.app, acc).read(native);
    touchSync(this.app, acc.id);
    return m;
  }

  async sendReply(args: Record<string, unknown>): Promise<ActionOutcome> {
    const body = String(args.body ?? '').trim();
    if (!body) return { ok: false, text: 'The reply is empty.' };
    try {
      const { acc, native } = this.locate(String(args.mailId ?? ''));
      const r = await this.backend(this.app, acc).reply(native, {
        body,
        ...(typeof args.to === 'string' ? { to: args.to } : {}),
        ...(typeof args.subject === 'string' ? { subject: args.subject } : {}),
      });
      touchSync(this.app, acc.id);
      return { ok: true, text: `Reply sent to ${r.to}.` };
    } catch (e) {
      return { ok: false, text: `Could not send the reply: ${errText(e)}` };
    }
  }
}
