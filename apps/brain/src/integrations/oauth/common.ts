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

/** Server-side data of a sign-in in progress, keyed by `state` (kv). */
export function savePending(
  app: App,
  ns: string,
  state: string,
  data: object,
): void {
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
    throw new Error('Unknown or already used OAuth state. Start again.');
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
  const res = await app.fetch(url, {
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      accept: 'application/json',
    },
    body: new URLSearchParams(body).toString(),
    signal: AbortSignal.timeout(15_000),
  });
  const j: any = await res.json().catch(() => ({}));
  if (!res.ok || !j.access_token)
    throw new Error(
      `${who} token request failed: ${j.error_description ?? j.error ?? res.status}`,
    );
  return j;
}
