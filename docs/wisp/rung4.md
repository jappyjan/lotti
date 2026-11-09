# Wisp — rung 4 plan: the first native flash

**Status: approved by Jan on 2026-11-08 ("I approve everything", R4-1 to R4-8, W19 done); nothing in it has run on hardware yet.** This was written on t3-worker from the docs and the code, and no hardware was touched. An independent review checked it against safety.md; its findings are worked in. Jan gave the go to plan the next rung. Every write below still needs its own explicit go (safety rule 4). The rule changes in [Decisions for Jan](#decisions-for-jan) are now in safety.md.

Tags as elsewhere: **[C]** confirmed (code, log, static analysis), **[I]** inferred, **[?]** open.

## Where things stand

- **W18 is complete on both temples** ([hardware log](safety.md#hardware-log)). drdaeman's patched bootloader (`87e2d4e0…`, CRC-32 `63cd8dda`) is in MRAM. Its UART2 loader runs at every boot, **before any main-app code**. The case path works: USB → case STM32 ROM → feeding relay `observed-33-feed` → pogo UART → temple loader. The relay feeds the case's YHM4005. The RAM programs `feed`, `dump_fed` and `recover_fed` feed the temple's nPM1300 watchdog.
- **Recovery is proven on both temples.** `w18.py recover` wrote the full stock 2.4.0.24 main app into `0x438000` in one session of about 72 min, final CRC `d9864941`.
- **Not proven yet: recovery when the temple is not running stock.** Every case reset on hardware so far hit a temple whose stock app was running (W18 D–F2). The temple reset is Even's 372-byte waveform from case 1.2.57; it calls a `reset_gpio` routine (`wisp_w18/pins.py:86-89`). Nobody has analysed whether it works at hardware level or depends on something the stock app does. drdaeman's loader also "silently falls back to stock behaviour if the stock UART2 state is not as expected" ([recovery.md, step D](recovery.md#step-by-step-for-jan-mac-left-temple-first)). **The plan's central claim, "the loader always comes first", rests on both, so it tests both before and right after the first native flash** (W20, W21, W24). *W20 (2026-11-08, static, [hardware.md](hardware.md#rung-4-static-analysis-w20-2026-11-08)):* the loader's UART2 precondition reads only the bootloader's own state, rebuilt at every boot [C]. The waveform is a pulse code on the selected pogo line that waits for nothing from the temple, and case 1.2.57 uses it on temples that stopped answering, so it should not need the stock app [I]. W21 proves it on hardware.
- Rung 1 passed on the left. Rung 2 was dropped. Rung 3 has 26/26 in Renode and W17 asked for no more work on it; it was never formally signed off (safety.md, "Rung 3 status"). M6 so far: BLE and the wisp-core session run end to end in emulation, and the drivers (panel, touch/wear, IMU, light, PMIC) pass in Renode.
- **What the code does not have yet** [C, surveyed for this plan]:
  - Wisp Boot and the Zephyr app have never been joined. The app is linked at `0x438000`, does not feed Wisp Boot's watchdog and never calls `confirm()`. Rung 3 ran bare-metal fault apps only.
  - There is no update service and no storage HAL (MSPI1 is disabled in the app's DTS).
  - Wisp Boot's NOR driver knows only the MX25U25643G (RDID `C2 25 39`; anything else makes it run the app degraded). Wisp Boot never touches the nPM1300 watchdog.
  - Wisp Boot's boot record is keyed only on the staging file's CRC word (`wisp_boot.c:77`), so it cannot tell that an image was written straight to MRAM.
  - The panel is chosen at build time. The default is `a6n-g`, which puts **BUCK1 at 1.8 V** (`wisp_g2.dts:263-270`). Both of Jan's temples report hardware 5, the JBD4010, which stock drives with npmx code 1, read as 1.1 V [I].
  - Nothing can put `wisp/rescue.bin` on a temple or read it back. Stock's OTA receiver accepts only each component type's own target path (`packages/wisp-ota/src/transfer/protocol.ts:53-55`), and no stock file-read path is known. **Rule 11 cannot be met today.**
  - `w18.py recover` is locked to the stock image by its SHA-256 pin (`cli.py:428-430`, `session.py:328-329`) and bounded to the stock image's length (`session.py:260-261`). Otherwise its writer is image-agnostic.
  - *Update, W22 (emulation only):* Wisp Boot and the real app are joined in `native-0`: the app at `0x448000` feeds both watchdogs, confirms after `HELLO`, answers the case UART; observe-only Wisp Boot and its status block; no default panel; the PMIC left unconfigured; the no-MRAM-write gate. See [native-0 status](#native-0-status-w22).
  - *Update, rung-4 tooling (emulation only):* the writer now takes an image and its end bound, zeroes the vectors first, and `install-wisp` exists (G1), gated so that it refuses every image until R4-1 is approved and an image is pinned. See [Tooling status](#tooling-status).
  - *Update, W23 (2026-11-08, emulation only):* the reviewed `native-0` (`5d373fd8…`, commit `8374f9a`) is pinned and committed, `boot-watch` speaks its case-UART status, and W24 has a [runbook](#w24-runbook-first-native-flash-left).
  - *Update, W24 (2026-11-08, hardware):* native-0 was written and verified on the left temple, and the loader answered after it, but on silicon the image reboots about every 10.4 s (Wisp Boot's watchdog), never answers on the case UART and never advertises. The PMIC came back at its reset values after its own watchdog fired. W24 stopped at step 9. Analysis, the next images and the diagnostics they carry: [W24 result and analysis](#w24-result-and-analysis).
  - *Update, W24b prepared (2026-11-08, emulation only):* Wisp Boot carries the diagnostics (D1 record, reset cause, the boot report on the case UART, the PMIC watchdog kick at every boot); `stage-0`, a bare-metal app of about 5 KiB, is built and committed, and pinned after its independent review (W24b-0, 2026-11-09); Renode now runs the LFRC at 900 Hz, models `RSTGEN.STAT` and the PMIC's power-on values, and fails native cases on unreviewed writes to unmodelled power, clock and trim registers. The next hardware step: [W24b](#w24b-stage-0-the-next-hardware-step).
  - *Update, W24b (2026-11-09, hardware, then analysis on t3-worker):* stage-0 installed (`19b3e002`) and recovered (`d9864941`); it looped every ≈10.68 s and boot-watch got nothing. The silence is the tool's: the relay holds an unanswered request until the temple's next frame, and the one report request per boot landed in the loader's window. Fixed host-side (the report is aimed at Wisp Boot's window); a second read path added (`peek` of the record in a held loader); the loop analysed (most likely Wisp Boot hangs after its window, in its NOR phase). See [W24b results and the fix](#w24b-results-and-the-fix), with a rerun runbook for the same stage-0.

## The short answer

| Question | Recommendation |
| --- | --- |
| Route | **(b) the case loader**: a new `w18.py install-wisp` that writes a pinned Wisp image with the proven `recover_fed` machinery. Needs rule 1 amended (R4-1). |
| First image | **`native-0`**: Wisp Boot in an *observe-only* build (reads the NOR, never writes it, never rescues, always runs the app) and the native app as built (BLE + session). The app feeds the watchdogs, answers a status query on the case UART, and keeps the panel unpowered. It contains no update service and no MRAM write code. |
| First flash ends with | **a case `recover` back to stock**, so the core assumption (case recovery works from a native state) is proven at the first native flash, not at the end. |
| Exit check | Five items on hardware: confirmed boots and a working session; back to stock over BLE through Wisp's own update service; fallback to stock through forced faults; case recovery from a native state; bootloader, flag and PMIC registers unchanged throughout. [The row](#1-the-exit-check-for-rung-4). |
| Pre-qualification from RAM | Only cheap reads: the NOR part, a PMIC register snapshot and the panel variant. One reset test of a temple held in the loader. No stager, and no Zephyr code from RAM. |
| Rule 11 | **Relax it** (R4-2). Case recovery replaces `rescue.bin` as the precondition for bench flashes. `rescue.bin` is still required before the forced-fault test, before any native install over BLE (together with a proven flag-clear exit) and before daily use. It gets onto the NOR through Wisp's own storage and update service. |
| Steps | W19–W31. W24, W25 and W27–W30 write to the temple. |

## 1. The exit check for rung 4

This is the replacement (approved, R4-4, now in safety.md) for the rung-4 row of the [ladder](safety.md#the-ladder) (decision R4-4). The present row still requires "SWD access proven", which W17 replaced.

| Rung | What gets flashed | Brick risk | Exit check | Precondition |
| --- | --- | --- | --- | --- |
| 4 | **Native Wisp** (Wisp Boot + native app) on the left temple, written into the app region through the case loader (`w18.py install-wisp`); later images also over BLE through Wisp's own update service | **high** for the first flash, **bounded by case recovery**: the patched loader runs before any Wisp code, `recover` is proven on that temple, and a held-temple reset test passed | On real hardware, each item logged. **(1)** 10 consecutive boots, each started by a case reset or a software reset. Each is confirmed: Wisp Boot's record says confirmed, BLE advertises, and the SDK completes `HELLO` from the Mac. One 10-minute session works (`PING`, `TIME_SYNC`, a panel test pattern). **(2)** Back to stock over BLE: Wisp's update service stages the pure stock 2.4.0.24 main, the Even bootloader installs it, and the temple boots stock with the Even app working. **(3)** Fallback to stock with no host action: forced-fault images that hang early or fault at reset end in stock through Wisp Boot's rescue. **(4)** Case `recover` brings a native temple back to stock, once from a running native image and once from a dead one. **(5)** At every loader session: the bootloader CRC is `63cd8dda`; the update flag holds one of its two documented values; the app region's CRC is the expected image's; the PMIC registers equal the stock snapshot (only the watchdog timer may differ). Nothing is written outside the app region, the flag record and `wisp/` on the NOR littlefs. | rung 3; W18 F2 passed on that temple; the held-temple reset test (W21) passed; `loader-hello` passes in the same session, before each case write; rules as amended by R4-1 to R4-4 and R4-7 |

**"Passed"** means all five items on the left temple, written into the hardware log. Rule 5 then lets the right temple follow, with the same steps and a go for each write.

A **cold boot** in the strict sense is not available on a temple: there is no power switch, and the PMIC runs off the battery. The case's temple reset is the hardest reset a host can trigger. The PMIC watchdog's power cycle is a harder one, and `native-0` keeps it armed for that reason ([§2](#2-which-image-goes-on-first)).

An intermediate checkpoint, **"4a: first native boot"** (W24–W25), is logged as its own row. It is not a pass.

## 2. Which image goes on first

| Option | What it proves | Why not first |
| --- | --- | --- |
| Full native: Wisp Boot with records and rescue, the app with every driver live, the update service | everything at once | Too many unknowns in one flash: a failure says little about which part failed. The update service and storage HAL don't exist yet. |
| App only at `0x438000`, no Wisp Boot | the Zephyr port on silicon | The boot path changes again in the next image. Rule 12 and the native layout put Wisp Boot first. Leaving it out does not lower the risk under route (b). |
| **`native-0` (recommended)** | the real native boot path (Even bootloader → Wisp Boot → app); the NOR read path; clocks and STIMER; the watchdogs; the EM9305 over HCI; the case UART | — |

**`native-0` contents:**

- **Wisp Boot, observe-only build.** This is the same code with writes compiled out:
  - It arms and locks the Apollo watchdog (8 s) as usual.
  - It reads `wisp/boot.rec`, the staging preamble and `wisp/rescue.bin`, and lists `/firmware/*` (names, sizes, CRCs) for an inventory.
  - It never writes the NOR or the flag. Its decision is always `run-app`.
  - It leaves what it saw in a **RAM status block** in its own RAM (`0x20370000–0x20380000`), which the services table at `0x438200` points to. The table itself is a const in MRAM. The block holds RDID, the mount result, the record, the staging CRC word, the rescue check and the inventory.
  - This is a **known-answer test of the NOR read path before the first NOR write**. On the left temple the staging file should still hold the pure stock 2.4.0.24 main from rung 1's return trip, with preamble CRC word `0x971F4516` [I]. The NOR commands are only RDID, RDSR and reads (the review checked this in `boot_nor.c`).
- **The app as built** (Zephyr, BLE, Wisp GATT service, wisp-core session, drivers suspended), plus:
  - **Relinked at `0x448000`.** `sram0` and the stack stay out of Wisp Boot's RAM.
  - **Feeds Wisp Boot's locked 8 s watchdog** from a `k_timer` or the highest-priority thread, started before `bt_enable()`. The EM9305 bring-up blocks for up to 5 s, and nothing may starve the feed.
  - **Keeps the nPM1300 watchdog armed** at stock's 30.72 s and kicks it every second, as stock does, instead of stopping it (today `power.c:38-39` stops it). The PMIC's power cycle is the one reset that also clears the Apollo state a software reset keeps (clock gen and PMU registers survive a software POR, hal_ambiq `am_hal_reset.h`). Loader sessions feed it as they do for stock.
  - **Calls `confirm()` after `HELLO`.** It is a no-op in observe-only Wisp Boot, but the call path gets exercised.
  - **Answers on the case UART** (UART2, 1 Mbaud, `5A A5 FF` replies). It answers step 0's version query `24 00 01 00 a7` with a Wisp-identifying frame, and a Wisp status query with: the boot stage, Wisp Boot's status block, the `bt_enable()` result, the sensors-present mask, battery mV, VBUS and charger state, the reset cause and uptime. It also takes a **reset command**. This is the observation channel when BLE does not come up, which is the most likely first failure (W11 names the fallback: AmbiqSuite + Cordio). The same reset command is offered over BLE.
  - **Leaves the panel unpowered.** BUCK1, LDSW2 and the panel GPIOs are never switched. The build has **no default panel**: it fails unless one is chosen explicitly. The test pattern moves to `native-1`, after W21's snapshot has given BUCK1's real voltage code.
  - **Links no MRAM write path.** No `am_hal_mram_*`, no `nv_program_*`, no boot-ROM helper address `0x0200FF20` and no key `0x12344321` anywhere in `[0x448000, end)`, and the MRAM flash driver is off. A post-link gate proves it (G13). The bootloader region is the one thing case recovery cannot repair, so the app must be unable to write it.
- **Left out:** the update service, the storage HAL, `rescue.bin` handling, the touch rescue hold, and sensor caps in `HELLO`.

Size: Wisp Boot padded to 64 KiB plus the 190 KB app, about 210 KB. Through the loader that is about 13,100 `INPUT_DATA` and 820 progress exchanges at about 17.4 ms: **about 4–5 min per install**, against 72 min for `recover`.

**`native-1`** is the next image. It changes two things:

- **Wisp Boot's normal build:** it writes `boot.rec`, counts boots and confirms. With no `rescue.bin` it runs the app degraded after 3 unconfirmed boots instead of rescuing. This is the first native write to the NOR, and it comes after `native-0` has shown the read path is right.
- **The JBD4010 test pattern:** BUCK1 is set to the voltage code W21 read from stock, and the build gates on it.

## 3. How it gets onto the temple

|  | (a) Stock BLE OTA of a main-only Wisp bundle (rung 1's way) | (b) Case loader: `w18.py install-wisp` |
| --- | --- | --- |
| Proven on this hardware | the stock OTA path, with stock images (rung 1) | the loader write path, 3.7 MB in one session, twice (W18 F2, both temples) |
| What does the write | stock's OTA receiver stages the file; the **Even bootloader** installs it at the next boot | our pinned `recover_fed.bin` in the held loader. With R4-1: zeroes the vectors first, then the body, a whole-body CRC, the vectors, and a full CRC |
| **State afterwards** | update flag `0x55555555` and the staging file = Wisp, until something clears the flag. The bootloader reinstalls Wisp at every boot until then | flag clear, staging file still stock 2.4.0.24 (left) [I]: **exactly the state F2 recovered from** |
| If the new image is dead | case `recover` **refuses** a pending flag (`cli.py:449-454`). Forced with `--allow-pending-flag`, it writes stock, but after `CONT` the bootloader's flag check reinstalls Wisp from staging. With no `rescue.bin`, Wisp Boot never stages anything. **No proven way out** (the "flag trap"); it needs a loader-side flag clear (G26) | `install-wisp` the next image (about 5 min) or `recover` stock (about 72 min): both proven paths, from the same state |
| Rules | rule 1 unchanged. Rule 11 must still be met or amended, and the rung-4 row still asks for SWD | **rule 1's W18 exception must be extended** (R4-1) |
| Tooling | `wisp-ota pack-main` exists. The iOS screen sends only `rung1` or `stock` (`WispOtaEngine.swift:41`), so a Mac sender or a new iOS kind is needed | about 60–120 lines on top of `recover`, plus tests |
| Temple, Jan's time | out of the case, BLE, phone or Mac; a few minutes | seated in the case, case on USB, Mac; about 6 min with checks |
| Observation right after | BLE only: if BLE fails, nothing is visible | the same tool can `CONT` and query the case-UART status in the same relay session (`boot-watch`) |
| Exercises the future update path | yes (staging, flag, Even bootloader) | no. Exit items (2) and (3) exercise it later, through Wisp's own update service and Wisp Boot's rescue |

**Recommendation: (b) for every image until rung 4 passes.** The state row decides it. Route (a) leaves the flag set and a Wisp image staged, a state from which no tested path leads out: case `recover` is refused or undone, and Wisp Boot's rescue needs the `rescue.bin` that cannot be placed yet. Route (b) leaves exactly the state that recovery was proven from, so every write can be undone by a path that has already run on that temple. It also gives observation over the cable, and a retry costs minutes, not an hour.

Route (a), installing from the phone over stock with no cable (goal 5), comes back after rung 4. By then these are in place: `rescue.bin`, the loader flag clear (G26), Wisp Boot's flag clear (R4-3), its PMIC kick (G16) and image-keyed records (G24).

**R4-1, the change to rule 1 (approved 2026-11-08, now in safety.md).** The exception now ends:

> Its loader tools write MRAM only in the stock main-app region and only with the pinned stock image.

Proposed:

> Its loader tools write MRAM only inside the main-app region `[0x438000, 0x7F8000)`, with one of two images: (i) the pinned stock main image (`recover`), or (ii) a Wisp native image (`install-wisp`) that meets all of the following:
>
> - its SHA-256, and those of its ELF and map files, are pinned in `wisp_w18/pins.py` by a reviewed commit;
> - the tool re-runs every rule-3 check, in both implementations, on the exact bytes it sends;
> - its first 64 KiB (Wisp Boot) are byte-identical to a Wisp Boot build that passed its rung-3 suite on the stock 2.4.0.24 bootloader **and** the patched `87e2d4e0…` bootloader. For the fallback build that is `wisp-fw:boot-test`; the observe-only build has its own suite with its own expected outcomes;
> - `check_rule8.py` passes, and the no-MRAM-write gate passes over `[0x448000, end)`.
>
> Both kinds zero the 16 vector bytes first and write them last, so an interrupted write leaves the bootloader refusing the hand-off instead of running a mix of old and new code. Besides these images, the loader may write one thing more: the documented **clear** record of the update flag, and only by calling the bootloader's own `bootloader_error_reset` from a pinned program (`flag-clear`). Each write needs its own go (rule 4) naming the image hash. The tools refuse in code the install value of the flag, the bootloader region and everything at or past `0x7F8000`. No write runs unless `loader-hello` has read the bootloader CRC `63cd8dda` and a clear flag in the same session (`flag-clear` excepted, which exists to clear a set flag).

In code (built, [Tooling status](#tooling-status)):

- `AppWriter` and `Session._write` take a pin and an end bound, and the image list goes into `pins.py`.
- The SP check uses wisp-ota's strict SRAM bound (`0x20380000`), not `image.py`'s `0x20400000`.
- `--battery` is required, as for `bootloader-install`, plus `--expect <sha256 prefix>` so the operator names the image.

### Tooling status

Built on t3-worker on 2026-11-08, in emulation only (fakes, Unicorn, Renode `w18-test`); nothing ran on hardware. Details in [apps/wisp-recovery/README.md](../../apps/wisp-recovery/README.md#w18-patched-bootloader-and-case-loader) and [recovery.md](recovery.md#tooling-appswisp-recoveryw18py).

- **G1, `w18.py install-wisp`: built; open for native-0 only since W23 (below).** As first built: `pins.R4_1_APPROVED` is `False` and `pins.WISP_IMAGES` is empty, so the command refuses every image before it touches the case; a test keeps the table empty while R4-1 is not approved. Opening it takes a reviewed commit that sets the flag after Jan's approval and pins a built `native-0` (image, ELF and map SHA-256, the `check_rule8` and no-MRAM-write gates) and its Wisp Boot in `pins.WISP_BOOT_PASSED` with both rung-3 suites (stock 2.4.0.24 and patched `87e2d4e0…`). `WISP_BOOT_PASSED` is empty too: the Wisp Boot that passed 26/26 (`8dd8fd69ef4b…`) ran on stock bootloaders only.
  - Checks before the case is touched: the pins above, `--expect`, `--battery` (≥ 80 % or ≥ 3,900 mV), the ELF's MRAM segments against the image, and rule 3 in both implementations: a Python port of wisp-ota's `checkMainPayload` (with two CRC-32 implementations), and wisp-ota's own, run by Node from its build (`pnpm nx run wisp-ota:build`; without it the command refuses). Both suites also run the same 26 vectors offline and must flag the same guards.
  - The writer gates too: `AppImage` refuses any image that is neither the stock pin nor, with R4-1 approved, in `WISP_IMAGES`, whoever builds it. The Renode harness pins its synthetic image in its own process only.
  - In every session, before any write: the `loader-hello` gate (bootloader CRC twice, flag clear, no override); then rule 3 again on the exact bytes the writer sends; the end bound is the image's own end.
  - Renode: `install-wisp` writes a synthetic non-stock image (the stock app with a marker appended, so it boots) through the real patched loader over a running stock app, and the boot ROM's write log shows the vectors zeroed first and written last, every write inside the bound. `install-wisp-cut` cuts the power half way: the vectors read zero, no app runs, the loader answers again, and a second session completes the image. G15 (Wisp Boot and the real app booting behind it) still waits for `native-0`.
- **Vectors zeroed first, also for `recover`: built.** Same CRC gates; a resumed run finds the vectors zero and does not rewrite them. A stopped `recover` now leaves a temple that does not boot until the write is resumed (before, stock over stock left it bootable). In Renode the patched bootloader then logs no hand-off and the loader answers at the next boot (`install-wisp-cut`). **Not yet seen on hardware:** a temple with zero vectors has never booted on silicon. The first `recover` with this tooling should be a deliberate step with its own go, before the change is relied on (a split `recover` passes through that state at every session boundary).
- `recover` keeps its old flag gate (refuse `0x55555555` unless `--allow-pending-flag`). `install-wisp` requires a clear flag, as R4-1 words it. If R4-1 is approved as worded, `recover` should require a clear flag too; that is left to the approval.
- **G5, the split-session status-3 fix: built.** The 13-byte `G2RS` is recognised at once (zero writes), the case record is checked as a zero-write record instead of a route restore, sessions after the first let the case app run 5 s after its banner (about 5 s more per session, so a 280-session split `recover` takes about 23 min longer), and a refused session is retried once after that. [recovery.md, Between sessions](recovery.md#between-sessions-the-pogo-switch-status-3).
- `link-soak`'s progress line counts the running stream (it printed "0 stream exchanges so far").
- **R4-1 in code (2026-11-08):** `pins.R4_1_APPROVED` is `True`. Since W23, `pins.WISP_IMAGES` holds exactly native-0 and `pins.WISP_BOOT_PASSED` its Wisp Boot; a test keeps it so.
- **G4, W20's static analysis: done** ([hardware.md](hardware.md#rung-4-static-analysis-w20-2026-11-08)). `bootloader_error_reset` is at `0x42E156` in the patched image. The loader's precondition is the bootloader's own state. The case's reset is a pulse code on the pogo line, and case 1.2.57 resets a temple that has not answered its `0x13` status poll for 180 s. The NOR record is at `0x2000023C`: it tells GD apart, but MX and an unknown part read the same. The board strap is at `0x20027018`. Step 0's "hardware 5" is the panel's hw_version (JBD4010). Stock skips the touch update when `firmware/touch.bin` is missing, but reprograms the PSoC from a present but different file.
- **G3, `peek` and `pmic_read.bin`: built** ([recovery.md](recovery.md#rung-4-reads-peek-pmic_read-app-check-boot-watch-and-the-held-temple-reset)). `pmic_read.bin` is 504 B, `491f98f5…`. One kick, then 58 allowlisted registers, each by one write-read. The real binary runs under Unicorn, and `peek` and `pmic_read` run in Renode against the real patched bootloader (`w18-test` case `rung4-reads`). **Its first hardware run needs Jan's own go.**
- **G25, `loader-hello --no-release` and `held-reset-test`: built.** The second session's `HELO` must come within 3 s of its relay start and before the PMIC's watchdog could have fired after the first session's last kick, so a PMIC power cycle cannot pass for the case's reset.
- **G2, `app-check` and `boot-watch`: built.** `boot-watch` takes a pluggable `StatusProtocol` (`wisp_w18/status.py`), which must fit the pinned relay's frames: requests of 9, 25 or 32 bytes starting `7E 00 01 n-5`, answers of 13, 21, 29 or 32 bytes framed `5A A5 FF`. Registered: `listen` and, since W23, `wisp` (below).
- **W23 (2026-11-08): native-0 pinned, emulation only.**
  - The reviewed build (commit `8374f9a`) was rebuilt on t3-worker byte for byte: image `5d373fd8874275a3…` (230,428 B), app map `28fcb218…`, Wisp Boot `d793a93e…` in slot `16616d9d…`; the build's `check_rule8` and no-MRAM-write gates passed. The image, the app map, the app ELF after `objcopy --strip-debug` (no paths) and the manifest are committed in `apps/wisp-recovery/wisp_w18/data/native-0/` ([README](../../apps/wisp-recovery/wisp_w18/data/native-0/README.md)) and pinned in `pins.WISP_IMAGES["native-0"]`; Wisp Boot's slot is in `pins.WISP_BOOT_PASSED` with both observe suites (6/6 on stock 2.4.0.24, 6/6 on the patched `87e2d4e0…`).
  - `install-wisp`'s whole gate before the case accepts the committed files and refuses a one-byte change to the image, the ELF or the map (`tests/test_install_wisp.py`). The W23 review's fix to `elf_matches` (it compares section bytes, not the padding between sections) is in.
  - Two CRCs: `app-check` compares the image's own 230,428 bytes, `c0dd9dc0`. `install-wisp`'s final CRC covers the 16-byte-aligned region, whose last 4 bytes keep what was there: over stock 2.4.0.24 it is **`efde0857`**, the value the W24 report must show.
  - `boot-watch --protocol wisp` (`wisp_w18/case_uart.py`): native-0's case-UART status ([case-uart.md](case-uart.md)), a port of the firmware's reference host code, checked against the same golden vectors and against the reference module. It asks IDENT, reads the app's status and Wisp Boot's block (a READ without an answer is asked again), then IDENT until the BLE bring-up has ended, and decodes both blocks into the report. It never sends RESET.
  - `w18.py ble-scan`: read-only, no case, never connects. Lists the Wisp and Even temples advertising near the Mac, with gaps in their adverts (the case's reset, G10b).
  - `wisp-fw:w18-test`: the `native-0` case now installs the committed, pinned files after `native.resolve` accepted them with the repository's pins (no in-process pin), checks the final CRC `efde0857`, and runs boot-watch's `wisp` protocol against the real app. New case **`native-0-recover`**: native-0 runs behind the patched loader, a case reset, the loader's `HELO` is claimed and the temple held, the loader-hello checks, the region's CRC is native-0's, `recover` writes the whole stock 2.4.0.24 main in one session under the armed PMIC watchdog, the CRC over the stock image is the stock pin, and stock boots. Renode resets the whole machine for the case reset; the real pogo waveform is W24's to prove.

### native-0 status (W22)

Built on t3-worker on 2026-11-08, in emulation only (host tests, Renode); nothing ran on hardware and nothing is pinned (that is W23, after review). `pnpm nx run wisp-fw:build-native` builds it (`apps/wisp-fw/scripts/build_native.sh native-0`; details in [apps/wisp-fw/README.md](../../apps/wisp-fw/README.md#native-0)). The image's SHA-256 depends on the commit (the app embeds its git revision); Wisp Boot's does not. The values for the PR head are in the PR and in `.wisp-cache/build/native-0/manifest.json`.

What is in it, gap by gap:

- **G6** the app is linked at `0x448000` (code partition `wisp-app`); `check_image.py --part app` fails it unless its SP and every RAM section stay below Wisp Boot's RAM (`0x20370000`). `build_native.sh` combines Wisp Boot (padded to 64 KiB) and the app, checks the layout and both vector tables (`check_native.py`), runs wisp-ota's own rule-3 guards (`pack-main`: sendable), and writes the manifest (image, ELFs, maps, Wisp Boot's binary and its 64 KiB slot).
- **G7, G27** one watchdog thread at the highest priority, started at `POST_KERNEL` init (before the drivers and `bt_enable()`), feeds Wisp Boot's locked WDT (raw `RSTRT`, also once at `PRE_KERNEL_1`) and kicks the nPM1300 every second, after arming it with stock's own writes (`07 05 0A`, `07 08 00 3C 00`, `07 03 01`, `07 00 01`). It no longer stops the PMIC watchdog. In Renode the app's kicks are never more than about 1.1 s apart, also across reboots, and no power cycle happens.
- **G8** the first BLE session per boot that completed `HELLO` calls `confirm()` through the services table (interrupts locked). Observe-only Wisp Boot only counts it. **For native-1** (the fallback build, whose `confirm()` runs littlefs and a NOR commit): it must run on a thread with a larger stack than the link work queue's 2 KiB and get its own rung-3 case before it is flashed.
- **G9** observe-only Wisp Boot (`-DWISP_BOOT_OBSERVE=ON`, 8,256 B): littlefs built `LFS_READONLY`, no NOR program/erase, no flag write (the code is not compiled in; `check_no_mram_write.py` passes on it, while the fallback build fails it on its one flag write, as it must). It reads the record, the staging preamble, `rescue.bin` (full check) and lists `/firmware/*` with sizes and CRCs, computes the fallback build's decision and publishes it as `would_action`, and always runs the app. Its status block (612 B, CRC-sealed) sits in its RAM; the services table (version 2) points at it. Its UART1 log is compiled out (`-DWISP_BOOT_LOG=OFF`): whether UART1 is powered after the hand-off is unconfirmed on glasses.
- **G10** case-UART status on UART2 ([case-uart.md](case-uart.md)): IDENT, READ (the app's status and Wisp Boot's block) and RESET, shaped for the pinned relay (PR #73), plus stock's `0x24` version query for step 0's bridge. `tests/boot/case_uart.py WispStatus` is the boot-watch hook. **The case app's `0x13` poll is not answered** (G10b below): native-0 in a case whose own app runs is reset about every 3 minutes.
- **G11** W21 confirmed hardware 5 (strap 167 mV) and BUCK1 `VOUT_NORM 0x01` (stock's JBD code, ~1.1 V [I]; never the A6N-G's 0x08 = 1.8 V): the JBD4010 overlay sets 1.1 V, which Zephyr writes as code 0x01, and the baseline check fails any other BUCK1 write. native-0 still keeps the panel off (the pattern is native-1). native-0 also disables MSPI0, the panel's bus (otherwise its driver would drive CLK, CE and data into the unpowered panel at boot). `wisp_g2` has no default panel: every build names one (`WISP_PANEL=jbd4010|a6n-g`, `boards/panels/`, which also set BUCK1's voltage), and the board DTS has no BUCK1 voltage. PR #73 confirmed that step 0's "hardware 5" is the byte `uled_mspi_init` uses, so both temples have the **JBD4010**; native-0 names it and keeps the panel node **disabled**. `cmake/hwimage.cmake` fails any hardware image (`CONFIG_WISP_HW_IMAGE`) with the panel, MSPI0 or any nPM13xx node enabled, or with a test switch set; `check_native.py` checks the same facts again on the app's `.config` and that Wisp Boot links none of the NOR/littlefs/flag write functions, and records both in the manifest.
- **G12, with W21's snapshot** (left temple, 2026-11-08, PR #76) now in `apps/wisp-fw/images/pmic-baseline-w21.json` and checked by `scripts/pmic_baseline.py`: every PMIC write the app makes in Renode (rung 3, `w18-test native-0`) must leave each configuration register at stock's value (only the listed tasks, value 1, besides). native-0's writes match it exactly: the watchdog's `TIMER.CONFIG 0x0a` and target `00 3c 00` are stock's own, confirmed on hardware. The driver test reports what the development build's Zephyr drivers with our DTS would change, and they would: `VBUSIN.ILIMSTARTUP` 0x05 (stock 0x01), `ISET_DISCHG` `cf 01` (stock `9b 00`, a value Zephyr's driver cannot even produce: it offers only 84 and 415 mA), NTC cool/warm LSB 0x00 (stock 0x01), `LDSW.CONFIG` 0x00 (stock 0x30), `BUCK.SW_CTRL` 0x02 on the way to 0x03, and two ADC enables (`TASK_AUTO`, `IBAT_EN`) stock does not set. So the decision below stands with evidence: native-0 runs **none** of Zephyr's nPM1300 drivers. Their init would write SHIP/LPRESET (`mfd_npm13xx.c`), the GPIO1 mode, BUCK2/LDO1 and the whole charger configuration (termination 4.45 V, 96 mA, NTC, VBUS limit) from our DTS, values nobody has compared with what stock programmed; a wrong termination voltage is the one setting that could damage the battery. The power HAL talks to the PMIC directly instead, and its only writes are the watchdog's (above) and the ADC task of one VBAT conversion (`05 00 01`); the charger and VBUS status are reads. Renode checks that allowlist on every PMIC write the app makes. Re-enabling the drivers needs the DTS (and for the discharge limit, the driver) brought to the snapshot, with `pmic_baseline.py` reporting no difference.
- **G13** `check_no_mram_write.py` runs after every app link (symbols, map, Kconfig, raw bytes at every offset, movw/movt pairs): no `am_hal_mram_*`, `nv_program_*`, boot-ROM helper address or program key. `wisp-fw:test` proves it fires (a canary linking `am_hal_mram_main_program`).
- **G15** `wisp-fw:w18-test --only native-0`: install-wisp writes the real native-0 over a running stock app through the patched loader (vectors zeroed first and written last, every write inside the image's bound), under the armed PMIC watchdog with the temple feed; `CONT`; the patched bootloader hands off to Wisp Boot, which runs the app; the app arms the PMIC watchdog and kicks it (no power cycle, nothing else written); Wisp Boot's NOR commands are RDID, RDSR and reads only; the case UART answers (IDENT, both blocks: the stock staging CRC word, 4 firmware files); a RESET over the case UART ends in the loader's `HELO` and a second native boot.
- **Rung 3, rule 12**: `wisp-fw:boot-test` now runs two suites on the stock 2.4.0.24 and the patched `87e2d4e0…` bootloader. **Observe-only Wisp Boot `d793a93e02ba18f7…` (native-0's first 64 KiB): 6/6 on both bootloaders**: the real native-0 over 4 boots (PMIC writes equal to W21's snapshot, the case-UART queries), a recorded "would rescue" it does not act on, a reset-handler fault, a never-fed watchdog, an erased slot, and a GD25LE256H RDID it reports and survives by running the app. **Fallback Wisp Boot `5d2a7be1cd514ad3…`: 28/28 on stock** (the 26 earlier cases plus the real app behind it: it boots, feeds both watchdogs, answers the case UART; never confirming, it is rescued to stock after 3 power cuts) and **reference plus both real-app cases on the patched bootloader**. Its 25 fault and power-cut cases on the patched bootloader did not fit (Renode runs that bootloader about 30× slower here); the fallback build is not in native-0, so that run is due before native-1 is flashed (rule 12: "before it may be flashed"). Details: [apps/wisp-fw/README.md](../../apps/wisp-fw/README.md#rung-3-fallback-to-stock-with-the-real-even-bootloader-wisp-fwboot-test).

Found on the way, worth knowing for W24:

- Every device starts runtime-suspended in this Zephyr build (`PM_DEVICE_RUNTIME_DEFAULT_ENABLE`): UART2 would have stayed off and the case UART deaf. The app now resumes it for good.
- The stock 2.4.0.24 bootloader also programs UART2 at boot (seen in Renode's register log); the patched one is built on 2.3.2.14's. No effect on the app, which reconfigures it.
- Wisp Boot's status block names the NOR part from its own RDID read, which W21's `peek` cannot (it tells only GD from "MX or unknown"). W21 found the MX record (not GD), so **G18 is not needed**; the observe suite still checks that a GD id would be reported and survived.
- The map files hold absolute paths, so the map's SHA-256 (R4-1 pins it) differs between checkouts. W23 should pin the files from the one build it reviews, not rebuild elsewhere and expect the same map hash.

Left open (none blocks W24, each is safe as it stands):

- The watchdog thread feeds unconditionally: native-0 catches scheduler- and interrupt-level hangs (8 s, then the PMIC's 30.72 s), not a stuck main or link thread. A liveness check comes with R4-8.

- **G10b**: answer the case app's `0x13` poll as stock does. Needs stock's reply layout (its `pt_protocol_procsr` handler) and what the case does with the fields; not guessed. Until then: BLE sessions with the temple out of the case, or accept a reset every ~3 minutes in a case that runs its own app.
- The reset over BLE (`SYSTEM REBOOT`): with the update service (W26).
- `/firmware/*` is never written: native-0 has no NOR write path at all; the storage HAL (G19) keeps writes under `wisp/` only, since stock reflashes the touch controller from a `touch.bin` that is present but different (PR #73).
- ~~`install-wisp`'s own gate ran on native-0 only inside `w18-test`, with an in-process pin.~~ W23: it runs on the committed files with the repository's pins, in the unit tests and in `w18-test`.

## 4. Pre-qualification without writing MRAM

The loader can run our code from RAM. The question is what is worth running there.

Under route (b), if the reset test in W21 passes, nothing a native image does to the Apollo510 can stop the loader, because the loader runs first at every boot. The native image is then a safe bench for everything that lives inside the Apollo and goes away with a reset. Pre-qualifying from RAM is worth it only for three things:

- what **outlives a reset in another chip**, which case recovery cannot undo: the PMIC, the NOR content, the EM9305's NVM;
- what **decides the build**: the NOR part, the panel;
- **the loader's own reachability**.

| Candidate | What it settles | How | New temple code | Value | Do it? |
| --- | --- | --- | --- | --- | --- |
| **Reset of a held temple** | whether the case reset works without a running stock app, the premise of route (b) | session 1 claims the temple and ends without `CONT`. Session 2, started within about 10 s (well inside the 30.72 s PMIC window), resets it, and `HELO` must come back within 2 s. Also W20: static analysis of the waveform's `reset_gpio` and of the loader's UART2 precondition | none (a `--no-release` option) | **essential** | **yes, W21** |
| **NOR part** (MX25U25643G or GD25LE256H) | whether Wisp Boot's MX-only driver can work; the old "never older than 2.2.9.22" question | `peek nor`: the bootloader's NOR ops record at `0x2000023C` (W20: `0x4336B0` = GD; `0x4336A0` = MX **or** an unknown ID, whose fallback is the MX record). Only a ≤ 512-byte RDID program would separate MX from unknown | none (`peek`) or one small program | high | **yes, W21** |
| **PMIC register snapshot** | whether Wisp's DTS matches what stock really programmed. PMIC settings outlive every reset, and a wrong rail or charge setting is the one way a native image could **damage** hardware that case recovery cannot undo | a ≤ 512-byte write-read program over the bootloader's IOM7 HAL (the binding `pmic_kick.h` uses), reads only. It covers BUCK1/2 VOUT and enable, LDSW1/2, charger current, termination, enable and trickle, NTC, VBUS limit, the GPIO modes, SHIP/LPRESET, POF, TIMER, and the reset cause / ERRLOG | `pmic_read.bin` | high | **yes, W21**, and at the start of every loader session after a native boot |
| **Panel variant** | which panel driver, and **which BUCK1 voltage** | step 0 already reads "hardware 5" on both temples (`wisp_case/bridge.py:120`, reply byte 12). **W20: it is the byte `uled_mspi_init` uses** (`board_info(1)`, `0x20076D9D`): JBD4010 on both. The snapshot gives BUCK1's programmed code | none | high | **W20 done; BUCK1 at W21** |
| INFOC / DCU (the SWD lock) | whether SWD is open | needs the OTP and CryptoCell domains powered, by a pinned program setting `DEVPWREN` bits | one small program | low now: rule 1 keeps every native write away from the bootloader | optional, R4-5 |
| Wisp Boot's NOR driver and littlefs from RAM | the read path | a **stager** (a ≤ 512-byte program that streams a blob into SSRAM and calls it) plus an SSRAM-linked build of `boot_nor` and littlefs (about 16 KB). It would run in the loader's 4 KiB worker stack, under the bootloader's FreeRTOS, on MSPI1 state the bootloader owns | stager + build variant (M) | medium | **no**: `native-0`'s observe-only Wisp Boot runs the same code in its real context, also without a NOR write |
| Clock and power init, panel init, EM9305 HCI bring-up | the Zephyr port | Zephyr's SoC init cannot sensibly run under the bootloader's FreeRTOS, and a hand-written HCI program would test other code than ships | large | low | **no**: `native-0` with its case-UART status is the bench. Rule 8 holds either way (update and recovery paths compiled out, standard HCI only) |

Tooling needed:

- `w18.py peek`: read-only, an allowlist of SRAM and register ranges, through the pinned `dump`/`dump_fed`.
- `--no-release` for `loader-hello`.
- One pinned program, `pmic_read.bin`, built by `programs/build.sh`. Unicorn (`tests/temple_cpu.py`) proves that it only does write-reads with a 2-byte register address and no data, against a register allowlist. Renode (`WispPmicWdt` on IOM7) runs it too. Its first run on hardware gets its own explicit go: it is a new program talking on the PMIC bus.

## 5. Rule 11 (`rescue.bin`)

**Still needed as a guard against bricking? No.**

- Rule 11 exists because "Wisp Boot without a valid rescue image cannot fall back", and a native app without BLE would then be "an SWD-only repair". Case recovery covers everything `rescue.bin` covers and more: Wisp Boot hanging, a NOR that won't mount, BLE never coming up. It is proven on both temples, and from a native state at W24.
- As written, the rule cannot be met: no stock path writes or reads back an arbitrary littlefs file. Safety.md's "written through the stock OTA file path" is wrong for 2.4.0.24's receiver, which refuses any path but the component type's own.

**Still needed for something? Yes:**

- for Wisp Boot's own fallback;
- for the forced-fault test (exit item 3);
- for any install over BLE, because those go through the staging file and the flag ([§3](#3-how-it-gets-onto-the-temple), the state row);
- for a temple that runs native away from the case and the Mac.

**R4-2: wording** (approved 2026-11-08, now in safety.md):

> 11. **No native flash without a proven way back to stock on that temple.** Before every native write: case recovery (W18 F2) has passed on that temple, the held-temple reset test has passed, and `loader-hello` passes in the same session as the write, before it.
>
> A verified `wisp/rescue.bin` is **also** required:
>
> - before the forced-fault test;
> - before any native install over BLE, together with a `flag-clear` proven on that temple;
> - before a native temple is used away from the case and the Mac.
>
> Verified means: size, preamble and zlib CRC equal the pinned stock main payload of the installed version, as checked on the temple by Wisp Boot's own rescue check (header and full CRC, `image_verify` in `boot_main.c:176`), and reported over BLE or the case UART.

**How `rescue.bin` gets there:** through Wisp itself, in `native-2` (W26–W27).

1. The storage HAL (littlefs on MSPI1, with Wisp Boot's geometry and NOR code) and a file-put in the update service let the Mac send the pinned stock main payload (from the pinned bundle, rule 7). The file-put **writes only under `wisp/`**. The staging file is written only by the update service, after the rule-3 checks. `/firmware/*`, `ota/s200_bootloader.bin` and `boot_count` are never written: stock reflashes co-processors from `/firmware/*.bin` ("reprograms on a mismatch"), so writing those files would get around rules 2 and 8.
2. The app writes the file under a temporary name, checks it with the same code and renames it.
3. Wisp Boot re-checks it at every boot and publishes the result in its status block. The app reports it, and the host compares size and CRC with the pin.

The temple's own fallback code is the verifier, which is what rule 11 asked for. The update service needs authentication before this step (G22), because W27 already writes the NOR over it.

The alternative, a RAM-loaded littlefs writer through the case (a stager plus about 72 minutes of streaming), would be new NOR-writing code with no test bench. Not recommended.

**How Wisp Boot's fallback relates to the case net.** They are layers, and the floor has moved.

- **Case recovery is the floor.** It is proven, covers every failure above the bootloader and needs no NOR and no BLE. It does need the case, the Mac, a person and about 72 minutes.
- **Wisp Boot's fallback is the automatic layer.** It needs no tools, works anywhere and takes minutes, but only for failures after Wisp Boot has run, and only with `rescue.bin` and a working NOR.

With the case as the floor, the "SWD-only" terminal states in [safety.md](safety.md#fallback-to-stock-designed-into-native-mode) become **case repairs**: a missing `rescue.bin`, 4 failed rescues, a crash inside Wisp Boot. The UART2 listener in Wisp Boot ([recovery.md 3e](recovery.md#3e-wisp-boot-listens-on-uart2-our-own-no-bootloader-change)) is no longer needed, because the patched loader does the same job earlier.

## 6. The forced-fault test on hardware

**Preconditions:**

- `native-2` installed and `rescue.bin` verified (W27);
- Wisp Boot kicks the nPM1300 watchdog during long work (G16);
- its records are keyed on the image in MRAM as well as on the staging file (G24);
- it clears the flag after a new install (R4-3, G17).

Why G24: Wisp Boot keys its record on the staging CRC word only (`wisp_boot.c:77`). After F1's rescue the record stays in its rescue state, and the staging file equals `rescue.bin`. A freshly `install-wisp`ed `native-2` would then resume the rescue on its first boot and go straight back to stock; attempts would also carry over from image to image.

Why G16: an Apollo reset never stops the PMIC watchdog. A 3.7 MB rescue copy on the NOR (about 900 sector erases, 14,500 page programs and a re-read CRC) probably takes longer than 30.72 s on hardware [I, not measured]. Without kicks, the rescue would be power-cycled again and again until Wisp Boot gives up after 4 tries.

Each fault image is the passed `native-2` Wisp Boot plus an app built with one `CONFIG_WISP_FAULT_*`. Each is written by `install-wisp`, with its own go. Power cuts cannot be made on a temple, whose PMIC runs off the battery, so they stay covered by rung 3 in emulation.

**Every loader session that releases a native-2 temple counts as a boot attempt.** Three sessions in a row without a `HELLO` in between trigger a rescue. So after every case session, the Mac completes a `HELLO` before the next one, except where a fault test wants the opposite.

| # | Fault | Expected path | How "ends in stock" is shown |
| --- | --- | --- | --- |
| F1 | the app hangs early: no watchdog feed, no BLE | 3 boots ended by the 8 s watchdog → Wisp Boot copies `rescue.bin` to staging and sets the flag → the Even bootloader installs stock → stock clears the flag | **No host action.** Within minutes the temple advertises as stock and the Even app connects. Then read-only through the case: `app-check` gives app region CRC `d9864941` over 3,700,080 B, bootloader CRC `63cd8dda`, flag clear, and `pmic_read` matches the snapshot. Step 0 answers 2.4.0.24 |
| F2 | HardFault in the app's reset handler | as F1: the app's vector table is live, the fault halts, and the locked 8 s watchdog resets | as F1 |
| F3 | the app runs and BLE works, but it never confirms (`HELLO` handler disabled) | Attempts count only at boot, and the app keeps feeding the watchdog. So the three boots come from **three case resets** (host action), then the rescue follows. A "no confirm within N minutes, then reset" rule in the app would make it automatic; that is R4-8, approved | as F1 |
| F4 | a case reset during the rescue copy | the rescue resumes at the next boot and ends in stock | as F1, plus Wisp Boot's report that it resumed. The timing comes from F1's measured copy time |
| F5 | a dead native image with no `rescue.bin`: `native-1` with an erased app part (Wisp Boot's vector check resets at once) | Wisp Boot cannot rescue → **case recovery** | `recover` (about 72 min) ends at CRC `d9864941`, and stock boots: case recovery from a temple in a reset loop |
| (F6) | touchpad rescue hold | only if implemented (Wisp Boot TODO, `boot_main.c:307`) | as F1 |

Between faults, write `native-2` again with `install-wisp` (about 5 min), complete a `HELLO`, and re-check `rescue.bin`.

## 7. Steps and gaps

Step numbers continue W18's, from W19 on. They are steps, not decisions; the decisions are R4-1 to R4-8.

- **RO** = read-only on hardware: no MRAM write, only reads and the usual watchdog kick.
- **W** = writes to the temple.
- **—** = no hardware.

Jan's standing permission of 2026-11-07 covers starting RO runs. Every **W** step needs its own go, and so does the first run of any new temple program.

| Step | What | HW | Needs |
| --- | --- | --- | --- |
| W19 | **Done 2026-11-08:** Jan approved R4-1 to R4-8 | — | this plan |
| W20 | **Done 2026-11-08** ([hardware.md](hardware.md#rung-4-static-analysis-w20-2026-11-08); tools in [recovery.md](recovery.md#rung-4-reads-peek-pmic_read-app-check-boot-watch-and-the-held-temple-reset)). Static analysis, no hardware: **the reset waveform's `reset_gpio` and the loader's UART2 precondition**; the NOR classifier and board-detect results in the patched bootloader's RAM; whether step 0's "hardware 5" is the hw_version byte `uled_mspi_init` uses; how case 1.2.57 treats a temple that doesn't answer its UART protocol (does it reset it, or start a case-UART OTA?); what stock does at boot when `/firmware/*.bin` is missing or wrong; the address of `bootloader_error_reset` in the patched image. Then build `peek`, `--no-release` and `pmic_read.bin` | — | G3, G4 |
| W21 | **Pre-qualification session, left.** `loader-hello`; the **held-temple reset test** (`held-reset-test`); `peek` for the NOR record and the board strap; `app-check`; the `pmic_read` snapshot (its first run with its own go). About 10 min. **Stop the whole plan if the held temple does not come back with `HELO`.** | **RO** | G3, G25 |
| W22 | **Built in emulation 2026-11-08** ([status](#native-0-status-w22)). Build `native-0` and its tooling; emulate: rung 3 for the observe-only Wisp Boot (its own suite) and the fallback build, on the stock and the patched bootloaders, with the real app behind both (rule 12). A `w18-test` case writes `native-0` through the loader into the stock app region, then `CONT` → Wisp Boot → app, with the PMIC watchdog armed and the case-UART status answering | — | G1, G2, G5–G15, G27 |
| W23 | **Done 2026-11-08** (emulation only, [Tooling status](#tooling-status)). Independent review of `native-0` and `install-wisp`; pin the image, ELF and map hashes. Pinned: `5d373fd8…` from commit `8374f9a` | — | W22 |
| W24 | **Ran 2026-11-08, stopped at step 9** ([analysis](#w24-result-and-analysis)). **First native flash, left** ([runbook](#w24-runbook-first-native-flash-left)). `loader-hello` and `pmic_read` → `install-wisp native-0` → `boot-watch --protocol wisp` (`CONT`, then the case-UART status and the `/firmware/*` inventory) → **a BLE advertising scan from the Mac** (`ble-scan`). **Then, the first thing after the first native boot: a case reset and `loader-hello` (stop if it fails), `pmic_read` (diff against W21), and `recover` back to stock (about 72 min).** Stock boots and the Even app works. Exit item 4, from a running native image. *Changed at W23:* no `HELLO` or session from the Mac here. There is no Mac session tool yet (G14), and observe-only Wisp Boot's `confirm()` does nothing, so a `HELLO` would only exercise the call path; that moves to W25, at no safety cost | **W** | W19 (R4-1, R4-2, R4-4, R4-7), W21, W23 |
| W24b | **Next, prepared 2026-11-08 (emulation only).** `stage-0` on the left temple ([runbook](#w24b-stage-0-the-next-hardware-step)): does the hand-off reach code at `0x448000`, do UART2 and the PMIC kick work with our own register sequences, how fast is the LFRC really, and does SRAM keep the diagnostics record across resets. W24b-0 (independent review, then pin): **done 2026-11-09** | **W** (MRAM via the case, twice: install and `recover`) | review + pin (W24b-0, done), G1 |
| W25 | `install-wisp native-1`: the first NOR writes by Wisp Boot, and the JBD test pattern with the gated BUCK1. The first `HELLO` and session from the Mac (G14). 10 confirmed boots, the record read back through the status, a `HELLO` after every session, the PMIC diff at every session. Then F5 (a dead image, then `recover`). **Checkpoint 4a logged.** Gate: W20's answer on missing `/firmware/*`, and W24's inventory matching the pinned bundle | **W** | W24 |
| W26 | Build `native-2`: storage HAL (only `wisp/`), update service (receive, rule-3 checks on the glasses, an allowlist of Wisp Boot hashes and stock, stage, the flag through Wisp Boot's services, reset), file-put, authentication, Wisp Boot's PMIC kick, flag clear and image-keyed record, the loader's `flag-clear` program. Rung 3 reruns with the new cases. A native_sim end-to-end test of the update service; a Mac sender | — | G16–G24, G26, R4-3, R4-6 |
| W27 | `install-wisp native-2` → put `rescue.bin` over BLE → Wisp Boot's check reported OK and equal to the pin. **`flag-clear` proven on hardware**, with the flag already clear and stock staged | **W** (MRAM via the case, NOR via Wisp, the clear flag record) | W26 |
| W28 | Over BLE through the update service: Wisp → Wisp (a version bump: staging, flag, Even bootloader install, Wisp Boot clears the flag); then Wisp → pure stock 2.4.0.24 main; stock boots and the Even app works (**exit item 2**). Then `install-wisp native-2` again | **W** | W27 |
| W29 | Forced faults F1, F2 and F4 (no host action) and F3 (case resets), F6 optional; each ends in stock (**exit item 3**) | **W** each | W27, G16, G17, G21, G24 |
| W30 | The exit check's 10-boot run and 10-minute session, if not already logged at W25 (**item 1**); the final PMIC diff (**item 5**) | **W** (if a reinstall is needed) | W29 |
| W31 | Log rung 4 as passed (or not) in safety.md and README M6. Then the right temple: W21 and W24–W30 with `--side right`, each write with its own go | — / **W** | all |

### W24 runbook: first native flash, left

Prepared on t3-worker on 2026-11-08 and run through in emulation only (`wisp-recovery:test`, `wisp-fw:w18-test` cases `native-0` and `native-0-recover`). **Two steps write MRAM: step 5 (`install-wisp`) and step 11 (`recover`). Each needs Jan's own explicit go** (rule 4); the go for step 5 names the image, `5d373fd8874275a3…`. The other steps are read-only, plus the usual PMIC watchdog kick, and `boot-watch` releases the boot like every session's end. They fall under Jan's standing permission for read-only runs.

**Setup** (rule 6, case session):

- left temple seated, lid open, case on USB, Mac on its charger;
- battery ≥ 80 %, read in the Even app just before, while the left temple still runs stock;
- Even firmware updates declined;
- on the Mac, from the repository root: `git pull`, then `pnpm nx run wisp-ota:build` (`install-wisp` runs wisp-ota's own rule-3 checks from that build);
- every case command runs as `caffeinate -i uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py …`, written `w18 …` below. `ble-scan` runs as `uv run --with bleak==0.22.3 python -I apps/wisp-recovery/w18.py ble-scan …`.

Every case command loads the relay `observed-33-feed` and feeds the temple's watchdog by default. Each must end with relay exit status 6, the route restored and the case back on 1.2.57. Reports go to `apps/wisp-recovery/runs/`.

| # | Command | Expect | Stop if |
| --- | --- | --- | --- |
| 1 | `w18 loader-hello --side left` | bootloader CRC `63cd8dda` twice, flag `0xffffffff`, feed status 0; the temple boots stock | anything else (§8) |
| 2 | `w18 pmic-read --side left --compare apps/wisp-recovery/runs/w18-pmic-read-left-20261108T131013Z.json` | exit 0: no configuration register differs from W21's snapshot | exit 3 |
| 3 | `w18 app-check --side left` | `stock 2.4.0.24 main: … MATCH` (`9c66404b` over 3,700,068 B), flag clear | no match, or the flag not clear |
| 4 | `uv run --with bleak==0.22.3 python -I apps/wisp-recovery/w18.py ble-scan --side left --seconds 30` | a baseline: `stock-left` and `stock-right` advertising, no Wisp | — (informational) |
| 5 | **Jan's go for `5d373fd8874275a3…`**, then `w18 install-wisp --side left --image apps/wisp-recovery/wisp_w18/data/native-0/native-0.bin --elf apps/wisp-recovery/wisp_w18/data/native-0/zephyr.elf --map apps/wisp-recovery/wisp_w18/data/native-0/zephyr.map --expect 5d373fd88742 --battery <N>` (N = the Even app's percentage from the setup) | `install-wisp: native-0 5d373fd887427…, 230428 B`; the session's loader-hello gate; `vectors zeroed`; body written and read back (about 4–5 min); `OK: Wisp native-0 written and verified (efde0857)`; boot released | any `REFUSED` (nothing was sent: do not work around it); any stop during the write (the vectors are zero, the temple stays in its loader and boots nothing: send the report, and resume with the printed `--resume-at` or `recover` only with a new go); a final CRC other than `efde0857` |
| 6 | `w18 boot-watch --side left --protocol wisp --watch-s 60 --interval-s 0.1` (at once after 5) | no `HELO` after `CONT` (no reboot). `IDENT: Wisp … kind 0, stage bt-up`, flags with `pmic-wdt`, `boot-services`, `boot-status`, `boot-observe`. App status (read again once the bring-up has ended; the earlier read is `status_early`): rev `8374f9a62d`, PMIC kicks above `status_early`'s, PMIC errors 0. `uptime` and `sessions` cross a 17-byte READ boundary and can be torn by a few ms or one count. Wisp Boot: observe True, NOR id `0x3925c2` (MX25U25643G) result 0, mount 0, action `run-app`, staging present `971f4516` (= stock 2.4.0.24) [I], `/firmware`: `codec.bin`, `ble_em9305.bin`, `touch.bin`, `box.bin` with the installed bundle's sizes. **Write down the battery mV** (rule 6's native threshold, ≥ 3,900 mV, is calibrated against it) | see below |
| 7 | `uv run --with bleak==0.22.3 python -I apps/wisp-recovery/w18.py ble-scan --side left --seconds 60` (at once after 6) | `OK: 1 Wisp advertiser(s)`: name `Wisp` or service `cf099bf1-f34e-49e2-b353-7f20e02243bc`; `stock-left` gone. A gap in its adverts is the case's reset (G10b, below), not a failure | — (no Wisp advertiser is a finding, not a stop: go on to 8) |
| 8 | `w18 loader-hello --side left` (**the first case reset of a running native temple**) | `HELO` within the relay's window, CRC `63cd8dda` twice, flag `0xffffffff` | no `HELO`: reseat once and rerun; **fails twice after a reseat: STOP**, write nothing, send the reports (the floor is in question, §8). A CRC other than `63cd8dda`: STOP, do not reset again |
| 9 | `w18 pmic-read --side left --compare apps/wisp-recovery/runs/w18-pmic-read-left-20261108T131013Z.json` | exit 0. native-0 arms the watchdog with stock's own values, so only status registers may differ | exit 3: STOP before `recover`, send the report |
| 10 | `w18 app-check --side left` | `Wisp native-0: … MATCH` (`c0dd9dc0` over 230,428 B), flag clear | no match, or the flag not clear |
| 11 | **Jan's go for `recover`**, then `w18 recover --side left --image .wisp-cache/stock/g2-2.4.0.24.bin` | one session, about 72 min; `vectors zeroed`, then body, CRC, vectors; `OK: stock 2.4.0.24 main app written and verified (d9864941)`; boot released | as F2 in [recovery.md](recovery.md#step-by-step-for-jan-mac-left-temple-first): a stop prints `--resume-at N` (it needs a new go); a `resume check failed` or any other stop: send the report as it is |
| 12 | `w18 app-check --side left`, then `uv run --with bleak==0.22.3 python -I apps/wisp-recovery/w18.py ble-scan --side left --seconds 30` | `stock 2.4.0.24 main: … MATCH`, flag clear; `stock-left` advertising. Jan: the Even app, Lotti, touch and the microphone work on both temples | anything else; misbehaviour after the return to stock stops the plan before the right temple (§8) |

Then a hardware-log row: **"rung 4 W24 (checkpoint 4a, part)"**, with the reports of 1–12, the battery mV of step 6 and the final CRCs `efde0857` and `d9864941`.

**Step 6 in detail.** `boot-watch` observes the **second** native boot. `install-wisp` ends its session with `CONT`, so native-0's first boot runs unobserved, and `boot-watch`'s relay start resets the temple again.

- A `HELO` after `CONT` means the temple rebooted (a crash, the 8 s watchdog, the PMIC's power cycle). Note when, and go straight to step 8.
- `stage bt-failed` (the EM9305 did not come up under Zephyr, W11's known risk) is not a stop. It is a finding. Step 7 will then find no advertiser. Go on to 8.
- No answer at all to IDENT for 60 s: the app is not running, or UART2 is deaf. Go to step 8.
- `boot_error` with a CRC mismatch: Wisp Boot's block is not to be trusted. Record it and go on.
- A `HELO` in the middle of the watch resets what the protocol read so far (`reboots_reset` in the summary), so the summary is the last boot's.
- **Stop (§8)** if the status shows that the NOR fails to mount, or a NOR id other than MX: the observe-only Wisp Boot never writes the NOR, but stock will mount and format it after `recover`. Send the report and wait for Jan's decision before step 11.

**The case's `0x13` poll (G10b) in this sequence.** Case 1.2.57 polls each seated temple with opcode `0x13`, and native-0 does not answer. After a temple has not answered for 180 s, the case resets it, and then every 180 s ([case-uart.md](case-uart.md#the-case-apps-0x13-poll-not-answered-by-native-0)).

- During a relay session (steps 5, 6, 8–11) the case runs our relay, not its app: nothing polls and nothing resets. This also holds for `recover`'s 72 minutes.
- Between sessions the case app runs. From the end of step 5's session on, the native temple is reset about every 3 minutes. Each reset goes through the patched loader (its `HELO` unanswered) into native-0 again. That is harmless: the loader runs first, observe-only Wisp Boot writes nothing, and the PMIC watchdog stays armed and kicked.
- So: run 6 right after 5 and 7 right after 6, and keep step 7 to 60 s. A gap of a few seconds in step 7's adverts (`gaps`) is such a reset. Don't pause the sequence with the temple native in the case. If a pause happens anyway, expect the resets, and expect the right temple and the Even app to complain about the left; neither is a stop.
- Each reset is also a fresh boot. Reboots seen between sessions say nothing about native-0's stability.

**Stop conditions, all of them** (with §8's general list):

- `loader-hello` fails twice after a reseat (step 1 or 8), or reads a bootloader CRC other than `63cd8dda` (then don't reset the temple again);
- the flag reads anything but `0xffffffff`;
- `pmic-read --compare` exits 3;
- `install-wisp` refuses, stops, or ends with a CRC other than `efde0857`;
- `recover` stops on a CRC mismatch or a refused resume check;
- a native boot's status shows the EM9305 update or recovery path ran (rule 8's gates make that impossible);
- after the return to stock, the Even app, Lotti, touch or the microphone misbehave;
- the case doesn't come back on 1.2.57, or a relay exit status other than 6;
- the temple gets warm;
- anything the expected output above doesn't describe (W18's rule).

**What W24 proves, and what it leaves.** It proves the first native write and boot on silicon, the case UART from a native app, the NOR read path (known answer: the staging CRC word and the inventory), the case reset of a running native temple, and `recover` from it (exit item 4, first half). It leaves for W25: `HELLO` and a session from the Mac (G14), confirmed boots and NOR writes.

### W24 result and analysis

Written on t3-worker on 2026-11-08, after W24. **No hardware was touched for this section.** It uses the W24 reports as Jan's session summarised them ([hardware log](safety.md#hardware-log), PR #79), the code at `e32aff9`, the pinned native-0 files, and static analysis of the stock 2.4.0.24 main app and the patched bootloader. The Even binaries were disassembled from the git-ignored `.wisp-cache/` and are not committed. Tags as above: **[C]** confirmed (code, binary, log), **[I]** inferred, **[?]** open.

**In one paragraph.** native-0 was written and verified (`efde0857`), and the patched loader still answered afterwards. The case reset of a native temple works, so the floor held. On silicon the image reboots about every 10.4 s, never answers on the case UART and never advertises. The reboots are Wisp Boot's locked Apollo watchdog [I, strong]. Nothing fed it for its whole period, so **the app stopped scheduling threads very early in its start-up, before its first PMIC transaction**. This much follows from the PMIC's own record, below. Where it stopped cannot be told from what W24 recorded. The two leading candidates, ranked below, are a fault early in the Zephyr start-up, and a failed PMIC write whose error log spins on the UART1 console inside the watchdog thread itself. **The PMIC at its power-on values is explained without any write by Wisp:** native-0 never kicked the nPM1300's watchdog (stock had armed it, 30.72 s). It fired 30.72 s after the tool's last kick, power-cycled the PMIC, and the PMIC came back at its reset values. native-0 by design programs nothing on the PMIC, and it never got as far as re-arming the watchdog. The next image must therefore be one whose failure can be **seen**. The diagnostics below are the main deliverable.

#### What was observed

- [C, W24 reports] Step 5 passed (vectors zeroed first and written last, final CRC `efde0857`). Step 6 `boot-watch --protocol wisp`: zero answers to IDENT at 0.1 s intervals for 60 s. The loader's `HELO` came at t = 9.9, 20.3, 30.7, 31.7, 42.0, 52.4 and 62.9 s after `CONT`; t counts from the confirmed `CONT` (`status.watch`, `cli.py:637-640`), and the tool's last `feed.bin` kick came before `CONT` in the same session. Step 7: no Wisp advertiser in 60 s. Step 8: `loader-hello` passed (relay status 3 on the first try, then `HELO` after the G5 settle). Step 9: 23 configuration registers differed from W21.
- [C] The intervals are 10.4, 10.4, (1.0), 10.3, 10.4, 10.5 s. [I] The first `HELO` after `CONT` comes about 0.5 s sooner than the steady period. That 0.5 s fits the loader's `HELO` window (drdaeman's 500 ms), which `CONT` skips and an unanswered `HELO` waits out.
- [I] The extra `HELO` at 31.7 s is about 1 s after 30.72 s, the nPM1300 watchdog's period counted from the tool's last kick before `CONT`. It fell inside the boot after the 30.7 s reboot.
- [C] Step 2 (`pmic-read` after step 1's case reset of a stock temple) found 0 differences, so the case's reset waveform does not reset the PMIC. Only the PMIC's own watchdog (or a power loss) does.

#### (b) The PMIC at its power-on values

**Root cause: the nPM1300's own watchdog power cycle. No write by Wisp caused it.** [I, strong]

- Stock arms the nPM1300 timer as a 30.72 s reset watchdog. An Apollo reset does not stop it (W18 F1c, hardware.md). After `CONT` nothing kicked it, and it fired on schedule at about 30.7 s. That is the 31.7 s `HELO`.
- A watchdog reset is a full PMIC reset. The snapshot afterwards matches the part's reset state: the timer off (`TIMER.CONFIG 0x00`, target 0), `BUCK.SW_CTRL 0x00` (the BUCKs follow their VSET pins, not the `VOUT_NORM` registers), the charger disabled (`BCHGENABLE 0x00`) with its reset currents and termination, `VBUSIN.ILIM 0x01`, the load switches off (`LDSW.STATUS 0x00`), GPIO1 back to its default mode, `ADC.NTCR_SEL 0x01`. [I: the values match the reset state; checking each against the nPM1300 product specification's reset column is [?]]
- [C, code] Nothing in Wisp could have written those registers:
  - Wisp Boot has no I2C code at all.
  - native-0's only PMIC writes are the watchdog's (`07 05 0A`, `07 08 00 3C 00`, `07 03 01`, `07 00 01`, kicks `07 04 01`) and the ADC task `05 00 01` (`power.c`; enforced in Renode against W21's baseline on every write).
  - No SHIP, hibernate, reset or other TASK register is written. The arming bytes are stock's own, and the kick `07 04 01` is what `feed.bin` has sent in every case session since W18 F1d without a reset.
- [I, strong; it rests on the reading above] **native-0 never armed the PMIC watchdog in any boot after the power cycle.** `pmic_wdt_arm()` is the first PMIC transaction of every native boot, and it would have left `TIMER.CONFIG 0x0a`. At step 9 it read `0x00`, after at least three boots in boot-watch and more during step 7's minute. [I] It did not kick in the three boots before the power cycle either: the PMIC fired on the tool's schedule, and any kick from the app would have pushed it back by the time from `CONT` to that kick, more than a second of slack the `HELO` times do not show.
- **Consequence while native:** after the power cycle the charger is off and the PMIC watchdog is disarmed. BUCK2 also really moved: `BUCK2.VOUT_STAT 0x15→0x08` is the rail's status, not only its setting [C, W24 snapshot]. What BUCK2 and the load switches supply on the G2 is [?].
  - A temple left on native-0 in this state does not charge in the case [I]. It drains in its 10 s reboot loop, and only the Apollo watchdog resets it.
  - Stock programs the PMIC at boot (Renode: 71 distinct PMIC writes after a release), so `recover` restores it [I].
  - **Done, 2026-11-08 17:46–18:59 UTC:** `recover` ran on Jan's go ("Both temples cold. You may go on."; the temple had been full at 16:56 UTC) in one session, final CRC `d9864941`. `pmic-read --compare` against W21 about 60 s after the stock boot showed **0 config, 0 watchdog and 0 status differences** [C]: stock reprograms the PMIC at boot, as expected. Both temples advertised at 19:01 UTC (hardware log, W24 row).
  - The next images keep the charger off after a PMIC power cycle too, unless they prevent the power cycle itself (fix plan, item 3). The PMIC's own `ERRLOG` (reset cause) would have confirmed the watchdog reset directly. `pmic_read.bin` does not read it yet (its offsets were never checked, recovery.md).

#### (a) The reboot loop: what the evidence says

The reboot is Wisp Boot's watchdog [I, strong]:

- [C] Wisp Boot arms and locks the Apollo WDT with `CLKSEL = 2` (LFRC/64) and `RESVAL = 128`, then feeds it in its NOR loops. The register layout and keys (`CFG` 0x0, `RSTRT` 0x4 = `0xB2`, `LOCK` 0x8 = `0x3A`, `RSTGEN.CFG.WDREN` bit 1) match hal_ambiq's `apollo510.h`.
- [C] The same header gives the LFRC as "approximately 900 Hz", not 1024 Hz (`STIMER_STCFG_CLKSEL_LFRC_NOMINAL`, "LFRC=900Hz"). [I] So Wisp Boot's "8 s" is **probably about 9.1 s on silicon**. The LFRC is uncalibrated, so the real figure is for stage-0 to measure (WDT `COUNT` against the STIMER). Renode's `WispWdt` (1024 Hz) runs it at 8.0 s.
- [I] Steady period = loader window 0.5 s + the loader and bootloader up to the hand-off + time from the arm to the last feed + 9.1 s + reset to `HELO` (SBL, bootloader init with its NOR scan and `boot_count` write). With the period at 10.4 s, **the last feed came at most about 0.5 s after Wisp Boot armed the WDT**. Even at 1024 Hz it would be under 2 s. native-0's watchdog thread feeds every 10 ms until I2C7 is ready and every second after that, so it cannot have run for more than a moment.
- [?] The reset cause itself (`RSTGEN.STAT.WDRSTAT`) was not read. native-0 captures it into its status (`capture_reset_cause`), but nobody could read the status.

Where the app stopped [I]. The native-0 init order, from the pinned ELF's `initlevel` table:

1. `z_arm_reset` → `z_prep_c` (VTOR, CPACR, bss, data, ITCM copy) → `soc_early_init_hook`: `am_hal_pwrctrl_low_power_init` (INFO1/OTP and trim reads, the spot manager, crypto power-down, memory configuration), the **SIMO buck enable**, `am_hal_pwrctrl_temp_update`, caches on.
2. PRE_KERNEL_1: `early_feed` (WDT restart), `capture_reset_cause`, the GPIO banks, **UART1 (console) and UART2**, `uart_console_init`.
3. PRE_KERNEL_2: `stimer_init`.
4. POST_KERNEL: `early_watchdogs` creates the watchdog thread (highest cooperative priority): it feeds, finds I2C7 not ready and sleeps 10 ms. Then I2C on IOM2/4/5, SPI on IOM6, **I2C7 (the PMIC)**, the BT HCI device and the sensors. Then `main()`, which starts the case UART first.

The watchdog thread preempts init and `main` (both preemptible) whenever its 10 ms or 1 s sleep ends. A spin with interrupts enabled there, a stuck UART `poll_out` included, therefore does not stop the feeding. A spinning **cooperative** thread does stop it: the system work queue (priority −1), the BT host threads, or the watchdog thread itself. I2C transfers are polled (`am_hal_iom_blocking_transfer`, IOM7 has no `dma-mode`) with bounded waits, so a dead bus alone returns an error. But the error is logged, and with `CONFIG_LOG_MODE_MINIMAL=y` a log line is a direct `printk` to the UART1 console from the calling thread. For the WDT to fire *and* the PMIC never to be armed, one of these must hold:

| # | Hypothesis | Fits | Against / open | Rank |
| --- | --- | --- | --- | --- |
| H1 | **A fault (or a stop with interrupts locked) during the Zephyr start-up, at the latest within ~10 ms of I2C7's init.** Zephyr's default fatal path is `arch_system_halt`: a spin with interrupts locked, no reset, no output the case can see (the console is UART1). Silicon-only candidates are everything Renode does not model or models as "reads 0, writes ignored": the Ambiq SoC init in step 1 (INFO1/OTP reads, trims, spot manager, SIMO buck, the `temp_update` path), the PRE_KERNEL_1 pin and UART set-up, and the clock manager running on hal_ambiq's defaults (the board has no `board.c`, so `XTAL_HS` is "24 MHz crystal" and `XTAL_LS` "external clock") | every observation: no feed after the first ~0.5 s, no PMIC arm, no IDENT, same period in every boot | which step faults is unknown. Stock runs comparable AmbiqSuite code on the same chip and reaches its tasks. A difference in HAL version or in the order of calls is plausible but not shown | **1** |
| H1b | **Two silicon-only faults together: I2C7 fails (pins, pad function or pull-ups; the bootloader's own IOM7 HAL works, Zephyr's pinctrl for it is untested), and UART1 does not drain (pads unverified, README "Unverified on the G2").** The first PMIC write (the kick in `pmic_wdt_arm`) fails, and `i2c_ambiq` and `power.c` log it. That `printk` runs **in the watchdog thread**, the highest cooperative thread, and spins in `poll_out` on a full TX FIFO with no timeout. Nothing else runs: no feed, no arm, no `main`, no IDENT | every observation, and both parts are listed as unverified on the G2. Neither can happen in Renode (the IOM model answers, the UARTs drain at once) | needs two faults at once. [C] UART1 stuck alone would hang the boot banner in `main`'s thread with interrupts on: the feeder would keep feeding and arm the PMIC. I2C7 failing alone: the feeder logs, the log drains, the feeding goes on | **1** (with H1) |
| H2 | **The system timer never fires** (STIMER compare interrupt not delivered, or the counter not counting): the watchdog thread feeds once at POST_KERNEL and never wakes from its 10 ms sleep, so it never arms the PMIC. `main` may run on, but the case thread sleeps on its first empty poll and never answers | every observation | [C] stock and the bootloader clock the STIMER from the same source (`STCFG` `…\|0x103`, `XTAL_32KHZ`, compare A; stock's call at `0x45887C`, the bootloader's at `0x41B74C`). The bootloader's FreeRTOS delays work on silicon (the 500 ms `HELO` window). The clock manager does not manage `XTAL_LS` in this HAL (`AM_HAL_CLKMGR_MANAGE_XTAL_LS` is commented out). So a dead 32 kHz clock is unlikely; a wrong STIMER IRQ number or priority in the DTS is untested on silicon | **2** |
| H3 | **Wisp Boot never hands off**: it locks up after the arm. A plain fault would reset at once through its `fault_handler` (SWPOR), giving a ~1.5 s loop, not 10.4 s | the period | every NOR wait is bounded (`TIMEOUT` loops, about 0.1–0.3 s each), every NOR error ends in `run-app-degraded`, and the observe build has no writes. It needs a lockup (a fault while stacking). In Renode it ran behind the same real bootloader | 3 |
| H4 | The feed write has no effect on silicon | the period | [C] layout and key match the header, and the arm, using the same addresses, evidently worked | 4 (ruled out as far as statics can) |
| — | EM9305 / `bt_enable()` | — | comes after the PMIC arm (POST_KERNEL I2C7, then `main`). Ruled out as the first failure by the PMIC evidence | out |
| — | UART1 console stuck (pads unverified) | could explain silence on UART1 | `poll_out` waits for FIFO space **with interrupts enabled** (`uart_ambiq.c:484-486`), so the watchdog thread still runs. Not sufficient alone | out as sole cause |
| — | SSRAM/TCM unpowered | — | [C] the HAL's default memory configuration powers all 3 MiB of SSRAM and ITCM 256K / DTCM 512K. Wisp Boot ran on the top 64 KiB of SSRAM. Stock and the bootloader also execute HAL helpers from ITCM (`bl 0x40`, `bl 0x48`) | out |
| — | FPU disabled by `z_prep_c` (CPACR cleared) while the HAL takes a `float` | — | [C] the app contains no VFP or MVE instruction (`CONFIG_FPU=n`, soft-float) | out |

The hand-off state is the other thing Renode reproduces only as well as its models [C, bootloader `0x42E13A`/`0x42DFD8`]:

- The patched bootloader jumps from inside its DFU **task**: Thread mode on PSP (its `ldr sp, [r0]` sets the active stack, PSP), with its PSPLIM/MSPLIM. Stock and the bootloader both set MSPLIM/PSPLIM to `0x2007D000` first thing (stock `0x5FBE3E`, bootloader `0x432CA2`); Zephyr's stacks lie above that (`z_interrupt_stacks` at `0x2008F3A0`), so a stale limit is probably harmless [I]; where the DFU task's stack lives is [?]. Its de-init is `cpsid i` and three calls (`0x41F8BA(1)`, `0x41BA80(1)`, `0x41C990`) not decoded further [?]. The bootloader never references SysTick [C]; whether it leaves caches or the MPU on was not checked [?].
- Wisp Boot keeps all of that, clears and un-pends the NVIC, and jumps with `cpsie i`. It does not clear a pending PendSV or SysTick in `ICSR`.
- Zephyr's `__start` sets MSP and PSP and ORs SPSEL into CONTROL. It does not reset CONTROL, PSPLIM or MSPLIM. `CONFIG_INIT_ARCH_HW_AT_BOOT` is off, so it does not reset the MPU, caches or SysTick either.
- None of this differs between Renode and silicon as far as the bootloader is concerned. It is listed because it is the part of the hand-off that no test has varied.

**Why Renode did not catch it.** [C, models and harness]

- Outside the modelled blocks (g2emu's CLKGEN/RTC, PWRCTRL, UART1 and IOM, and Wisp's models), the peripheral windows are plain memory (`periph_lo0…periph_hi2`, `MappedMemory` in `wisp_g2.repl`/`wisp_g2_boot.repl`): a register reads back what was last written, or 0, and nothing happens. So trims and INFO1/OTP reads, the SIMO buck, the spot manager, the clock manager's stabilisation flags and the cache set-up all "succeed" by construction. Renode never runs the silicon side of step 1.
- `WispWdt` runs the LFRC at 1024 Hz (8.0 s); silicon is probably about 9.1 s.
- `WispPmicWdt` is armed by the harness. It logs the app's arming writes but does not act on them, and a power cycle is a harness event, not a register reset. A PMIC that came back at its reset values would not have been visible.
- The STIMER model counts whatever its clock source. The EM9305 is not modelled, so every bring-up ends quickly in `bt-failed`. The UARTs drain at once and have no pads.
- `WispRstGen` models `CFG`, `SWPOI` and `SWPOR` but not `RSTGEN.STAT`, so `reset_cause` says nothing in emulation.
- W22 already said it (G15): Renode "cannot catch state that persists on silicon". Rung 3 proves the fallback logic. It does not prove the Ambiq start-up on this board.

#### Fix plan for the next image

There is no fix that the evidence points at directly. Changing the start-up blindly, flashing, and watching the same silence again would cost a `recover` (about 72 min) each time. **The next two images exist to locate the failure.** Each is a W24-style session (`install-wisp`, `boot-watch`, case reset, `pmic-read`, `recover`), and each write has its own go.

1. **`stage-0`: Wisp Boot (observe-only, plus D1 and D2) and a bare-metal app of a few KiB, with no Zephyr and no Ambiq HAL init.**
   - The app feeds the Apollo WDT and kicks the PMIC watchdog (as built: it only kicks, `07 04 01`, and never arms it) with stock's bytes over a polled IOM7, reusing `pmic_kick.h`'s register sequence (not the bootloader's HAL).
   - It answers IDENT and READ on UART2, polled, with the same frames as native-0.
   - It reports `RSTGEN.STAT`, the STIMER counter read twice 100 ms apart (proves the 32 kHz clock) and the LFRC measured against it (the real WDT period).
   - **If it answers:** the hand-off path, UART2, the PMIC on I2C7 (our own register sequence) and the STIMER clock are proven on silicon, and the failure is inside Zephyr or HAL start-up (H1, H1b, H2).
   - **If it does not:** Wisp Boot or the hand-off (H3) is the suspect, and D1/D2 say where.
   - About 4 KiB, so `install-wisp` takes under 3 min. Its PMIC writes are a subset of native-0's.
2. **`native-0b`: native-0 plus D1–D5 in the app.** Breadcrumbs at every init step in the order listed above, including each call inside `soc_early_init_hook` (Wisp carries that hook's replacement through its fork patch if needed) and before and after the first PMIC transfer. A fatal-error handler that records the fault and resets at once (D3). A STIMER liveness check (D5). With these, one flash names the failing step.
3. Independent of the diagnosis, **in native-0b already**:
   - Remove the UART1 console from hardware images (`zephyr,console` unset, UART1 disabled, logging off or to a RAM buffer). Its pads are unverified, the case cannot see it, and under H1b it is what turns a failed I2C write into a dead temple. Breadcrumbs go to RAM and UART2 instead.
   - Feed the Apollo WDT only from code that cannot block or log: a short feed-only path (a `k_timer` callback, plus a feed before each PMIC transfer), with the PMIC traffic and its error handling in a separate thread. The watchdog thread must never `printk`.
   - **Kick the PMIC watchdog first thing at every boot** (G16, brought forward: in Wisp Boot, through a polled IOM7 write with `pmic_kick.h`'s sequence and stock's bytes). An Apollo reboot loop then keeps re-kicking, the PMIC watchdog never expires, and the PMIC keeps stock's configuration, the charger included. W24's PMIC reset came only because nothing kicked. The price: a temple stuck in an Apollo reboot loop no longer gets the PMIC's harder power cycle, and the loop is reset only by the case or the Apollo WDT. That is acceptable on the bench, where the case is always at hand. The new PMIC write path needs Renode's byte-level allowlist (only `07 04 01`) and its own rung-3 cases.
   - Wisp Boot clears `ICSR.PENDSVSET`/`PENDSTSET`, disables SysTick, and hands over in Thread mode on MSP with PSPLIM/MSPLIM zeroed. That is the state Zephyr assumes at reset. Each such change reruns rung 3 (rule 12).
   - Correct the documented WDT period to about 9.1 s (LFRC ≈ 900 Hz) wherever "8 s" is used for timing, and recheck the 25.72 s held-reset margin and G16's assumptions against it.
4. After the failing step is known: fix it (most likely a board-specific clock or power setting for the Apollo510B that stock sets differently, found by diffing stock's start-up against Zephyr's for that step), rerun rung 3 and `w18-test`, then pin it as native-0 again (W23's way) for a new W24.

#### Diagnostics the next image must carry

The goal: any failure on silicon leaves a reading the case path can fetch, through mechanisms with no dependency on the failing code.

- **D1, the reset-cause and breadcrumb record (RAM, read by the next boot and by the loader).**
  - A 64-byte record at a fixed address outside every RAM range the SBL and the bootloader use. A candidate is a `NOLOAD` slot at the start of Wisp Boot's own RAM (`0x20370000`), which its `reset_handler` neither copies nor zeroes; check in Renode that neither the bootloader nor stock writes it, and add the check to `w18-test`. It holds magic, version, CRC, a boot counter, the last stage code and its STIMER time, and the last fault (PC, LR, xPSR, CFSR, HFSR, BFAR, MMFAR, EXC_RETURN).
  - Wisp Boot first copies the previous record into its status block (`prev_*` fields), then records `RSTGEN.STAT` and starts a fresh record. [I] The SBL and the bootloader only read `RSTGEN.STAT` (POASTAT at bootloader `0x41ACB6`/`0x41C4C2`; stock stores it as its reset cause at `0x5055FC`), so it should still hold the cause when Wisp Boot runs. [?] Whether SRAM survives a WDT reset or SWPOR on this chip (hardware.md "still open"). The record's magic and CRC tell.
  - `peek` gains a read-only region for the record and for `RSTGEN.STAT` (`0x4000885C`, [C] the header's offset): host code only, no new temple program, readable in the loader-hello session right after the failure. A `peek` of `RSTGEN.STAT` shows the case reset that started that session; it shows the earlier cause only if STAT accumulates across resets [?]. So D1 and D2 must carry the cause; the `peek` is a cross-check.
- **D2, a boot report from Wisp Boot on UART2.**
  - The relay carries only request/answer pairs (requests of 9, 25 or 32 bytes starting `7E 00 01`; answers of 13, 21, 29 or 32 bytes framed `5A A5 FF`), at about 17.5 ms per exchange. Wisp Boot's full block is 612 B, 36 READs, about 0.63 s. So the report must be small: **one IDENT-sized answer** (27-byte payload, a new "boot report" kind) with `RSTGEN.STAT`, D1's previous last stage and its time, the previous fault's PC, LR and CFSR, the boot counter, and this boot's NOR result.
  - After it arms the WDT, Wisp Boot polls UART2 and answers that request. Its window stays open until about 100 ms after the last request it answered, with a cap (about 300 ms with no request at all), so a boot without a host loses almost nothing.
  - `boot-watch` gets a `boot-report` mode that sends the request on **every** exchange (not once a second as `WispStatus` does today), from the `CONT` on. Every boot in a reboot loop then reports **why the previous boot ended and how far it got**, with or without a working app.
  - Cost: a polled UART2 driver in Wisp Boot (pins 42/44, 1 Mbaud, re-initialised in full rather than trusting the loader's state), a new reply kind in `case_uart.py` and the firmware codec with golden vectors, and the rung-3 reruns.
- **D3, in the app: a fatal-error handler that resets.** `k_sys_fatal_error_handler` (and an early fault vector before the kernel is up) writes the fault into D1 and resets at once by SWPOR. A fault then shows as a short reboot loop (about 1.5 s) with its PC in the next boot report, and a hang keeps the WDT's 10.4 s. The period separates a fault from a hang, not H1 from H2: H1 also covers a stop with interrupts locked, and H1b is a spin.
- **D4, breadcrumbs in the app.** A one-word stage code written to D1 at each step:
  - each call inside `soc_early_init_hook`;
  - every init level, and every device init, by a wrapper around `z_sys_init_run_level` or an `EARLY`-level hook that steps through the table;
  - `stimer_init`, and a second STIMER read 10 ms later (D5);
  - the watchdog thread's first run, I2C7 ready, the PMIC armed, `main`, the case UART up, BT start and end.

  Last value wins, and the cost is a few cycles each. The stage code is also in the case-UART status.
- **D5, STIMER liveness.** At the end of PRE_KERNEL_2: the counter must advance across a 1 ms `am_hal_delay_us`. If it does not, record it in D1 and drop into a busy loop that feeds the WDT and **polls UART2 itself** to answer the boot-report and IDENT requests (the case thread would sleep forever on a dead timer). The image then stays observable instead of rebooting.
- **D6, the nPM1300 reset cause.** Add `ERRLOG` (RSTCAUSE and the charger error registers) to `pmic_read.bin` once their offsets are checked against the product specification [?]. That is a new pinned program: review, Unicorn/Renode tests, and Jan's go for its first run. It turns "consistent with the reset values" into "the PMIC says watchdog".
- **D7, session practice.** `boot-watch` in `boot-report` mode from `CONT` on, switching to `wisp` once the app answers IDENT. In step 8's session, a `peek` of D1 before anything else. Nothing on the temple sends unsolicited frames, so `listen` would only block on the relay's poll bound (about 18 s, `links.py`).

Not recommended: Apollo `MCUCTRL.SCRATCH0/1` as a breadcrumb store (SCRATCH0's top bits carry the OEM-recovery retry magic, which Ambiq's `soc.c` checks and clears), and the STIMER's `SNVR0/1` (epoch storage; whether stock uses them is unchecked [?]).

#### Renode changes that would have caught it, or made it visible

- **Strict start-up mode for `w18-test` and the boot suites.** From `CONT` until the app's first case-UART answer, every access to the plain-memory peripheral windows (registers without a model) is logged with PC, address and value, and the run fails unless the access is on a reviewed allowlist. Each allowlist entry names what stock does with the same register (static analysis), so the silicon-only start-up path becomes a reviewed list instead of a silent "reads 0".
- **`WispWdt` at about 900 Hz,** with a `--lfrc-hz` sweep (for example 800–1100) in one case, so no test depends on "8.0 s".
- **`WispPmicWdt` holds registers:** the arming writes act on the model, a watchdog expiry resets every register to the product specification's reset values and sets `ERRLOG`, and `pmic_read` in `w18-test` reads them. A boot that never arms the PMIC then fails a check ("no PMIC kick within N s of `CONT`"), instead of being fed by the harness.
- **Liveness assertions in `native-0`-style cases:** the first Apollo WDT feed by the app, the first PMIC kick and the first IDENT answer each within a bound after `CONT`, and **no WDT reset** in a 60 s watch. W24's failure in Renode terms is "a WDT reset at 9 s"; the case would have had to assert its absence.
- **`RSTGEN.STAT`** in `WispRstGen`, set by the reset source, so D1 is tested end to end, including a WDT reset and an SWPOR.
- **Fault injection for the diagnostics:** a fault at each of D4's stages in turn, checked to show up in D2's next-boot answer and in `peek`. This tests the observability, which is what W24 lacked.
- Renode cannot model the unknown silicon behaviour itself. The point of these changes is that the next unknown is caught by a liveness check and explained by the record, not that Renode would have predicted it.

### W24b: stage-0, the next hardware step

Prepared on t3-worker on 2026-11-08, **emulation only**: no hardware was touched. It carries out fix-plan item 1, the Wisp Boot half of item 3 (the PMIC kick at every boot), diagnostics D1, D2 and D7, and the Renode changes above, scoped to what stage-0 needs. native-0b (D3–D5 in the Zephyr app, the hand-off hardening, the console removal) and D6 (`ERRLOG` in `pmic_read.bin`) are not in it.

**What was built.**

- **Wisp Boot** (both builds; a Wisp Boot change, so rule 12, results below), right after it arms the watchdog:
  - **D1, the record**: the previous boot's 64-byte record at `0x20370000` (a `NOLOAD` slot, never copied or zeroed) is kept in the status block (now version 2, 692 B) and a fresh one is started with `RSTGEN.STAT` (`0x4000885C`), a boot counter, breadcrumbs at every stage up to the hand-off, and the fault if a handler runs (it records, then resets) ([case-uart.md](case-uart.md#the-boot-report-op-04), `src/boot/wisp_diag.h`).
  - **The PMIC kick**: one `07 04 01` over IOM7 at every boot, with the patched bootloader's own IOM7 values (read from a Renode trace of the real bootloader: pads 22/23 `0x4200`, `FIFOTHR 0x1010`, `MI2CCFG 0x3F270`, `CLKCFG 0x1D0E2301`, the I2C submodule on) and pmic_kick.h's transfer; IOM7 is powered down after. A reboot loop then keeps re-kicking it, and the PMIC no longer power-cycles back to its reset values as on W24. The kick is the only PMIC write Wisp Boot can make (one function, constant bytes; it sends only from an empty write FIFO), and every rung-3 case checks it by the writing PC. Known limits, all fail-safe (the kick then returns an error and sends nothing): its FIFO reset is simpler than the HAL's, and if it ever finds IOM7 left on, the wait after powering it off is a guess.
  - **D2, the boot-report window**: UART2 set up with the loader's own values (pads 42/44 function 4, 1 Mbaud), then only BOOTREP is answered, about 300 ms with no request, 100 ms after the last answer, at most 1 s, timed by the STIMER on the crystal when it counts, and capped by a poll count whatever the clock says. Pad writes (here and for the kick) go between GPIO PADKEY `0x73` and 0, as the bootloader's own.
  - The hand-off itself is **unchanged**, on purpose: stage-0 tests the hand-off native-0 got (H3). stage-0 sets MSP, PSP, CONTROL and the stack limits itself.
- **stage-0** (`apps/wisp-fw/src/stage0/`, 5,208 B at `0x448000`; image 70,744 B, `fc267e0b0de4…`, built from commit `9bfac4d`): bare metal, no Zephyr, no Ambiq HAL start-up, interrupts masked. It feeds the Apollo watchdog and kicks the PMIC's every second (the same kick code), answers IDENT, READ (its status, Wisp Boot's block, block 3 its clock measurements, block 4 its record), BOOTREP and RESET on UART2, polled, with the same codec as native-0; and it times 16 watchdog ticks (1,024 LFRC cycles) against the STIMER (the crystal) and SysTick (the core clock), 2 s after start and every 15 s, without feeding in between. It reconfigures no clock and writes no other PMIC register; panel and EM9305 untouched. Gates: rule 3 (both implementations), rule 8, the no-MRAM-write gate over `[0x448000, end)`, `check_native.py --observe --bare-app-elf`. Committed in `apps/wisp-recovery/wisp_w18/data/stage-0/` (README there), **pinned at W24b-0** (below).
- **boot-watch** (`--protocol wisp`; **superseded after W24b**, see [W24b results](#w24b-results-and-the-fix): the relay allows one try per boot, so the report is now aimed at Wisp Boot's window): at every boot (from `CONT`, and after each loader `HELO`) the boot report on every exchange with no pause until one answers (at most 200 exchanges, about 3.5 s), then IDENT and the blocks as before, stage-0's blocks 3 and 4 too. It prints every boot's report: why the previous boot ended and how far it got. native-0's codec answers BOOTREP with status 1, and the watch then moves on at once.
- **Renode**: LFRC 900 Hz (`WispWdt`, from `apollo510.h`); `RSTGEN.STAT` set by each reset's cause; SRAM retention across warm resets when a case asks for it (the record); the PMIC model acts on the app's own arming writes and comes back at W24's power-on values when it expires (`images/pmic-poweron-w24.json`, 14 of the 23 changed registers known; the other 11 are in the W24 report on the Mac [?]); the strict start-up record with its allowlist (empty); `w18-test`'s native cases fail on an Apollo watchdog bite, on no app PMIC kick within 3 s of a boot, and on any unreviewed write to an unmodelled power, clock or trim register.

**What the native-0 cases show now** (`wisp-fw:w18-test native-0`, the pinned image unchanged): **FAIL**, on the strict record only: no watchdog bite, the app kicks within 3 s of every boot, the PMIC is armed with stock's writes and never expires. Renode cannot say what silicon does with these writes; it now says that native-0's start-up makes 33 writes (16 distinct registers, each boot) to power, clock and trim registers that no model acts on, all from the HAL start-up before the kernel runs (PCs in the pinned ELF):

| Function (native-0) | Registers written |
| --- | --- |
| `am_hal_pwrctrl_low_power_init` | `RSTGEN.STAT` (0x2: the ERR027 `BORSTAT` clear, writing the register the header says never to write), `MCUCTRL.DBGCTRL`, `MCUCTRL.WICCONTROL`, `CLKGEN.MISC` (0xFBBFC0), `CLKGEN.CLKCTRL`, `MCUCTRL.AUDADCPWRDLY`, `MCUCTRL.PWRSW0`, `MCUCTRL.PWRSW1` |
| `am_hal_pwrctrl_mcu_memory_config`, `am_hal_pwrctrl_sram_config` | `MCUCTRL.FORCEAXICLKEN`, `PWRCTRL.SSRAMRETCFG`, `PWRCTRL.MMSOVERRIDE` |
| `buck_ldo_override_init`, `am_hal_pwrctrl_control` (**the SIMO buck enable**) | `MCUCTRL.VRCTRL` (0xF01EF, ten times), `MCUCTRL.SIMOBUCK15`, `MCUCTRL.SIMOBUCK0`, `PWRCTRL.VRCTRL` = 1 |
| `am_hal_clkgen_private_hfrc_force_on` (later, repeatedly) | `CLKGEN.MISC` |

This is H1's candidate list made concrete; it does not say which write (if any) stops the chip. The next step for native-0b is to compare each of these with what stock does at the same point (static analysis of stock 2.4.0.24's start-up), then either allowlist a write with that reason or change it. stage-0 makes none of them (its strict record holds only GPIO writes: PADKEY and the pads for pins 22, 23, 42 and 44).

**Emulation results**, t3-worker 2026-11-08 (Wisp Boot observe build `wisp_boot.bin` `b54ee856faaf9b82…`, 11,056 B, the one in stage-0; fallback build `b33da81aff164896…`):

| Suite | Stock 2.4.0.24 bootloader | Patched `87e2d4e0…` bootloader |
| --- | --- | --- |
| rung 3 observe (`wisp-fw:boot-test`) | **8/8 pass**: the six earlier cases, `obs-diag-wdt` (a watchdog reset with SRAM kept: the next boot reports prev stage `boot-handoff`, cause `watchdog`), `obs-stage-0` (IDENT kind 16, LFRC 922 Hz, a case-UART RESET, then Wisp Boot's window reports prev `s0-reset-request`, cause `sw-por`) | **8/8 pass** |
| rung 3 fallback | **28/28 pass** (reference, the 25 fault and power-cut cases, `native-app-runs`, `native-app-unconfirmed`) | **10 run, 10 pass**: reference, `good-confirms`, `app-hangs`, `app-hangs-flag-clear`, `crash-reset-handler`, `crash-after-300ms`, `wdt-never-fed`, `app-slot-erased`, `native-app-runs`, `native-app-unconfirmed`. **Not run:** `record-corrupt`, `rescue-corrupt`, `rescue-missing` and the 15 power-cut cases (the run was stopped at its 2-hour limit; on a shared, loaded host one patched case took 20–40 min). The fallback build is not in stage-0; its full patched run is due before a fallback Wisp Boot is flashed (rule 12) |
| every rung-3 case | Wisp Boot's PMIC writes are only `07 04 01`, once per run (by PC); no Wisp Boot write to an unmodelled power, clock or trim register | same |
| `w18-test` (patched bootloader) | — | 16 earlier cases **pass** under the new models (control, hello, info, the four `recover` variants, temple watchdog, `rung4-reads`, `install-wisp` and its cut); **`stage-0` passes** (install `19b3e002`, boot-watch at 17.5 ms, the reports after RESET and after the case reset, 3 Wisp Boot kicks, no bite, strict clean); **`native-0` and `native-0-recover` FAIL** on the strict record only (the table above) |

In Renode the crystal is 32,000 Hz (Renode's Apollo4 STIMER), so stage-0 reads the 900 Hz LFRC as 922 Hz there and the watchdog period as 8.9 s. On silicon it reads the real figures.

#### W24b-0 review

Independent review on t3-worker, 2026-11-09, **emulation and static analysis only; no hardware**. Scope: the committed stage-0 files (`fc267e0b0de4…`, 70,744 B) and the observe-only Wisp Boot in them (`wisp_boot.bin` `b54ee856…`, slot `7a5c399b…`). **Verdict: safe to install on the left temple with `install-wisp` and `recover` back to stock per the runbook below.** No blocker; pinned in the same change.

- **Rebuild.** From `9bfac4d` (clean worktree, the wisp-fw flake): `stage-0.bin`, `wisp_boot.bin`, the stripped `stage0.elf` (`e1bd148b…`) and the stripped `wisp_boot.elf` (`84d6432e…`) are byte-identical to the committed files. The maps differ only in the checkout's paths (pinned as built, as native-0's). The merged tree (`3518721`) changes no source after `9bfac4d`; built from it, the image differs in exactly the 10 bytes of the revision string stage-0 reports.
- **No MRAM or NOR write code.** `check_no_mram_write.py` passes on Wisp Boot's slot (65,536 B, its ELF), on the app (5,208 B, its ELF and map) and on all 70,744 bytes. No program key, no word in the boot-ROM helper table; the only literal in boot-ROM space anywhere is `0x02008005`, Wisp Boot's watchdog `CFG` value (unchanged since native-0). No literal names the flag record, the SBL or the bootloader region.
- **The only PMIC write is `07 04 01` to `0x6B`.** One `boot_pmic_kick`, the same machine code in both binaries, with the image's only `FIFOPUSH` (`0x00010407`), `CMD` (`0x301`: WRITE, TSIZE 3) and `DEVCFG` (`0x6B`) stores. The transfer is `pmic_kick.h`'s step for step. Set-up values equal hal_ambiq's 400 kHz I2C configuration (`CLKCFG 0x1D0E2301`, `MI2CCFG 0x3F270`, `FIFOTHR 0x1010`, `SMOD1EN`); every offset and bit was checked against `apollo510.h` by compiling `offsetof`. Pads are written between `PADKEY 0x73` and 0. Sending starts only from an empty write FIFO with room for 4, and a partial transfer can only be `07`, `07 04` (a register address, no data) or the kick itself, so no failure can turn into a write of another register.
- **Rule 3**: both implementations pass on the exact bytes (`native.rule3`, wisp-ota's `pack-main` in the build). CRCs: image `96aaf1c7`; over `[0x438000, 0x449460)` on stock 2.4.0.24, `19b3e002`.
- **Watchdogs and the window.** Wisp Boot arms, records and kicks within the first milliseconds, then feeds on every poll of the window. The window is capped at 2,000,000 polls whatever the STIMER does, and every UART wait is bounded. stage-0 feeds before anything else, then every second; its measurement goes at most about 3.6 s unfed against about 9.1 s. Every boot kicks the PMIC within about 1.5 s of reset, so a reboot loop (about 10.4 s) can no longer let the 30.72 s PMIC watchdog power-cycle the PMIC.
- **Registers stage-0 writes**: `WDT.RSTRT`; GPIO `PADKEY` and `PINCFG` 22/23 (`0x4200`) and 42/44 (`4`); `PWRCTRL.DEVPWREN` bits 8 (IOM7 on, then off) and 11 (UART2 on); IOM7's transfer registers; UART2's `CR`, `IBRD`, `FBRD`, `LCRH`, `IFLS`, `IER`, `IEC`, `RSR`, `DR`; `RSTGEN.SWPOR` (only on RESET or a fault); core-private SysTick, `ICSR`, `VTOR`, MSP/PSP/CONTROL/stack limits. No CLKGEN, MCUCTRL or trim register, and nothing else in PWRCTRL. Renode's strict record agrees (GPIO only outside the modelled blocks).
- **The record at `0x20370000`** is Wisp Boot's own RAM, as it has been since W17. No literal in the patched bootloader points into `0x2036xxxx`–`0x2037xxxx`. Stock does use that region, but stock runs only after `recover`, when Wisp no longer does. A clobbered record only loses `prev-valid`; it is diagnostic.
- **Host side**: boot-watch's decoders match the firmware byte for byte (report `<BBBBIHIII>`, 22 B; record, 64 B; clock block, 52 B).
- **Reruns** (this tree, `b54ee856…`): `wisp-fw:boot-test` observe suite **8/8 on stock 2.4.0.24 and 8/8 on the patched `87e2d4e0…`**; `wisp-fw:w18-test --only stage-0` **pass** against the repository's pin (final CRC `19b3e002`, 3 Wisp Boot kicks, no bite, strict clean); `wisp-recovery:test` pass.

Findings, none blocking, ranked:

1. Low, liveness only. `stage0.c:401`: the STIMER probe waits on SysTick with no bound, and without the crystal `now()` (`stage0.c:86`) is SysTick only. If SysTick did not count on silicon, stage-0 would feed once and the WDT would reset it every ~10 s. The next boot report then says `s0-uart` and Wisp Boot keeps kicking the PMIC, so this is diagnosable and harmless. Bound the probe loop by a poll count in a later image.
2. Low. `stage0.c:55`: without the crystal, time is SysTick at an assumed 96 MHz. At a hand-off clock under about 38 MHz, a measurement that times out (COUNT never moving) would outlast the WDT period. Same outcome as 1 (breadcrumb `s0-measure`).
3. Info. `boot_pmic.c:91`: on the 0x400 timeout IOM7 is powered off mid-transfer. At worst a slave holding SDA keeps later kicks failing, the PMIC power-cycles as on W24, and step 8 catches it. No other register can be written.
4. Info. In Renode stage-0 reports the core clock as about 429,496,7xx Hz (≈ 2³²/10): the SysTick model, not a meaningful figure. The core clock is checked on silicon only (step 5).
5. Doc, fixed here. The W24 fix plan said stage-0 "arms and kicks" the PMIC watchdog; it only kicks. The runbook's step 4/9 output lines now quote what the tool prints. The w18 harness pinned stage-0 in memory and did not check the final CRC; it now uses the repository's pin and checks `19b3e002`.

#### W24b runbook: stage-0, left

*After W24b:* rerun with the [W24b rerun runbook](#w24b-rerun-runbook-the-same-stage-0-left) (the fixed boot-watch, and a `peek` after step 7).

**W24b-0 (before any write): an independent review of this tree, then pin stage-0. Done 2026-11-09** ([review](#w24b-0-review)): `pins.WISP_IMAGES["stage-0"]` (image `fc267e0b0de4…`, 70,744 B; stripped ELF `e1bd148b…`; map `6df0f5ea…`; both gates; `crc32` `96aaf1c7`; `crc32_aligned_over_stock` `19b3e002`; slot `7a5c399b…`) and its Wisp Boot slot in `WISP_BOOT_PASSED` (observe suite 8/8 on both bootloaders). `tests/test_stage0.py` runs install-wisp's whole gate on the committed files and refuses a one-byte change to any of them. The `--expect` value for step 4 is exactly **`fc267e0b0de4`** (12 hex digits; fewer are refused).

**Two steps write MRAM: 4 (`install-wisp`) and 10 (`recover`). Each needs Jan's own go** (rule 4); the go for step 4 names the image hash. The rest are read-only plus the usual PMIC kick. Setup as W24 (rule 6, case session; `git pull`, `pnpm nx run wisp-ota:build`; `w18 …` = `caffeinate -i uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py …`). No `ble-scan`: stage-0 has no BLE. Every case command must end with relay exit status 6, the route restored and the case back on 1.2.57. `S0=apps/wisp-recovery/wisp_w18/data/stage-0`.

| # | Command | Expect | Stop if |
| --- | --- | --- | --- |
| 1 | `w18 loader-hello --side left` | CRC `63cd8dda` twice, flag `0xffffffff`, feed status 0; stock boots | anything else (§8) |
| 2 | `w18 pmic-read --side left --compare apps/wisp-recovery/runs/w18-pmic-read-left-20261108T131013Z.json` | exit 0 (stock restored the PMIC after W24) | exit 3 |
| 3 | `w18 app-check --side left` | `stock 2.4.0.24 main: … MATCH`, flag clear | no match, or the flag not clear |
| 4 | **Jan's go for `fc267e0b0de4…`**, then `w18 install-wisp --side left --image $S0/stage-0.bin --elf $S0/stage0.elf --map $S0/stage0.map --expect fc267e0b0de4 --battery <N>` | `install-wisp: stage-0 fc267e0b0de465f2..., 70744 B into …`; the loader-hello gate; `vectors zeroed`; body written and read back (well under a minute: 70 KiB); `OK … written and verified (19b3e002)`; boot released | any `REFUSED`; any stop during the write (vectors zero: the temple boots nothing; resume or `recover` only with a new go); another final CRC |
| 5 | `w18 boot-watch --side left --protocol wisp --watch-s 60 --interval-s 0.1` (at once after 4) | see "Reading step 5" below. On success: a boot report (`from wisp-boot` or `from app`), `IDENT: Wisp 0.1.0 kind 16, stage bare-metal`, no `HELO` after `CONT`; app status with PMIC kicks rising, errors 0; Wisp Boot v2 with `PMIC kick 0x0`, `previous record` (none on this first boot: the install session's relay start was a case reset after stock, which writes no record); NOR id `0x3925c2`, staging `971f4516`, the four `/firmware` files; **`stage-0 clocks: LFRC … Hz … watchdog's period … ms; core … Hz; timebase stimer-xt`. Write the LFRC and the core clock down: they are the facts this step exists for** | none (findings are not stops), except the NOR stop of W24 step 6 |
| 6 | `w18 boot-watch --side left --protocol wisp --watch-s 20 --interval-s 0.1` (a second session: its relay start resets the temple with the reset line) | the first boot report: `reset cause 0x0001 ['external']` (or with more bits, if STAT accumulates [?]) and, **if SRAM survived the reset and the bootloader**, `previous boot's last stage s0-loop` (or `s0-measure`) with its time; `boot 2`. No `prev-valid`: SRAM is not kept across this reset, or the bootloader uses `0x20370000`; either is a finding, not a stop. Then IDENT and the blocks again | — |
| 7 | `w18 loader-hello --side left` (the case reset of a running stage-0 temple) | `HELO`, CRC `63cd8dda` twice, flag `0xffffffff` | as W24 step 8: twice no `HELO` after a reseat: STOP; another CRC: STOP, no further reset |
| 8 | `w18 pmic-read --side left --compare apps/wisp-recovery/runs/w18-pmic-read-left-20261108T131013Z.json` | **exit 0**: stage-0 and Wisp Boot only kick, the PMIC watchdog stays armed and kicked, so W24's power cycle does not happen | exit 3: STOP before `recover`, send the report (the kick did not work on silicon, or something else wrote the PMIC) |
| 9 | `w18 app-check --side left` | `Wisp stage-0: region CRC-32 96aaf1c7 over 70744 B, image 96aaf1c7: MATCH`, flag clear | no match, or the flag not clear |
| 10 | **Jan's go for `recover`**, then `w18 recover --side left --image .wisp-cache/stock/g2-2.4.0.24.bin` | one session, about 72 min, `OK: stock 2.4.0.24 main app written and verified (d9864941)` | as W24 step 11 |
| 11 | `w18 app-check --side left`; `ble-scan --side left --seconds 30`; `pmic-read --compare` W21 about 60 s after the stock boot | stock `9c66404b` MATCH, flag clear; stock-left advertising; exit 0. Jan: the Even app, Lotti, touch and the microphone work | anything else (§8) |

Then a hardware-log row "rung 4 W24b (stage-0)" with the reports of 1–11, the boot reports of 5 and 6 as printed, the clock block, and the final CRCs.

**Reading step 5** (and 6): what each outcome means, against the W24 hypotheses.

| What boot-watch shows | Means | Next |
| --- | --- | --- |
| stage-0 answers, no `HELO` in 60 s, PMIC kicks rising | Wisp Boot → `0x448000` hand-off, UART2, the PMIC kick over our own IOM7 sequence and the crystal all work on silicon. W24's failure is inside Zephyr or the HAL start-up (H1, H1b, H2), not Wisp Boot (H3) | native-0b, with the strict list above as the first suspects |
| `HELO` loop; each boot's report from `wisp-boot` with prev stage `boot-handoff`, cause `0x40` (watchdog) | the hand-off happens but stage-0's reset handler never leaves a breadcrumb: the jump or the state it leaves (H3) | hand-off hardening in Wisp Boot (rule 12), then stage-0 again |
| `HELO` loop; prev stage `s0-…` and its time | stage-0 got that far: the stage names the step (UART set-up, the kick, the measurement) | fix that step |
| a report with `prev-fault` | a fault handler ran: its PC, LR and CFSR are in the report | decode against `stage0.elf` / `wisp_boot.elf` |
| `HELO` loop, no boot report at all, PMIC config intact at step 8 | Wisp Boot dies before its window (after the kick), or UART2 TX does not work from Wisp Boot | step 6's report (a second chance), then a Wisp Boot change |
| `HELO` loop, no boot report, PMIC config reset at step 8 | Wisp Boot dies before (or in) its kick | as above; the kick is the suspect |
| reports flag no `kick-ok` | the IOM7 sequence fails on silicon | compare with the bootloader's HAL (pmic_kick.h) |
| no `prev-valid` ever, also without a power cycle | SRAM at `0x20370000` does not survive these resets (or the bootloader uses it): the record can only carry this boot's cause | move the record (MCUCTRL scratch is not an option, see D1 notes) or accept cause-only reports |

**What Renode cannot check here.** Its IOM and UART models ignore power, pad, clock-divider and baud settings, and GPIO is plain storage, so `kick-ok` and an answered window in emulation prove only that the code runs to the end with the right bytes. Whether these register sequences work is exactly what step 5 shows on silicon.

Between sessions the case app polls with `0x13`, which stage-0 does not answer: the case resets the temple about every 3 minutes, as with native-0. Each such reset is a fresh boot; its report says `external`. Keep 5 and 6 back to back.


### W24b results and the fix

Written on t3-worker on 2026-11-09, after W24b. **No hardware was touched for this section**: it uses W24b's hardware-log row (PR #83), the Mac thread's tooling finding, drdaeman's relay and loader sources at `1d22097`, the pinned stage-0 files, the patched bootloader (`87e2d4e0…`, rebuilt from the cache and disassembled, not committed), hal_ambiq's `apollo510.h` and emulation. Tags as above.

**What happened.** stage-0 was installed and verified (`19b3e002`) and later recovered to stock (`d9864941`); the temple is fine. boot-watch got **nothing**: `HELO` after `CONT` 6× (t = 10.2, 20.9, 31.5, 42.2, 52.9, 63.6 s, period ≈ 10.68 s), no boot report, no IDENT, no blocks; step 6 the same. The PMIC kept its configuration through about 3 minutes of loop (step 8: 0 config diffs), so a boot-time `07 04 01` kick ran on silicon at every boot.

#### The tooling fault: the relay blocks on an unanswered request

[C, `case_exchange.c`] After a `G2TX` the relay sends the frame, re-initialises its temple receiver and calls `relay_receive`: up to 64,000,000 polls (about 31 s with the YHM4005 feed, 18 s without) waiting for the temple's first four bytes. **It does not read the host port meanwhile.** The wait ends with a frame (status 0), or early with status 2 on four bytes that are no `5A A5 FF` header or a UART error flag; otherwise at the poll bound with status 2. Consequences:

- An unanswered request costs the rest of the boot in a reboot loop (the next frame is the loader's `HELO`), or the whole poll bound if the temple is up but silent.
- The host cannot time out and ask again: its bytes would reach the relay only after the wait, and USART1 has a one-byte receive register (a later byte overruns, the framing breaks, the relay exits). The tool never did this (`status.watch` is synchronous; `query` waits up to 120 s).
- Temple frames sent while no exchange is pending are lost: the next exchange re-arms the receiver first.

W24b's boot-watch asked BOOTREP ~15 ms after `CONT` and after each `HELO`. After `CONT` the loader hands off at once, but 15 ms is before Wisp Boot's UART2 set-up (the hand-off, the watchdog arm, the record and the PMIC kick come first), so the bytes were lost. After a `HELO` the request lands in the loader's own 512-tick window: [C, `bootloader.c`] the loader's worker reads the 9-byte frame, it is not the 25-byte `HOLD`, it waits on; the window ends, it deletes its thread, powers UART2 down and hands off. Nobody answers, so the relay held the exchange until the next `HELO`, ~10.7 s later, and the tool asked the same way again. `WispStatus.REPORT_TRIES = 200` assumed an unanswered request comes back within one 17.5 ms exchange. That was true only of our relay model (`relay_model.py` answered status 2 at once), and of the Renode harness, which injected a request every 17.5 ms regardless of replies. **"No boot report" from W24b says nothing about Wisp Boot's window.**

**The fix (host only; stage-0 and Wisp Boot unchanged, so no rule-12 reruns and no re-pin):**

- `WispStatus` asks the boot report **once per boot, aimed at Wisp Boot's window**: `--report-at` seconds after the loader's release (`CONT`, or the `HELO` + 0.512 s window when nobody holds it). Default `0.15, 0.35, 0.55, 0.75, 0.95`: the k-th value on a boot after k unanswered tries, so a window opening anywhere from about −0.15 to 0.95 s after the release is hit within five boots (about 55 s in a loop). Once Wisp Boot answers, that offset is kept, and the report carries `asked_s_after_release`. The expected hand-off is a few ms after the release (the loader's flag check and de-init, then Wisp Boot's arm, record, PMIC kick and UART2 set-up), so 0.15 s lands in the middle of a 300 ms window. Without the crystal Wisp Boot's window is shorter (about 30–150 ms); then the sweep may miss, and `--report-at` can be set by hand.
- IDENT waits 2 s after the report's answer: Wisp Boot's window ignores it and stays open 100 ms after its answer, then come its NOR scan and the hand-off, and a request in between would block the relay. If the report try is unanswered and the relay comes back with status 2 (the temple is up but silent), IDENT follows at once, and stage-0's own BOOTREP (source `app`) later.
- `status.watch` gives a protocol `anchor(t, kind)` (release and each `HELO`), `wait(t)` and `no_answer(t)` hooks. `listen` and the other protocols keep the plain interval.
- **The models block like the relay.** `RelayModel` answers an unanswered request after its poll bound, or sooner if the fake temple sends a frame by itself (`wait_frame`); four non-header bytes still end it at once. `tests/test_boot_watch_timing.py` has a fake temple with the boot's real timeline (loader window, hand-off, Wisp Boot's window with its extension and cap, NOR scan, stage-0 start-up, then stage-0 answering, or dead until the watchdog's reset and the next `HELO`). With W24b's timing it reproduces the hardware: zero reports, every request in the loader phase, a steady period. With the fix: a report at every boot of a looping temple, a healthy stage-0 complete in under 10 s, a late window found by the sweep and kept, and a missed window on a healthy temple costing one poll bound. The Renode harness's watch (`wisp-fw:w18-test`, case `stage-0`) now runs the same way: each request waits for the first frame up to the poll bound, nothing else is injected meanwhile, frames outside an exchange are dropped, and `HELO` re-anchors the timing. Its checks now require that the report after the case-UART RESET came from Wisp Boot's window at an aimed offset.

Emulation result (t3-worker, 2026-11-09, this tree): `wisp-fw:w18-test --only stage-0` **pass** against the patched bootloader (install `19b3e002`, 3 Wisp Boot kicks, no bite, strict clean). After the case-UART RESET and after the case reset, the harness listened for the `HELO`, asked BOOTREP 0.925 / 0.96 s after it (release + 0.15 s) and got Wisp Boot's report on that one try (prev `s0-reset-request`, cause `sw-por`; then prev `s0-loop`, cause `external`, boot 3); IDENT followed 2.02 s after the report and was answered. A run before the IDENT fix showed IDENT only 1.34 s after the report (timed from the `HELO`, not the answer), which the review caught; the case now checks the spacing. `wisp-recovery:test`: 256 tests pass.

#### A second read path: `peek` of the record

The record (D1) lives at `0x20370000`; the boot report is only one way to fetch it. `peek` can read it from a **held loader** after the session's case reset, through `dump_fed` (no new temple program):

- [C, static] The patched bootloader's only SSRAM use is its FreeRTOS heap: `0x41FD70` memsets `[0x20081000, +0xBB800)` and hands it to the heap init (`0x417240`). Its literal pools hold no other SSRAM address (the others are `0x20080000`, a DMA cache-maintenance threshold, and ASCII); its largest DTCM literal is `0x2007D000`, the stack limit. So nothing in it writes `0x2037xxxx`. Wisp Boot's `reset_handler` never copies or zeroes the record, and a held loader never runs Wisp Boot. What the SBL does with SRAM, and whether SRAM keeps its contents across the case reset, is open [?]: the record's magic and CRC tell.
- [I, strong] SSRAM group 2 (the top MiB) is powered when the bootloader hands off: Wisp Boot's stack, data and bss are there, and Wisp Boot evidently ran (it armed the watchdog; a reset handler without RAM would lock up before the arm, and the bootloader arms none). Whether it is already powered during the hold is not proven, so the tool reads `PWRCTRL.SSRAMPWRST` first (`0x40021028`; offsets checked by compiling `offsetof` against `apollo510.h`) and dumps the Wisp regions only if bit 2 is set. Peripheral reads through `dump` already ran on hardware (`info-dump`, W18 E, `PWRCTRL` at `0x40021004`).
- New `pins.PEEK_REGIONS`, all reads: `ssram-power` (`0x40021028`, 4 B), `rstgen-stat` (`0x4000885C`, 4 B: the cause of the reset that started the session), `wisp-record` (`0x20370000`, 64 B) and `wisp-boot-status` (`0x20375330`, 692 B: `st` of the stage-0 Wisp Boot, slot `7a5c399b…`; a test checks both addresses against the committed `wisp_boot.elf`). A refused gated region is a finding, not a stop.
- What they show: `wisp-record` is the boot that the case reset interrupted (its boot counter, cause, last stage and when it got there). In a reboot loop that boot may have been cut short; **`wisp-boot-status`'s `prev` is the boot before it, which ran to its end** (the watchdog's reset), so its last stage is where it stopped. Both carry `RSTGEN.STAT` as Wisp Boot found it.
- [?] **Cache.** The bootloader carries the HAL's cache code (CCR reads at `0x41C9CE`/`0x41E34A`, set/way maintenance literals at `0x41E458–0x41E470`), so it may leave the D-cache on. SSRAM is cacheable by default; a breadcrumb still in a dirty line when the watchdog resets the chip is lost, and the record in SRAM is older than the last breadcrumb, or fails its CRC. Renode has no cache, so it cannot show this. A later image should clean the record's two lines after each write (`DCCMVAC`), or make the region non-cacheable. For this rerun: a valid record whose stage looks too early may be stale.
- In Renode the `stage-0` case now also attaches a held-loader session after a case reset and peeks: `ssram-power` `0x7`, `rstgen-stat` `external`, `wisp-record` valid (boot 3, stage `s0-loop` at 3,661 ms, cause `external`), and `wisp-boot-status` sealed, with `prev` valid (`s0-loop`). The harness now keeps all of Wisp Boot's RAM across warm resets (`RetainRange 0x20370000 0x10000`; it kept only the 64-byte record before, and filled the rest with `0xA5`). That shows the read path and that the bootloader leaves the region alone in emulation, not that silicon SRAM survives.

#### (c) The ~10.7 s loop: what the numbers say

Both images loop with the same structure: period = reset to `HELO` + the loader's 0.512 s window + hand-off + Wisp Boot from its arm to the **last effective watchdog restart** + the watchdog period (128 × 64 LFRC cycles, about 9.1 s at 900 Hz).

1. [C] The first `HELO` after `CONT` came 0.48 s before the steady period (10.2 vs 10.68 s), as on W24 (9.9 vs 10.4): the skipped loader window.
2. [I] **stage-0's period is 0.28 s longer than native-0's** (10.68 vs 10.4 s, both steady within ±0.1 s). W24b's Wisp Boot added exactly one thing between its arm and the hand-off: the report window, 300 ms when nothing asks (and nothing reached it on W24b), fed on every poll. The difference fits that window. It shows only if **Wisp Boot's feeds work** and the last effective restart is Wisp Boot's, in both images. If Wisp Boot's feeds did nothing, the period would count from the arm and the window would not appear; then the 0.28 s needs another cause, LFRC drift between two days (3 %) being the only one at hand [?].
3. [C] **The app never restarted the watchdog later than about 0.1–0.2 s after the hand-off.** Any app that fed once at time t after the hand-off and then stopped would lengthen the period by t. stage-0 feeds within microseconds of entry (`stage0_main`: SysTick set-up, then `feed()`), then once a second. So stage-0 either **never reached its first feed**, or reached it and **stopped within its start-up**, before its main loop (its measurement starts 2 s in, which would have shown).
4. [C, code] **A handled fault would loop in about 1.5 s, not 10.7.** Wisp Boot's and stage-0's fault vectors record the fault and reset by SWPOR within microseconds (VTOR is `0x438000` from the bootloader, then `0x448000` from `hw_jump`). So the 9.1 s is a **hang**, or a fault that cannot be handled: a fault while stacking or inside the handler, a lockup that only the watchdog ends.
5. [C] The PMIC kept its configuration: a kick ran in every boot within 30.72 s of the last. Wisp Boot kicks right after its arm and record, before its window, so Wisp Boot ran at least that far. stage-0 would also kick, but only after its first feed, UART set-up and SysTick probe.

**Checked and ruled out (statics):**

- **The feed itself** [C]. `apollo510.h`: `CFG` 0x0, `RSTRT` 0x4 (key `0xB2`), `LOCK` 0x8 (key `0x3A`), `COUNT` 0xC, by `offsetof`. hal_ambiq's `am_hal_wdt_restart` is that one store. The lock blocks only `CFG` writes ("Once locked, the WDTCFG reg cannot be written"), not restarts. No clock enable is needed for a restart: the HAL's `am_hal_clkmgr_clock_request(LFRC)` in `am_hal_wdt_start` is bookkeeping, and the watchdog evidently counts. Wisp Boot's `CFG` is `0x02008005` (LFRC/64, `RESVAL` 128, `RESEN`, `WDTEN`, no interrupt); the HAL writes `CFG` without `WDTEN`, restarts, then sets `WDTEN`, which is immaterial. Renode's `WispWdt` uses the same offsets. stage-0 stores the same value to the same address as Wisp Boot, whose stores worked (2). **Out.**
- **`stage0.c:55`, the assumed 96 MHz** [C]. Used only without the crystal. A slower core makes stage-0's "second" longer: at f MHz it feeds every 96/f s, under 9.1 s for f > 11 MHz, and its first measurement (up to 3.6 virtual s unfed) only after 2 virtual s of feeding. Either way it would have fed for seconds first and lengthened the period (3). **Out as the cause of this loop.**
- **The hand-off state, for stage-0** [C, code]. The bootloader jumps from its DFU task in Thread mode on PSP; `hw_jump` masks interrupts, clears and un-pends the NVIC, sets VTOR and MSP (not the active PSP), unmasks and branches. stage-0's naked reset handler masks interrupts, sets MSP and PSP to its own stack, CONTROL to 0, and the stack limits to 0 before any push, so a stale `MSPLIM`/`PSPLIM` (`0x2007D000`) or SPSEL cannot hurt it. A pending PendSV or SysTick taken at `cpsie i` goes to `stage0_ignore`, which returns. The bootloader's literal pools hold no MPU address (`0xE000ED90/94`) [C], so a bootloader MPU set-up is unlikely [I]. stage-0's RAM (DTCM `0x20000000–0x2000FFFF`) is the bootloader's own RAM, powered. **Not a stage-0 cause.** For native-0, the pending PendSV is still live: Zephyr's `z_arm_pendsv` before the kernel is up (W24 hand-off notes).

**Ranked, for the ~10.7 s loop of both images:**

| # | Hypothesis | Fits | Against | Rank |
| --- | --- | --- | --- | --- |
| A | **Wisp Boot hangs after its window and before the hand-off**, in a loop that does not feed: its NOR bring-up, littlefs mount, inventory or `rescue.bin` verify on silicon (MSPI1 on the bootloader's state; littlefs on real flash contents). Common to both images: native-0 ran the same observe Wisp Boot code after its arm | (2), (3), (4), (5): the last effective feed is Wisp Boot's, no app code ever runs, the same period in both images, no fault | the NOR waits are bounded (`TIMEOUT` 2,000,000 polls) and the block reads feed (`boot_main.c` read/verify loops), but littlefs's own loops and a long run of bounded timeouts do not feed; a hang there is exactly a watchdog reset 9.1 s after the last feed | **1** |
| B | **The jump lands, and the app faults in a way that locks up** before its first feed: e.g. a bus fault on its first push or fetch whose exception entry faults again. Common to both images (both start in DTCM and MRAM `0x448000`, which Wisp Boot never touches) | (2)–(5) | stage-0 is tiny and does nothing unusual before its feed; the bootloader runs from the same memories; no MPU literal in the bootloader | 2 |
| C | **stage-0 stops in its start-up after its first feed** (`stage0.c:401`'s unbounded SysTick probe, if SysTick does not count in the state the hand-off leaves) | (2)–(5) for stage-0, and Wisp Boot's kick keeps the PMIC | SysTick is implemented on Apollo510 (hal_ambiq has `am_hal_systick` for it); not a native-0 cause, so W24 would need a different failure with the same timing | 3 |
| D | Wisp Boot's restarts do nothing (H4 of W24), and the 0.28 s is LFRC drift | the period alone | the same store pattern from the app would fail equally, so it predicts the same loop for any app; offsets and keys checked | 4 |

**What separates them on the rerun.** With the aimed boot report each boot says `prev_stage` (`boot-window-end`, `boot-nor`, `boot-mounted`, `boot-inputs`, `boot-decided`: A; `boot-handoff`, `s0-reset`, `s0-init`: B; `s0-feed`, `s0-uart`: C) and `reset_cause` (`watchdog` expected). The `peek` after step 7 gives the same from RAM, independent of UART2, and Wisp Boot's status block says how far that boot got. If neither shows a valid record (`prev-valid` never set), SRAM does not survive these resets (or the cache held the record back), and the next image needs a different store; the reset cause alone (`RSTGEN.STAT` in the report) still says watchdog or not.

#### W24b rerun runbook: the same stage-0, left

Same image, same pins, same review (`fc267e0b0de4…`, final CRC `19b3e002`): nothing to re-review. Only the tool changed (this section). Setup, rules and the two write gos as in the [W24b runbook](#w24b-runbook-stage-0-left); `git pull` first, so the Mac runs the fixed boot-watch. Steps 1–4 and 8–11 are unchanged; the changes are:

| # | Command | Expect | Stop if |
| --- | --- | --- | --- |
| 5 | `w18 boot-watch --side left --protocol wisp --watch-s 70 --interval-s 0.1` (at once after 4) | a line per boot `boot report (from wisp-boot) … asked 0.15 s after release` (or a later offset of the sweep: write it down), then either `IDENT: Wisp 0.1.0 kind 16, stage bare-metal` and the blocks as in W24b's step 5, or the next `HELO`. In a loop: one report per boot after the first miss at most five boots, each with `prev stage` and `reset cause` | none, except the NOR stop of W24 step 6 |
| 6 | `w18 boot-watch --side left --protocol wisp --watch-s 30 --interval-s 0.1` | the first boot's report: `reset cause … external`, and the previous boot's last stage if SRAM survived | — |
| 7 | `w18 loader-hello --side left` | as before | as before |
| 7b | `w18 peek --side left --what ssram-power rstgen-stat wisp-record wisp-boot-status` (its relay start is the case reset of the stage-0 boot that step 7's `CONT` started) | `ssram-power` with `wisp_ram_powered: true`; `rstgen-stat` `external`; `wisp-record` `valid: true` with the interrupted boot's counter, cause and stage; `wisp-boot-status` with `prev` (the full boot before). Group 2 not powered: the Wisp regions are `refused`, a finding. `valid: false`: SRAM or the cache did not keep it, a finding | the usual: no `HELO` twice after a reseat, another bootloader CRC |

**Reading step 5 again**, with the aimed report:

| What boot-watch shows | Means |
| --- | --- |
| reports from `wisp-boot`, `prev stage` one of `boot-window-end` … `boot-decided`, cause `watchdog` | A: Wisp Boot hangs in its NOR/littlefs phase on silicon; native-0's W24 loop is the same failure. Next: NOR phase breadcrumbs per call, feeds in littlefs's callbacks, or skip the NOR phase in the observe build |
| `prev stage boot-handoff`, cause `watchdog` | B: the jump, or stage-0's first instructions. Next: hand-off hardening (W24 fix plan 3), rule 12 |
| `prev stage s0-reset` or `s0-init` | B: stage-0 ran its first C lines and stopped before its first feed (data copy, bss, VTOR, SysTick set-up) |
| `prev stage s0-uart`, or `s0-feed` (UART2 set-up failed, which is bounded) | C: the SysTick probe (`stage0.c:401`) |
| `prev stage s0-loop`, no IDENT although the report came | stage-0 runs: the watch's IDENT is the suspect (timing); read the `exchanges` and ask the Mac thread |
| reports, but never `prev-valid` | the record does not survive (SRAM, SBL or cache): decide from `reset cause` alone, and move the record |
| still no report in 70 s (about six boots) | Wisp Boot never opens its window (it hangs before it, after its kick: the PMIC still kept), or UART2 TX from Wisp Boot fails. `peek` (7b) then decides: a valid record with stage `boot-pmic-kick` or `boot-window` names it |

### Gaps

Size: **S** < 1 day, **M** 1–3 days, **L** > 3 days, for one thread.

| # | Gap | Project | Size | In emulation? | Needed by |
| --- | --- | --- | --- | --- | --- |
| G1 | **Built, closed until R4-1** ([status](#tooling-status)). `install-wisp`, per R4-1: image, ELF and map pins; an end bound from the image; rule-3 checks rerun on the sent bytes; the Wisp Boot allowlist from the rung-3 suites; vectors zeroed first and written last (the same change for `recover`); `--expect`, `--battery`; a same-session `loader-hello` gate; a report | wisp-recovery | M | yes: fakes plus a Renode `w18-test` case | W24 |
| G2 | **Built** ([status](#tooling-status)). `app-check` (read-only: bootloader CRC, flag, the app region's CRC against the known images) and `boot-watch` (`CONT`, then status queries through the relay before `G2EX`; the status protocol is a hook, `listen` only until G10) | wisp-recovery | S | yes: fake case; `WispCaseLink` waits for G10/G15 | W24 |
| G3 | **Built** ([status](#tooling-status)). `peek` (allowlisted reads via `dump`/`dump_fed`) and `pmic_read.bin` (504 B, bootloader IOM7 HAL, write-read only, register allowlist proven in Unicorn), pinned | wisp-recovery | S–M | yes: Unicorn `temple_cpu`, Renode `rung4-reads` | W21 |
| G4 | **Done** ([hardware.md](hardware.md#rung-4-static-analysis-w20-2026-11-08)). The static analysis for W20 | docs (hardware.md, recovery.md) | S–M | n/a (static) | W21, W24, W25 |
| G5 | **Built** ([status](#tooling-status)). The split-session pogo-settle fix: `_arm` (`links.py:217-228`) recognises the bridge's 13-byte `G2RS` and reports status 3 at once, instead of a 60 s "got 13 of 16 bytes"; plus a settle wait in `run_sessions` or `CaseRelayLink.start` | wisp-recovery | S | yes: fake case | before relying on `--max-session-s` or `--no-temple-feed`; recommended before W24 as plan B |
| G6 | **Built (W22).** The real app behind Wisp Boot: link at `0x448000`, `sram0` and the stack out of `0x20370000+`, a combine step for the real app (today only `tests/boot/app/combine.cmake` for fault apps), a `pack-main` target for later | wisp-fw | M | yes: Renode, rung 3 with the real app | W24 |
| G7 | **Built (W22).** The app feeds the locked 8 s watchdog (a raw `RSTRT` write, because Wisp Boot locked the configuration) from a `k_timer` or the highest-priority thread, started before `bt_enable()` | wisp-fw | S | yes | W24 |
| G8 | **Built (W22).** `confirm()` through the services table after `HELLO` | wisp-fw | S | yes: a rung-3 `good`-style case | W24 |
| G9 | **Built (W22).** The observe-only Wisp Boot build (writes compiled out, decision forced to `run-app`), the RAM status block with the `/firmware/*` inventory, and its own rung-3 suite | wisp-fw | M | yes | W24 |
| G10 | **Firmware side and spec built (W22, [case-uart.md](case-uart.md)); the `0x13` reply is G10b.** Case-UART status: a UART2 node; answers to the `24` version query and to a Wisp status query; a reset command (also over BLE); the host side in step 0 and `boot-watch` | wisp-fw + wisp-recovery | M | yes: `WispCaseLink` in Renode, fake case | W24 |
| G11 | **No default panel, JBD4010 named, panel off: built (W22); the pattern is native-1.** No default panel; JBD4010 for hardware 5 (or a runtime choice from the ADC strap); BUCK1's code gated against W21's snapshot; the test pattern (`native-1`) | wisp-fw | S | yes: `drivers-test` JBD | W24 (no default), W25 (pattern) |
| G12 | **Built (W22) with W21's snapshot: native-0 writes no PMIC configuration (checked against `images/pmic-baseline-w21.json` in Renode); the development DTS still differs (listed in the W22 status).** PMIC values checked against W21's snapshot over every register the Zephyr MFD, charger and regulator drivers write; a review that the app never enters ship or hibernate mode and never changes charger limits from stock's | wisp-fw | S–M | partly | W24 |
| G13 | **Built (W22).** A no-MRAM-write gate over `[0x448000, end)`, post-link like `check_rule8.py`: no `am_hal_mram_*`, `nv_program_*`, `0x0200FF20` or `0x12344321`, and the MRAM flash driver off | wisp-fw | S | yes (negative build) | W24 |
| G14 | A Mac-side session tool (the TS SDK's `Transport` over a Node BLE binding, or a bleak bridge). Test from the Mac, not iOS, so that iOS's cached stock GATT database for that address doesn't interfere. *Moved from W24 to W25 at W23: W24 only scans for adverts (`w18.py ble-scan`)* | wisp-sdk-ts / tools | S–M | yes: native_sim + Bumble | W25 |
| G15 | **Built (W22).** A `w18-test` case: `install-wisp` into the stock app region, `CONT`, then Wisp Boot and the app booting behind the real patched bootloader, PMIC watchdog armed. Note: Renode resets every register on reset, so it cannot catch state that persists on silicon; W21 and W24 do | wisp-fw (Renode) | S–M | yes | W24 |
| G16 | **First half built (W24b, emulation only):** Wisp Boot kicks once at every boot (`stage/boot_pmic.c`, its own polled IOM7 write with the bootloader's register values; rung 3 proves it is its only PMIC write). Still open: Wisp Boot kicks the nPM1300 watchdog during long work, the rescue copy above all (a PIO I2C7 write as in `pmic_kick.h`); rung-3 cases with `WispPmicWdt` armed | wisp-fw | M | yes | W27, W29, and any BLE install |
| G17 | Wisp Boot clears the flag after a new install, with the documented clear record through the same single function (R4-3); rung-3 cases including power cuts around it | wisp-fw | S | yes | W28 |
| G18 | **Not needed: W21 read the MX record on the left temple (not GD).** GD25LE256H support in Wisp Boot's NOR driver, and a NOR model answering `C8 60 19`. **Only if W21 finds GD.** Same command modes as stock: no QPI/OPI, no volatile-configuration writes | wisp-fw | S–M | yes | W24 |
| G19 | Storage HAL: littlefs on MSPI1 in Zephyr, sharing Wisp Boot's geometry and driver, writes **only under `wisp/`**, stock's NOR command modes only, coexisting with the Even bootloader's `boot_count` writes. A Renode NOR model whose mode persists across an Apollo reset | wisp-fw | M–L | yes: Renode NOR model | W26 |
| G20 | Update service (protocol `0x07`) with file-put: wisp-core service, firmware side, rule-3 checks on the glasses, an allowlist (Wisp Boot hashes and the stock pin), the flag through Wisp Boot's services table, the SDK API, a Mac sender | wisp-core, wisp-fw, wisp-sdk-ts | L | yes: native_sim end to end; Renode with the real bootloader's install | W26 |
| G21 | Fault variants (`CONFIG_WISP_FAULT_*`) of the real app, rerun in rung 3 | wisp-fw | S | yes | W29 |
| G22 | Authentication for the update service and file-put. Today anyone in range can open a session (wisp-fw README, "Still missing" 5). At least a shared key (an HMAC, as with the loader's `HOLD`) or bench-only enabling (R4-6) | wisp-core, wisp-fw, wisp-sdk-ts | M | yes | W27 |
| G23 | A real entropy source (TRNG) for the BLE host; today it uses Zephyr's test-only fake entropy | wisp-fw | S | partly | before daily use, not W24 |
| G24 | Wisp Boot keys its record on the image in MRAM (a build-id word in the app header at `0x448000`) as well as on the staging CRC word; rung-3 cases "`install-wisp` over a rescue-state record" and "over attempts = 2" | wisp-fw | S–M | yes | W27 |
| G25 | **Built** ([status](#tooling-status)). `loader-hello --no-release` (end the session holding the temple, without `CONT`), and `held-reset-test` around it | wisp-recovery | S | yes: fake temple | W21 |
| G26 | `flag-clear`: a pinned ≤ 512-byte program calling the patched bootloader's own `bootloader_error_reset` (it writes the documented clear record and resets; no new MRAM-write code), plus its tool command. Proven in Renode against the real patched bootloader with a set flag | wisp-recovery + wisp-fw (Renode) | S–M | yes | W27, before any BLE install |
| G27 | **Built (W22).** `native-0` keeps the nPM1300 watchdog armed at stock's period and kicks it every second (`power.c` today stops it) | wisp-fw | S | yes: `drivers-test`, `WispPmicWdt` | W24 |
| G10b | Answer the case app's `0x13` status poll as stock does, so a native temple in a case running its own app is not reset every 180 s (PR #73). Needs the reply layout from stock's `pt_protocol_procsr` handler and what the case does with its fields (soc, charging); not guessed in native-0 | docs (W20 follow-up) + wisp-fw | S–M | partly: the case side only by static analysis | before native temples are left in the case |

### Loose ends

- **Even firmware updates replace the patched bootloader** [I]. A full Even update from the Even app carries the bootloader component (type 1; every recent bundle has one). It would overwrite drdaeman's loader with a stock bootloader, removing the case recovery path, and it would reopen the 1-second install window that W18 accepted once. Until Jan decides otherwise: **decline Even firmware updates on both temples.** The same applies to repairing a reformatted NOR with a full Even update (next item).
- **NOR content** [?]. The Even bootloader formats the littlefs whenever the mount fails (hardware.md). A corrupt littlefs, or a NOR left in a volatile mode the bootloader's 1-1-1 reset cannot leave, would lose `/firmware/*.bin` at the next stock boot. The obvious repair, a full Even update, is the one above. W20: with `firmware/touch.bin` missing, stock skips the PSoC update and leaves the PSoC alone [C]. With the file present but different, it reprograms the PSoC from it; a missing `codec.bin` ends the codec upgrade at the file open [I] ([hardware.md](hardware.md#stock-24024-at-boot-with-firmwarebin-missing-or-wrong)). Hence W20's analysis, the inventory in `native-0`, the observe-only first image, and G18/G19's "stock's command modes only".
- **SWD lock state unknown** (INFOC/DCU skipped on both temples). **Not a rung-4 blocker.** SWD now matters only for a broken bootloader or SBL. W18's install was the one accepted window for that, rule 1 keeps native code out of the bootloader region, and G13 enforces it for the app. Reading the lock state needs OTP and CryptoCell powered from a pinned program (R4-5, optional).
- **Split-session pogo settle (the status-3 refusal).** Fixed in the tooling (G5, [Tooling status](#tooling-status)), in emulation only. The first split run on hardware shows whether 5 s of settle is enough; its report records when the case app's status lines came.
- **Battery.** It was never measured during W18: `--battery 80` was typed from the case's reading the evening before, and `recover` checks no battery at all. Rule 6 is written for BLE flashing ("temples out of the case"), while case writes need the temple seated. R4-4 asks rule 6 to name both setups. For case sessions:
  - the temple is seated, the lid open, the case on USB, and the Mac on its charger with `caffeinate`;
  - battery ≥ 80 %, read in the Even app while on stock, or **≥ 3,900 mV** from Wisp's status while native. Wisp's percentage is a coarse voltage estimate that reads high while charging; the mV threshold is to be confirmed against stock's 80 % at W21.

  Whether VBUS and charging continue during a relay session, and whether the loader is reachable from a deeply discharged temple, are open [?]. `native-0`'s status reports VBUS and charger state.
- **The case and a non-stock temple** (W20, [hardware.md](hardware.md#the-cases-temple-reset-case-1257)). Case 1.2.57 polls each seated temple with opcode `0x13`. After 8 missed replies it **resets that temple every 180 s** (unless a flag at `0x200000C0` is set) and shows the error LED after 210 s [C]. It never updates a temple: its only update path pulls its own `box.bin` from the temple and does not start without an answer [C]. None of this runs during a relay session. **For G10:** `native-0` should answer `0x13` as stock does, or every native boot with the case app running ends in a case reset within about 3 minutes. That is harmless (the loader runs first) but cuts W24's observation short.
- **The right (master) temple next to a native left** [?]. Stock talks to the left over the inter-temple UART and will get no answers. Nothing it sends can write to a Wisp temple, but the Even app may show errors while the left is native.
- **Rung 3 was never formally signed off** (safety.md, "Rung 3 status"). W17 asked for no more rung-3 work. This plan adds Wisp Boot changes, each of which reruns rung 3 (rule 12), so R4-7 asks Jan to allow them.
- The `w18-test` install cases k = 35/36 still hang Renode. The hang is pre-existing and limited to the install cases, so it does not affect rung 4.
- `image.py`'s SP bound (`0x20400000`) is looser than wisp-ota's (`0x20380000`). `install-wisp` uses the strict one.
- iOS: the Wisp update screen sends only `rung1` and `stock` images, and the Personal Team signing was due to expire on 2026-11-08 [I, project notes]. Route (b) does not need the phone.

## 8. Risks, and when to stop

**Risks, largest first:**

1. **The loader's reachability from a native state** (unproven until W21 and W24). If the case reset needs the stock app, or Wisp disturbs what the loader expects on UART2, the floor is gone. Mitigations:
   - W20's static analysis;
   - W21's held-temple reset test (the plan stops if it fails);
   - W24 tries the case reset and runs `recover` immediately after the first native boot;
   - `native-0` keeps the PMIC watchdog armed, so a full power cycle still comes even if everything else hangs.
2. **State that outlives a reset in another chip**, which case recovery cannot undo:
   - PMIC registers (rail voltages, BUCK1 above all, charger settings, ship mode). Mitigations: the snapshot, the per-session diff, G11 and G12, and no panel power in `native-0`.
   - The EM9305's NVM. Mitigation: rule 8's gates.
   - The PSoC's EEPROM: these images never send commands 5 or 7.
   - The NOR content. Mitigations: observe-only first, writes only under `wisp/`, stock's command modes only.
3. **An MRAM write by the app** reaching the bootloader region: the one native failure that ends in SWD. Mitigation: no MRAM write code in the app (G13). The only MRAM writer is Wisp Boot's single flag function, fault-tested in rung 3.
4. **The write itself.** `install-wisp` uses the code that wrote 3.7 MB twice. The vectors are zeroed first, so an interrupted write ends with the bootloader refusing the hand-off (after the loader has run), not with a mix of old and new code running. The exposure is about 4 minutes, against F2's 72.
5. **The flag trap** once BLE installs begin (W28). Mitigations: `flag-clear` proven first (G26), Wisp Boot's flag clear (G17), `rescue.bin`, and the update service's allowlist.
6. **EM9305 bring-up** with Even's controller firmware may not work under Zephyr's HCI driver (W11's fallback: AmbiqSuite + Cordio). This is not a brick; G10's status shows it.
7. **The PMIC watchdog during a rescue copy** (G16), and the copy's real duration.
8. **Boot attempts counted per case session** (§6). A forgotten `HELLO` makes `native-2` rescue itself to stock. That is safe, but surprising.
9. **The case link** depends on seating. W18 ran about 72 minutes twice without a problem.
10. **The unauthenticated update service** (G22), and the iOS GATT cache (G14).
11. **Human factors:** long sessions; the left temple out of everyday use while native; sides mixed up. The tools check the side through the case and the BLE name.

**Stop, report, and don't retry without a new go, if:**

- the held temple in W21 does not come back with `HELO`; or, after any native boot, a case reset and `loader-hello` fail twice after a reseat;
- `loader-hello` reads a bootloader CRC other than `63cd8dda`. Then don't reset the temple again ([recovery.md step D](recovery.md#step-by-step-for-jan-mac-left-temple-first));
- the flag reads anything but `0xFFFFFFFF`, or `0x55555555` in a step that set it on purpose;
- `install-wisp`, `recover` or `flag-clear` stops on a CRC mismatch or a refused resume check;
- `pmic_read` after a native boot differs from the snapshot anywhere but the watchdog timer;
- W21 shows a NOR that is neither MX nor GD, or a PMIC snapshot that disagrees with Wisp's DTS on a rail or a charger setting. Fix the build before W24;
- a native boot's status shows that the EM9305 update or recovery path ran (the gates make that impossible), that the NOR fails to mount after Wisp Boot wrote it, or any write outside `wisp/` on the NOR;
- the temple gets warm, loses more than about 10 % an hour while idle, or (from `native-1` on) the panel shows anything but the test pattern;
- after any return to stock, the Even app, Lotti, touch or the microphone misbehave. Stop before the right temple;
- the case doesn't come back on 1.2.57, or the relay exits with a status other than 6;
- anything happens that the step's expected output doesn't describe (W18's rule).

## Decisions for Jan

**All approved by Jan on 2026-11-08** ("I approve everything"). Where a decision offered a choice, the recommendation stands: R4-6 is a shared key (an HMAC, as with the loader's `HOLD`); R4-8's N is set in W26 and is long enough for a bench session; R4-5's program still needs its own go for its first run; `recover` keeps `--allow-pending-flag`.

| # | Decision | Needed before |
| --- | --- | --- |
| R4-1 | Route (b): extend rule 1's W18 exception to pinned Wisp images through `install-wisp`, and to the flag's clear record through `flag-clear` ([wording in §3](#3-how-it-gets-onto-the-temple)) | W24 (`flag-clear`: W27) |
| R4-2 | Rule 11: case recovery replaces `rescue.bin` for bench flashes. `rescue.bin` is still required before the fault test, BLE installs (with `flag-clear`) and daily use ([wording in §5](#5-rule-11-rescuebin)) | W24 |
| R4-3 | Wisp Boot may also write the flag's **clear** record, through the same single function. Rule 1 today says "the install record". With it, the app links no MRAM write path at all | W26 |
| R4-4 | The new rung-4 ladder row ([§1](#1-the-exit-check-for-rung-4)), and rule 6 naming the case-session setup (seated, case on USB, battery ≥ 80 % or ≥ 3,900 mV) | W24 |
| R4-5 | Optional: power OTP and CryptoCell from a pinned program to read INFOC/DCU (the SWD lock) | — |
| R4-6 | Update-service authentication: a shared key, or bench-only enabling | W27 |
| R4-7 | Changes to Wisp Boot after W17's "stays as built": the observe-only build, the status block, the PMIC kick, the flag clear and the image-keyed record. Each change reruns rung 3 (rule 12), now also on the patched bootloader | W22 |
| R4-8 | Optional: a native app that is running but unconfirmed resets itself after N minutes, so that "boots but useless" (F3) also ends in stock without a host | W26 |
| — | Practical: the left temple is native, and the glasses unusable with the Even app, during the W24–W30 sessions (W24 ends back on stock). After the later sessions, either `recover` to stock (about 72 min) or leave the temple native in the case. Decline Even firmware updates on both temples while W18's loader is relied on | W24 |
