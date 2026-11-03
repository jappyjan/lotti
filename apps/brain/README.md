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

| var                                                                        | meaning                                                                                              |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `MASTER_KEY`                                                               | required, >= 16 chars. AES-256-GCM key for secrets at rest (HKDF-derived).                           |
| `PUBLIC_URL`                                                               | URL shown in the pairing QR/log (default `http://localhost:$PORT`).                                  |
| `PORT`                                                                     | default `8787`.                                                                                      |
| `DATA_DIR`                                                                 | default `/data`. SQLite at `DATA_DIR/lotti.db`; workspace at `DATA_DIR/workspace/{scripts,skills}`.  |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY`, `APNS_TOPIC`, `APNS_PRODUCTION` | optional alternative to the `push.configure` op (the op wins). Push is OFF until one of them is set. |
| `TZ`                                                                       | cron schedules and the catch-up night window use the process time zone.                              |

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
  integrations/        interfaces (index.ts) + implementations, wired in register.ts: bring/ google/ calendar/ mail/ mcp/ runtimes/ push/ search/
  testing/             MockProvider, FakeClock helpers, in-process WebSocket client
```

### Operations (`src/ops`)

`{name, group, description, inputSchema (zod), risk: free|tap|app_only, handler}`; one registry, three front doors:

- HTTP: `GET /api/v1/ops`, `POST /api/v1/ops/<name>` -> `{ok:true,result,undo?}` / `{ok:false,error}` (device token; everything).
- Admin MCP: `POST /mcp/admin` (streamable HTTP, JSON-RPC). **Off** until an admin token exists (`admin_token.create` in the app; the token is shown once, stored hashed). No `app_only` ops. Tool names are op names with `_` (`jobs_create`).
- Agent: ops of the groups in setting `agent.op_tool_groups` (default memory, inbox, jobs, skills, scripts, settings, status, catchup, bring, providers, mcp; `tap` ops such as `providers.set_active`, `providers.set_model` and `mcp.*` only PROPOSE an action when the agent calls them) are tools for the internal agent loop.

Risk rules: `app_only` never reaches MCP/agent. `tap` called by MCP/agent returns a **proposed server action** (`op:<name>`) that runs only after the app sends `perform`; from the app it runs directly. `free` ops return an `undo` handle where possible (job/memory/skill/script/inbox/setting/Bring), undone with `undo {undoId}`.

| group               | ops                                                                                                                                                                                                                                                                                           |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status`            | `status.get`, `pairing.new_code`/`devices`/`revoke_device` (app_only)                                                                                                                                                                                                                         |
| `providers`         | `list`, `status`, `set_active` (active + fallback), `set_model`, `models`, `set_credential`/`clear_credential` (app_only; for `claude_code` the credential is the `claude setup-token` token), `codex_login_start`/`codex_logout` (app_only), `codex_login_status`                            |
| `settings`          | `list`, `get`, `set`, `set_safety` (tap: shell.\*, web_fetch, location, step limit, agent op groups), `reset`                                                                                                                                                                                 |
| `accounts`          | `list`/`check`, `add`/`update`/`delete` (tap), `set_credential` (app_only), `set_google_client`/`google_auth_url`/`google_exchange` (app_only), `calendars`/`mailboxes` (live lists), `set_calendars`/`set_mailboxes` (tap); `secrets.set`/`delete`/`list` (app_only, write-only, names only) |
| `bring`             | `status`, `lists`, `items`, `recent`, `add`, `remove` (immediate + undo), `set_default_list`, `login` (app_only)                                                                                                                                                                              |
| `mcp`               | `list`, `add`/`update`/`delete`/`test`/`tools`/`set_tool_confirmation` (all tap), `set_credential` (app_only: `bearer` or `env.NAME`)                                                                                                                                                         |
| `jobs`              | `list`, `create`, `update`, `delete`, `run_now`, `history` (cron or friendly: "daily at 08:00", "weekdays at 07:30", "every 30 minutes", German too)                                                                                                                                          |
| `memory`            | `list`, `search`, `get`, `update`, `delete`, `remember`, `forget` (id or words), `restore`                                                                                                                                                                                                    |
| `skills`, `scripts` | `list` (with last use), `get`, `put`, `delete`                                                                                                                                                                                                                                                |
| `conversations`     | `list`, `get`, `search`                                                                                                                                                                                                                                                                       |
| `inbox`             | `list`, `read`, `dismiss` (`all`), `dismiss_all`, `restore`, `create`                                                                                                                                                                                                                         |
| `catchup`           | `get_settings`, `set_settings`, `recent`, `run_now`                                                                                                                                                                                                                                           |
| `privacy`           | `location_log`, `shell_log`                                                                                                                                                                                                                                                                   |
| `dreaming`          | `run_now`, `reports`                                                                                                                                                                                                                                                                          |
| `push`              | `status`, `configure`/`clear`/`test` (app_only)                                                                                                                                                                                                                                               |
| `admin_token`       | `create`, `revoke`, `status` (all app_only)                                                                                                                                                                                                                                                   |

### Tools (`src/tools`)

`{name, description, inputSchema, kind: server|phone, needsConfirmation?, status?, handler}`. Native: `weather` (Open-Meteo; place or lat/lon, date, hourly range or up to 16 daily; **no default location**: it tells the model to call `location`), `location` and `reminders` (phone proxies, 10 s; `location_access start/end` + log around every location read), `shell` (workspace cwd, timeout, output cap, minimal env without secrets, PATH = `workspace/scripts` + system, every command in `shell_log`; non-root in Docker), `web_fetch`, `conversation_search`/`conversation_read`, `skill_load`, and the proposal tools `set_timer`, `create_reminder`, `start_navigation` (phone) and `send_mail_reply`, `create_calendar_event` (server). Plus every non-`app_only` op of the enabled groups as `<group>_<verb>`. The same registry is served at `POST /mcp/tools` (internal token; header `X-Lotti-Ask: <askId>` attaches proposals to a running ask) for subscription runtimes.

### Agent loop (`src/agent`)

System prompt (persona, date/time 24 h, channel rule: glasses = one very short sentence, top memories via FTS, skill index, conversation summary) -> tool loop (max 8 rounds, silence-based timeout per model call, cancel aborts everything, status lines streamed). Final answer: `answer` tool `{text, followUps}` > a JSON object in the text > plain text. `actions` (<= 2) are the proposals made during the run. The active provider may fall back on error/timeout; cancel never falls back.

Conversations: one shared conversation; 10 min idle -> LLM summary replaces old turns (recent kept) and memories are extracted; 1 h idle -> closed with title + summary, a new one starts. FTS5 over titles, summaries, turns. Memory: SQLite + FTS5, `supersedes`; dreaming (nightly 03:00, `dreaming.run_now`) dedupes, resolves contradictions (newest wins), drops stale, reports unused skills/scripts, summarises, writes a report.

Scheduler: SQLite jobs, `Scheduler.tick()` every 30 s. Built-ins `meeting_soon` (every minute, 10 min lookahead), `important_mail` (every 10 min, LLM triage), `dreaming` (03:00): editable/disable-able, not deletable. User jobs run the agent with a prompt: "NOTHING" or an inbox item. Catch-up: presence events -> away >= 2 h, or slept (>= 4 h of the 22:00-09:00 window without phone use while the phone was charging/still; works without wear events), once per return, all settings editable under `catchup.*`.

## Integrations (`src/integrations`)

Everything is configured from the app through ops; credentials are `app_only` and write-only (stored encrypted, never returned). `register.ts` wires the implementations; slots stay replaceable (`app.integrations.*`). Failures are reported on the account (`status`, `lastError`, `lastSyncAt`), never crash a job.

### Accounts

`accounts.add {kind, label, config}` then `accounts.set_credential {id, key, value}` then `accounts.check {id}` (-> `{ok, status, error?}`; stores status + last sync). `accounts.list` rows: `{id, kind, label, config, status, lastError, lastSyncAt}`. `accounts.update` replaces the whole `config`. Services per account: `config.calendar` / `config.mail` (booleans; defaults below), `config.enabled=false` switches an account off.

| kind     | services (default) | config                                                                                           | credentials (`accounts.set_credential`)   |
| -------- | ------------------ | ------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| `google` | calendar + mail    | `email`, `calendars: [ids]`, `writeDefault`                                                      | created by the OAuth flow below           |
| `icloud` | calendar + mail    | `username` (Apple ID), `email?`, `calendars`, `mailboxes`                                        | `password` (app-specific password)        |
| `caldav` | calendar           | `url`, `username`, `calendars`                                                                   | `password`                                |
| `imap`   | mail               | `username`, `email?`, `imapHost`, `imapPort?` (993), `smtpHost?`, `smtpPort?` (465), `mailboxes` | `password`                                |
| `bring`  | -                  | -                                                                                                | `email`, `password` (or op `bring.login`) |

Choosing what to use: `accounts.calendars {id}` -> `[{id, name, selected}]`, `accounts.set_calendars {id, calendars: [id]}` (empty = default: Google primary, CalDAV all); `accounts.mailboxes {id}` / `accounts.set_mailboxes {id, mailboxes}` for IMAP (default INBOX; Gmail searches everything).

- **Calendar** (`MergedCalendar`): all calendar accounts merged and de-duplicated; tool `calendar_events {from?, to?, days?, nextOnly?}`; built-ins `meeting_soon` and catch-up use it; the proposed action `create_calendar_event` does a Google `events.insert` / CalDAV `PUT` after `perform`. CalDAV is hand-rolled over `fetch` (PROPFIND discovery, `calendar-query` with server-side `expand`, so recurrences come expanded; servers without `expand` only show the master event).
- **Mail** (`MergedMail`): Gmail REST, IMAP (`imapflow`), SMTP (`nodemailer`). Tools `mail_search {query?, limit?}` (empty = most recent; Gmail syntax works for Gmail) and `mail_read {id}`; ids are `<accountId>:<native>`. Built-in `important_mail` triages `unread(since)`; `send_mail_reply` (replies in the same thread, Gmail `messages.send` / SMTP) runs after `perform`. iCloud: `imap.mail.me.com:993`, `smtp.mail.me.com:587` (STARTTLS).

### Google sign-in (OAuth, PKCE, custom scheme)

1. In Google Cloud create an OAuth client (type iOS, or Web) and enable the Calendar and Gmail APIs. In the app: `accounts.set_google_client {clientId, clientSecret?, redirectUri?}` (default redirect `lotti://oauth`; an iOS client needs no secret).
2. `accounts.google_auth_url {accountId?, label?}` -> `{url, state, redirectUri}`. The app opens `url` in `ASWebAuthenticationSession` with callback scheme `lotti`.
3. Google redirects to `lotti://oauth?code=...&state=...`; the app calls `accounts.google_exchange {code, state}` -> `{accountId, email}`. The backend exchanges the code (with its PKCE verifier, kept per `state` for 15 min, single use), stores access/refresh token encrypted (`account.<id>.*`), refreshes the access token on demand, and creates the `google` account (or re-connects `accountId`). A revoked token shows as `status: error` with "connect the account again".

Scopes: `calendar.readonly`, `calendar.events`, `gmail.readonly`, `gmail.send`, `openid email`.

### Bring!

Unofficial API, isolated in `bring/api.ts` (it can break; errors say "Bring! login failed", "HTTP 5xx", ...). `bring.login {email, password}` stores the login as a `bring` account (secrets `email`, `password`) and checks it; `bring.status` -> `{connected, account?, defaultList?, error?}`; `bring.lists`, `bring.items {listId?}` -> `[{name, spec?}]`, `bring.recent`, `bring.set_default_list {listId}`. `bring.add {item, spec?, listId?, locale?}` / `bring.remove {item, listId?, locale?}` run at once (remove = check off, like ticking in the app) and return a Done line ("Milch (2 l) hinzugefügt", default German, `locale: "en"` for English) plus an `undo` handle (the inverse op). The agent gets them as tools `bring_lists`, `bring_items`, `bring_add`, `bring_remove`, `bring_recent` (group `bring` is in the default `agent.op_tool_groups`).

### MCP client

Servers are added with `mcp.add` (http URL or stdio command + args). `mcp.set_credential {id, key: "bearer" | "env.NAME", value}` (app only) adds an `Authorization: Bearer` token or an environment variable for stdio servers (stdio servers do **not** inherit the backend environment). `mcp.test {id}` -> `{ok, tools[]|error}`; `mcp.tools {id}` -> `[{name, description, needsConfirmation}]`; `mcp.set_tool_confirmation` flips the per-tool flag (default: needs confirmation). Transports: stdio (newline-delimited JSON-RPC) and streamable HTTP (JSON or SSE replies, session id). One connection per operation. Enabled servers' tools are registered as `mcp__<server>__<tool>` (at start and after every mcp.* change; names are reduced to `[A-Za-z0-9_-]`); tools needing confirmation only PROPOSE an action (`tool: "mcp__server__tool"`, runs after `perform`), the others run at once. They also appear in `/mcp/tools` with the server's own JSON Schema.

### Subscription runtimes

- **Codex** (`providers.*`, id `codex`): state in `DATA_DIR/codex` (`CODEX_HOME`, file credential store). `providers.codex_login_start` spawns `codex login --device-auth` and returns `{state: "pending", url, code}`; the app shows both (user opens the URL on any device, enters the code). Poll `providers.codex_login_status` -> `{state: idle|pending|done|error, loggedIn, url?, code?, error?}`; `providers.codex_logout`. Runs `codex exec` (read-only sandbox, no approvals) with Lotti attached as MCP server `lotti` (`/mcp/tools`, token via `LOTTI_TOOLS_TOKEN`, header `X-Lotti-Ask`); the final message is read with `-o`. Needs the `codex` binary on PATH (the Docker image installs it).
- **Claude Code** (id `claude_code`): run `claude setup-token` anywhere, paste the token in the app with `providers.set_credential {provider: "claude_code", apiKey: <token>}`. Runs `claude -p` with `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CONFIG_DIR=DATA_DIR/claude`, built-in tools off (`--tools ""`) and Lotti's tools as MCP config.
- Select either with `providers.set_active` like any provider; `providers.status` shows `configured` and the last error. A fallback provider is used when a runtime fails.

### Push (APNs)

OFF until configured: `push.configure {key: <.p8 text>, keyId, teamId, topic: <bundle id>, production?}` (or the `APNS_*` env vars). Token-based auth (ES256 JWT, refreshed every 40 min) over HTTP/2 to `api.push.apple.com` (`production: false` = sandbox). Every inbox item created while no socket is open is sent with `content-available: 1` (wakes the app to sync) plus an alert; a dead token (410 / BadDeviceToken) is cleared from the device. `push.status` -> `{apnsConfigured, devices[{id,name,hasApnsToken,connected}], queued}`, `push.test {deviceId?}`, `push.clear`.

### Web search

Tool `web_search {query, count?, freshness?}` uses the Brave Search API when the secret `search.brave.api_key` exists (`secrets.set` in the app); otherwise it tells the model to use curl via the shell tool or `web_fetch`.

### Extension points

`McpClient`, `BringClient`, `CalendarSource`, `MailSource`, `PushNotifier`, `AccountConnector` and `AgentRuntimeProvider` are interfaces in `integrations/index.ts` / `providers/types.ts`; new tools, ops and server actions: `app.tools.register`, `app.ops.register(defineOp(...))`, `app.actions.register(tool, handler)`.

## Tests

`pnpm nx test brain` compiles with `tsc` and runs `node --test` (mock provider, fake clock, in-process WebSocket client, mock `fetch`; no network). `DEEPSEEK_API_KEY=... pnpm nx test brain` also runs the live DeepSeek test.
