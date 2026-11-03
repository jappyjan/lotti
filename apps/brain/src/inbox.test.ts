import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HOUR } from './util/clock.ts';
import {
  WsClient,
  makeApp,
  pairDevice,
  startServer,
} from './testing/helpers.ts';

test('inbox lifecycle: pending -> seen -> dismissed, expiry sweeper, restore', () => {
  const t = makeApp();
  const events: any[] = [];
  t.app.hub.add({
    id: 'c',
    deviceId: 'd',
    deviceName: 'd',
    ready: true,
    send: (m) => events.push(m),
    close() {},
  });
  const a = t.app.inbox.create({
    kind: 'mail',
    title: 'Von Lena',
    summary: 'Abendessen?',
  });
  const b = t.app.inbox.create({
    kind: 'info',
    title: 'Kurzlebig',
    expiresInHours: 1,
  });
  assert.equal(a.status, 'pending');
  assert.equal(a.expiresAt?.slice(0, 10), '2026-11-06', 'default expiry 72 h');
  assert.deepEqual(
    events.map((e) => e.type),
    ['inbox', 'push', 'inbox', 'push'],
  );
  assert.equal(t.app.inbox.markSeen(a.id)!.status, 'seen');
  assert.deepEqual(events.at(-1), {
    type: 'inbox',
    full: false,
    items: [{ ...a, status: 'seen' }],
    removedIds: [],
  });
  t.clock.advance(2 * HOUR);
  assert.deepEqual(t.app.inbox.sweepExpired(), [b.id]);
  assert.equal(t.app.inbox.get(b.id)!.status, 'expired');
  assert.deepEqual(events.at(-1), {
    type: 'inbox',
    full: false,
    items: [],
    removedIds: [b.id],
  });
  assert.equal(t.app.inbox.dismiss(a.id)!.status, 'dismissed');
  assert.equal(t.app.inbox.dismiss(a.id)!.status, 'dismissed');
  assert.equal(t.app.inbox.list().length, 0);
  assert.equal(t.app.inbox.restore(a.id)!.status, 'pending');
  assert.equal(
    t.app.inbox.get(b.id)!.status,
    'expired',
    'expired stays expired',
  );
  const c = t.app.inbox.create({
    title: 'Dup',
    sourceRef: 'x:1',
    dedupe: true,
  });
  assert.equal(
    t.app.inbox.create({ title: 'Dup', sourceRef: 'x:1', dedupe: true }).id,
    c.id,
  );
  assert.equal(t.app.inbox.dismissAll().length, 2);
  assert.deepEqual(t.app.inbox.full().items, []);
});

test('push queue: offline items are queued per device, APNs hook called, replayed on reconnect', async () => {
  const notified: string[] = [];
  const t = makeApp({
    integrations: {
      push: {
        notifyOffline: async (dev, item) =>
          void notified.push(`${dev.name}:${item.title}`),
      },
    },
  });
  const srv = await startServer(t);
  try {
    const token = pairDevice(t.app, 'Jans iPhone');
    const x = t.app.inbox.create({
      kind: 'mail',
      title: 'Wichtig',
      summary: 's',
    });
    const y = t.app.inbox.create({ kind: 'calendar', title: 'Meeting' });
    assert.deepEqual(notified, ['Jans iPhone:Wichtig', 'Jans iPhone:Meeting']);
    assert.equal(t.app.inbox.queueDepth(), 2);
    const c = await WsClient.connect(srv, token);
    await c.waitFor((m) => m.type === 'inbox' && m.full);
    await c.waitFor((m) => m.type === 'push' && m.item.id === y.id);
    assert.deepEqual(
      c.of('push').map((m) => m.item.id),
      [x.id, y.id],
    );
    assert.deepEqual(
      c
        .of('inbox')[0]
        .items.map((i: any) => i.id)
        .sort(),
      [x.id, y.id].sort(),
      'full sync covers them too',
    );
    assert.equal(t.app.inbox.queueDepth(), 0, 'queue drained');
    // connected: new items are pushed live and not queued / not notified through APNs
    t.app.inbox.create({ title: 'Live' });
    await c.waitFor((m) => m.type === 'push' && m.item.title === 'Live');
    assert.equal(t.app.inbox.queueDepth(), 0);
    assert.equal(notified.length, 2);
    await c.close();
  } finally {
    await srv.close();
  }
});

test('phone events and sync update the inbox both ways', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const c = await WsClient.connect(srv, pairDevice(t.app));
    const a = t.app.inbox.create({ title: 'A' });
    const b = t.app.inbox.create({ title: 'B' });
    c.send({ type: 'inbox_event', itemId: a.id, event: 'shown' });
    c.send({ type: 'inbox_event', itemId: b.id, event: 'dismissed' });
    // messages are handled in order: the full sync answers after both events were applied
    const fullP = c.next('inbox', 3000, (m) => m.full === true);
    c.send({ type: 'inbox_sync' });
    const full = await fullP;
    assert.equal(t.app.inbox.get(a.id)!.status, 'seen');
    assert.equal(t.app.inbox.get(b.id)!.status, 'dismissed');
    assert.equal(full.full, true);
    assert.deepEqual(
      full.items.map((i: any) => [i.id, i.status]),
      [[a.id, 'seen']],
    );
    // server-side change is broadcast to the app
    await t.app.ops.invoke('inbox.dismiss', { id: a.id }, 'agent');
    const upd = await c.waitFor(
      (m) => m.type === 'inbox' && !m.full && m.removedIds.includes(a.id),
    );
    assert.deepEqual(upd.items, []);
    await c.close();
  } finally {
    await srv.close();
  }
});

test('agent inbox tools: list, read, dismiss all', async () => {
  const t = makeApp();
  const a = t.app.inbox.create({ title: 'A', body: 'Langer Text' });
  t.app.inbox.create({ title: 'B' });
  const run = {
    channel: 'job' as const,
    locale: 'en' as const,
    actions: [],
    status() {},
  };
  const l = await t.app.tools.call('inbox_list', {}, { app: t.app, run });
  assert.match(l.text, /"title":"A"/);
  assert.match(
    (await t.app.tools.call('inbox_read', { id: a.id }, { app: t.app, run }))
      .text,
    /Langer Text/,
  );
  assert.equal(t.app.inbox.get(a.id)!.status, 'seen');
  const d = await t.app.tools.call(
    'inbox_dismiss',
    { all: true },
    { app: t.app, run },
  );
  assert.match(d.text, /Dismissed 2/);
  assert.equal(t.app.inbox.list().length, 0);
});
