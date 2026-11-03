import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { App } from '../../app.ts';
import type {
  AgentRuntimeProvider,
  RuntimeRequest,
} from '../../providers/types.ts';
import { baseEnv, runProc, stripAnsi } from './proc.ts';

/**
 * Claude subscription via `claude -p`. Auth: a long-lived token from `claude setup-token`, pasted in the app
 * as the provider credential (providers.set_credential claude_code). Lotti's tools are attached as an MCP
 * server (/mcp/tools); Claude's built-in tools are switched off.
 */
export class ClaudeRuntime implements AgentRuntimeProvider {
  readonly kind = 'agent-runtime' as const;
  readonly id = 'claude_code';
  readonly label = 'Claude Code (subscription)';
  readonly defaultModel = '';
  readonly knownModels = ['sonnet', 'opus', 'haiku'];
  constructor(
    private app: App,
    private bin = 'claude',
  ) {}

  private token(): string | undefined {
    return this.app.secrets.get('provider.claude_code.api_key');
  }
  configured(): boolean {
    return !!this.token();
  }

  async run(req: RuntimeRequest): Promise<{ text: string }> {
    const token = this.token();
    if (!token)
      throw new Error(
        'Claude Code has no token: run `claude setup-token` and paste it in the app.',
      );
    const configDir = join(this.app.config.dataDir, 'claude');
    mkdirSync(configDir, { recursive: true });
    mkdirSync(this.app.config.workspaceDir, { recursive: true });
    const mcp = req.mcpServers[0];
    const model = req.model || this.app.providers.modelFor(this.id);
    const mcpJson = JSON.stringify({
      mcpServers: mcp
        ? {
            [mcp.name]: {
              type: 'http',
              url: mcp.url,
              headers: {
                authorization: `Bearer ${mcp.bearerToken}`,
                ...(req.askId ? { 'x-lotti-ask': req.askId } : {}),
              },
            },
          }
        : {},
    });
    const args = [
      '-p',
      '--output-format',
      'text',
      '--no-session-persistence',
      '--permission-mode',
      'dontAsk',
      '--system-prompt',
      req.system,
      ...(model ? ['--model', model] : []),
      '--strict-mcp-config',
      '--tools',
      '',
      ...(mcp ? ['--allowedTools', `mcp__${mcp.name}`] : []),
      '--mcp-config',
      mcpJson,
    ];
    req.onStatus?.('Claude …');
    const r = await runProc(this.bin, args, {
      env: baseEnv({
        CLAUDE_CODE_OAUTH_TOKEN: token,
        CLAUDE_CONFIG_DIR: configDir,
      }),
      cwd: this.app.config.workspaceDir,
      input: req.prompt,
      ...(req.signal ? { signal: req.signal } : {}),
    });
    const text = stripAnsi(r.stdout).trim();
    if (r.code !== 0)
      throw new Error(
        `Claude Code failed (${r.code}): ${stripAnsi(r.stderr || r.stdout)
          .trim()
          .slice(-400)}`,
      );
    return { text };
  }
}
