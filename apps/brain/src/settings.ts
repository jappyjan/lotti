import type { App } from './app.ts';

export interface SettingDef {
  default: unknown;
  description: string;
  /** Safety settings change what the agent may do: setting them is a `tap` op for the agent. */
  safety?: boolean;
  /** Number settings: allowed range (inclusive), `int` for whole numbers only. */
  min?: number;
  max?: number;
  int?: boolean;
  /** String settings: `pattern` the whole value must match, `format` says so in an error. */
  pattern?: RegExp;
  format?: string;
}

const HHMM = /^([01]?\d|2[0-3]):[0-5]\d$/;

export const SETTING_DEFS: Record<string, SettingDef> = {
  'user.name': {
    default: 'Jan',
    description: 'How Lotti addresses you',
    pattern: /^\S.{0,39}$/,
    format: '1 to 40 characters, not starting with a space',
  },
  'provider.active': {
    default: 'deepseek',
    description: 'Active model provider id',
  },
  'provider.fallback': {
    default: '',
    description: 'Fallback provider id (used on error/timeout), empty = none',
  },
  'provider.deepseek.model': {
    default: 'deepseek-flash',
    description:
      'DeepSeek model id (deepseek-flash = the latest V4.1 Flash, deepseek-v4-pro)',
  },
  'provider.deepseek.thinking': {
    default: 'off',
    description:
      'DeepSeek thinking: off (fastest answers), or its effort low, high or max',
    pattern: /^(off|low|high|max)$/,
    format: 'off, low, high or max',
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
    min: 1,
    max: 30,
    int: true,
  },
  'agent.silence_timeout_sec': {
    default: 60,
    description: 'Give up when the model is silent this long',
    min: 1,
    max: 600,
    int: true,
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
    min: 1,
    max: 1440,
    int: true,
  },
  'conversation.new_idle_min': {
    default: 60,
    description: 'Start a new conversation after this idle time',
    min: 1,
    max: 10080,
    int: true,
  },
  'conversation.keep_recent_turns': {
    default: 6,
    description: 'Turns kept verbatim when compacting',
    min: 0,
    max: 50,
    int: true,
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
    min: 1,
    max: 600,
    int: true,
  },
  'shell.max_output_chars': {
    default: 20000,
    description: 'Shell output cap',
    safety: true,
    min: 100,
    max: 200000,
    int: true,
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
    min: 0.1,
    max: 72,
  },
  'catchup.night_start': {
    default: '22:00',
    description: 'Night window start (HH:MM)',
    pattern: HHMM,
    format: 'HH:MM, 00:00 to 23:59',
  },
  'catchup.night_end': {
    default: '09:00',
    description: 'Night window end (HH:MM)',
    pattern: HHMM,
    format: 'HH:MM, 00:00 to 23:59',
  },
  'catchup.sleep_min_hours': {
    default: 4,
    description: 'Night overlap that counts as slept',
    min: 0,
    max: 24,
  },
  'catchup.use_weather': {
    default: true,
    description: 'Include weather at the current location',
  },
  'inbox.default_expiry_hours': {
    default: 72,
    description: 'Inbox items expire after this (0 = never)',
    min: 0,
    max: 8760,
  },
  'memory.stale_days': {
    default: 180,
    description: 'Dreaming drops memories unused this long',
    min: 1,
    max: 3650,
    int: true,
  },
  'dreaming.enabled': { default: true, description: 'Nightly dreaming' },
  'jobs.meeting_soon.lead_min': {
    default: 10,
    description: 'Meeting soon: minutes before an event it shows up',
    min: 1,
    max: 1440,
    int: true,
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

  /** Throws unless `value` is allowed for `key`; `set` checks too, this lets a batch check first. */
  check(key: string, value: unknown): void {
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
    if (typeof value === 'number') {
      if (
        !Number.isFinite(value) ||
        (def.int && !Number.isInteger(value)) ||
        (def.min !== undefined && value < def.min) ||
        (def.max !== undefined && value > def.max)
      )
        throw new Error(
          `Setting ${key} must be a ${def.int ? 'whole number' : 'number'} from ${def.min ?? '-∞'} to ${def.max ?? '∞'}`,
        );
    }
    if (typeof value === 'string' && def.pattern && !def.pattern.test(value))
      throw new Error(
        `Setting ${key} has the wrong format${def.format ? `: ${def.format}` : ''}`,
      );
  }

  set(key: string, value: unknown): void {
    this.check(key, value);
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
  /** The language of the phone's last ask; actions confirmed from the inbox have no ask of their own. */
  noteLocale(locale: 'de' | 'en'): void {
    if (this.kvGet('phone.locale') !== locale)
      this.kvSet('phone.locale', locale);
  }
  lastLocale(): 'de' | 'en' {
    return this.kvGet('phone.locale') === 'de' ? 'de' : 'en';
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
