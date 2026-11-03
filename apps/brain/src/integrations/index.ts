/**
 * EXTENSION POINTS for integrations (Bring!, calendar, mail, Google OAuth, MCP client,
 * Codex/Claude subscription runtimes, APNs, web search).
 *
 * The core never imports a concrete integration. `createApp()` (src/app.ts) takes an
 * `integrations` override and `main.ts` calls `registerIntegrations(app)` (src/integrations/register.ts),
 * which is where the integrations agent wires real implementations in. Everything below is optional
 * and the core degrades gracefully ("not connected") when a slot is empty.
 */
import type { App } from '../app.ts';
import type { InboxItem } from '../inbox.ts';

export interface CalendarEvent {
  id: string;
  title: string;
  start: number; // epoch ms
  end: number;
  location?: string;
}

/** Used by the built-in `meeting_soon` job and the catch-up brief. */
export interface CalendarSource {
  /** Events starting between `from` and `to` (epoch ms), sorted by start. */
  events(from: number, to: number): Promise<CalendarEvent[]>;
  /** Server action `create_calendar_event` runs this after `perform`. */
  createEvent?(args: Record<string, unknown>): Promise<ActionOutcome>;
}

export interface MailMessage {
  id: string;
  from: string;
  subject: string;
  snippet: string;
  receivedAt: number;
}

/** Used by the built-in `important_mail` job. */
export interface MailSource {
  /** Unread messages received after `since` (epoch ms). */
  unread(since: number): Promise<MailMessage[]>;
  /** Server action `send_mail_reply` runs this after `perform`. */
  sendReply?(args: Record<string, unknown>): Promise<ActionOutcome>;
}

export interface ActionOutcome {
  ok: boolean;
  text: string;
  undo?: { label: string; op: string; input: unknown };
}

export interface DeviceInfo {
  id: string;
  name: string;
  apnsToken?: string | null;
}

/** APNs hook. Called when an inbox item is created and no socket is open. */
export interface PushNotifier {
  notifyOffline(device: DeviceInfo, item: InboxItem): Promise<void>;
}

export interface McpServerConfig {
  id: string;
  name: string;
  transport: 'http' | 'stdio';
  url?: string | null;
  command?: string | null;
  args: string[];
  enabled: boolean;
  /** tool name -> { needsConfirmation } (default true: tap) */
  toolFlags: Record<string, { needsConfirmation: boolean }>;
}

/**
 * MCP *client* (talking to external MCP servers). The stub reports "not implemented".
 * The real one should, for every enabled server, `app.tools.register(...)` each remote tool with
 * `kind: 'server'` and `needsConfirmation` taken from `toolFlags` (default true -> the tool must
 * return a proposed action instead of calling; see `proposeServerAction` in tools/actions.ts).
 */
export interface McpClient {
  test(
    server: McpServerConfig,
  ): Promise<{ ok: boolean; tools?: string[]; error?: string }>;
  listTools(
    server: McpServerConfig,
  ): Promise<{ name: string; description?: string; inputSchema?: unknown }[]>;
  callTool(
    server: McpServerConfig,
    tool: string,
    args: unknown,
  ): Promise<string>;
}

export interface AccountRow {
  id: string;
  kind: string;
  label: string;
  config: Record<string, unknown>;
  status: string;
  lastError: string | null;
}

/** One per account kind (google, imap, caldav, bring, ...). Credentials live in `app.secrets` under `account.<id>.<key>`. */
export interface AccountConnector {
  kind: string;
  check(
    account: AccountRow,
    app: App,
  ): Promise<{ ok: boolean; status: string; error?: string }>;
}

/** Bring! shopping lists. `bring.*` ops delegate here; register matching tools if you like. */
export interface BringClient {
  lists(): Promise<{ id: string; name: string }[]>;
  items(listId?: string): Promise<{ name: string; spec?: string }[]>;
  add(item: string, spec?: string, listId?: string): Promise<ActionOutcome>;
  remove(item: string, listId?: string): Promise<ActionOutcome>;
}

export interface Integrations {
  calendar?: CalendarSource;
  mail?: MailSource;
  bring?: BringClient;
  push: PushNotifier;
  mcp: McpClient;
  connectors: Map<string, AccountConnector>;
}

export const notImplementedMcp: McpClient = {
  async test() {
    return { ok: false, error: 'MCP client not implemented yet' };
  },
  async listTools() {
    return [];
  },
  async callTool() {
    throw new Error('MCP client not implemented yet');
  },
};

export const noopPush: PushNotifier = {
  async notifyOffline() {},
};

export function defaultIntegrations(): Integrations {
  return { push: noopPush, mcp: notImplementedMcp, connectors: new Map() };
}
