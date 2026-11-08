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
  - *Update, rung-4 tooling (emulation only):* the writer now takes an image and its end bound, zeroes the vectors first, and `install-wisp` exists (G1), gated so that it refuses every image until R4-1 is approved and an image is pinned. See [Tooling status](#tooling-status).

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

- **G1, `w18.py install-wisp`: built, and closed.** `pins.R4_1_APPROVED` is `False` and `pins.WISP_IMAGES` is empty, so the command refuses every image before it touches the case; a test keeps the table empty while R4-1 is not approved. Opening it takes a reviewed commit that sets the flag after Jan's approval and pins a built `native-0` (image, ELF and map SHA-256, the `check_rule8` and no-MRAM-write gates) and its Wisp Boot in `pins.WISP_BOOT_PASSED` with both rung-3 suites (stock 2.4.0.24 and patched `87e2d4e0…`). `WISP_BOOT_PASSED` is empty too: the Wisp Boot that passed 26/26 (`8dd8fd69ef4b…`) ran on stock bootloaders only.
  - Checks before the case is touched: the pins above, `--expect`, `--battery` (≥ 80 % or ≥ 3,900 mV), the ELF's MRAM segments against the image, and rule 3 in both implementations: a Python port of wisp-ota's `checkMainPayload` (with two CRC-32 implementations), and wisp-ota's own, run by Node from its build (`pnpm nx run wisp-ota:build`; without it the command refuses). Both suites also run the same 26 vectors offline and must flag the same guards.
  - The writer gates too: `AppImage` refuses any image that is neither the stock pin nor, with R4-1 approved, in `WISP_IMAGES`, whoever builds it. The Renode harness pins its synthetic image in its own process only.
  - In every session, before any write: the `loader-hello` gate (bootloader CRC twice, flag clear, no override); then rule 3 again on the exact bytes the writer sends; the end bound is the image's own end.
  - Renode: `install-wisp` writes a synthetic non-stock image (the stock app with a marker appended, so it boots) through the real patched loader over a running stock app, and the boot ROM's write log shows the vectors zeroed first and written last, every write inside the bound. `install-wisp-cut` cuts the power half way: the vectors read zero, no app runs, the loader answers again, and a second session completes the image. G15 (Wisp Boot and the real app booting behind it) still waits for `native-0`.
- **Vectors zeroed first, also for `recover`: built.** Same CRC gates; a resumed run finds the vectors zero and does not rewrite them. A stopped `recover` now leaves a temple that does not boot until the write is resumed (before, stock over stock left it bootable). In Renode the patched bootloader then logs no hand-off and the loader answers at the next boot (`install-wisp-cut`). **Not yet seen on hardware:** a temple with zero vectors has never booted on silicon. The first `recover` with this tooling should be a deliberate step with its own go, before the change is relied on (a split `recover` passes through that state at every session boundary).
- `recover` keeps its old flag gate (refuse `0x55555555` unless `--allow-pending-flag`). `install-wisp` requires a clear flag, as R4-1 words it. If R4-1 is approved as worded, `recover` should require a clear flag too; that is left to the approval.
- **G5, the split-session status-3 fix: built.** The 13-byte `G2RS` is recognised at once (zero writes), the case record is checked as a zero-write record instead of a route restore, sessions after the first let the case app run 5 s after its banner (about 5 s more per session, so a 280-session split `recover` takes about 23 min longer), and a refused session is retried once after that. [recovery.md, Between sessions](recovery.md#between-sessions-the-pogo-switch-status-3).
- `link-soak`'s progress line counts the running stream (it printed "0 stream exchanges so far").
- **R4-1 in code (2026-11-08):** `pins.R4_1_APPROVED` is `True`. `pins.WISP_IMAGES` and `pins.WISP_BOOT_PASSED` stay empty until W23 pins `native-0` after review, so `install-wisp` still refuses every image; a test keeps both tables empty.
- **G4, W20's static analysis: done** ([hardware.md](hardware.md#rung-4-static-analysis-w20-2026-11-08)). `bootloader_error_reset` is at `0x42E156` in the patched image. The loader's precondition is the bootloader's own state. The case's reset is a pulse code on the pogo line, and case 1.2.57 resets a temple that has not answered its `0x13` status poll for 180 s. The NOR record is at `0x2000023C`: it tells GD apart, but MX and an unknown part read the same. The board strap is at `0x20027018`. Step 0's "hardware 5" is the panel's hw_version (JBD4010). Stock skips the touch update when `firmware/touch.bin` is missing, but reprograms the PSoC from a present but different file.
- **G3, `peek` and `pmic_read.bin`: built** ([recovery.md](recovery.md#rung-4-reads-peek-pmic_read-app-check-boot-watch-and-the-held-temple-reset)). `pmic_read.bin` is 504 B, `491f98f5…`. One kick, then 58 allowlisted registers, each by one write-read. The real binary runs under Unicorn, and `peek` and `pmic_read` run in Renode against the real patched bootloader (`w18-test` case `rung4-reads`). **Its first hardware run needs Jan's own go.**
- **G25, `loader-hello --no-release` and `held-reset-test`: built.** The second session's `HELO` must come within 3 s of its relay start and before the PMIC's watchdog could have fired after the first session's last kick, so a PMIC power cycle cannot pass for the case's reset.
- **G2, `app-check` and `boot-watch`: built.** `boot-watch` takes a pluggable `StatusProtocol` (`wisp_w18/status.py`); today only `listen` is registered. The Wisp protocol is G10's, and it must fit the pinned relay's frames: requests of 9, 25 or 32 bytes starting `7E 00 01 n-5`, answers of 13, 21, 29 or 32 bytes framed `5A A5 FF`.

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
| W22 | Build `native-0` and its tooling; emulate: rung 3 for the observe-only Wisp Boot (its own suite) and the fallback build, on the stock and the patched bootloaders, with the real app behind both (rule 12). A `w18-test` case writes `native-0` through the loader into the stock app region, then `CONT` → Wisp Boot → app, with the PMIC watchdog armed and the case-UART status answering | — | G1, G2, G5–G15, G27 |
| W23 | Independent review of `native-0` and `install-wisp`; pin the image, ELF and map hashes | — | W22 |
| W24 | **First native flash, left.** `loader-hello` and `pmic_read` → `install-wisp native-0` → `boot-watch` (`CONT`, then the case-UART status) → `HELLO` and a session from the Mac → the `/firmware/*` inventory from the status. **Then, the first thing after the first native boot: a case reset and `loader-hello` (stop if it fails), `pmic_read` (diff against W21), and `recover` back to stock (about 72 min).** Stock boots and the Even app works. Exit item 4, from a running native image | **W** | W19 (R4-1, R4-2, R4-4, R4-7), W21, W23 |
| W25 | `install-wisp native-1`: the first NOR writes by Wisp Boot, and the JBD test pattern with the gated BUCK1. 10 confirmed boots, the record read back through the status, a `HELLO` after every session, the PMIC diff at every session. Then F5 (a dead image, then `recover`). **Checkpoint 4a logged.** Gate: W20's answer on missing `/firmware/*`, and W24's inventory matching the pinned bundle | **W** | W24 |
| W26 | Build `native-2`: storage HAL (only `wisp/`), update service (receive, rule-3 checks on the glasses, an allowlist of Wisp Boot hashes and stock, stage, the flag through Wisp Boot's services, reset), file-put, authentication, Wisp Boot's PMIC kick, flag clear and image-keyed record, the loader's `flag-clear` program. Rung 3 reruns with the new cases. A native_sim end-to-end test of the update service; a Mac sender | — | G16–G24, G26, R4-3, R4-6 |
| W27 | `install-wisp native-2` → put `rescue.bin` over BLE → Wisp Boot's check reported OK and equal to the pin. **`flag-clear` proven on hardware**, with the flag already clear and stock staged | **W** (MRAM via the case, NOR via Wisp, the clear flag record) | W26 |
| W28 | Over BLE through the update service: Wisp → Wisp (a version bump: staging, flag, Even bootloader install, Wisp Boot clears the flag); then Wisp → pure stock 2.4.0.24 main; stock boots and the Even app works (**exit item 2**). Then `install-wisp native-2` again | **W** | W27 |
| W29 | Forced faults F1, F2 and F4 (no host action) and F3 (case resets), F6 optional; each ends in stock (**exit item 3**) | **W** each | W27, G16, G17, G21, G24 |
| W30 | The exit check's 10-boot run and 10-minute session, if not already logged at W25 (**item 1**); the final PMIC diff (**item 5**) | **W** (if a reinstall is needed) | W29 |
| W31 | Log rung 4 as passed (or not) in safety.md and README M6. Then the right temple: W21 and W24–W30 with `--side right`, each write with its own go | — / **W** | all |

### Gaps

Size: **S** < 1 day, **M** 1–3 days, **L** > 3 days, for one thread.

| # | Gap | Project | Size | In emulation? | Needed by |
| --- | --- | --- | --- | --- | --- |
| G1 | **Built, closed until R4-1** ([status](#tooling-status)). `install-wisp`, per R4-1: image, ELF and map pins; an end bound from the image; rule-3 checks rerun on the sent bytes; the Wisp Boot allowlist from the rung-3 suites; vectors zeroed first and written last (the same change for `recover`); `--expect`, `--battery`; a same-session `loader-hello` gate; a report | wisp-recovery | M | yes: fakes plus a Renode `w18-test` case | W24 |
| G2 | **Built** ([status](#tooling-status)). `app-check` (read-only: bootloader CRC, flag, the app region's CRC against the known images) and `boot-watch` (`CONT`, then status queries through the relay before `G2EX`; the status protocol is a hook, `listen` only until G10) | wisp-recovery | S | yes: fake case; `WispCaseLink` waits for G10/G15 | W24 |
| G3 | **Built** ([status](#tooling-status)). `peek` (allowlisted reads via `dump`/`dump_fed`) and `pmic_read.bin` (504 B, bootloader IOM7 HAL, write-read only, register allowlist proven in Unicorn), pinned | wisp-recovery | S–M | yes: Unicorn `temple_cpu`, Renode `rung4-reads` | W21 |
| G4 | **Done** ([hardware.md](hardware.md#rung-4-static-analysis-w20-2026-11-08)). The static analysis for W20 | docs (hardware.md, recovery.md) | S–M | n/a (static) | W21, W24, W25 |
| G5 | **Built** ([status](#tooling-status)). The split-session pogo-settle fix: `_arm` (`links.py:217-228`) recognises the bridge's 13-byte `G2RS` and reports status 3 at once, instead of a 60 s "got 13 of 16 bytes"; plus a settle wait in `run_sessions` or `CaseRelayLink.start` | wisp-recovery | S | yes: fake case | before relying on `--max-session-s` or `--no-temple-feed`; recommended before W24 as plan B |
| G6 | The real app behind Wisp Boot: link at `0x448000`, `sram0` and the stack out of `0x20370000+`, a combine step for the real app (today only `tests/boot/app/combine.cmake` for fault apps), a `pack-main` target for later | wisp-fw | M | yes: Renode, rung 3 with the real app | W24 |
| G7 | The app feeds the locked 8 s watchdog (a raw `RSTRT` write, because Wisp Boot locked the configuration) from a `k_timer` or the highest-priority thread, started before `bt_enable()` | wisp-fw | S | yes | W24 |
| G8 | `confirm()` through the services table after `HELLO` | wisp-fw | S | yes: a rung-3 `good`-style case | W24 |
| G9 | The observe-only Wisp Boot build (writes compiled out, decision forced to `run-app`), the RAM status block with the `/firmware/*` inventory, and its own rung-3 suite | wisp-fw | M | yes | W24 |
| G10 | Case-UART status: a UART2 node; answers to the `24` version query and to a Wisp status query; a reset command (also over BLE); the host side in step 0 and `boot-watch` | wisp-fw + wisp-recovery | M | yes: `WispCaseLink` in Renode, fake case | W24 |
| G11 | No default panel; JBD4010 for hardware 5 (or a runtime choice from the ADC strap); BUCK1's code gated against W21's snapshot; the test pattern (`native-1`) | wisp-fw | S | yes: `drivers-test` JBD | W24 (no default), W25 (pattern) |
| G12 | PMIC values checked against W21's snapshot over every register the Zephyr MFD, charger and regulator drivers write; a review that the app never enters ship or hibernate mode and never changes charger limits from stock's | wisp-fw | S–M | partly | W24 |
| G13 | A no-MRAM-write gate over `[0x448000, end)`, post-link like `check_rule8.py`: no `am_hal_mram_*`, `nv_program_*`, `0x0200FF20` or `0x12344321`, and the MRAM flash driver off | wisp-fw | S | yes (negative build) | W24 |
| G14 | A Mac-side session tool (the TS SDK's `Transport` over a Node BLE binding, or a bleak bridge). Test from the Mac, not iOS, so that iOS's cached stock GATT database for that address doesn't interfere | wisp-sdk-ts / tools | S–M | yes: native_sim + Bumble | W24 |
| G15 | A `w18-test` case: `install-wisp` into the stock app region, `CONT`, then Wisp Boot and the app booting behind the real patched bootloader, PMIC watchdog armed. Note: Renode resets every register on reset, so it cannot catch state that persists on silicon; W21 and W24 do | wisp-fw (Renode) | S–M | yes | W24 |
| G16 | Wisp Boot kicks the nPM1300 watchdog during long work, the rescue copy above all (a PIO I2C7 write as in `pmic_kick.h`); rung-3 cases with `WispPmicWdt` armed | wisp-fw | M | yes | W27, W29, and any BLE install |
| G17 | Wisp Boot clears the flag after a new install, with the documented clear record through the same single function (R4-3); rung-3 cases including power cuts around it | wisp-fw | S | yes | W28 |
| G18 | GD25LE256H support in Wisp Boot's NOR driver, and a NOR model answering `C8 60 19`. **Only if W21 finds GD.** Same command modes as stock: no QPI/OPI, no volatile-configuration writes | wisp-fw | S–M | yes | W24 |
| G19 | Storage HAL: littlefs on MSPI1 in Zephyr, sharing Wisp Boot's geometry and driver, writes **only under `wisp/`**, stock's NOR command modes only, coexisting with the Even bootloader's `boot_count` writes. A Renode NOR model whose mode persists across an Apollo reset | wisp-fw | M–L | yes: Renode NOR model | W26 |
| G20 | Update service (protocol `0x07`) with file-put: wisp-core service, firmware side, rule-3 checks on the glasses, an allowlist (Wisp Boot hashes and the stock pin), the flag through Wisp Boot's services table, the SDK API, a Mac sender | wisp-core, wisp-fw, wisp-sdk-ts | L | yes: native_sim end to end; Renode with the real bootloader's install | W26 |
| G21 | Fault variants (`CONFIG_WISP_FAULT_*`) of the real app, rerun in rung 3 | wisp-fw | S | yes | W29 |
| G22 | Authentication for the update service and file-put. Today anyone in range can open a session (wisp-fw README, "Still missing" 5). At least a shared key (an HMAC, as with the loader's `HOLD`) or bench-only enabling (R4-6) | wisp-core, wisp-fw, wisp-sdk-ts | M | yes | W27 |
| G23 | A real entropy source (TRNG) for the BLE host; today it uses Zephyr's test-only fake entropy | wisp-fw | S | partly | before daily use, not W24 |
| G24 | Wisp Boot keys its record on the image in MRAM (a build-id word in the app header at `0x448000`) as well as on the staging CRC word; rung-3 cases "`install-wisp` over a rescue-state record" and "over attempts = 2" | wisp-fw | S–M | yes | W27 |
| G25 | **Built** ([status](#tooling-status)). `loader-hello --no-release` (end the session holding the temple, without `CONT`), and `held-reset-test` around it | wisp-recovery | S | yes: fake temple | W21 |
| G26 | `flag-clear`: a pinned ≤ 512-byte program calling the patched bootloader's own `bootloader_error_reset` (it writes the documented clear record and resets; no new MRAM-write code), plus its tool command. Proven in Renode against the real patched bootloader with a set flag | wisp-recovery + wisp-fw (Renode) | S–M | yes | W27, before any BLE install |
| G27 | `native-0` keeps the nPM1300 watchdog armed at stock's period and kicks it every second (`power.c` today stops it) | wisp-fw | S | yes: `drivers-test`, `WispPmicWdt` | W24 |

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
