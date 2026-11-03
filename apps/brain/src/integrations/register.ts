import type { App } from '../app.ts';

/**
 * Integrations agent: wire everything here (called once from main.ts after createApp()).
 *
 *   app.integrations.calendar = new GoogleCalendar(app)        // CalendarSource
 *   app.integrations.mail = new GmailSource(app)               // MailSource
 *   app.integrations.push = new ApnsPush(app.config.apns)      // PushNotifier
 *   app.integrations.mcp = new RealMcpClient(app)              // McpClient
 *   app.integrations.bring = new BringHttp(app)                // BringClient
 *   app.integrations.connectors.set('google', googleConnector) // AccountConnector
 *   app.providers.register(new CodexRuntime(app))              // agent-runtime provider (src/providers/agent-runtime.ts)
 *   app.tools.register({ name: 'web_search', ... })            // new tool (src/tools/registry.ts)
 *   app.ops.register({ name: 'google.start_oauth', risk: 'app_only', ... }) // new op (src/ops/registry.ts)
 *   app.actions.register('some_tool', async (args) => ({ ok: true, text: '...' })) // server action (perform)
 */
export function registerIntegrations(_app: App): void {
  // intentionally empty: all slots are stubs
}
