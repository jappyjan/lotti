import type { App } from './app.ts';

export interface SettingDef {
  default: unknown;
  description: string;
  /** Safety settings change what the agent may do: setting them is a `tap` op for the agent. */
  safety?: boolean;
}

export const SETTING_DEFS: Record<string, SettingDef> = {
  'user.name': { default: 'Jan', description: 'How Lotti addresses you' },
  'provider.active': {
    default: 'deepseek',
    description: 'Active model provider id',
  },
  'provider.fallback': {
    default: '',
    description: 'Fallback provider id (used on error/timeout), empty = none',
  },
  'provider.deepseek.model': {
    default: 'deepseek-chat',
    description: 'DeepSeek model id',
  },
  'provider.deepseek.base_url': {
    default: '',
    description:
      'DeepSeek API base URL (empty = https://api.deepseek.com). Any OpenAI-compatible endpoint works.',
    safety: true,
  },
  'provider.openai.model': {
    default: 'gpt-4.1-mini',
    description: 'OpenAI model id',
  },
  'provider.anthropic.model': {
    default: 'claude-sonnet-5-5',
    description: 'Anthropic model id',
  },
  'provider.codex.model': {
    default: '',
    description: 'Codex runtime model (empty = CLI default)',
  },
  'provider.claude_code.model': {
    default: '',
    description: 'Claude Code runtime model (empty = CLI default)',
  },
  'bring.default_list': {
    default: '',
    description:
      'Bring! list id used when none is given (empty = your first list)',
  },
  'push.apns.production': {
    default: true,
    description:
      'Use the production APNs server (false = sandbox, for dev builds)',
  },
  'agent.max_rounds': {
    default: 8,
    description: 'Max tool rounds per question',
    safety: true,
  },
  'agent.silence_timeout_sec': {
    default: 60,
    description: 'Give up when the model is silent this long',
  },
  'agent.op_tool_groups': {
    default: [
      'memory',
      'inbox',
      'jobs',
      'skills',
      'scripts',
      'settings',
      'status',
      'catchup',
      'bring',
      'providers',
      'mcp',
      'dreaming',
    ],
    description: 'Op groups the agent may use as tools (app_only ops never)',
    safety: true,
  },
  'conversation.compact_idle_min': {
    default: 10,
    description: 'Compact the conversation after this idle time',
  },
  'conversation.new_idle_min': {
    default: 60,
    description: 'Start a new conversation after this idle time',
  },
  'conversation.keep_recent_turns': {
    default: 6,
    description: 'Turns kept verbatim when compacting',
  },
  'shell.enabled': {
    default: true,
    description: 'Agent may run shell commands',
    safety: true,
  },
  'shell.timeout_sec': {
    default: 30,
    description: 'Shell command timeout',
    safety: true,
  },
  'shell.max_output_chars': {
    default: 20000,
    description: 'Shell output cap',
    safety: true,
  },
  'web_fetch.enabled': {
    default: true,
    description: 'Agent may fetch web pages',
    safety: true,
  },
  'location.enabled': {
    default: true,
    description: 'Agent may read the phone location',
    safety: true,
  },
  'catchup.enabled': {
    default: true,
    description: 'Generate a brief when you return',
  },
  'catchup.away_hours': {
    default: 2,
    description: 'Away this long without presence = return',
  },
  'catchup.night_start': {
    default: '22:00',
    description: 'Night window start (HH:MM)',
  },
  'catchup.night_end': {
    default: '09:00',
    description: 'Night window end (HH:MM)',
  },
  'catchup.sleep_min_hours': {
    default: 4,
    description: 'Night overlap that counts as slept',
  },
  'catchup.use_weather': {
    default: true,
    description: 'Include weather at the current location',
  },
  'inbox.default_expiry_hours': {
    default: 72,
    description: 'Inbox items expire after this (0 = never)',
  },
  'memory.stale_days': {
    default: 180,
    description: 'Dreaming drops memories unused this long',
  },
  'dreaming.enabled': { default: true, description: 'Nightly dreaming' },
  'jobs.meeting_soon.lead_min': {
    default: 10,
    description: 'Meeting soon: minutes before an event it shows up',
  },
};

/** Keys owned by the providers.* ops: settings.set / settings.reset refuse them. */
export const isProviderManaged = (key: string) => key.startsWith('provider.');

export class SettingsService {
  constructor(private app: App) {}

  get<T = unknown>(key: string): T {
    const r = this.app.db.get<{ value: string }>(
      'SELECT value FROM kv WHERE key=?',
      'setting:' + key,
    );
    if (r) return JSON.parse(r.value) as T;
    return SETTING_DEFS[key]?.default as T;
  }
  num(key: string): number {
    return Number(this.get(key));
  }
  bool(key: string): boolean {
    return Boolean(this.get(key));
  }
  str(key: string): string {
    return String(this.get(key) ?? '');
  }

  set(key: string, value: unknown): void {
    const def = SETTING_DEFS[key];
    if (!def) throw new Error(`Unknown setting: ${key}`);
    if (
      typeof def.default !== typeof value ||
      Array.isArray(def.default) !== Array.isArray(value)
    ) {
      throw new Error(
        `Setting ${key} expects ${Array.isArray(def.default) ? 'array' : typeof def.default}`,
      );
    }
    this.app.db.run(
      `INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`,
      'setting:' + key,
      JSON.stringify(value),
    );
  }
  reset(key: string): void {
    this.app.db.run('DELETE FROM kv WHERE key=?', 'setting:' + key);
  }
  isSafety(key: string): boolean {
    return !!SETTING_DEFS[key]?.safety;
  }
  all(): {
    key: string;
    value: unknown;
    default: unknown;
    description: string;
    safety: boolean;
    managedBy?: 'providers';
  }[] {
    return Object.entries(SETTING_DEFS).map(([key, d]) => ({
      key,
      value: this.get(key),
      default: d.default,
      description: d.description,
      safety: !!d.safety,
      ...(isProviderManaged(key) ? { managedBy: 'providers' as const } : {}),
    }));
  }

  /** The phone's UTC offset (minutes) from its last ask; remembered for background work. */
  notePhoneOffset(offsetMin: number): void {
    if (this.kvGet('phone.utc_offset_min') !== String(offsetMin))
      this.kvSet('phone.utc_offset_min', String(offsetMin));
  }
  /**
   * Offset to render times in for background work (jobs, catch-up, meeting items): the phone's last one,
   * unless the server has its own TZ configured. null = server local time.
   */
  displayOffsetMin(): number | null {
    if (process.env.TZ) return null;
    const v = this.kvGet('phone.utc_offset_min');
    return v === undefined || Number.isNaN(Number(v)) ? null : Number(v);
  }

  /** Raw internal kv (not user settings): last-run markers etc. */
  kvGet(key: string): string | undefined {
    return this.app.db.get<{ value: string }>(
      'SELECT value FROM kv WHERE key=?',
      key,
    )?.value;
  }
  kvSet(key: string, value: string): void {
    this.app.db.run(
      `INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`,
      key,
      value,
    );
  }
}
