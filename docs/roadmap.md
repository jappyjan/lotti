# Lotti — Roadmap

**MVP first.** Build the smallest Lotti that's useful every day, wear it, then fix and add what real use asks for.

- A spike happens only when a feature can't be built without the answer, and it stays a quick yes/no check. No exhaustive measuring up front.
- Hand-written code before frameworks: no shared schema, simulator or generic renderer until the hand-coded version hurts.
- Out of scope always: setting up, configuring or adding tools to Hermes. Lotti only connects to an existing Hermes.

Labels: `spike`, `ios`, `shared`, `design`, `docs`, plus feature labels `navigation`, `messaging`, `voice`, `brain`.

---

## Done

- **S1 — G2 over BLE** ([write-up](spikes/s1-ble.md)): connect, auth, text on the glasses. D6 (own BLE layer) and D7 (plain Xcode project) decided.
- **S2 — Ring and touchpad input** ([write-up](spikes/s2-ring.md)): ring gestures arrive through the glasses link.
- **S3 — On-device brain** ([write-up](spikes/s3-brain.md)): Apple's on-device model for every task (D11). Eval set and runner in `packages/brain-eval`.

- **Phone tools, Hermes and a better on-device brain** (2026-11-01, pulled forward from After the MVP, PR #8):
  - **Phone tools** for both brains: calendar, weather, location, directions (MapKit), reminders; timer (AlarmKit) and new reminder as tap-to-confirm actions. See [architecture.md](architecture.md#phone-tools).
  - **Hermes connector** with Lotti's reply format, which lets Hermes call several phone tools at once. Tried with the real Hermes over Tailscale: answers in 2–4 s.
  - **On-device brain rebuilt as a pipeline of small steps** (rules → choose → fill in → tools → answer) after the single-session version made things up. No fixed facts in any prompt. See [architecture.md](architecture.md#on-device-brain-a-pipeline-of-small-steps).
  - **Talk gesture with the display off:** double tap, then hold within 3 s. Hold alone still talks while something is shown.
  - **`Documents/lotti.log`** on the phone, readable with `devicectl`, for checking runs afterwards.
  - Known gaps: the model chooser sometimes picks an unrelated tool when no rule matches; an occasional invented detail; the phone's iOS 27 model is only checked in real use (the eval runs on the Mac's model).

---

## MVP — "Talk to Lotti"

Goal: phone in the pocket, glasses on. Look up or tap and Lotti tells you about your day; hold and ask her anything; answer her choices with the ring. No notifications yet: `AccessoryNotifications` needs entitlements a free developer account can't get (checked 2026-11-01, see below).

In this order:

1. **Screen and gestures** `ios`: one hand-coded screen: Lotti's sentence on the left, choices in the rail on the right. Scroll moves the highlight, tap picks, double tap goes back or turns the display off, long press is talk (only). The rail is reusable for the Actions list later.
2. **Today view** `ios` `design`: the look-up view. Time, date, your next appointments and the weather, as one sentence from Lotti plus dim details. Opens on a tap when the display is off, or when you look up (head-up from the glasses' IMU, if the firmware sends it).
3. **Chat** `ios` `brain`: Apple's on-device model as Lotti, with S3's persona. A conversation keeps context until you dismiss it. Answers are one or two sentences plus up to three follow-ups in the rail. Simple tools: today's calendar, weather, time. Prewarmed, with a timeout (S3 saw rare 20–60 s stalls).
4. **Voice** `ios` `voice`: hold to talk, the glasses' mic (LC3), on-device speech-to-text (`SpeechAnalyzer`), your words shown while you hold (Listening), then Lotti answers. Phone mic as fallback if the glasses' mic doesn't work.
5. **Keeps running** `ios`: stays connected with the phone locked (Bluetooth background mode) and reconnects on its own.
6. **Basics** `ios`: a status screen on the phone. Nothing more.

Not in the MVP: notifications and messaging, navigation (keep using the Even app for it), wake word, Hermes, memory and learning, the web simulator, the shared UI schema, CI.

_Done when:_ you wear Lotti for a normal day and use the today view and chat from the glasses.

**Notifications (moved out of the MVP):** `AccessoryNotifications` needs three app extensions with the entitlements `accessory-data-provider`, `accessory-transport-security` and `accessory-transport-extension`. Apple's list of capabilities for the Personal Team doesn't include them, and signing fails. With a paid account: try again, then build triage, summaries and replies (the old MVP plan) on top of the screen and chat.

---

## After the MVP

Rough order, to be re-sorted by what real use shows:

1. **Actions without voice** `ios` `design`: a tap on the today view opens a ring-driven list of common actions (timer, navigate home, quiet for an hour, read the last answer again). See [design.md](design.md#without-voice).
2. **Messages** `messaging` (needs a paid developer account): notifications in through `AccessoryNotifications`, triage, one-sentence summaries, suggested replies with a Proposal, more replies behind "Change".
3. **Navigation** `navigation`: drive the G2's built-in navigation screen (quick check of BLE sid `0x08` first, was S8), MapKit routes, step tracking, rerouting. Replaces the last reason to open the Even app.
4. **Memory** `brain`: who matters, what you ignore, your writing style per person; "why did you show me this?"
5. **Structure when it hurts** `shared`: UI schema, renderer, web simulator, CI fix (CI looks for an npm/yarn lock file but the repo uses pnpm; fails on `main` too), prompt and eval harness on top of `packages/brain-eval`.
6. **Wake word** `voice` (was S4): only if push-to-talk feels limiting.
7. **Battery and background measurements** (was S7, plus S3's leftovers): only when something drains or gets killed.

## Later / ideas

Ideas that are wanted soon but not picked yet live in [ideas.md](ideas.md); they move up here when we take one on.

- Full Telegram (TDLib) and Matrix API integrations: history, hands-free sending
- Relay server so Hermes can push to the glasses unprompted (decision D8)
- Mini map image on the navigation screen; offline routing (Valhalla)
- Live captions and translation
- Media controls from the ring. iOS has no public way for an app to control other apps' playback (iOS 27's `NowPlaying` covers only the app's own media; no EU accessory feature for media; the G2 firmware has no media service). Possible: Apple Music (`MPMusicPlayerController.systemMusicPlayer`), Spotify (App Remote SDK), and play/pause for any app by briefly taking the audio session. Shortcuts can't be run from the background. See design.md, Media
- Proactive briefings: morning, before meetings, on arrival
- Teleprompter / notes mode
- Health data from the R1 ring
- iOS 27 Private Cloud Compute as a middle brain tier (bigger Apple model, not offline, needs a paid developer account)
- Publish parts (BLE layer, renderer) as open source

## Open questions

- Paid Apple developer account: needed for `AccessoryNotifications` (notifications and replies) and Private Cloud Compute, and to avoid reinstalling every 7 days.
- Besides navigation, are there other Even app features you'd miss while Lotti is connected (Conversate, translate, teleprompter)?
- Should Lotti have a "personality slider" (more raccoon vs more neutral)?
