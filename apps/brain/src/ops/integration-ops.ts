import { z } from 'zod';
import type { App } from '../app.ts';
import type { AccountRow, McpServerConfig } from '../integrations/index.ts';
import {
  clearMcpOauth,
  isAuthError,
  mcpOauthExchange,
  mcpOauthStart,
  mcpSignedIn,
  setManualClient,
} from '../integrations/mcp/oauth.ts';
import { newId } from '../util/crypto.ts';
import { defineOp, out, type Operation } from './registry.ts';

// ---- MCP client config (stored in DB; the client itself is the integrations agent's) -------------

interface McpRow {
  id: string;
  name: string;
  transport: 'http' | 'stdio';
  url: string | null;
  command: string | null;
  args: string;
  enabled: number;
  tool_flags: string;
  status: string | null;
  last_error: string | null;
}
const toMcp = (
  r: McpRow,
): McpServerConfig & { status: string | null; lastError: string | null } => ({
  id: r.id,
  name: r.name,
  transport: r.transport,
  url: r.url,
  command: r.command,
  args: JSON.parse(r.args),
  enabled: !!r.enabled,
  toolFlags: JSON.parse(r.tool_flags),
  status: r.status,
  lastError: r.last_error,
});

/** For the MCP client: configured servers. Tools default to needsConfirmation = true (tap). */
export function loadMcpServers(app: App): McpServerConfig[] {
  return app.db
    .all<McpRow>('SELECT * FROM mcp_servers ORDER BY created_at')
    .map(toMcp);
}
export function mcpToolNeedsConfirmation(
  server: McpServerConfig,
  tool: string,
): boolean {
  return server.toolFlags[tool]?.needsConfirmation ?? true;
}

const mcpTarget = (i: {
  transport?: string | null;
  url?: string | null;
  command?: string | null;
  args?: string[];
}) =>
  i.transport === 'stdio' || (!i.url && i.command)
    ? `stdio: ${[i.command ?? '', ...(i.args ?? [])].join(' ')}`
    : `http: ${i.url ?? ''}`;

/** Env secrets belong to one program: a new command or new args drop them. */
const stdioTargetChanged = (
  cur: McpRow,
  i: { command?: string; args?: string[] },
) =>
  (i.command !== undefined && i.command !== cur.command) ||
  (i.args !== undefined && JSON.stringify(i.args) !== (cur.args ?? '[]'));

const mcpRow = (app: App, id: string) =>
  app.db.get<McpRow>('SELECT * FROM mcp_servers WHERE id=?', id);

/** What an mcp.update would change (only real changes), for the confirmation title. */
function mcpChanges(
  cur: McpRow | undefined,
  i: {
    name?: string;
    url?: string;
    command?: string;
    args?: string[];
    enabled?: boolean;
  },
): string[] {
  const out: string[] = [];
  if (i.name !== undefined && i.name !== cur?.name) out.push(`name ${i.name}`);
  if (i.url !== undefined && i.url !== cur?.url) out.push(`url ${i.url}`);
  if (i.command !== undefined && i.command !== cur?.command)
    out.push(`command ${i.command}`);
  if (i.args && JSON.stringify(i.args) !== (cur?.args ?? '[]'))
    out.push(`args ${i.args.join(' ')}`);
  if (i.enabled !== undefined && i.enabled !== !!cur?.enabled)
    out.push(i.enabled ? 'enable' : 'disable');
  return out;
}

/** Config keys that decide where an account's password is sent. */
const HOST_KEY = /url|host|port|secure/i;
function accountHostChanges(
  cur: Record<string, unknown>,
  next: Record<string, unknown>,
): string[] {
  return [...new Set([...Object.keys(cur), ...Object.keys(next)])]
    .filter((k) => HOST_KEY.test(k))
    .filter((k) => JSON.stringify(cur[k]) !== JSON.stringify(next[k]))
    .map(
      (k) => `${k} ${next[k] === undefined ? '(removed)' : String(next[k])}`,
    );
}

const mcpFields = {
  transport: z.enum(['http', 'stdio']),
  url: z.string().url().optional(),
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  enabled: z.boolean().optional(),
};

export function accountRow(app: App, id: string): AccountRow | undefined {
  const r = app.db.get<{
    id: string;
    kind: string;
    label: string;
    config: string;
    status: string;
    last_error: string | null;
    last_sync_at: number | null;
  }>('SELECT * FROM accounts WHERE id=?', id);
  return r
    ? {
        id: r.id,
        kind: r.kind,
        label: r.label,
        config: JSON.parse(r.config),
        status: r.status,
        lastError: r.last_error,
        lastSyncAt: r.last_sync_at ?? null,
      }
    : undefined;
}

/** Called after MCP server config changes: re-register remote tools. Failures are logged, never thrown. */
function refreshMcp(app: App): void {
  void app.integrations.mcp
    .refresh?.()
    .catch((e) => app.log.warn('mcp refresh failed', String(e)));
}

const bringStub = (app: App) => {
  if (!app.integrations.bring)
    throw new Error('The Bring! connector is not installed yet.');
  return app.integrations.bring;
};

/** The item as it is on the list now (name match ignores case), so undo can restore it. Best effort. */
async function bringFind(
  b: NonNullable<App['integrations']['bring']>,
  item: string,
  listId?: string,
): Promise<{ name: string; spec?: string } | undefined> {
  try {
    const key = item.trim().toLowerCase();
    return (await b.items(listId)).find(
      (x) => x.name.trim().toLowerCase() === key,
    );
  } catch {
    return undefined;
  }
}

export const integrationOps: Operation[] = [
  // ---- mcp -----------------------------------------------------------------------------------
  defineOp({
    name: 'mcp.list',
    group: 'mcp',
    description:
      'External MCP servers Lotti can use (config, status, per-tool confirmation flags, whether a credential is saved).',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) =>
      app.db
        .all<McpRow>('SELECT * FROM mcp_servers ORDER BY created_at')
        .map((r) => ({
          ...toMcp(r),
          // Counts OAuth secrets too (mcp.<id>.oauth.*), never returns any.
          hasCredential: app.secrets.list(`mcp.${r.id}.`).length > 0,
          signedIn: mcpSignedIn(app, r.id),
          authRequired: r.status === 'error' && isAuthError(r.last_error),
        })),
  }),
  defineOp({
    name: 'mcp.add',
    group: 'mcp',
    description:
      'Add an external MCP server (http URL or stdio command). Its tools need confirmation by default.',
    inputSchema: z.object({ name: z.string().min(1), ...mcpFields }),
    risk: 'tap',
    proposalTitle: (i) => `Add MCP server "${i.name}" (${mcpTarget(i)})`,
    handler(i, { app }) {
      if (i.transport === 'http' && !i.url)
        throw new Error('url is required for http.');
      if (i.transport === 'stdio' && !i.command)
        throw new Error('command is required for stdio.');
      if (app.db.get('SELECT 1 AS x FROM mcp_servers WHERE name=?', i.name))
        throw new Error(`An MCP server named "${i.name}" already exists.`);
      const id = newId('mcp_');
      app.db.run(
        'INSERT INTO mcp_servers(id,name,transport,url,command,args,enabled,created_at) VALUES(?,?,?,?,?,?,?,?)',
        id,
        i.name,
        i.transport,
        i.url ?? null,
        i.command ?? null,
        JSON.stringify(i.args ?? []),
        i.enabled === false ? 0 : 1,
        app.clock.now(),
      );
      refreshMcp(app);
      return out(
        { id },
        {
          undo: {
            label: `Remove MCP server ${i.name}`,
            op: 'mcp.delete',
            input: { id },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'mcp.update',
    group: 'mcp',
    description: 'Change an MCP server (url, command, args, enabled, name).',
    inputSchema: z.object({
      id: z.string(),
      name: z.string().optional(),
      url: z.string().url().optional(),
      command: z.string().optional(),
      args: z.array(z.string()).optional(),
      enabled: z.boolean().optional(),
    }),
    risk: 'tap',
    proposalTitle(i, app) {
      const cur = mcpRow(app, i.id);
      const ch = mcpChanges(cur, i);
      const secrets =
        cur &&
        ((i.url !== undefined && i.url !== cur.url) ||
          stdioTargetChanged(cur, i)) &&
        app.secrets.list(`mcp.${cur.id}.`).length
          ? ' (its saved credential is removed)'
          : '';
      return `Change MCP server "${cur?.name ?? i.id}": ${ch.join(', ') || 'no change'}${secrets}`;
    },
    handler(i, { app }) {
      const cur = mcpRow(app, i.id);
      if (!cur) throw new Error('No such MCP server.');
      // A saved bearer / OAuth login / env secret must never follow the server to a new address or command.
      if (i.url !== undefined && i.url !== cur.url) {
        app.secrets.delete(`mcp.${cur.id}.bearer`);
        clearMcpOauth(app, cur.id);
      }
      if (stdioTargetChanged(cur, i))
        for (const x of app.secrets.list(`mcp.${cur.id}.env.`))
          app.secrets.delete(x.name);
      app.db.run(
        'UPDATE mcp_servers SET name=?, url=?, command=?, args=?, enabled=? WHERE id=?',
        i.name ?? cur.name,
        i.url ?? cur.url,
        i.command ?? cur.command,
        i.args ? JSON.stringify(i.args) : cur.args,
        i.enabled === undefined ? cur.enabled : i.enabled ? 1 : 0,
        i.id,
      );
      refreshMcp(app);
      return { id: i.id };
    },
  }),
  defineOp({
    name: 'mcp.delete',
    group: 'mcp',
    description: 'Remove an MCP server.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'tap',
    proposalTitle: (i, app) =>
      `Remove MCP server "${mcpRow(app, i.id)?.name ?? i.id}"`,
    handler(i, { app }) {
      const r = app.db.run('DELETE FROM mcp_servers WHERE id=?', i.id);
      if (!r.changes) throw new Error('No such MCP server.');
      for (const x of app.secrets.list(`mcp.${i.id}.`))
        app.secrets.delete(x.name);
      refreshMcp(app);
      return { deleted: i.id };
    },
  }),
  defineOp({
    name: 'mcp.test',
    group: 'mcp',
    description:
      'Connect to an MCP server and list its tools (runs its command for stdio servers).',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    async handler(i, { app }) {
      const row = app.db.get<McpRow>(
        'SELECT * FROM mcp_servers WHERE id=?',
        i.id,
      );
      if (!row) throw new Error('No such MCP server.');
      const r = await app.integrations.mcp.test(toMcp(row));
      app.db.run(
        'UPDATE mcp_servers SET status=?, last_error=? WHERE id=?',
        r.ok ? 'ok' : 'error',
        r.error ?? null,
        i.id,
      );
      if (r.ok) refreshMcp(app);
      return {
        ...r,
        authRequired: r.authRequired ?? false,
        signedIn: mcpSignedIn(app, i.id),
      };
    },
  }),
  defineOp({
    name: 'mcp.tools',
    group: 'mcp',
    description:
      'Tools of an MCP server with description and whether each needs confirmation (connects to the server).',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    async handler(i, { app }) {
      const row = app.db.get<McpRow>(
        'SELECT * FROM mcp_servers WHERE id=?',
        i.id,
      );
      if (!row) throw new Error('No such MCP server.');
      const srv = toMcp(row);
      const tools = await app.integrations.mcp.listTools(srv);
      return tools.map((t) => ({
        name: t.name,
        description: t.description ?? '',
        needsConfirmation: mcpToolNeedsConfirmation(srv, t.name),
      }));
    },
  }),
  defineOp({
    name: 'mcp.set_credential',
    group: 'mcp',
    description:
      'Store a secret for an MCP server: key "bearer" (HTTP Authorization bearer token) or "env.NAME" (environment variable for stdio servers). Write-only.',
    inputSchema: z.object({
      id: z.string(),
      key: z.string().regex(/^(bearer|env\.[A-Za-z_][A-Za-z0-9_]*)$/),
      value: z.string().min(1),
    }),
    risk: 'app_only',
    handler(i, { app }) {
      if (!app.db.get('SELECT 1 AS x FROM mcp_servers WHERE id=?', i.id))
        throw new Error('No such MCP server.');
      app.secrets.set(`mcp.${i.id}.${i.key}`, i.value);
      refreshMcp(app);
      return { id: i.id, key: i.key, set: true };
    },
  }),
  defineOp({
    name: 'mcp.clear_credential',
    group: 'mcp',
    description:
      'Delete every stored secret of an MCP server (bearer token, OAuth sign-in and env.* values): also signs out.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'app_only',
    handler(i, { app }) {
      if (!mcpRow(app, i.id)) throw new Error('No such MCP server.');
      const names = app.secrets.list(`mcp.${i.id}.`).map((x) => x.name);
      for (const n of names) app.secrets.delete(n);
      refreshMcp(app);
      return { id: i.id, removed: names.length, hasCredential: false };
    },
  }),
  defineOp({
    name: 'mcp.oauth_start',
    group: 'mcp',
    description:
      'Start OAuth sign-in to an HTTP MCP server: discovers the authorization server, registers a client when the server allows it, returns {url, state, redirectUri, callbackScheme}. The app opens url in a web auth session; then call mcp.oauth_exchange with the code and state.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'app_only',
    async handler(i, { app }) {
      const row = mcpRow(app, i.id);
      if (!row) throw new Error('No such MCP server.');
      return mcpOauthStart(app, toMcp(row));
    },
  }),
  defineOp({
    name: 'mcp.oauth_exchange',
    group: 'mcp',
    description:
      'Finish MCP sign-in: the app sends the code and state from the redirect; the backend stores the tokens (encrypted). Returns {id, signedIn}.',
    inputSchema: z.object({
      code: z.string().min(1),
      state: z.string().min(1),
    }),
    risk: 'app_only',
    async handler(i, { app }) {
      const r = await mcpOauthExchange(app, i.code, i.state, (id: string) => {
        const row = mcpRow(app, id);
        return row ? toMcp(row) : undefined;
      });
      refreshMcp(app);
      return { id: r.serverId, signedIn: true };
    },
  }),
  defineOp({
    name: 'mcp.oauth_set_client',
    group: 'mcp',
    description:
      'Use a registered OAuth client for an MCP server that has no automatic client registration (clientId, optional clientSecret). Write-only.',
    inputSchema: z.object({
      id: z.string(),
      clientId: z.string().max(512),
      clientSecret: z.string().max(2048).optional(),
    }),
    risk: 'app_only',
    handler(i, { app }) {
      if (!mcpRow(app, i.id)) throw new Error('No such MCP server.');
      const clientId = i.clientId.trim();
      if (!clientId) throw new Error('Client id is empty.');
      setManualClient(app, i.id, clientId, i.clientSecret?.trim() || undefined);
      return { id: i.id, configured: true };
    },
  }),
  defineOp({
    name: 'mcp.set_tool_confirmation',
    group: 'mcp',
    description:
      "Set whether calling one tool of an MCP server needs the user's tap (default yes).",
    inputSchema: z.object({
      id: z.string(),
      tool: z.string(),
      needsConfirmation: z.boolean(),
    }),
    risk: 'tap',
    proposalTitle: (i, app) =>
      `${i.needsConfirmation ? 'Require' : 'Skip'} confirmation for ${i.tool} on MCP server "${mcpRow(app, i.id)?.name ?? i.id}"`,
    handler(i, { app }) {
      const row = app.db.get<McpRow>(
        'SELECT * FROM mcp_servers WHERE id=?',
        i.id,
      );
      if (!row) throw new Error('No such MCP server.');
      const flags = JSON.parse(row.tool_flags);
      const prev = flags[i.tool]?.needsConfirmation ?? true;
      flags[i.tool] = { needsConfirmation: i.needsConfirmation };
      app.db.run(
        'UPDATE mcp_servers SET tool_flags=? WHERE id=?',
        JSON.stringify(flags),
        i.id,
      );
      refreshMcp(app);
      return out(
        { id: i.id, tool: i.tool, needsConfirmation: i.needsConfirmation },
        {
          undo: {
            label: 'Revert confirmation flag',
            op: 'mcp.set_tool_confirmation',
            input: { id: i.id, tool: i.tool, needsConfirmation: prev },
          },
        },
      );
    },
  }),

  // ---- accounts (config + status only; connectors are integrations) ---------------------------------
  defineOp({
    name: 'accounts.list',
    group: 'accounts',
    description:
      'Connected accounts (google, mail, calendar, ...) with status. Credentials are never shown.',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) =>
      app.db
        .all<{ id: string }>('SELECT id FROM accounts ORDER BY created_at')
        .map((r) => accountRow(app, r.id)),
  }),
  defineOp({
    name: 'accounts.add',
    group: 'accounts',
    description:
      'Add an account entry (kind, label, non-secret config). Credentials go in via accounts.set_credential in the app.',
    inputSchema: z.object({
      kind: z.enum(['google', 'icloud', 'imap', 'caldav', 'ics']),
      label: z.string().min(1),
      config: z.record(z.string(), z.unknown()).optional(),
    }),
    risk: 'tap',
    proposalTitle: (i) => {
      const hosts = accountHostChanges({}, i.config ?? {});
      return `Add ${i.kind} account "${i.label}"${hosts.length ? `: ${hosts.join(', ')}` : ''}`;
    },
    handler(i, { app }) {
      const id = newId('acc_');
      app.db.run(
        'INSERT INTO accounts(id,kind,label,config,created_at) VALUES(?,?,?,?,?)',
        id,
        i.kind,
        i.label,
        JSON.stringify(i.config ?? {}),
        app.clock.now(),
      );
      return { id };
    },
  }),
  defineOp({
    name: 'accounts.update',
    group: 'accounts',
    description: 'Change an account label or non-secret config.',
    inputSchema: z.object({
      id: z.string(),
      label: z.string().optional(),
      config: z.record(z.string(), z.unknown()).optional(),
    }),
    risk: 'tap',
    proposalTitle(i, app) {
      const cur = accountRow(app, i.id);
      const hosts = i.config
        ? accountHostChanges(cur?.config ?? {}, i.config)
        : [];
      const label =
        i.label !== undefined && i.label !== cur?.label
          ? [`label ${i.label}`]
          : [];
      const pw =
        hosts.length && cur && app.secrets.get(`account.${cur.id}.password`)
          ? ' (saved password is removed: enter it again)'
          : '';
      return `Change account "${cur?.label ?? i.id}": ${[...label, ...hosts].join(', ') || 'settings'}${pw}`;
    },
    handler(i, { app }) {
      const cur = accountRow(app, i.id);
      if (!cur) throw new Error('No such account.');
      // The saved password must never be sent to a host the user did not enter it for.
      if (i.config && accountHostChanges(cur.config, i.config).length)
        app.secrets.delete(`account.${cur.id}.password`);
      app.db.run(
        'UPDATE accounts SET label=?, config=? WHERE id=?',
        i.label ?? cur.label,
        JSON.stringify(i.config ?? cur.config),
        i.id,
      );
      return { id: i.id };
    },
  }),
  defineOp({
    name: 'accounts.delete',
    group: 'accounts',
    description: 'Remove an account and its stored credentials.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'tap',
    proposalTitle: (i, app) =>
      `Remove account "${accountRow(app, i.id)?.label ?? i.id}"`,
    handler(i, { app }) {
      for (const s of app.secrets.list(`account.${i.id}.`))
        app.secrets.delete(s.name);
      if (!app.db.run('DELETE FROM accounts WHERE id=?', i.id).changes)
        throw new Error('No such account.');
      return { deleted: i.id };
    },
  }),
  defineOp({
    name: 'accounts.set_credential',
    group: 'accounts',
    description:
      'Store a credential for an account (password, token, refresh token). Write-only.',
    inputSchema: z.object({
      id: z.string(),
      key: z.string().min(1),
      value: z.string().min(1),
    }),
    risk: 'app_only',
    handler(i, { app }) {
      if (!accountRow(app, i.id)) throw new Error('No such account.');
      app.secrets.set(`account.${i.id}.${i.key}`, i.value);
      return { id: i.id, key: i.key, set: true };
    },
  }),
  defineOp({
    name: 'accounts.check',
    group: 'accounts',
    description:
      'Check an account connection with its connector and store the status.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'free',
    async handler(i, { app }) {
      const acc = accountRow(app, i.id);
      if (!acc) throw new Error('No such account.');
      const c = app.integrations.connectors.get(acc.kind);
      const r = c
        ? await c.check(acc, app)
        : {
            ok: false,
            status: 'not_connected',
            error: `No connector for "${acc.kind}" installed yet.`,
          };
      app.db.run(
        'UPDATE accounts SET status=?, last_error=? WHERE id=?',
        r.status,
        r.error ?? null,
        i.id,
      );
      return r;
    },
  }),

  // ---- bring ---------------------------------------------------------------------------------------
  defineOp({
    name: 'bring.status',
    group: 'bring',
    description:
      'Whether the Bring! shopping list is connected (login works) and the default list.',
    inputSchema: z.object({}),
    risk: 'free',
    async handler(_i, { app }) {
      const b = app.integrations.bring;
      if (!b) return { connected: false };
      return b.status ? await b.status() : { connected: true };
    },
  }),
  defineOp({
    name: 'bring.lists',
    group: 'bring',
    description: 'Bring! shopping lists (id, name).',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => bringStub(app).lists(),
  }),
  defineOp({
    name: 'bring.items',
    group: 'bring',
    description:
      'Items on a Bring! list (name, spec like "2 l"). Without listId: the default list.',
    inputSchema: z.object({ listId: z.string().optional() }),
    risk: 'free',
    handler: (i, { app }) => bringStub(app).items(i.listId),
  }),
  defineOp({
    name: 'bring.recent',
    group: 'bring',
    description:
      'Recently used Bring! items (what was bought lately; good suggestions).',
    inputSchema: z.object({ listId: z.string().optional() }),
    risk: 'free',
    async handler(i, { app }) {
      const b = bringStub(app);
      if (!b.recent) throw new Error('Recently used items are not available.');
      return b.recent(i.listId);
    },
  }),
  defineOp({
    name: 'bring.set_default_list',
    group: 'bring',
    description: 'Choose the default Bring! list (id from bring.lists).',
    inputSchema: z.object({ listId: z.string().min(1) }),
    risk: 'free',
    handler(i, { app }) {
      const prev = app.settings.str('bring.default_list');
      app.settings.set('bring.default_list', i.listId);
      return out(
        { defaultList: i.listId },
        {
          undo: {
            label: 'Default list back',
            op: 'bring.set_default_list',
            input: { listId: prev || i.listId },
          },
        },
      );
    },
  }),
  defineOp({
    name: 'bring.login',
    group: 'bring',
    description:
      'Save the Bring! login (email + password, stored encrypted, write-only) and check it works.',
    inputSchema: z.object({
      email: z.string().min(3),
      password: z.string().min(1),
    }),
    risk: 'app_only',
    async handler(i, { app }) {
      let id = app.db.get<{ id: string }>(
        "SELECT id FROM accounts WHERE kind='bring' ORDER BY created_at LIMIT 1",
      )?.id;
      if (!id) {
        id = newId('acc_');
        app.db.run(
          'INSERT INTO accounts(id,kind,label,config,created_at) VALUES(?,?,?,?,?)',
          id,
          'bring',
          'Bring!',
          '{}',
          app.clock.now(),
        );
      }
      app.secrets.set(`account.${id}.email`, i.email);
      app.secrets.set(`account.${id}.password`, i.password);
      const acc = accountRow(app, id)!;
      const r = await app.integrations.connectors.get('bring')?.check(acc, app);
      const res = r ?? {
        ok: false,
        status: 'not_connected',
        error: 'No Bring! connector installed.',
      };
      app.db.run(
        'UPDATE accounts SET status=?, last_error=? WHERE id=?',
        res.status,
        res.error ?? null,
        id,
      );
      return { accountId: id, ...res };
    },
  }),
  defineOp({
    name: 'bring.add',
    group: 'bring',
    description:
      'Add an item to the Bring! shopping list at once (spec e.g. "2 l"). Returns a Done line and an undo.',
    inputSchema: z.object({
      item: z.string().min(1),
      spec: z.string().optional(),
      listId: z.string().optional(),
      locale: z.enum(['de', 'en']).optional(),
    }),
    risk: 'free',
    async handler(i, { app }) {
      const b = bringStub(app);
      const before = await bringFind(b, i.item, i.listId);
      const r = await b.add(i.item, i.spec, i.listId, i.locale);
      if (!r.ok) throw new Error(r.text);
      // Undo restores what was there: the old specification if the item was already on the list.
      return out(
        { added: i.item },
        {
          text: r.text,
          undo: before
            ? {
                label: `${i.item} back to ${before.spec || 'no specification'}`,
                op: 'bring.add',
                input: {
                  item: before.name,
                  ...(before.spec ? { spec: before.spec } : { spec: '' }),
                  listId: i.listId,
                },
              }
            : {
                label: `Remove ${i.item} again`,
                op: 'bring.remove',
                input: { item: i.item, listId: i.listId },
              },
        },
      );
    },
  }),
  defineOp({
    name: 'bring.remove',
    group: 'bring',
    description:
      'Take an item off the Bring! shopping list (checks it off, like ticking it in the app). Returns a Done line and an undo.',
    inputSchema: z.object({
      item: z.string().min(1),
      listId: z.string().optional(),
      locale: z.enum(['de', 'en']).optional(),
    }),
    risk: 'free',
    async handler(i, { app }) {
      const b = bringStub(app);
      const before = await bringFind(b, i.item, i.listId);
      const r = await b.remove(i.item, i.listId, i.locale);
      if (!r.ok) throw new Error(r.text);
      return out(
        { removed: i.item },
        {
          text: r.text,
          undo: {
            label: `Add ${i.item} again`,
            op: 'bring.add',
            input: {
              item: before?.name ?? i.item,
              ...(before?.spec ? { spec: before.spec } : {}),
              listId: i.listId,
            },
          },
        },
      );
    },
  }),
];
