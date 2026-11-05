# Lotti — Design language

Status: agreed direction after four prototype rounds. This describes the experience only, not how it's built.

## Core idea: everything is a conversation with Lotti

1. **Only Lotti speaks.** Messages and notifications never appear as they arrive. Lotti keeps what doesn't matter quiet and tells you the rest in one sentence, in her own voice.
2. **You only talk to Lotti.** Hold and say anything: "tell Mara I'm late", "what did she write exactly?", "walk me there". Lotti works out what to do. Or say nothing: everything you do often also works with the ring alone (see [Without voice](#without-voice)).
3. **Lotti proposes, you approve.** Anything that affects other people (sending a message, moving a meeting) is shown as exactly what Lotti wants to do and waits for your OK. Nothing goes out without it.
4. **The original is one question away.** Every summary has "Original" in its choices, or you just ask.
5. **Lotti learns.** She remembers who matters, what you ignore, how you write, and gets quieter and more accurate over time.

## The display

The glasses show a 576×288 green, see-through display. Black is invisible; only lit pixels are seen.

- **Light means attention.** The display stays dark unless something is worth seeing.
- **Two text sizes.** Regular for everything; big only for numbers read at a glance (time, distance). The firmware font has one size, so big numbers are drawn as pictures (the clock on the look-up view).
- **Brightness sets importance.** Bright = new or highlighted; dim = context.
- **Three things max:** what Lotti says (one or two sentences), optional context, and your choices.
- **Text first, pictures where they beat words:** Lotti's raccoon mask, maps, and small line icons that are read faster than a word — weather, a timer dial that empties as time runs out, the calendar, a bell for a ringing timer, a check for "done", a labelled bar for each day's low to high. One weight (2 px lines), 32 px, drawn as 1-bit images (`LensArt`).
- **Calm.** Screens change in place. Nothing slides, blinks or bounces.
- **Hints fade away.** Gesture hints show while you're learning, then disappear.

## Screen anatomy

```
┌───────────────────────────────────┐
│ (mask) Mara asks if you're still  │
│        coming at 8. They're       │
│        ordering pizza.            │
│                                   │
│ > On my way                       │ ← highlighted = best guess
│   Running late                    │
│   Original                        │
└───────────────────────────────────┘
  Lotti's sentence (top, full width)  choices (below, one per line)
```

- **Lotti's line:** the raccoon mask followed by her sentence. The mask marks "this is Lotti talking".
- **The choices:** in one block under the sentence, one per line, up to 4. The highlight starts on Lotti's best guess. Each item is a shortcut for something you could also say. The sentence gets 6 of the 10 lines, so it only works with short sentences; without choices the sentence uses the full height.
- **Originals** are shown without the mask, word for word, with the sender and time in dim text above.

### The rail is too narrow

In use the choices on the right were too small and too short: the rail got 176 of 576 px, about 13 characters a line, so a real suggestion ("Running late, order me a margherita") arrived as two clipped words.

**Decided 2026-11-01 by wearing all three built variants: choices below the sentence** — the sentence gets the full 576 px, the choices sit in one block underneath, one per line, highlighted as today. Costs 3–4 of the 10 lines, so it only works with short sentences. The side rail and the wider rail are removed: choices below is the only layout.

**Preferred long-term: choices in a popup on the second display layer** — the sentence alone on the content layer; the choices appear on the layer above on a scroll or tap and vanish when you pick one. This is how the Even app does it: two layers, content below, popups above. The menu widget's content command is mapped (`g2.menu` `APP_SEND_MENU_INFO`, selectable items, picks back over EvenHub Cmd 0x15), but the menu is opened by the firmware, not the app — there is no known app-side "open popup" command. A live BLE capture with the Even app is the next step to find one (see [apk-recon](spikes/apk-recon.md), [D12](architecture.md#decisions)). "Two steps" (best guess + "More" → full list on the popup layer) rides along.

## Gestures

The same on the R1 ring and both temple touchpads.

| Gesture           | Meaning everywhere                                                                                                                                                                            |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scroll / swipe    | Move the highlight in the choices; in a list, move between items                                                                                                                              |
| Tap               | Do the highlighted thing. On its own (display off) it does nothing                                                                                                                            |
| Double tap        | Back or dismiss. With the display off: the today view (also by looking up, if head-up is on). While a catch-up brief from the last 12 h exists, Today has a "Catch-up" choice that shows it again |
| Long press (hold) | Talk to Lotti while held. She knows what you're looking at ("tell her…" means the sender). With the display off: double tap (today opens), then hold, so a stray hold doesn't start listening |
| "Hey Lotti"       | Not a gesture, but the same as a hold, from any state (display off, phone locked): Listening starts by itself and ends after 1.5 s of quiet; nothing said in 5 s, the display goes dark. Double tap cancels |
| Look up           | The look-up view; look down to hide it                                                                                                                                                        |

## Without voice

Often you can't speak: in a meeting, on a full train, somewhere loud. Voice is a shortcut, never the only way.

- **Answering:** pick one of Lotti's suggested replies. "Change" in a Proposal offers more ready-made replies (the ones you use most with this person) instead of dictation. Free text means taking out the phone.
- **Starting something:** tap on the look-up view opens **Actions**, a List of things to do, with what you most likely need right now first: reply to the last message, media, timer (5 / 10 / 25 min), navigate home or to a favourite place, quiet for an hour, read the last summary again (later also media).
- **Rule:** every voice command people use often gets an entry in Actions.

## Media

Not planned yet (see roadmap, Later): iOS only allows full control of Apple Music and Spotify, and play/pause for other apps.

- **Now playing** is a quiet line in the look-up view while something plays.
- Actions → **Media** opens a Card: title and artist, with Play/Pause, Next, Previous and Volume as its choices. On Volume, scroll changes the volume.
- Voice works too ("pause", "next song"), but it's never needed.

## How loud a screen is

| Level      | Behaviour                                                      | Examples                                              |
| ---------- | -------------------------------------------------------------- | ----------------------------------------------------- |
| **Quiet**  | Never appears by itself. Only in the look-up view.             | weather, things Lotti held back, low-priority updates |
| **Normal** | Shows for a few seconds, then moves to the look-up view.       | most summaries, answers                               |
| **Urgent** | Stays until you act or dismiss it. Rare; Lotti has to earn it. | turn coming up, a call, someone Lotti knows matters   |

Who and what counts as urgent is not a setting. Lotti learns it (see Memory).

## Building blocks

Lotti composes every screen from these. Layout always comes from the design language.

| Block          | What it shows                                                                                     |
| -------------- | ------------------------------------------------------------------------------------------------- |
| **Lotti says** | Her sentence, optionally with choices below it. Summaries, answers, suggestions                   |
| **Proposal**   | Exactly what Lotti wants to do ("I'll tell Mara: …"), with **Send / Change / Cancel** as choices  |
| **Original**   | The source word for word: a message, a mail, a notification                                       |
| **List**       | Pick one of many: places, people, the rest of today. One line each                                |
| **Reading**    | A longer answer, page by page ("Read on" as a choice)                                             |
| **Working**    | Lotti is on it, and says what she's doing ("Sniffing around… checking the BVG"). Double tap stops |
| **Listening**  | Your words appearing as you speak, while you hold (or, after "Hey Lotti", until you go quiet for 1.5 s) |
| **Card**       | A few facts at a glance (label + value), optionally one big number                                |
| **Done**       | One line that disappears after 2 s ("Told Mara.")                                                 |

Every screen also has: how loud it is, how long it stays, and which choice is Lotti's best guess.

## Key flows

**You put the glasses on**

1. The glasses tell us they're being worn. The IMU is already read for head-up, so the signal exists.
2. Lotti greets with one sentence: what happened while they were off, and what's next ("Two things: Mara asked about 8, and the dentist is in 40 min. Rain later.").
3. Choices only when they help: the first thing, or Navigate. Otherwise no choices.
4. Nothing happened and nothing is due: no greeting, the display stays dark.

**A message comes in**

1. Lotti decides: quiet, normal or urgent. Most things stay quiet.
2. If shown: one sentence in Lotti's voice, choices below it (likely replies + "Original").
3. Several things at once become one summary, with the one that needs you first ("3 new: … Mara first?").

**You reply**

1. Tap a suggested reply, or hold and say what you want ("tell her ten minutes late, and I want a margherita").
2. Lotti shows a **Proposal** with the exact words, written in your own style: "I'll tell Mara: …" with Send / Change / Cancel.
3. Tap Send → "Told Mara." The answer comes back later as part of the same conversation.

**Lotti suggests something**
Always as a question with choices ("Ben moved your 15:00 to 15:30. Push your 15:45 with Lea too?"). Approving leads to a Proposal if it affects other people.

## Look-up view

What you see when you look up: **one thing**. Lotti picks the single most useful sentence right now.

```
┌───────────────────────────────────────────────┐
│ Thu 5 Nov                               14:05 │ header: date, clock
│ Dentist in 25 min.                            │ the one thing
│                                               │
│ +2 more today                                 │
│ Pasta                 9° cloudy               │ cards: running timers,
│ 4 min left            6° / 11°                │ weather, what's later
│ Rings 14:09           Rain from 18:00         │
│ > Agenda                                      │ choices, as many lines
│   Weather                                     │ as there are
└───────────────────────────────────────────────┘
```

- **Header:** date on the left, time on the right.
- **Cards** under the sentence, two side by side: running timers first, then the weather, then what's later today if there's room. They update when the minute changes.
- **Choices** at the bottom, one line each; on this view the block is only as tall as its choices, so the cards get the room.
- **Weather** opens the forecast: today's weather in a sentence, then a column per day for four days: the icon, a bar for the day's range on the scale of the whole week with the low at its left end and the high at its right, and the chance of rain from 20 %. Temperatures always read low to high ("6° / 11°").
- **A ringing timer** takes over the display ("Time's up: Pasta", choice: Stop). Tap or double tap stops it on the phone too, then you're back where you were. It waits while you talk or Lotti thinks.
- Each block is its own text container, each picture its own image container (at most 8 text, 4 image and 12 containers in all per page: the glasses reject a page with a fifth picture). Pictures use brightness 15 of 15, like the text. A small blank text box in the top-right corner takes the touch events: the firmware scrolls and bounces whichever container takes them, so the sentence and choices stay still and Lotti moves the highlight. The firmware's own list container was tried (2026-11-05) and dropped: its selection border looked out of place next to the text.

- **Something matters:** "Leave in 8 min for pizza at Mara's. Rain at 21:00, take the umbrella." Time and "2 more" in dim text below.
- **Nothing matters:** "All quiet. Nothing needs you." Time, date, temperature below.
- **Tap:** Actions (see [Without voice](#without-voice)).
- **Scroll:** the rest, in order, as a List. The last item says what Lotti held back ("I kept 14 things quiet, mostly newsletters").
- **While navigating:** the one thing, plus the next turn pinned at the bottom.

## Navigation

Uses the glasses' own navigation screen, the same as the Even app: turn arrow, distance, street, time left and a small map, plus a full map with a tap. Lotti starts it ("walk me there"), changes it ("add a stop at the Späti") and talks about it in the look-up view, but doesn't redesign it.

## Memory: how Lotti learns

Lotti keeps memories, and you can always ask about them.

- **What she remembers:**
  - who matters to you and when (Mum always, work chats not after 19:00)
  - what you ignore
  - how you write to each person
  - places (home, Mara's)
  - preferences you said out loud
- **How she learns:**
  - from what you open, answer, dismiss or ignore
  - from things you tell her ("always let Mum through", "never bother me with the volleyball group")
  - now and then she asks: "Mum wrote three times today. Should she always come through?" (Yes / No / Only urgent)
- **Staying in control:**
  - "What do you know about Mara?"
  - "Forget that."
  - "Why did you show me this?" Lotti always has an answer.

## Lotti's voice

- **When Lotti talks to you:** brief, warm, a bit curious. A little raccoon flavour ("Sniffing around…", "Found it"), but never at the cost of clarity.
- **When Lotti writes for you:** your own style, per person, learned from how you write. Never raccoon flavour. People shouldn't be able to tell.

## Phone app

**AI-first:** the app opens to a chat with Lotti, like the ChatGPT or Claude apps: text input, a hold-to-talk mic, streamed status lines, answers, follow-up chips, action buttons (tap = approve, Undo where available), and inline inbox items and catch-up briefs. Questions asked on the glasses appear in the same conversation; a list holds past conversations. Settings sit behind a gear. Plain native iOS look: standard grouped lists and controls, one accent colour (the same green).

### Attention and location indicators (glasses)

Incoming things never appear as full notifications. A **small image indicator** at an edge of the view shows a kind icon (mail, calendar, job, reminder, info) plus a count, and stays in the display-off state. It never covers Lotti's sentence or choices and never opens by itself. The today view gives a one-line summary ("2 Mails, Termin in 10 min") and a choice for the full list; each item opens in full with Dismiss and its actions. A second small icon, a location pin, shows while the phone's location is read and briefly after. Icons are images (EvenHub image containers), not letters.

### Catch-up brief

To open **Today** with the display off: double tap, or look up (if head-up is switched on). A brief from the last 12 hours stays reachable there as the "Catch-up" choice.

When Jan comes back after sleep or ≥ 2 h away, putting the glasses on (or opening the app first) gives one short catch-up: what happened, what is next, anything weather-relevant. Nothing relevant means nothing shown. Once per return.

- **Setup:** pair glasses and ring
- **Status:** connected, batteries
- **Settings:** a grouped page for everything: Lotti Brain, providers, accounts, MCP servers, jobs, memory, skills and scripts, inbox and catch-up, glasses, phone tools, privacy, push, debug
- **Memory & log:** what Lotti remembers, what she showed or held back and why. Read and delete only; teaching happens by talking to her.

## Mascot

A small raccoon in the phone app that wears glasses when yours are on. Purely cosmetic: it carries no information and nothing depends on it.

- **Placement:** large (200 pt) and centred above the greeting in the empty-chat state, and as a small 32 pt head-only avatar in the chat header once the conversation has messages. Nowhere else in the app, apart from the Settings > Glasses switch. Never on the glasses.
- **Glasses:** on only while the glasses are connected and reported worn; off when unknown or disconnected. Changes shorter than about 1 s are ignored. The first state shown on appearing is not animated.
- **Head:** while the glasses are worn and the mascot is on screen in the foreground, the raccoon's head follows yours: nod (about ±20°) and tilt (about ±15°), eased between the roughly once-a-second samples. It never turns sideways (see IMU findings).
- **Without a usable IMU** (no samples within 5 s): the head stays neutral, the glasses still follow wear state, one log line, no error.
- **Settings:** a switch in Settings > Glasses turns the mascot off (it then costs no IMU traffic).
- **Art:** drawn by an Opus 5.5 (extra-high effort) subagent and approved by a second, separate Opus 5.5 reviewer after 2 rounds (previews in `docs/mascot/`, preview tool `apps/ios/scripts/render-mascot/`); the drawings live in `apps/ios/Lotti/Mascot/Art/`; logic is in `packages/lotti-kit/Sources/LottiKit/Mascot/` (`MascotController`, `MascotWearMapper`, `HeadAngleMapper`). To change the look, replace the art; the logic doesn't care.

### IMU findings

- **Source:** `G2Event.imu(x:y:z:)`, a gravity-normalised vector (|v| about 1 at rest) from the Sys event type 8 (`IMU_Report_Data {1 x, 2 y, 3 z}`, 32-bit floats). There is **no gyroscope, magnetometer or heading field** in what the app decodes, so **yaw is not observable**: gravity doesn't change when you turn your head. The mascot's yaw stays 0.
- **Axes:** the x axis tilts with the head (`HeadUpDetector`, calibrated on a worn G2): nod = asin(x / |v|), positive looking up, straight ahead reads about 0 to 25° (`HeadUpSettings.straightAhead` is the neutral). Tilt is atan2(lateral, vertical) in the remaining axes; which of y/z is lateral, and the sign, are **unverified on hardware** (defaults y lateral, z vertical, configurable in `HeadAngleMapper.Config`). When x dominates (looking straight up or down) tilt is held.
- **Rate:** the app asks for pace code 200, but the G2 sends about one sample per second (comment in `HeadUpDetector`). Hence the targets are smoothed (low-pass, dead zone 2°) and the view eases over about one sample interval (`animationDuration`, measured, 0.2 to 1.5 s).
- **Arming:** reporting only works with a live EvenHub page (a dark one is shown if none exists) and is re-armed after every page rebuild and reconnect. Field 20 is tried first, then 22.
- **Battery and traffic:** the feed is requested only while someone needs it. `IMUDemand` is reference-counted: head-up detection and the mascot each hold a token; the glasses get "on" for the first and "off" after the last release. A second user adds no link traffic, and one turning off never cuts the other. The mascot holds its token only while visible in the foreground and worn. Head-up gestures are ignored in the Conductor while head-up is switched off, even if the mascot keeps the feed on.

## Open questions

- Should approval ever relax later (e.g. Lotti may send "on my way" to Mara without asking once she's proven herself)? For now: always approve.
- Should Lotti answer out loud through the phone or earbuds, or only on the display?
