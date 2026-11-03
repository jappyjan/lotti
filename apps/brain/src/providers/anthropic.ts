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

export function toAnthropic(messages: ChatMessage[]): {
  system: string;
  messages: unknown[];
} {
  const system = messages
    .filter((m) => m.role === 'system')
    .map((m) => m.content)
    .join('\n\n');
  const out: { role: 'user' | 'assistant'; content: unknown[] }[] = [];
  const push = (role: 'user' | 'assistant', block: unknown) => {
    const last = out[out.length - 1];
    if (last && last.role === role) last.content.push(block);
    else out.push({ role, content: [block] });
  };
  for (const m of messages) {
    if (m.role === 'user') push('user', { type: 'text', text: m.content });
    else if (m.role === 'assistant') {
      if (m.content) push('assistant', { type: 'text', text: m.content });
      for (const c of m.toolCalls ?? [])
        push('assistant', {
          type: 'tool_use',
          id: c.id,
          name: c.name,
          input: c.args,
        });
    } else if (m.role === 'tool') {
      push('user', {
        type: 'tool_result',
        tool_use_id: m.toolCallId,
        content: m.content,
      });
    }
  }
  return { system, messages: out };
}

/** Anthropic Messages API with tools. Plain fetch. */
export class AnthropicProvider implements Provider {
  readonly kind = 'chat' as const;
  readonly id = 'anthropic';
  readonly label = 'Anthropic';
  readonly defaultModel = 'claude-sonnet-5-5';
  readonly knownModels = [
    'claude-sonnet-5-5',
    'claude-opus-4-5',
    'claude-haiku-4-5',
  ];
  constructor(private deps: HttpDeps) {}

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
      throw new ProviderError('Anthropic is not configured (no API key).');
    const conv = toAnthropic(messages);
    const body: Record<string, unknown> = {
      model: opts.model,
      max_tokens: opts.maxTokens ?? 4096,
      ...(conv.system ? { system: conv.system } : {}),
      messages: conv.messages,
      ...(opts.temperature !== undefined
        ? { temperature: opts.temperature }
        : {}),
    };
    if (tools.length)
      body.tools = tools.map((t) => ({
        name: t.name,
        description: t.description,
        input_schema: t.parameters,
      }));
    const res = await this.deps.fetch(
      this.deps.baseUrl().replace(/\/+$/, '') + '/v1/messages',
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify(body),
        ...(opts.signal ? { signal: opts.signal } : {}),
      },
    );
    opts.onActivity?.();
    if (!res.ok)
      throw new ProviderError(
        `Anthropic HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`,
        res.status,
      );
    const j: any = await res.json();
    let text = '';
    const toolCalls: ToolCall[] = [];
    for (const b of j.content ?? []) {
      if (b.type === 'text') text += b.text;
      else if (b.type === 'tool_use')
        toolCalls.push({ id: b.id, name: b.name, args: b.input ?? {} });
    }
    return { text, toolCalls };
  }

  async listModels(signal?: AbortSignal): Promise<string[]> {
    const key = this.deps.apiKey();
    if (!key) throw new ProviderError('not configured');
    const res = await this.deps.fetch(
      this.deps.baseUrl().replace(/\/+$/, '') + '/v1/models',
      {
        headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01' },
        ...(signal ? { signal } : {}),
      },
    );
    if (!res.ok) throw new ProviderError(`HTTP ${res.status}`, res.status);
    return ((await res.json()) as any).data.map((m: any) => String(m.id));
  }
}
