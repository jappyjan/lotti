import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { request } from 'node:http';
import { test } from 'node:test';
import { makeApp, startServer } from '../testing/helpers.ts';
import { registerIntegrations } from './register.ts';
import { googleApp, mockFetch } from './testing.ts';

const op = async (
  t: ReturnType<typeof makeApp>,
  name: string,
  input: unknown,
) => (await t.app.ops.invoke(name, input, 'app')) as any;

// ---- /oauth/callback ----------------------------------------------------------------------------------------

function get(port: number, path: string) {
  return new Promise<{
    status: number;
    headers: Record<string, any>;
    body: string;
  }>((resolve, reject) => {
    request({ port, path, method: 'GET' }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () =>
        resolve({ status: res.statusCode!, headers: res.headers, body }),
      );
    })
      .on('error', reject)
      .end();
  });
}

test('oauth callback: no auth, 302 to lotti://oauth with allow-listed params only, 400 without state', async () => {
  const t = makeApp();
  const s = await startServer(t);
  try {
    const r = await get(
      s.port,
      '/oauth/callback?code=c1&state=s1&evil=1&redirect=https://evil.example&error_description=nope',
    );
    assert.equal(r.status, 302);
    const loc = new URL(r.headers.location);
    assert.equal(loc.protocol, 'lotti:');
    assert.equal(loc.host, 'oauth');
    assert.deepEqual([...loc.searchParams.keys()].sort(), [
      'code',
      'error_description',
      'state',
    ]);
    assert.equal(r.headers['cache-control'], 'no-store');
    assert.match(r.body, /href="lotti:\/\/oauth\?/);
    const bad = await get(s.port, '/oauth/callback?code=c1');
    assert.equal(bad.status, 400);
  } finally {
    await s.close();
  }
});

// ---- Google redirect modes ---------------------------------------------------------------------------------

test('google redirect: iOS client gets the reversed id, Web client the https callback, override wins', async () => {
  const { t } = googleApp();
  const ios = '123-abc.apps.googleusercontent.com';
  await op(t, 'accounts.set_google_client', { clientId: ios });
  const info = (await op(t, 'accounts.google_client', {})).result;
  assert.deepEqual(info, {
    configured: true,
    mode: 'ios',
    redirectUri: 'com.googleusercontent.apps.123-abc:/oauth2redirect',
    callbackScheme: 'com.googleusercontent.apps.123-abc',
  });
  const u = (await op(t, 'accounts.google_auth_url', {})).result;
  assert.equal(u.callbackScheme, 'com.googleusercontent.apps.123-abc');
  assert.equal(
    new URL(u.url).searchParams.get('redirect_uri'),
    'com.googleusercontent.apps.123-abc:/oauth2redirect',
  );
  // Web client: needs https PUBLIC_URL.
  await op(t, 'accounts.set_google_client', {
    clientId: 'web.apps.googleusercontent.com',
    clientSecret: 'sec',
  });
  const bad = await op(t, 'accounts.google_auth_url', {});
  assert.match(bad.error, /HTTPS PUBLIC_URL/);
  assert.equal(
    (await op(t, 'accounts.google_client', {})).result.configured,
    true,
  );
  t.app.config.publicUrl = 'https://lotti.example.ts.net';
  const w = (await op(t, 'accounts.google_auth_url', {})).result;
  assert.equal(w.redirectUri, 'https://lotti.example.ts.net/oauth/callback');
  assert.equal(w.callbackScheme, 'lotti');
  const info2 = JSON.stringify(
    (await op(t, 'accounts.google_client', {})).result,
  );
  assert.ok(!info2.includes('sec"') && !info2.includes('"sec'));

  // Explicit override wins, also over the https callback.
  await op(t, 'accounts.set_google_client', {
    clientId: 'web.apps.googleusercontent.com',
    clientSecret: 'sec',
    redirectUri: 'lotti://oauth',
  });
  const c = (await op(t, 'accounts.google_auth_url', {})).result;
  assert.equal(c.redirectUri, 'lotti://oauth');
  assert.equal(c.callbackScheme, 'lotti');
});

test('google client: redirect override is trimmed and validated', async () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const set = (redirectUri: string) =>
    op(t, 'accounts.set_google_client', {
      clientId: ' 123-abc.apps.googleusercontent.com ',
      redirectUri,
    });
  // Blank override = no override (stays an iOS client); the client id is trimmed.
  const blank = (await set('   ')).result;
  assert.equal(blank.mode, 'ios');
  assert.equal(
    blank.redirectUri,
    'com.googleusercontent.apps.123-abc:/oauth2redirect',
  );
  for (const bad of ['nodomain', 'javascript:alert(1)', 'DATA:text/html,x'])
    assert.equal((await set(bad)).ok, false, bad);
  assert.equal(
    (await set(' lotti://oauth ')).result.redirectUri,
    'lotti://oauth',
  );
});

test('google redirect: token exchange sends the same redirect_uri', async () => {
  const { t, m } = googleApp();
  await op(t, 'accounts.set_google_client', {
    clientId: 'x1.apps.googleusercontent.com',
  });
  const u = (await op(t, 'accounts.google_auth_url', {})).result;
  await op(t, 'accounts.google_exchange', { code: 'good', state: u.state });
  const tok = m.seen.find((s) => s.url.includes('/token'))!;
  assert.equal(
    new URLSearchParams(tok.body).get('redirect_uri'),
    u.redirectUri,
  );
});

test('google client: agent cannot read or set the client', async () => {
  const { t } = googleApp();
  for (const n of ['accounts.google_client', 'accounts.set_google_client']) {
    const r = (await t.app.ops.invoke(n, { clientId: 'x' }, 'agent')) as any;
    assert.ok(r.error, n);
  }
});

// ---- MCP OAuth ---------------------------------------------------------------------------------------------

const MCP = 'https://mcp.example/rpc';
const AS = 'https://auth.example';

interface Opts {
  dcr?: boolean;
  prmHeader?: boolean;
  asWellKnown?: 'oauth' | 'openid' | 'none';
  refreshFails?: boolean;
}

function mcpFetch(o: Opts = {}) {
  const dcr = o.dcr ?? true;
  const issued = { n: 0 };
  const valid = new Set<string>();
  const m = mockFetch([
    {
      m: 'GET',
      u: 'https://mcp.example/.well-known/oauth-protected-resource',
      res: () => ({
        resource: MCP,
        authorization_servers: [AS],
        scopes_supported: ['read', 'write'],
      }),
    },
    {
      m: 'GET',
      u: 'https://meta.example/prm',
      res: () => ({ resource: MCP, authorization_servers: [AS] }),
    },
    {
      m: 'GET',
      u: `${AS}/.well-known/oauth-authorization-server`,
      res: () =>
        o.asWellKnown === 'openid' || o.asWellKnown === 'none'
          ? new Response('', { status: 404 })
          : {
              authorization_endpoint: `${AS}/authz`,
              token_endpoint: `${AS}/tok`,
              ...(dcr ? { registration_endpoint: `${AS}/reg` } : {}),
            },
    },
    {
      m: 'GET',
      u: `${AS}/.well-known/openid-configuration`,
      res: () =>
        o.asWellKnown === 'openid'
          ? {
              authorization_endpoint: `${AS}/oidc-authz`,
              token_endpoint: `${AS}/tok`,
              ...(dcr ? { registration_endpoint: `${AS}/reg` } : {}),
            }
          : new Response('', { status: 404 }),
    },
    {
      m: 'POST',
      u: `${AS}/reg`,
      res: (r) => ({ client_id: 'dyn-' + JSON.parse(r.body).redirect_uris[0] }),
    },
    {
      m: 'POST',
      u: `${AS}/tok`,
      res: (r) => {
        const f = new URLSearchParams(r.body);
        if (f.get('grant_type') === 'refresh_token') {
          if (o.refreshFails)
            return new Response('{"error":"invalid_grant"}', { status: 400 });
          const at = `at-r${++issued.n}`;
          valid.add(at);
          return { access_token: at, refresh_token: 'rt2', expires_in: 3600 };
        }
        valid.add('at1');
        return f.get('code') === 'good'
          ? { access_token: 'at1', refresh_token: 'rt1', expires_in: 3600 }
          : new Response('{"error":"invalid_grant"}', { status: 400 });
      },
    },
    {
      m: 'POST',
      u: MCP,
      res: (r) => {
        const auth = r.headers.authorization?.replace('Bearer ', '');
        if (!auth || !valid.has(auth))
          return new Response('', {
            status: 401,
            headers: {
              'www-authenticate': o.prmHeader
                ? 'Bearer resource_metadata="https://meta.example/prm", scope="read"'
                : 'Bearer',
            },
          });
        const b = JSON.parse(r.body);
        if (b.method === 'notifications/initialized')
          return new Response('', { status: 202 });
        if (b.method === 'tools/list')
          return {
            jsonrpc: '2.0',
            id: b.id,
            result: { tools: [{ name: 'ping' }] },
          };
        return { jsonrpc: '2.0', id: b.id, result: {} };
      },
    },
    { m: 'DELETE', u: MCP, res: () => new Response('', { status: 200 }) },
  ]);
  return { m, valid };
}

async function mcpApp(o: Opts = {}, publicUrl?: string) {
  const f = mcpFetch(o);
  const t = makeApp({ fetch: f.m.fetch });
  if (publicUrl) t.app.config.publicUrl = publicUrl;
  registerIntegrations(t.app);
  const id = (
    await op(t, 'mcp.add', { name: 'web', transport: 'http', url: MCP })
  ).result.id as string;
  return { t, id, ...f };
}

test('mcp oauth: discovery (well-known), dynamic registration, PKCE + resource, exchange, bearer use', async () => {
  const { t, id, m, valid } = await mcpApp({}, 'https://lotti.example.ts.net');
  const probe = (await op(t, 'mcp.test', { id })).result;
  assert.equal(probe.ok, false);
  assert.equal(probe.authRequired, true);
  assert.equal((await op(t, 'mcp.list', {})).result[0].authRequired, true);

  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  const url = new URL(s.url);
  assert.equal(url.origin + url.pathname, `${AS}/authz`);
  const p = url.searchParams;
  assert.equal(p.get('code_challenge_method'), 'S256');
  assert.equal(p.get('state'), s.state);
  assert.equal(p.get('resource'), MCP);
  assert.equal(p.get('scope'), 'read write');
  assert.equal(
    p.get('redirect_uri'),
    'https://lotti.example.ts.net/oauth/callback',
  );
  assert.equal(s.callbackScheme, 'lotti');
  assert.match(p.get('client_id')!, /^dyn-/);
  const reg = JSON.parse(m.seen.find((x) => x.url.endsWith('/reg'))!.body);
  assert.equal(reg.token_endpoint_auth_method, 'none');

  await op(t, 'mcp.oauth_exchange', { code: 'good', state: s.state }).then(
    (r) => assert.equal(r.result.signedIn, true),
  );
  const tok = new URLSearchParams(
    m.seen.filter((x) => x.url.endsWith('/tok'))[0]!.body,
  );
  assert.equal(
    createHash('sha256').update(tok.get('code_verifier')!).digest('base64url'),
    p.get('code_challenge'),
  );
  assert.equal(tok.get('resource'), MCP);
  assert.equal(tok.get('redirect_uri'), p.get('redirect_uri'));
  assert.equal(valid.has('at1'), true);

  // single use
  const again = await op(t, 'mcp.oauth_exchange', {
    code: 'good',
    state: s.state,
  });
  assert.match(again.error, /Unknown or already used/);

  // token is encrypted, used as bearer, and never listed
  const raw = t.app.db.get<{ value: string }>(
    'SELECT value FROM secrets WHERE name=?',
    `mcp.${id}.oauth.access_token`,
  )!;
  assert.ok(!raw.value.includes('at1'));
  const test = (await op(t, 'mcp.test', { id })).result;
  assert.equal(test.ok, true);
  assert.equal(test.signedIn, true);
  const list = (await op(t, 'mcp.list', {})).result;
  assert.equal(list[0].hasCredential, true);
  assert.equal(list[0].signedIn, true);
  assert.ok(!JSON.stringify(list).includes('at1'));
});

test('mcp oauth: resource_metadata from WWW-Authenticate and openid-configuration fallback', async () => {
  const { t, id, m } = await mcpApp({ prmHeader: true, asWellKnown: 'openid' });
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.ok(m.seen.some((x) => x.url === 'https://meta.example/prm'));
  assert.equal(new URL(s.url).pathname, '/oidc-authz');
  assert.equal(new URL(s.url).searchParams.get('scope'), 'read');
  // http PUBLIC_URL: the app scheme
  assert.equal(s.redirectUri, 'lotti://oauth');
});

test('mcp oauth: no metadata at all falls back to /authorize /token /register on the origin', async () => {
  const f = mockFetch([
    {
      m: 'POST',
      u: 'https://plain.example/mcp',
      res: () => new Response('', { status: 401 }),
    },
    {
      m: 'POST',
      u: 'https://plain.example/register',
      res: () => ({ client_id: 'c9' }),
    },
  ]);
  const t = makeApp({ fetch: f.fetch });
  registerIntegrations(t.app);
  const id = (
    await op(t, 'mcp.add', {
      name: 'plain',
      transport: 'http',
      url: 'https://plain.example/mcp',
    })
  ).result.id;
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.equal(
    new URL(s.url).origin + new URL(s.url).pathname,
    'https://plain.example/authorize',
  );
  assert.equal(new URL(s.url).searchParams.get('client_id'), 'c9');
});

test('mcp oauth: without dynamic registration a client id is needed; manual client works', async () => {
  const { t, id, m } = await mcpApp({ dcr: false });
  // The origin fallback would have offered /register only without metadata; here metadata says "none".
  const r = await op(t, 'mcp.oauth_start', { id });
  assert.match(r.error, /client id/);
  // Blank and oversized ids are refused; a padded one is trimmed.
  for (const clientId of ['', '   ', 'x'.repeat(513)])
    assert.equal(
      (await op(t, 'mcp.oauth_set_client', { id, clientId })).ok,
      false,
      JSON.stringify(clientId.slice(0, 8)),
    );
  await op(t, 'mcp.oauth_set_client', {
    id,
    clientId: ' mine ',
    clientSecret: 'shh',
  });
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.equal(new URL(s.url).searchParams.get('client_id'), 'mine');
  await op(t, 'mcp.oauth_exchange', { code: 'good', state: s.state });
  const body = new URLSearchParams(
    m.seen.filter((x) => x.url.endsWith('/tok')).at(-1)!.body,
  );
  assert.equal(body.get('client_secret'), 'shh');
  assert.equal(body.get('client_id'), 'mine');
});

test('mcp oauth: expired state, bad code, agent cannot call the ops', async () => {
  const { t, id } = await mcpApp();
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  t.clock.advance(16 * 60_000);
  assert.match(
    (await op(t, 'mcp.oauth_exchange', { code: 'good', state: s.state })).error,
    /took too long/,
  );
  const s2 = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.match(
    (await op(t, 'mcp.oauth_exchange', { code: 'bad', state: s2.state })).error,
    /token request failed: invalid_grant/,
  );
  for (const n of [
    'mcp.oauth_start',
    'mcp.oauth_exchange',
    'mcp.oauth_set_client',
  ]) {
    const r = (await t.app.ops.invoke(
      n,
      { id, code: 'x', state: 'y', clientId: 'z' },
      'agent',
    )) as any;
    assert.ok(r.error, n);
  }
});

async function signedIn(o: Opts = {}) {
  const x = await mcpApp(o);
  const s = (await op(x.t, 'mcp.oauth_start', { id: x.id })).result;
  await op(x.t, 'mcp.oauth_exchange', { code: 'good', state: s.state });
  return x;
}

test('mcp oauth: token is refreshed 60 s before expiry', async () => {
  const { t, id, m } = await signedIn();
  t.clock.advance(3600_000 - 30_000);
  const r = (await op(t, 'mcp.test', { id })).result;
  assert.equal(r.ok, true);
  const refresh = m.seen.filter(
    (x) => new URLSearchParams(x.body).get('grant_type') === 'refresh_token',
  );
  assert.equal(refresh.length, 1);
  assert.equal(new URLSearchParams(refresh[0]!.body).get('resource'), MCP);
  assert.equal(t.app.secrets.get(`mcp.${id}.oauth.refresh_token`), 'rt2');
});

test('mcp oauth: a 401 refreshes once and retries', async () => {
  const { t, id, m, valid } = await signedIn();
  valid.delete('at1'); // revoked on the server
  const r = (await op(t, 'mcp.test', { id })).result;
  assert.equal(r.ok, true);
  assert.equal(
    m.seen.filter(
      (x) => new URLSearchParams(x.body).get('grant_type') === 'refresh_token',
    ).length,
    1,
  );
});

test('mcp oauth: failed refresh sets status=error with "sign in again"', async () => {
  const { t, id, valid } = await signedIn({ refreshFails: true });
  valid.delete('at1');
  const r = (await op(t, 'mcp.test', { id })).result;
  assert.equal(r.ok, false);
  assert.match(r.error, /sign in again/);
  assert.equal(r.authRequired, true);
  const row = (await op(t, 'mcp.list', {})).result[0];
  assert.equal(row.status, 'error');
  assert.match(row.lastError, /sign in again/);
});

test('mcp oauth: OAuth token beats a manual bearer; url change and clear_credential delete the login', async () => {
  const { t, id, m } = await signedIn();
  await op(t, 'mcp.set_credential', { id, key: 'bearer', value: 'manual' });
  m.seen.length = 0;
  await op(t, 'mcp.test', { id });
  const used = m.seen.filter((x) => x.url === MCP && x.headers.authorization);
  assert.ok(used.every((x) => x.headers.authorization === 'Bearer at1'));

  await op(t, 'mcp.clear_credential', { id });
  assert.equal(t.app.secrets.list(`mcp.${id}.`).length, 0);
  assert.equal((await op(t, 'mcp.list', {})).result[0].hasCredential, false);

  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  await op(t, 'mcp.oauth_exchange', { code: 'good', state: s.state });
  assert.ok(t.app.secrets.list(`mcp.${id}.oauth.`).length > 0);
  await op(t, 'mcp.update', { id, url: 'https://evil.example/mcp' });
  assert.equal(t.app.secrets.list(`mcp.${id}.`).length, 0);
});
