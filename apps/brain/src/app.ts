import { ActionService } from './actions.ts';
import { ask } from './agent/loop.ts';
import type { AskInput } from './agent/loop.ts';
import { Auth } from './auth.ts';
import { CatchupService } from './catchup.ts';
import type { Config } from './config.ts';
import { ConversationService } from './conversations.ts';
import { Db, migrate } from './db.ts';
import { DreamingService } from './dreaming.ts';
import { InboxService } from './inbox.ts';
import {
  defaultIntegrations,
  type Integrations,
} from './integrations/index.ts';
import { MemoryService } from './memory.ts';
import { registerAllOps } from './ops/index.ts';
import { OpRegistry } from './ops/registry.ts';
import { ProviderRegistry } from './providers/registry.ts';
import { Scheduler } from './scheduler/scheduler.ts';
import { SecretsStore } from './secrets.ts';
import { Hub } from './server/hub.ts';
import { SettingsService } from './settings.ts';
import { SkillStore } from './skills.ts';
import { registerNativeTools } from './tools/index.ts';
import { ToolRegistry, type RunState } from './tools/registry.ts';
import { systemClock, type Clock } from './util/clock.ts';
import { deriveKey } from './util/crypto.ts';
import { consoleLogger, type Logger } from './util/log.ts';

/** Everything wired together. Services keep a reference to `app` and use it lazily. */
export interface App {
  config: Config;
  clock: Clock;
  log: Logger;
  fetch: typeof fetch;
  key: Buffer;
  startedAt: number;
  db: Db;
  secrets: SecretsStore;
  settings: SettingsService;
  auth: Auth;
  inbox: InboxService;
  actions: ActionService;
  conversations: ConversationService;
  memory: MemoryService;
  skills: SkillStore;
  dreaming: DreamingService;
  scheduler: Scheduler;
  catchup: CatchupService;
  providers: ProviderRegistry;
  tools: ToolRegistry;
  ops: OpRegistry;
  hub: Hub;
  integrations: Integrations;
  /** Active runs by ask id (lets /mcp/tools attach proposals to the right run). */
  runs: Map<string, RunState>;
  ask(input: AskInput): ReturnType<typeof ask>;
}

export interface CreateAppOptions {
  config: Config;
  clock?: Clock;
  fetch?: typeof fetch;
  logger?: Logger;
  integrations?: Partial<Integrations>;
}

export function createApp(o: CreateAppOptions): App {
  const app = {} as App;
  app.config = o.config;
  app.clock = o.clock ?? systemClock;
  app.log = o.logger ?? consoleLogger;
  app.fetch = o.fetch ?? ((...a) => fetch(...a));
  app.key = deriveKey(o.config.masterKey);
  app.startedAt = app.clock.now();
  app.db = new Db(o.config.dbPath);
  migrate(app.db);
  app.integrations = { ...defaultIntegrations(), ...o.integrations };
  app.runs = new Map();
  app.secrets = new SecretsStore(app);
  app.settings = new SettingsService(app);
  app.auth = new Auth(app);
  app.hub = new Hub(app);
  app.inbox = new InboxService(app);
  app.actions = new ActionService(app);
  app.memory = new MemoryService(app);
  app.conversations = new ConversationService(app);
  app.skills = new SkillStore(app);
  app.dreaming = new DreamingService(app);
  app.scheduler = new Scheduler(app);
  app.catchup = new CatchupService(app);
  app.providers = new ProviderRegistry(app);
  app.ops = new OpRegistry(app);
  app.tools = new ToolRegistry(app);
  app.ask = (input) => ask(app, input);
  registerAllOps(app);
  registerNativeTools(app);
  app.skills.ensureDirs();
  app.scheduler.seedBuiltins();
  return app;
}
