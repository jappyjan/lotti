import assert from 'node:assert/strict';
import { createVerify, generateKeyPairSync } from 'node:crypto';
import { test } from 'node:test';
import { jsonResponse, makeApp, pairDevice } from '../testing/helpers.ts';
import { newRun } from '../tools/registry.ts';
import {
  ApnsPush,
  apnsJwt,
  apnsPayload,
  type ApnsTransport,
} from './push/apns.ts';
import { registerIntegrations } from './register.ts';

const { privateKey, publicKey } = generateKeyPairSync('ec', {
  namedCurve: 'prime256v1',
});
const P8 = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();

test('apns: JWT is a valid ES256 token with kid/iss/iat', () => {
  const jwt = apnsJwt(
    { key: P8, keyId: 'KEY123', teamId: 'TEAM456' },
    1_800_000_000_000,
  );
  const [h, b, s] = jwt.split('.') as [string, string, string];
  assert.deepEqual(JSON.parse(Buffer.from(h, 'base64url').toString()), {
    alg: 'ES256',
    kid: 'KEY123',
  });
  assert.deepEqual(JSON.parse(Buffer.from(b, 'base64url').toString()), {
    iss: 'TEAM456',
    iat: 1_800_000_000,
  });
  assert.equal(Buffer.from(s, 'base64url').length, 64);
  const ok = createVerify('SHA256')
    .update(`${h}.${b}`)
    .verify(
      { key: publicKey, dsaEncoding: 'ieee-p1363' },
      Buffer.from(s, 'base64url'),
    );
  assert.ok(ok);
});

test('apns: payload wakes the app (content-available) and carries the item', () => {
  const p = apnsPayload({
    id: 'in_1',
    kind: 'mail',
    title: 'Chef fragt',
    summary: 'Termin morgen',
  });
  assert.equal(p.aps['content-available'], 1);
  assert.deepEqual(p.aps.alert, { title: 'Chef fragt', body: 'Termin morgen' });
  assert.equal(p.itemId, 'in_1');
});

function pushApp(
  res: { status: number; body: string } = { status: 200, body: '' },
) {
  const t = makeApp();
  registerIntegrations(t.app);
  const calls: {
    host: string;
    path: string;
    headers: Record<string, string>;
    body: any;
  }[] = [];
  const transport: ApnsTransport = async (host, path, headers, body) => {
    calls.push({ host, path, headers, body: JSON.parse(body) });
    return res;
  };
  t.app.integrations.push = new ApnsPush(t.app, transport);
  return { t, calls };
}
const configure = (t: ReturnType<typeof makeApp>, production = true) =>
  t.app.ops.invoke(
    'push.configure',
    { key: P8, keyId: 'K', teamId: 'T', topic: 'com.lotti.app', production },
    'app',
  );

test('apns: OFF until configured; then offline inbox items are pushed to devices with a token', async () => {
  const { t, calls } = pushApp();
  const token = pairDevice(t.app);
  const dev = t.app.auth.verifyDevice(token)!;
  t.app.auth.touchDevice(dev.id, undefined, 'aabbcc');
  t.app.inbox.create({ kind: 'info', title: 'Vorher', summary: 's' });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(calls.length, 0);
  assert.equal(
    ((await t.app.ops.invoke('push.status', {}, 'app')) as any).result
      .apnsConfigured,
    false,
  );

  await configure(t);
  assert.equal(
    ((await t.app.ops.invoke('push.status', {}, 'app')) as any).result
      .apnsConfigured,
    true,
  );
  t.app.inbox.create({ kind: 'mail', title: 'Chef fragt', summary: 'Termin' });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(calls.length, 1);
  const c = calls[0]!;
  assert.equal(c.host, 'api.push.apple.com');
  assert.equal(c.path, '/3/device/aabbcc');
  assert.equal(c.headers['apns-topic'], 'com.lotti.app');
  assert.equal(c.headers['apns-push-type'], 'alert');
  assert.match(c.headers.authorization!, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.equal(c.body.aps['content-available'], 1);
});

test('apns: sandbox host, test push op, dead token is dropped, key never readable', async () => {
  const { t, calls } = pushApp({
    status: 410,
    body: '{"reason":"Unregistered"}',
  });
  const dev = t.app.auth.verifyDevice(pairDevice(t.app))!;
  t.app.auth.touchDevice(dev.id, undefined, 'tok1');
  assert.match(
    ((await t.app.ops.invoke('push.test', {}, 'app')) as any).error,
    /not configured/,
  );
  await configure(t, false);
  const r = (await t.app.ops.invoke('push.test', {}, 'app')) as any;
  assert.equal(calls[0]!.host, 'api.sandbox.push.apple.com');
  assert.equal(r.result[0].ok, false);
  assert.equal(r.result[0].reason, 'Unregistered');
  assert.equal(t.app.auth.devices()[0]!.apnsToken, null);
  assert.match(
    ((await t.app.ops.invoke('push.test', {}, 'app')) as any).error,
    /No device with an APNs token/,
  );
  for (const op of ['push.configure', 'push.test', 'push.clear'])
    assert.match(
      ((await t.app.ops.invoke(op, {}, 'agent')) as any).error,
      /only available in the app/,
    );
  assert.ok(
    !JSON.stringify(await t.app.ops.invoke('secrets.list', {}, 'app')).includes(
      'BEGIN',
    ),
  );
  await t.app.ops.invoke('push.clear', {}, 'app');
  assert.equal(
    ((await t.app.ops.invoke('push.status', {}, 'app')) as any).result
      .apnsConfigured,
    false,
  );
});

test('web_search: Brave with key, curl hint without', async () => {
  const seen: { url: string; key: string }[] = [];
  const t = makeApp({
    fetch: async (u: any, init: any) => {
      seen.push({ url: String(u), key: init.headers['x-subscription-token'] });
      return jsonResponse({
        web: {
          results: [
            {
              title: 'Lotti',
              url: 'https://lotti.app',
              description: 'A <b>glasses</b> assistant',
            },
          ],
        },
      });
    },
  });
  registerIntegrations(t.app);
  const run = newRun();
  const none = await t.app.tools.call(
    'web_search',
    { query: 'lotti' },
    { app: t.app, run },
  );
  assert.match(none.text, /curl/);
  assert.equal(seen.length, 0);
  await t.app.ops.invoke(
    'secrets.set',
    { name: 'search.brave.api_key', value: 'BSA-key' },
    'app',
  );
  const r = await t.app.tools.call(
    'web_search',
    { query: 'lotti glasses', count: 3, freshness: 'week' },
    { app: t.app, run },
  );
  assert.match(
    r.text,
    /Lotti\n {2}https:\/\/lotti.app\n {2}A glasses assistant/,
  );
  assert.equal(seen[0]!.key, 'BSA-key');
  assert.match(seen[0]!.url, /q=lotti\+glasses.*count=3.*freshness=pw/);
});

test('registerIntegrations: all slots filled, new ops present and sorted into the right groups', () => {
  const t = makeApp();
  registerIntegrations(t.app);
  const i = t.app.integrations;
  assert.ok(i.bring && i.calendar && i.mail && i.mcp.refresh);
  for (const k of ['google', 'icloud', 'caldav', 'imap', 'bring'])
    assert.ok(i.connectors.has(k), k);
  const ops = new Map(t.app.ops.all().map((o) => [o.name, o]));
  for (const [n, risk] of [
    ['accounts.google_auth_url', 'app_only'],
    ['accounts.google_exchange', 'app_only'],
    ['accounts.set_google_client', 'app_only'],
    ['accounts.calendars', 'free'],
    ['accounts.set_calendars', 'tap'],
    ['accounts.mailboxes', 'free'],
    ['accounts.set_mailboxes', 'tap'],
    ['bring.recent', 'free'],
    ['bring.login', 'app_only'],
    ['bring.set_default_list', 'free'],
    ['mcp.tools', 'tap'],
    ['mcp.set_credential', 'app_only'],
    ['providers.codex_login_start', 'app_only'],
    ['providers.codex_login_status', 'free'],
    ['push.configure', 'app_only'],
    ['push.test', 'app_only'],
  ] as const)
    assert.equal(ops.get(n)?.risk, risk, n);
  const tools = t.app.tools.all().map((x) => x.name);
  for (const n of [
    'calendar_events',
    'mail_search',
    'mail_read',
    'web_search',
    'bring_add',
    'bring_recent',
  ])
    assert.ok(tools.includes(n), n);
  assert.ok(
    !tools.some((n) =>
      /google|codex_login|push_configure|set_credential/.test(n),
    ),
  );
});
