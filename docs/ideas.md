# Lotti — Idea backlog

Ideas we want soon but haven't put on the roadmap. Each is written to be decided on, not to be complete: why now, what shape it takes, what it costs.

Rule: an idea moves into [roadmap.md](roadmap.md) when we pick it and disappears from here. Something that needs an answer before it can be built gets `spike` and a write-up in `docs/spikes/`.

Labels as in the roadmap: `ios` `voice` `brain` `design` `shared`.

## Cheap and high use — during or right after the MVP

### 1. Follow-up window: one more turn without holding `ios` `voice`

After Lotti asks something or answers a question, the mic stays open for about 4 s: "Listening" with a shrinking bar, speak and she takes it, say nothing and it closes.

- **Why now:** holding for every turn is the biggest remaining friction, and it needs none of the wake-word work.
- **Shape:** end-of-speech on 1 s of silence plus a hard 4 s cap. Only after an answer or a question from Lotti, never while a `Working` screen is up. Double tap closes it.
- **Cost:** S–M. Needs a silence rule and a visible countdown, so a stray TV doesn't feel like a bug.
- **Watch out:** in a loud place this must lose, not guess. Two misfires in a row and it stays off until you ask for it again.

### 2. "What left the phone" — an egress log `ios` `brain`

Hermes escalation is the only path data takes off the phone. Log exactly what goes out — the question, which phone-tool results were attached, the address — and show the last 20 in the app next to Memory & log.

- **Why now:** there is one egress path today. Two later (Private Cloud Compute, the relay) and this gets expensive to retrofit.
- **Cost:** S. Writes to the existing `Documents/lotti.log` plus a short list view.
- **Bonus:** answers "why was that slow?" — the request and response sit next to the timings.

### 3. A latency budget on the Debug screen `ios` `brain`

Split every answer into stages — speech-to-text, routing, model first token, model complete, render, BLE write — and keep p50/p95 of the last 50 runs.

- **Why now:** the success criteria are numbers (< 1.5 s on-device, < 4 s via Hermes) and today we eyeball them.
- **Cost:** S. A ring buffer in LottiKit, one table on the Debug screen.
- **Also:** catches the prompt change that quietly costs 500 ms.

### 4. Log → eval case, in one command `shared` `brain`

`packages/brain-eval` runs a fixed set. Add a command that takes a line from `lotti.log` — question, context, what Lotti said — and writes a fixture: the correct answer, or a note that it was fine. Marked keep/ignore.

- **Why now:** real use produces the eval set for free, and prompt work only stays safe with one.
- **Cost:** S. A script and a naming convention; the runner already exists.
- **Needs:** the log to carry the whole prompt context, which the pipeline change mostly made true.

### 5. Focus modes are respected `ios` `brain`

Read `INFocusStatusCenter`. While a Focus is on, only `interrupt` screens get through, and the last answer stays reachable for a reply.

- **Why now:** "mostly silent" is the promise, and the phone already knows when you said "don't bother me".
- **Cost:** S. One more input to the loudness decision, plus a line on the status screen saying what's active.
- **Limit:** iOS tells us whether *a* Focus is on, not which. Enough for loudness, not for per-Focus rules.

### 6. Dictate into the clipboard `ios` `voice`

After a dictation the rail offers **Copy** next to sending to Lotti: the text lands on the pasteboard and a Shortcut picks it up from there (note, task, message).

- **Why now:** the glasses' mic becomes useful for capture in any app without a single integration.
- **Cost:** S. `UIPasteboard`, and keeping the dictation screen from dismissing itself. Unverified: iOS may block a silent clipboard write from the background — if it does, the rail needs a visible "tap to copy" step.
- **First Shortcut:** append to the daily note.

## After a week of wearing it

### 7. Traffic-aware "leave in 8 min" `ios` `brain`

When the next event has a location, get the MapKit ETA with traffic and turn it into a nudge: "Leave in 8 min for Mara's — 14 min by bike." One choice: Navigate.

- **Why now:** the first genuinely proactive screen that needs no notification entitlement. The today view is read-only; this gives it a reason to be looked up.
- **Cost:** S–M. `MKDirections` with a departure date, directions already exist, lead time learned from how often you're late.
- **Watch out:** an ETA without traffic in a city is noise. Only worth shipping if the number beats the calendar's start time on real days.

### 8. Talk to the tools you already use `ios` `brain`

Two thin phone tools: `add_shopping_item` (Bring!) and `home_action` (Hue through Home Assistant). "Add milk to the shopping list", "turn the desk light off".

- **Why now:** these are the demos that make a ring worth wearing every day, and each is one HTTP call.
- **Cost:** S each, behind `PhoneTool` so Hermes gets them too.
- **Watch out:** keep both `action` tools, so they always arrive as a tap-to-confirm and never fire silently.

### 9. When the link drops, nothing is lost `ios`

If BLE disconnects mid-question: hold the audio, transcribe on the phone, and show the answer the moment the glasses are back, with one line on the phone ("answered while disconnected") and a quiet "offline" mark in the look-up view.

- **Why now:** "keeps running" is an MVP criterion, and a dropped link is the normal failure, not the exception.
- **Cost:** M. A small queue and a replay path in the conductor.
- **Cheaper half:** never lose the dictation. The queue alone is S.

### 10. A week of hindsight, in the app `ios` `design`

One screen: how many screens Lotti showed, how many you dismissed unseen, which rules fired most, what she held back and why. Weekly, not live.

- **Why now:** the "shown vs ignored" success criterion has nowhere to be read.
- **Cost:** S on top of the log. Mostly counting.
- **Careful:** this is for tuning, not for managing. No settings, just a report.

## Parked, with a reason

- **Answers out loud, through earbuds or the phone speaker.** Useful while the glasses charge, cheap later with `AVSpeechSynthesizer`, but it competes with the display, which is the whole point of Lotti.
- **Ambient brightness policy.** The phone knows the ambient light and the G2 stays dim in sun. Needs a real measurement of what the hardware can do, so it waits for a walk in the sun.
- **Eyes-free audio only.** Same reason, plus battery.
