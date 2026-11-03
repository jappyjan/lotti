import nodemailer from 'nodemailer';
import type { App } from '../../app.ts';
import { stripHtml } from '../../util/text.ts';
import { googleFetch } from '../google/oauth.ts';
import type { AccountRow, MailFull, MailMessage } from '../index.ts';
import type { MailBackend, ReplyArgs } from './source.ts';

const G = 'https://gmail.googleapis.com/gmail/v1/users/me';

const header = (m: any, name: string): string =>
  (m.payload?.headers ?? []).find(
    (h: any) => String(h.name).toLowerCase() === name.toLowerCase(),
  )?.value ?? '';

function toMessage(acc: AccountRow, m: any): MailMessage {
  return {
    id: `${acc.id}:${m.id}`,
    from: header(m, 'From'),
    subject: header(m, 'Subject'),
    snippet: String(m.snippet ?? ''),
    receivedAt: Number(m.internalDate ?? 0),
    unread: (m.labelIds ?? []).includes('UNREAD'),
  };
}

function bodyOf(part: any): { plain: string; html: string } {
  const r = { plain: '', html: '' };
  const walk = (p: any) => {
    if (!p) return;
    if (p.body?.data) {
      const t = Buffer.from(p.body.data, 'base64url').toString('utf8');
      if (p.mimeType === 'text/plain') r.plain += t;
      else if (p.mimeType === 'text/html') r.html += t;
    }
    for (const c of p.parts ?? []) walk(c);
  };
  walk(part);
  return r;
}

export function gmailBackend(app: App, acc: AccountRow): MailBackend {
  const list = async (q: string, limit: number): Promise<MailMessage[]> => {
    const j = await googleFetch(
      app,
      acc.id,
      `${G}/messages?${new URLSearchParams({ q, maxResults: String(limit) })}`,
    );
    const out: MailMessage[] = [];
    for (const r of (j.messages ?? []).slice(0, limit)) {
      const m = await googleFetch(
        app,
        acc.id,
        `${G}/messages/${r.id}?format=metadata&metadataHeaders=From&metadataHeaders=Subject`,
      );
      out.push(toMessage(acc, m));
    }
    return out;
  };
  return {
    unread: (since) =>
      list(`is:unread in:inbox after:${Math.floor(since / 1000)}`, 25),
    search: (q, limit) => list(q || 'in:inbox', limit),
    async read(nativeId): Promise<MailFull> {
      const m = await googleFetch(
        app,
        acc.id,
        `${G}/messages/${nativeId}?format=full`,
      );
      const b = bodyOf(m.payload);
      return {
        ...toMessage(acc, m),
        to: header(m, 'To'),
        body: b.plain || stripHtml(b.html) || String(m.snippet ?? ''),
      };
    },
    async reply(nativeId, a: ReplyArgs) {
      const m = await googleFetch(
        app,
        acc.id,
        `${G}/messages/${nativeId}?format=metadata&metadataHeaders=From&metadataHeaders=Reply-To&metadataHeaders=Subject&metadataHeaders=Message-ID&metadataHeaders=References`,
      );
      const to = a.to || header(m, 'Reply-To') || header(m, 'From');
      const subject = a.subject || reSubject(header(m, 'Subject'));
      const msgId = header(m, 'Message-ID');
      const raw = await buildRaw({
        from: String(acc.config.email ?? ''),
        to,
        subject,
        text: a.body,
        ...(msgId
          ? {
              inReplyTo: msgId,
              references: [header(m, 'References'), msgId]
                .filter(Boolean)
                .join(' '),
            }
          : {}),
      });
      await googleFetch(app, acc.id, `${G}/messages/send`, {
        method: 'POST',
        body: { raw: raw.toString('base64url'), threadId: m.threadId },
      });
      return { to, subject };
    },
  };
}

export const reSubject = (s: string) =>
  /^re:/i.test(s) ? s : `Re: ${s}`.trim();

/** Build an RFC 822 message without sending it. */
export async function buildRaw(m: {
  from?: string;
  to: string;
  subject: string;
  text: string;
  inReplyTo?: string;
  references?: string;
}): Promise<Buffer> {
  const t = nodemailer.createTransport({ streamTransport: true, buffer: true });
  const r = await t.sendMail({
    ...(m.from ? { from: m.from } : {}),
    to: m.to,
    subject: m.subject,
    text: m.text,
    ...(m.inReplyTo ? { inReplyTo: m.inReplyTo } : {}),
    ...(m.references ? { references: m.references } : {}),
  });
  return r.message as Buffer;
}
