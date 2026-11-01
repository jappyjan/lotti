# Lotti — Architecture (draft)

Status: draft for discussion. Nothing here is built yet.

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
| Hermes connector | iOS    | Sends a request to your Hermes endpoint, gets back screens or text. Endpoint and key set in Lotti settings                        |
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
2. **On-device model** (first token ~1.3 s, full screen ~2.4 s; Apple FM): triage, quick replies, screen generation, simple tools, starting navigation.
3. **Hermes connector** (seconds): anything the on-device model flags as "needs more", or the user asks for explicitly ("Lotti, dig into…").

## Hermes connector

What Lotti needs from Hermes, and nothing more:

- **An endpoint + API key**, entered in Lotti's settings. Hermes Agent exposes an OpenAI-compatible API; the connector work after the MVP confirms the details.
- **Request:** Lotti's persona prompt, the screen JSON Schema, a short description of the event (utterance, notification, location), and minimal context the user allowed.
- **Response:** a screen (structured output, or a `show_screen` call Lotti defines on the client side), or plain text, which Lotti wraps in a `text` screen.
- **Streaming:** while Hermes works, the glasses show a `progress`/`stream` screen; ring "back" cancels.
- **Offline / unreachable:** a clear toast, and the on-device brain handles what it can.

Lotti does **not** run a server of its own in this plan. If we later need Hermes to push things to the glasses unprompted (a long task finishes an hour later), that needs a small relay. It's listed under "Later" in the roadmap, decision D8.

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
  - Unverified: everything is decoded from the app binary, and nobody has confirmed it live yet. Fallback: our own `nav` screen in containers.
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
