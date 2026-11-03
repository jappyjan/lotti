import { z } from 'zod';
import type { App } from '../app.ts';
import type { AccountRow, McpServerConfig } from '../integrations/index.ts';
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

const mcpFields = {
  transport: z.enum(['http', 'stdio']),
  url: z.string().url().optional(),
  command: z.string().optional(),
  args: z.array(z.string()).optional(),
  enabled: z.boolean().optional(),
};

function accountRow(app: App, id: string): AccountRow | undefined {
  const r = app.db.get<{
    id: string;
    kind: string;
    label: string;
    config: string;
    status: string;
    last_error: string | null;
  }>('SELECT * FROM accounts WHERE id=?', id);
  return r
    ? {
        id: r.id,
        kind: r.kind,
        label: r.label,
        config: JSON.parse(r.config),
        status: r.status,
        lastError: r.last_error,
      }
    : undefined;
}

const bringStub = (app: App) => {
  if (!app.integrations.bring)
    throw new Error('The Bring! connector is not installed yet.');
  return app.integrations.bring;
};

export const integrationOps: Operation[] = [
  // ---- mcp -----------------------------------------------------------------------------------
  defineOp({
    name: 'mcp.list',
    group: 'mcp',
    description:
      'External MCP servers Lotti can use (config, status, per-tool confirmation flags).',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) =>
      app.db
        .all<McpRow>('SELECT * FROM mcp_servers ORDER BY created_at')
        .map(toMcp),
  }),
  defineOp({
    name: 'mcp.add',
    group: 'mcp',
    description:
      'Add an external MCP server (http URL or stdio command). Its tools need confirmation by default.',
    inputSchema: z.object({ name: z.string().min(1), ...mcpFields }),
    risk: 'tap',
    proposalTitle: (i) => `Add MCP server ${i.name}`,
    handler(i, { app }) {
      if (i.transport === 'http' && !i.url)
        throw new Error('url is required for http.');
      if (i.transport === 'stdio' && !i.command)
        throw new Error('command is required for stdio.');
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
    proposalTitle: (i) => `Change MCP server ${i.id}`,
    handler(i, { app }) {
      const cur = app.db.get<McpRow>(
        'SELECT * FROM mcp_servers WHERE id=?',
        i.id,
      );
      if (!cur) throw new Error('No such MCP server.');
      app.db.run(
        'UPDATE mcp_servers SET name=?, url=?, command=?, args=?, enabled=? WHERE id=?',
        i.name ?? cur.name,
        i.url ?? cur.url,
        i.command ?? cur.command,
        i.args ? JSON.stringify(i.args) : cur.args,
        i.enabled === undefined ? cur.enabled : i.enabled ? 1 : 0,
        i.id,
      );
      return { id: i.id };
    },
  }),
  defineOp({
    name: 'mcp.delete',
    group: 'mcp',
    description: 'Remove an MCP server.',
    inputSchema: z.object({ id: z.string() }),
    risk: 'tap',
    proposalTitle: (i) => `Remove MCP server ${i.id}`,
    handler(i, { app }) {
      const r = app.db.run('DELETE FROM mcp_servers WHERE id=?', i.id);
      if (!r.changes) throw new Error('No such MCP server.');
      return { deleted: i.id };
    },
  }),
  defineOp({
    name: 'mcp.test',
    group: 'mcp',
    description:
      'Connect to an MCP server and list its tools (runs its command for stdio servers).',
    inputSchema: z.object({ id: z.string() }),
    risk: 'tap',
    proposalTitle: (i) => `Test MCP server ${i.id}`,
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
      return r;
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
    proposalTitle: (i) =>
      `${i.needsConfirmation ? 'Require' : 'Skip'} confirmation for ${i.tool}`,
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
      kind: z.string().min(1),
      label: z.string().min(1),
      config: z.record(z.string(), z.unknown()).optional(),
    }),
    risk: 'tap',
    proposalTitle: (i) => `Add ${i.kind} account ${i.label}`,
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
    proposalTitle: (i) => `Change account ${i.id}`,
    handler(i, { app }) {
      const cur = accountRow(app, i.id);
      if (!cur) throw new Error('No such account.');
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
    proposalTitle: (i) => `Remove account ${i.id}`,
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

  // ---- bring (stub: integrations agent provides app.integrations.bring) ---------------------------------
  defineOp({
    name: 'bring.status',
    group: 'bring',
    description: 'Whether the Bring! shopping list is connected.',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => ({ connected: !!app.integrations.bring }),
  }),
  defineOp({
    name: 'bring.lists',
    group: 'bring',
    description: 'Bring! shopping lists.',
    inputSchema: z.object({}),
    risk: 'free',
    handler: (_i, { app }) => bringStub(app).lists(),
  }),
  defineOp({
    name: 'bring.items',
    group: 'bring',
    description: 'Items on a Bring! list.',
    inputSchema: z.object({ listId: z.string().optional() }),
    risk: 'free',
    handler: (i, { app }) => bringStub(app).items(i.listId),
  }),
  defineOp({
    name: 'bring.add',
    group: 'bring',
    description: 'Add an item to the Bring! shopping list.',
    inputSchema: z.object({
      item: z.string().min(1),
      spec: z.string().optional(),
      listId: z.string().optional(),
    }),
    risk: 'free',
    async handler(i, { app }) {
      const r = await bringStub(app).add(i.item, i.spec, i.listId);
      if (!r.ok) throw new Error(r.text);
      return out(
        { added: i.item },
        {
          text: r.text,
          undo: {
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
    description: 'Remove an item from the Bring! shopping list.',
    inputSchema: z.object({
      item: z.string().min(1),
      listId: z.string().optional(),
    }),
    risk: 'free',
    async handler(i, { app }) {
      const r = await bringStub(app).remove(i.item, i.listId);
      if (!r.ok) throw new Error(r.text);
      return out(
        { removed: i.item },
        {
          text: r.text,
          undo: {
            label: `Add ${i.item} again`,
            op: 'bring.add',
            input: { item: i.item, listId: i.listId },
          },
        },
      );
    },
  }),
];
