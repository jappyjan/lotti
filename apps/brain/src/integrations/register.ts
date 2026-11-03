import type { App } from '../app.ts';
import { bringConnector, BringHttp } from './bring/index.ts';
import { calendarEventsTool } from './calendar/tool.ts';
import { MergedCalendar } from './calendar/source.ts';
import { connectorKinds, makeConnector } from './connectors.ts';
import { McpClientImpl } from './mcp/client.ts';
import { MergedMail } from './mail/source.ts';
import { mailReadTool, mailSearchTool } from './mail/tools.ts';
import { accountOps } from './ops.ts';
import { ApnsPush } from './push/apns.ts';
import { ClaudeRuntime } from './runtimes/claude.ts';
import { CodexRuntime } from './runtimes/codex.ts';
import { webSearchTool } from './search/web-search.ts';

/** Wires every integration into the app (called once from main.ts after createApp()). */
export function registerIntegrations(app: App): void {
  const i = app.integrations;
  i.bring = new BringHttp(app);
  i.connectors.set('bring', bringConnector);
  for (const k of connectorKinds) i.connectors.set(k, makeConnector(k));

  // The `create_calendar_event` server action (tools/proposals.ts) runs i.calendar.createEvent.
  i.calendar = new MergedCalendar(app);
  const mail = new MergedMail(app);
  i.mail = mail;

  i.push = new ApnsPush(app);
  const mcp = new McpClientImpl(app);
  i.mcp = mcp;

  app.providers.register(new CodexRuntime(app));
  app.providers.register(new ClaudeRuntime(app));

  for (const t of [
    calendarEventsTool,
    mailSearchTool,
    mailReadTool,
    webSearchTool,
  ])
    app.tools.register(t);
  for (const op of accountOps) app.ops.register(op);

  // Remote MCP tools register themselves once the servers answer (does not block start-up).
  void mcp
    .refresh()
    .catch((e) => app.log.warn('mcp refresh failed', String(e)));
}
