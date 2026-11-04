import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { googleAccessToken } from './google/oauth.ts';
import { connectGoogle, googleApp } from './testing.ts';

test('google oauth: auth url has PKCE + custom scheme redirect; exchange stores encrypted tokens', async () => {
  const { t, m } = googleApp();
  const noClient = (await t.app.ops.invoke(
    'accounts.google_auth_url',
    {},
    'app',
  )) as any;
  assert.match(noClient.error, /client id/);
  await t.app.ops.invoke(
    'accounts.set_google_client',
    { clientId: 'cid', clientSecret: 'csec', redirectUri: 'lotti://oauth' },
    'app',
  );
  const u = (await t.app.ops.invoke(
    'accounts.google_auth_url',
    { label: 'Privat' },
    'app',
  )) as any;
  const url = new URL(u.result.url);
  assert.equal(
    url.origin + url.pathname,
    'https://accounts.google.com/o/oauth2/v2/auth',
  );
  assert.equal(url.searchParams.get('redirect_uri'), 'lotti://oauth');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(url.searchParams.get('access_type'), 'offline');
  assert.match(url.searchParams.get('scope')!, /calendar/);
  assert.match(url.searchParams.get('scope')!, /gmail/);
  assert.equal(url.searchParams.get('state'), u.result.state);

  const x = (await t.app.ops.invoke(
    'accounts.google_exchange',
    { code: 'good', state: u.result.state },
    'app',
  )) as any;
  assert.equal(x.result.email, 'jan@gmail.com');
  const body = new URLSearchParams(
    m.seen.find((s) => s.url.includes('/token'))!.body,
  );
  const challenge = createHash('sha256')
    .update(body.get('code_verifier')!)
    .digest('base64url');
  assert.equal(challenge, url.searchParams.get('code_challenge'));
  assert.equal(body.get('client_secret'), 'csec');
  const id = x.result.accountId;
  assert.equal(t.app.secrets.get(`account.${id}.refresh_token`), 'rt1');
  const raw = t.app.db.get<{ value: string }>(
    'SELECT value FROM secrets WHERE name=?',
    `account.${id}.refresh_token`,
  )!;
  assert.ok(!raw.value.includes('rt1'));
  const list = JSON.stringify(
    ((await t.app.ops.invoke('accounts.list', {}, 'app')) as any).result,
  );
  assert.ok(
    list.includes('Privat') && !list.includes('rt1') && !list.includes('at1'),
  );

  // state is single use
  const again = (await t.app.ops.invoke(
    'accounts.google_exchange',
    { code: 'good', state: u.result.state },
    'app',
  )) as any;
  assert.match(again.error, /Unknown or already used/);
});

test('google oauth: bad code and agent access', async () => {
  const { t } = googleApp();
  await t.app.ops.invoke(
    'accounts.set_google_client',
    { clientId: 'cid', redirectUri: 'lotti://oauth' },
    'app',
  );
  const u = (await t.app.ops.invoke(
    'accounts.google_auth_url',
    {},
    'app',
  )) as any;
  const x = (await t.app.ops.invoke(
    'accounts.google_exchange',
    { code: 'bad', state: u.result.state },
    'app',
  )) as any;
  assert.match(x.error, /Bad code/);
  for (const op of [
    'accounts.google_auth_url',
    'accounts.google_exchange',
    'accounts.set_google_client',
  ])
    assert.match(
      (
        (await t.app.ops.invoke(
          op,
          { code: 'x', state: 'y', clientId: 'z' },
          'agent',
        )) as any
      ).error,
      /only available in the app/,
    );
});

test('google: access token refreshes when expired, and a revoked refresh token is a clear error', async () => {
  const { t } = googleApp();
  const id = await connectGoogle(t);
  assert.equal(await googleAccessToken(t.app, id), 'at1');
  t.clock.advance(2 * 3600_000);
  const fresh = await googleAccessToken(t.app, id);
  assert.notEqual(fresh, 'at1');
  assert.equal(await googleAccessToken(t.app, id), fresh); // cached
  t.app.secrets.set(`account.${id}.refresh_token`, 'revoked');
  t.clock.advance(2 * 3600_000);
  await assert.rejects(
    googleAccessToken(t.app, id),
    /connect the account again/,
  );
});
