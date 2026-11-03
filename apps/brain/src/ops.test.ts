import assert from 'node:assert/strict';
import { test } from 'node:test';
import { handleMcp } from './server/mcp.ts';
import { answer, call, makeApp } from './testing/helpers.ts';

test('registry: every op has a name, group, schema and risk; app_only is HTTP-only', () => {
  const t = makeApp();
  const all = t.app.ops.describe('app');
  assert.ok(all.length > 60);
  const groups = new Set(all.map((o) => o.group));
  for (const g of [
    'status',
    'providers',
    'accounts',
    'bring',
    'mcp',
    'jobs',
    'memory',
    'skills',
    'scripts',
    'conversations',
    'inbox',
    'catchup',
    'settings',
    'privacy',
    'push',
    'dreaming',
    'admin_token',
  ]) {
    assert.ok(groups.has(g), 'missing group ' + g);
  }
  for (const o of all)
    assert.ok(
      ['free', 'tap', 'app_only'].includes(o.risk) &&
        o.inputSchema &&
        o.description,
      o.name,
    );
  const mcp = t.app.ops.describe('mcp').map((o) => o.name);
  const agent = t.app.tools.all().map((x) => x.name);
  for (const o of all.filter((x) => x.risk === 'app_only')) {
    assert.ok(!mcp.includes(o.name), o.name + ' in mcp');
    assert.ok(
      !agent.includes(o.name.replace('.', '_')),
      o.name + ' in agent tools',
    );
  }
  assert.ok(
    all.some(
      (o) => o.risk === 'app_only' && o.name === 'providers.set_credential',
    ),
  );
});

test('agent cannot call app_only ops', async () => {
  const t = makeApp();
  const r = await t.app.ops.invoke(
    'providers.set_credential',
    { provider: 'deepseek', apiKey: 'x' },
    'agent',
  );
  assert.deepEqual(r, {
    ok: false,
    error: 'providers.set_credential is only available in the app.',
  });
  assert.equal(t.app.secrets.has('provider.deepseek.api_key'), false);
  const viaTool = await t.app.tools.call(
    'providers_set_credential',
    { provider: 'deepseek', apiKey: 'x' },
    {
      app: t.app,
      run: { channel: 'job', locale: 'en', actions: [], status() {} },
    },
  );
  assert.match(viaTool.text, /Unknown tool/);
  const ok = await t.app.ops.invoke(
    'providers.set_credential',
    { provider: 'deepseek', apiKey: 'sk-1' },
    'app',
  );
  assert.equal(ok.ok, true);
  assert.equal(
    t.app.providers.status().find((p) => p.id === 'deepseek')!.configured,
    true,
  );
});

test('secrets are write-only and encrypted at rest', async () => {
  const t = makeApp();
  await t.app.ops.invoke(
    'secrets.set',
    { name: 'api.thing', value: 'super-secret-value' },
    'app',
  );
  const list = await t.app.ops.invoke('secrets.list', {}, 'app');
  assert.ok(list.ok);
  assert.ok(!JSON.stringify(list).includes('super-secret-value'));
  const raw = t.app.db.get<{ value: string }>(
    'SELECT value FROM secrets WHERE name=?',
    'api.thing',
  )!.value;
  assert.ok(!raw.includes('super-secret-value'));
  assert.equal(t.app.secrets.get('api.thing'), 'super-secret-value');
  assert.equal((await t.app.ops.invoke('secrets.list', {}, 'agent')).ok, false);
  await t.app.ops.invoke('secrets.delete', { name: 'api.thing' }, 'app');
  assert.equal(t.app.secrets.has('api.thing'), false);
});

test('tap ops: app runs them directly, agent only proposes; perform executes', async () => {
  const t = makeApp();
  const direct = await t.app.ops.invoke(
    'settings.set_safety',
    { key: 'shell.timeout_sec', value: 5 },
    'app',
  );
  assert.equal(direct.ok && !direct.proposed, true);
  assert.equal(t.app.settings.num('shell.timeout_sec'), 5);
  t.app.settings.set('shell.timeout_sec', 30);

  t.mock.script(
    call('settings_set_safety', { key: 'shell.timeout_sec', value: 600 }),
    answer('Ich habe es vorgeschlagen'),
  );
  t.app.settings.set('agent.op_tool_groups', ['settings']);
  const a = await t.app.ask({
    text: 'Erhöhe das Shell-Timeout',
    channel: 'phone',
    locale: 'de',
  });
  assert.equal(
    t.app.settings.num('shell.timeout_sec'),
    30,
    'nothing happened yet',
  );
  assert.equal(a.actions.length, 1);
  assert.equal(a.actions[0]!.target, 'server');
  assert.equal(a.actions[0]!.tool, 'op:settings.set_safety');
  const p = await t.app.actions.perform(a.actions[0]!.id);
  assert.equal(p.ok, true);
  assert.equal(t.app.settings.num('shell.timeout_sec'), 600);
  assert.ok(p.undoHandle, 'perform returns an undo');
  const u = await t.app.actions.undo(p.undoHandle!.id);
  assert.equal(u.ok, true);
  assert.equal(t.app.settings.num('shell.timeout_sec'), 30);
  assert.equal(
    (await t.app.actions.undo(p.undoHandle!.id)).ok,
    false,
    'undo is single use',
  );
});

test('settings.set refuses safety keys, set_safety refuses normal keys', async () => {
  const t = makeApp();
  assert.match(
    (
      (await t.app.ops.invoke(
        'settings.set',
        { key: 'shell.enabled', value: false },
        'app',
      )) as any
    ).error,
    /safety setting/,
  );
  assert.match(
    (
      (await t.app.ops.invoke(
        'settings.set_safety',
        { key: 'user.name', value: 'X' },
        'app',
      )) as any
    ).error,
    /not a safety/,
  );
  assert.equal(
    (
      await t.app.ops.invoke(
        'settings.set',
        { key: 'user.name', value: 'Jan Jaap' },
        'app',
      )
    ).ok,
    true,
  );
  assert.match(
    (
      (await t.app.ops.invoke(
        'settings.set',
        { key: 'user.name', value: 5 },
        'app',
      )) as any
    ).error,
    /expects string/,
  );
});

test('free ops return an undo handle: jobs, memory, skills, scripts', async () => {
  const t = makeApp();
  const j = await t.app.ops.invoke(
    'jobs.create',
    { name: 'Tee', prompt: 'p', schedule: 'daily at 08:30' },
    'agent',
  );
  assert.ok(j.ok && j.undoHandle);
  assert.equal(
    t.app.scheduler.list().filter((x) => x.kind === 'user').length,
    1,
  );
  await t.app.actions.undo(j.undoHandle!.id);
  assert.equal(
    t.app.scheduler.list().filter((x) => x.kind === 'user').length,
    0,
  );

  const m = await t.app.ops.invoke(
    'memory.remember',
    { text: 'Jan trinkt Tee' },
    'agent',
  );
  assert.ok(m.ok && m.undoHandle);
  const id = (m as any).result.id;
  const d = await t.app.ops.invoke('memory.delete', { id }, 'agent');
  assert.equal(t.app.memory.get(id), undefined);
  await t.app.actions.undo((d as any).undoHandle.id);
  assert.equal(t.app.memory.get(id)!.text, 'Jan trinkt Tee');

  const s = await t.app.ops.invoke(
    'skills.put',
    { name: 'a', content: '# A\none' },
    'agent',
  );
  await t.app.ops.invoke(
    'skills.put',
    { name: 'a', content: '# A\ntwo' },
    'agent',
  );
  assert.equal(t.app.skills.get('skill', 'a'), '# A\ntwo');
  assert.ok((s as any).undoHandle);
  const del = await t.app.ops.invoke(
    'scripts.put',
    { name: 'x.sh', content: 'echo 1' },
    'agent',
  );
  await t.app.actions.undo((del as any).undoHandle.id);
  assert.equal(t.app.skills.list('script').length, 0);
  assert.equal(
    (
      await t.app.ops.invoke(
        'skills.put',
        { name: '../evil', content: 'x' },
        'app',
      )
    ).ok,
    false,
  );
});

test('admin MCP: only non-app_only ops, tap ops propose, tools/call works', async () => {
  const t = makeApp();
  const tools = (await handleMcp(
    t.app,
    'admin',
    { jsonrpc: '2.0', id: 1, method: 'tools/list' },
    {},
  )) as any;
  const names: string[] = tools.result.tools.map((x: any) => x.name);
  assert.ok(names.includes('memory_remember') && names.includes('jobs_create'));
  assert.ok(
    !names.includes('providers_set_credential') &&
      !names.includes('secrets_set') &&
      !names.includes('admin_token_create'),
  );
  const r = (await handleMcp(
    t.app,
    'admin',
    {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: 'memory_remember', arguments: { text: 'via mcp' } },
    },
    {},
  )) as any;
  assert.equal(r.result.isError, false);
  assert.equal(t.app.memory.list()[0]!.text, 'via mcp');
  const tap = (await handleMcp(
    t.app,
    'admin',
    {
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: {
        name: 'settings_set_safety',
        arguments: { key: 'shell.enabled', value: false },
      },
    },
    {},
  )) as any;
  assert.match(tap.result.content[0].text, /Proposed/);
  assert.equal(t.app.settings.bool('shell.enabled'), true);
  const bad = (await handleMcp(
    t.app,
    'admin',
    {
      jsonrpc: '2.0',
      id: 4,
      method: 'tools/call',
      params: { name: 'secrets_set', arguments: {} },
    },
    {},
  )) as any;
  assert.equal(bad.result.isError, true);
  assert.equal(
    await handleMcp(
      t.app,
      'admin',
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      {},
    ),
    null,
  );
});

test('tools MCP exposes the agent tools (not `answer`) and attaches proposals to the run', async () => {
  const t = makeApp();
  const list = (await handleMcp(
    t.app,
    'tools',
    { jsonrpc: '2.0', id: 1, method: 'tools/list' },
    {},
  )) as any;
  const names: string[] = list.result.tools.map((x: any) => x.name);
  for (const n of [
    'weather',
    'location',
    'reminders',
    'shell',
    'web_fetch',
    'skill_load',
    'set_timer',
    'send_mail_reply',
    'create_calendar_event',
    'memory_remember',
    'inbox_list',
  ])
    assert.ok(names.includes(n), n);
  assert.ok(!names.includes('answer'));
  const run = {
    askId: 'ask-1',
    channel: 'phone' as const,
    locale: 'en' as const,
    actions: [] as any[],
    status() {},
  };
  t.app.runs.set('ask-1', run);
  await handleMcp(
    t.app,
    'tools',
    {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: 'set_timer', arguments: { minutes: 5 } },
    },
    { 'x-lotti-ask': 'ask-1' },
  );
  assert.equal(run.actions.length, 1);
});

test('mcp config ops: tap risk enforced, flags stored, stub client reports not implemented', async () => {
  const t = makeApp();
  const prop = await t.app.ops.invoke(
    'mcp.add',
    { name: 'fs', transport: 'stdio', command: 'npx' },
    'agent',
  );
  assert.ok(prop.ok && prop.proposed);
  assert.equal(
    ((await t.app.ops.invoke('mcp.list', {}, 'app')) as any).result.length,
    0,
  );
  const add = (await t.app.ops.invoke(
    'mcp.add',
    { name: 'fs', transport: 'stdio', command: 'npx', args: ['-y', 'x'] },
    'app',
  )) as any;
  const id = add.result.id;
  await t.app.ops.invoke(
    'mcp.set_tool_confirmation',
    { id, tool: 'read_file', needsConfirmation: false },
    'app',
  );
  const list = (await t.app.ops.invoke('mcp.list', {}, 'app')) as any;
  assert.deepEqual(list.result[0].toolFlags, {
    read_file: { needsConfirmation: false },
  });
  const test_ = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.equal(test_.result.ok, false);
  assert.match(test_.result.error, /not implemented/);
  assert.equal(
    ((await t.app.ops.invoke('mcp.delete', { id }, 'agent')) as any).proposed
      .target,
    'server',
  );
});

test('bring and accounts stubs', async () => {
  const t = makeApp();
  assert.deepEqual(
    ((await t.app.ops.invoke('bring.status', {}, 'app')) as any).result,
    { connected: false },
  );
  assert.match(
    ((await t.app.ops.invoke('bring.add', { item: 'Milch' }, 'app')) as any)
      .error,
    /not installed/,
  );
  const acc = (await t.app.ops.invoke(
    'accounts.add',
    { kind: 'google', label: 'Privat' },
    'app',
  )) as any;
  await t.app.ops.invoke(
    'accounts.set_credential',
    { id: acc.result.id, key: 'refresh_token', value: 'r' },
    'app',
  );
  const chk = (await t.app.ops.invoke(
    'accounts.check',
    { id: acc.result.id },
    'app',
  )) as any;
  assert.equal(chk.result.ok, false);
  assert.ok(
    !JSON.stringify(
      await t.app.ops.invoke('accounts.list', {}, 'app'),
    ).includes('"r"'),
  );
  await t.app.ops.invoke('accounts.delete', { id: acc.result.id }, 'app');
  assert.equal(t.app.secrets.list('account.').length, 0);
  t.app.integrations.bring = {
    lists: async () => [],
    items: async () => [],
    add: async () => ({ ok: true, text: 'Milch hinzugefügt' }),
    remove: async () => ({ ok: true, text: 'weg' }),
  };
  const b = (await t.app.ops.invoke(
    'bring.add',
    { item: 'Milch' },
    'agent',
  )) as any;
  assert.ok(b.undoHandle);
});

test('validation errors are reported, not thrown', async () => {
  const t = makeApp();
  const r = (await t.app.ops.invoke(
    'jobs.create',
    { name: 'x' },
    'app',
  )) as any;
  assert.equal(r.ok, false);
  assert.match(r.error, /Invalid input/);
  assert.match(
    ((await t.app.ops.invoke('nope.nope', {}, 'app')) as any).error,
    /Unknown operation/,
  );
});
