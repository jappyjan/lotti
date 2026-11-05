import type { App } from '../../app.ts';
import { newId } from '../../util/crypto.ts';
import {
  isHttps,
  newPkce,
  newState,
  savePending,
  takePending,
  tokenPost,
} from '../oauth/common.ts';

export const GOOGLE_SCOPES = [
  'openid',
  'email',
  'https://www.googleapis.com/auth/calendar.readonly',
  'https://www.googleapis.com/auth/calendar.events',
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.send',
];
const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const USERINFO_URL = 'https://openidconnect.googleapis.com/v1/userinfo';

export const GOOGLE_SECRETS = {
  clientId: 'google.client_id',
  clientSecret: 'google.client_secret',
  redirect: 'google.redirect_uri',
};

/** The custom scheme Google accepts for iOS-type clients: the client id, reversed. */
export function iosRedirect(clientId: string): string | undefined {
  const m = /^(.+)\.apps\.googleusercontent\.com$/.exec(clientId);
  return m ? `com.googleusercontent.apps.${m[1]}:/oauth2redirect` : undefined;
}

export interface GoogleRedirect {
  mode: 'ios' | 'web' | 'custom';
  redirectUri: string;
  /** Scheme the app waits for in ASWebAuthenticationSession. */
  callbackScheme: string;
}

/** The URI scheme (`lotti`, `https`, `com.googleusercontent.apps.x`), or undefined without one. */
export const schemeOf = (u: string): string | undefined =>
  /^([a-z][a-z0-9+.-]*):/i.exec(u)?.[1];

/** An http(s) redirect lands on the brain's /oauth/callback, which bounces the browser to lotti://oauth. */
const callbackSchemeOf = (u: string) => {
  const s = schemeOf(u) ?? 'lotti';
  return /^https?$/i.test(s) ? 'lotti' : s;
};

/**
 * Which redirect URI is used: an explicit override always wins; otherwise an iOS-type client (no secret)
 * gets the reversed client id, a Web-type client (has a secret) `<PUBLIC_URL>/oauth/callback`.
 */
export function googleRedirect(
  app: App,
  c: {
    clientId: string;
    clientSecret?: string | undefined;
    explicit?: string | undefined;
  },
): GoogleRedirect {
  if (c.explicit)
    return {
      mode: 'custom',
      redirectUri: c.explicit,
      callbackScheme: callbackSchemeOf(c.explicit),
    };
  if (!c.clientSecret) {
    const r = iosRedirect(c.clientId);
    if (!r)
      throw new Error(
        'This client id does not look like a Google iOS client (…apps.googleusercontent.com). Enter a redirect URI explicitly or use a Web client with a secret.',
      );
    return { mode: 'ios', redirectUri: r, callbackScheme: callbackSchemeOf(r) };
  }
  if (!isHttps(app.config.publicUrl))
    throw new Error(
      `A Google Web client needs an HTTPS PUBLIC_URL (now ${app.config.publicUrl}) for its redirect URI.`,
    );
  return {
    mode: 'web',
    redirectUri: `${app.config.publicUrl}/oauth/callback`,
    callbackScheme: 'lotti',
  };
}

/** Client id and secret only: what token refresh needs (never depends on the redirect). */
function googleCredentials(app: App) {
  const clientId = app.secrets.get(GOOGLE_SECRETS.clientId);
  if (!clientId)
    throw new Error(
      'Google client id is not set: enter it in the app (accounts.set_google_client).',
    );
  return {
    clientId,
    clientSecret: app.secrets.get(GOOGLE_SECRETS.clientSecret),
  };
}

/** Credentials plus the redirect sign-in uses. Throws when no redirect can be derived. */
export function googleClient(app: App) {
  const cred = googleCredentials(app);
  const r = googleRedirect(app, {
    ...cred,
    explicit: app.secrets.get(GOOGLE_SECRETS.redirect),
  });
  return { ...cred, ...r };
}

/** Stores a new client. It replaces the old one completely (secret and override included). */
export function setGoogleClient(
  app: App,
  i: {
    clientId: string;
    clientSecret?: string | undefined;
    redirectUri?: string | undefined;
  },
): ReturnType<typeof googleClientInfo> {
  const clientId = i.clientId.trim();
  const clientSecret = i.clientSecret?.trim();
  const redirectUri = i.redirectUri?.trim();
  if (!clientId) throw new Error('Client id is empty.');
  if (redirectUri) {
    const scheme = schemeOf(redirectUri);
    if (!scheme)
      throw new Error(
        'The redirect URI needs a scheme, e.g. lotti://oauth or https://host/path.',
      );
    if (/^(javascript|data|file|vbscript|about|blob)$/i.test(scheme))
      throw new Error(`The redirect URI scheme "${scheme}" is not allowed.`);
  }
  app.secrets.set(GOOGLE_SECRETS.clientId, clientId);
  if (clientSecret) app.secrets.set(GOOGLE_SECRETS.clientSecret, clientSecret);
  else app.secrets.delete(GOOGLE_SECRETS.clientSecret);
  if (redirectUri) app.secrets.set(GOOGLE_SECRETS.redirect, redirectUri);
  else app.secrets.delete(GOOGLE_SECRETS.redirect);
  return googleClientInfo(app);
}

/** What is configured, without any secret (the app shows the redirect URI to paste into the console). */
export function googleClientInfo(app: App): {
  configured: boolean;
  mode?: GoogleRedirect['mode'];
  redirectUri?: string;
  callbackScheme?: string;
  error?: string;
} {
  if (!app.secrets.get(GOOGLE_SECRETS.clientId)) return { configured: false };
  try {
    const { mode, redirectUri, callbackScheme } = googleClient(app);
    return { configured: true, mode, redirectUri, callbackScheme };
  } catch (e) {
    return {
      configured: true,
      error: e instanceof Error ? e.message : String(e),
    };
  }
}

/** Step 1: URL for the app to open in a web auth session. PKCE verifier is kept server side per `state`. */
export function googleAuthUrl(
  app: App,
  opts: { accountId?: string; label?: string } = {},
): { url: string; state: string; redirectUri: string; callbackScheme: string } {
  const c = googleClient(app);
  const { verifier, challenge } = newPkce();
  const state = newState();
  // The exchange must send exactly this redirect_uri, even if settings change meanwhile.
  savePending(app, 'google', state, {
    verifier,
    redirectUri: c.redirectUri,
    ...opts,
  });
  const q = new URLSearchParams({
    client_id: c.clientId,
    redirect_uri: c.redirectUri,
    response_type: 'code',
    scope: GOOGLE_SCOPES.join(' '),
    access_type: 'offline',
    prompt: 'consent',
    include_granted_scopes: 'true',
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
  });
  return {
    url: `${AUTH_URL}?${q}`,
    state,
    redirectUri: c.redirectUri,
    callbackScheme: c.callbackScheme,
  };
}

const tokenRequest = (app: App, body: Record<string, string>) =>
  tokenPost(app, TOKEN_URL, body, 'Google') as Promise<{
    access_token: string;
    refresh_token?: string;
    expires_in: number;
    id_token?: string;
  }>;

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
  const p = takePending<{
    verifier: string;
    redirectUri?: string;
    accountId?: string;
    label?: string;
  }>(app, 'google', state);
  const c = googleCredentials(app);
  const t = await tokenRequest(app, {
    grant_type: 'authorization_code',
    code,
    client_id: c.clientId,
    // Older pending entries (before redirectUri was saved) fall back to the current redirect.
    redirect_uri: p.redirectUri ?? googleClient(app).redirectUri,
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
  const c = googleCredentials(app);
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
