# Lotti Brain protocol

The contract between the Lotti app (`BackendClient` in LottiKit) and the backend (`apps/brain`).
Both sides are built against this file. Change it first, then the code.

## Transport and auth

- `GET /health` → `{"ok":true}` (no auth).
- `POST /api/v1/pair` `{code, deviceName}` → `{token}` (no auth; the code is printed at first start, single use, and re-printable via `GET /api/v1/pair/code` only from the server logs). The app keeps the token in the Keychain.
- Everything else needs `Authorization: Bearer <device token>` (WebSocket: header, or `?token=` query).
- Live socket: `GET /ws` (WebSocket upgrade). JSON text frames, one object per frame, always with `"type"`.
- Dates are ISO 8601 with offset (`2026-11-03T08:15:00+01:00`). Ids are strings.

## Live WebSocket

### App → server

| type | fields |
|---|---|
| `hello` | `appVersion`, `deviceName`, `apnsToken?` |
| `ask` | `id`, `text`, `channel` (`glasses`\|`phone`), `now`, `locale` (`de`/`en`) |
| `cancel` | `id` (the ask id) |
| `tool_result` | `callId`, `ok` (bool), `text` (model-readable result or error message) |
| `perform` | `id` (client request id), `actionId` (from an answer's `actions`) |
| `undo` | `id`, `undoId` |
| `inbox_event` | `itemId`, `event` (`shown`\|`opened`\|`dismissed`) |
| `inbox_sync` | – (ask for a full inbox) |
| `presence` | `event`, `at`, `detail?` — events: `glasses_worn`, `glasses_removed`, `glasses_connected`, `glasses_disconnected`, `gesture`, `head_up`, `phone_unlock`, `app_open`, `phone_charging`, `phone_unplugged`, `phone_still`, `phone_moving` |

### Server → app

| type | fields |
|---|---|
| `welcome` | `serverVersion`, `conversationId`, `settings` (small: `catchup`, `activeProvider`) |
| `status` | `id` (ask id), `text` (one short line, e.g. "Suche Mails …") |
| `answer` | `id`, `conversationId`, `text`, `followUps` (≤3 strings), `actions` (≤2), `undo?` |
| `error` | `id?`, `message` |
| `tool_call` | `callId`, `askId?`, `name`, `args` (JSON object). Phone tools: `location`, `reminders`. The app replies with `tool_result` within 10 s. |
| `location_access` | `phase` (`start`\|`end`), `callId`, `at` — the app shows/hides the location icon on the glasses and logs the read |
| `performed` | `id` (the perform/undo request id), `ok`, `text`, `undo?` |
| `inbox` | `full` (bool), `items` (upserts, or the whole list if `full`), `removedIds` |
| `push` | `item` (an inbox item) — also sent as `inbox` change; queued server side while offline and delivered on reconnect |
| `catchup` | `id`, `text`, `at` — one catch-up brief, shown as the first chat message / on the glasses |
| `conversation` | `conversationId`, `event` (`new`\|`compacted`) |
| `message` | `conversationId`, `role` (`user`\|`assistant`), `text`, `channel`, `at` — mirrors turns made on the other surface (glasses question appears in phone chat) |

### Answer actions and undo

`actions[]`: `{id, title, target: "phone"|"server", tool?, args?}`.
- `target: "server"` — tap sends `perform {actionId}`; server runs it and replies `performed`.
- `target: "phone"` — the app runs it itself through its `Toolbox` (`set_timer`, `create_reminder`, `start_navigation`) after the tap. Actions never run on a brain's say-so.
- `undo: {id, label}` is present after immediate actions (Bring! add/remove, self-management). The app sends `undo {undoId}`.

### Inbox item

`{id, kind (mail|calendar|job|reminder|info|…), title, summary, body, sourceRef?, createdAt, expiresAt?, status (pending|seen|dismissed|expired)}`

## Management API (HTTP/JSON)

One operations layer, two front doors: the app calls it over HTTP and the Lotti admin MCP server exposes the same operations as tools.

- `GET /api/v1/ops` → `[{name, description, inputSchema, risk: "free"|"tap"|"app_only", group}]`.
- `POST /api/v1/ops/<name>` with a JSON body = the operation input → `{ok:true, result}` or `{ok:false, error}`.
- `risk: "app_only"` ops (credentials: `secrets.*`, provider keys/tokens, account logins, OAuth tokens, pairing tokens) exist only on this HTTP API, never in the MCP server or the agent. Secrets are write-only: no op ever returns one.
- `risk: "tap"` ops, when called by the agent, return a proposed action the user must confirm; from the app they run directly.
- Op groups: `status`, `providers`, `accounts`, `bring`, `mcp`, `jobs`, `memory`, `skills`, `scripts`, `conversations`, `inbox`, `catchup`, `settings`, `privacy` (location log, shell log), `push`, `dreaming`, `admin_token`.
- Op names, inputs and outputs are listed by `GET /api/v1/ops` and documented in `apps/brain/README.md`.

## Pushes and presence

The server keeps the inbox as the source of truth. While no socket is open, `push` items queue and are replayed on reconnect (the `inbox` full sync after `hello` covers it). APNs wakes the app when configured and no socket is open.

## Implementation notes (apps/brain)

Where the backend is more specific than the contract above:

- `GET /api/v1/pair/code` answers only requests from the server itself (loopback) and logs the code. More devices: op `pairing.new_code` (app only). Pairing link in the QR/log: `lotti://pair?url=<server>&code=<code>`. Wrong codes are rate-limited (429).
- A new `hello` is answered by `welcome`, then a full `inbox`, then one `push` per item that queued while the device was offline.
- `cancel` makes the ask end with `error {id, message: "cancelled"}`; there is no `answer`.
- `message` is sent to every socket for the user turn (including the asking socket, so a glasses question shows up in the phone chat; clients ignore turns of their own channel) and for the assistant turn to every socket except the asking one (it gets `answer`).
- `answer.undo` is present when the run made a `free` op change that can be undone; `performed.undo` likewise after `perform`. `undo` answers with `performed {id, ok, text}`.
- `perform` for a `target: "phone"` action answers `performed {ok:false}`: only the app runs those.
- A `tap` op proposed by the agent appears as an action `{target:"server", tool:"op:<name>"}`.
- HTTP ops: `400 {ok:false,error}` for invalid input or a failing op, `404` for an unknown op; a successful response may carry `undo: {id,label}`.
- Admin MCP: `POST /mcp/admin` (JSON-RPC over streamable HTTP, stateless, JSON replies), `Authorization: Bearer <admin token>`; `404` while no admin token exists. Agent tools for subscription runtimes: `POST /mcp/tools` with the internal token.
