# Lotti — Roadmap

Format: each **milestone** maps to a Linear project, each **issue** to a Linear issue.
Labels: `spike`, `ios`, `shared`, `design`, `docs`, plus feature labels `navigation`, `messaging`, `voice`, `brain`.

Order matters. M0 answers the questions that could kill or reshape the plan before we build on top of them. Navigation comes early because it's the one Even app feature we must replace before Lotti can be used day to day.

Out of scope for every milestone: setting up, configuring or adding tools to Hermes. Lotti only connects to an existing Hermes.

---

## M0 — Spikes: can we do this?

Goal: answer the risky questions with throwaway prototypes. Each spike ends with a short write-up in `docs/spikes/`.

- **S1 — Talk to the G2 over BLE from iOS** `spike` `ios`
  Connect, authenticate, draw text, receive touchpad events. Compare MentraOS iOS SDK, OpenEvenSdk, g2-kit and even-realities-app-template (license, completeness, maintenance).
  _Done when:_ "Hello from Lotti" shows on the glasses from our own app; a decision on D6 is written.
- **S2 — R1 ring input** `spike` `ios`
  Pair and authenticate the R1, receive tap/scroll/hold. Can the ring and glasses both connect to our app at once?
  _Done when:_ ring gestures are logged in our app while the glasses are connected.
- **S3 — On-device brain quality** `spike` `ios` `brain`
  Apple's on-device Foundation Model vs Gemma 4 E2B and E4B on a real iPhone, both behind the Foundation Models API. Tasks: triage, one-sentence summaries (German + English), rail suggestions, replies in your own style, screen generation, tool calls. Measure quality, latency, memory, battery and heat over 30 minutes of sustained use, and background behaviour. Check what iOS 27 changes (on-device context size, Private Cloud Compute).
  _Done when:_ there's a small eval set (~30 real notifications/requests) with Apple FM vs Gemma 4 vs Hermes results, a model choice per task type, and decision D11 confirmed or changed.
  ✅ Done ([write-up](spikes/s3-brain.md)): Apple's model for all tasks, Gemma not bundled. Hermes and PCC not run (no endpoint; PCC needs a paid account). Battery/heat and locked-phone runs moved to S7.
- **S4 — Wake word battery cost** `spike` `ios` `voice`
  Stream the glasses mic continuously, run a keyword spotter (openWakeWord / Porcupine / custom) for "Hey Lotti". Measure glasses + phone battery drain per hour against push-to-talk only. Measure false wake-ups per hour of normal conversation (German + English).
  _Done when:_ a table of battery drain and false-trigger rate exists; decision on wake word for v1.
- **S5 — Notification forwarding and replies (EU)** `spike` `ios` `messaging`
  `AccessoryNotifications` (iOS 26.3+): receive forwarded notifications and send a quick reply back. Entitlements needed? Does it coexist with the BLE link?
  _Done when:_ a reply sent from our app arrives for **each** of iMessage, WhatsApp, Signal, Telegram and Matrix (Element X), and a table records what works per messenger (reply, mark read, what text is visible).
- **S6 — Hermes connector** `spike` `brain`
  Call an existing Hermes from the phone: endpoint, auth, streaming, and how to get a screen back (structured output vs a client-side `show_screen` tool). No changes to Hermes itself.
  _Done when:_ an utterance sent from the phone comes back as a valid screen shown in the simulator or on the glasses.
- **S7 — Background life on iOS** `spike` `ios`
  Keep BLE, mic and model working with the phone locked for hours. What gets killed and when? Includes what S3 didn't get to: Apple's model with the phone locked, and battery and heat over 30 minutes of sustained use (`--background` / `--soak` in the eval screen, see [S3](spikes/s3-brain.md#running-the-eval)).
  _Done when:_ a 4-hour locked-phone test log exists.
- **S8 — Navigation** `spike` `ios` `navigation`
  Drive the G2's **built-in navigation screen** (BLE sid `0x08`, decoded but untested; see architecture.md): START → BASIC_INFO with arrow ID + texts, heartbeat, ARRIVE/STOP. Capture BLE traffic from the Even app during a real walk to learn the mini/full map bitmap format. Plus MapKit walking/cycling routes in Germany, step tracking with background location, rerouting. Measure battery per hour of guidance.
  _Done when:_ a real 20-minute walk is guided on the glasses' native nav screen (or we know why it can't be), the map format is documented, with a battery and accuracy note; decision D10 confirmed or changed.

**Decisions to close in M0:** D6 (BLE library), D7 (project generation), D10 (routing provider), D11 (local model).

---

## M1 — Foundations

Goal: the repo has its real projects and contracts; nothing smart yet.

- Create Nx projects: `ui-schema`, `persona`, `lotti-kit` (Swift), `ios`, `simulator` `shared`
- Write UI schema v1 (templates, priority, actions, intents) + JSON fixtures as contract tests `shared` `design`
- Lotti persona + system prompt v1 `design`
- Swift mirror of the schema, tested against the shared fixtures `ios`
- iOS app shell: onboarding, permissions (Bluetooth, mic, location, notifications), settings `ios`
- CI: fix the Nx-generated workflow (pnpm, no Nx Cloud); TypeScript checks on Linux, Swift build/test on macOS `docs`

---

## M2 — Glasses UI loop (no AI)

Goal: hand-written screens render on the glasses and the ring drives them.

- Renderer: schema screen → G2 containers, with pagination and focus `ios`
- Gesture mapping: ring/touchpad → current screen's actions; global back/dismiss `ios`
- Screen stack and priority rules (ambient vs normal vs interrupt, TTL) `ios`
- Web simulator: render fixtures at 576×288, keyboard as ring `shared`
- Head-up / dashboard behavior for ambient screens `ios` `design`

_Done when:_ all fixtures look right on the glasses and in the simulator, and every gesture works.

---

## M3 — Navigation (port from the Even app)

Goal: replace Even's turn-by-turn so you never need to switch back to the Even app for it.

- Route search and start from the phone: search field, share sheet ("Share location → Lotti"), favorites (home, work) `ios` `navigation`
- Routing via MapKit: walking, cycling, driving; transit as overview only `ios` `navigation`
- Guidance engine: step tracking, distance-based announcements, off-route detection, rerouting `ios` `navigation`
- `nav` screen: arrow, distance, street, ETA; ambient while walking, interrupt just before a turn `ios` `design` `navigation`
- Heading: arrow relative to your facing direction (phone compass, glasses IMU if S8 says it works) `ios` `navigation`
- Ring controls during navigation: next/previous step, overview, stop `ios` `navigation`
- Battery mode: lower location accuracy on long straight sections `ios` `navigation`

_Done when:_ walk, bike and drive routes in your city are guided on the glasses as well as the Even app does it.

---

## M4 — Voice

- Push-to-talk on long press → on-device speech-to-text → transcript `ios` `voice`
- Dictation screen (`stream` template) with live text, confirm/cancel by ring `ios` `voice`
- German + English, auto-detect or setting `ios` `voice`
- (if S4 passed) "Hey Lotti" wake word, with a battery-saver toggle `ios` `voice`

---

## M5 — On-device brain

- Brain router: rules → on-device → Hermes connector, with a visible reason for each decision `ios` `brain`
- On-device screen generation with guided generation `ios` `brain`
- Phone tools for the model: time, timer, reminder, calendar, contacts, location, **start navigation** `ios` `brain`
- Prompt and eval harness: replay recorded events against the brain, score results; builds on `packages/brain-eval` from S3 `shared` `brain`

_Done when:_ "Hey Lotti, when's my next meeting?" and "Hey Lotti, walk me home" work offline, first screen in under 1.5 s.

---

## M6 — Messaging & phone signals

Messengers: **iMessage, WhatsApp, Signal, Telegram, Matrix.**

- Notification forwarding (EU) → triage → show or ignore `ios` `messaging`
- Summaries in Lotti's voice instead of raw notifications; "Original" on request `ios` `messaging` `brain`
- Replies as proposals: Lotti writes in your own style, shows the exact words, you approve (Send / Change / Cancel); sent back via AccessoryNotifications `ios` `messaging`
- Per-messenger handling from the S5 table (what's visible, what reply options exist) `ios` `messaging`
- Memory: who matters and when, what you ignore, your writing style per person, places; learned from your behaviour and from what you tell her; "what do you know about…" / "forget that" / "why did you show me this?" `ios` `brain`
- Short per-chat memory from earlier notifications, so replies have some context `ios` `messaging` `brain`
- New messages by voice ("tell Mara I'm late"): compose sheet / Shortcuts / URL schemes, with a phone tap to confirm `ios` `messaging`
- Location: significant changes, arrived/left places, as context only `ios`
- Quiet rules: focus modes, navigation active, meetings; everything else is learned by memory `ios` `design`
- Memory & log screen on the phone: what Lotti remembers, showed or held back and why `ios`

_Done when:_ answering a message in any of the five messengers takes one glance and one or two ring gestures.

---

## M7 — Hermes connector

- Settings: Hermes endpoint, API key (Keychain), connection test `ios` `brain`
- Connector: send persona + screen schema + event, receive screens or text, with streaming `ios` `brain`
- Escalation from the router, with a progress screen on the glasses; ring "back" cancels `ios` `brain`
- Offline / unreachable handling: clear toast, fall back to on-device `ios` `brain`
- Privacy: which phone data may be sent to Hermes, per source (notifications, location, calendar) `design`

_Done when:_ "Hey Lotti, dig into…" goes to Hermes and the answer shows up on the glasses as a proper screen.

---

## Later / ideas

- Full Telegram (TDLib) and Matrix API integrations: history, hands-free sending
- Relay server so Hermes can push to the glasses unprompted (decision D8)
- Mini map image on the `nav` screen; offline routing (Valhalla)
- Live captions and translation (`stream` template)
- Proactive briefings: morning, before meetings, on arrival
- Teleprompter / notes mode
- Health data from the R1 ring
- iOS 27 Private Cloud Compute as a middle brain tier (bigger Apple model, free for small apps, not offline)
- Publish parts (BLE layer, renderer) as open source

## Open questions

- Besides navigation, are there other Even app features you'd miss while Lotti is connected (Conversate, translate, teleprompter)?
- Should Lotti have a "personality slider" (more raccoon vs more neutral)?
