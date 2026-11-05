import { createHash, randomBytes } from 'node:crypto';
import type { App } from '../../app.ts';

export const PENDING_TTL = 15 * 60_000;
/** The app's custom scheme: the brain's /oauth/callback bounces the browser here. */
export const APP_REDIRECT = 'lotti://oauth';

const b64u = (b: Buffer) => b.toString('base64url');

export function newPkce(): { verifier: string; challenge: string } {
  const verifier = b64u(randomBytes(48));
  return {
    verifier,
    challenge: b64u(createHash('sha256').update(verifier).digest()),
  };
}
export const newState = () => b64u(randomBytes(16));

/** Server-side data of a sign-in in progress, keyed by `state` (kv). Abandoned ones older than the TTL are dropped. */
export function savePending(
  app: App,
  ns: string,
  state: string,
  data: object,
): void {
  const prefix = `oauth.${ns}.`;
  for (const r of app.db.all<{ key: string; value: string }>(
    'SELECT key, value FROM kv WHERE substr(key, 1, ?) = ?',
    prefix.length,
    prefix,
  )) {
    let at = 0;
    try {
      at = Number(JSON.parse(r.value).at) || 0;
    } catch {
      /* broken entry: drop it */
    }
    if (app.clock.now() - at > PENDING_TTL)
      app.db.run('DELETE FROM kv WHERE key=?', r.key);
  }
  app.settings.kvSet(
    `oauth.${ns}.${state}`,
    JSON.stringify({ ...data, at: app.clock.now() }),
  );
}

/** Single use: the entry is gone after the first read. Throws for unknown, used or expired states. */
export function takePending<T extends object>(
  app: App,
  ns: string,
  state: string,
): T {
  const key = `oauth.${ns}.${state}`;
  const raw = app.settings.kvGet(key);
  if (!raw)
    throw new Error(
      'This sign-in was already used or has expired: start it again.',
    );
  app.db.run('DELETE FROM kv WHERE key=?', key);
  const p = JSON.parse(raw) as T & { at: number };
  if (app.clock.now() - p.at > PENDING_TTL)
    throw new Error('The sign-in took too long. Start again.');
  return p;
}

export const isHttps = (u: string) => /^https:\/\//i.test(u);

/** `<PUBLIC_URL>/oauth/callback`, only when PUBLIC_URL is HTTPS (providers reject plain http redirects). */
export function webRedirect(app: App): string | undefined {
  return isHttps(app.config.publicUrl)
    ? `${app.config.publicUrl}/oauth/callback`
    : undefined;
}

const FORWARD = ['code', 'state', 'error', 'error_description'];

/** Target of the browser bounce: fixed scheme, only the allow-listed parameters. */
export function callbackBounce(params: URLSearchParams): string | undefined {
  const state = params.get('state');
  if (!state) return undefined;
  const q = new URLSearchParams();
  for (const k of FORWARD) {
    const v = params.get(k);
    if (v !== null) q.set(k, v.slice(0, 4096));
  }
  return `${APP_REDIRECT}?${q}`;
}

/** Adds a final period unless the text already ends a sentence. */
export const sentence = (s: string) => (/[.!?]$/.test(s) ? s : `${s}.`);

/**
 * A failed token request. `refused`: the token endpoint answered with an OAuth error (HTTP 400/401, e.g.
 * invalid_grant), so the grant or client is no good. `unavailable`: network error, timeout, 5xx or a garbled
 * reply; worth trying again later.
 */
export class TokenError extends Error {
  constructor(
    message: string,
    readonly kind: 'refused' | 'unavailable',
  ) {
    super(message);
    this.name = 'TokenError';
  }
}

/** Token endpoint call (form encoded). Errors carry the provider's message, never the request. */
export async function tokenPost(
  app: App,
  url: string,
  body: Record<string, string>,
  who: string,
): Promise<{
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  id_token?: string;
}> {
  let res: Response;
  try {
    res = await app.fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/x-www-form-urlencoded',
        accept: 'application/json',
      },
      body: new URLSearchParams(body).toString(),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (e) {
    throw new TokenError(
      sentence(`Cannot reach the ${who} sign-in server: ${reachWhy(e)}`),
      'unavailable',
    );
  }
  const j: any = await res.json().catch(() => ({}));
  if (res.ok && j.access_token) return j;
  if (res.status === 400 || res.status === 401) {
    const code = typeof j.error === 'string' ? j.error : undefined;
    const why =
      (typeof j.error_description === 'string' && j.error_description) ||
      (code === 'invalid_grant'
        ? body.grant_type === 'refresh_token'
          ? 'the sign-in is no longer valid'
          : 'the sign-in code expired or was already used: start the sign-in again'
        : code) ||
      `HTTP ${res.status}`;
    throw new TokenError(
      sentence(`${who} token request failed: ${why}`),
      'refused',
    );
  }
  throw new TokenError(
    res.ok
      ? `The ${who} sign-in server sent no token.`
      : `Cannot reach the ${who} sign-in server: it answered HTTP ${res.status}.`,
    'unavailable',
  );
}

/** A server URL as shown in messages and logs: no query, fragment or credentials (they may hold a token). */
export function publicUrl(url: string): string {
  try {
    const u = new URL(url);
    return `${u.origin}${u.pathname}`;
  } catch {
    return '[MCP server URL]';
  }
}

/** Why a request to a server failed, in one readable clause (a timeout is not "aborted"). */
export function reachWhy(e: unknown): string {
  if (e instanceof Error && e.name === 'TimeoutError')
    return 'it did not answer in time';
  const code =
    (e as { code?: string } | undefined)?.code ??
    ((e as { cause?: { code?: string } } | undefined)?.cause?.code as
      string | undefined);
  if (code === 'ENOTFOUND') return 'the server name was not found';
  if (code === 'ECONNREFUSED') return 'the connection was refused';
  return e instanceof Error
    ? ((e.cause as Error | undefined)?.message ?? e.message)
    : String(e);
}
