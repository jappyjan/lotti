import { ImapFlow } from 'imapflow';
import { simpleParser } from 'mailparser';
import nodemailer from 'nodemailer';
import type { App } from '../../app.ts';
import { mailText } from '../../util/text.ts';
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
  list(o?: {
    statusQuery?: { unseen?: boolean };
  }): Promise<(ListedBox & { status?: { unseen?: number } })[]>;
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

/** How much of each message a list fetch reads: headers alone can take 10 KB, HTML mail much more. */
const LIST_FETCH_BYTES = 64_000;

async function textOf(
  source: Buffer | undefined,
): Promise<{ snippet: string; text: string }> {
  if (!source) return { snippet: '', text: '' };
  try {
    const p = await simpleParser(source);
    const text = mailText(p.text, typeof p.html === 'string' ? p.html : '');
    return {
      snippet: text.replace(/\s+/g, ' ').slice(0, 240),
      text: text.slice(0, 4000),
    };
  } catch {
    return { snippet: '', text: '' };
  }
}

const EXCLUDED_SPECIAL_USE = [
  '\\Trash',
  '\\Junk',
  '\\Drafts',
  '\\All',
  '\\Flagged',
  '\\Important',
];
const SPECIAL_USE = [...EXCLUDED_SPECIAL_USE, '\\Sent', '\\Archive'];

type ListedBox = {
  path: string;
  delimiter?: string;
  flags?: Set<string>;
  specialUse?: string;
};

/**
 * "All folders" leaves out what is noise or a duplicate: Trash, Spam, Drafts, the "All Mail" /
 * Flagged / Important virtual folders and anything not selectable. Sent and Archive stay.
 */
export function isExcludedMailbox(b: ListedBox): boolean {
  if (b.flags?.has('\\Noselect') || b.flags?.has('\\NonExistent')) return true;
  // imapflow reports only some SPECIAL-USE attributes as `specialUse` (not \Important), so look at the flags too.
  const special = new Set(
    [b.specialUse, ...(b.flags ?? [])].filter((x): x is string => !!x),
  );
  if (EXCLUDED_SPECIAL_USE.some((u) => special.has(u))) return true;
  if (b.specialUse || SPECIAL_USE.some((u) => special.has(u))) return false;
  // Servers without SPECIAL-USE: fall back to the usual names.
  return /(^|[/.])(trash|bin|deleted( (items|messages))?|spam|junk( e-?mail)?|drafts?|papierkorb|entw(ü|ue)rfe|all mail|alle nachrichten|starred|important)$/i.test(
    b.path,
  );
}

/** isExcludedMailbox, plus what sits inside an excluded folder ("Trash/Old", "INBOX.Junk.2024"). */
export function excludedMailboxes(list: ListedBox[]): Set<string> {
  const out = new Set(list.filter(isExcludedMailbox).map((b) => b.path));
  // A \Noselect parent ("[Gmail]") only groups folders: what is inside it still counts on its own.
  const parents = list
    .filter(
      (b) =>
        out.has(b.path) &&
        !b.flags?.has('\\Noselect') &&
        !b.flags?.has('\\NonExistent'),
    )
    .map((b) => b.path + (b.delimiter ?? '/'));
  for (const b of list)
    if (parents.some((p) => b.path.startsWith(p))) out.add(b.path);
  return out;
}

export function imapBackend(
  app: App,
  acc: AccountRow,
  deps: ImapDeps = realImapDeps,
): MailBackend {
  const allFolders = () => acc.config.allMailboxes === true;
  /** With `unseenOnly`, "All folders" skips folders the server says have no unseen mail (one LIST-STATUS). */
  const boxes = async (c: ImapLike, unseenOnly = false): Promise<string[]> => {
    // "All folders" is evaluated per run, so new folders are picked up on their own.
    if (allFolders()) {
      const list = await c.list(
        unseenOnly ? { statusQuery: { unseen: true } } : undefined,
      );
      const excluded = excludedMailboxes(list);
      return list
        .filter((b) => !excluded.has(b.path))
        .filter((b) => !unseenOnly || b.status?.unseen !== 0)
        .map((b) => b.path);
    }
    return strList(acc.config.mailboxes).length
      ? strList(acc.config.mailboxes)
      : ['INBOX'];
  };
  const settings = () => imapSettings(app, acc);

  const fetchSome = async (
    c: ImapLike,
    box: string,
    uids: number[],
  ): Promise<(MailMessage & { messageId?: string })[]> => {
    const out: (MailMessage & { messageId?: string })[] = [];
    if (!uids.length) return out;
    for await (const m of c.fetch(
      uids.join(','),
      {
        uid: true,
        envelope: true,
        internalDate: true,
        flags: true,
        source: { start: 0, maxLength: LIST_FETCH_BYTES },
      },
      { uid: true },
    )) {
      out.push({
        id: `${acc.id}:${m.uid}:${box}`,
        from: fmtAddr(m.envelope?.from?.[0]),
        subject: String(m.envelope?.subject ?? ''),
        ...(await textOf(m.source)),
        receivedAt: new Date(m.internalDate ?? m.envelope?.date ?? 0).getTime(),
        unread: !m.flags?.has?.('\\Seen'),
        ...(m.envelope?.messageId
          ? { messageId: String(m.envelope.messageId) }
          : {}),
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
      const all: (MailMessage & { messageId?: string })[] = [];
      const list = await boxes(c, query.seen === false);
      let failed = 0;
      for (const box of list) {
        try {
          all.push(
            ...(await inMailbox(c, box, async () => {
              const uids = ((await c.search(query, { uid: true })) || []).slice(
                -limit,
              );
              return fetchSome(c, box, uids);
            })),
          );
        } catch (e) {
          // A folder you chose must work; one of "All folders" that can't be opened is skipped.
          // When none worked it's the connection, not a folder: that is an account error, not "no mail".
          if (!allFolders() || ++failed === list.length) throw e;
          app.log.warn(`mail: skipped folder ${box}`, String(e));
        }
      }
      // The same mail in several folders (Gmail labels over IMAP) counts once.
      const seen = new Set<string>();
      return all
        .filter((m) => minTime === undefined || m.receivedAt >= minTime)
        .sort((a, b) => b.receivedAt - a.receivedAt)
        .filter((m) =>
          !m.messageId
            ? true
            : seen.has(m.messageId)
              ? false
              : (seen.add(m.messageId), true),
        )
        .slice(0, limit)
        .map(({ messageId: _, ...m }) => m);
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
        body: mailText(
          parsed.text,
          typeof parsed.html === 'string' ? parsed.html : '',
        ),
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
  return withClient(deps, imapSettings(app, acc), async (c) => {
    const list = await c.list();
    const excluded = excludedMailboxes(list);
    return list.map((b) => ({
      id: b.path,
      name: b.path,
      excluded: excluded.has(b.path),
    }));
  });
}
