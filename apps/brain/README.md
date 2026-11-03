# Lotti Brain (`apps/brain`)

Lotti's own always-on AI backend: Node 24 + TypeScript (ESM), SQLite (`node:sqlite`, FTS5), `ws`, `zod`. The phone app talks to it over the protocol in [`docs/protocol.md`](../../docs/protocol.md).

## Run

```sh
# Docker (build context = repo root)
export MASTER_KEY=$(openssl rand -hex 32)      # keep it: it decrypts the stored secrets
docker compose -f apps/brain/docker-compose.yml up -d --build
docker compose -f apps/brain/docker-compose.yml logs brain   # pairing code + URL + QR on first start

# Local
pnpm nx build brain && MASTER_KEY=... DATA_DIR=./data PORT=8787 node apps/brain/dist/main.js
pnpm nx run-many -t build test typecheck -p brain
```

Environment (nothing else is read; API keys, accounts and tokens are entered in the app and stored encrypted):

| var                                                                        | meaning                                                                                             |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `MASTER_KEY`                                                               | required, >= 16 chars. AES-256-GCM key for secrets at rest (HKDF-derived).                          |
| `PUBLIC_URL`                                                               | URL shown in the pairing QR/log (default `http://localhost:$PORT`).                                 |
| `PORT`                                                                     | default `8787`.                                                                                     |
| `DATA_DIR`                                                                 | default `/data`. SQLite at `DATA_DIR/lotti.db`; workspace at `DATA_DIR/workspace/{scripts,skills}`. |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY`, `APNS_TOPIC`, `APNS_PRODUCTION` | optional; read into `config.apns` for the APNs integration.                                         |
| `TZ`                                                                       | cron schedules and the catch-up night window use the process time zone.                             |

Migrations are in code (`src/db.ts`) and run at start.

## Pairing

On first start (no paired device) the server prints a one-time code, the URL and an ASCII QR (`lotti://pair?url=<PUBLIC_URL>&code=<CODE>`). The app calls `POST /api/v1/pair {code, deviceName}` and keeps the returned token (stored hashed here). More devices: op `pairing.new_code` (app only). `GET /api/v1/pair/code` works from the server itself only (loopback), e.g. `docker exec`.

## Architecture

```
src/
  app.ts               composition root (createApp)          main.ts  start-up, banner
  config.ts db.ts      env + SQLite/migrations               secrets.ts settings.ts auth.ts
  ops/                 ONE registry of operations (registry.ts) + groups (core.ts data.ts integration-ops.ts)
  tools/               ONE registry of agent tools (registry.ts) + weather shell web phone proposals misc
  providers/           chat providers (deepseek/openai/anthropic) + agent-runtime stubs + fallback registry
  agent/               system prompt + tool loop (rounds, silence timeout, cancel, structured final answer)
  conversations.ts memory.ts dreaming.ts skills.ts inbox.ts catchup.ts actions.ts
  scheduler/           cron parser, friendly schedules, jobs, built-in jobs
  server/              http.ts (REST + MCP endpoints), ws.ts (protocol), hub.ts (sockets, phone tools), mcp.ts
  integrations/        EXTENSION POINTS (interfaces + stubs)
  testing/             MockProvider, FakeClock helpers, in-process WebSocket client
```

### Operations (`src/ops`)

`{name, group, description, inputSchema (zod), risk: free|tap|app_only, handler}`; one registry, three front doors:

- HTTP: `GET /api/v1/ops`, `POST /api/v1/ops/<name>` -> `{ok:true,result,undo?}` / `{ok:false,error}` (device token; everything).
- Admin MCP: `POST /mcp/admin` (streamable HTTP, JSON-RPC). **Off** until an admin token exists (`admin_token.create` in the app; the token is shown once, stored hashed). No `app_only` ops. Tool names are op names with `_` (`jobs_create`).
- Agent: ops of the groups in setting `agent.op_tool_groups` (default memory, inbox, jobs, skills, scripts, settings, status, catchup) are tools for the internal agent loop.

Risk rules: `app_only` never reaches MCP/agent. `tap` called by MCP/agent returns a **proposed server action** (`op:<name>`) that runs only after the app sends `perform`; from the app it runs directly. `free` ops return an `undo` handle where possible (job/memory/skill/script/inbox/setting/Bring), undone with `undo {undoId}`.

| group               | ops                                                                                                                                                   |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status`            | `status.get`, `pairing.new_code`/`devices`/`revoke_device` (app_only)                                                                                 |
| `providers`         | `list`, `status`, `set_active` (active + fallback), `set_model`, `models`, `set_credential`/`clear_credential` (app_only)                             |
| `settings`          | `list`, `get`, `set`, `set_safety` (tap: shell.\*, web_fetch, location, step limit, agent op groups), `reset`                                         |
| `accounts`          | `accounts.list`/`check`, `add`/`update`/`delete` (tap), `set_credential` (app_only); `secrets.set`/`delete`/`list` (app_only, write-only, names only) |
| `bring`             | `status`, `lists`, `items`, `add`, `remove` (stub until a `BringClient` is registered)                                                                |
| `mcp`               | `list`, `add`/`update`/`delete`/`test`/`set_tool_confirmation` (all tap; config in DB, client is a stub)                                              |
| `jobs`              | `list`, `create`, `update`, `delete`, `run_now`, `history` (cron or friendly: "daily at 08:00", "weekdays at 07:30", "every 30 minutes", German too)  |
| `memory`            | `list`, `search`, `get`, `update`, `delete`, `remember`, `forget` (id or words), `restore`                                                            |
| `skills`, `scripts` | `list` (with last use), `get`, `put`, `delete`                                                                                                        |
| `conversations`     | `list`, `get`, `search`                                                                                                                               |
| `inbox`             | `list`, `read`, `dismiss` (`all`), `dismiss_all`, `restore`, `create`                                                                                 |
| `catchup`           | `get_settings`, `set_settings`, `recent`, `run_now`                                                                                                   |
| `privacy`           | `location_log`, `shell_log`                                                                                                                           |
| `dreaming`          | `run_now`, `reports`                                                                                                                                  |
| `push`              | `status`                                                                                                                                              |
| `admin_token`       | `create`, `revoke`, `status` (all app_only)                                                                                                           |

### Tools (`src/tools`)

`{name, description, inputSchema, kind: server|phone, needsConfirmation?, status?, handler}`. Native: `weather` (Open-Meteo; place or lat/lon, date, hourly range or up to 16 daily; **no default location**: it tells the model to call `location`), `location` and `reminders` (phone proxies, 10 s; `location_access start/end` + log around every location read), `shell` (workspace cwd, timeout, output cap, minimal env without secrets, PATH = `workspace/scripts` + system, every command in `shell_log`; non-root in Docker), `web_fetch`, `conversation_search`/`conversation_read`, `skill_load`, and the proposal tools `set_timer`, `create_reminder`, `start_navigation` (phone) and `send_mail_reply`, `create_calendar_event` (server). Plus every non-`app_only` op of the enabled groups as `<group>_<verb>`. The same registry is served at `POST /mcp/tools` (internal token; header `X-Lotti-Ask: <askId>` attaches proposals to a running ask) for subscription runtimes.

### Agent loop (`src/agent`)

System prompt (persona, date/time 24 h, channel rule: glasses = one very short sentence, top memories via FTS, skill index, conversation summary) -> tool loop (max 8 rounds, silence-based timeout per model call, cancel aborts everything, status lines streamed). Final answer: `answer` tool `{text, followUps}` > a JSON object in the text > plain text. `actions` (<= 2) are the proposals made during the run. The active provider may fall back on error/timeout; cancel never falls back.

Conversations: one shared conversation; 10 min idle -> LLM summary replaces old turns (recent kept) and memories are extracted; 1 h idle -> closed with title + summary, a new one starts. FTS5 over titles, summaries, turns. Memory: SQLite + FTS5, `supersedes`; dreaming (nightly 03:00, `dreaming.run_now`) dedupes, resolves contradictions (newest wins), drops stale, reports unused skills/scripts, summarises, writes a report.

Scheduler: SQLite jobs, `Scheduler.tick()` every 30 s. Built-ins `meeting_soon` (every minute, 10 min lookahead), `important_mail` (every 10 min, LLM triage), `dreaming` (03:00): editable/disable-able, not deletable. User jobs run the agent with a prompt: "NOTHING" or an inbox item. Catch-up: presence events -> away >= 2 h, or slept (>= 4 h of the 22:00-09:00 window without phone use while the phone was charging/still; works without wear events), once per return, all settings editable under `catchup.*`.

## Extension points for integrations (`src/integrations`)

All optional; the core says "not connected" when empty. Wire them in `src/integrations/register.ts`.

| what                             | interface (file)                                                                                                                                                                                                                | used by                                                                                                                                  |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| calendar                         | `CalendarSource.events(from,to)`, `createEvent?` (`integrations/index.ts`) -> `app.integrations.calendar`                                                                                                                       | `meeting_soon`, catch-up, server action `create_calendar_event`                                                                          |
| mail                             | `MailSource.unread(since)`, `sendReply?` -> `app.integrations.mail`                                                                                                                                                             | `important_mail`, server action `send_mail_reply`                                                                                        |
| APNs                             | `PushNotifier.notifyOffline(device, item)` -> `app.integrations.push` (`config.apns`, `device.apnsToken`)                                                                                                                       | every inbox item created while no socket is open                                                                                         |
| MCP client                       | `McpClient` -> `app.integrations.mcp`; config via `loadMcpServers(app)` / `mcpToolNeedsConfirmation()` (`ops/integration-ops.ts`)                                                                                               | `mcp.*` ops. Register remote tools with `app.tools.register`; confirmation-needed tools must `proposeAction(...)` (`tools/proposals.ts`) |
| accounts                         | `AccountConnector` per kind -> `app.integrations.connectors.set(kind, c)`; credentials in `app.secrets` under `account.<id>.<key>`                                                                                              | `accounts.check`                                                                                                                         |
| Bring!                           | `BringClient` -> `app.integrations.bring`                                                                                                                                                                                       | `bring.*` ops (add `bring` to `agent.op_tool_groups` default in `settings.ts` to expose them as tools)                                   |
| subscription runtimes            | `AgentRuntimeProvider.run(req)` (`providers/types.ts`, stubs in `providers/agent-runtime.ts`) -> `app.providers.register`. `req.mcpServers` has the `/mcp/tools` URL + internal token, `req.askId` for the `X-Lotti-Ask` header | active provider = `codex` / `claude_code`                                                                                                |
| new tools / ops / server actions | `app.tools.register`, `app.ops.register(defineOp(...))`, `app.actions.register(tool, handler)`                                                                                                                                  | agent, MCP, HTTP, `perform`                                                                                                              |
| web search                       | register a `web_search` tool                                                                                                                                                                                                    | agent                                                                                                                                    |

## Tests

`pnpm nx test brain` compiles with `tsc` and runs `node --test` (mock provider, fake clock, in-process WebSocket client, mock `fetch`; no network). `DEEPSEEK_API_KEY=... pnpm nx test brain` also runs the live DeepSeek test.
