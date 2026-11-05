import type { App } from '../../app.ts';
import {
  APP_REDIRECT,
  TokenError,
  newPkce,
  newState,
  publicUrl,
  reachWhy,
  savePending,
  sentence,
  takePending,
  tokenPost,
  webRedirect,
} from '../oauth/common.ts';
import type { McpServerConfig } from '../index.ts';

/**
 * OAuth for remote MCP servers (MCP authorization spec): protected resource metadata (RFC 9728), authorization
 * server metadata (RFC 8414), dynamic client registration (RFC 7591), authorization code + PKCE S256 and the
 * `resource` parameter (RFC 8707). Everything lives in encrypted secrets under `mcp.<id>.oauth.*`.
 */

const S = (id: string, k: string) => `mcp.${id}.oauth.${k}`;
export const oauthPrefix = (id: string) => `mcp.${id}.oauth.`;
const SKEW_MS = 60_000;

export const AUTH_REFUSED = 'MCP server refused the login';
export const BEARER_REFUSED = `${AUTH_REFUSED}: sign in or set the bearer token in the app.`;
export const SIGN_IN_AGAIN = 'MCP sign-in expired: sign in again in the app.';
export const SIGNED_OUT =
  'Signed out of this MCP server: sign in again in the app.';
const SIGN_IN_GONE =
  'The MCP sign-in was removed while it was being renewed: sign in again in the app.';
const AUTH_MESSAGES = new Set([
  BEARER_REFUSED,
  SIGN_IN_AGAIN,
  SIGNED_OUT,
  SIGN_IN_GONE,
]);

/** Our own "the user has to sign in (again)" signal. Server-supplied error text never is one. */
export class McpAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'McpAuthError';
  }
}
/** For a stored last_error: exactly one of our own sign-in messages (never a substring of server text). */
export const isAuthError = (msg: string | null | undefined) =>
  !!msg && AUTH_MESSAGES.has(msg);

/**
 * The resource indicator (RFC 8707) of a server: its URL without query and fragment, which may hold a token
 * and would otherwise reach a third-party authorization server and the browser's address bar.
 */
export function canonicalResource(serverUrl: string): string {
  const u = new URL(serverUrl);
  return `${u.origin}${u.pathname === '/' ? '' : u.pathname}`;
}
/** For comparing resource and issuer identifiers: lower-case scheme/host, no query, no trailing slash. */
function idOf(u: string): { origin: string; path: string } | undefined {
  try {
    const x = new URL(u);
    return { origin: x.origin, path: x.pathname.replace(/\/+$/, '') };
  } catch {
    return undefined;
  }
}
const sameId = (a: string, b: string) => {
  const x = idOf(a);
  const y = idOf(b);
  return !!x && !!y && x.origin === y.origin && x.path === y.path;
};
/** RFC 9728 §3.3: metadata must be for this server (same origin, and the server's path at or below its path). */
function resourceCovers(resource: string, serverUrl: string): boolean {
  const r = idOf(resource);
  const s = idOf(serverUrl);
  return (
    !!r &&
    !!s &&
    r.origin === s.origin &&
    (s.path === r.path || s.path.startsWith(`${r.path}/`))
  );
}

interface AsMeta {
  authorization_endpoint: string;
  token_endpoint: string;
  registration_endpoint?: string;
}
interface Discovery extends AsMeta {
  scope?: string;
}

/** https, or http to the local machine (development servers). */
const safeUrl = (u: string) => {
  try {
    const x = new URL(u);
    return (
      x.protocol === 'https:' ||
      (x.protocol === 'http:' &&
        ['localhost', '127.0.0.1', '[::1]'].includes(x.hostname))
    );
  } catch {
    return false;
  }
};

async function getJson(app: App, url: string): Promise<any | undefined> {
  if (!safeUrl(url)) return undefined;
  try {
    const r = await app.fetch(url, {
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(10_000),
    });
    if (!r.ok) return undefined;
    const j = await r.json();
    return j && typeof j === 'object' ? j : undefined;
  } catch {
    return undefined;
  }
}

/** Well-known URL with the path of `u` appended (RFC 8414 / 9728 insertion form). */
function wellKnown(u: URL, name: string): string {
  const p = u.pathname === '/' ? '' : u.pathname.replace(/\/+$/, '');
  return `${u.origin}/.well-known/${name}${p}`;
}

function challengeParam(h: string | null, name: string): string | undefined {
  if (!h) return undefined;
  return new RegExp(`${name}="([^"]*)"`, 'i').exec(h)?.[1] ?? undefined;
}

/** Find the authorization endpoints of an MCP server that answered 401. */
export async function discover(
  app: App,
  serverUrl: string,
  wwwAuthenticate: string | null,
): Promise<Discovery> {
  const su = new URL(serverUrl);
  const hinted = challengeParam(wwwAuthenticate, 'resource_metadata');
  let prm: any;
  for (const u of [
    ...(hinted ? [hinted] : []),
    wellKnown(su, 'oauth-protected-resource'),
    `${su.origin}/.well-known/oauth-protected-resource`,
  ]) {
    prm = await getJson(app, u);
    if (prm) break;
  }
  if (
    typeof prm?.resource === 'string' &&
    !resourceCovers(prm.resource, serverUrl)
  )
    throw new Error(
      `The MCP server's sign-in metadata is for a different resource (${publicUrl(prm.resource)}).`,
    );
  const scope =
    challengeParam(wwwAuthenticate, 'scope') ??
    (Array.isArray(prm?.scopes_supported) && prm.scopes_supported.length
      ? prm.scopes_supported.join(' ')
      : undefined);
  const issuer: string =
    (Array.isArray(prm?.authorization_servers) &&
      typeof prm.authorization_servers[0] === 'string' &&
      prm.authorization_servers[0]) ||
    su.origin;
  if (!safeUrl(issuer))
    throw new Error('The MCP server points to an unsafe authorization server.');
  const iu = new URL(issuer);
  let as: any;
  for (const u of [
    wellKnown(iu, 'oauth-authorization-server'),
    wellKnown(iu, 'openid-configuration'),
    `${iu.origin}${iu.pathname.replace(/\/+$/, '')}/.well-known/openid-configuration`,
  ]) {
    as = await getJson(app, u);
    if (as?.authorization_endpoint && as?.token_endpoint) break;
    as = undefined;
  }
  // RFC 8414 §3.3: the metadata must name the issuer it was fetched for.
  if (typeof as?.issuer === 'string' && !sameId(as.issuer, issuer))
    throw new Error(
      `The authorization server's metadata names a different issuer (${publicUrl(as.issuer)}).`,
    );
  const meta: AsMeta = as
    ? {
        authorization_endpoint: as.authorization_endpoint,
        token_endpoint: as.token_endpoint,
        ...(as.registration_endpoint
          ? { registration_endpoint: as.registration_endpoint }
          : {}),
      }
    : {
        authorization_endpoint: `${iu.origin}/authorize`,
        token_endpoint: `${iu.origin}/token`,
        registration_endpoint: `${iu.origin}/register`,
      };
  for (const e of Object.values(meta))
    if (!safeUrl(e))
      throw new Error('The MCP server gave an unsafe OAuth endpoint.');
  return { ...meta, ...(scope ? { scope } : {}) };
}

/** Ask the server without credentials: a 401 tells where the authorization server is. */
async function probe(app: App, url: string): Promise<string> {
  let r: Response;
  try {
    r = await app.fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json, text/event-stream',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          protocolVersion: '2025-03-26',
          capabilities: {},
          clientInfo: { name: 'lotti-brain', version: app.config.version },
        },
      }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (e) {
    throw new Error(
      sentence(
        `Cannot reach the MCP server at ${publicUrl(url)}: ${reachWhy(e)}`,
      ),
    );
  }
  if (r.status === 401 || r.status === 403)
    return r.headers.get('www-authenticate') ?? '';
  throw new Error(
    r.ok
      ? 'This MCP server does not ask for a sign-in.'
      : `MCP server answered HTTP ${r.status}.`,
  );
}

const NO_DCR = 'This server has no automatic client registration.';

/** Dynamic client registration (RFC 7591). A refusal is no error: the user can enter a client instead. */
async function register(
  app: App,
  endpoint: string,
  redirectUri: string,
  scope?: string,
): Promise<{ clientId: string } | { refused: string }> {
  let res: Response;
  try {
    res = await app.fetch(endpoint, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        accept: 'application/json',
      },
      body: JSON.stringify({
        client_name: 'Lotti',
        redirect_uris: [redirectUri],
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        token_endpoint_auth_method: 'none',
        ...(scope ? { scope } : {}),
      }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch (e) {
    throw new Error(
      sentence(`Cannot reach the client registration: ${reachWhy(e)}`),
    );
  }
  if (res.status >= 500)
    throw new Error(
      `The client registration answered HTTP ${res.status}: try again later.`,
    );
  // The origin fallback guesses /register: not there means no automatic registration.
  if (res.status === 404) return { refused: NO_DCR };
  const j: any = await res.json().catch(() => ({}));
  if (!res.ok || !j.client_id)
    return {
      refused: `The server refused the automatic client registration (${j.error_description ?? j.error ?? `HTTP ${res.status}`}).`,
    };
  return { clientId: String(j.client_id) };
}

export type McpOauthStart =
  | { url: string; state: string; redirectUri: string; callbackScheme: string }
  /** No client to sign in with: register Lotti at the server with `redirectUri`, then mcp.oauth_set_client. */
  | { needsClient: true; redirectUri: string; reason: string };

export async function mcpOauthStart(
  app: App,
  server: McpServerConfig,
): Promise<McpOauthStart> {
  if (server.transport !== 'http' || !server.url)
    throw new Error('Sign-in works for HTTP MCP servers only.');
  const d = await discover(app, server.url, await probe(app, server.url));
  const redirectUri = webRedirect(app) ?? APP_REDIRECT;
  let clientId = app.secrets.get(S(server.id, 'client_id'));
  const manual = app.secrets.get(S(server.id, 'client_manual')) === '1';
  // A dynamically registered client is bound to one redirect URI: register again when it changed.
  if (
    !manual &&
    (!clientId ||
      app.secrets.get(S(server.id, 'client_redirect')) !== redirectUri)
  ) {
    if (!d.registration_endpoint)
      return { needsClient: true, redirectUri, reason: NO_DCR };
    const r = await register(
      app,
      d.registration_endpoint,
      redirectUri,
      d.scope,
    );
    if ('refused' in r)
      return { needsClient: true, redirectUri, reason: r.refused };
    clientId = r.clientId;
    app.secrets.set(S(server.id, 'client_id'), clientId);
    app.secrets.set(S(server.id, 'client_redirect'), redirectUri);
  }
  if (!clientId)
    return {
      needsClient: true,
      redirectUri,
      reason: 'Enter a client ID for this server first.',
    };
  const moved = manual && pinTokenOrigin(app, server.id, d.token_endpoint);
  if (moved) return { needsClient: true, redirectUri, reason: moved };
  const { verifier, challenge } = newPkce();
  const state = newState();
  savePending(app, 'mcp', state, {
    serverId: server.id,
    serverUrl: server.url,
    verifier,
    redirectUri,
    tokenEndpoint: d.token_endpoint,
  });
  const au = new URL(d.authorization_endpoint);
  for (const [k, v] of Object.entries({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: redirectUri,
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    resource: canonicalResource(server.url),
    ...(d.scope ? { scope: d.scope } : {}),
  }))
    au.searchParams.set(k, v);
  return { url: au.href, state, redirectUri, callbackScheme: 'lotti' };
}

/**
 * A client secret the user entered goes only to the token endpoint origin of the first sign-in after it was
 * entered: later sign-ins that discover another origin are refused.
 */
function pinTokenOrigin(
  app: App,
  id: string,
  tokenEndpoint: string,
): string | undefined {
  const origin = new URL(tokenEndpoint).origin;
  const pinned = app.secrets.get(S(id, 'client_token_origin'));
  if (!pinned) app.secrets.set(S(id, 'client_token_origin'), origin);
  else if (pinned !== origin && app.secrets.get(S(id, 'client_secret')))
    return `The server now uses another token endpoint (${origin}) than the one your client was set up with (${pinned}): enter the client again.`;
  return undefined;
}

function store(
  app: App,
  id: string,
  t: { access_token: string; refresh_token?: string; expires_in?: number },
  tokenEndpoint: string,
): void {
  app.secrets.set(S(id, 'access_token'), t.access_token);
  app.secrets.set(
    S(id, 'expires_at'),
    String(app.clock.now() + (t.expires_in ?? 3600) * 1000),
  );
  if (t.refresh_token) app.secrets.set(S(id, 'refresh_token'), t.refresh_token);
  app.secrets.set(S(id, 'token_endpoint'), tokenEndpoint);
}

function clientBody(
  app: App,
  id: string,
  tokenEndpoint: string,
): Record<string, string> {
  const pinned = app.secrets.get(S(id, 'client_token_origin'));
  const secret =
    !pinned || pinned === new URL(tokenEndpoint).origin
      ? app.secrets.get(S(id, 'client_secret'))
      : undefined;
  return {
    client_id: app.secrets.get(S(id, 'client_id')) ?? '',
    ...(secret ? { client_secret: secret } : {}),
  };
}

export async function mcpOauthExchange(
  app: App,
  code: string,
  state: string,
  server: (id: string) => McpServerConfig | undefined,
): Promise<{ serverId: string }> {
  const p = takePending<{
    serverId: string;
    serverUrl: string;
    verifier: string;
    redirectUri: string;
    tokenEndpoint: string;
  }>(app, 'mcp', state);
  const cur = server(p.serverId);
  if (!cur || cur.url !== p.serverUrl)
    throw new Error('The MCP server changed during sign-in. Start again.');
  const t = await tokenPost(
    app,
    p.tokenEndpoint,
    {
      grant_type: 'authorization_code',
      code,
      redirect_uri: p.redirectUri,
      code_verifier: p.verifier,
      resource: canonicalResource(p.serverUrl),
      ...clientBody(app, p.serverId, p.tokenEndpoint),
    },
    'MCP',
  );
  store(app, p.serverId, t, p.tokenEndpoint);
  app.db.run(
    "UPDATE mcp_servers SET status='ok', last_error=NULL WHERE id=?",
    p.serverId,
  );
  return { serverId: p.serverId };
}

export function setManualClient(
  app: App,
  id: string,
  clientId: string,
  clientSecret?: string,
): void {
  app.secrets.set(S(id, 'client_id'), clientId);
  app.secrets.set(S(id, 'client_manual'), '1');
  // Pinned again at the next sign-in.
  app.secrets.delete(S(id, 'client_token_origin'));
  if (clientSecret) app.secrets.set(S(id, 'client_secret'), clientSecret);
  else app.secrets.delete(S(id, 'client_secret'));
}

export const mcpSignedIn = (app: App, id: string) =>
  !!(
    app.secrets.get(S(id, 'access_token')) ||
    app.secrets.get(S(id, 'refresh_token'))
  );

export function clearMcpOauth(app: App, id: string): void {
  for (const x of app.secrets.list(oauthPrefix(id))) app.secrets.delete(x.name);
}

/** Sign out: drop the tokens, keep the client (registered or entered) and any bearer. */
export function signOutMcpOauth(app: App, id: string): void {
  for (const k of [
    'access_token',
    'refresh_token',
    'expires_at',
    'token_endpoint',
  ])
    app.secrets.delete(S(id, k));
  app.db.run(
    "UPDATE mcp_servers SET status='error', last_error=? WHERE id=?",
    SIGNED_OUT,
    id,
  );
}

const inflight = new Map<string, Promise<string>>();

function signInAgain(app: App, id: string): McpAuthError {
  app.db.run(
    "UPDATE mcp_servers SET status='error', last_error=? WHERE id=?",
    SIGN_IN_AGAIN,
    id,
  );
  return new McpAuthError(SIGN_IN_AGAIN);
}

/**
 * Only an OAuth error reply of the token endpoint (or no refresh token at all) means "sign in again". An
 * unreachable or failing sign-in server throws a plain error: the request fails and is retried later.
 */
function refreshToken(app: App, server: McpServerConfig): Promise<string> {
  const hit = inflight.get(server.id);
  if (hit) return hit;
  const run = (async () => {
    const rt = app.secrets.get(S(server.id, 'refresh_token'));
    const te = app.secrets.get(S(server.id, 'token_endpoint'));
    if (!rt || !te) throw signInAgain(app, server.id);
    let t: Awaited<ReturnType<typeof tokenPost>>;
    try {
      t = await tokenPost(
        app,
        te,
        {
          grant_type: 'refresh_token',
          refresh_token: rt,
          ...(server.url ? { resource: canonicalResource(server.url) } : {}),
          ...clientBody(app, server.id, te),
        },
        'MCP',
      );
    } catch (e) {
      if (e instanceof TokenError && e.kind === 'refused')
        throw signInAgain(app, server.id);
      throw e;
    }
    // Signed out, signed in anew or moved to another URL meanwhile: these tokens belong to nobody now.
    const url = app.db.get<{ url: string | null }>(
      'SELECT url FROM mcp_servers WHERE id=?',
      server.id,
    )?.url;
    const now = app.secrets.get(S(server.id, 'refresh_token'));
    if (!now || url !== server.url) throw new McpAuthError(SIGN_IN_GONE);
    // A new sign-in finished meanwhile: keep its tokens, drop these.
    if (now !== rt) {
      const cur = app.secrets.get(S(server.id, 'access_token'));
      if (cur) return cur;
      throw new McpAuthError(SIGN_IN_GONE);
    }
    store(app, server.id, t, te);
    return t.access_token;
  })().finally(() => inflight.delete(server.id));
  inflight.set(server.id, run);
  return run;
}

/** OAuth bearer for a server (refreshed at expiry - 60 s), or undefined when it has none (then a manual bearer is used). */
export async function mcpAccessToken(
  app: App,
  server: McpServerConfig,
  forceRefresh = false,
): Promise<string | undefined> {
  if (!mcpSignedIn(app, server.id)) return undefined;
  const cur = app.secrets.get(S(server.id, 'access_token'));
  const exp = Number(app.secrets.get(S(server.id, 'expires_at')) ?? 0);
  if (!forceRefresh && cur && exp - SKEW_MS > app.clock.now()) return cur;
  return refreshToken(app, server);
}
