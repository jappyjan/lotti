import type { App } from '../app.ts';
import { jsonSchemaOf } from '../ops/registry.ts';
import { newRun } from '../tools/registry.ts';

type Mode = 'admin' | 'tools';

interface RpcRequest {
  jsonrpc: '2.0';
  id?: string | number | null;
  method: string;
  params?: any;
}

/**
 * Minimal MCP server (streamable HTTP, JSON responses, stateless):
 *  - /mcp/admin : admin ops as tools (never app_only; tap ops return a proposal), admin token.
 *  - /mcp/tools : the agent's tool registry for subscription runtimes, internal token.
 *    Optional header `X-Lotti-Ask: <askId>` attaches proposed actions to that run.
 */
export async function handleMcp(
  app: App,
  mode: Mode,
  body: unknown,
  headers: Record<string, string | string[] | undefined>,
): Promise<unknown | null> {
  if (Array.isArray(body)) {
    const rs = (
      await Promise.all(
        body.map((b) => handleOne(app, mode, b as RpcRequest, headers)),
      )
    ).filter((r) => r !== null);
    return rs.length ? rs : null;
  }
  return handleOne(app, mode, body as RpcRequest, headers);
}

async function handleOne(
  app: App,
  mode: Mode,
  req: RpcRequest,
  headers: Record<string, string | string[] | undefined>,
): Promise<unknown | null> {
  const isNotification = req.id === undefined;
  const ok = (result: unknown) =>
    isNotification ? null : { jsonrpc: '2.0', id: req.id, result };
  const err = (code: number, message: string) =>
    isNotification
      ? null
      : { jsonrpc: '2.0', id: req.id ?? null, error: { code, message } };
  switch (req.method) {
    case 'initialize':
      return ok({
        protocolVersion: req.params?.protocolVersion ?? '2025-03-26',
        capabilities: { tools: { listChanged: false } },
        serverInfo: {
          name: mode === 'admin' ? 'lotti-admin' : 'lotti-tools',
          version: app.config.version,
        },
      });
    case 'ping':
      return ok({});
    case 'tools/list':
      return ok({ tools: listTools(app, mode) });
    case 'tools/call': {
      const name = String(req.params?.name ?? '');
      const args = req.params?.arguments ?? {};
      if (mode === 'admin') {
        const op = app.ops
          .visibleTo('mcp')
          .find((o) => o.name.replace('.', '_') === name);
        if (!op)
          return ok({
            isError: true,
            content: [{ type: 'text', text: `Unknown tool: ${name}` }],
          });
        const r = await app.ops.invoke(op.name, args, 'mcp');
        // Nobody is on the other end to tap: surface the proposal in the app's inbox to confirm.
        if (r.ok && r.proposed)
          app.actions.toInbox(
            r.proposed,
            'Requested through the admin MCP. Confirm to apply.',
          );
        return ok({
          isError: !r.ok,
          content: [{ type: 'text', text: r.ok ? r.text : r.error }],
        });
      }
      const askId =
        typeof headers['x-lotti-ask'] === 'string'
          ? headers['x-lotti-ask']
          : undefined;
      const attached = askId ? app.runs.get(askId) : undefined;
      const run = attached ?? newRun();
      const r = await app.tools.call(name, args, { app, run });
      let text = r.text;
      // No live ask to show the proposal on (header lost, run already over): the inbox is the next best
      // place; dropping it would leave the model saying "tap to confirm" with nothing to tap.
      if (!attached && run.actions.length) {
        app.log.warn(
          `tool ${name} proposed ${run.actions.length} action(s) but no live ask matches "${askId ?? ''}": parked in the inbox`,
        );
        for (const a of run.actions)
          app.actions.toInbox(a, 'Lotti proposed this. Confirm to apply.');
        text += ' It is waiting in the app\'s inbox for the user to confirm.';
      }
      return ok({ isError: !r.ok, content: [{ type: 'text', text }] });
    }
    default:
      if (req.method?.startsWith('notifications/')) return null;
      return err(-32601, `Method not found: ${req.method}`);
  }
}

function listTools(app: App, mode: Mode) {
  if (mode === 'admin') {
    return app.ops.visibleTo('mcp').map((o) => ({
      name: o.name.replace('.', '_'),
      description: `${o.description}${o.risk === 'tap' ? ' (proposes an action the user must confirm in the app)' : ''}`,
      inputSchema: jsonSchemaOf(o.inputSchema),
    }));
  }
  return app.tools.all().map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: t.jsonSchema ?? jsonSchemaOf(t.inputSchema),
  }));
}
