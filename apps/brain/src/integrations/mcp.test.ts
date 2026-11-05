import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mock, test } from 'node:test';
import { buildSystemPrompt } from '../agent/prompt.ts';
import { makeApp, text } from '../testing/helpers.ts';
import { newRun } from '../tools/registry.ts';
import { handleMcp } from '../server/mcp.ts';
import { registerIntegrations } from './register.ts';
import { mockFetch } from './testing.ts';

/** A tiny MCP server over stdio (newline-delimited JSON-RPC): tools `echo` and `fail`. */
const SERVER = `
import { createInterface } from 'node:readline';
const rl = createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...m }) + '\\n');
rl.on('line', (line) => {
  const m = JSON.parse(line);
  if (m.method === 'initialize') send({ id: m.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'mock', version: '1' } } });
  else if (m.method === 'tools/list') send({ id: m.id, result: { tools: [
    { name: 'echo', description: 'Echo text', inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } },
    { name: 'fail', description: 'Always fails', inputSchema: { type: 'object' } } ] } });
  else if (m.method === 'tools/call') {
    if (m.params.name === 'echo') send({ id: m.id, result: { content: [{ type: 'text', text: 'echo:' + m.params.arguments.text + ':' + (process.env.MOCK_TOKEN ?? '') + ':' + (process.env.MASTER_KEY ?? 'nokey') }] } });
    else send({ id: m.id, result: { isError: true, content: [{ type: 'text', text: 'boom' }] } });
  }
});
`;

async function stdioApp() {
  const dir = mkdtempSync(join(tmpdir(), 'mock-mcp-'));
  const file = join(dir, 'server.mjs');
  writeFileSync(file, SERVER);
  const t = makeApp();
  registerIntegrations(t.app);
  const r = (await t.app.ops.invoke(
    'mcp.add',
    {
      name: 'My Server',
      transport: 'stdio',
      command: process.execPath,
      args: [file],
    },
    'app',
  )) as any;
  return { t, id: r.result.id as string };
}
/** Wait for the refreshes the ops started: refreshes are serialised, so a new one ends after all earlier ones. */
const settle = (t: ReturnType<typeof makeApp>) =>
  t.app.integrations.mcp.refresh!();

test('mcp stdio: test connection lists tools; mcp.tools shows confirmation flags', async () => {
  const { t, id } = await stdioApp();
  const r = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.deepEqual(r.result, {
    ok: true,
    tools: ['echo', 'fail'],
    authRequired: false,
    signedIn: false,
  });
  const tools = (await t.app.ops.invoke('mcp.tools', { id }, 'app')) as any;
  assert.deepEqual(
    tools.result.map((x: any) => [x.name, x.needsConfirmation]),
    [
      ['echo', true],
      ['fail', true],
    ],
  );
  const list = (await t.app.ops.invoke('mcp.list', {}, 'app')) as any;
  assert.equal(list.result[0].status, 'ok');
});

test('mcp stdio: remote tools are registered as mcp__server__tool; confirmation gates the call', async () => {
  const { t, id } = await stdioApp();
  await t.app.ops.invoke('mcp.test', { id }, 'app');
  await settle(t);
  const names = t.app.tools.all().map((x) => x.name);
  assert.ok(names.includes('mcp__My_Server__echo'));
  const spec = t.app.tools
    .specs(t.app.tools.all())
    .find((s) => s.name === 'mcp__My_Server__echo')!;
  assert.deepEqual((spec.parameters as any).required, ['text']);
  // also listed in /mcp/tools with its own schema
  const l: any = await handleMcp(
    t.app,
    'tools',
    { jsonrpc: '2.0', id: 1, method: 'tools/list' },
    {},
  );
  assert.ok(
    l.result.tools.find((x: any) => x.name === 'mcp__My_Server__echo')
      .inputSchema.properties.text,
  );

  // default: needs confirmation -> proposal, nothing runs
  const run = newRun();
  const r = await t.app.tools.call(
    'mcp__My_Server__echo',
    { text: 'hi' },
    { app: t.app, run },
  );
  assert.match(r.text, /Proposed/);
  assert.equal(run.actions.length, 1);
  assert.equal(run.actions[0]!.tool, 'mcp__My_Server__echo');
  const out = await t.app.actions.perform(run.actions[0]!.id);
  assert.ok(out.ok, out.text);
  assert.match(out.text, /^echo:hi:/);
  assert.ok(
    out.text.endsWith(':nokey'),
    'backend secrets must not reach the server env',
  );

  // flag off -> runs at once
  await t.app.ops.invoke(
    'mcp.set_tool_confirmation',
    { id, tool: 'echo', needsConfirmation: false },
    'app',
  );
  await settle(t);
  const run2 = newRun();
  const r2 = await t.app.tools.call(
    'mcp__My_Server__echo',
    { text: 'direct' },
    { app: t.app, run: run2 },
  );
  assert.match(r2.text, /^echo:direct/);
  assert.equal(run2.actions.length, 0);

  // tool errors surface as errors
  await t.app.ops.invoke(
    'mcp.set_tool_confirmation',
    { id, tool: 'fail', needsConfirmation: false },
    'app',
  );
  await settle(t);
  const r3 = await t.app.tools.call(
    'mcp__My_Server__fail',
    {},
    { app: t.app, run: newRun() },
  );
  assert.equal(r3.ok, false);
  assert.match(r3.text, /boom/);

  // delete removes the tools
  await t.app.ops.invoke('mcp.delete', { id }, 'app');
  await settle(t);
  assert.ok(!t.app.tools.all().some((x) => x.name.startsWith('mcp__')));
  assert.equal(
    t.app.actions.hasHandler('mcp__My_Server__echo'),
    false,
    'perform handlers go with the tools',
  );
});

test('mcp stdio: env secret reaches the server; set_credential is app only', async () => {
  const { t, id } = await stdioApp();
  assert.match(
    (
      (await t.app.ops.invoke(
        'mcp.set_credential',
        { id, key: 'env.MOCK_TOKEN', value: 's3' },
        'agent',
      )) as any
    ).error,
    /only available in the app/,
  );
  await t.app.ops.invoke(
    'mcp.set_credential',
    { id, key: 'env.MOCK_TOKEN', value: 's3' },
    'app',
  );
  await t.app.ops.invoke(
    'mcp.set_tool_confirmation',
    { id, tool: 'echo', needsConfirmation: false },
    'app',
  );
  await settle(t);
  const r = await t.app.tools.call(
    'mcp__My_Server__echo',
    { text: 'x' },
    { app: t.app, run: newRun() },
  );
  assert.match(r.text, /^echo:x:s3:nokey/);
});

test('mcp stdio: broken command reports a clear error', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const r = (await t.app.ops.invoke(
    'mcp.add',
    { name: 'Broken', transport: 'stdio', command: '/nonexistent/server' },
    'app',
  )) as any;
  const x = (await t.app.ops.invoke(
    'mcp.test',
    { id: r.result.id },
    'app',
  )) as any;
  assert.equal(x.result.ok, false);
  assert.match(x.result.error, /Cannot start/);
});

test('mcp http: JSON and SSE replies, bearer token, session id', async () => {
  let sid = 0;
  const m = mockFetch([
    {
      m: 'POST',
      u: 'https://mcp.example/rpc',
      res: (r) => {
        const b = JSON.parse(r.body);
        if (b.method === 'notifications/initialized')
          return new Response('', { status: 202 });
        if (b.method === 'initialize')
          return new Response(
            JSON.stringify({ jsonrpc: '2.0', id: b.id, result: {} }),
            {
              headers: {
                'content-type': 'application/json',
                'mcp-session-id': 'S' + ++sid,
              },
            },
          );
        if (b.method === 'tools/list')
          return new Response(
            `event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', id: b.id, result: { tools: [{ name: 'now', description: 'Time', inputSchema: { type: 'object' } }] } })}\n\n`,
            { headers: { 'content-type': 'text/event-stream' } },
          );
        return new Response(
          JSON.stringify({
            jsonrpc: '2.0',
            id: b.id,
            result: { content: [{ type: 'text', text: 'noon' }] },
          }),
          { headers: { 'content-type': 'application/json' } },
        );
      },
    },
    {
      m: 'DELETE',
      u: 'https://mcp.example/rpc',
      res: () => new Response('', { status: 200 }),
    },
  ]);
  const t = makeApp({ fetch: m.fetch });
  registerIntegrations(t.app);
  const id = (
    (await t.app.ops.invoke(
      'mcp.add',
      { name: 'web', transport: 'http', url: 'https://mcp.example/rpc' },
      'app',
    )) as any
  ).result.id;
  await t.app.ops.invoke(
    'mcp.set_credential',
    { id, key: 'bearer', value: 'tok' },
    'app',
  );
  await settle(t);
  m.seen.length = 0;
  const r = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.deepEqual(r.result, {
    ok: true,
    tools: ['now'],
    authRequired: false,
    signedIn: false,
  });
  assert.equal(m.seen[0]!.headers.authorization, 'Bearer tok');
  assert.match(m.seen[1]!.headers['mcp-session-id']!, /^S\d+$/);
  const out = await t.app.integrations.mcp.callTool(
    {
      id,
      name: 'web',
      transport: 'http',
      url: 'https://mcp.example/rpc',
      args: [],
      enabled: true,
      toolFlags: {},
    },
    'now',
    {},
  );
  assert.equal(out, 'noon');
});

test('mcp http: auth failure is clear', async () => {
  const t = makeApp({ fetch: async () => new Response('', { status: 401 }) });
  registerIntegrations(t.app);
  const id = (
    (await t.app.ops.invoke(
      'mcp.add',
      { name: 'web', transport: 'http', url: 'https://mcp.example/rpc' },
      'app',
    )) as any
  ).result.id;
  const r = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.match(r.result.error, /bearer token/);
});

test('refresh keeps the old tools until the new set is ready (no "unknown tool" window) and rejects duplicate names', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const stdio = (name: string) => ({
    name,
    transport: 'stdio' as const,
    command: process.execPath,
    args: [
      '-e',
      `const rl=require('readline').createInterface({input:process.stdin});rl.on('line',l=>{const m=JSON.parse(l);const s=o=>console.log(JSON.stringify(o));if(m.method==='initialize')s({jsonrpc:'2.0',id:m.id,result:{protocolVersion:'2025-03-26',capabilities:{tools:{}},serverInfo:{name:'x',version:'1'}}});else if(m.method==='tools/list')setTimeout(()=>s({jsonrpc:'2.0',id:m.id,result:{tools:[{name:'echo',inputSchema:{type:'object'}}]}}),300)})`,
    ],
  });
  const add = await t.app.ops.invoke('mcp.add', stdio('slow'), 'app');
  assert.equal(add.ok, true);
  await t.app.integrations.mcp.refresh!();
  assert.ok(t.app.tools.get('mcp__slow__echo'));
  const dup = await t.app.ops.invoke('mcp.add', stdio('slow'), 'app');
  assert.equal(dup.ok, false);
  assert.match((dup as { error: string }).error, /already exists/);
  const p = t.app.integrations.mcp.refresh!();
  assert.ok(t.app.tools.get('mcp__slow__echo'), 'still there while refreshing');
  await p;
  assert.ok(t.app.tools.get('mcp__slow__echo'));
});

test('mcp http: a non-MCP reply gives a readable error without echoing the body', async () => {
  const t = makeApp({
    fetch: async () =>
      new Response('BEGIN:VCALENDAR secret-body', {
        status: 200,
        headers: { 'content-type': 'text/calendar' },
      }),
  });
  registerIntegrations(t.app);
  const id = (
    (await t.app.ops.invoke(
      'mcp.add',
      { name: 'ics', transport: 'http', url: 'https://mcp.example/cal.ics' },
      'app',
    )) as any
  ).result.id;
  const r = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.match(r.result.error, /did not answer like an MCP server/);
  assert.ok(!r.result.error.includes('secret-body'));
});

test('mcp http: an unreachable server does not echo the URL query (it may hold a token)', async () => {
  const t = makeApp({
    fetch: async () => {
      throw new TypeError('fetch failed');
    },
  });
  registerIntegrations(t.app);
  const id = (
    (await t.app.ops.invoke(
      'mcp.add',
      {
        name: 'q',
        transport: 'http',
        url: 'https://mcp.example/rpc?token=SECRETKEY',
      },
      'app',
    )) as any
  ).result.id;
  const r = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.match(
    r.result.error,
    /Cannot reach the MCP server at https:\/\/mcp\.example\/rpc:/,
  );
  assert.ok(!JSON.stringify(r).includes('SECRETKEY'));
});

test('/mcp/tools: a proposal with no live ask is parked in the inbox, one with a live ask rides on it', async () => {
  const { t, id } = await stdioApp();
  await t.app.ops.invoke('mcp.test', { id }, 'app');
  await settle(t);
  const rpc = (headers: Record<string, string>) =>
    handleMcp(
      t.app,
      'tools',
      {
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: { name: 'mcp__My_Server__echo', arguments: { text: 'hi' } },
      },
      headers,
    ) as Promise<any>;

  const lost = await rpc({ 'x-lotti-ask': 'gone' });
  assert.match(lost.result.content[0].text, /inbox/);
  const items = t.app.inbox.full().items;
  assert.equal(items.length, 1);
  assert.equal(items[0]!.actions?.[0]?.tool, 'mcp__My_Server__echo');

  const run = newRun();
  t.app.runs.set('live', run);
  const live = await rpc({ 'x-lotti-ask': 'live' });
  assert.doesNotMatch(live.result.content[0].text, /inbox/);
  assert.equal(run.actions.length, 1);
  assert.equal(t.app.inbox.full().items.length, 1, 'nothing else parked');
});

test('a server that was down at boot is retried, and the model is told while it is down', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'mock-mcp-'));
  const file = join(dir, 'late.mjs');
  const t = makeApp();
  registerIntegrations(t.app);
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    await t.app.ops.invoke(
      'mcp.add',
      {
        name: 'Late',
        transport: 'stdio',
        command: process.execPath,
        args: [file],
      },
      'app',
    );
    await settle(t);
    assert.ok(!t.app.tools.all().some((x) => x.name.startsWith('mcp__')));
    t.mock.script(text('Home Assistant ist nicht erreichbar.'));
    await t.app.ask({ text: 'Tür auf', channel: 'phone', locale: 'de' });
    const sys = t.mock.calls[0]!.messages[0] as any;
    assert.match(sys.content, /unreachable right now.*Late \(/);

    writeFileSync(file, SERVER); // it comes up
    mock.timers.tick(30_000);
    await settle(t); // refreshes run in order: ends after the retry's
    assert.ok(t.app.tools.get('mcp__Late__echo'), 'registered by the retry');
    assert.equal(
      buildSystemPrompt({
        now: 0,
        locale: 'en',
        channel: 'phone',
        userName: 'Jan',
        memories: [],
        skillIndex: '',
        conversationSummary: null,
      }).includes('unreachable'),
      false,
    );
  } finally {
    mock.timers.reset();
  }
});

test('mcp: a server that needs a sign-in is not retried on a timer', async () => {
  const t = makeApp({
    fetch: async () => new Response('', { status: 401 }),
  });
  registerIntegrations(t.app);
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    await t.app.ops.invoke(
      'mcp.add',
      { name: 'Locked', transport: 'http', url: 'https://mcp.example/rpc' },
      'app',
    );
    await settle(t);
    const list = (await t.app.ops.invoke('mcp.list', {}, 'app')) as any;
    assert.equal(list.result[0].authRequired, true);
    const calls = t.fetchCalls.length;
    mock.timers.tick(600_000);
    await settle(t);
    // Only the explicit settle() refresh ran again; no timer-driven one.
    assert.ok(t.fetchCalls.length - calls <= 1);
  } finally {
    mock.timers.reset();
  }
});
