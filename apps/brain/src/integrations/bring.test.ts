import assert from 'node:assert/strict';
import { test } from 'node:test';
import { jsonResponse, makeApp } from '../testing/helpers.ts';
import { mockFetch } from './testing.ts';
import { registerIntegrations } from './register.ts';
import { newRun } from '../tools/registry.ts';

function bringApp(extra: Parameters<typeof mockFetch>[0] = []) {
  let lists = {
    items: {
      purchase: [{ name: 'Brot', specification: '1 Stk' }, { name: 'Käse' }],
      recently: [{ name: 'Butter', specification: '' }],
    },
  };
  const m = mockFetch([
    ...extra,
    {
      m: 'POST',
      u: '/bringauth',
      res: (r) => {
        const f = new URLSearchParams(r.body);
        return f.get('password') === 'pw'
          ? {
              uuid: 'U1',
              access_token: 'tok',
              name: 'Jan',
              bringListUUID: 'L1',
            }
          : new Response('{}', { status: 401 });
      },
    },
    {
      u: '/bringusers/U1/lists',
      res: () => ({
        lists: [
          { listUuid: 'L1', name: 'Zuhause' },
          { listUuid: 'L2', name: 'Party' },
        ],
      }),
    },
    { m: 'GET', u: '/bringlists/', res: () => lists },
    {
      m: 'PUT',
      u: '/bringlists/',
      res: (r) => {
        const f = new URLSearchParams(r.body);
        if (f.get('purchase'))
          lists.items.purchase.push({
            name: f.get('purchase')!,
            ...(f.get('specification')
              ? { specification: f.get('specification')! }
              : {}),
          } as any);
        if (f.get('recently'))
          lists.items.purchase = lists.items.purchase.filter(
            (i) => i.name !== f.get('recently'),
          );
        return new Response('', { status: 200 });
      },
    },
  ]);
  const t = makeApp({ fetch: m.fetch });
  registerIntegrations(t.app);
  return { t, m };
}
const login = async (t: ReturnType<typeof makeApp>, pw = 'pw') =>
  (await t.app.ops.invoke(
    'bring.login',
    { email: 'a@b.de', password: pw },
    'app',
  )) as any;

test('bring: login stores secrets and checks; wrong password is a clear error', async () => {
  const { t } = bringApp();
  const bad = await login(t, 'nope');
  assert.equal(bad.result.ok, false);
  assert.match(bad.result.error, /wrong email or password/);
  const ok = await login(t);
  assert.equal(ok.result.ok, true);
  assert.ok(t.app.secrets.has(`account.${ok.result.accountId}.password`));
  const st = (await t.app.ops.invoke('bring.status', {}, 'app')) as any;
  assert.deepEqual(st.result, {
    connected: true,
    account: 'Jan',
    defaultList: 'L1',
  });
  assert.ok(
    !JSON.stringify(
      await t.app.ops.invoke('accounts.list', {}, 'app'),
    ).includes('"pw"'),
  );
});

test('bring: not set up gives a clear message', async () => {
  const { t } = bringApp();
  const r = (await t.app.ops.invoke('bring.lists', {}, 'app')) as any;
  assert.match(r.error, /not set up/);
  assert.equal(
    ((await t.app.ops.invoke('bring.status', {}, 'app')) as any).result
      .connected,
    false,
  );
});

test('bring: lists, items with spec, recent, default list', async () => {
  const { t, m } = bringApp();
  await login(t);
  const lists = (await t.app.ops.invoke('bring.lists', {}, 'app')) as any;
  assert.deepEqual(lists.result, [
    { id: 'L1', name: 'Zuhause' },
    { id: 'L2', name: 'Party' },
  ]);
  const items = (await t.app.ops.invoke('bring.items', {}, 'app')) as any;
  assert.deepEqual(items.result, [
    { name: 'Brot', spec: '1 Stk' },
    { name: 'Käse' },
  ]);
  const rec = (await t.app.ops.invoke('bring.recent', {}, 'app')) as any;
  assert.deepEqual(rec.result, [{ name: 'Butter' }]);
  await t.app.ops.invoke('bring.set_default_list', { listId: 'L2' }, 'app');
  await t.app.ops.invoke('bring.items', {}, 'app');
  assert.ok(
    m.seen.some((s) => s.method === 'GET' && s.url.endsWith('/bringlists/L2')),
  );
  assert.ok(
    m.seen.find((s) => s.url.includes('/bringlists/'))!.headers
      .authorization === 'Bearer tok',
  );
});

test('bring: add and remove run at once, return Done line + inverse undo', async () => {
  const { t, m } = bringApp();
  await login(t);
  const add = (await t.app.ops.invoke(
    'bring.add',
    { item: 'Milch', spec: '2 l' },
    'agent',
  )) as any;
  assert.equal(add.text, 'Milch (2 l) hinzugefügt');
  assert.ok(add.undoHandle);
  const put = m.seen.find((s) => s.method === 'PUT')!;
  const f = new URLSearchParams(put.body);
  assert.equal(f.get('purchase'), 'Milch');
  assert.equal(f.get('specification'), '2 l');
  assert.ok(
    (
      ((await t.app.ops.invoke('bring.items', {}, 'app')) as any)
        .result as any[]
    ).some((i) => i.name === 'Milch'),
  );
  const u = await t.app.actions.undo(add.undoHandle.id);
  assert.ok(u.ok);
  assert.ok(
    !(
      ((await t.app.ops.invoke('bring.items', {}, 'app')) as any)
        .result as any[]
    ).some((i) => i.name === 'Milch'),
  );

  const rm = (await t.app.ops.invoke(
    'bring.remove',
    { item: 'Käse', locale: 'en' },
    'agent',
  )) as any;
  assert.equal(rm.text, 'Käse checked off');
  assert.equal(
    new URLSearchParams(
      m.seen.filter((s) => s.method === 'PUT').at(-1)!.body,
    ).get('recently'),
    'Käse',
  );
  await t.app.actions.undo(rm.undoHandle.id);
  assert.ok(
    (
      ((await t.app.ops.invoke('bring.items', {}, 'app')) as any)
        .result as any[]
    ).some((i) => i.name === 'Käse'),
  );
});

test('bring: agent tools exist (bring_lists, bring_items, bring_add, bring_remove, bring_recent)', async () => {
  const { t } = bringApp();
  await login(t);
  const names = t.app.tools.all().map((x) => x.name);
  for (const n of [
    'bring_lists',
    'bring_items',
    'bring_add',
    'bring_remove',
    'bring_recent',
  ])
    assert.ok(names.includes(n), n);
  const run = newRun();
  const r = await t.app.tools.call(
    'bring_add',
    { item: 'Eier' },
    { app: t.app, run },
  );
  assert.equal(r.text, 'Eier hinzugefügt');
  assert.ok(run.undo);
  assert.ok(!names.includes('bring_login'));
});

test('bring: expired session re-logs in once; API failure is clear', async () => {
  let calls = 0;
  const { t } = bringApp([
    {
      u: '/bringusers/U1/lists',
      res: () =>
        ++calls === 1 ? new Response('', { status: 401 }) : { lists: [] },
    },
  ]);
  await login(t);
  const r = (await t.app.ops.invoke('bring.lists', {}, 'app')) as any;
  assert.equal(r.ok, true);
  assert.equal(calls, 2);

  const t2 = makeApp({ fetch: async () => jsonResponse({}, 500) });
  registerIntegrations(t2.app);
  const id = (await login(t2)).result;
  assert.equal(id.ok, false);
  assert.match(id.error, /HTTP 500/);
});
