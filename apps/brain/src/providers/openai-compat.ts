import type {
  ChatMessage,
  CompleteOptions,
  CompleteResult,
  HttpDeps,
  Provider,
  ToolCall,
  ToolSpec,
} from './types.ts';
import { ProviderError } from './types.ts';

export function toOpenAiMessages(messages: ChatMessage[]): unknown[] {
  return messages.map((m) => {
    if (m.role === 'assistant') {
      return {
        role: 'assistant',
        content: m.content || null,
        ...(m.reasoning ? { reasoning_content: m.reasoning } : {}),
        ...(m.toolCalls?.length
          ? {
              tool_calls: m.toolCalls.map((c) => ({
                id: c.id,
                type: 'function',
                function: { name: c.name, arguments: JSON.stringify(c.args) },
              })),
            }
          : {}),
      };
    }
    if (m.role === 'tool')
      return { role: 'tool', tool_call_id: m.toolCallId, content: m.content };
    return { role: m.role, content: m.content };
  });
}

export function parseOpenAiResponse(json: any): CompleteResult {
  const msg = json?.choices?.[0]?.message;
  if (!msg) throw new ProviderError('Provider returned no message');
  const toolCalls: ToolCall[] = (msg.tool_calls ?? []).map(
    (c: any, i: number) => {
      let args: Record<string, unknown> = {};
      try {
        args = c.function?.arguments ? JSON.parse(c.function.arguments) : {};
      } catch {
        args = { _raw: String(c.function?.arguments) };
      }
      return { id: c.id ?? `call_${i}`, name: c.function?.name ?? '', args };
    },
  );
  return {
    text: typeof msg.content === 'string' ? msg.content : '',
    toolCalls,
    ...(typeof msg.reasoning_content === 'string' && msg.reasoning_content
      ? { reasoning: msg.reasoning_content }
      : {}),
  };
}

/** OpenAI-compatible chat completions (DeepSeek, OpenAI). Plain fetch, no SDK. */
export class OpenAiCompatProvider implements Provider {
  readonly kind = 'chat' as const;
  constructor(
    readonly id: string,
    readonly label: string,
    readonly defaultModel: string,
    readonly knownModels: string[],
    private deps: HttpDeps,
    private chatPath = '/chat/completions',
  ) {}

  configured(): boolean {
    return !!this.deps.apiKey();
  }

  async complete(
    messages: ChatMessage[],
    tools: ToolSpec[],
    opts: CompleteOptions,
  ): Promise<CompleteResult> {
    const key = this.deps.apiKey();
    if (!key)
      throw new ProviderError(`${this.label} is not configured (no API key).`);
    const body: Record<string, unknown> = {
      model: opts.model,
      messages: toOpenAiMessages(messages),
      ...(opts.maxTokens ? { max_tokens: opts.maxTokens } : {}),
      ...(opts.temperature !== undefined
        ? { temperature: opts.temperature }
        : {}),
      ...this.deps.extraBody?.(),
    };
    if (tools.length) {
      body.tools = tools.map((t) => ({
        type: 'function',
        function: {
          name: t.name,
          description: t.description,
          parameters: t.parameters,
        },
      }));
      body.tool_choice = 'auto';
    }
    const res = await this.deps.fetch(
      this.deps.baseUrl().replace(/\/+$/, '') + this.chatPath,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${key}`,
        },
        body: JSON.stringify(body),
        ...(opts.signal ? { signal: opts.signal } : {}),
      },
    );
    opts.onActivity?.();
    if (!res.ok)
      throw new ProviderError(
        `${this.label} HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`,
        res.status,
      );
    return parseOpenAiResponse(await res.json());
  }

  async listModels(signal?: AbortSignal): Promise<string[]> {
    const key = this.deps.apiKey();
    if (!key) throw new ProviderError('not configured');
    const res = await this.deps.fetch(
      this.deps.baseUrl().replace(/\/+$/, '') + '/models',
      {
        headers: { authorization: `Bearer ${key}` },
        ...(signal ? { signal } : {}),
      },
    );
    if (!res.ok) throw new ProviderError(`HTTP ${res.status}`, res.status);
    const j: any = await res.json();
    return (j.data ?? []).map((m: any) => String(m.id)).sort();
  }
}
