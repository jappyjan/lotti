import { ImapFlow } from 'imapflow';
import { simpleParser } from 'mailparser';
import nodemailer from 'nodemailer';
import type { App } from '../../app.ts';
import { stripHtml } from '../../util/text.ts';
import { strList } from '../accounts.ts';
import type { AccountRow, MailFull, MailMessage } from '../index.ts';
import { reSubject } from './gmail.ts';
import type { MailBackend, ReplyArgs } from './source.ts';

/** The part of ImapFlow we use (lets tests plug in a fake server). */
export interface ImapLike {
  connect(): Promise<void>;
  logout(): Promise<void>;
  on?(ev: string, f: (...a: any[]) => void): unknown;
  getMailboxLock(path: string): Promise<{ release(): void }>;
  search(
    q: Record<string, unknown>,
    o?: Record<string, unknown>,
  ): Promise<number[] | false>;
  fetch(
    range: any,
    q: Record<string, unknown>,
    o?: Record<string, unknown>,
  ): AsyncIterable<any>;
  fetchOne(
    seq: string,
    q: Record<string, unknown>,
    o?: Record<string, unknown>,
  ): Promise<any>;
  list(): Promise<{ path: string; flags?: Set<string>; specialUse?: string }[]>;
}
export interface SmtpLike {
  sendMail(m: Record<string, unknown>): Promise<unknown>;
}
export interface ImapDeps {
  imap(s: ImapSettings): ImapLike;
  smtp(s: SmtpSettings): SmtpLike;
}
export interface ImapSettings {
  host: string;
  port: number;
  secure: boolean;
  user: string;
  pass: string;
}
export interface SmtpSettings extends ImapSettings {
  from: string;
}

export const realImapDeps: ImapDeps = {
  imap: (s) =>
    new ImapFlow({
      host: s.host,
      port: s.port,
      secure: s.secure,
      auth: { user: s.user, pass: s.pass },
      logger: false,
    }) as unknown as ImapLike,
  smtp: (s) =>
    nodemailer.createTransport({
      host: s.host,
      port: s.port,
      secure: s.secure,
      auth: { user: s.user, pass: s.pass },
    }),
};

export function imapSettings(
  app: App,
  acc: AccountRow,
): ImapSettings & { smtp: SmtpSettings } {
  const c = acc.config;
  const icloud = acc.kind === 'icloud';
  const user = String(c.username ?? '');
  const pass = app.secrets.get(`account.${acc.id}.password`) ?? '';
  const host = String(c.imapHost ?? (icloud ? 'imap.mail.me.com' : ''));
  if (!host || !user || !pass)
    throw new Error(
      'IMAP needs host, username and password (set them in the app).',
    );
  const port = Number(c.imapPort ?? 993);
  const secure =
    c.imapSecure !== undefined ? c.imapSecure === true : port === 993;
  const smtpPort = Number(c.smtpPort ?? (icloud ? 587 : 465));
  return {
    host,
    port,
    secure,
    user,
    pass,
    smtp: {
      host: String(
        c.smtpHost ??
          (icloud ? 'smtp.mail.me.com' : host.replace(/^imap\./, 'smtp.')),
      ),
      port: smtpPort,
      secure:
        c.smtpSecure !== undefined ? c.smtpSecure === true : smtpPort === 465,
      user,
      pass,
      from: String(c.email ?? user),
    },
  };
}

async function withClient<T>(
  deps: ImapDeps,
  s: ImapSettings,
  f: (c: ImapLike) => Promise<T>,
): Promise<T> {
  const c = deps.imap(s);
  c.on?.('error', () => {});
  await c.connect();
  try {
    return await f(c);
  } finally {
    await c.logout().catch(() => {});
  }
}

async function inMailbox<T>(
  c: ImapLike,
  box: string,
  f: () => Promise<T>,
): Promise<T> {
  const lock = await c.getMailboxLock(box);
  try {
    return await f();
  } finally {
    lock.release();
  }
}

const fmtAddr = (a?: { name?: string; address?: string }) =>
  a ? (a.name ? `${a.name} <${a.address}>` : String(a.address ?? '')) : '';

async function snippetOf(source: Buffer | undefined): Promise<string> {
  if (!source) return '';
  try {
    const p = await simpleParser(source);
    return (p.text || stripHtml(typeof p.html === 'string' ? p.html : ''))
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 240);
  } catch {
    return '';
  }
}

export function imapBackend(
  app: App,
  acc: AccountRow,
  deps: ImapDeps = realImapDeps,
): MailBackend {
  const boxes = () =>
    strList(acc.config.mailboxes).length
      ? strList(acc.config.mailboxes)
      : ['INBOX'];
  const settings = () => imapSettings(app, acc);

  const fetchSome = async (
    c: ImapLike,
    box: string,
    uids: number[],
  ): Promise<MailMessage[]> => {
    const out: MailMessage[] = [];
    if (!uids.length) return out;
    for await (const m of c.fetch(
      uids.join(','),
      {
        uid: true,
        envelope: true,
        internalDate: true,
        flags: true,
        source: { start: 0, maxLength: 6000 },
      },
      { uid: true },
    )) {
      out.push({
        id: `${acc.id}:${m.uid}:${box}`,
        from: fmtAddr(m.envelope?.from?.[0]),
        subject: String(m.envelope?.subject ?? ''),
        snippet: await snippetOf(m.source),
        receivedAt: new Date(m.internalDate ?? m.envelope?.date ?? 0).getTime(),
        unread: !m.flags?.has?.('\\Seen'),
      });
    }
    return out;
  };

  const find = (
    query: Record<string, unknown>,
    limit: number,
    minTime?: number,
  ) =>
    withClient(deps, settings(), async (c) => {
      const all: MailMessage[] = [];
      for (const box of boxes()) {
        all.push(
          ...(await inMailbox(c, box, async () => {
            const uids = ((await c.search(query, { uid: true })) || []).slice(
              -limit,
            );
            return fetchSome(c, box, uids);
          })),
        );
      }
      return all
        .filter((m) => minTime === undefined || m.receivedAt >= minTime)
        .sort((a, b) => b.receivedAt - a.receivedAt)
        .slice(0, limit);
    });

  const readRaw = (native: string) => {
    const m = /^(\d+):(.*)$/.exec(native);
    if (!m) throw new Error('Bad mail id.');
    const uid = m[1]!;
    const box = m[2]!;
    return withClient(deps, settings(), (c) =>
      inMailbox(c, box, async () => {
        const r = await c.fetchOne(
          uid,
          { source: true, envelope: true, internalDate: true, flags: true },
          { uid: true },
        );
        if (!r?.source) throw new Error('Mail not found.');
        return { r, parsed: await simpleParser(r.source), box, uid };
      }),
    );
  };

  return {
    unread: (since) =>
      find({ seen: false, since: new Date(since - 86_400_000) }, 25, since),
    search: (q, limit) => find(q ? { text: q } : { all: true }, limit),
    async read(native): Promise<MailFull> {
      const { r, parsed, box, uid } = await readRaw(native);
      return {
        id: `${acc.id}:${uid}:${box}`,
        from: fmtAddr(r.envelope?.from?.[0]),
        to: parsed.to
          ? Array.isArray(parsed.to)
            ? parsed.to.map((t) => t.text).join(', ')
            : parsed.to.text
          : '',
        subject: String(r.envelope?.subject ?? ''),
        snippet: '',
        receivedAt: new Date(r.internalDate ?? 0).getTime(),
        body:
          parsed.text ||
          stripHtml(typeof parsed.html === 'string' ? parsed.html : ''),
      };
    },
    async reply(native, a: ReplyArgs) {
      const { parsed } = await readRaw(native);
      const to = a.to || parsed.replyTo?.text || parsed.from?.text || '';
      if (!to) throw new Error('Could not find a recipient to reply to.');
      const subject = a.subject || reSubject(parsed.subject ?? '');
      const s = settings().smtp;
      await deps.smtp(s).sendMail({
        from: s.from,
        to,
        subject,
        text: a.body,
        ...(parsed.messageId
          ? {
              inReplyTo: parsed.messageId,
              references: [
                ...(Array.isArray(parsed.references)
                  ? parsed.references
                  : parsed.references
                    ? [parsed.references]
                    : []),
                parsed.messageId,
              ].join(' '),
            }
          : {}),
      });
      return { to, subject };
    },
  };
}

/** Mailbox names of an IMAP account (for the app's picker) and a connection test. */
export async function imapMailboxes(
  app: App,
  acc: AccountRow,
  deps: ImapDeps = realImapDeps,
) {
  return withClient(deps, imapSettings(app, acc), async (c) =>
    (await c.list()).map((b) => ({ id: b.path, name: b.path })),
  );
}
