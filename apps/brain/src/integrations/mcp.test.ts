import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { makeApp } from '../testing/helpers.ts';
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
const settle = () => new Promise((r) => setTimeout(r, 400));

test('mcp stdio: test connection lists tools; mcp.tools shows confirmation flags', async () => {
  const { t, id } = await stdioApp();
  const r = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.deepEqual(r.result, { ok: true, tools: ['echo', 'fail'] });
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
  await settle();
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
  await settle();
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
  await settle();
  const r3 = await t.app.tools.call(
    'mcp__My_Server__fail',
    {},
    { app: t.app, run: newRun() },
  );
  assert.equal(r3.ok, false);
  assert.match(r3.text, /boom/);

  // delete removes the tools
  await t.app.ops.invoke('mcp.delete', { id }, 'app');
  await settle();
  assert.ok(!t.app.tools.all().some((x) => x.name.startsWith('mcp__')));
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
  await settle();
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
  await settle();
  m.seen.length = 0;
  const r = (await t.app.ops.invoke('mcp.test', { id }, 'app')) as any;
  assert.deepEqual(r.result, { ok: true, tools: ['now'] });
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
