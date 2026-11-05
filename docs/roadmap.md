# Lotti — Roadmap

**MVP first.** Build the smallest Lotti that's useful every day, wear it, then fix and add what real use asks for.

- A spike happens only when a feature can't be built without the answer, and it stays a quick yes/no check. No exhaustive measuring up front.
- Hand-written code before frameworks: no shared schema, simulator or generic renderer until the hand-coded version hurts.
- Hermes is gone: Lotti has its own backend, Lotti Brain (D13).
- Product rule: a thing does not exist until the app can configure and manage it.

Labels: `spike`, `ios`, `shared`, `design`, `docs`, plus feature labels `navigation`, `messaging`, `voice`, `brain`.

---

## Done

- **S1 — G2 over BLE** ([write-up](spikes/s1-ble.md)): connect, auth, text on the glasses. D6 (own BLE layer) and D7 (plain Xcode project) decided.
- **S2 — Ring and touchpad input** ([write-up](spikes/s2-ring.md)): ring gestures arrive through the glasses link.
- **S3 — On-device brain** ([write-up](spikes/s3-brain.md)): Apple's on-device model for every task (D11). Eval set and runner in `packages/brain-eval`.

- **Phone tools, Hermes and a better on-device brain** (2026-11-01, pulled forward from After the MVP, PR #8):
  - **Phone tools** for both brains: calendar, weather, location, reminders; timer (AlarmKit), new reminder and start-navigation as tap-to-confirm actions. See [architecture.md](architecture.md#phone-tools).
  - **Hermes connector** with Lotti's reply format, which lets Hermes call several phone tools at once. Tried with the real Hermes over Tailscale: answers in 2–4 s.
  - **On-device brain rebuilt as a pipeline of small steps** (rules → choose → fill in → tools → answer) after the single-session version made things up. No fixed facts in any prompt. See [architecture.md](architecture.md#on-device-brain-a-pipeline-of-small-steps).
  - **Talk gesture with the display off:** double tap (today opens), then hold. Hold alone still talks while something is shown.
  - **Routing**: Hermes first — every question goes to Hermes when it's set up; the on-device brain answers only when Hermes isn't set up (D2 flipped 2026-11-02). The Hermes timeout counts silence, not total time: any traffic (tokens, keepalives, tool progress) restarts the clock, and Hermes's own tool steps are logged, not shown on the glasses.
  - **`Documents/lotti.log`** on the phone, readable with `devicectl`, for checking runs afterwards.
  - Known gaps: the model chooser sometimes picks an unrelated tool when no rule matches; an occasional invented detail; the phone's iOS 27 model is only checked in real use (the eval runs on the Mac's model).

- **Wake word "Hey Lotti"** (2026-11-03): say it with the glasses on and the phone in your pocket, no gesture. Energy gate, Create ML sound classifier and Apple speech confirm on the shared glasses mic; ends on 1.5 s of quiet. Setting in Settings → Glasses → Voice (default on), Debug section with score and recorder. See [architecture.md](architecture.md#wake-word).
  - Checked on the phone and glasses (2026-11-03): 8 of 10 "Hey Lotti, wie wird das Wetter?" woke Lotti and were answered; about 11 minutes of talk nearby gave one classifier hit (0.82) that the speech confirm rejected, so no false wake. The first, synthetic-only model scored real glasses audio near 0; it was retrained with 30 recorded phrases and ~1.5 min of background.
  - Checked again on the merged build with Lotti Brain (2026-11-05): 4 of 4 wakes confirmed (0.94–1.00) and answered through the backend (timer proposal, weather, time). About 45 minutes of talk and TV nearby gave ~20 classifier hits, all rejected by the speech confirm: no false wake, but many more hits than the first run. The glasses stop the mic stream now and then; the watchdog restarted it each time.
  - Known gaps: few real recordings (more clips from Debug → Record training clips will help); the "phone locked" and background run were seen in the log but not measured over a day; battery is unmeasured (item 8); rejection targets (98%) are just missed on held-out clips (96.9% near misses, 96.8% other speech).
- **Lotti Brain and the AI-first app** (2026-11-03): own backend (`apps/brain`: agent loop, DeepSeek/OpenAI/Anthropic/Codex/Claude providers, MCP client and admin MCP server, dynamic weather, location as a visible tool, calendar, mail, Bring!, shell, conversations, memory and dreaming, jobs, inbox, catch-up, APNs off by default); chat-first phone app with Settings for everything; wear detection and EvenHub image containers; attention and location indicators; Hermes removed. Needs real-device checks: image containers, indicator placement, background WebSocket behaviour.

---

## MVP — "Talk to Lotti"

Goal: phone in the pocket, glasses on. Look up or tap and Lotti tells you about your day; hold and ask her anything; answer her choices with the ring. No notifications yet: `AccessoryNotifications` needs entitlements a free developer account can't get (checked 2026-11-01, see below).

In this order:

1. **Screen and gestures** `ios`: one hand-coded screen: Lotti's sentence on the left, choices in the rail on the right. Scroll moves the highlight, tap picks, double tap goes back or turns the display off, long press is talk (only). The rail is reusable for the Actions list later.
2. **Today view** `ios` `design`: the look-up view. Time, date, your next appointments and the weather, as one sentence from Lotti plus dim details. Opens on a double tap when the display is off, or when you look up (head-up from the glasses' IMU, if the firmware sends it).
3. **Chat** `ios` `brain`: Apple's on-device model as Lotti, with S3's persona. A conversation keeps context until you dismiss it. Answers are one or two sentences plus up to three follow-ups in the rail. Simple tools: today's calendar, weather, time. Prewarmed, with a timeout (S3 saw rare 20–60 s stalls).
4. **Voice** `ios` `voice`: hold to talk, the glasses' mic (LC3), on-device speech-to-text (`SpeechAnalyzer`), your words shown while you hold (Listening), then Lotti answers. Phone mic as fallback if the glasses' mic doesn't work.
5. **Keeps running** `ios`: stays connected with the phone locked (Bluetooth background mode) and reconnects on its own.
6. **Basics** `ios`: a status screen on the phone. Nothing more.

Not in the MVP: notifications and messaging, navigation (keep using the Even app for it), wake word, a backend, memory and learning, the web simulator, the shared UI schema, CI.

_Done when:_ you wear Lotti for a normal day and use the today view and chat from the glasses.

**Notifications (moved out of the MVP):** `AccessoryNotifications` needs three app extensions with the entitlements `accessory-data-provider`, `accessory-transport-security` and `accessory-transport-extension`. Apple's list of capabilities for the Personal Team doesn't include them, and signing fails. With a paid account: try again, then build triage, summaries and replies (the old MVP plan) on top of the screen and chat.

---

## After the MVP

Rough order, to be re-sorted by what real use shows:

1. **Choices and layout** `ios` `design`: **decided: choices below the sentence** (judged wearing, 2026-11-01), now the only layout (side and wide rail removed). **Open: choices in a popup on the second display layer** (preferred long-term) — menu content is mapped but the menu is firmware-opened; needs a live BLE capture to find an on-demand open ([apk-recon](spikes/apk-recon.md), D12). See [design.md](design.md#the-rail-is-too-narrow).
2. **Put it on** `ios` `design` `brain`: **built as the catch-up brief** (wear status asked from the glasses every 10 s on sid `0x10`, since they never report it on their own (capture 2026-11-05), verified on real glasses 2026-11-05, plus away/slept heuristics). When Jan comes back after ≥ 2 h or sleep, one short catch-up. See [design.md](design.md#key-flows).
3. **Actions without voice** `ios` `design`: a tap on the today view opens a ring-driven list of common actions (timer, navigate home, quiet for an hour, read the last answer again). See [design.md](design.md#without-voice).
4. **Messages** `messaging` (needs a paid developer account): notifications in through `AccessoryNotifications`, triage, one-sentence summaries, suggested replies with a Proposal, more replies behind "Change".
5. **Navigation** `navigation`: drive the G2's built-in navigation screen (sid `0x08`, proto already decoded — [apk-recon](spikes/apk-recon.md)), MapKit routes, step tracking, rerouting. Replaces the last reason to open the Even app. **Built: arrow + text** (START, heartbeat, BASIC_INFO cards, rerouting, arrival, walk↔bike switch, exit handling; `NavigationSession` + `StepTracker` in LottiKit, `start_navigation` action in the app) **and map streaming to the Even app's format** (4 bpp BMP road network, LZ4/raw, fragmented `mini_map_msg`/`max_map_msg`; `NavMapBmp` + `NavMapRenderer`). Still open: confirming the maps live on the glasses, drawing the road network (needs a road source — the route alone renders for now), launching from the glasses' menu, the share-sheet entry point.
6. **Memory** `brain`: built in Lotti Brain (auto memory, dreaming). Still open: per-person writing style, "why did you show me this?"
7. **Structure when it hurts** `shared`: UI schema, renderer, web simulator, CI fix (CI looks for an npm/yarn lock file but the repo uses pnpm; fails on `main` too), prompt and eval harness on top of `packages/brain-eval`.
8. **Battery and background measurements** (was S7, plus S3's leftovers): only when something drains or gets killed.

## Later / ideas

- Full Telegram (TDLib) and Matrix API integrations: history, hands-free sending
- Messenger read/write (WhatsApp, Matrix, Signal, Telegram, iMessage) through Lotti Brain (inbox kinds and accounts screen leave room)
- APNs on a real device (built, off until a paid developer account; opt-in build setting)
- Road network on the navigation map (OSM vector tiles or similar); offline routing (Valhalla)
- Live captions and translation
- Media controls from the ring. iOS has no public way for an app to control other apps' playback (iOS 27's `NowPlaying` covers only the app's own media; no EU accessory feature for media; the G2 firmware has no media service). Possible: Apple Music (`MPMusicPlayerController.systemMusicPlayer`), Spotify (App Remote SDK), and play/pause for any app by briefly taking the audio session. Shortcuts can't be run from the background. See design.md, Media
- Proactive briefings: morning, before meetings, on arrival
- Teleprompter / notes mode
- Health data from the R1 ring
- iOS 27 Private Cloud Compute as a middle brain tier (bigger Apple model, not offline, needs a paid developer account)
- Publish parts (BLE layer, renderer) as open source
- Custom firmware: possible today (CRC-only, no signature) and already a community ecosystem — faceclaw, g2flash, openCFW, webflasher, g2emu. See [custom-firmware](spikes/custom-firmware.md).

## Open questions

- Paid Apple developer account: needed for `AccessoryNotifications` (notifications and replies) and Private Cloud Compute, and to avoid reinstalling every 7 days.
- Besides navigation, are there other Even app features you'd miss while Lotti is connected (Conversate, translate, teleprompter)?
- Should Lotti have a "personality slider" (more raccoon vs more neutral)?
