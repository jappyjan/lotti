import assert from 'node:assert/strict';
import { test } from 'node:test';
import { builtinJobs, mailOriginal } from './scheduler/builtin.ts';
import { makeApp, text } from './testing/helpers.ts';
import {
  decodeEntities,
  looksLikeHtml,
  mailGist,
  mailText,
  stripHtml,
} from './util/text.ts';

test('stripHtml: comments, head, and cut-off style blocks or tags leave no markup behind', () => {
  const html =
    '<!DOCTYPE html><html><head><title>Newsletter</title><style>.a{color:red}</style></head>' +
    '<body><!--[if mso]><table><tr><td><![endif]--><p>Hallo&nbsp;Jan,</p><div>Ihr Paket&#8203; kommt&hellip;</div>' +
    '<style>td { padding: 0; } @media (max-width:600px){ .x { display:none';
  assert.equal(stripHtml(html), 'Hallo Jan,\nIhr Paket kommt…');
  assert.equal(stripHtml('<p>Text</p><a href="https://x.de/very'), 'Text');
  assert.equal(stripHtml('a &lt;b&gt; c'), 'a <b> c', 'escaped markup stays text');
});

test('decodeEntities: named, decimal and hex; invisible preview padding is dropped by mailText', () => {
  assert.equal(decodeEntities('It&#39;s &amp; &#x263A; &rsquo; &bogus;'), "It's & ☺ ’ ");
  assert.equal(mailText('Sale‌ ͏‌  now'), 'Sale now');
});

test('mailText: a text part that is really HTML is stripped; real plain text is kept', () => {
  const fake = '<div><p>Ihre Rechnung</p><br><span>39,90 €</span></div>';
  assert.ok(looksLikeHtml(fake));
  assert.equal(mailText(fake, ''), 'Ihre Rechnung\n\n39,90 €');
  assert.ok(!looksLikeHtml('a < b and c > d'));
  assert.equal(mailText('Hallo Jan,\n\n\n\nbis morgen', '<p>x</p>'), 'Hallo Jan,\n\nbis morgen');
  assert.equal(mailText('', '<p>Nur HTML</p>'), 'Nur HTML');
});

test('mailGist: drops quoted replies, tracking links and image placeholders, then clips', () => {
  const t =
    'Kannst du morgen?\n[image: Logo]\nhttps://click.example.com/track/abcdefghijklmnopqrstuvwxyz0123\n> Am Montag schrieb Anna:\n> alt';
  assert.equal(mailGist(t, 100), 'Kannst du morgen?');
  assert.equal(mailGist('x'.repeat(50), 10).length, 10);
});

test('important_mail: the AI sees the cleaned body, user mail notes; items get plain text and a readable original', async () => {
  const t = makeApp({
    integrations: {
      mail: {
        unread: async () => [
          {
            id: 'm1',
            from: 'Anna <anna@x.de>',
            subject: 'Freitag',
            snippet: '<div>Hallo',
            text: 'Hallo Jan,\nhast du Freitag um 19 Uhr Zeit?\n> alter Text',
            receivedAt: 1,
          },
          { id: 'm2', from: 'news@shop.de', subject: 'Sale', snippet: '-20%', receivedAt: 2 },
        ],
      },
    },
  });
  t.app.memory.remember('Mails von LinkedIn sind unwichtig.');
  t.mock.script(
    text(
      '[{"id":"m1","important":true,"title":"<b>Anna</b>: Freitag?","summary":"<p>Fragt, ob du Freitag 19 Uhr Zeit hast.</p>"},{"id":"m2","important":false,"title":"Sale","summary":"-20%"},{"id":"zz","important":true}]',
    ),
  );
  const job = builtinJobs.find((j) => j.key === 'important_mail')!;
  assert.match(await job.run(t.app), /2 new mail\(s\), 1 important/);
  const msgs = t.mock.calls[0]!.messages;
  assert.match(String(msgs[0]!.content), /LinkedIn sind unwichtig/);
  const user = String(msgs[1]!.content);
  assert.match(user, /hast du Freitag um 19 Uhr Zeit/);
  assert.doesNotMatch(user, /alter Text/);
  const items = t.app.inbox.list();
  assert.equal(items.length, 1);
  assert.equal(items[0]!.title, 'Anna : Freitag?');
  assert.equal(items[0]!.summary, 'Fragt, ob du Freitag 19 Uhr Zeit hast.');
  assert.equal(
    items[0]!.body,
    'From: Anna <anna@x.de>\nSubject: Freitag\nHallo Jan,\nhast du Freitag um 19 Uhr Zeit?',
  );
});

test('mailOriginal falls back to the snippet when there is no body text', () => {
  assert.equal(
    mailOriginal({ id: 'a', from: 'b@c', subject: '', snippet: 'Kurz', receivedAt: 0 }),
    'From: b@c\nKurz',
  );
});
