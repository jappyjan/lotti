import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  WsClient,
  answer,
  call,
  calls,
  hang,
  makeApp,
  pairDevice,
  startServer,
  text,
  until,
} from './testing/helpers.ts';

async function setup(opts: Parameters<typeof makeApp>[0] = {}) {
  const t = makeApp(opts);
  const srv = await startServer(t);
  const token = pairDevice(t.app);
  return { t, srv, token, done: () => srv.close() };
}

test('hello -> welcome + full inbox; unknown types and bad JSON give errors', async () => {
  const { t, srv, token, done } = await setup();
  try {
    t.app.inbox.create({ title: 'Schon da' });
    const c = await WsClient.connect(srv, token);
    const w = c.of('welcome')[0];
    assert.equal(w.serverVersion, '0.1.0');
    assert.match(w.conversationId, /^conv_/);
    assert.deepEqual(w.settings, { catchup: true, activeProvider: 'mock' });
    const inbox = await c.waitFor((m) => m.type === 'inbox');
    assert.equal(inbox.full, true);
    assert.equal(inbox.items[0].title, 'Schon da');
    assert.equal(t.app.auth.devices()[0]!.name, 'Test iPhone');
    c.send({ type: 'bogus' });
    assert.match(
      (await c.waitFor((m) => m.type === 'error')).message,
      /Unknown message type/,
    );
    c.ws.send('not json');
    await c.waitFor(
      (m) => m.type === 'error' && /Invalid JSON/.test(m.message),
    );
    await c.close();
  } finally {
    await done();
  }
});

test('ask -> status -> answer with follow-ups and actions; turns are mirrored to other sockets', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const phone = await WsClient.connect(srv, token);
    const second = await WsClient.connect(srv, token); // multiple sockets per device are fine
    t.mock.script(
      call('set_timer', { minutes: 10, label: 'Tee' }),
      answer('Timer vorgeschlagen.', ['Noch einen?']),
    );
    phone.send({
      type: 'ask',
      id: 'a1',
      text: 'Stell einen Timer',
      channel: 'glasses',
      now: '2026-11-03T08:15:00+01:00',
      locale: 'de',
    });
    const ans = await phone.waitFor((m) => m.type === 'answer');
    assert.equal(ans.id, 'a1');
    assert.equal(ans.text, 'Timer vorgeschlagen.');
    assert.deepEqual(ans.followUps, ['Noch einen?']);
    assert.equal(ans.actions.length, 1);
    assert.deepEqual(
      [ans.actions[0].target, ans.actions[0].tool, ans.actions[0].args.minutes],
      ['phone', 'set_timer', 10],
    );
    assert.ok(ans.actions[0].title && ans.actions[0].id);
    assert.equal(ans.conversationId, phone.of('welcome')[0].conversationId);
    const statuses = phone.of('status').map((s) => s.text);
    assert.ok(statuses.includes('Denke nach …'));
    assert.ok(phone.of('status').every((s) => s.id === 'a1'));
    // mirroring: every socket (the asker too) sees both turns; only the asker gets `answer`
    await second.waitFor((m) => m.type === 'message' && m.role === 'assistant');
    await phone.waitFor((m) => m.type === 'message' && m.role === 'assistant');
    assert.deepEqual(
      second.of('message').map((m) => [m.role, m.channel, m.text]),
      [
        ['user', 'glasses', 'Stell einen Timer'],
        ['assistant', 'glasses', 'Timer vorgeschlagen.'],
      ],
    );
    assert.equal(second.of('answer').length, 0);
    assert.deepEqual(
      phone.of('message').map((m) => m.role),
      ['user', 'assistant'],
    );
    // phone actions are not performed by the server
    phone.send({ type: 'perform', id: 'p1', actionId: ans.actions[0].id });
    const pf = await phone.waitFor(
      (m) => m.type === 'performed' && m.id === 'p1',
    );
    assert.equal(pf.ok, false);
    await phone.close();
    await second.close();
  } finally {
    await done();
  }
});

test('phone tools: location emits location_access around the tool_call, logs, and the result reaches the model', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const c = await WsClient.connect(srv, token);
    c.ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      if (m.type === 'tool_call')
        c.send({
          type: 'tool_result',
          callId: m.callId,
          ok: true,
          text:
            m.name === 'location'
              ? 'lat 53.5511, lon 9.9937 (Hamburg)'
              : '- Müll rausbringen',
        });
    });
    t.mock.script(
      calls(
        { id: 'x1', name: 'location', args: {} },
        { id: 'x2', name: 'reminders', args: { list: 'Zuhause' } },
      ),
      (msgs) => {
        const results = msgs
          .filter((m) => m.role === 'tool')
          .map((m: any) => m.content);
        assert.deepEqual(results, [
          'lat 53.5511, lon 9.9937 (Hamburg)',
          '- Müll rausbringen',
        ]);
        return answer('Du bist in Hamburg.');
      },
    );
    c.send({
      type: 'ask',
      id: 'a2',
      text: 'Wo bin ich?',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'de',
    });
    const ans = await c.waitFor((m) => m.type === 'answer');
    assert.equal(ans.text, 'Du bist in Hamburg.');
    const order = c.messages
      .filter((m) => ['location_access', 'tool_call'].includes(m.type))
      .map((m) =>
        m.type === 'location_access' ? `loc:${m.phase}` : `call:${m.name}`,
      );
    assert.deepEqual(
      order.filter((x) => x.startsWith('loc')),
      ['loc:start', 'loc:end'],
    );
    assert.ok(
      order.indexOf('loc:start') < order.indexOf('call:location') &&
        order.indexOf('call:location') < order.indexOf('loc:end'),
    );
    const tc = c.of('tool_call').find((m) => m.name === 'location');
    const [start, end] = c.of('location_access');
    assert.equal(start.callId, tc.callId);
    assert.equal(end.callId, tc.callId);
    assert.equal(tc.askId, 'a2');
    assert.match(start.at, /^\d{4}-\d\d-\d\dT/);
    const log = (await t.app.ops.invoke(
      'privacy.location_log',
      {},
      'app',
    )) as any;
    assert.equal(log.result.length, 1);
    assert.deepEqual(
      [log.result[0].source, log.result[0].ok, log.result[0].askId],
      ['agent', true, 'a2'],
    );
    await c.close();
  } finally {
    await done();
  }
});

test('phone tool times out after the configured time; location_access still ends', async () => {
  const { t, srv, token, done } = await setup({ toolTimeoutMs: 150 });
  try {
    const c = await WsClient.connect(srv, token);
    t.mock.script(call('location'), (msgs) => {
      assert.match(
        (msgs.at(-1) as any).content,
        /did not answer location within 0\.15 s/,
      );
      return answer('Konnte den Standort nicht lesen.');
    });
    c.send({
      type: 'ask',
      id: 'a3',
      text: 'Wo?',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'de',
    });
    await c.waitFor((m) => m.type === 'answer');
    assert.deepEqual(
      c.of('location_access').map((m) => m.phase),
      ['start', 'end'],
    );
    assert.equal(
      t.app.db.get<{ ok: number }>('SELECT ok FROM location_log')!.ok,
      0,
    );
    await c.close();
  } finally {
    await done();
  }
});

test('cancel aborts a running ask', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const c = await WsClient.connect(srv, token);
    t.mock.script(hang);
    c.send({
      type: 'ask',
      id: 'slow',
      text: 'Lange Frage',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'de',
    });
    await c.waitFor((m) => m.type === 'status');
    c.send({ type: 'cancel', id: 'slow' });
    const err = await c.waitFor((m) => m.type === 'error');
    assert.deepEqual([err.id, err.message], ['slow', 'cancelled']);
    assert.equal(c.of('answer').length, 0);
    // the socket is still usable
    t.mock.script(answer('wieder da'));
    c.send({
      type: 'ask',
      id: 'next',
      text: 'Hallo',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'de',
    });
    assert.equal(
      (await c.waitFor((m) => m.type === 'answer')).text,
      'wieder da',
    );
    await c.close();
  } finally {
    await done();
  }
});

test('perform runs a proposed server action once; undo reverts; wrong ids fail cleanly', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const c = await WsClient.connect(srv, token);
    const created: any[] = [];
    t.app.integrations.calendar = {
      events: async () => [],
      createEvent: async (a) => (
        created.push(a),
        {
          ok: true,
          text: 'Termin angelegt',
          undo: {
            label: 'Termin löschen',
            op: 'memory.remember',
            input: { text: 'undo-ran' },
          },
        }
      ),
    };
    t.mock.script(
      call('create_calendar_event', {
        title: 'Zahnarzt',
        start: '2026-11-04T10:00:00+01:00',
        end: '2026-11-04T11:00:00+01:00',
      }),
      answer('Soll ich den Termin anlegen?'),
    );
    c.send({
      type: 'ask',
      id: 'a5',
      text: 'Zahnarzt morgen 10 Uhr',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'de',
    });
    const ans = await c.waitFor((m) => m.type === 'answer');
    assert.equal(ans.actions[0].target, 'server');
    assert.equal(created.length, 0, 'not executed by the proposal');
    c.send({ type: 'perform', id: 'r1', actionId: ans.actions[0].id });
    const done1 = await c.waitFor(
      (m) => m.type === 'performed' && m.id === 'r1',
    );
    assert.deepEqual([done1.ok, done1.text], [true, 'Termin angelegt']);
    assert.equal(created.length, 1);
    assert.equal(done1.undo.label, 'Termin löschen');
    c.send({ type: 'perform', id: 'r2', actionId: ans.actions[0].id });
    assert.equal(
      (await c.waitFor((m) => m.type === 'performed' && m.id === 'r2')).ok,
      false,
    );
    assert.equal(created.length, 1);
    c.send({ type: 'perform', id: 'r3', actionId: 'act_nope' });
    assert.equal(
      (await c.waitFor((m) => m.type === 'performed' && m.id === 'r3')).ok,
      false,
    );
    c.send({ type: 'undo', id: 'u1', undoId: done1.undo.id });
    const u = await c.waitFor((m) => m.type === 'performed' && m.id === 'u1');
    assert.equal(u.ok, true);
    assert.equal(t.app.memory.list()[0]!.text, 'undo-ran');
    await c.close();
  } finally {
    await done();
  }
});

test('free op via the agent returns an undo handle in the answer; the app can undo it', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const c = await WsClient.connect(srv, token);
    t.mock.script(
      call('memory_remember', { text: 'Jan mag Oliven' }),
      answer('Gemerkt.'),
    );
    c.send({
      type: 'ask',
      id: 'a6',
      text: 'Merk dir: ich mag Oliven',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'de',
    });
    const ans = await c.waitFor((m) => m.type === 'answer');
    assert.ok(ans.undo.id && ans.undo.label);
    c.send({ type: 'undo', id: 'u2', undoId: ans.undo.id });
    await c.waitFor((m) => m.type === 'performed' && m.id === 'u2' && m.ok);
    assert.equal(t.app.memory.count(), 0);
    await c.close();
  } finally {
    await done();
  }
});

test('presence over the socket drives catch-up and arrives as `catchup`', async () => {
  const { t, srv, token, done } = await setup({ toolTimeoutMs: 50 });
  try {
    const c = await WsClient.connect(srv, token);
    t.mock.script(text('Willkommen zurück: eine neue Mail.'));
    c.send({
      type: 'presence',
      event: 'app_open',
      at: '2026-11-03T06:00:00+01:00',
    });
    c.send({
      type: 'presence',
      event: 'phone_unlock',
      at: '2026-11-03T06:00:30+01:00',
    });
    await until(
      () => t.app.settings.kvGet('presence.last_phone_use'),
      3000,
      'both presence events recorded',
    );
    t.clock.set(new Date('2026-11-03T10:00:00+01:00'));
    c.send({
      type: 'presence',
      event: 'head_up',
      at: '2026-11-03T10:00:00+01:00',
    });
    const b = await c.waitFor((m) => m.type === 'catchup');
    assert.equal(b.text, 'Willkommen zurück: eine neue Mail.');
    assert.ok(b.id && b.at);
    c.send({
      type: 'presence',
      event: 'nonsense',
      at: new Date().toISOString(),
    });
    await c.waitFor(
      (m) => m.type === 'error' && /Unknown presence event/.test(m.message),
    );
    await c.close();
  } finally {
    await done();
  }
});

test('errors from the model are reported against the ask id', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const c = await WsClient.connect(srv, token);
    t.mock.script(() => {
      throw new Error('DeepSeek HTTP 401: bad key');
    });
    c.send({
      type: 'ask',
      id: 'bad',
      text: 'x',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'en',
    });
    const e = await c.waitFor((m) => m.type === 'error');
    assert.deepEqual([e.id, e.message], ['bad', 'DeepSeek HTTP 401: bad key']);
    c.send({ type: 'ask', text: '' });
    await c.waitFor((m) => m.type === 'error' && !m.id);
    await c.close();
  } finally {
    await done();
  }
});

test('shared conversation: glasses question then phone question see each other', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const c = await WsClient.connect(srv, token);
    t.mock.script(answer('Hamburg.'), answer('Ja, wegen Hamburg.'));
    c.send({
      type: 'ask',
      id: 'g1',
      text: 'Wo wohne ich?',
      channel: 'glasses',
      now: new Date().toISOString(),
      locale: 'de',
    });
    const a1 = await c.waitFor((m) => m.type === 'answer' && m.id === 'g1');
    c.send({
      type: 'ask',
      id: 'p1',
      text: 'Warum?',
      channel: 'phone',
      now: new Date().toISOString(),
      locale: 'de',
    });
    const a2 = await c.waitFor((m) => m.type === 'answer' && m.id === 'p1');
    assert.equal(a1.conversationId, a2.conversationId);
    const second = t.mock.calls[1]!.messages.filter(
      (m) => m.role !== 'system',
    ).map((m: any) => m.content);
    assert.deepEqual(second, ['Wo wohne ich?', 'Hamburg.', 'Warum?']);
    await c.close();
  } finally {
    await done();
  }
});

test('asks are keyed per socket (same id from two devices), phone tools go to the asking socket', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const a = await WsClient.connect(srv, token);
    const b = await WsClient.connect(srv, pairDevice(t.app, 'iPad')); // most recent socket
    a.ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      if (m.type === 'tool_call')
        a.send({ type: 'tool_result', callId: m.callId, ok: true, text: 'Berlin' });
    });
    t.mock.script(call('location', {}), answer('In Berlin.'));
    a.send({ type: 'ask', id: 'q', text: 'Wo bin ich?', channel: 'phone', locale: 'de' });
    const ans = await a.waitFor((m) => m.type === 'answer' && m.id === 'q');
    assert.equal(ans.text, 'In Berlin.');
    assert.equal(a.of('tool_call').length, 1);
    assert.equal(b.of('tool_call').length, 0, 'not sent to the newest socket');

    const slow = async () => {
      await new Promise((r) => setTimeout(r, 80));
      return answer('fertig');
    };
    t.mock.script(slow, slow);
    for (const c of [a, b])
      c.send({ type: 'ask', id: 'same', text: 'x', channel: 'phone', locale: 'de' });
    const [ra, rb] = await Promise.all(
      [a, b].map((c) => c.waitFor((m) => (m.type === 'answer' || m.type === 'error') && m.id === 'same')),
    );
    assert.deepEqual([ra.type, rb.type], ['answer', 'answer'], 'neither cancelled the other');
    await a.close();
    await b.close();
  } finally {
    await done();
  }
});

test('liveness: a socket that stops answering pings is terminated, so pushes queue for APNs', async () => {
  const { t, srv, token, done } = await setup({ wsPingMs: 40 });
  try {
    const live = await WsClient.connect(srv, token);
    const dead = await WsClient.connect(srv, token);
    assert.equal(t.app.hub.connections().length, 2);
    (dead.ws as any)._socket.pause(); // a vanished phone: no pong ever comes back
    await until(() => t.app.hub.connections().length === 1, 3000, 'dead socket removed');
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(t.app.hub.connections().length, 1, 'the answering socket stays');
    await live.close();
    await until(() => !t.app.hub.hasConnections(), 3000, 'live socket closed');
    t.app.inbox.create({ title: 'Neu' });
    assert.equal(t.app.inbox.queueDepth(), 1, 'queued for the offline device');
    (dead.ws as any)._socket.destroy();
  } finally {
    await done();
  }
});

test('ask: a status frame arrives at once, before conversation maintenance finishes; the ask goes on after a bounded wait', async () => {
  const { t, srv, token, done } = await setup();
  try {
    const c = await WsClient.connect(srv, token);
    let release!: () => void;
    const slow = new Promise<void>((r) => (release = r));
    t.app.conversations.maintain = () => slow; // a compaction hanging on the LLM
    const { MAINTAIN_WAIT_MS } = await import('./conversations.ts');
    assert.equal(MAINTAIN_WAIT_MS, 3000);
    t.mock.script(answer('Hallo.'));
    const t0 = Date.now();
    c.send({ type: 'ask', id: 'u-1', text: 'Hallo', channel: 'phone', locale: 'de' });
    const st = await c.waitFor((m) => m.type === 'status' && m.id === 'u-1', 1000);
    assert.equal(st.text, 'Denke nach …');
    assert.ok(Date.now() - t0 < 1000, 'well within the app\'s 6 s');
    const ans = await c.waitFor((m) => m.type === 'answer' && m.id === 'u-1', 10_000);
    assert.equal(ans.text, 'Hallo.');
    assert.ok(Date.now() - t0 < 9000, 'maintenance wait is bounded');
    release();
    await c.close();
  } finally {
    await done();
  }
});
