# Lotti — Vision & Goals

## One line

Lotti is a curious raccoon who lives in your Even G2 glasses: an AI-first assistant that decides what deserves your attention and shows it in a glance. You control it with the R1 ring, the temple touchpads or your voice ("Hey Lotti").

## Why

The stock Even app works like a phone squeezed onto glasses: menus, apps, features. Most interactions are slower than pulling out the phone, and you can't act on notifications at all. Lotti flips this:

- **The AI chooses what to show.** There are no fixed apps. The agent gets context (speech, notifications, location, time, calendar) and builds a small UI for the task at hand.
- **One gesture beats five taps.** The most likely action is always one ring tap away.
- **Everything is a conversation with Lotti.** She summarises what comes in, you talk back, she proposes what to do and you approve. See [design.md](design.md).
- **Mostly silent.** Most notifications and location updates should produce nothing on the display. Lotti only interrupts when you'd thank it for doing so.

## Persona

- **Name:** Lotti, from the raccoon's scientific name _Procyon lotor_, "the washer".
- **Character:** curious, warm, a bit mischievous. Digs through your world to find the one shiny thing that matters right now.
- **Voice:** brief, because the display is tiny and in front of your eyes. Honest when it doesn't know. A little raccoon flavor ("sniffing around…", "found it"), but never at the cost of clarity.
- **Wake word:** "Hey Lotti". The "Hey" prefix lowers false wake-ups from words like "a lotta".
- **Repo / product name:** `lotti`

## Goals

1. **Glanceable AI UI.** The agent outputs a screen description in a schema. The phone renders it to the G2's 576×288 monochrome display.
2. **Input that feels native.** Ring and touchpad gestures (tap, double tap, long press, scroll) map to the actions on the current screen.
3. **Voice.** Push-to-talk (long press) and dictation in v1. "Hey Lotti" wake word if the battery cost is acceptable.
4. **Phone as sensor hub.** Forward notifications, location and device state to the brain. The brain decides what to do with them.
5. **Act on things.** Reply to messages (iMessage, WhatsApp, Signal, Telegram, Matrix), set reminders, hand bigger tasks to Hermes.
6. **Navigation.** Turn-by-turn on the glasses, replacing the Even app's navigation.
7. **On-device first.** Fast, offline, private by default. Escalate to your existing Hermes only when the task needs it.

## Non-goals (for now)

- Publishing on the App Store or Even Hub. This is a personal tool first.
- Android. iPhone only.
- Supporting other glasses. The G2 + R1 are the target. Keep the glasses link behind an interface so others could be added later.
- Camera features. The G2 has no camera.
- Setting up or configuring Hermes (models, tools, memory). Lotti only connects to an existing Hermes.

## Success criteria

- Answering a message in any of the five messengers takes **one glance and one or two ring gestures**, faster than reaching for the phone.
- A typical day of notifications produces **few, useful** screens. Track the shown-vs-ignored ratio and how often you dismiss.
- Navigation works as well as the Even app's, so there's no reason to switch back.
- Push-to-talk → first screen in **< 1.5 s** on-device, **< 4 s** via Hermes.
- Battery: glasses and phone together last a full workday with Lotti running.

## Constraints

- **Hardware:** G2 display is 576×288, monochrome green. The official SDK allows up to 12 containers per page and one container that takes input. Raw BLE may allow more; see spike S1. The firmware's service table confirms a second layer above the content for popups, and the spawn command is mapped (EvenHub Cmd 17, `MenuStartUpEvent{widgetId}`); open is the foreground-notification content command ([D12](architecture.md#decisions), [apk-recon](spikes/apk-recon.md)).
- **Protocol:** we use the community reverse-engineered BLE protocol. Firmware updates can break it.
- **Exclusive connection:** while Lotti is connected, the Even app can't use the glasses.
- **iOS notification replies:** only in the EU, via `AccessoryNotifications` (iOS 26.3+), with one forwarding device at a time. Turning it on disables notifications on Apple Watch.
- **No custom wake word API on iOS:** we need our own keyword spotter on the glasses mic stream.
