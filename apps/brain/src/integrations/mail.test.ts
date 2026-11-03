import assert from 'node:assert/strict';
import { test } from 'node:test';
import { makeApp } from '../testing/helpers.ts';
import { newRun } from '../tools/registry.ts';
import { builtinJobs } from '../scheduler/builtin.ts';
import { text } from '../testing/helpers.ts';
import { imapBackend, type ImapDeps, type ImapLike } from './mail/imap.ts';
import { MergedMail } from './mail/source.ts';
import { connectorDeps, makeConnector } from './connectors.ts';
import { registerIntegrations } from './register.ts';
import { connectGoogle, googleApp } from './testing.ts';

const b64u = (s: string) => Buffer.from(s).toString('base64url');
const gmsg = (
  id: string,
  subject: string,
  from: string,
  at: number,
  unread = true,
) => ({
  id,
  threadId: 't' + id,
  snippet: 'Snippet ' + subject,
  internalDate: String(at),
  labelIds: unread ? ['INBOX', 'UNREAD'] : ['INBOX'],
  payload: {
    headers: [
      { name: 'From', value: from },
      { name: 'Subject', value: subject },
      { name: 'To', value: 'jan@gmail.com' },
      { name: 'Message-ID', value: `<${id}@x>` },
    ],
    mimeType: 'multipart/alternative',
    parts: [
      {
        mimeType: 'text/plain',
        body: { data: b64u('Hallo Jan,\nbitte antworte bis Freitag.') },
      },
      { mimeType: 'text/html', body: { data: b64u('<p>Hallo</p>') } },
    ],
  },
});

function gmailApp() {
  const now = new Date(2026, 10, 3, 7, 55).getTime();
  return googleApp([
    {
      m: 'GET',
      u: /gmail\/v1\/users\/me\/messages\?/,
      res: (r) =>
        r.url.includes('is%3Aunread') ||
        r.url.includes('q=from') ||
        r.url.includes('q=in')
          ? { messages: [{ id: 'm1' }, { id: 'm2' }] }
          : { messages: [] },
    },
    {
      m: 'GET',
      u: /messages\/m1\?/,
      res: () => gmsg('m1', 'Rechnung fällig', 'Anna <anna@x.de>', now),
    },
    {
      m: 'GET',
      u: /messages\/m2\?/,
      res: () => gmsg('m2', 'Newsletter', 'news@shop.de', now - 1000, false),
    },
    { m: 'POST', u: '/messages/send', res: () => ({ id: 'sent1' }) },
  ]);
}

test('gmail: search, read, unread filter, tools', async () => {
  const { t, m } = gmailApp();
  const acc = await connectGoogle(t);
  const mail = t.app.integrations.mail!;
  const r = await mail.search!('from:anna', 5);
  assert.equal(r.length, 2);
  assert.equal(r[0]!.id, `${acc}:m1`);
  assert.equal(r[0]!.subject, 'Rechnung fällig');
  assert.equal(r[0]!.unread, true);
  assert.match(
    m.seen.find((s) => s.url.includes('q=from'))!.url,
    /q=from%3Aanna/,
  );
  const un = await mail.unread(t.clock.now() - 600_000);
  assert.ok(un.length >= 1);
  assert.match(
    m.seen.filter((s) => s.url.includes('is%3Aunread')).at(-1)!.url,
    /after%3A\d{10}/,
  );
  const full = await mail.read!(`${acc}:m1`);
  assert.match(full.body, /bitte antworte bis Freitag/);
  const run = newRun();
  assert.match(
    (
      await t.app.tools.call(
        'mail_search',
        { query: 'from:anna' },
        { app: t.app, run },
      )
    ).text,
    /id=.*m1 .*Rechnung/,
  );
  assert.match(
    (
      await t.app.tools.call(
        'mail_read',
        { id: `${acc}:m1` },
        { app: t.app, run },
      )
    ).text,
    /Subject: Rechnung fällig/,
  );
  assert.equal(
    (await t.app.tools.call('mail_read', { id: 'nope:1' }, { app: t.app, run }))
      .ok,
    false,
  );
});

test('gmail: send_mail_reply sends only after perform, threaded', async () => {
  const { t, m } = gmailApp();
  const acc = await connectGoogle(t);
  const run = newRun();
  await t.app.tools.call(
    'send_mail_reply',
    { mailId: `${acc}:m1`, body: 'Mach ich, danke!' },
    { app: t.app, run },
  );
  assert.ok(!m.seen.some((s) => s.url.endsWith('/messages/send')));
  const o = await t.app.actions.perform(run.actions[0]!.id);
  assert.ok(o.ok, o.text);
  const send = m.seen.find((s) => s.url.endsWith('/messages/send'))!;
  const body = JSON.parse(send.body);
  assert.equal(body.threadId, 'tm1');
  const raw = Buffer.from(body.raw, 'base64url').toString();
  assert.match(raw, /To: Anna <anna@x.de>/);
  assert.match(raw, /Subject: =\?UTF-8\?Q\?Re=3A_Rechnung/);
  assert.match(raw, /In-Reply-To: <m1@x>/);
  assert.match(raw, /Mach ich, danke!/);
});

// ---- IMAP with a fake server ----------------------------------------------------------------------------

const rfc = (subject: string, from: string, body: string) =>
  Buffer.from(
    `From: ${from}\r\nTo: jan@icloud.com\r\nSubject: ${subject}\r\nMessage-ID: <orig@x>\r\nDate: Tue, 03 Nov 2026 07:50:00 +0100\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${body}\r\n`,
  );

function fakeImap() {
  const log: string[] = [];
  const sent: any[] = [];
  const boxes: Record<
    string,
    { uid: number; seen: boolean; src: Buffer; at: number }[]
  > = {
    INBOX: [
      {
        uid: 1,
        seen: true,
        src: rfc('Alt', 'old@x.de', 'old'),
        at: new Date(2026, 10, 1).getTime(),
      },
      {
        uid: 2,
        seen: false,
        src: rfc(
          'Termin morgen',
          'Chef <chef@firma.de>',
          'Können wir morgen um 10 Uhr?',
        ),
        at: new Date(2026, 10, 3, 7, 50).getTime(),
      },
    ],
    Archive: [
      {
        uid: 7,
        seen: false,
        src: rfc('Archiv', 'a@x.de', 'archiv'),
        at: new Date(2026, 10, 3, 7, 51).getTime(),
      },
    ],
  };
  let open = 'INBOX';
  const client: ImapLike = {
    async connect() {
      log.push('connect');
    },
    async logout() {
      log.push('logout');
    },
    async getMailboxLock(p) {
      open = p;
      log.push('lock ' + p);
      return {
        release() {
          log.push('release');
        },
      };
    },
    async search(q) {
      log.push('search ' + JSON.stringify(q));
      return boxes[open]!.filter((m) =>
        q.seen === false ? !m.seen : true,
      ).map((m) => m.uid);
    },
    async *fetch(range: string) {
      const uids = range.split(',').map(Number);
      for (const m of boxes[open]!.filter((x) => uids.includes(x.uid)))
        yield {
          uid: m.uid,
          envelope: {
            from: [{ name: 'X', address: 'x@y' }],
            subject: /Subject: (.*)\r/.exec(m.src.toString())![1],
          },
          internalDate: new Date(m.at),
          flags: new Set(m.seen ? ['\\Seen'] : []),
          source: m.src,
        };
    },
    async fetchOne(uid) {
      const m = boxes[open]!.find((x) => x.uid === Number(uid))!;
      return {
        uid: m.uid,
        envelope: {
          from: [{ name: 'Chef', address: 'chef@firma.de' }],
          subject: 'Termin morgen',
        },
        internalDate: new Date(m.at),
        source: m.src,
      };
    },
    async list() {
      return [{ path: 'INBOX' }, { path: 'Archive' }];
    },
  };
  const deps: ImapDeps = {
    imap: () => client,
    smtp: (s) => ({
      async sendMail(m) {
        sent.push({ s, m });
      },
    }),
  };
  return { deps, log, sent };
}

async function imapApp(kind = 'icloud') {
  const t = makeApp();
  registerIntegrations(t.app);
  const f = fakeImap();
  connectorDeps.imap = f.deps;
  t.app.integrations.mail = new MergedMail(t.app, (app, acc) =>
    imapBackend(app, acc, f.deps),
  );
  const id = (
    (await t.app.ops.invoke(
      'accounts.add',
      {
        kind,
        label: 'iCloud',
        config: {
          username: 'jan@icloud.com',
          ...(kind === 'imap'
            ? {
                imapHost: 'imap.example.com',
                smtpHost: 'smtp.example.com',
                mail: true,
                calendar: false,
              }
            : { calendar: false }),
        },
      },
      'app',
    )) as any
  ).result.id;
  await t.app.ops.invoke(
    'accounts.set_credential',
    { id, key: 'password', value: 'app-pw' },
    'app',
  );
  return { t, id, ...f };
}

test('imap: unread since, search, read, mailbox selection', async () => {
  const { t, id, log } = await imapApp();
  const mail = t.app.integrations.mail!;
  const un = await mail.unread(new Date(2026, 10, 3, 7, 0).getTime());
  assert.deepEqual(
    un.map((m) => m.subject),
    ['Termin morgen'],
  );
  assert.equal(un[0]!.id, `${id}:2:INBOX`);
  assert.match(un[0]!.snippet, /Können wir morgen/);
  assert.ok(log.includes('logout'));
  const s = await mail.search!('termin', 5);
  assert.ok(s.length >= 1);
  assert.ok(log.some((l) => l.startsWith('search {"text":"termin"')));
  const full = await mail.read!(`${id}:2:INBOX`);
  assert.match(full.body, /morgen um 10 Uhr/);
  assert.equal(full.to, 'jan@icloud.com');

  const mb = (await t.app.ops.invoke(
    'accounts.mailboxes',
    { id },
    'app',
  )) as any;
  assert.deepEqual(mb.result, [
    { id: 'INBOX', name: 'INBOX', selected: true },
    { id: 'Archive', name: 'Archive', selected: false },
  ]);
  await t.app.ops.invoke(
    'accounts.set_mailboxes',
    { id, mailboxes: ['INBOX', 'Archive'] },
    'app',
  );
  const both = await t.app.integrations.mail!.unread(
    new Date(2026, 10, 3, 7, 0).getTime(),
  );
  assert.deepEqual(both.map((m) => m.subject).sort(), [
    'Archiv',
    'Termin morgen',
  ]);
});

test('imap: reply goes out via SMTP (icloud defaults) with threading, only after perform', async () => {
  const { t, id, sent } = await imapApp();
  const run = newRun();
  await t.app.tools.call(
    'send_mail_reply',
    { mailId: `${id}:2:INBOX`, body: 'Ja, passt.' },
    { app: t.app, run },
  );
  assert.equal(sent.length, 0);
  const o = await t.app.actions.perform(run.actions[0]!.id);
  assert.ok(o.ok, o.text);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].s.host, 'smtp.mail.me.com');
  assert.equal(sent[0].s.port, 587);
  assert.equal(sent[0].s.secure, false);
  assert.match(sent[0].m.to, /chef@firma.de/);
  assert.equal(sent[0].m.subject, 'Re: Termin morgen');
  assert.equal(sent[0].m.inReplyTo, '<orig@x>');
});

test('imap: generic account needs host; connector check reports problems', async () => {
  const { t, id } = await imapApp('imap');
  const f = fakeImap();
  const c = makeConnector('imap', { imap: f.deps });
  const acc = ((await t.app.ops.invoke('accounts.list', {}, 'app')) as any)
    .result[0];
  assert.deepEqual(await c.check({ ...acc, id }, t.app), {
    ok: true,
    status: 'ok',
  });
  const bad: ImapDeps = {
    ...f.deps,
    imap: () => ({
      ...f.deps.imap({} as any),
      connect: async () => {
        throw new Error('AUTHENTICATIONFAILED');
      },
    }),
  };
  const r = await makeConnector('imap', {
    calendar: undefined as any,
    imap: bad,
  }).check({ ...acc, id }, t.app);
  assert.equal(r.ok, false);
  assert.match(r.error!, /AUTHENTICATIONFAILED/);
  // no password -> clear message
  t.app.secrets.delete(`account.${id}.password`);
  await assert.rejects(
    t.app.integrations.mail!.search!('x'),
    /IMAP needs host, username and password/,
  );
});

test('important_mail built-in job triages unread mail from the sources', async () => {
  const { t, id } = await imapApp();
  t.mock.script(
    text(
      JSON.stringify([
        {
          id: `${id}:2:INBOX`,
          important: true,
          title: 'Chef fragt',
          summary: 'Termin morgen 10 Uhr',
        },
      ]),
    ),
  );
  t.app.settings.kvSet(
    'important_mail.since',
    String(new Date(2026, 10, 3, 7, 0).getTime()),
  );
  const job = builtinJobs.find((j) => j.key === 'important_mail')!;
  assert.match(await job.run(t.app), /1 new mail\(s\), 1 important/);
  const item = t.app.inbox.list().find((i) => i.kind === 'mail')!;
  assert.equal(item.title, 'Chef fragt');
});

test('errText: readable reasons for fetch and IMAP failures', async () => {
  const { errText } = await import('./accounts.ts');
  const refused = Object.assign(new TypeError('fetch failed'), {
    cause: { code: 'ECONNREFUSED' },
  });
  assert.equal(errText(refused), 'Cannot reach the server (ECONNREFUSED).');
  assert.match(
    errText(
      Object.assign(new Error('Command failed'), {
        authenticationFailed: true,
      }),
    ),
    /login failed/,
  );
  assert.match(
    errText(
      Object.assign(new Error('Command failed'), { responseText: 'NO nope' }),
    ),
    /refused.*NO nope/,
  );
  assert.equal(errText(new Error('plain')), 'plain');
});
