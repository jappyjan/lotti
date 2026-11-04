import type { AgentRuntimeProvider, RuntimeRequest } from './types.ts';

/**
 * STUBS for the subscription runtimes. The integrations agent replaces these with real
 * implementations (spawn `codex exec` / Claude Agent SDK, attach `req.mcpServers`, return the final text)
 * and registers them with `app.providers.register(...)` from src/integrations/register.ts.
 */
export class StubRuntime implements AgentRuntimeProvider {
  readonly kind = 'agent-runtime' as const;
  readonly defaultModel = '';
  readonly knownModels: string[] = [];
  constructor(
    readonly id: string,
    readonly label: string,
  ) {}
  configured(): boolean {
    return false;
  }
  async run(_req: RuntimeRequest): Promise<{ text: string }> {
    throw new Error(`${this.label} runtime is not implemented yet`);
  }
}

export const stubRuntimes = () => [
  new StubRuntime('codex', 'Codex (subscription)'),
  new StubRuntime('claude_code', 'Claude Code (subscription)'),
];
