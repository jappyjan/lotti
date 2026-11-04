import { createHash, randomBytes } from 'node:crypto';
import type { App } from '../../app.ts';
import { newId } from '../../util/crypto.ts';

export const GOOGLE_SCOPES = [
  'openid',
  'email',
  'https://www.googleapis.com/auth/calendar.readonly',
  'https://www.googleapis.com/auth/calendar.events',
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.send',
];
export const DEFAULT_REDIRECT = 'lotti://oauth';
const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const USERINFO_URL = 'https://openidconnect.googleapis.com/v1/userinfo';
const PENDING_TTL = 15 * 60_000;

export const GOOGLE_SECRETS = {
  clientId: 'google.client_id',
  clientSecret: 'google.client_secret',
  redirect: 'google.redirect_uri',
};

export function googleClient(app: App) {
  const clientId = app.secrets.get(GOOGLE_SECRETS.clientId);
  if (!clientId)
    throw new Error(
      'Google client id is not set: enter it in the app (accounts.set_google_client).',
    );
  return {
    clientId,
    clientSecret: app.secrets.get(GOOGLE_SECRETS.clientSecret),
    redirect: app.secrets.get(GOOGLE_SECRETS.redirect) || DEFAULT_REDIRECT,
  };
}

const b64u = (b: Buffer) => b.toString('base64url');

/** Step 1: URL for the app to open in a web auth session. PKCE verifier is kept server side per `state`. */
export function googleAuthUrl(
  app: App,
  opts: { accountId?: string; label?: string } = {},
): { url: string; state: string; redirectUri: string } {
  const c = googleClient(app);
  const verifier = b64u(randomBytes(48));
  const state = b64u(randomBytes(16));
  app.settings.kvSet(
    `oauth.google.${state}`,
    JSON.stringify({ verifier, ...opts, at: app.clock.now() }),
  );
  const q = new URLSearchParams({
    client_id: c.clientId,
    redirect_uri: c.redirect,
    response_type: 'code',
    scope: GOOGLE_SCOPES.join(' '),
    access_type: 'offline',
    prompt: 'consent',
    include_granted_scopes: 'true',
    state,
    code_challenge: b64u(createHash('sha256').update(verifier).digest()),
    code_challenge_method: 'S256',
  });
  return { url: `${AUTH_URL}?${q}`, state, redirectUri: c.redirect };
}

async function tokenRequest(app: App, body: Record<string, string>) {
  const res = await app.fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString(),
    signal: AbortSignal.timeout(15_000),
  });
  const j: any = await res.json().catch(() => ({}));
  if (!res.ok)
    throw new Error(
      `Google token request failed: ${j.error_description ?? j.error ?? res.status}`,
    );
  return j as {
    access_token: string;
    refresh_token?: string;
    expires_in: number;
    id_token?: string;
  };
}

export function storeGoogleTokens(
  app: App,
  accountId: string,
  t: { access_token: string; refresh_token?: string; expires_in: number },
): void {
  app.secrets.set(`account.${accountId}.access_token`, t.access_token);
  app.secrets.set(
    `account.${accountId}.expires_at`,
    String(app.clock.now() + t.expires_in * 1000),
  );
  if (t.refresh_token)
    app.secrets.set(`account.${accountId}.refresh_token`, t.refresh_token);
}

/** Step 2: the app sends the `code` it got on the redirect. Creates (or updates) the google account. */
export async function googleExchange(
  app: App,
  code: string,
  state: string,
): Promise<{ accountId: string; email: string | null }> {
  const raw = app.settings.kvGet(`oauth.google.${state}`);
  if (!raw)
    throw new Error('Unknown or already used OAuth state. Start again.');
  const p = JSON.parse(raw) as {
    verifier: string;
    accountId?: string;
    label?: string;
    at: number;
  };
  app.db.run('DELETE FROM kv WHERE key=?', `oauth.google.${state}`);
  if (app.clock.now() - p.at > PENDING_TTL)
    throw new Error('The sign-in took too long. Start again.');
  const c = googleClient(app);
  const t = await tokenRequest(app, {
    grant_type: 'authorization_code',
    code,
    client_id: c.clientId,
    redirect_uri: c.redirect,
    code_verifier: p.verifier,
    ...(c.clientSecret ? { client_secret: c.clientSecret } : {}),
  });
  if (!t.refresh_token)
    throw new Error(
      'Google returned no refresh token. Remove Lotti from your Google account permissions and sign in again.',
    );
  let email: string | null = null;
  try {
    const u = await app.fetch(USERINFO_URL, {
      headers: { authorization: `Bearer ${t.access_token}` },
      signal: AbortSignal.timeout(10_000),
    });
    email = ((await u.json()) as any).email ?? null;
  } catch {
    /* label stays generic */
  }
  let id = p.accountId;
  if (id && !app.db.get('SELECT 1 AS x FROM accounts WHERE id=?', id))
    id = undefined;
  if (!id) {
    id = newId('acc_');
    app.db.run(
      "INSERT INTO accounts(id,kind,label,config,status,created_at) VALUES(?,?,?,?,'ok',?)",
      id,
      'google',
      p.label ?? email ?? 'Google',
      JSON.stringify({ email, calendar: true, mail: true }),
      app.clock.now(),
    );
  } else {
    app.db.run(
      "UPDATE accounts SET status='ok', last_error=NULL WHERE id=?",
      id,
    );
  }
  storeGoogleTokens(app, id, t);
  return { accountId: id, email };
}

/** A valid access token for a google account (refreshes when needed). */
export async function googleAccessToken(
  app: App,
  accountId: string,
): Promise<string> {
  const cur = app.secrets.get(`account.${accountId}.access_token`);
  const exp = Number(app.secrets.get(`account.${accountId}.expires_at`) ?? 0);
  if (cur && exp - 60_000 > app.clock.now()) return cur;
  const refresh = app.secrets.get(`account.${accountId}.refresh_token`);
  if (!refresh)
    throw new Error('Google account is not signed in: connect it in the app.');
  const c = googleClient(app);
  try {
    const t = await tokenRequest(app, {
      grant_type: 'refresh_token',
      refresh_token: refresh,
      client_id: c.clientId,
      ...(c.clientSecret ? { client_secret: c.clientSecret } : {}),
    });
    storeGoogleTokens(app, accountId, t);
    return t.access_token;
  } catch (e) {
    throw new Error(
      `Google sign-in expired, connect the account again in the app (${e instanceof Error ? e.message : e}).`,
    );
  }
}

/** Authorized fetch to a Google REST API. */
export async function googleFetch(
  app: App,
  accountId: string,
  url: string,
  init: { method?: string; body?: unknown } = {},
): Promise<any> {
  const token = await googleAccessToken(app, accountId);
  const res = await app.fetch(url, {
    method: init.method ?? 'GET',
    headers: {
      authorization: `Bearer ${token}`,
      ...(init.body !== undefined
        ? { 'content-type': 'application/json' }
        : {}),
    },
    ...(init.body !== undefined ? { body: JSON.stringify(init.body) } : {}),
    signal: AbortSignal.timeout(20_000),
  });
  const text = await res.text();
  if (!res.ok) {
    let msg = text.slice(0, 200);
    try {
      msg = JSON.parse(text).error?.message ?? msg;
    } catch {
      /* keep raw */
    }
    throw new Error(`Google API ${res.status}: ${msg}`);
  }
  return text ? JSON.parse(text) : {};
}
