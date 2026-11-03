import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MIN } from './util/clock.ts';
import { makeApp, text } from './testing/helpers.ts';

async function chat(
  t: ReturnType<typeof makeApp>,
  q: string,
  channel: 'glasses' | 'phone' = 'phone',
) {
  t.mock.script(text('Antwort auf ' + q));
  return t.app.ask({ text: q, channel, locale: 'de' });
}

test('one shared conversation across glasses and phone', async () => {
  const t = makeApp();
  const a = await chat(t, 'Frage eins', 'glasses');
  t.clock.advanceMinutes(2);
  const b = await chat(t, 'Frage zwei', 'phone');
  assert.equal(a.conversationId, b.conversationId);
  const msgs = t.mock.calls[1]!.messages;
  assert.deepEqual(
    msgs.slice(1).map((m) => m.role),
    ['user', 'assistant', 'user'],
    'second question sees the first turn from the glasses',
  );
  assert.deepEqual(
    t.app.conversations.turns(a.conversationId).map((x) => x.channel),
    ['glasses', 'glasses', 'phone', 'phone'],
  );
});

test('after 10 min idle: LLM summary replaces old turns, recent turns stay', async () => {
  const t = makeApp();
  t.app.settings.set('conversation.keep_recent_turns', 2);
  for (const q of [
    'Ich plane eine Reise nach Rom',
    'Wann fährt der Zug',
    'Und das Hotel',
  ]) {
    await chat(t, q);
    t.clock.advanceMinutes(1);
  }
  const id = t.app.conversations.current().id;
  assert.equal(t.app.conversations.turns(id).length, 6);
  t.clock.advanceMinutes(8); // 9 min idle in total
  await t.app.conversations.maintain();
  assert.equal(t.app.conversations.turns(id).length, 6, '9 min: nothing yet');
  t.clock.advanceMinutes(2);
  t.mock.script(
    text('Jan plant eine Reise nach Rom, Zug und Hotel offen.'),
    text('[{"text":"Jan reist nach Rom","kind":"fact"}]'),
  );
  await t.app.conversations.maintain();
  const turns = t.app.conversations.turns(id);
  assert.equal(turns.length, 2, 'only the 2 most recent turns remain');
  assert.equal(turns[0]!.text, 'Und das Hotel');
  assert.match(t.app.conversations.summaryOf(id)!, /Rom/);
  // the history is kept in full (flagged), and stays searchable
  const full = t.app.conversations.get(id)!.turns;
  assert.equal(full.length, 6);
  assert.deepEqual(
    full.map((x) => !!x.compacted),
    [true, true, true, true, false, false],
  );
  assert.ok(t.app.conversations.search('Rom').length > 0);
  assert.equal(
    t.app.memory.search('Rom')[0]!.text,
    'Jan reist nach Rom',
    'auto-extraction after compaction',
  );
  const before = t.mock.calls.length;
  await t.app.conversations.maintain();
  assert.equal(
    t.mock.calls.length,
    before,
    'compaction runs once per idle period',
  );
  // the next question carries the summary
  await chat(t, 'Weiter');
  assert.match(
    (t.mock.calls.at(-1)!.messages[0] as any).content,
    /Earlier in this conversation[\s\S]*Rom/,
  );
});

test('after 1 h idle: new conversation, old one gets title + summary and is searchable', async () => {
  const t = makeApp();
  const events: any[] = [];
  const a = await chat(t, 'Wie funktioniert ein Sauerteig');
  t.clock.advanceMinutes(30);
  const same = await chat(t, 'Wie lange muss er gehen');
  assert.equal(a.conversationId, same.conversationId);
  t.clock.advanceMinutes(61);
  t.app.hub.add({
    id: 'c',
    deviceId: 'd',
    deviceName: 'd',
    ready: true,
    send: (m) => events.push(m),
    close() {},
  });
  t.mock.script(
    text(
      '{"title":"Sauerteig backen","summary":"Jan fragt nach Sauerteig und Gehzeit."}',
    ),
    text('[]'),
    text('neue Antwort'),
  );
  const b = await t.app.ask({
    text: 'Neues Thema: Steuern',
    channel: 'phone',
    locale: 'de',
  });
  assert.notEqual(b.conversationId, a.conversationId);
  assert.deepEqual(
    events.find((e) => e.type === 'conversation'),
    { type: 'conversation', conversationId: b.conversationId, event: 'new' },
  );
  const old = t.app.conversations.get(a.conversationId)!;
  assert.equal(old.conversation.status, 'closed');
  assert.equal(old.conversation.title, 'Sauerteig backen');
  assert.match(old.conversation.summary!, /Gehzeit/);
  // new conversation does not see old turns
  const sys = t.mock.calls.at(-1)!.messages;
  assert.equal(sys.length, 2);
});

test('FTS5 search over titles, summaries and turns', async () => {
  const t = makeApp();
  await chat(t, 'Rezept für Linsensuppe mit Kokosmilch');
  t.clock.advanceMinutes(90);
  t.mock.script(
    text('{"title":"Linsensuppe","summary":"Rezeptfrage zu Suppe."}'),
    text('[]'),
  );
  await t.app.conversations.maintain();
  const cid = t.app.conversations.list()[0]!.id;
  const byTitle = t.app.conversations.search('linsensuppe');
  assert.ok(
    byTitle.some((r) => r.conversationId === cid && r.kind === 'summary'),
  );
  const byTurn = t.app.conversations.search('Kokosmilch');
  assert.ok(
    byTurn.some((r) => r.kind === 'turn' && /Kokosmilch/.test(r.snippet)),
  );
  assert.deepEqual(t.app.conversations.search('xyzzy'), []);
  const tool = await t.app.tools.call(
    'conversation_read',
    { conversationId: cid },
    {
      app: t.app,
      run: { channel: 'job', locale: 'en', actions: [], status() {} },
    },
  );
  assert.match(tool.text, /Linsensuppe/);
  assert.ok(t.clock.now() > 60 * MIN);
});

test('compaction failure leaves turns untouched', async () => {
  const t = makeApp();
  t.app.settings.set('conversation.keep_recent_turns', 1);
  await chat(t, 'a');
  await chat(t, 'b');
  t.clock.advanceMinutes(15);
  t.mock.script(() => {
    throw new Error('llm down');
  });
  await t.app.conversations.maintain();
  assert.equal(
    t.app.conversations.turns(t.app.conversations.current().id).length,
    4,
  );
});
