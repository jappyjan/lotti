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

---

## MVP — "Lotti tells you your messages"

Goal: phone in the pocket, glasses on. Messages from the five messengers (iMessage, WhatsApp, Signal, Telegram, Matrix) show up as one sentence from Lotti, unimportant ones stay quiet, and the ring sends a suggested reply.

In this order:

1. **Notifications in** `ios` `messaging` (was spike S5, now a quick check first): receive forwarded notifications with `AccessoryNotifications` (EU, iOS 26.3+). Does it work on the free developer account, or does it need an entitlement only a paid account gets? Check that first; the MVP depends on it. Then find which messengers offer a reply.
2. **Brain** `ios` `brain`: Apple's on-device model with S3's prompts. Triage (quiet / normal / urgent), a one-sentence summary, and up to three reply choices. Muted apps and senders are plain rules.
3. **Glasses screen** `ios`: one hand-coded "Lotti says" screen, with the sentence on the left and the choices plus "Original" in the rail on the right. Scroll moves the highlight, tap picks, double tap dismisses (ring and touchpads).
4. **Reply** `ios` `messaging`: picking a choice shows a Proposal ("I'll tell Mara: On my way"), Send replies through `AccessoryNotifications`, then a short "Done" line.
5. **Keeps running** `ios`: stays connected with the phone locked (Bluetooth background mode) and reconnects on its own. Fix what breaks while wearing it.
6. **Basics** `ios`: a status screen and a list of muted apps on the phone. Nothing more.

Not in the MVP: navigation (keep using the Even app for it), voice, wake word, Hermes, memory and learning, the web simulator, the shared UI schema, CI.

_Done when:_ you wear Lotti for a normal day and answer messages from the glasses.

---

## After the MVP

Rough order, to be re-sorted by what real use shows:

1. **Look-up view and actions without voice** `ios` `design`: the one most useful sentence when you look up; tap opens a ring-driven list of common actions (reply to the last message, timer, navigate home, quiet for an hour). More ready-made replies behind "Change". See [design.md](design.md#without-voice).
2. **Navigation** `navigation`: drive the G2's built-in navigation screen (quick check of BLE sid `0x08` first, was S8), MapKit routes, step tracking, rerouting. Replaces the last reason to open the Even app.
3. **Push-to-talk** `voice`: hold to talk, glasses mic, on-device speech-to-text, "tell Mara I'm late".
4. **Memory** `brain`: who matters, what you ignore, your writing style per person; "why did you show me this?"
5. **Hermes connector** `brain` (was S6): escalate "dig into…" requests to your existing Hermes.
6. **Structure when it hurts** `shared`: UI schema, renderer, web simulator, CI fix, prompt and eval harness on top of `packages/brain-eval`.
7. **Wake word** `voice` (was S4): only if push-to-talk feels limiting.
8. **Battery and background measurements** (was S7, plus S3's leftovers): only when something drains or gets killed. The S3 eval screen already has `--soak` and `--background` runs.

## Later / ideas

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

- Paid Apple developer account: needed if `AccessoryNotifications` (MVP step 1) or Private Cloud Compute require managed entitlements, and to avoid reinstalling every 7 days.
- Besides navigation, are there other Even app features you'd miss while Lotti is connected (Conversate, translate, teleprompter)?
- Should Lotti have a "personality slider" (more raccoon vs more neutral)?
