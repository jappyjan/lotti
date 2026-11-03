import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  WsClient,
  makeApp,
  pairDevice,
  startServer,
} from './testing/helpers.ts';

const base = (port: number) => `http://127.0.0.1:${port}`;
const j = (body: unknown, token?: string) => ({
  method: 'POST',
  headers: {
    'content-type': 'application/json',
    ...(token ? { authorization: `Bearer ${token}` } : {}),
  },
  body: JSON.stringify(body),
});

test('startup code, pairing is single use, token stored hashed', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    assert.deepEqual(await (await fetch(base(srv.port) + '/health')).json(), {
      ok: true,
    });
    const code = t.app.auth.ensureStartupCode()!;
    assert.match(code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    assert.equal(t.app.auth.ensureStartupCode(), code, 'same code until used');
    assert.equal(
      (
        await fetch(
          base(srv.port) + '/api/v1/pair',
          j({ code: 'AAAA-BBBB', deviceName: 'x' }),
        )
      ).status,
      401,
    );
    const res = await fetch(
      base(srv.port) + '/api/v1/pair',
      j({ code, deviceName: 'Jans iPhone' }),
    );
    assert.equal(res.status, 200);
    const { token } = (await res.json()) as { token: string };
    assert.ok(token.startsWith('lt_'));
    assert.equal(
      (
        await fetch(
          base(srv.port) + '/api/v1/pair',
          j({ code, deviceName: 'again' }),
        )
      ).status,
      401,
      'code is single use',
    );
    assert.ok(
      !JSON.stringify(t.app.db.all('SELECT * FROM devices')).includes(token),
      'token is not stored in clear',
    );
    assert.equal(
      t.app.auth.ensureStartupCode(),
      undefined,
      'no code once a device is paired',
    );
    assert.equal(t.app.auth.devices()[0]!.name, 'Jans iPhone');
  } finally {
    await srv.close();
  }
});

test('API needs a device token; ops list and call', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const token = pairDevice(t.app);
    assert.equal((await fetch(base(srv.port) + '/api/v1/ops')).status, 401);
    assert.equal(
      (
        await fetch(base(srv.port) + '/api/v1/ops', {
          headers: { authorization: 'Bearer nope' },
        })
      ).status,
      401,
    );
    const ops = (await (
      await fetch(base(srv.port) + '/api/v1/ops', {
        headers: { authorization: `Bearer ${token}` },
      })
    ).json()) as any[];
    assert.ok(
      ops.find(
        (o) =>
          o.name === 'memory.remember' &&
          o.risk === 'free' &&
          o.group === 'memory' &&
          o.inputSchema.type === 'object',
      ),
    );
    assert.ok(
      ops.find((o) => o.name === 'secrets.set' && o.risk === 'app_only'),
    );
    const r = (await (
      await fetch(
        base(srv.port) + '/api/v1/ops/memory.remember',
        j({ text: 'Jan mag Tee' }, token),
      )
    ).json()) as any;
    assert.equal(r.ok, true);
    assert.ok(r.undo.id);
    assert.equal(r.result.text, 'Jan mag Tee');
    const bad = await fetch(
      base(srv.port) + '/api/v1/ops/memory.remember',
      j({}, token),
    );
    assert.equal(bad.status, 400);
    assert.equal(((await bad.json()) as any).ok, false);
    assert.equal(
      (await fetch(base(srv.port) + '/api/v1/ops/nope', j({}, token))).status,
      404,
    );
    // app may set credentials over HTTP
    assert.equal(
      (
        (await (
          await fetch(
            base(srv.port) + '/api/v1/ops/providers.set_credential',
            j({ provider: 'deepseek', apiKey: 'k' }, token),
          )
        ).json()) as any
      ).ok,
      true,
    );
    // revoked device stops working
    t.app.auth.revokeDevice(t.app.auth.devices()[0]!.id);
    assert.equal(
      (
        await fetch(base(srv.port) + '/api/v1/ops', {
          headers: { authorization: `Bearer ${token}` },
        })
      ).status,
      401,
    );
  } finally {
    await srv.close();
  }
});

test('pair/code only from loopback and logs it; rate limit on wrong codes', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const r = await fetch(base(srv.port) + '/api/v1/pair/code');
    assert.equal(r.status, 200); // test client is on loopback
    assert.match(((await r.json()) as any).code, /^[A-Z2-9]{4}-/);
    let last = 0;
    for (let i = 0; i < 12; i++)
      last = (
        await fetch(
          base(srv.port) + '/api/v1/pair',
          j({ code: 'XXXX-XXXX', deviceName: 'x' }),
        )
      ).status;
    assert.equal(last, 429);
  } finally {
    await srv.close();
  }
});

test('websocket rejects bad tokens; accepts ?token=', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    await assert.rejects(WsClient.connect(srv, 'bad'), /401/);
    const token = pairDevice(t.app);
    const { WebSocket } = await import('ws');
    const ws = new WebSocket(`ws://127.0.0.1:${srv.port}/ws?token=${token}`);
    await new Promise<void>(
      (res, rej) => (ws.once('open', () => res()), ws.once('error', rej)),
    );
    ws.close();
  } finally {
    await srv.close();
  }
});

test('admin MCP endpoint is off until an admin token is created; internal token guards /mcp/tools', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const rpc = { jsonrpc: '2.0', id: 1, method: 'tools/list' };
    assert.equal(
      (await fetch(base(srv.port) + '/mcp/admin', j(rpc))).status,
      404,
    );
    const device = pairDevice(t.app);
    const created = (await (
      await fetch(
        base(srv.port) + '/api/v1/ops/admin_token.create',
        j({ name: 'claude' }, device),
      )
    ).json()) as any;
    assert.equal(created.ok, true);
    const adminToken = created.result.token as string;
    assert.ok(
      !JSON.stringify(t.app.db.all('SELECT * FROM admin_tokens')).includes(
        adminToken,
      ),
    );
    assert.equal(
      (await fetch(base(srv.port) + '/mcp/admin', j(rpc))).status,
      401,
    );
    assert.equal(
      (await fetch(base(srv.port) + '/mcp/admin', j(rpc, device))).status,
      401,
      'device token is not an admin token',
    );
    const ok = await fetch(base(srv.port) + '/mcp/admin', j(rpc, adminToken));
    assert.equal(ok.status, 200);
    assert.ok(((await ok.json()) as any).result.tools.length > 20);
    const status = (await (
      await fetch(
        base(srv.port) + '/api/v1/ops/admin_token.status',
        j({}, device),
      )
    ).json()) as any;
    assert.equal(status.result.enabled, true);
    assert.ok(!JSON.stringify(status).includes(adminToken));
    await fetch(
      base(srv.port) + '/api/v1/ops/admin_token.revoke',
      j({ id: created.result.id }, device),
    );
    assert.equal(
      (await fetch(base(srv.port) + '/mcp/admin', j(rpc, adminToken))).status,
      404,
    );

    assert.equal(
      (await fetch(base(srv.port) + '/mcp/tools', j(rpc, adminToken))).status,
      401,
    );
    assert.equal(
      (await fetch(base(srv.port) + '/mcp/tools', j(rpc, device))).status,
      401,
    );
    const tools = await fetch(
      base(srv.port) + '/mcp/tools',
      j(rpc, t.app.auth.internalToken()),
    );
    assert.equal(tools.status, 200);
    assert.ok(
      ((await tools.json()) as any).result.tools.some(
        (x: any) => x.name === 'weather',
      ),
    );
  } finally {
    await srv.close();
  }
});

test('revoking a device closes its open websocket', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const token = pairDevice(t.app);
    const c = await WsClient.connect(srv, token);
    const closed = new Promise<void>((res) => c.ws.once('close', () => res()));
    const r = (await (
      await fetch(
        base(srv.port) + '/api/v1/ops/pairing.revoke_device',
        j({ id: t.app.auth.devices()[0]!.id }, token),
      )
    ).json()) as any;
    assert.equal(r.result.revoked, true);
    await closed;
    await assert.rejects(WsClient.connect(srv, token), /401/);
  } finally {
    await srv.close();
  }
});

test('pair/code refuses requests that came through a proxy (forwarded headers)', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const r = await fetch(base(srv.port) + '/api/v1/pair/code', {
      headers: { 'x-forwarded-for': '100.64.0.7' },
    });
    assert.equal(r.status, 403);
  } finally {
    await srv.close();
  }
});

test('oversized websocket frames are rejected without taking the server down', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const token = pairDevice(t.app);
    const c = await WsClient.connect(srv, token);
    const closed = new Promise<void>((res) => c.ws.once('close', () => res()));
    c.ws.send('x'.repeat(2_000_000));
    await closed;
    const c2 = await WsClient.connect(srv, token);
    await c2.close();
  } finally {
    await srv.close();
  }
});

test('starting with another MASTER_KEY on existing data fails with a clear message', async () => {
  const { mkdtempSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { createApp, MASTER_KEY_MISMATCH } = await import('./app.ts');
  const { loadConfig } = await import('./config.ts');
  const dir = mkdtempSync(join(tmpdir(), 'brain-key-'));
  const cfg = (k: string) =>
    loadConfig({ MASTER_KEY: k, DATA_DIR: dir, PORT: '0' });
  const a = createApp({ config: cfg('first-master-key-0123456789') });
  a.secrets.set('x', 'y');
  a.db.close();
  assert.throws(
    () => createApp({ config: cfg('other-master-key-0123456789') }),
    (e: Error) => e.message === MASTER_KEY_MISMATCH,
  );
  const again = createApp({ config: cfg('first-master-key-0123456789') });
  assert.equal(again.secrets.get('x'), 'y');
  again.db.close();
});

test('admin MCP: a tap op creates a proposal that shows up as an inbox item with the action', async () => {
  const t = makeApp();
  const srv = await startServer(t);
  try {
    const { token } = t.app.auth.createAdminToken('claude');
    const r = (await (
      await fetch(
        base(srv.port) + '/mcp/admin',
        j(
          {
            jsonrpc: '2.0',
            id: 1,
            method: 'tools/call',
            params: {
              name: 'providers_set_active',
              arguments: { active: 'anthropic' },
            },
          },
          token,
        ),
      )
    ).json()) as any;
    assert.equal(r.result.isError, false);
    assert.notEqual(t.app.providers.activeId(), 'anthropic');
    const item = t.app.inbox.list()[0]!;
    assert.equal(item.actions?.length, 1);
    assert.equal(item.actions![0]!.tool, 'op:providers.set_active');
    const p = await t.app.actions.perform(item.actions![0]!.id);
    assert.equal(p.ok, true);
    assert.equal(t.app.providers.activeId(), 'anthropic');
  } finally {
    await srv.close();
  }
});
