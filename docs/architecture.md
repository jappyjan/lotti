# Lotti — Architecture (draft)

Status: living document. Built so far: glasses link, ring input, the hand-coded screen and today view, on-device chat and voice, phone tools and the Hermes connector. The UI schema, simulator, messaging and navigation are still plans.

## Big picture

```
 ┌──────────── Even G2 glasses ────────────┐     ┌──── R1 ring ────┐
 │ display 576×288 · mic (LC3) · touchpads │     │ tap/scroll/hold │
 └───────────────────┬─────────────────────┘     └────────┬────────┘
                     │ BLE ◄──── ring gestures ───────────┘ BLE (glasses ↔ ring)
                     │ (reverse-engineered protocol)
 ┌───────────────────┴─────────────────────────────────────────────┐
 │                       iPhone: Lotti app                         │
 │  Glasses link · Ring input · Renderer (schema → G2 containers)  │
 │  Voice (push-to-talk, dictation, "Hey Lotti")                   │
 │  Signals (notifications, location, calendar, battery)           │
 │  Navigation (routing, turn-by-turn on the glasses)              │
 │  Brain router ──► on-device brain (Apple Foundation Models)     │
 │        │                                                        │
 │        └──► Hermes connector                                    │
 └────────┼────────────────────────────────────────────────────────┘
          │ HTTPS (only when escalating)
 ┌────────┴──────────── existing Hermes (not part of Lotti) ───────┐
 │  Your Hermes Agent, its model, tools and memory                 │
 └─────────────────────────────────────────────────────────────────┘
```

The **phone is the hub.** It owns the glasses and ring connection, gathers signals, renders screens and runs the fast brain. Lotti must stay useful offline.

**Hermes is external.** Lotti ships a connector to it and nothing more. Installing, configuring, choosing models for, or adding tools to Hermes is out of scope for this repo.

## Components

| Component        | Where  | Job                                                                                                                               |
| ---------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------- |
| Glasses link     | iOS    | BLE connection, auth handshake, display commands, mic stream, touchpad events                                                     |
| Ring input       | iOS    | R1 gestures. The ring is linked to the glasses, which relay its gestures through the glasses link ([S2](spikes/s2-ring.md))       |
| Renderer         | iOS    | Turns a schema screen into G2 containers; pagination, focus, gesture → action mapping                                             |
| Voice            | iOS    | Push-to-talk, on-device speech-to-text (`SpeechAnalyzer`), wake word spotter                                                      |
| Signals          | iOS    | Notifications (`AccessoryNotifications`, EU), location, calendar, battery and connection state                                    |
| Messaging        | iOS    | Quick replies to forwarded notifications for the five messengers (see below)                                                      |
| Navigation       | iOS    | Routing, step tracking, rerouting, `nav` screens on the glasses (see below)                                                       |
| Memory           | iOS    | What Lotti has learned: who matters, what you ignore, your writing style per person, places. On the phone; viewable and deletable |
| Brain router     | iOS    | Decides per event: rules → on-device model → Hermes connector                                                                     |
| On-device brain  | iOS    | Apple Foundation Models with tool calling and guided generation of screens                                                        |
| Phone tools      | iOS    | Calendar, weather, location, reminders, timer, new reminder; shared by both brains (see below)                                    |
| Hermes connector | iOS    | Sends a question to your Hermes, runs the phone tools it asks for, gets back a sentence and actions. Address and key in Lotti     |
| Simulator        | web    | Renders schema screens at 576×288 with keyboard-as-ring, so UI and prompts can be iterated without glasses                        |
| UI schema        | shared | Single source of truth for screens; TypeScript, JSON Schema for LLMs, Swift mirror                                                |
| Persona          | shared | Lotti's system prompt and voice, used by the on-device brain and sent along with Hermes requests                                  |

## The UI schema idea

The AI never draws pixels or positions boxes. It picks a **template** and fills it in. The renderer guarantees the result fits the display. This keeps generated UI reliable, works with small on-device models, and keeps the BLE traffic small.

The templates are the building blocks from [design.md](design.md#building-blocks): Lotti says, Proposal, Original, List, Reading, Working, Listening, Card, Done. Navigation uses the glasses' native nav screen instead of a template.

Every screen also has an id (to update or dismiss it later), a **priority** (`ambient` = only when you look up, `normal`, `interrupt`), an optional time-to-live, and up to 4 **actions**. An action is bound to a gesture and runs an **intent**: dismiss, back, ask the brain, call a phone tool, reply to a notification (always via an approved Proposal), start dictation, or start navigation.

One schema definition feeds three consumers:

- **TypeScript** (simulator), with validation
- **JSON Schema**, sent to Hermes so it can answer with a valid screen
- **Swift** (renderer and on-device brain), as `@Generable` types for guided generation

Shared JSON fixtures act as contract tests so all three stay in sync.

## A second layer for popups (confirmed; the spawn command is mapped)

The firmware's UI service table (`g2.service_id_def.SID`, decoded in g2-kit) separates two planes: **background** content (`DASHBOARD` 1, `NAVIGATION` 8, `EVENHUB` 224) and **foreground** popups (`MEUN` 3, `NOTIFICATION` 4, `EVEN_AI` 7, `SYSTEM_ALERT` 33, `SYSTEM_CLOSE` 34). So the Even app really does draw content below and popups above.

The spawn command is already decoded in g2-kit (`EvenHub_pb.ts`): EvenHub `Cmd 17` `OS_NOTIFY_MENU_STARTUP_PACKET` carries `MenuStartUpEvent { uint32 widgetId = 1 }`, where `widgetId` is the foreground SID (3=menu, 4=notification, 7=even_ai); the glasses reply `Cmd 18` `APP_RESPONSE_MENU_STARTUP_FAILED_PACKET` (`MenuStartUpResPonse`). See [apk-recon](spikes/apk-recon.md).

So the foreground layer is the natural home for the rail once 176 px stops being enough ([design.md](design.md#the-rail-is-too-narrow)): Lotti's sentence stays on the layer below while choices, a "More" list or the Actions list appear above it and close again, without rebuilding the content page.

The one genuinely open piece is the command that fills a foreground notification popup's body (title/body) once it's spawned — the dashboard's `APP_SEND_NEWS_DATA` is the background news widget, not the foreground popup. Confirm with a BLE capture of the official app showing a notification.

## Brain: how much can run on the phone?

**Short answer: most of the everyday work. Not the heavy tasks.**

| Task                                                        | On-device?  | Notes                                                                                                                                       |
| ----------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Speech-to-text (dictation, push-to-talk)                    | ✅          | `SpeechAnalyzer` (iOS 26+), on-device and fast                                                                                              |
| Wake word "Hey Lotti"                                       | ✅ but DIY  | No iOS API; small keyword-spotting model on the glasses mic stream. Battery is the open question; only built if push-to-talk feels limiting |
| Notification triage (show / ignore / priority)              | ✅          | Small classification task, a good fit for a ~3B model                                                                                       |
| Quick replies for messages                                  | ✅          | Short generation, user tone from a few examples                                                                                             |
| Choosing and filling a screen template                      | ✅          | Guided generation (`@Generable`) produces valid screens directly                                                                            |
| Simple tools (timer, reminder, calendar lookup, navigation) | ✅          | Tool calling in Foundation Models                                                                                                           |
| Multi-step research, mail summaries, web, anything agentic  | ❌ → Hermes | Needs a bigger model, more context and whatever tools your Hermes has                                                                       |

### Which model runs locally

**Decision (D11, confirmed by [S3](spikes/s3-brain.md)): Apple's on-device Foundation Model for every task type, behind the Foundation Models `LanguageModel` API, so the model can be swapped. Gemma isn't bundled in v1.**

| Option                                                | For                                                                                                                                                                                                                | Against                                                                                                                                                                                                                                        |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Apple Foundation Model** (on-device, ~3B)           | Built into iOS: no download, no app memory, tuned for the Neural Engine, so it's light on battery and heat. Guided generation (`@Generable`) produces valid screens directly. Tool calling. Free. German supported | Small context: still 4K on iOS 27 (iPhone 16, S3). Quality ceiling of a ~3B model. Apple decides the model version. Needs Apple Intelligence enabled (works in Germany on iOS 27, S3)                                                          |
| **Gemma 4 E2B / E4B** (Google, open, Apr 2026)        | Likely better writing and multilingual quality, especially E4B. Native function calling. Native audio and image input. Runs on recent iPhones (~40–50 tok/s E2B on iPhone 17 Pro, community numbers). Apache 2.0   | S3 on iPhone 16: E2B 3.3 GB download, 2.9 GB app memory, ~2× Apple's latency (3× for tool calls); E4B 4.4 GB, killed by iOS for memory. GPU only, so likely unusable with the phone locked. Runtime: Apple's `MLXLanguageModel` (mlx-swift-lm) |
| **Other small open models** (Qwen 3, LFM2, Llama 3.2) | Very fast at 0.6–3B                                                                                                                                                                                                | Weaker at summarising and writing in your style. Only interesting as tiny helpers                                                                                                                                                              |
| **Apple Private Cloud Compute** (iOS 27)              | Bigger Apple model, 32K context, reasoning, private by design. Free for apps under 2M downloads; per-user daily quota                                                                                              | Not offline. Needs a managed entitlement (paid developer account). A middle tier, not a local model                                                                                                                                            |

Why this shape:

- **iOS 27 made the Foundation Models API model-agnostic** ("Language Model protocol", "Dynamic Profiles"). Lotti's brain is written once against this API, with tools, guided screen generation and persona. Apple's local model, a Gemma provider, PCC or even the Hermes connector can sit behind it and be swapped per task.
- **Apple's model for everything.** In S3 it scored 25/35 against Gemma 4 E2B's 23/35. It led on screens, tool calls and replies, tied on triage and summaries, and was about twice as fast. It costs nothing in memory or setup.
- **Gemma 4 E2B is a tested drop-in, not a dependency.** It was clearly better only at rail suggestions, which template defaults can cover. If real use or the eval harness shows a task falling short, E2B can take it over through the same API. E4B doesn't fit on 8 GB iPhones.
- **Speech stays on Apple's `SpeechAnalyzer`.** Gemma's audio input is interesting (talk straight to the model), but it's heavier and not needed for v1.

Known limits (from S3):

- Apple's on-device context is 4K, also on iOS 27. Screens and tool calls already use 500–1,000 prompt tokens, mostly schema. Keep prompts tiny, drop tool outputs after use, and pass only the few memories relevant to the current event.
- Write prompts as explicit rules. The ~3B model copies examples from its instructions, and only calls tools when told when to.
- First token in 1.2–1.4 s, a full screen in ~2.4 s, and a cold first call in ~5 s. A first screen in under 1.5 s needs streaming, prewarming and a timeout (two calls stalled for 23 s and 59 s).
- Rail choices are the weakest output. Fill fixed choices from the template and let the model add one or two.
- Running in the background (locked phone, BLE wake-ups) is still unmeasured. Measure it once the MVP runs all day and something drains or gets killed.

**Router tiers:**

1. **Rules** (0 ms): deterministic stuff. Ring "back", known apps muted, do-not-disturb.
2. **On-device model** (0.4–1.7 s for an answer with tools; Apple FM, as a pipeline of small steps, see below): everyday questions, phone tools, quick replies, starting navigation.
3. **Hermes connector** (seconds): anything the on-device chooser hands over, or you ask for explicitly ("Hermes, …", "Dig into…", "Ask Hermes" in the rail).

## Phone tools

One set of tools on the phone, used by the on-device brain, by Hermes and later by the ring's Actions list. Each tool is a `PhoneTool` in LottiKit (name, description, arguments, `read` or `action`); the app implements the real ones in `apps/ios/Lotti/PhoneTools.swift`.

| Tool              | Kind   | Backed by                                                                        | On-device brain | Hermes            |
| ----------------- | ------ | -------------------------------------------------------------------------------- | --------------- | ----------------- |
| `calendar`        | read   | EventKit (your chosen calendars)                                                 | ✅              | ✅ if shared      |
| `weather`         | read   | Open-Meteo at your location                                                      | ✅              | ✅ if shared      |
| `location`        | read   | CoreLocation + MapKit address                                                    | ✅              | ✅ if shared      |
| `reminders`       | read   | EventKit reminders                                                               | ✅              | ✅ if shared      |
| `directions`      | read   | MapKit: place search near Jan (~30 km), travel times on foot, bike, transit, car | ✅              | ✅ if shared      |
| `set_timer`       | action | AlarmKit (rings in silent mode)                                                  | ✅              | ✅ (suggest only) |
| `create_reminder` | action | EventKit reminders                                                               | ✅              | ✅ (suggest only) |

Rules (enforced by `Toolbox`, not by prompts):

- **Reads** run as soon as a brain asks, several at once, each with a 10 s limit. Arguments are checked against the tool's parameters first.
- **Actions never run on a brain's say-so.** A brain can only _prepare_ one: it becomes a choice in the rail ("Timer 10 min"), and runs when you tap it. A wrong transcript or a confused model can't set anything.
- **You choose what Hermes may read** (Lotti app → Hermes). Unshared reads are left out of Hermes's prompt and refused if asked for anyway.
- **No fixed facts in any prompt.** Brains get the date and time; everything about Jan (where he is, his calendar, the weather there) comes from a tool in that turn. Weather needs a location fix (at most 15 minutes old); without one there is no weather rather than another city's.
- Tool results are written for small models: days by name ("tomorrow", "monday"; the code works out the date), weather spelled out ("Rain today: yes, from 15:00").

## On-device brain: a pipeline of small steps

A single session with tool calling failed on the ~3B model: it made up a free calendar instead of calling the tool, answered as if it were Jan, claimed a timer was set, and broke its output format. One step per job works far better (`LocalPipeline`, `AppleBrain`):

1. **Choose tools.** Rules first. Questions only Hermes can answer (news, prices, opening hours, "who won", search) go straight to Hermes; Hermes asks the phone for the location itself when "here" matters. Then clear phrases ("wo bin ich", "Termin", "Wetter", "Schirm", "erinner mich", "Timer", …) pick tools instantly. Only otherwise does the model pick 0–3 options from a list, with descriptive option names (`remind_me_later`, `read_existing_reminders`, `hermes_web_news_research`). Hermes is one of the options.
2. **Fill in arguments,** one small step per chosen tool, with only that tool's parameters and no date in the prompt (the model copies a date instead of writing "tomorrow").
3. **Actions are only prepared** and get a fixed sentence ("Bereit: Timer 10 min. Tipp zum Starten."), so the model can't claim they're done. A hand-off gets "Ich frag Hermes."
4. **Run the reads** in parallel; the glasses show what's being checked.
5. **Shorten** results longer than ~280 characters to what the question needs.
6. **Answer** from the facts only. The answer step also says whether the facts really answer the question; if not, the question goes to Hermes instead of "I don't know". Answer, in a fresh session: the answer's language is detected in code (`NLLanguageRecognizer`, German or English), Jan is addressed as du/you, 24-hour times. Facts are labelled by meaning ("where Jan is right now: …") so they don't get mixed up.

Every step is a fresh session with a small prompt, so the 4K context never fills up; follow-ups get the last three turns with their facts. A first form-based planner (one optional field per tool) failed: the model filled in nearly every field. A second planning round after the tools ran only repeated the first, so there is one round.

Measured on the Mac's model (macOS 26.6), `LOTTI_LIVE_MODEL=1 swift test --filter LiveModel`, 11 German and English questions plus a follow-up: all pass, 0.4–1.7 s per answer (rules: 0.4–1.5 s, model choice adds ~0.6 s). Directions use MapKit on the phone, not Hermes: it knows where Jan is and the places around him. The search is limited to ~30 km (unlimited, "Media Markt Altenach" found a store 530 km away) and a misheard name is retried with fewer words. A street address in the facts can make Apple's model refuse with "unsupported language"; the answer step then retries with short instructions, then plain text, then shows the facts as they are. `location` is rules-only: the model chooser picked it for "where is the meeting" and mixed Jan's address into the answer. An answer that says "I don't know" goes to Hermes. Still seen: the chooser sometimes picks an unrelated tool for an open question (weather for "how tall is the Eiffel tower"), an occasional invented detail ("im Café am Hafen"), and the location tool picked for questions that don't need it. The phone's iOS 27 model may differ; the same tests run there through the app's debug flags.

## Hermes connector

Built (`packages/lotti-kit/Sources/LottiKit/Hermes`). Lotti talks to Hermes's API server (`hermes gateway`, OpenAI-compatible `/v1/chat/completions`), with the address and `API_SERVER_KEY` set in the Lotti app (key in the Keychain). Nothing in Hermes needs configuring.

**When Lotti asks Hermes:**

1. You say so: "Hermes, …", "Frag Hermes …", "Dig into …" (rules, no model).
2. The on-device chooser picks Hermes (news, the web, prices, opening hours, research).
3. You pick "Ask Hermes" in the rail under any on-device answer.

Once a conversation is with Hermes, its follow-ups stay there until the conversation ends (double tap, or 5 minutes).

**Phone tools for Hermes: Lotti's reply format.** Hermes runs its own tools on its server and never hands tool calls back to the client, so the phone's tools travel inside the conversation as JSON. Lotti's system message (Hermes layers it on top of its own prompt) lists the tools you share and asks for exactly one JSON object per reply:

```json
{
  "type": "call",
  "status": "Checking your day",
  "calls": [
    { "id": "c1", "tool": "calendar", "args": { "from": "2026-11-02" } },
    { "id": "c2", "tool": "weather", "args": {} }
  ]
}
```

All calls in one reply run at the same time. The phone answers in the same conversation:

```json
{
  "type": "results",
  "results": [
    { "id": "c1", "ok": true, "content": "Mon 2 Nov: 09:30–09:45 Standup" },
    {
      "id": "c2",
      "ok": true,
      "content": "Weather tomorrow: light rain, 6–11°C"
    }
  ]
}
```

and Hermes calls again or answers:

```json
{
  "type": "answer",
  "sentence": "Standup at 9:30, and take an umbrella.",
  "followUps": ["Later?"],
  "actions": [
    { "tool": "set_timer", "args": { "minutes": 10, "label": "Leave" } }
  ]
}
```

Details:

- **Limits:** at most 4 rounds of phone calls per question; with the last results Hermes is told to answer now. The whole question gives up after 2 minutes; double tap cancels sooner.
- **Hermes asks for what it needs.** The first message carries only the date and time; calendar, weather and location are sent only when Hermes calls for them.
- **Forgiving parser:** finds the JSON inside fences or prose, accepts `args` or `arguments`, numbers missing ids. A reply that isn't JSON is shown as plain text. Invalid actions are dropped.
- **Stateless:** every request carries the whole conversation, so the phone owns the history (Hermes's `X-Hermes-Session-Id` isn't used; mixing it with a full history isn't documented). A failed or cancelled question is removed, so "Try again" starts clean.
- **Streaming:** Hermes's `hermes.tool.progress` events and the format's `status` show on the glasses' working screen ("Searching the web…", "Checking your calendar…").
- **Errors:** unreachable, wrong key, busy or too slow each get a short sentence and a "Try again" choice.
- **Network:** HTTPS (e.g. `tailscale serve`) or plain HTTP on the local network. Hermes binds to localhost by default, so it has to be reachable from the phone.

**Trying it without Hermes:** `python3 packages/lotti-kit/scripts/mock-hermes.py` plays Hermes (two parallel phone calls, then an answer with a timer). `HERMES_URL=… HERMES_KEY=… swift test --filter LiveHermes` runs the connector against it or against your real Hermes. `LOTTI_LIVE_MODEL=1 swift test --filter LiveModel` checks the on-device brain's tool use.

Lotti still runs no server of its own. Hermes pushing to the glasses unprompted (a long task finishing later) needs a relay: decision D8, under "Later".

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

The Even app's turn-by-turn navigation is the one stock feature we need to keep. Plan:

- **Start:** by voice ("Hey Lotti, walk me to Mauerpark"), from a `list`/`card` action, or from a shared location on the phone (share sheet → Lotti).
- **Routing:** Apple MapKit (`MKDirections`): walking, driving, cycling (MapKit availability per region: check), transit only as overview. It's free, on the phone, no extra account. Alternatives if MapKit isn't good enough: Mapbox, GraphHopper, or offline routing (Valhalla with downloaded regions) later.
- **Guidance:** iOS has no turn-by-turn API for third-party apps, so Lotti tracks progress itself: background location, distance to the next step, announce at fixed distances, reroute when off-route.
- **On the glasses: use the firmware's built-in navigation screen.** The G2 has a native navigation mini-app on its own BLE service (sid `0x08`, `g2.navigation` protobuf, decoded from the Even app; see [g2-kit](https://github.com/Commute773/g2-kit), [even-g2-protocol `apps/navigation.py`](https://github.com/ithinkthisiscool/even-g2-protocol)). The phone sends an arrow ID (1–35: turns, U-turns, roundabouts, forks…) plus short text fields (distance, road, time, remaining distance, ETA, speed), and the firmware lays out the screen. The phone sends maps (mini map and full map) as bitmaps. The firmware handles the heading-up rotation and the compass, and reports view changes and exit back to the phone. This is what Even's own app uses, so we get Even's layout without drawing it ourselves.
  - Plan: arrow and text first; maps once their format is known (capture BLE traffic from the Even app during a real walk).
  - Decoded: the `g2.navigation` proto is complete (arrow ID, text fields, mini/max map bitmap streaming, compass events); see [apk-recon](spikes/apk-recon.md). The Even app itself routes with Mapbox and streams the arrow + bitmaps to the glasses, confirming the approach. Nobody has confirmed it live on our side yet; fallback: our own `nav` screen in containers.
  - Even's nav supports walking and cycling only; driving would need our own screen.
- **Heading:** the native nav screen uses the glasses' compass (it sends compass events back). Outside native nav: phone compass.
- **Battery:** navigation is location-heavy. Measure it when navigation is built.

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
                navigation, voice, Hermes connector
docs/           vision, architecture, roadmap
```

## Decisions

| #   | Decision                                                                                                                                                                                | Status                                |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| D1  | Native iOS app with direct BLE; replaces the Even app while connected                                                                                                                   | ✅ decided                            |
| D2  | On-device first, Hermes for escalation                                                                                                                                                  | ✅ decided ([S3](spikes/s3-brain.md)) |
| D3  | Hermes is external: Lotti only has a connector; no Hermes setup, model choice or tools in this repo                                                                                     | ✅ decided                            |
| D4  | Push-to-talk after the MVP; wake word only if push-to-talk feels limiting (then check battery)                                                                                          | ✅ decided                            |
| D5  | Template-based UI schema instead of free layout                                                                                                                                         | ✅ proposed                           |
| D6  | Build our own BLE layer in LottiKit, using g2-kit, even-g2-protocol and MentraOS as references; behind `GlassesLink` ([S1](spikes/s1-ble.md#d6-build-our-own-ble-layer))                | ✅ decided                            |
| D7  | Xcode project: plain checked-in project with synchronized folders, no XcodeGen/Tuist ([S1](spikes/s1-ble.md#d7-plain-checked-in-xcode-project))                                         | ✅ decided                            |
| D8  | Do we ever need our own relay server (Hermes pushing unprompted, Signal via signal-cli)? Default: no                                                                                    | ⏳ open, revisit after M6             |
| D9  | Messaging main path: EU notification forwarding for all five messengers. Needs a paid developer account (entitlements not available to the Personal Team, checked 2026-11-01)           | ⏸ blocked on paid account             |
| D10 | Navigation routing: MapKit first, alternative providers only if needed                                                                                                                  | ✅ proposed (pending S8)              |
| D11 | Local model: Apple Foundation Model for all tasks, behind the Foundation Models API; Gemma not bundled in v1, E2B a tested drop-in ([S3](spikes/s3-brain.md#model-choice-per-task-d11)) | ✅ decided                            |
| D12 | A second display layer for popups. Confirmed via `g2.service_id_def.SID` (background vs foreground); the spawn command is EvenHub Cmd 17 `OS_NOTIFY_MENU_STARTUP_PACKET` → `MenuStartUpEvent{widgetId}`. Open: the foreground-notification content command ([apk-recon](spikes/apk-recon.md)) | ✅ mapped (spawn); ⏳ content cmd |
