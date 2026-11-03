import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DAY } from './util/clock.ts';
import { answer, call, makeApp, text } from './testing/helpers.ts';

test('memory: remember, FTS search, forget, update, dedupe on exact text', () => {
  const t = makeApp();
  const m = t.app.memory.remember('Jan trinkt morgens Kaffee ohne Milch', {
    kind: 'preference',
  });
  t.app.memory.remember('Jans Schwester heißt Lena', { kind: 'person' });
  assert.equal(
    t.app.memory.remember('jan trinkt morgens kaffee ohne milch!').id,
    m.id,
    'normalised duplicate',
  );
  assert.equal(t.app.memory.count(), 2);
  assert.deepEqual(
    t.app.memory.search('Kaffee').map((x) => x.id),
    [m.id],
  );
  assert.equal(
    t.app.memory.search('Wer ist Lena?')[0]!.text,
    'Jans Schwester heißt Lena',
  );
  assert.deepEqual(t.app.memory.search('???'), []);
  t.app.memory.update(m.id, { text: 'Jan trinkt Tee' });
  assert.equal(t.app.memory.search('Kaffee').length, 0);
  assert.equal(t.app.memory.search('Tee').length, 1);
  const f = t.app.ops.invoke('memory.forget', { query: 'Lena' }, 'agent');
  return f.then(() => assert.equal(t.app.memory.count(), 1));
});

test('memory tools through the agent: remember and forget', async () => {
  const t = makeApp();
  t.mock.script(
    call('memory_remember', {
      text: 'Jan hat eine Katze namens Mio',
      kind: 'fact',
    }),
    answer('Gemerkt'),
  );
  await t.app.ask({
    text: 'Merk dir: ich habe eine Katze Mio',
    channel: 'phone',
    locale: 'de',
  });
  assert.ok(
    t.app.memory.search('Mio')[0]!.sourceConversation,
    'remembers which conversation it came from',
  );
  t.mock.script(call('memory_forget', { query: 'Katze' }), answer('Vergessen'));
  await t.app.ask({
    text: 'Vergiss die Katze',
    channel: 'phone',
    locale: 'de',
  });
  assert.equal(t.app.memory.search('Mio').length, 0);
});

test('dreaming: dedupe, contradictions (newest wins), stale, report', async () => {
  const t = makeApp();
  const { app, clock } = t;
  clock.set(new Date(2026, 0, 10));
  app.memory.remember('Jan wohnt in Berlin', { kind: 'place' });
  clock.set(new Date(2026, 0, 11)); // the duplicate is newer: it is the one kept
  app.memory.remember('Jan wohnt in Berlin Mitte', { kind: 'place' });
  app.memory.remember('Jan fährt gern Fahrrad', { kind: 'preference' });
  app.memory.remember('Das Meeting mit Frau Schulz war am Montag', {
    kind: 'fact',
  }); // will go stale
  clock.set(new Date(2026, 10, 1));
  const newer = app.memory.remember('Jan wohnt jetzt in Hamburg', {
    kind: 'place',
  });
  const berlinId = app.memory
    .list()
    .find((m) => m.text === 'Jan wohnt in Berlin Mitte')!.id;
  app.skills.put('skill', 'alt', '# Alt');
  t.mock.script((msgs) => {
    const body = (msgs[1] as any).content as string;
    assert.match(body, /Hamburg/);
    // newer first: the code must decide by timestamp, not by the order the model chose
    return text(JSON.stringify([{ a: newer.id, b: berlinId }]));
  });
  clock.set(new Date(2026, 10, 3, 3, 0));
  const rep = await app.dreaming.run();
  const texts = app.memory.list().map((m) => m.text);
  assert.ok(texts.includes('Jan wohnt jetzt in Hamburg'));
  assert.ok(
    !texts.includes('Jan wohnt in Berlin Mitte'),
    'contradicted memory superseded',
  );
  assert.ok(!texts.includes('Jan wohnt in Berlin'), 'near-duplicate merged');
  assert.ok(
    !texts.includes('Das Meeting mit Frau Schulz war am Montag'),
    'stale dropped',
  );
  assert.ok(texts.includes('Jan fährt gern Fahrrad'), 'preferences are kept');
  assert.equal(app.memory.get(newer.id)!.supersedes, berlinId);
  assert.equal(app.memory.get(berlinId)!.status, 'superseded');
  assert.equal(
    app.memory.search('Berlin').length,
    0,
    'superseded not searchable',
  );
  assert.deepEqual(
    [rep.stats.merged, rep.stats.contradictions, rep.stats.stale],
    [1, 1, 1],
  );
  assert.match(rep.report, /Contradiction/);
  assert.equal(app.dreaming.reports()[0]!.id, rep.id);
  clock.advance(100 * DAY);
  const rep2 = await app.dreaming.run();
  assert.match(rep2.report, /Unused skill/);
});

test('dreaming op + report survive a failing LLM', async () => {
  const t = makeApp();
  t.app.memory.remember('a one', {});
  t.app.memory.remember('b two', {});
  t.mock.script(() => {
    throw new Error('llm down');
  });
  const r = (await t.app.ops.invoke('dreaming.run_now', {}, 'app')) as any;
  assert.equal(r.ok, true);
  assert.match(r.result.report, /skipped/);
});

test('dreaming scales: prefix-filtered dedupe, contradiction prompts batched per kind (<= 150)', async () => {
  const { CONTRADICTION_BATCH, findNearDuplicates } = await import('./dreaming.ts');
  // exactness of the prefix filter against the brute-force pairs
  const words = ['jan', 'mag', 'kaffee', 'tee', 'berlin', 'hamburg', 'rad', 'auto', 'katze', 'hund'];
  let seed = 7;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  const items = Array.from({ length: 300 }, (_, i) => ({
    id: String(i),
    kind: i % 2 ? 'fact' : 'place',
    text: Array.from({ length: 3 + Math.floor(rnd() * 4) }, () => words[Math.floor(rnd() * words.length)]).join(' '),
  }));
  const fast: string[] = [];
  await findNearDuplicates(items, (a, b) => fast.push(`${a.id}>${b.id}`));
  const { norm } = await import('./memory.ts');
  const set = (t: string) => new Set(norm(t).split(' ').filter(Boolean));
  const jac = (x: Set<string>, y: Set<string>) => {
    const inter = [...x].filter((w) => y.has(w)).length;
    return inter / (x.size + y.size - inter);
  };
  const slow: string[] = [];
  const gone = new Set<number>();
  for (let i = 0; i < items.length; i++) {
    if (gone.has(i)) continue;
    for (let j = i + 1; j < items.length; j++)
      if (!gone.has(j) && items[i]!.kind === items[j]!.kind && jac(set(items[i]!.text), set(items[j]!.text)) >= 0.8) {
        gone.add(j);
        slow.push(`${i}>${j}`);
      }
  }
  assert.deepEqual(fast, slow);

  const t = makeApp();
  for (let i = 0; i < 320; i++)
    t.app.memory.remember(`Erinnerung Nummer ${i} über Thema ${i * 7}`, { kind: i < 200 ? 'fact' : 'place' });
  const sizes: number[] = [];
  t.mock.script(
    ...Array.from({ length: 5 }, () => (msgs: any[]) => {
      sizes.push(String(msgs[1].content).split('\n').length);
      return text('[]');
    }),
  );
  await t.app.dreaming.run();
  assert.deepEqual(sizes.sort((a, b) => a - b), [50, 120, 150]);
  assert.ok(sizes.every((n) => n <= CONTRADICTION_BATCH));
});

test('dreaming refreshes a missing summary without reopening the conversation', async () => {
  const t = makeApp();
  const conv = t.app.conversations.current();
  t.app.conversations.addTurn(conv.id, 'user', 'Wie wird das Wetter?');
  t.app.db.run("UPDATE conversations SET status='closed', summary=NULL WHERE id=?", conv.id);
  let openDuring: unknown = 'unset';
  t.mock.script(() => {
    openDuring = t.app.conversations.openRow()?.id ?? null;
    return text('{"title":"Wetter","summary":"Frage nach dem Wetter."}');
  });
  const r = await t.app.dreaming.run();
  assert.equal(r.stats.summaries, 1);
  assert.equal(openDuring, null, 'never the open conversation');
  const c = t.app.conversations.get(conv.id)!.conversation;
  assert.deepEqual([c.status, c.title, c.summary], ['closed', 'Wetter', 'Frage nach dem Wetter.']);
});

test('remember() finds duplicates through the indexed norm column; old rows are backfilled', () => {
  const t = makeApp();
  const m = t.app.memory.remember('Jan mag Tee', {});
  assert.equal(
    t.app.db.get<{ norm: string }>('SELECT norm FROM memories WHERE id=?', m.id)!.norm,
    'jan mag tee',
  );
  t.app.db.run('UPDATE memories SET norm=NULL');
  t.app.memory.backfillNorm();
  assert.equal(t.app.memory.remember('JAN MAG TEE.').id, m.id);
  const plan = t.app.db
    .all<{ detail: string }>("EXPLAIN QUERY PLAN SELECT * FROM memories WHERE norm='x' AND status='active'")
    .map((r) => r.detail)
    .join(' ');
  assert.match(plan, /memories_norm/);
});
