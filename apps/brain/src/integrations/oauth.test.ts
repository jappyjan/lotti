import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { request } from 'node:http';
import { mock, test } from 'node:test';
import { makeApp, startServer } from '../testing/helpers.ts';
import { canonicalResource } from './mcp/oauth.ts';
import { reachWhy } from './oauth/common.ts';
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

test('google redirect: an explicit http(s) override waits for lotti:// (the brain callback bounces there)', async () => {
  const { t } = googleApp();
  for (const redirectUri of [
    'https://lotti.example.ts.net/oauth/callback',
    'http://localhost:8787/oauth/callback',
  ]) {
    const r = (
      await op(t, 'accounts.set_google_client', {
        clientId: 'web.apps.googleusercontent.com',
        clientSecret: 'sec',
        redirectUri,
      })
    ).result;
    assert.equal(r.mode, 'custom');
    assert.equal(r.callbackScheme, 'lotti', redirectUri);
    const u = (await op(t, 'accounts.google_auth_url', {})).result;
    assert.equal(u.redirectUri, redirectUri);
    assert.equal(u.callbackScheme, 'lotti');
  }
  // A custom scheme override is waited for as is.
  await op(t, 'accounts.set_google_client', {
    clientId: 'x.apps.googleusercontent.com',
    redirectUri: 'com.example.app:/cb',
  });
  assert.equal(
    (await op(t, 'accounts.google_client', {})).result.callbackScheme,
    'com.example.app',
  );
});

test('google redirect: Web mode exchange sends the https redirect_uri', async () => {
  const { t, m } = googleApp();
  t.app.config.publicUrl = 'https://lotti.example.ts.net';
  await op(t, 'accounts.set_google_client', {
    clientId: 'web.apps.googleusercontent.com',
    clientSecret: 'sec',
  });
  const u = (await op(t, 'accounts.google_auth_url', {})).result;
  const x = await op(t, 'accounts.google_exchange', {
    code: 'good',
    state: u.state,
  });
  assert.ok(x.result.accountId, JSON.stringify(x));
  const tok = new URLSearchParams(
    m.seen.find((s) => s.url.includes('/token'))!.body,
  );
  assert.equal(
    tok.get('redirect_uri'),
    'https://lotti.example.ts.net/oauth/callback',
  );
  assert.equal(tok.get('client_secret'), 'sec');
});

test('google redirect: exchange uses the redirect saved at start, even if settings change meanwhile', async () => {
  const { t, m } = googleApp();
  t.app.config.publicUrl = 'https://lotti.example.ts.net';
  await op(t, 'accounts.set_google_client', {
    clientId: 'web.apps.googleusercontent.com',
    clientSecret: 'sec',
  });
  const u = (await op(t, 'accounts.google_auth_url', {})).result;
  // PUBLIC_URL moves to http: the current redirect can't even be derived any more.
  t.app.config.publicUrl = 'http://lotti.local:8787';
  const x = await op(t, 'accounts.google_exchange', {
    code: 'good',
    state: u.state,
  });
  assert.ok(x.result.accountId, JSON.stringify(x));
  // Another start, then an override is set before the exchange.
  t.app.config.publicUrl = 'https://lotti.example.ts.net';
  const u2 = (await op(t, 'accounts.google_auth_url', {})).result;
  await op(t, 'accounts.set_google_client', {
    clientId: 'web.apps.googleusercontent.com',
    clientSecret: 'sec',
    redirectUri: 'lotti://oauth',
  });
  await op(t, 'accounts.google_exchange', { code: 'good', state: u2.state });
  const sent = m.seen
    .filter((s) => s.url.includes('/token'))
    .map((s) => new URLSearchParams(s.body).get('redirect_uri'));
  assert.deepEqual(sent, [
    'https://lotti.example.ts.net/oauth/callback',
    'https://lotti.example.ts.net/oauth/callback',
  ]);
});

// ---- MCP OAuth ---------------------------------------------------------------------------------------------

const MCP = 'https://mcp.example/rpc';
const AS = 'https://auth.example';

interface Opts {
  dcr?: boolean;
  prmHeader?: boolean;
  asWellKnown?: 'oauth' | 'openid' | 'none';
  refreshFails?: boolean;
  /** Statuses the token endpoint answers refresh requests with first (one each), then it works again. */
  refreshStatus?: number[];
  /** Refresh requests wait for this. */
  refreshGate?: Promise<unknown>;
  /** The MCP server answers 401 to every token. */
  rejectAll?: boolean;
  /** Signed in, the MCP server answers this status. */
  signedInStatus?: number;
  /** tools/list answers with this JSON-RPC error message. */
  rpcError?: string;
  /** `issuer` in the AS metadata (default AS). */
  issuer?: string;
  /** `resource` in the protected resource metadata (default MCP). */
  prmResource?: string;
  regRefused?: boolean;
  /** `token_endpoint` in the AS metadata (read at each discovery). */
  tokenUrl?: string;
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
        resource: o.prmResource ?? MCP,
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
              issuer: o.issuer ?? AS,
              authorization_endpoint: `${AS}/authz`,
              token_endpoint: o.tokenUrl ?? `${AS}/tok`,
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
      res: (r) =>
        o.regRefused
          ? new Response(
              '{"error":"invalid_client_metadata","error_description":"no public clients"}',
              { status: 400 },
            )
          : { client_id: 'dyn-' + JSON.parse(r.body).redirect_uris[0] },
    },
    {
      m: 'POST',
      u: `${AS}/tok`,
      res: async (r) => {
        const f = new URLSearchParams(r.body);
        if (f.get('grant_type') === 'refresh_token') {
          await o.refreshGate;
          const st = o.refreshStatus?.shift();
          if (st) return new Response('<h1>down</h1>', { status: st });
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
        if (!auth || !valid.has(auth) || o.rejectAll)
          return new Response('', {
            status: 401,
            headers: {
              'www-authenticate': o.prmHeader
                ? 'Bearer resource_metadata="https://meta.example/prm", scope="read"'
                : 'Bearer',
            },
          });
        if (o.signedInStatus)
          return new Response('', { status: o.signedInStatus });
        const b = JSON.parse(r.body);
        if (b.method === 'notifications/initialized')
          return new Response('', { status: 202 });
        if (b.method === 'tools/list' && o.rpcError)
          return {
            jsonrpc: '2.0',
            id: b.id,
            error: { code: -32000, message: o.rpcError },
          };
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

async function mcpApp(o: Opts = {}, publicUrl?: string, url = MCP) {
  const f = mcpFetch(o);
  const t = makeApp({ fetch: f.m.fetch });
  if (publicUrl) t.app.config.publicUrl = publicUrl;
  registerIntegrations(t.app);
  const id = (await op(t, 'mcp.add', { name: 'web', transport: 'http', url }))
    .result.id as string;
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
  assert.match(again.error, /already used or has expired: start it again\./);

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
  const r = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.deepEqual(r, {
    needsClient: true,
    redirectUri: 'lotti://oauth',
    reason: 'This server has no automatic client registration.',
  });
  // A registration endpoint without a client id is no "secret set".
  assert.equal((await op(t, 'mcp.list', {})).result[0].hasCredential, false);
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
    /^MCP token request failed: the sign-in code expired or was already used: start the sign-in again\.$/,
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

// ---- MCP OAuth: review fixes --------------------------------------------------------------------------------

/** Wait for the refreshes the ops started (refreshes run one after the other). */
const settleMcp = (t: ReturnType<typeof makeApp>) =>
  t.app.integrations.mcp.refresh!();
const refreshCalls = (m: { seen: { body: string }[] }) =>
  m.seen.filter(
    (x) => new URLSearchParams(x.body).get('grant_type') === 'refresh_token',
  ).length;

test('mcp oauth: an unreachable sign-in server at expiry is no "sign in again" and is retried', async () => {
  const { t, id } = await signedIn({ refreshStatus: [503] });
  await settleMcp(t);
  t.clock.advance(3600_000);
  const r = (await op(t, 'mcp.test', { id })).result;
  assert.equal(r.ok, false);
  assert.equal(
    r.error,
    'Cannot reach the MCP sign-in server: it answered HTTP 503.',
  );
  assert.equal(r.authRequired, false);
  const row = (await op(t, 'mcp.list', {})).result[0];
  assert.equal(row.authRequired, false);
  assert.equal(row.signedIn, true);
  assert.equal(t.app.secrets.get(`mcp.${id}.oauth.refresh_token`), 'rt1');
  assert.equal((await op(t, 'mcp.test', { id })).result.ok, true);
});

test('mcp oauth: the backoff timer retries a server whose sign-in server was down', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const { t, m } = await signedIn({ refreshStatus: [503] });
    await settleMcp(t);
    assert.ok(t.app.tools.get('mcp__web__ping'));
    t.clock.advance(3600_000);
    await settleMcp(t); // the refresh fails: 503
    assert.ok(!t.app.tools.get('mcp__web__ping'));
    assert.equal(refreshCalls(m), 1);
    mock.timers.tick(30_000);
    for (
      const end = Date.now() + 5000;
      Date.now() < end && !t.app.tools.get('mcp__web__ping');
    )
      await new Promise((r) => setImmediate(r));
    assert.ok(t.app.tools.get('mcp__web__ping'), 'the timer brought it back');
    assert.equal(refreshCalls(m), 2);
  } finally {
    mock.timers.reset();
  }
});

test('mcp oauth: server error text with "sign in again" is no sign-in signal', async () => {
  const { t, id } = await signedIn({
    rpcError: 'Upstream token expired, please sign in again',
  });
  await settleMcp(t);
  const r = (await op(t, 'mcp.test', { id })).result;
  assert.equal(r.ok, false);
  assert.match(r.error, /please sign in again/);
  assert.equal(r.authRequired, false);
  assert.equal((await op(t, 'mcp.list', {})).result[0].authRequired, false);
});

test('mcp oauth: a 403 is a permission problem, not a sign-in one', async () => {
  const { t, id, m } = await signedIn({ signedInStatus: 403 });
  await settleMcp(t);
  m.seen.length = 0;
  const r = (await op(t, 'mcp.test', { id })).result;
  assert.equal(
    r.error,
    'The MCP server refused access (HTTP 403): the signed-in account lacks permission.',
  );
  assert.equal(r.authRequired, false);
  assert.equal(refreshCalls(m), 0);
});

test('mcp oauth: refresh accepted but still 401: one refresh per call, then "sign in again"', async () => {
  const { t, id, m } = await signedIn({ rejectAll: true });
  await settleMcp(t);
  m.seen.length = 0;
  const r = (await op(t, 'mcp.test', { id })).result;
  assert.equal(r.ok, false);
  assert.match(r.error, /sign in again/);
  assert.equal(r.authRequired, true);
  assert.equal(refreshCalls(m), 1);
});

test('mcp oauth: a refresh in flight does not write tokens back after the sign-in was removed', async () => {
  let open!: () => void;
  const gate = new Promise<void>((r) => (open = r));
  const { t, id, m } = await signedIn({ refreshGate: gate });
  await settleMcp(t);
  t.clock.advance(3600_000);
  const pending = op(t, 'mcp.test', { id });
  for (let i = 0; i < 1000 && !refreshCalls(m); i++)
    await new Promise((r) => setImmediate(r));
  assert.equal(refreshCalls(m), 1);
  await op(t, 'mcp.clear_credential', { id });
  open();
  const r = (await pending).result;
  assert.equal(r.ok, false);
  assert.equal(r.authRequired, true);
  assert.deepEqual(t.app.secrets.list(`mcp.${id}.`), []);
});

test('mcp oauth: a new sign-in that lands during a refresh keeps its tokens', async () => {
  let open!: () => void;
  const gate = new Promise<void>((r) => (open = r));
  const { t, id, m } = await signedIn({ refreshGate: gate });
  await settleMcp(t);
  t.clock.advance(3600_000);
  const pending = op(t, 'mcp.test', { id });
  for (let i = 0; i < 1000 && !refreshCalls(m); i++)
    await new Promise((r) => setImmediate(r));
  assert.equal(refreshCalls(m), 1);
  // What a finished sign-in stores.
  t.app.secrets.set(`mcp.${id}.oauth.refresh_token`, 'rt-new');
  t.app.secrets.set(`mcp.${id}.oauth.access_token`, 'at-new');
  open();
  const r = (await pending).result;
  assert.doesNotMatch(String(r.error ?? ''), /removed while/);
  // The old refresh's tokens were dropped: the next refresh (the mock does not know at-new) uses rt-new.
  const bodies = m.seen
    .filter((x) => x.body.includes('grant_type=refresh_token'))
    .map((x) => new URLSearchParams(x.body).get('refresh_token'));
  assert.deepEqual(bodies.slice(1), ['rt-new']);
});

test('mcp oauth: the resource of a root server URL has no trailing slash, and never a query', () => {
  assert.equal(canonicalResource('https://mcp.example'), 'https://mcp.example');
  assert.equal(
    canonicalResource('https://mcp.example/'),
    'https://mcp.example',
  );
  assert.equal(
    canonicalResource('https://mcp.example/rpc?k=SECRET#x'),
    'https://mcp.example/rpc',
  );
});

test('mcp oauth: a client Lotti registered for a cancelled sign-in is no "secret set"', async () => {
  const { t, id } = await mcpApp();
  await op(t, 'mcp.oauth_start', { id });
  assert.ok(t.app.secrets.get(`mcp.${id}.oauth.client_id`));
  const has = async () =>
    (await op(t, 'mcp.list', {})).result[0].hasCredential as boolean;
  assert.equal(await has(), false);
  await op(t, 'mcp.oauth_set_client', { id, clientId: 'mine' });
  assert.equal(await has(), true, 'an entered client counts');
  await op(t, 'mcp.clear_credential', { id });
  await op(t, 'mcp.set_credential', { id, key: 'bearer', value: 'b' });
  assert.equal(await has(), true, 'a bearer counts');
});

test('mcp oauth: sign out drops only the tokens; the client and bearer stay; app only', async () => {
  const { t, id, m } = await signedIn();
  await op(t, 'mcp.set_credential', { id, key: 'bearer', value: 'manual' });
  await settleMcp(t);
  const r = (await op(t, 'mcp.oauth_sign_out', { id })).result;
  assert.equal(r.signedIn, false);
  assert.equal(r.hasCredential, true);
  const names = t.app.secrets.list(`mcp.${id}.`).map((x) => x.name);
  for (const k of ['access_token', 'refresh_token', 'expires_at'])
    assert.ok(!names.includes(`mcp.${id}.oauth.${k}`), k);
  assert.ok(names.includes(`mcp.${id}.oauth.client_id`));
  assert.ok(names.includes(`mcp.${id}.bearer`));
  const row = (await op(t, 'mcp.list', {})).result[0];
  assert.equal(row.signedIn, false);
  assert.equal(row.authRequired, true);
  // Signing in again reuses the registered client.
  const regs = m.seen.filter((x) => x.url === `${AS}/reg`).length;
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.ok(s.url);
  assert.equal(m.seen.filter((x) => x.url === `${AS}/reg`).length, regs);
  const agent = (await t.app.ops.invoke(
    'mcp.oauth_sign_out',
    { id },
    'agent',
  )) as any;
  assert.ok(agent.error);
  assert.equal(
    t.app.ops.all().find((o) => o.name === 'mcp.oauth_sign_out')?.risk,
    'app_only',
  );
});

test('mcp oauth: a refused registration asks for a client, with the exact redirect URI', async () => {
  const { t, id } = await mcpApp(
    { regRefused: true },
    'https://lotti.example.ts.net',
  );
  assert.deepEqual((await op(t, 'mcp.oauth_start', { id })).result, {
    needsClient: true,
    redirectUri: 'https://lotti.example.ts.net/oauth/callback',
    reason:
      'The server refused the automatic client registration (no public clients).',
  });
});

test('mcp oauth: resource is the server URL without query and fragment, everywhere', async () => {
  const { t, id, m } = await mcpApp({}, undefined, `${MCP}?key=SECRET#frag`);
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.equal(new URL(s.url).searchParams.get('resource'), MCP);
  await op(t, 'mcp.oauth_exchange', { code: 'good', state: s.state });
  await settleMcp(t);
  t.clock.advance(3600_000);
  assert.equal((await op(t, 'mcp.test', { id })).result.ok, true);
  const tok = m.seen.filter((x) => x.url === `${AS}/tok`);
  assert.equal(tok.length, 2);
  for (const x of tok)
    assert.equal(new URLSearchParams(x.body).get('resource'), MCP);
  assert.ok(!s.url.includes('SECRET'));
  for (const x of m.seen.filter((x) => x.url.startsWith(AS)))
    assert.ok(!x.url.includes('SECRET') && !x.body.includes('SECRET'), x.url);
});

test('mcp oauth: metadata must be for this server and this issuer', async () => {
  const start = async (o: Opts) => {
    const { t, id } = await mcpApp(o);
    return op(t, 'mcp.oauth_start', { id });
  };
  assert.match(
    (await start({ prmResource: 'https://other.example/rpc' })).error,
    /different resource \(https:\/\/other\.example\/rpc\)/,
  );
  assert.match(
    (await start({ prmResource: 'https://mcp.example/rpc/deeper' })).error,
    /different resource/,
  );
  assert.match(
    (await start({ issuer: 'https://evil.example' })).error,
    /different issuer/,
  );
  // Same identifiers, written differently; a resource covering the whole origin.
  assert.ok((await start({ prmResource: 'HTTPS://MCP.example/rpc/' })).result);
  assert.ok((await start({ prmResource: 'https://mcp.example' })).result);
  assert.ok((await start({ issuer: `${AS}/` })).result);
});

test('mcp oauth: an entered client secret only goes to the token endpoint origin it was set up with', async () => {
  const o: Opts = { dcr: false };
  const { t, id } = await mcpApp(o);
  await op(t, 'mcp.oauth_set_client', {
    id,
    clientId: 'mine',
    clientSecret: 'shh',
  });
  assert.ok((await op(t, 'mcp.oauth_start', { id })).result.url);
  o.tokenUrl = 'https://other.example/tok';
  // The app gets the client fields back, with the reason.
  const moved = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.equal(moved.needsClient, true);
  assert.match(
    moved.reason,
    /another token endpoint \(https:\/\/other\.example\)/,
  );
  // Entering the client again pins the new origin.
  await op(t, 'mcp.oauth_set_client', {
    id,
    clientId: 'mine',
    clientSecret: 'shh',
  });
  assert.ok((await op(t, 'mcp.oauth_start', { id })).result.url);
});

test('mcp oauth: state is still valid at 14 min; abandoned states are cleaned up', async () => {
  const { t, id } = await mcpApp();
  const old = (await op(t, 'mcp.oauth_start', { id })).result.state;
  t.clock.advance(16 * 60_000);
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.equal(t.app.settings.kvGet(`oauth.mcp.${old}`), undefined);
  t.clock.advance(14 * 60_000);
  const r = await op(t, 'mcp.oauth_exchange', { code: 'good', state: s.state });
  assert.equal(r.result.signedIn, true);
});

test('mcp oauth: a changed redirect registers the client again', async () => {
  const { t, id, m } = await mcpApp();
  await op(t, 'mcp.oauth_start', { id });
  t.app.config.publicUrl = 'https://lotti.example.ts.net';
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  assert.deepEqual(
    m.seen
      .filter((x) => x.url === `${AS}/reg`)
      .map((x) => JSON.parse(x.body).redirect_uris[0]),
    ['lotti://oauth', 'https://lotti.example.ts.net/oauth/callback'],
  );
  assert.equal(
    new URL(s.url).searchParams.get('client_id'),
    'dyn-https://lotti.example.ts.net/oauth/callback',
  );
});

test('mcp oauth: a server changed during sign-in stores nothing', async () => {
  const { t, id } = await mcpApp();
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  await op(t, 'mcp.update', { id, url: 'https://mcp.example/other' });
  const r = await op(t, 'mcp.oauth_exchange', { code: 'good', state: s.state });
  assert.match(r.error, /changed during sign-in/);
  assert.deepEqual(t.app.secrets.list(`mcp.${id}.`), []);
});

test('mcp oauth: tokens are never returned by start, exchange or test', async () => {
  const { t, id } = await mcpApp();
  const {
    url: _u,
    state,
    ...start
  } = (await op(t, 'mcp.oauth_start', { id })).result;
  const out = [JSON.stringify(start)];
  out.push(
    JSON.stringify(await op(t, 'mcp.oauth_exchange', { code: 'good', state })),
  );
  out.push(JSON.stringify(await op(t, 'mcp.test', { id })));
  t.clock.advance(3600_000); // refreshed: at-r1 / rt2
  out.push(JSON.stringify(await op(t, 'mcp.test', { id })));
  const again = (await op(t, 'mcp.oauth_start', { id })).result;
  out.push(JSON.stringify({ ...again, url: undefined, state: undefined }));
  for (const o of out)
    for (const tok of ['at1', 'rt1', 'at-r1', 'rt2'])
      assert.ok(!o.includes(tok), `${tok} in ${o}`);
});

test('mcp oauth: discovery through the path-suffixed metadata only, issuer with a path', async () => {
  const SRV = 'https://deep.example/api/mcp';
  const f = mockFetch([
    {
      m: 'POST',
      u: /^https:\/\/deep\.example\/api\/mcp$/,
      res: () =>
        new Response('', {
          status: 401,
          headers: { 'www-authenticate': 'Bearer' },
        }),
    },
    {
      m: 'GET',
      u: /^https:\/\/deep\.example\/\.well-known\/oauth-protected-resource\/api\/mcp$/,
      res: () => ({
        resource: SRV,
        authorization_servers: ['https://login.example/tenant1'],
      }),
    },
    {
      m: 'GET',
      u: /^https:\/\/login\.example\/\.well-known\/oauth-authorization-server\/tenant1$/,
      res: () => ({
        issuer: 'https://login.example/tenant1',
        authorization_endpoint: 'https://login.example/tenant1/authorize',
        token_endpoint: 'https://login.example/tenant1/token',
        registration_endpoint: 'https://login.example/tenant1/register',
      }),
    },
    {
      m: 'POST',
      u: 'https://login.example/tenant1/register',
      res: () => ({ client_id: 'deep-client' }),
    },
  ]);
  const t = makeApp({ fetch: f.fetch });
  registerIntegrations(t.app);
  const id = (
    await op(t, 'mcp.add', { name: 'd', transport: 'http', url: SRV })
  ).result.id;
  const s = (await op(t, 'mcp.oauth_start', { id })).result;
  const u = new URL(s.url);
  assert.equal(
    u.origin + u.pathname,
    'https://login.example/tenant1/authorize',
  );
  assert.equal(u.searchParams.get('client_id'), 'deep-client');
  assert.equal(u.searchParams.get('resource'), SRV);
  // The root form was never needed.
  assert.ok(
    !f.seen.some(
      (x) =>
        x.url === 'https://deep.example/.well-known/oauth-protected-resource',
    ),
  );
});

test('readable errors: token endpoint and network reasons', () => {
  assert.equal(
    reachWhy(new TypeError('fetch failed', { cause: { code: 'ENOTFOUND' } })),
    'the server name was not found',
  );
  assert.equal(
    reachWhy(
      new TypeError('fetch failed', { cause: { code: 'ECONNREFUSED' } }),
    ),
    'the connection was refused',
  );
  assert.equal(reachWhy(new Error('boom')), 'boom');
});

test('mcp oauth: a guessed /register that is not there asks for a client; a failing one is an error', async () => {
  let regStatus = 404;
  const f = mockFetch([
    {
      m: 'POST',
      u: 'https://plain.example/mcp',
      res: () => new Response('', { status: 401 }),
    },
    {
      m: 'POST',
      u: 'https://plain.example/register',
      res: () => new Response('', { status: regStatus }),
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
  assert.deepEqual((await op(t, 'mcp.oauth_start', { id })).result, {
    needsClient: true,
    redirectUri: 'lotti://oauth',
    reason: 'This server has no automatic client registration.',
  });
  regStatus = 502;
  assert.equal(
    (await op(t, 'mcp.oauth_start', { id })).error,
    'The client registration answered HTTP 502: try again later.',
  );
});
