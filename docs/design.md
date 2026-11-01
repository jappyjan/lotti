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
- **Two text sizes.** Regular for everything; big only for numbers read at a glance (time, distance).
- **Brightness sets importance.** Bright = new or highlighted; dim = context.
- **Three things max:** what Lotti says (one or two sentences), optional context, and your choices.
- **Text first.** Pictures only where they beat words: Lotti's raccoon mask and maps.
- **Calm.** Screens change in place. Nothing slides, blinks or bounces.
- **Hints fade away.** Gesture hints show while you're learning, then disappear.

## Screen anatomy

```
┌───────────────────────────────────┬──────────────┐
│                                   │              │
│ (mask) Mara asks if you're still  │ [On my way]  │ ← highlighted = best guess
│        coming at 8. They're       │  Running late│
│        ordering pizza.            │  Original    │
│                                   │              │
└───────────────────────────────────┴──────────────┘
  Lotti's sentence (left)             the rail (right)
```

- **Lotti's line:** the raccoon mask followed by her sentence. The mask marks "this is Lotti talking".
- **The rail:** every screen with choices puts them in a column on the right, up to 4. The highlight starts on Lotti's best guess. Each item is a shortcut for something you could also say.
- **No choices, no rail:** the sentence uses the full width.
- **Originals** are shown without the mask, word for word, with the sender and time in dim text above.

### The rail is too narrow

In use the choices on the right are too small and too short: the rail gets 176 of 576 px, about 13 characters a line, so a real suggestion ("Running late, order me a margherita") arrives as two clipped words. The rail as drawn above is the weakest part of the screen.

Options to test, cheapest first:

1. **Wider rail, fewer choices.** 240 px (~18 characters) with three choices instead of four. The sentence drops to ~26 characters a line instead of 31.
2. **Choices below the sentence.** The sentence gets the full 576 px, the choices sit in one block underneath, one per line, highlighted as today. Costs 3–4 of the 10 lines, so it only works with short sentences.
3. **A popup on a second layer.** The sentence alone on the content layer; the choices appear on the layer above on a scroll or tap and vanish when you pick one. This is how the Even app does it: two layers, content below, popups above. Whether the firmware gives the second layer to us is not known yet ([architecture.md](architecture.md#a-second-layer-for-popups-unverified)).
4. **Two steps.** The rail keeps Lotti's best guess plus "More"; "More" opens the full list on the popup layer.

How to compare: there is no simulator yet, so the hand-coded screen switches between the variants with a debug setting on the phone and we judge them while wearing the glasses. The winner replaces the anatomy above and goes into the renderer.

## Gestures

The same on the R1 ring and both temple touchpads.

| Gesture           | Meaning everywhere                                                                        |
| ----------------- | ----------------------------------------------------------------------------------------- |
| Scroll / swipe    | Move the highlight in the rail; in a list, move between items                             |
| Tap               | Do the highlighted thing. On its own (display off) it does nothing                        |
| Double tap        | Back or dismiss. With the display off: the today view                                     |
| Long press (hold) | Talk to Lotti while held. She knows what you're looking at ("tell her…" means the sender). With the display off: double tap (today opens), then hold, so a stray hold doesn't start listening |
| Look up           | The look-up view; look down to hide it                                                    |

## Without voice

Often you can't speak: in a meeting, on a full train, somewhere loud. Voice is a shortcut, never the only way.

- **Answering:** pick one of Lotti's suggested replies. "Change" in a Proposal offers more ready-made replies (the ones you use most with this person) instead of dictation. Free text means taking out the phone.
- **Starting something:** tap on the look-up view opens **Actions**, a List of things to do, with what you most likely need right now first: reply to the last message, media, timer (5 / 10 / 25 min), navigate home or to a favourite place, quiet for an hour, read the last summary again (later also media).
- **Rule:** every voice command people use often gets an entry in Actions.

## Media

Not planned yet (see roadmap, Later): iOS only allows full control of Apple Music and Spotify, and play/pause for other apps.

- **Now playing** is a quiet line in the look-up view while something plays.
- Actions → **Media** opens a Card: title and artist, with Play/Pause, Next, Previous and Volume in the rail. On Volume, scroll changes the volume.
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
| **Lotti says** | Her sentence, optionally with choices in the rail. Summaries, answers, suggestions                |
| **Proposal**   | Exactly what Lotti wants to do ("I'll tell Mara: …"), with **Send / Change / Cancel** in the rail |
| **Original**   | The source word for word: a message, a mail, a notification                                       |
| **List**       | Pick one of many: places, people, the rest of today. One line each                                |
| **Reading**    | A longer answer, page by page ("Read on" in the rail)                                             |
| **Working**    | Lotti is on it, and says what she's doing ("Sniffing around… checking the BVG"). Double tap stops |
| **Listening**  | Your words appearing as you speak, while you hold                                                 |
| **Card**       | A few facts at a glance (label + value), optionally one big number                                |
| **Done**       | One line that disappears after 2 s ("Told Mara.")                                                 |

Every screen also has: how loud it is, how long it stays, and which choice is Lotti's best guess.

## Key flows

**You put the glasses on**

1. The glasses tell us they're being worn. The IMU is already read for head-up, so the signal exists.
2. Lotti greets with one sentence: what happened while they were off, and what's next ("Two things: Mara asked about 8, and the dentist is in 40 min. Rain later.").
3. Choices only when they help: the first thing, or Navigate. Otherwise no rail.
4. Nothing happened and nothing is due: no greeting, the display stays dark.

**A message comes in**

1. Lotti decides: quiet, normal or urgent. Most things stay quiet.
2. If shown: one sentence in Lotti's voice, choices in the rail (likely replies + "Original").
3. Several things at once become one summary, with the one that needs you first ("3 new: … Mara first?").

**You reply**

1. Tap a suggested reply, or hold and say what you want ("tell her ten minutes late, and I want a margherita").
2. Lotti shows a **Proposal** with the exact words, written in your own style: "I'll tell Mara: …" with Send / Change / Cancel.
3. Tap Send → "Told Mara." The answer comes back later as part of the same conversation.

**Lotti suggests something**
Always as a question with choices ("Ben moved your 15:00 to 15:30. Push your 15:45 with Lea too?"). Approving leads to a Proposal if it affects other people.

## Look-up view

What you see when you look up: **one thing**. Lotti picks the single most useful sentence right now.

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

Plain native iOS look: standard lists and controls, one accent colour (the same green). The goal is that you never need it day to day.

- **Setup:** pair glasses and ring
- **Status:** connected, batteries
- **Settings:** Hermes, messengers, privacy
- **Memory & log:** what Lotti remembers, what she showed or held back and why. Read and delete only; teaching happens by talking to her.

## Open questions

- Should approval ever relax later (e.g. Lotti may send "on my way" to Mara without asking once she's proven herself)? For now: always approve.
- Should Lotti answer out loud through the phone or earbuds, or only on the display?
