# Lotti — Architecture (draft)

Status: living document. Built: glasses link, ring input, screens and today view, on-device offline brain (timer, navigation), phone tools, turn-by-turn navigation, **Lotti Brain** (own backend, `apps/brain`), the AI-first phone app, attention and location indicators on the glasses. The wear event (sid `0x0D`) and EvenHub image containers are decoded from the APK/references and still unverified on real glasses. The UI schema, simulator and messengers are plans.

## Big picture

```
 ┌──────────── Even G2 glasses ────────────┐     ┌──── R1 ring ────┐
 │ display 576×288 · mic (LC3) · touchpads │     │ tap/scroll/hold │
 └───────────────────┬─────────────────────┘     └────────┬────────┘
                     │ BLE (sid 0x0D wear, image containers)  │
 ┌───────────────────┴─────────────────────────────────────────────┐
 │                  iPhone: Lotti app (AI-first)                   │
 │  Chat · Settings (manages everything) · Glasses link · Renderer │
 │  Phone tools: location, reminders, timer, navigation            │
 │  Router ──► BackendBrain (WebSocket)                            │
 │        └──► offline brain (timer, navigation, reminders)        │
 └────────┼────────────────────────────────────────────────────────┘
          │ WSS + HTTPS (Tailscale), device token
 ┌────────┴────────────── Lotti Brain (apps/brain, Docker) ────────┐
 │ agent loop · providers · tools · MCP client/servers · shell     │
 │ conversations · memory · dreaming · jobs · inbox · catch-up     │
 │ SQLite + /data workspace (scripts, skills)                      │
 └─────────────────────────────────────────────────────────────────┘
```

The **phone is the hub for the glasses and sensors.** **Lotti Brain is the brain.** It reads weather, calendar, mail, the web and Bring! itself, and uses the phone only for sensors and on-device actions (location, timer, reminders, navigation). The glasses and the phone chat are two ways to talk to the same conversation. Without the backend only the offline brain answers.

**Product rule:** a thing does not exist until the app can configure and manage it. Every backend feature has a screen in Settings.

## Components

| Component      | Where  | Job                                                                                                                               |
| -------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------- |
| Glasses link   | iOS    | BLE connection, auth handshake, display commands, mic stream, touchpad events                                                     |
| Ring input     | iOS    | R1 gestures. The ring is linked to the glasses, which relay its gestures through the glasses link ([S2](spikes/s2-ring.md))       |
| Renderer       | iOS    | Turns a schema screen into G2 containers; pagination, focus, gesture → action mapping                                             |
| Voice          | iOS    | Push-to-talk, on-device speech-to-text (`SpeechAnalyzer`), wake word spotter                                                      |
| Signals        | iOS    | Notifications (`AccessoryNotifications`, EU), location, calendar, battery and connection state                                    |
| Messaging      | iOS    | Quick replies to forwarded notifications for the five messengers (see below)                                                      |
| Navigation     | iOS    | Routing, step tracking, rerouting, `nav` screens on the glasses (see below)                                                       |
| Memory         | iOS    | What Lotti has learned: who matters, what you ignore, your writing style per person, places. On the phone; viewable and deletable |
| Brain router   | iOS    | Backend reachable → `BackendBrain`; otherwise the offline brain                                                                   |
| Offline brain  | iOS    | Timer, navigation, reminders and a short "I'm offline" sentence (Apple Foundation Models as a helper)                             |
| Phone tools    | iOS    | Calendar, weather, location, reminders, timer, new reminder; shared by both brains (see below)                                    |
| Backend client | iOS    | `BackendClient`/`BackendBrain`: WebSocket to Lotti Brain, phone tools, inbox, presence; `BackendManagementClient` for Settings    |
| Simulator      | web    | Renders schema screens at 576×288 with keyboard-as-ring, so UI and prompts can be iterated without glasses                        |
| UI schema      | shared | Single source of truth for screens; TypeScript, JSON Schema for LLMs, Swift mirror                                                |
| Lotti Brain    | server | Own agent loop, providers, tools, memory, jobs, inbox ([protocol](protocol.md), [apps/brain](../apps/brain/README.md))            |

## The UI schema idea

The AI never draws pixels or positions boxes. It picks a **template** and fills it in. The renderer guarantees the result fits the display. This keeps generated UI reliable, works with small on-device models, and keeps the BLE traffic small.

The templates are the building blocks from [design.md](design.md#building-blocks): Lotti says, Proposal, Original, List, Reading, Working, Listening, Card, Done. Navigation uses the glasses' native nav screen instead of a template.

Every screen also has an id (to update or dismiss it later), a **priority** (`ambient` = only when you look up, `normal`, `interrupt`), an optional time-to-live, and up to 4 **actions**. An action is bound to a gesture and runs an **intent**: dismiss, back, ask the brain, call a phone tool, reply to a notification (always via an approved Proposal), start dictation, or start navigation.

One schema definition feeds three consumers:

- **TypeScript** (simulator), with validation
- **JSON Schema**, sent to the backend so it can answer with a valid screen
- **Swift** (renderer and on-device brain), as `@Generable` types for guided generation

Shared JSON fixtures act as contract tests so all three stay in sync.

## A second layer for popups (confirmed; the spawn command is mapped)

The firmware's UI service table (`g2.service_id_def.SID`, decoded in g2-kit) separates two planes: **background** content (`DASHBOARD` 1, `NAVIGATION` 8, `EVENHUB` 224) and **foreground** popups (`MEUN` 3, `NOTIFICATION` 4, `EVEN_AI` 7, `SYSTEM_ALERT` 33, `SYSTEM_CLOSE` 34). So the Even app really does draw content below and popups above.

The spawn command is already decoded in g2-kit (`EvenHub_pb.ts`): EvenHub `Cmd 17` `OS_NOTIFY_MENU_STARTUP_PACKET` carries `MenuStartUpEvent { uint32 widgetId = 1 }`, where `widgetId` is the foreground SID (3=menu, 4=notification, 7=even_ai); the glasses reply `Cmd 18` `APP_RESPONSE_MENU_STARTUP_FAILED_PACKET` (`MenuStartUpResPonse`). See [apk-recon](spikes/apk-recon.md).

So the foreground layer is the natural home for the rail once 176 px stops being enough ([design.md](design.md#the-rail-is-too-narrow)): Lotti's sentence stays on the layer below while choices, a "More" list or the Actions list appear above it and close again, without rebuilding the content page.

The one genuinely open piece is the foreground notification body: it travels over the **file service** (sid `0xc4`/`0xc5`, `ANDROID_MSG_JSON_NOTIFICATION`) as a JSON payload whose title/body field names are still undecoded (the dashboard's `APP_SEND_NEWS_DATA` is the background news widget, not this). Confirm with a BLE capture of the official app showing a notification.

## Brain: how much can run on the phone?

**Short answer: most of the everyday work. Not the heavy tasks.**

| Task                                                        | On-device?   | Notes                                                                                                                                       |
| ----------------------------------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Speech-to-text (dictation, push-to-talk)                    | ✅           | `SpeechAnalyzer` (iOS 26+), on-device and fast                                                                                              |
| Wake word "Hey Lotti"                                       | ✅ but DIY   | No iOS API; small keyword-spotting model on the glasses mic stream. Battery is the open question; only built if push-to-talk feels limiting |
| Notification triage (show / ignore / priority)              | ✅           | Small classification task, a good fit for a ~3B model                                                                                       |
| Quick replies for messages                                  | ✅           | Short generation, user tone from a few examples                                                                                             |
| Choosing and filling a screen template                      | ✅           | Guided generation (`@Generable`) produces valid screens directly                                                                            |
| Simple tools (timer, reminder, calendar lookup, navigation) | ✅           | Tool calling in Foundation Models                                                                                                           |
| Multi-step research, mail summaries, web, anything agentic  | ❌ → backend | Needs a bigger model, more context and server tools                                                                                         |

### Which model runs locally

**Decision (D11, confirmed by [S3](spikes/s3-brain.md)): Apple's on-device Foundation Model for every task type, behind the Foundation Models `LanguageModel` API, so the model can be swapped. Gemma isn't bundled in v1.**

| Option                                                | For                                                                                                                                                                                                                | Against                                                                                                                                                                                                                                        |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Apple Foundation Model** (on-device, ~3B)           | Built into iOS: no download, no app memory, tuned for the Neural Engine, so it's light on battery and heat. Guided generation (`@Generable`) produces valid screens directly. Tool calling. Free. German supported | Small context: still 4K on iOS 27 (iPhone 16, S3). Quality ceiling of a ~3B model. Apple decides the model version. Needs Apple Intelligence enabled (works in Germany on iOS 27, S3)                                                          |
| **Gemma 4 E2B / E4B** (Google, open, Apr 2026)        | Likely better writing and multilingual quality, especially E4B. Native function calling. Native audio and image input. Runs on recent iPhones (~40–50 tok/s E2B on iPhone 17 Pro, community numbers). Apache 2.0   | S3 on iPhone 16: E2B 3.3 GB download, 2.9 GB app memory, ~2× Apple's latency (3× for tool calls); E4B 4.4 GB, killed by iOS for memory. GPU only, so likely unusable with the phone locked. Runtime: Apple's `MLXLanguageModel` (mlx-swift-lm) |
| **Other small open models** (Qwen 3, LFM2, Llama 3.2) | Very fast at 0.6–3B                                                                                                                                                                                                | Weaker at summarising and writing in your style. Only interesting as tiny helpers                                                                                                                                                              |
| **Apple Private Cloud Compute** (iOS 27)              | Bigger Apple model, 32K context, reasoning, private by design. Free for apps under 2M downloads; per-user daily quota                                                                                              | Not offline. Needs a managed entitlement (paid developer account). A middle tier, not a local model                                                                                                                                            |

Why this shape:

- **iOS 27 made the Foundation Models API model-agnostic** ("Language Model protocol", "Dynamic Profiles"). Lotti's brain is written once against this API, with tools, guided screen generation and persona. Apple's local model, a Gemma provider, PCC can sit behind it and be swapped per task.
- **Apple's model for everything.** In S3 it scored 25/35 against Gemma 4 E2B's 23/35. It led on screens, tool calls and replies, tied on triage and summaries, and was about twice as fast. It costs nothing in memory or setup.
- **Gemma 4 E2B is a tested drop-in, not a dependency.** It was clearly better only at rail suggestions, which template defaults can cover. If real use or the eval harness shows a task falling short, E2B can take it over through the same API. E4B doesn't fit on 8 GB iPhones.
- **Speech stays on Apple's `SpeechAnalyzer`.** Gemma's audio input is interesting (talk straight to the model), but it's heavier and not needed for v1.

Known limits (from S3):

- Apple's on-device context is 4K, also on iOS 27. Screens and tool calls already use 500–1,000 prompt tokens, mostly schema. Keep prompts tiny, drop tool outputs after use, and pass only the few memories relevant to the current event.
- Write prompts as explicit rules. The ~3B model copies examples from its instructions, and only calls tools when told when to.
- First token in 1.2–1.4 s, a full screen in ~2.4 s, and a cold first call in ~5 s. A first screen in under 1.5 s needs streaming, prewarming and a timeout (two calls stalled for 23 s and 59 s).
- Rail choices are the weakest output. Fill fixed choices from the template and let the model add one or two.
- Running in the background (locked phone, BLE wake-ups) is still unmeasured. Measure it once the MVP runs all day and something drains or gets killed.

**Routing (`Router`): backend first.**

| Situation                            | Brain                                                   |
| ------------------------------------ | ------------------------------------------------------- |
| Lotti Brain reachable (WebSocket up) | `BackendBrain`: every question, glasses or phone        |
| Backend unreachable                  | offline brain: timer, navigation, reminders, today view |
| Anything else while offline          | a short "Ich bin offline" / "I'm offline" sentence      |

The backend run is cancellable (double tap sends `cancel`) and its status lines stream to the glasses or phone. A silence-based timeout applies: any status or token restarts the clock. Shell steps and other server tool calls are logged, not shown on the glasses; only status lines show. Deterministic rules still come first: ring "back", gestures, the today view.

## Phone tools

One set of tools on the phone, used by the offline brain, by Lotti Brain (proxied over the WebSocket) and later by the ring's Actions list. Each tool is a `PhoneTool` in LottiKit (name, description, arguments, `read` or `action`); the app implements the real ones in `apps/ios/Lotti/PhoneTools.swift`.

| Tool               | Kind   | Backed by                                                                       | Offline brain | Lotti Brain       |
| ------------------ | ------ | ------------------------------------------------------------------------------- | ------------- | ----------------- |
| `calendar`         | read   | EventKit (your chosen calendars)                                                | ✅            | ✅ if shared      |
| `weather`          | read   | Open-Meteo at your location                                                     | ✅            | ✅ if shared      |
| `location`         | read   | CoreLocation + MapKit address                                                   | ✅            | ✅ if shared      |
| `reminders`        | read   | EventKit reminders                                                              | ✅            | ✅ if shared      |
| `start_navigation` | action | MapKit: place search near Jan (~30 km), turn-by-turn on the glasses' nav screen | ✅            | ✅ (suggest only) |
| `set_timer`        | action | AlarmKit (rings in silent mode)                                                 | ✅            | ✅ (suggest only) |
| `create_reminder`  | action | EventKit reminders                                                              | ✅            | ✅ (suggest only) |

Rules (enforced by `Toolbox`, not by prompts):

- **Reads** run as soon as a brain asks, several at once, each with a 10 s limit. Arguments are checked against the tool's parameters first.
- **Actions never run on a brain's say-so.** A brain can only _prepare_ one: it becomes a choice in the rail ("Timer 10 min"), and runs when you tap it. A wrong transcript or a confused model can't set anything.
- **You choose which phone tools the backend may call** (Settings → Phone tools). The client refuses any other tool name.
- **No fixed facts in any prompt.** Brains get the date and time; everything about Jan (where he is, his calendar, the weather there) comes from a tool in that turn. Weather needs a location fix (at most 15 minutes old); without one there is no weather rather than another city's.
- Tool results are written for small models: days by name ("tomorrow", "monday"; the code works out the date), weather spelled out ("Rain today: yes, from 15:00").

## On-device brain: a pipeline of small steps

A single session with tool calling failed on the ~3B model: it made up a free calendar instead of calling the tool, answered as if it were Jan, claimed a timer was set, and broke its output format. One step per job works far better (`LocalPipeline`, `AppleBrain`):

1. **Choose tools.** The offline brain only runs when the backend is unreachable (see Routing above). Rules first: questions the phone can never answer (news, prices, opening hours, "who won", search) get the short offline sentence. Then clear phrases ("wo bin ich", "Termin", "Wetter", "Schirm", "erinner mich", "Timer", navigation) pick tools instantly. Only otherwise does the model pick 0–3 options from a list, with descriptive option names (`remind_me_later`, `read_existing_reminders`).
2. **Fill in arguments,** one small step per chosen tool, with only that tool's parameters and no date in the prompt (the model copies a date instead of writing "tomorrow").
3. **Actions are only prepared** and get a fixed sentence ("Bereit: Timer 10 min. Tipp zum Starten."), so the model can't claim they're done.
4. **Run the reads** in parallel; the glasses show what's being checked.
5. **Shorten** results longer than ~280 characters to what the question needs.
6. **Answer** from the facts only. The answer step also says whether the facts really answer the question; if not, it says it is offline instead of guessing. Answer, in a fresh session: the answer's language is detected in code (`NLLanguageRecognizer`, German or English), Jan is addressed as du/you, 24-hour times. Facts are labelled by meaning ("where Jan is right now: …") so they don't get mixed up.

Every step is a fresh session with a small prompt, so the 4K context never fills up; follow-ups get the last three turns with their facts. A first form-based planner (one optional field per tool) failed: the model filled in nearly every field. A second planning round after the tools ran only repeated the first, so there is one round.

Measured on the Mac's model (macOS 26.6), `LOTTI_LIVE_MODEL=1 swift test --filter LiveModel`, 11 German and English questions plus a follow-up: all pass, 0.4–1.7 s per answer (rules: 0.4–1.5 s, model choice adds ~0.6 s). Navigation uses MapKit on the phone, not the backend: it knows where Jan is and the places around him. The search is limited to ~30 km (unlimited, "Media Markt Altenach" found a store 530 km away) and a misheard name is retried with fewer words. A street address in the facts can make Apple's model refuse with "unsupported language"; the answer step then retries with short instructions, then plain text, then shows the facts as they are. `location` is rules-only: the model chooser picked it for "where is the meeting" and mixed Jan's address into the answer. Still seen: the chooser sometimes picks an unrelated tool for an open question (weather for "how tall is the Eiffel tower"), an occasional invented detail ("im Café am Hafen"), and the location tool picked for questions that don't need it. The phone's iOS 27 model may differ; the same tests run there through the app's debug flags.

## Lotti Brain (backend)

`apps/brain`: Node 24 + TypeScript, one Docker image, one `/data` volume (SQLite, `workspace/scripts`, `workspace/skills`, provider login state). Env holds only `MASTER_KEY` (secrets are encrypted at rest), an optional `PUBLIC_URL` and the optional APNs key; everything else is set in the app. Setup, pairing and the op list are in [apps/brain/README.md](../apps/brain/README.md); the wire contract is [protocol.md](protocol.md).

**Two APIs, one connection.** A live WebSocket (`ask`, streamed `status`, `answer` with ≤3 follow-ups and ≤2 actions, `tool_call`/`tool_result` for phone tools, `perform`, `undo`, `inbox`, `presence`, `location_access`, `push`, `catchup`) and an HTTP management API. The management API is the **operations layer**: one registry of operations, exposed as `POST /api/v1/ops/<name>` for the app and as the **Lotti admin MCP server** for the agent. Operations carry a risk: `free`, `tap` or `app_only`.

**Providers.** Thin adapters: DeepSeek (default, API key), OpenAI and Anthropic (API key), ChatGPT subscription via the Codex CLI ("Sign in with ChatGPT" device flow, started from the app) and Claude subscription via Claude Code with a `claude setup-token` token. The subscription runtimes get Lotti's tools as an MCP server. One active provider plus an optional fallback on error or timeout. Models are settings. Claude subscription use in a third-party app carries a policy risk the user accepted.

**Tool split.** Tools are defined once (server tools, phone tools proxied over the socket, Bring!, memory, inbox, jobs, conversations, self-management) and served to the internal agent loop and as an MCP server for the subscription runtimes.

- `weather` is dynamic: the agent picks place (geocoded by Open-Meteo) or coordinates, date and time range (hourly or daily up to 16 days). There is no hidden default location; "weather here" means calling `location` first.
- `location` is a phone tool the agent may call any time. Every read emits `location_access`, shows a small location icon on the glasses and is logged in the app.
- Calendar (Google, iCloud/CalDAV, generic), mail (Gmail, iCloud/IMAP, generic), `web_fetch`, web search with a key, `shell` (workspace cwd, timeout, output cap, no secrets in env, non-root, logged).
- Bring! (unofficial API, isolated in one client): adds and removes run at once with a "Done" line and **Undo**.
- Proposed actions need a tap and run only after `perform`: `send_mail_reply`, `create_calendar_event` (server), `set_timer`, `create_reminder`, `start_navigation` (phone), and MCP tools marked as needing confirmation.
- MCP client: stdio and streamable HTTP servers, added and tested in the app, with per-tool confirmation switches.

**Conversations.** One shared current conversation for glasses and phone. After 10 minutes idle it is compacted (an LLM summary replaces old turns); after 1 hour idle a new conversation starts and the old one gets a title and summary. FTS5 over titles, summaries and turns powers `conversation_search` / `conversation_read`.

**Memory and dreaming.** SQLite + FTS5, no embeddings. Facts are extracted after compaction or conversation end, plus explicit remember/forget; the top relevant memories go into the prompt. Lotti saves reusable scripts in `workspace/scripts/` and skills in `workspace/skills/<name>/SKILL.md`; the skill index is in the prompt and skills load on demand. A nightly **dreaming** job (03:00, editable) merges duplicates, supersedes contradictions (newest wins), drops stale memories, tidies skills and writes a report.

**Jobs, inbox, indicator, catch-up.** Jobs are cron-scheduled agent runs that report nothing or create an inbox item. Built-ins: meeting soon (10 min before), important mail (every 10 min, LLM triage), dreaming. The **inbox** is server-side truth (`pending → seen → dismissed/expired`); the phone reports shown/opened/dismissed. Items never pop up on the glasses: a small **image indicator** (kind icon plus count) sits at the edge of the view, also in display-off state; the today view gives the summary and all items in full. Pushes queue on the server while offline and APNs (built, off until configured) wakes the app. The **catch-up brief** replaces the fixed morning brief: after ≥ 2 h away, or away across the night window (22:00–09:00) with the phone still or charging, the first presence signal (glasses put on, app opened) gives one short brief, once per return, or nothing if nothing is relevant. Signals: wear on/off (sid `0x0D`), glasses connect/disconnect, gestures, head-up, phone unlock/app open, charging/motion. It works without the wear event. All rules are editable in the app.

**Self-management (no CLI).** The admin MCP server is always attached to the agent. Free with a visible line and Undo: jobs, memory, skills, scripts, inbox, catch-up and other non-security settings. Need a tap: switching providers or models, MCP server changes, safety settings. App only, never through the agent: credentials (keys, passwords, OAuth, pairing and admin tokens). External access to the admin MCP is off by default and uses its own token made in the app.

**Safety.** Mail and web content is untrusted. Mitigations: no secrets in the shell env, non-root container, external-effect actions tap-confirmed, credentials app-only, commands logged. Residual risk, accepted for a personal tool: data the agent can read could be sent out via curl.

**Not built yet:** WhatsApp, Matrix, Signal, Telegram and iMessage read/write. The inbox `kind`, the tool layout and the accounts screen leave room for them.

## Messaging: iMessage, WhatsApp, Signal, Telegram, Matrix

Main path for all five: **EU notification forwarding (`AccessoryNotifications`, iOS 26.3+).** iOS forwards the notification to Lotti; Lotti shows it, suggests replies, and sends the chosen reply back through iOS. The messenger app then sends it as if you'd replied from the lock screen.

What this means in practice:

- Replies only work where the messenger's iOS notification offers an inline "Reply" field. All five do or should, but the MVP's first step has to confirm each one, especially Element/Matrix.
- Lotti only sees what's in the notification: no chat history, no earlier messages. Reply suggestions have to work from that, plus whatever Lotti remembers from earlier notifications in the same chat.
- Only one device can receive forwarded notifications. Turning it on for Lotti turns it off for an Apple Watch.

Per messenger:

| Messenger | Notification reply (main path) | Richer access, if we ever need it (history, sending first)                                        |
| --------- | ------------------------------ | ------------------------------------------------------------------------------------------------- |
| iMessage  | ✅ expected, verify in MVP     | None on iPhone. Only via a Mac (Messages.app automation). Not planned                             |
| WhatsApp  | ✅ expected, verify in MVP     | No personal API. Unofficial libraries risk an account ban. Not planned                            |
| Signal    | ✅ expected, verify in MVP     | `signal-cli` as a linked device, which needs a server. Later, optional                            |
| Telegram  | ✅ expected, verify in MVP     | Official client API (TDLib), works on-device. Later                                               |
| Matrix    | ⚠️ verify Element X in MVP     | Open client-server API, works on-device. Easiest full integration, and a fallback if replies fail |

**Starting a new message** ("Lotti, tell Mara I'm late") isn't covered by notification replies. For v1 that goes through Apple's Messages compose sheet, Shortcuts or app URL schemes, and needs a tap on the phone. True hands-free sending only works for Telegram and Matrix through their APIs.

## Navigation (port from the Even app)

The Even app's turn-by-turn navigation is the one stock feature we need to keep. Built so far (arrow + text):

- **Start:** by voice ("Hey Lotti, walk me to Mauerpark") — the brains suggest the `start_navigation` action (destination, mode walk/bike), which runs after a tap on the glasses. From a shared location (share sheet → Lotti) and from the glasses' own menu (favorites) are still open.
- **Routing:** Apple MapKit (`MKDirections`): walking and cycling (what the firmware's screen supports). Free, on the phone, no extra account — and no HERE SDK for the tiles, which is what the Even app uses (`RoutePlanner`, D10 confirmed). Alternatives if MapKit isn't good enough: Mapbox, GraphHopper, or offline routing (Valhalla with downloaded regions) later.
- **Guidance:** iOS has no turn-by-turn API for third-party apps, so Lotti tracks progress itself (`StepTracker`): a location stream (`CLLocationUpdate.liveUpdates(.otherNavigation)`) snapped onto the route, distance to the next maneuver, cards refreshed on every step change and at least every 5 s, reroute when off-route (with `RECALCULATING` on the screen meanwhile).
- **On the glasses: the firmware's built-in navigation screen** (sid `0x08`, `g2.navigation` protobuf, decoded from the Even app; see [g2-kit](https://github.com/Commute773/g2-kit), [even-g2-protocol `apps/navigation.py`](https://github.com/ithinkthisiscool/even-g2-protocol)). The phone sends an arrow ID (1–35: turns, U-turns, roundabouts, forks…) plus short text fields (distance, road, time, remaining distance, ETA, speed), and the firmware lays out the screen and rotates it heading-up. `G2Navigation` builds the payloads and decodes the screen's events; `NavigationSession` drives the whole trip: `START` → a `HEARTBEAT` every 5 s → `BASIC_INFO` cards → `ARRIVE`/`STOP`/`RECALCULATING`, and it answers the screen's `NOTIFY_EXIT`, `END_SESSION_REQ` and `SWITCH_TRANSPORT_REQ` (walk ↔ bike replans the route). While the nav screen is up, the link suspends Lotti's own page (`displaySuspended`).
- **Not confirmed live:** everything on sid 0x08 is decoded from the Even app's decompile and g2-kit; the arrow/text session has not been seen working on real glasses yet. First walk is the test. Fallback if the native screen won't take it: our own `nav` screen in containers.
- **Map bitmaps (mini map, full map):** the Even app's format is fully reconstructed (see [~/lotti-recon/map-image-push.md](https://gist.github.com/jappyjan/c97da0c4ed718799e51197522df9a5ef), verified against the decompiled app): the phone streams a **4 bpp BMP of the road network** (green roads, the active route red, everything else transparent; rows bottom-up, 64-byte palette with `biClrUsed = 3`, pixel data at 0x76; **max 576×188, mini 170×170**), **LZ4-compressed** — `compressMode` **4 = LZ4, 0 = raw** when LZ4 doesn't shrink it. The max map fragments at **4096** bytes (`mapSessionId`, `mapFragmentIndex`, `mapFragmentPacketSize`, `mapRawData`); the **mini map has its own schema** (`mapSize=1, compressMode=2, mapRawData=3, errorCode=4, rotationAngle=5(heading mod 360), miniMapBorderEn=6, sessionId=7, index=8, packetSize=9`) and ≤ 8192 bytes goes in **one message without the session fields**. The firmware **answers every fragment with an errorCode** (0 = success; 5 = protobuf error, 11 = invalid length, 13 = duplicate). The glasses' view switch picks the stream: view 1 gets the mini map, view 2/3 the max map. Lotti draws with `NavMapRenderer` + `NavMapBmp`. **Open:** Lotti has no road-network source, so only the route (red) and markers (green) are drawn — a road tile source (e.g. OSM vector tiles) would fill in the roads.
- **Turn arrows:** MapKit gives no maneuver type, so `RoutePlanner` classifies each step from the route geometry (bearing change: straight / slight / turn / sharp / U-turn). Roundabout arrows (11–29) stay unused until roundabout exits can be detected.
- **Heading:** the native nav screen uses the glasses' compass (it sends compass events back). Outside native nav: phone compass.
- **Battery:** navigation is location-heavy. Measure it now that navigation is built.

## Planned repo layout

The workspace is empty for now. Projects get created when their milestone starts.

```
apps/
  ios/          Lotti iPhone app (SwiftUI, plain Xcode project), Nx run-commands targets
  simulator/    Web simulator for screens and gestures
packages/
  ui-schema/    Screen schema (source of truth) + JSON Schema + fixtures
  persona/      Lotti's system prompt and voice
  lotti-kit/    Swift package: glasses link, ring, renderer, brain, signals, messaging,
                navigation, voice, backend client
docs/           vision, architecture, roadmap
```

## Decisions

| #   | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Status                                      |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| D1  | Native iOS app with direct BLE; replaces the Even app while connected                                                                                                                                                                                                                                                                                                                                                                                                                                             | ✅ decided                                  |
| D2  | ~~Hermes first~~ — superseded (see D13): Lotti Brain first; the offline brain answers only timer, navigation and reminders without the backend                                                                                                                                                                                                                                                                                                                                                                    | ⛔ superseded (2026-11-03)                  |
| D3  | ~~Hermes is external~~ — superseded: Hermes is removed; Lotti has its own backend                                                                                                                                                                                                                                                                                                                                                                                                                                 | ⛔ superseded (2026-11-03)                  |
| D4  | Push-to-talk after the MVP; wake word only if push-to-talk feels limiting (then check battery)                                                                                                                                                                                                                                                                                                                                                                                                                    | ✅ decided                                  |
| D5  | Template-based UI schema instead of free layout                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | ✅ proposed                                 |
| D6  | Build our own BLE layer in LottiKit, using g2-kit, even-g2-protocol and MentraOS as references; behind `GlassesLink` ([S1](spikes/s1-ble.md#d6-build-our-own-ble-layer))                                                                                                                                                                                                                                                                                                                                          | ✅ decided                                  |
| D7  | Xcode project: plain checked-in project with synchronized folders, no XcodeGen/Tuist ([S1](spikes/s1-ble.md#d7-plain-checked-in-xcode-project))                                                                                                                                                                                                                                                                                                                                                                   | ✅ decided                                  |
| D8  | Own server for pushes and the brain                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | ✅ decided: yes (Lotti Brain, 2026-11-03)   |
| D9  | Messaging main path: EU notification forwarding for all five messengers. Needs a paid developer account (entitlements not available to the Personal Team, checked 2026-11-01)                                                                                                                                                                                                                                                                                                                                     | ⏸ blocked on paid account                   |
| D10 | Navigation routing: MapKit first, alternative providers only if needed                                                                                                                                                                                                                                                                                                                                                                                                                                            | ✅ decided (M5; no HERE/Mapbox anywhere)    |
| D11 | Local model: Apple Foundation Model for all tasks, behind the Foundation Models API; Gemma not bundled in v1, E2B a tested drop-in ([S3](spikes/s3-brain.md#model-choice-per-task-d11))                                                                                                                                                                                                                                                                                                                           | ✅ decided                                  |
| D12 | A second display layer for popups. Confirmed via `g2.service_id_def.SID` (background vs foreground). The menu widget's content command is mapped: `g2.menu` (sid 0x03) `APP_SEND_MENU_INFO` with selectable items, picks back via EvenHub Cmd 0x15. But the menu is opened by the firmware (Cmd 17 is OS→app); no app-side open command is known. Open: how to open a foreground popup on demand — likely needs a live BLE capture (notification-widget JSON schema, sid 0x04) ([apk-recon](spikes/apk-recon.md)) | ✅ mapped (menu content); ⏳ open-on-demand |
| D13 | Backend: Node 24 + TypeScript in Nx (`apps/brain`), one Docker image, SQLite + FTS5 on a volume, reached over Tailscale/HTTPS                                                                                                                                                                                                                                                                                                                                                                                     | ✅ decided (2026-11-03)                     |
| D14 | Providers: DeepSeek (default, key), OpenAI and Anthropic (key), ChatGPT via Codex sign-in, Claude via Claude Code token; one active plus fallback                                                                                                                                                                                                                                                                                                                                                                 | ✅ decided                                  |
| D15 | AI-first phone app: chat first, Settings manage everything ("a thing does not exist until the app can manage it")                                                                                                                                                                                                                                                                                                                                                                                                 | ✅ decided                                  |
| D16 | Indicators, not notifications: small image indicator (kind icon + count) at the edge; location icon on every location read                                                                                                                                                                                                                                                                                                                                                                                        | ✅ decided                                  |
| D17 | Catch-up brief from wear detection plus away/slept heuristics replaces the morning brief                                                                                                                                                                                                                                                                                                                                                                                                                          | ✅ decided                                  |
| D18 | Self-management through the Lotti admin MCP server, no CLI; tap only for providers/models, MCP and safety; credentials app-only                                                                                                                                                                                                                                                                                                                                                                                   | ✅ decided                                  |
| D19 | Offline brain keeps timer, navigation, reminders; handoffs removed                                                                                                                                                                                                                                                                                                                                                                                                                                                | ✅ decided                                  |
| D20 | Bring! natively via the unofficial API; adds/removes immediate with Undo                                                                                                                                                                                                                                                                                                                                                                                                                                          | ✅ decided                                  |
| D21 | Messengers (WhatsApp, Matrix, Signal, Telegram, iMessage) read/write later, not now                                                                                                                                                                                                                                                                                                                                                                                                                               | ⏳ later                                    |
