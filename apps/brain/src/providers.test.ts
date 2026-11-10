import assert from 'node:assert/strict';
import { test } from 'node:test';
import { toAnthropic } from './providers/anthropic.ts';
import { jsonResponse, makeApp } from './testing/helpers.ts';
import { z } from 'zod';
import { jsonSchemaOf } from './ops/registry.ts';

const tools = [
  {
    name: 'weather',
    description: 'w',
    parameters: jsonSchemaOf(z.object({ place: z.string().optional() })),
  },
];

test('DeepSeek: OpenAI-compatible request, default model, tool calls parsed', async () => {
  let seen: { url: string; init: any } | undefined;
  const t = makeApp({
    fetch: async (url, init) => {
      seen = { url: String(url), init };
      return jsonResponse({
        choices: [
          {
            message: {
              content: null,
              tool_calls: [
                {
                  id: 'c1',
                  type: 'function',
                  function: {
                    name: 'weather',
                    arguments: '{"place":"Hamburg"}',
                  },
                },
              ],
            },
          },
        ],
      });
    },
  });
  t.app.settings.set('provider.active', 'deepseek');
  assert.equal(
    t.app.providers.status().find((p) => p.id === 'deepseek')!.configured,
    false,
  );
  await assert.rejects(
    t.app.providers.complete([{ role: 'user', content: 'hi' }], []),
    /not configured/,
  );
  t.app.secrets.set('provider.deepseek.api_key', 'sk-test');
  const r = await t.app.providers.complete(
    [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'Wetter?' },
      {
        role: 'assistant',
        content: '',
        toolCalls: [{ id: 'p', name: 'weather', args: { place: 'X' } }],
      },
      { role: 'tool', toolCallId: 'p', name: 'weather', content: 'sonnig' },
    ],
    tools,
  );
  assert.equal(seen!.url, 'https://api.deepseek.com/chat/completions');
  assert.equal(seen!.init.headers.authorization, 'Bearer sk-test');
  const body = JSON.parse(seen!.init.body);
  assert.equal(body.model, 'deepseek-flash');
  assert.deepEqual(
    body.thinking,
    { type: 'disabled' },
    'thinking off by default',
  );
  assert.deepEqual(body.messages[2], {
    role: 'assistant',
    content: null,
    tool_calls: [
      {
        id: 'p',
        type: 'function',
        function: { name: 'weather', arguments: '{"place":"X"}' },
      },
    ],
  });
  assert.deepEqual(body.messages[3], {
    role: 'tool',
    tool_call_id: 'p',
    content: 'sonnig',
  });
  assert.equal(body.tools[0].function.name, 'weather');
  assert.deepEqual(r.toolCalls, [
    { id: 'c1', name: 'weather', args: { place: 'Hamburg' } },
  ]);
  // model ids are editable via settings (op)
  await t.app.ops.invoke(
    'providers.set_model',
    { provider: 'deepseek', model: 'deepseek-v4-pro' },
    'app',
  );
  await t.app.providers.complete([{ role: 'user', content: 'x' }], []);
  assert.equal(JSON.parse(seen!.init.body).model, 'deepseek-v4-pro');
  assert.ok(
    !('tools' in JSON.parse(seen!.init.body)),
    'no tools key when none given',
  );
  assert.ok(
    t.app.providers.status().find((p) => p.id === 'deepseek')!.lastOkAt,
  );
});

test('HTTP errors become provider status and trigger fallback', async () => {
  const t = makeApp({
    fetch: async (url) =>
      String(url).includes('deepseek')
        ? new Response('overloaded', { status: 503 })
        : jsonResponse({ choices: [{ message: { content: 'von OpenAI' } }] }),
  });
  t.app.secrets.set('provider.deepseek.api_key', 'a');
  t.app.secrets.set('provider.openai.api_key', 'b');
  await t.app.ops.invoke(
    'providers.set_active',
    { active: 'deepseek', fallback: 'openai' },
    'app',
  );
  const r = await t.app.providers.complete(
    [{ role: 'user', content: 'x' }],
    [],
  );
  assert.equal(r.text, 'von OpenAI');
  assert.equal(r.providerId, 'openai');
  const s = t.app.providers.status();
  assert.match(s.find((p) => p.id === 'deepseek')!.lastError!, /HTTP 503/);
  assert.equal(s.find((p) => p.id === 'deepseek')!.active, true);
  assert.equal(s.find((p) => p.id === 'openai')!.fallback, true);
});

test('Anthropic: Messages API mapping (system, tool_use, tool_result merging)', async () => {
  let body: any;
  let headers: any;
  const t = makeApp({
    fetch: async (_u, init) => {
      body = JSON.parse((init as any).body);
      headers = (init as any).headers;
      return jsonResponse({
        content: [
          { type: 'text', text: 'Moment' },
          {
            type: 'tool_use',
            id: 'tu1',
            name: 'weather',
            input: { place: 'Rom' },
          },
        ],
      });
    },
  });
  t.app.secrets.set('provider.anthropic.api_key', 'sk-ant');
  t.app.settings.set('provider.active', 'anthropic');
  const r = await t.app.providers.complete(
    [
      { role: 'system', content: 'S' },
      { role: 'user', content: 'Q' },
      {
        role: 'assistant',
        content: 'ok',
        toolCalls: [
          { id: 'a', name: 'weather', args: {} },
          { id: 'b', name: 'weather', args: {} },
        ],
      },
      { role: 'tool', toolCallId: 'a', name: 'weather', content: 'r1' },
      { role: 'tool', toolCallId: 'b', name: 'weather', content: 'r2' },
    ],
    tools,
  );
  assert.equal(headers['x-api-key'], 'sk-ant');
  assert.equal(headers['anthropic-version'], '2023-06-01');
  assert.equal(body.model, 'claude-sonnet-5-5');
  assert.equal(body.system, 'S');
  assert.equal(body.tools[0].input_schema.type, 'object');
  assert.deepEqual(
    body.messages.map((m: any) => m.role),
    ['user', 'assistant', 'user'],
  );
  assert.deepEqual(
    body.messages[2].content.map((c: any) => c.type),
    ['tool_result', 'tool_result'],
  );
  assert.deepEqual(r, {
    text: 'Moment',
    toolCalls: [{ id: 'tu1', name: 'weather', args: { place: 'Rom' } }],
    providerId: 'anthropic',
  });
  assert.equal(
    toAnthropic([
      { role: 'user', content: 'a' },
      { role: 'user', content: 'b' },
    ]).messages.length,
    1,
  );
});

test('agent-runtime providers are stubs that report not configured', async () => {
  const t = makeApp();
  const st = t.app.providers.status();
  for (const id of ['codex', 'claude_code']) {
    const p = st.find((x) => x.id === id)!;
    assert.deepEqual([p.kind, p.configured], ['agent-runtime', false]);
  }
  t.app.settings.set('provider.active', 'codex');
  await assert.rejects(
    t.app.ask({ text: 'x', channel: 'phone', locale: 'en' }),
    /not implemented/,
  );
});

test('an agent-runtime provider gets the MCP tools URL + internal token and its answer is used', async () => {
  const t = makeApp();
  let req: any;
  t.app.providers.register({
    kind: 'agent-runtime',
    id: 'fake_rt',
    label: 'Fake',
    defaultModel: '',
    knownModels: [],
    configured: () => true,
    async run(r) {
      req = r;
      return { text: '{"text":"vom Runtime","followUps":["f"]}' };
    },
  });
  t.app.settings.set('provider.active', 'fake_rt');
  const a = await t.app.ask({
    text: 'Hallo',
    channel: 'phone',
    locale: 'de',
    askId: 'ask-9',
  });
  assert.equal(a.text, 'vom Runtime');
  assert.deepEqual(a.followUps, ['f']);
  assert.equal(
    req.mcpServers[0].url,
    `http://127.0.0.1:${t.app.config.port}/mcp/tools`,
  );
  assert.equal(req.mcpServers[0].bearerToken, t.app.auth.internalToken());
  assert.match(
    req.askId,
    /^ask-9_\w+$/,
    'unique per run, derived from the ask id',
  );
  assert.match(req.system, /Lotti/);
});

test('providers.models falls back to suggestions', async () => {
  const t = makeApp();
  const r = (await t.app.ops.invoke(
    'providers.models',
    { provider: 'anthropic' },
    'app',
  )) as any;
  assert.equal(r.result.source, 'suggested');
  assert.ok(r.result.models.includes('claude-sonnet-5-5'));
});

test('providers.models: live list always includes the suggestions', async () => {
  const t = makeApp({
    fetch: async () =>
      jsonResponse({ data: [{ id: 'deepseek-chat' }, { id: 'deepseek-x' }] }),
  });
  t.app.secrets.set('provider.deepseek.api_key', 'sk-test');
  const r = (await t.app.ops.invoke(
    'providers.models',
    { provider: 'deepseek' },
    'app',
  )) as any;
  assert.equal(r.result.source, 'live');
  assert.deepEqual(
    r.result.models.filter((m: string) => m.startsWith('deepseek-v4')),
    ['deepseek-v4-pro'],
  );
  assert.ok(r.result.models.includes('deepseek-flash'));
  assert.ok(r.result.models.includes('deepseek-x'));
  assert.equal(new Set(r.result.models).size, r.result.models.length);
});

test('a saved DeepSeek model is kept when the default changes; retired ids mean the current Flash', () => {
  const t = makeApp();
  t.app.settings.set('provider.deepseek.model', 'deepseek-v4-pro');
  assert.equal(t.app.providers.modelFor('deepseek'), 'deepseek-v4-pro');
  for (const old of [
    'deepseek-chat',
    'deepseek-reasoner',
    'deepseek-v4-flash',
  ]) {
    t.app.settings.set('provider.deepseek.model', old);
    assert.equal(t.app.providers.modelFor('deepseek'), 'deepseek-flash');
  }
});

test('DeepSeek thinking: effort setting, reasoning_content sent back with tool calls', async () => {
  const bodies: any[] = [];
  const t = makeApp({
    fetch: async (_url, init) => {
      bodies.push(JSON.parse(String(init!.body)));
      return jsonResponse({
        choices: [
          {
            message: {
              content: 'ok',
              reasoning_content: 'thought',
              tool_calls: [
                {
                  id: 'c1',
                  type: 'function',
                  function: { name: 'weather', arguments: '{}' },
                },
              ],
            },
          },
        ],
      });
    },
  });
  t.app.settings.set('provider.active', 'deepseek');
  t.app.secrets.set('provider.deepseek.api_key', 'sk-test');
  assert.equal(
    t.app.providers.status().find((p) => p.id === 'deepseek')!.thinking,
    'off',
  );
  await t.app.ops.invoke(
    'providers.set_thinking',
    { provider: 'deepseek', level: 'high' },
    'app',
  );
  const r = await t.app.providers.complete(
    [
      { role: 'user', content: 'Wetter?' },
      {
        role: 'assistant',
        content: '',
        reasoning: 'earlier',
        toolCalls: [{ id: 'p', name: 'weather', args: {} }],
      },
      { role: 'tool', toolCallId: 'p', name: 'weather', content: 'sonnig' },
    ],
    tools,
  );
  assert.equal(r.reasoning, 'thought');
  assert.deepEqual(bodies[0].thinking, { type: 'enabled' });
  assert.equal(bodies[0].reasoning_effort, 'high');
  assert.equal(bodies[0].messages[1].reasoning_content, 'earlier');
  assert.throws(() =>
    t.app.settings.set('provider.deepseek.thinking', 'medium'),
  );
  // another OpenAI-compatible endpoint gets no DeepSeek-only fields
  t.app.settings.set('provider.deepseek.base_url', 'https://llm.example/v1');
  await t.app.providers.complete([{ role: 'user', content: 'x' }], []);
  assert.ok(!('thinking' in bodies[1]) && !('reasoning_effort' in bodies[1]));
});

const key = process.env.DEEPSEEK_API_KEY;
test(
  'LIVE DeepSeek: plain answer and a tool call',
  { skip: key ? false : 'set DEEPSEEK_API_KEY to run', timeout: 60_000 },
  async () => {
    const t = makeApp({ fetch: globalThis.fetch });
    t.app.secrets.set('provider.deepseek.api_key', key!);
    t.app.settings.set('provider.active', 'deepseek');
    const plain = await t.app.providers.complete(
      [{ role: 'user', content: 'Reply with the single word OK.' }],
      [],
    );
    assert.match(plain.text, /ok/i);
    const withTool = await t.app.providers.complete(
      [
        {
          role: 'user',
          content: 'What is the weather in Hamburg? Use the tool.',
        },
      ],
      tools,
    );
    assert.equal(withTool.toolCalls[0]?.name, 'weather');
  },
);

test('text(): with a subscription runtime active, background work uses a configured chat provider, else the runtime without tools, else a clear error + status warning', async () => {
  const t = makeApp();
  const reqs: any[] = [];
  let rtConfigured = true;
  t.app.providers.register({
    kind: 'agent-runtime',
    id: 'fake_rt',
    label: 'Fake',
    defaultModel: '',
    knownModels: [],
    configured: () => rtConfigured,
    async run(r) {
      reqs.push(r);
      return { text: ' vom Runtime ' };
    },
  });
  t.app.settings.set('provider.active', 'fake_rt'); // no fallback set
  t.mock.script({ text: 'Zusammenfassung', toolCalls: [] });
  assert.equal(await t.app.providers.text('sys', 'user'), 'Zusammenfassung');
  assert.equal(t.mock.calls[0]!.opts.signal instanceof AbortSignal, true);
  assert.equal(reqs.length, 0, 'chat provider preferred');

  t.mock.isConfigured = false;
  assert.equal(await t.app.providers.text('sys', 'user'), 'vom Runtime');
  assert.deepEqual(reqs[0].mcpServers, [], 'no tools');
  assert.equal(reqs[0].system, 'sys');

  rtConfigured = false;
  await assert.rejects(t.app.providers.text('sys', 'user'), /API-key provider/);
  const st = t.app.providers.status().find((p) => p.id === 'fake_rt')!;
  assert.match(st.warning!, /Background tasks/);
  t.mock.isConfigured = true;
  assert.equal(
    t.app.providers.status().find((p) => p.id === 'fake_rt')!.warning,
    undefined,
  );
});

test('text() times out (default 45 s) instead of hanging background work', async () => {
  const t = makeApp();
  const { hang } = await import('./testing/helpers.ts');
  t.mock.script(hang);
  await assert.rejects(
    t.app.providers.text('s', 'u', undefined, 30),
    /timed out/,
  );
  const { TEXT_TIMEOUT_MS } = await import('./providers/registry.ts');
  assert.equal(TEXT_TIMEOUT_MS, 45_000);
});
