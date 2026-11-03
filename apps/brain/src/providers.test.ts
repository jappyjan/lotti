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
  assert.equal(body.model, 'deepseek-chat');
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
    { provider: 'deepseek', model: 'deepseek-reasoner' },
    'app',
  );
  await t.app.providers.complete([{ role: 'user', content: 'x' }], []);
  assert.equal(JSON.parse(seen!.init.body).model, 'deepseek-reasoner');
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
  assert.equal(req.askId, 'ask-9');
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
