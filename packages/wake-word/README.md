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

`train` picks up `data/user/hey_lotti/` and `data/user/background/` by itself (any depth), trims each phrase clip to the loud part and makes a few level and noise variants. Debug → "Record 30 × Hey Lotti in a row" is the quick way. About 100 "Hey Lotti" clips in different places and 15 minutes of background is plenty.

Everything in `data/` is gitignored: no raw audio, and not your voice, goes into git.

## Results

**On the real glasses (2026-11-03):** a model trained on synthetic voices only scored real G2 audio near 0 (best 0.47 in a minute of speech). After adding 30 recorded phrases and 94 one-second background pieces and retraining, 8 of 10 spoken "Hey Lotti, wie wird das Wetter?" woke Lotti (candidates scored 0.94–1.00 and were confirmed), and about 11 minutes of nearby talk gave one classifier hit (0.82), rejected by the speech confirm. Record more clips (Debug → Record 30 × "Hey Lotti") if it misses in a new place.

Final model, held-out clips (1374), threshold 0.8, 2026-11-03. The synthetic voices are the ones the model trained on, so those rows are optimistic for the real glasses:

| Group                                  | Result                  | Target |
| -------------------------------------- | ----------------------- | ------ |
| synthetic `hey_lotti` fires (recall)   | 97.7% (563 of 576)      | ≥ 95%  |
| recorded `hey_lotti` fires (tiny set)  | 89.6% (43 of 48)        | –      |
| near misses rejected                   | **96.9%** (189 of 195)  | ≥ 98%  |
| other speech rejected                  | **96.8%** (480 of 496)  | ≥ 98%  |
| noise, silence, babble rejected        | 100% (37 of 37)         | ≥ 98%  |
| recorded background rejected (tiny set)| 86.4% (19 of 22)        | –      |

Rejection of near misses and other speech is just under 98% (the version before the recordings were added had 99.0% for other speech but fired on almost nothing real). The speech confirm in the app drops what slips through. "Hey Bobby", "Hey Loki", "Hotti Lotti" and "Hallo Lotto" are the usual near-miss hits.

Timing on an M-series Mac: `generate` about 16 minutes the first time (3800 `say` calls; the load on the Mac decides), seconds when the `say` output is cached; `train` about 3.5 minutes. The model is about 30 MB (it carries the VGGish feature extractor).
