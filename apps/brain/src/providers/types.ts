export interface ToolCall {
  id: string;
  name: string;
  args: Record<string, unknown>;
}

export type ChatMessage =
  | { role: 'system'; content: string }
  | { role: 'user'; content: string }
  | { role: 'assistant'; content: string; toolCalls?: ToolCall[] }
  | { role: 'tool'; toolCallId: string; name: string; content: string };

export interface ToolSpec {
  name: string;
  description: string;
  /** JSON Schema (object) */
  parameters: Record<string, unknown>;
}

export interface CompleteOptions {
  model: string;
  signal?: AbortSignal;
  /** Providers that stream call this on every chunk so the silence timeout can reset. */
  onActivity?: () => void;
  maxTokens?: number;
  temperature?: number;
}

export interface CompleteResult {
  text: string;
  toolCalls: ToolCall[];
}

/** Chat-completion style provider: one request -> text and/or tool calls. */
export interface Provider {
  readonly kind: 'chat';
  readonly id: string;
  readonly label: string;
  readonly defaultModel: string;
  /** Suggested model ids for the app's picker. */
  readonly knownModels: string[];
  configured(): boolean;
  complete(
    messages: ChatMessage[],
    tools: ToolSpec[],
    opts: CompleteOptions,
  ): Promise<CompleteResult>;
  /** Optional: live model list. */
  listModels?(signal?: AbortSignal): Promise<string[]>;
}

export interface RuntimeRequest {
  system: string;
  prompt: string;
  /** MCP servers the runtime should attach: Lotti's own tools server (internal token). */
  mcpServers: { name: string; url: string; bearerToken: string }[];
  signal?: AbortSignal;
  onStatus?: (line: string) => void;
  model?: string;
  /** Send as `X-Lotti-Ask` header to /mcp/tools so proposed actions land in this run. */
  askId?: string;
}

/**
 * "Agent-runtime" provider: a whole agent (Codex CLI / Claude Agent SDK subprocess) that runs its own
 * loop and calls Lotti's tools through `/mcp/tools`. Integrations agent: implement `run`, then
 * `app.providers.register(runtime)`; select it as active provider like any other.
 */
export interface AgentRuntimeProvider {
  readonly kind: 'agent-runtime';
  readonly id: string;
  readonly label: string;
  readonly defaultModel: string;
  readonly knownModels: string[];
  configured(): boolean;
  run(req: RuntimeRequest): Promise<{ text: string }>;
}

export type AnyProvider = Provider | AgentRuntimeProvider;

export class ProviderError extends Error {
  constructor(
    message: string,
    public status?: number,
  ) {
    super(message);
  }
}

export interface HttpDeps {
  fetch: typeof fetch;
  apiKey: () => string | undefined;
  baseUrl: () => string;
}
