import assert from 'node:assert/strict';
import { test } from 'node:test';
import { z } from 'zod';
import { CancelledError, parseFinal, runJobPrompt } from './agent/loop.ts';
import { answer, call, calls, hang, makeApp, text } from './testing/helpers.ts';

test('agent loop: tool call, then structured answer with follow-ups', async () => {
  const t = makeApp();
  t.app.tools.register({
    name: 'echo',
    description: 'echo',
    inputSchema: z.object({ v: z.string() }),
    kind: 'server',
    status: { de: 'Echo …', en: 'Echoing …' },
    handler: async (a) => `echo:${a.v}`,
  });
  t.mock.script(
    call('echo', { v: 'hi' }),
    answer('Fertig: echo:hi', ['a', 'b', 'c', 'd']),
  );
  const status: string[] = [];
  const r = await t.app.ask({
    text: 'Sag hi',
    channel: 'phone',
    locale: 'de',
    onStatus: (s) => status.push(s),
  });
  assert.equal(r.text, 'Fertig: echo:hi');
  assert.deepEqual(r.followUps, ['a', 'b', 'c']); // capped at 3
  assert.ok(status.includes('Echo …'));
  // the tool result reached the model on round 2
  const second = t.mock.calls[1]!.messages;
  assert.ok(second.some((m) => m.role === 'tool' && m.content === 'echo:hi'));
  // answer tool is offered, system prompt has persona + time
  const sys = t.mock.calls[0]!.messages[0]!;
  assert.equal(sys.role, 'system');
  assert.match((sys as any).content, /Lotti/);
  assert.match((sys as any).content, /2026-11-03/);
  assert.ok(t.mock.calls[0]!.tools.some((x) => x.name === 'answer'));
});

test('structured vs plain output', async () => {
  const t = makeApp();
  t.mock.script(
    text('{"text":"Hallo Jan","followUps":["Und morgen?"]}'),
    text('Just words, no JSON.'),
    text('```json\n{"text":"fenced"}\n```'),
  );
  const a = await t.app.ask({ text: '1', channel: 'phone', locale: 'de' });
  assert.equal(a.text, 'Hallo Jan');
  assert.deepEqual(a.followUps, ['Und morgen?']);
  const b = await t.app.ask({ text: '2', channel: 'phone', locale: 'en' });
  assert.equal(b.text, 'Just words, no JSON.');
  assert.deepEqual(b.followUps, []);
  const c = await t.app.ask({ text: '3', channel: 'phone', locale: 'en' });
  assert.equal(c.text, 'fenced');
  assert.deepEqual(parseFinal('{"foo":1}'), {
    text: '{"foo":1}',
    followUps: [],
  });
});

test('glasses channel prompt asks for one very short sentence', async () => {
  const t = makeApp();
  await t.app.ask({ text: 'wie spät', channel: 'glasses', locale: 'de' });
  assert.match(
    (t.mock.calls[0]!.messages[0] as any).content,
    /ONE very short sentence/,
  );
});

test('proposal tools give actions (max 2) and never act by themselves', async () => {
  const t = makeApp();
  t.mock.script(
    calls(
      { id: '1', name: 'set_timer', args: { minutes: 10, label: 'Tee' } },
      { id: '2', name: 'create_reminder', args: { title: 'Müll' } },
      {
        id: '3',
        name: 'start_navigation',
        args: { destination: 'Hamburg Hbf' },
      },
    ),
    answer('Vorschläge bereit'),
  );
  const r = await t.app.ask({ text: 'x', channel: 'phone', locale: 'de' });
  assert.equal(r.actions.length, 2);
  assert.deepEqual(
    r.actions.map((a) => [a.target, a.tool]),
    [
      ['phone', 'set_timer'],
      ['phone', 'create_reminder'],
    ],
  );
  const toolMsg = (
    t.mock.calls[1]!.messages.find((m) => m.role === 'tool') as any
  ).content;
  assert.match(toolMsg, /Nothing has happened yet/);
});

test('cancel aborts the run', async () => {
  const t = makeApp();
  t.mock.script(hang);
  const ac = new AbortController();
  const p = t.app.ask({
    text: 'langsam',
    channel: 'phone',
    locale: 'de',
    signal: ac.signal,
  });
  setTimeout(() => ac.abort(), 20);
  await assert.rejects(p, (e) => e instanceof CancelledError);
});

test('fallback provider takes over on error', async () => {
  const t = makeApp();
  const fb = new (t.mock.constructor as any)('fb', 'Fallback');
  t.app.providers.register(fb);
  t.app.settings.set('provider.fallback', 'fb');
  t.mock.script(() => {
    throw new Error('HTTP 500 boom');
  });
  fb.script(text('von fallback'));
  const r = await t.app.ask({ text: 'x', channel: 'phone', locale: 'en' });
  assert.equal(r.text, 'von fallback');
  const st = t.app.providers.status();
  assert.match(st.find((p) => p.id === 'mock')!.lastError!, /boom/);
  assert.ok(st.find((p) => p.id === 'fb')!.lastOkAt);
});

test('silence timeout triggers fallback', async () => {
  const t = makeApp();
  const fb = new (t.mock.constructor as any)('fb', 'Fallback');
  t.app.providers.register(fb);
  t.app.settings.set('provider.fallback', 'fb');
  t.mock.script(hang);
  fb.script(text('rescued'));
  const res = await t.app.providers.complete(
    [{ role: 'user', content: 'x' }],
    [],
    { silenceMs: 30 },
  );
  assert.equal(res.text, 'rescued');
  assert.match(
    t.app.providers.status().find((p) => p.id === 'mock')!.lastError!,
    /timed out/,
  );
});

test('error without fallback is surfaced', async () => {
  const t = makeApp();
  t.mock.script(() => {
    throw new Error('no key');
  });
  await assert.rejects(
    t.app.ask({ text: 'x', channel: 'phone', locale: 'en' }),
    /no key/,
  );
});

test('round limit: model that only calls tools is forced to answer', async () => {
  const t = makeApp();
  t.app.tools.register({
    name: 'noop',
    description: '',
    inputSchema: z.object({}),
    kind: 'server',
    handler: async () => 'done',
  });
  t.app.settings.set('agent.max_rounds', 3);
  t.mock.script(call('noop'), call('noop'), (_m, tools) => {
    assert.deepEqual(
      tools.map((x) => x.name),
      ['answer'],
    );
    return call('answer', { text: 'forced' });
  });
  const r = await t.app.ask({ text: 'x', channel: 'phone', locale: 'en' });
  assert.equal(r.text, 'forced');
  assert.equal(t.mock.calls.length, 3);
});

test('unknown tool and invalid args come back as tool results, not crashes', async () => {
  const t = makeApp();
  t.mock.script(
    call('does_not_exist'),
    call('weather', { lat: 999 }),
    answer('ok'),
  );
  const r = await t.app.ask({ text: 'x', channel: 'phone', locale: 'en' });
  assert.equal(r.text, 'ok');
  const tools = t.mock.calls[2]!.messages.filter((m) => m.role === 'tool').map(
    (m: any) => m.content,
  );
  assert.match(tools[0], /Unknown tool/);
  assert.match(tools[1], /Invalid arguments/);
});

test('job prompt: NOTHING means nothing to report; inbox_create reports', async () => {
  const t = makeApp();
  t.mock.script(text('NOTHING'));
  assert.equal((await runJobPrompt(t.app, 'check x')).nothing, true);
  t.mock.script(
    call('inbox_create', { title: 'Heads up', summary: 's' }),
    answer('Reported.'),
  );
  const r = await runJobPrompt(t.app, 'check y');
  assert.equal(r.nothing, false);
  assert.equal(t.app.inbox.list()[0]!.title, 'Heads up');
});

test('memories and skill index go into the system prompt', async () => {
  const t = makeApp();
  t.app.memory.remember('Jan wohnt in Hamburg', { kind: 'place' });
  t.app.skills.put(
    'skill',
    'wetter',
    '# Wetter-Routine\nimmer zuerst location',
  );
  await t.app.ask({
    text: 'Wie ist das Wetter in Hamburg?',
    channel: 'phone',
    locale: 'de',
  });
  const sys = (t.mock.calls[0]!.messages[0] as any).content as string;
  assert.match(sys, /Jan wohnt in Hamburg/);
  assert.match(sys, /wetter: Wetter-Routine/);
});
