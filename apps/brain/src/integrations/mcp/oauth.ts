import type { App } from '../../app.ts';
import {
  APP_REDIRECT,
  newPkce,
  newState,
  publicUrl,
  savePending,
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
export const SIGN_IN_AGAIN = 'MCP sign-in expired: sign in again in the app.';
/** True for errors that mean "the user has to sign in (again)". */
export const isAuthError = (msg: string | null | undefined) =>
  !!msg && (msg.includes(AUTH_REFUSED) || msg.includes('sign in again'));

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
      `Cannot reach the MCP server at ${publicUrl(url)}: ${e instanceof Error ? e.message : e}`,
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

async function register(
  app: App,
  endpoint: string,
  redirectUri: string,
  scope?: string,
): Promise<string> {
  const res = await app.fetch(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json' },
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
  const j: any = await res.json().catch(() => ({}));
  if (!res.ok || !j.client_id)
    throw new Error(
      `The server refused the automatic client registration (${j.error_description ?? j.error ?? res.status}): enter a client id in the app.`,
    );
  return String(j.client_id);
}

export interface McpOauthStart {
  url: string;
  state: string;
  redirectUri: string;
  callbackScheme: string;
}

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
      throw new Error(
        'This server has no automatic client registration: enter a client id (and secret) in the app.',
      );
    clientId = await register(
      app,
      d.registration_endpoint,
      redirectUri,
      d.scope,
    );
    app.secrets.set(S(server.id, 'client_id'), clientId);
    app.secrets.set(S(server.id, 'client_redirect'), redirectUri);
  }
  if (!clientId) throw new Error('Enter a client id for this server first.');
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
    resource: server.url,
    ...(d.scope ? { scope: d.scope } : {}),
  }))
    au.searchParams.set(k, v);
  return { url: au.href, state, redirectUri, callbackScheme: 'lotti' };
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

function clientBody(app: App, id: string): Record<string, string> {
  const secret = app.secrets.get(S(id, 'client_secret'));
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
      resource: p.serverUrl,
      ...clientBody(app, p.serverId),
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

const inflight = new Map<string, Promise<string>>();

function refreshToken(app: App, server: McpServerConfig): Promise<string> {
  const hit = inflight.get(server.id);
  if (hit) return hit;
  const run = (async () => {
    const rt = app.secrets.get(S(server.id, 'refresh_token'));
    const te = app.secrets.get(S(server.id, 'token_endpoint'));
    try {
      if (!rt || !te) throw new Error('no refresh token');
      const t = await tokenPost(
        app,
        te,
        {
          grant_type: 'refresh_token',
          refresh_token: rt,
          ...(server.url ? { resource: server.url } : {}),
          ...clientBody(app, server.id),
        },
        'MCP',
      );
      store(app, server.id, t, te);
      return t.access_token;
    } catch {
      app.db.run(
        "UPDATE mcp_servers SET status='error', last_error=? WHERE id=?",
        SIGN_IN_AGAIN,
        server.id,
      );
      throw new Error(SIGN_IN_AGAIN);
    }
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
