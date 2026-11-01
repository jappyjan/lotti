# Spike S3: on-device brain quality

Status: ✅ done (eval and model choice). Battery/heat and locked-phone runs moved to [S7](../roadmap.md). Ran on 2026-11-01.
Goal: how well a local model on the iPhone handles Lotti's everyday brain tasks, and decision D11.

## Result

- **D11 confirmed, with one change: Apple's on-device model for every task type in v1. Gemma is not bundled.** Gemma 4 E2B works through the same API and wins one task (rail suggestions), but it costs 3.3 GB of storage, 2.9 GB of app memory and roughly twice the latency (3× on tool calls). Gemma 4 E4B doesn't fit on an iPhone 16: iOS killed it for memory in 2 of 3 runs.
- **All models run behind one API.** iOS 27's `LanguageModel` protocol lets Apple's model, Private Cloud Compute (PCC) and MLX models (Gemma) back the same `LanguageModelSession`, with guided generation (`@Generable`) and tool calling. Lotti's brain code is written once.
- **The Apple model's context is still 4,096 tokens on iOS 27** (iPhone 16, variant "AFM 3 Core"). The four phone tools alone add about 500 of them.
- **PCC is blocked without a paid developer account.** It needs the managed entitlement `com.apple.developer.private-cloud-compute`, which only Developer Program members can request.
- Eval set, runner and scoring live in `packages/brain-eval`, where M5's prompt and eval harness can build on them.

## Setup: how each model runs on the phone

| Model                        | How it runs                                                                                                                                                            | Download                                     | App memory |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- | ---------- |
| Apple on-device (AFM 3 Core) | `SystemLanguageModel.default`. Built into iOS 27, runs in a system process                                                                                             | none                                         | ~20 MB     |
| Gemma 4 E2B (4-bit MLX)      | `MLXLanguageModel` from [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.32.3 (`MLXFoundationModels`), Apple's open-source adapter for the iOS 27 protocol | 3.3 GB (`mlx-community/gemma-4-e2b-it-4bit`) | ~2.9 GB    |
| Gemma 4 E4B (4-bit MLX)      | same                                                                                                                                                                   | 4.8 GB (`mlx-community/gemma-4-e4b-it-4bit`) | ~4.4 GB    |
| Apple PCC                    | `PrivateCloudComputeLanguageModel()`. Server-side, 32K context                                                                                                         | none                                         | n/a        |

No LiteRT-LM or custom provider needed: mlx-swift-lm ships Gemma 4 support, grammar-constrained guided generation (XGrammar) and Gemma 4's tool-call format.

Things that bit us:

- **Metal toolchain.** MLX needs Xcode's Metal compiler: `xcodebuild -downloadComponent MetalToolchain` (once per Mac, ~840 MB). CI on macOS will need the same step.
- **Macros.** mlx-swift-lm's `#hubDownloader` / `#huggingFaceTokenizerLoader` macros make Xcode ask for macro approval, which breaks command-line builds. `apps/ios/Lotti/Eval/HubBridge.swift` writes out what they expand to (about 50 lines) instead.
- **Memory limit.** `apps/ios/Lotti.entitlements` sets `com.apple.developer.kernel.increased-memory-limit` (works with the free team). Without it Gemma wouldn't load at all.
- **First MLX build** takes about 10 minutes (C++ and Metal kernels). Later builds are incremental.

### Gemma weights: outside git and outside the app bundle

The app looks for weights in `Library/Caches/models/<name>/` in its own data container, then falls back to downloading from Hugging Face on the phone. On-phone downloads of 3–5 GB failed twice (timeout, then "network connection lost"), so we sideloaded from the Mac:

```sh
# on the Mac (into tmp/, which git ignores)
for f in config.json generation_config.json chat_template.jinja processor_config.json tokenizer.json \
         tokenizer_config.json model.safetensors.index.json model.safetensors; do
  curl -fL -C - --retry 5 -o tmp/models/gemma-4-e2b-it-4bit/$f \
    https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/resolve/main/$f
done
# copy over the cable into the app's caches (~2.5 min for 3.3 GB)
xcrun devicectl device copy to --device <udid> --domain-type appDataContainer \
  --domain-identifier de.janjaap.lotti --source tmp/models/gemma-4-e2b-it-4bit \
  --destination Library/Caches/models/gemma-4-e2b-it-4bit
```

If Gemma ever ships for real, it needs a proper background download (`URLSession` background configuration, resumable) or Apple's Background Assets.

### Running the eval

The app has a throwaway "Brain eval" screen (`apps/ios/Lotti/Eval`). It keeps the phone awake while open. Runs can also be started from the Mac with launch arguments:

```sh
apps/ios/scripts/xcode.sh run-device --eval apple                      # or pcc, gemma4-e2b, gemma4-e4b
apps/ios/scripts/xcode.sh run-device --eval apple --tasks triage,tool  # only some tasks
apps/ios/scripts/xcode.sh run-device --eval apple --soak 30            # 30 min sustained use
apps/ios/scripts/xcode.sh run-device --eval apple --background 10 --probe apple,gemma4-e2b
```

Each case prints one `[Eval] case {json}` line (output, checks, time to first token, total time, tokens, memory), and each run ends with `[Eval] summary` lines per task. Raw results from this spike: [`s3-results/`](s3-results/).

## The eval set

`packages/brain-eval/Sources/BrainEval/Fixtures/s3-eval.json`, 35 cases. People, messages and writing samples are made up but realistic (Berlin, German and English, the five messengers plus mail, banking, DHL, calendar, Slack, GitHub).

| Task       | Cases | What's checked automatically                                                                                              |
| ---------- | ----- | ------------------------------------------------------------------------------------------------------------------------- |
| Triage     | 10    | quiet / normal / urgent, with memory rules ("never bother me with the volleyball group", "work chats quiet after 19:00")  |
| Summaries  | 6     | one sentence, ≤ 25 words, right language (incl. German → English and English → German), key facts present                 |
| Rail       | 4     | 1–3 choices of ≤ 4 words, the expected kinds of choice (e.g. a yes and a no)                                              |
| Replies    | 5     | right language and facts, no assistant voice, length; written from the user's earlier messages to that person             |
| Screens    | 5     | right building block (`lottiSays`, `proposal`, `original`, `list`, `card`), key facts                                     |
| Tool calls | 5     | right tool and arguments (`set_timer`, `start_navigation`, `next_meeting`, `create_reminder`), and no tool for small talk |

Each case runs in a fresh session with greedy sampling and guided generation into a per-task `@Generable` type. Prompts are in `Prompts.swift`, the same for every model. Expectations are loose on purpose; every output was also read and graded by hand (notes below).

**Prompt fixes during the spike.** The first run showed two problems in my own prompts, so I fixed them once, before any Gemma run: small models copied the example in the instructions ("Mara says…" for every sender; Send/Change/Cancel on every screen), and a vague "use a tool when needed" got zero tool calls from the Apple model. After a clear routing rule ("for a timer, navigation, calendar or reminder, call the tool first"), the Apple model went from 0/5 to 5/5 on tools. Lesson for M5: **prompts for a 3B model need explicit rules, not examples to imitate.**

## Results

iPhone 16 (8 GB), iOS 27.1, plugged in, phone awake. "Passed" means every automatic check passed. Times are medians: time to first token (first streamed snapshot) / total.

| Task       | Apple on-device       | Gemma 4 E2B                     | Gemma 4 E4B                           |
| ---------- | --------------------- | ------------------------------- | ------------------------------------- |
| Triage     | 8/10 · 1.4 / 1.5 s    | 8/10 · 1.7 / 2.8 s              | 8/8 before it was killed · 4–14 s     |
| Summaries  | 3/6 · 1.4 / 1.7 s     | 3/6 · 1.6 / 2.5 s               | not reached                           |
| Rail       | 1/4 · 1.3 / 1.5 s     | **3/4** · 1.7 / 3.1 s           | not reached                           |
| Replies    | **5/5** · 1.2 / 1.4 s | 4/5 · 1.7 / 2.8 s               | not reached                           |
| Screens    | **3/5** · 1.3 / 2.4 s | 1/5 · 2.3 / 4.8 s               | not reached                           |
| Tool calls | **5/5** · 2.0 / 2.8 s | 4/5 · 6.2 / 9.4 s               | not reached                           |
| **Total**  | **25/35**             | 23/35                           | —                                     |
| Cold start | first call 5.0 s      | load 5.7–12.5 s, first call 8 s | load 8–10 s                           |
| App memory | ~20 MB                | ~2.9 GB                         | ~4.4 GB, killed by iOS in 2 of 3 runs |

(Gemma E2B's tool score counts `start_navigation("Kastanienallee 12")` for "walk me home" as right: that's the home address in the prompt. The raw log still shows the stricter check.)

Hermes: skipped, no endpoint handy (S6). PCC: not run, see below.

### Quality notes (hand-graded)

**Triage.** Both 8/10, but different misses. Apple shows too much: a Zalando newsletter and evening "nice slides 👍" came out normal. Gemma E2B missed something important: "prod is down, can you look asap?" at 21:30 came out normal, because the "work quiet after 19:00" rule won. Apple got that one right, plus the 03:12 card payment of 1,249 €. Gemma E4B got all 8 it reached right, including the newsletter, so it's the best here, but it isn't usable on this phone.

**Summaries.** Tie at 3/6, different failures.

- Apple: two empty outputs ("Ben says:" and nothing else; one of them looped to the 300-token limit and took 23 s). When it works it's tight: "Lufthansa: Your flight LH 2034 to Munich is delayed. New departure 18:45 from gate B12."
- Gemma E2B: always produced a sentence and kept more facts, but got one meaning backwards ("Mama will dich am Hauptbahnhof abholen": she wants to be picked up, not pick him up).
- Both handled German → English. English → German: Apple answered empty and in English; Gemma answered in German but dropped Lea.

**Rail.** Gemma is clearly better. Gemma: "Ja, komme / Nein, später / Frage klären", "Yes, 4pm / No, later / Check calendar". Apple: "Ja, bitte / Ich bin dabei / Pizza gut" (no "running late"), "Agree / Confirm / Check time" (no way to say no). Neither suggested a useful action for the DHL notice (remind me, route to the Packstation).

**Replies.** Both good; Gemma sounds more like the user ("Bin 10 Min spät. Margherita bitte 🍕" vs Apple's "Ja, ich bin in 10 Minuten! Und ich hole mir bitte eine Margherita 🍕"). Apple got the register wrong for the landlord ("Hallo, alles klar, …" instead of "Sehr geehrte …"); Gemma returned nothing for that one. Apple never slipped into Lotti's voice.

**Screens.** Apple picked the right building block for proposal, original and list. It made one factual error: the weather card said "cloudy" when the context said rain from 21:00. Gemma turned "what did she write exactly?" into a proposal translated into English, and lost the times from the "rest of today" list.

**Tool calls.** Apple: right tool and arguments 5/5 (`set_timer(10, "pasta")`, `start_navigation("Mauerpark", bike)`, …), and no tool for small talk. But the text it showed afterwards was often weak: it echoed the request back, and its choices were junk ("Check / Talk / Sleep / Eat"). Gemma: 4/5 (no call for the German bike request) and 3× slower.

**Common to both.** Choices in the rail are the weakest part. M5 should fill fixed choices from the template (Proposal → Send / Change / Cancel; summaries → "Original") and let the model add at most one or two.

### Latency against the M5 target

M5 wants the first screen in under 1.5 s. The Apple model's first token arrives at 1.2–1.4 s and a full screen takes about 2.4 s, so the budget only works if Lotti:

- streams the screen into the renderer as it's generated (`streamResponse` snapshots are usable partial screens),
- prewarms the session when an event is likely (the first call after launch took 5 s), and
- keeps prompts small: screens and tool calls carry 500–1,000 prompt tokens, mostly schema.

Two Apple calls stalled for 23 s and 59 s with no error. M5 needs a timeout that falls back to a rule-based screen (or the original notification).

## Not measured: battery, heat, locked phone

The 30-minute sustained-use runs and the locked-phone test were built (`--soak`, `--background`) but didn't run: the first background attempt crashed on a bug in the probe (fixed in `5090128`), and there was no time for a second hour-long session. **These move to S7**, which already covers background life for BLE, mic and model. What we know without measuring:

- **Apple's model** runs in a system process, so it adds next to nothing to the app's memory. Battery and heat cost are what S7 has to measure.
- **Gemma (MLX) runs on the GPU.** iOS doesn't let apps submit GPU work in the background, except through `BGContinuedProcessingTask` with the GPU background entitlement. So Gemma is very likely unusable with the phone locked. That's one more reason not to depend on it for triage, which mostly happens with the phone in a pocket.
- Gemma's memory (2.9 GB) also makes it a likely target for iOS to kill the app in the background.

## iOS 27 notes

- **Model-agnostic Foundation Models.** `LanguageModel` + `LanguageModelExecutor` are public. Providers ship as Swift packages: Apple's `MLXLanguageModel` (mlx-swift-lm), and per WWDC26 session 339, `CoreAILanguageModel` plus Anthropic and Google packages. A request arrives as a `Transcript` plus tool definitions plus an optional `GenerationSchema`; the provider streams text and tool calls back.
- **On-device context: still 4,096 tokens** on the iPhone 16 (`SystemLanguageModel.default.contextSize`, variant `AFM 3 Core`). The SDK also has a `coreAdvanced3` variant, probably for newer phones; its context size is unknown. `tokenCount(for:)` (iOS 26.4+) can measure prompts, tools and schemas before sending.
- **German** is in `supportedLanguages`, along with 23 others.
- **Adapters are gone:** `SystemLanguageModel.Adapter` is obsoleted in iOS 27, so fine-tuning Apple's model for Lotti's style isn't an option.
- **New in sessions:** token `usage` per response, `ContextOptions.reasoningLevel` (light / moderate / deep, for reasoning models), and typed `LanguageModelError`s (`contextSizeExceeded`, `rateLimited`, `guardrailViolation`, …).
- **Private Cloud Compute** (`PrivateCloudComputeLanguageModel`): 32K context, a per-user daily quota tied to the iCloud account (`quotaUsage`), needs a network. On our phone it reported `available` and a 32,768-token context, but the first request **crashed the app** (`Fatal error: Missing entitlement: com.apple.developer.private-cloud-compute`) instead of throwing. The entitlement is managed: request it via [developer.apple.com/contact/request/private-cloud-compute](https://developer.apple.com/contact/request/private-cloud-compute/), which needs a paid Developer Program membership. Check for the entitlement before ever constructing a PCC session. Still a good middle tier between the phone and Hermes (roadmap "Later").

## Model choice per task (D11)

| Task                 | Model                               | Why                                                                                                                                  |
| -------------------- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Notification triage  | Apple on-device                     | Same score as Gemma, 2× faster, didn't miss "prod is down". Put newsletters/marketing in the rules tier                              |
| One-sentence summary | Apple on-device                     | Tie; Apple is faster and free. Guard against empty output: retry once, else show the Original                                        |
| Rail suggestions     | Apple on-device + template defaults | Gemma is better here, but not worth 3 GB for three labels. Fixed choices from the template, model adds 1–2. Re-check in M5's harness |
| Replies in own style | Apple on-device                     | 5/5; pass a formality hint from memory (du/Sie) per person                                                                           |
| Screen generation    | Apple on-device                     | 3/5 vs 1/5, and the faster first token                                                                                               |
| Tool calls           | Apple on-device                     | 5/5 at 2.8 s vs 4/5 at 9.4 s                                                                                                         |

**D11:** Apple's on-device Foundation Model for all task types, behind the Foundation Models `LanguageModel` API. Gemma isn't bundled in v1. Gemma 4 E2B stays a tested drop-in (same API, same eval) if M5's harness shows a task falling short; E4B is ruled out on 8 GB iPhones. PCC is the middle tier once the entitlement is available.
