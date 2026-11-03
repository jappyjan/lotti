# wake-word

Trains the "Hey Lotti" sound classifier (`HeyLotti.mlmodel`) that the app runs first when it listens for the wake word. A macOS tool on Create ML; the app then confirms every hit with Apple speech (see [architecture](../../docs/architecture.md#wake-word)).

## Retrain in one go

```sh
pnpm nx run wake-word:generate   # synthetic clips from macOS `say`, through the G2's LC3 codec
pnpm nx run wake-word:train      # trains and writes apps/ios/Lotti/HeyLotti.mlmodel
pnpm nx run wake-word:test       # accuracy on the held-out clips
```

Then commit `apps/ios/Lotti/HeyLotti.mlmodel`. Needs macOS with Xcode and the German and English voices installed (System Settings → Accessibility → Spoken Content).

## What it does

- **generate:** every installed German and English voice (no novelty voices) says the wake phrases ("Hey Lotti", "Hi Lotti", "Hallo Lotti", …, also followed by a command, cut after the phrase) at several speeds. Negatives: near misses ("a lotta", "Lotte", "Hey Lola", "Hotel", "Lotto", "Hey Otto", …), everyday speech in both languages, silence, room noise, hum, taps and babble. Every clip gets a random level, room noise and an LC3 encode → decode round trip (10 ms, 16 kHz, 40-byte frames) so it sounds like the glasses' mic. Output: 16 kHz mono 16-bit WAVs in `data/synthetic/`. The `say` output is cached in `data/raw/`, so changing the augmentation takes seconds.
- **train:** Create ML `MLSoundClassifier` (VGGish features, small neural net head), classes `hey_lotti` and `background`. 15% of the recordings are held out (by recording, so no near copy of a held-out clip is in the training set). At most 3300 clips per class are used: with many more, Create ML crashes. Your own clips come first.
- **test:** runs the trained model on the held-out clips like the app does (SoundAnalysis, `hey_lotti` confidence against 0.8) and prints per-group results and a threshold sweep. Also written to `data/results.txt`.

## Your own recordings

Synthetic voices are only a start. In the app: Debug → Record training clips (glasses connected). "Record 'Hey Lotti'" saves a 2 s clip per tap; "Record background" cuts continuous audio (talk, TV, street) into 1 s pieces. Then:

```sh
xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
  --domain-identifier de.janjaap.lotti --source Documents/wakeword --destination data/user
pnpm nx run wake-word:train
```

`train` picks up `data/user/hey_lotti/` and `data/user/background/` by itself. About 100 "Hey Lotti" clips in different places and 15 minutes of background is plenty.

Everything in `data/` is gitignored: no raw audio, and not your voice, goes into git.

## Results

Synthetic clips only, held out, threshold 0.8 (run on 2026-11-03, 1304 held-out clips; the synthetic voices are the same ones the model trained on, so this is optimistic for the real glasses):

| Group                                | Result                       | Target |
| ------------------------------------ | ---------------------------- | ------ |
| `hey_lotti` fires (recall)           | 95.1% (548 of 576)           | ≥ 95%  |
| near misses rejected                 | **96.9%** (189 of 195)       | ≥ 98%  |
| other speech rejected                | 99.0% (491 of 496)           | ≥ 98%  |
| noise, silence, babble rejected      | 100% (37 of 37)              | ≥ 98%  |

The near-miss target is missed: "Hey Bobby", "Hey Loki", "Hotti Lotti" and "Hallo Lotto" still fire now and then. The speech confirm in the app drops those. The recall misses are mostly "Hallo Lotti" in a few voices. Recall on real glasses audio is not measured; that needs the on-device check and probably a round of your own clips.

Timing on an M-series Mac: `generate` about 16 minutes the first time (3800 `say` calls; the load on the Mac decides), seconds when the `say` output is cached; `train` about 3.5 minutes. The model is about 30 MB (it carries the VGGish feature extractor).
