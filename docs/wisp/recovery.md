# Wisp — recovery: how a temple gets unbricked

Decision W17 ([README](README.md#decisions)) sets the one hard requirement before the first native flash (rung 4): a temple can always be **unbricked**, by cable if the hardware access is easy, or by an automatic fallback. This document compares the routes. It is research only: nothing here touched glasses.
Researched 2026-11-06. **[C]** = confirmed in the cited source, **[I]** = inferred, **[?]** = open. The sources are listed [at the end](#sources).

## Summary

- **SWD by cable: hard, and probably destructive.** The temple pods are glued; the FCC lab pried them off and cut the wires. The SWD pads are unlabelled and nobody has mapped them. The pins run at 1.8 V. Nobody has attached a probe to a G2 or a G1. Debug may be locked in OTP, and only Even could reopen it. It is not a route for Jan's only pair of glasses.
- **The charging case is the cable we already have.** Each temple's pogo contacts carry the Apollo's UART2 at 1 Mbaud, and the case can reset a temple and relay that UART to USB from a RAM program, without changing its own flash. The **stock** Even bootloader never listens on it, so today nothing can reflash a temple whose main app is dead.
- **drdaeman/g2-bootloader-patch** (MIT) adds a UART2 RAM loader to the bootloader. With it, the case can stop a temple at boot, run code in RAM, and write the main app straight to MRAM. It has been hardware-tested on both temples of a hardware-5 pair with app 2.4.0.24, but a full app replacement has not been tested yet. Installing it means writing the bootloader once, and today W1 and safety rules 1–2 forbid that.
- **Wisp Boot's fallback to stock is built and passes 26/26 in Renode**, but it covers only failures after Wisp Boot has run. Its first run on hardware _is_ the first native flash, so it cannot be proven on hardware first.
- **Recommendation:** first prove the case link on stock with no temple writes. Then let Jan decide on one bootloader write: the patched loader on the left temple, proven by a full stock-over-stock app recovery through the case. If that passes, it is the path that W17 asks to have proven. Nothing has to be bought for it. Details are under [Recommendation](#recommendation).

## 1. SWD on the temples

### What is known

| Question                          | Answer                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| FCC filing                        | **FCC ID 2BFKR-G2** (grantee 2BFKR = Even Realities), granted 2025-11-23, lab NTEK. Internal photos have been public since 2026-05-21; schematics and the block diagram are long-term confidential [C, fccid.io]. The case has no radio and no FCC ID; the test report lists it only as support unit "AE-3 Case" [C].                                                                                                                                                                                                                                                                                                                                                                                                         |
| What the photos show              | Two boards per temple, about 25×8 and 28×9 mm. One carries the MCU, marked **"4M AP510BFA 251803"** (the AP510BFA-CBR package that SEGGER lists), next to the GX8002 [C, photo 6]. The other carries a large blue QFN marked "AM308C" and two board-to-board FPC connectors. About 20 round gold pads run along the board edges, with large square pads at the corners; **no silkscreen labels (TP, SWDIO, SWCLK) are readable** at the photos' resolution [C, photos 5–6]. Which pads, if any, are SWD is unknown [?].                                                                                                                                                                                                       |
| How the shell is closed           | The rear end-pods are glued: the FCC photos show adhesive residue, pods pried off and temple wires cut [C, internal photos]. The G1 photos show the same. No public G2 teardown exists (iFixit, YouTube, Reddit, HN: none) [C, not found]. A non-destructive opening is unproven, and unlikely [I].                                                                                                                                                                                                                                                                                                                                                                                                                           |
| SWD pins on the chip              | SWDCK = GPIO20, SWDIO = GPIO21, function 0 (reset default), on the **VDDH domain, 1.71–2.20 V** (datasheet pin table, Table 11, electrical tables) [C]. The AP510BFA is a BGA: the balls cannot be probed, only pads or vias that route to them [I].                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Reachable through the pogo pins?  | No. The contacts carry power and UART2 (GPIO42 TX, GPIO44 RX) [C, webflasher]. SWD (GPIO20/21) is not routed to them as far as anyone knows [I]. The pin count is not documented [?].                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Anyone attached a probe?          | **No public report for the G2 or the G1** (openCFW, webflasher, g2flash, faceclaw, g2emu, drdaeman, Reddit, the web) [C, not found]. openCFW's validation notes say its authors had no probe at all. drdaeman's own last resort is to "open up the temple and try flashing back with JTAG, hoping it's accessible". The G1 is a different chip anyway (nRF5340, inductive charging), so it tells us nothing.                                                                                                                                                                                                                                                                                                                  |
| Debug locked by Even?             | **Unknown.** The Apollo510 can lock debug for good: the CryptoCell's debug control unit (DCU) has an SWD enable bit (`AM_HAL_DCU_SWD`) and one-way lock registers, and OTP INFOC holds `LOCKMASK0-3`, `DCU_DISABLEOVERRIDE` and a secure-debug certificate pointer. A locked part reopens only with a **per-chip debug certificate signed by the OEM** (INFO1 `SOCID0-7` exists for that) [C, hal_ambiq `am_hal_dcu.h`, `am_mcu_apollo510_otpinfoc.h`, datasheet §5.8–5.10]. How a locked Apollo5 looks to a probe is not public; on CryptoCell designs the DP usually still answers IDCODE while AP and core accesses fail [I]. drdaeman reports that Even did not enable image signing, which says nothing about debug [I]. |
| INFO0 / secure boot (hardware.md) | hardware.md had "SBL UART recovery depends on per-device INFO0 provisioning nobody has read yet". Still true: **no retail INFOC/INFO0 dump is public** [C, not found]. The fields that decide recovery are listed in [section 3c](#3c-ambiq-sbl-wired-update-and-mram-recovery).                                                                                                                                                                                                                                                                                                                                                                                                                                              |

### Do the charging pins carry anything besides power?

Yes, a UART [C]. The temple's **UART2** (`0x4003B000`) runs at 1 000 000 baud 8N1 without flow control: Apollo GPIO42 (TX) goes to case PB9 (USART3_RX), and GPIO44 (RX) is driven by case PB8 (USART3_TX). The case picks left or right through its YHM2510 front end [webflasher README; g2emu `apollo510-m1-stream.repl` models UART2 as "the charging-case link"]. On it, the **main app** speaks `5A A5 FF <cmd>` frames, including a product-test OTA (commands `0x52`–`0x55`) [webflasher, openCFW `g2-glasses.md`]. The **bootloader does not initialise UART2** [C, webflasher; confirmed below].

The "UART log in the bootloader" is a different port. In stock bootloader 2.4.0.24 (local copy, static analysis on 2026-11-06), EasyLogger writes through `redirect.c` to **UART0** (`0x40039000`, the only UART base among its literals). That port is not on the pogo pins as far as anyone knows [I]. The bootloader has **no receive path**: its UART0 interrupt vector points to the default handler (the same address as IRQ 0), and its only tasks are `task.manager` and `task.dfu`, the latter fed by the update flag (`EVENT_DFU_VALID`). It has no box, TinyFrame or command strings [C].

**The "7 bootloader modes"** in [docs/spikes/custom-firmware.md](../spikes/custom-firmware.md) come from a field in the Even app's protobuf. No such modes exist in the bootloader binary [C, static]. The same spike's line "the charging case's CH340 USB→UART is the recovery/brick path" holds only while the main app runs: the case's UART OTA is handled by the main app (hardware.md, 2.4.0.24 OTA receiver), and the webflasher says outright that it is "not a dead-temple recovery tool".

The Ambiq SBL prints boot status as **SWO on GPIO28 at 1 Mbaud** by default (pin configurable in INFOC `SEC_POL.SBL_SWO_PIN`) [C, datasheet]. That only helps once the temple is open.

## 2. What the cable route would take

### Shopping list (SWD)

| Item                                                  | Price           | Note                                                                                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------------------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **SEGGER J-Link EDU Mini**                            | $76             | The only cheap probe with confirmed Apollo510 support (device `AP510BFA-CBR`, J-Link software ≥ V7.89h; SEGGER KB "Apollo5": custom reset because the SBL runs first; the SBL area at `0x400000` can't be programmed). Licence: non-commercial use only, which fits a personal project. SEGGER lists 1.8 V and 3.3 V targets; check the VTref range on the product page before buying. |
| Raspberry Pi Debug Probe / Pico running debugprobe    | $12 / $5        | CMSIS-DAP, **3.3 V I/O into a 1.8 V domain: needs a level shifter**. Neither OpenOCD nor pyOCD supports Apollo510 (OpenOCD only has Apollo 1/2; pyOCD only through Ambiq's DFP pack, unverified). Fine for reads at best. Not recommended.                                                                                                                                             |
| ST-Link V2/V3                                         | ~$11            | Locked to STM32 targets. **Unsuitable.**                                                                                                                                                                                                                                                                                                                                               |
| 0.1 mm magnet wire, or Kynar 30 AWG                   | $1–11           | Soldered to pads under a microscope. Pogo pins (P50/P75, €13 per 100) or a 3D-printed jig only make sense once a pad map exists; a Tag-Connect needs a footprint the board doesn't have.                                                                                                                                                                                               |
| Fine iron tip, flux, Kapton tape, a stereo microscope | ~$30–200        | The boards are 8 mm wide. PCBite probes (~$150) are an alternative to soldering.                                                                                                                                                                                                                                                                                                       |
| **A spare G2**                                        | used-pair price | In practice, a donor pair for the first opening, not Jan's daily glasses.                                                                                                                                                                                                                                                                                                              |

### Steps and risks

| #   | Step                                                                                                                                                                                                                                                        | Risk                                                                                                                                                                                          |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Open the rear end-pod of a temple: heat the glue, then pry.                                                                                                                                                                                                 | **High.** The FCC lab cut the temple wires to do it. Risks: flex and antenna damage, puncturing the 96 mAh LiPo, a pod that won't close or seal again.                                        |
| 2   | Find SWDIO/SWCLK/GND/VDDH(1.8 V)/nRST among the ~20 unlabelled edge pads: measure the 1.8 V rail and GND; probe the remaining pads for SWD with J-Link's auto-detect or a JTAGulator-style scan.                                                            | Medium. Shorts and ESD on a powered 1.8 V board. Nothing guarantees that SWD reaches a pad at all; it may be on an unreachable via under the BGA.                                             |
| 3   | Solder magnet wire to the pads, VTref to 1.8 V. **Read-only attach**: J-Link Commander, `device AP510BFA-CBR`, `si SWD`, `speed 100`, `connect` without reset; read the DP IDCODE and `mem32` a few words.                                                  | Low for the chip if VTref is right. A 3.3 V probe without a shifter can damage it. Never use J-Flash or IDE "download" buttons; only Commander, and never `erase`, `loadbin` or `w4` to MRAM. |
| 4   | Dump INFOC (`0x400C2000`, 0x400 bytes; OTP may need powering up first), INFO0 (`0x42000000` MRAM and `0x42004000` OTP, at least 0x6C bytes) and the DCU state; then `savebin` MRAM `0x410000–0x800000` (the SBL area may be read-protected by `SBL_RPROT`). | Low. If debug is locked, this step fails and the opening was for nothing.                                                                                                                     |
| 5   | Recovery itself: J-Link `loadbin` of the stock main app at `0x438000`.                                                                                                                                                                                      | Medium. Only after steps 3–4 work and only to `0x438000+`, never the SBL, the bootloader or `0x7FE000+` (safety rule 1).                                                                      |
| 6   | Close and seal the pod.                                                                                                                                                                                                                                     | Water and dust resistance gone; wires soldered to a moving hinge.                                                                                                                             |

**Rating: hard / destructive.** Every step is doable for someone with microsoldering gear. What makes it hard is that step 1 likely destroys the pod, step 2 might find no SWD pad, and step 4 might find debug locked. Each is a dead end that costs a temple. Before anything else, someone has to take a donor temple apart and publish the pad map. That would make SWD a medium-difficulty repair method; it cannot be Wisp's first recovery path.

## 3. Software and case recovery routes

Each route below lists what it covers and the failure it does not. **"Wisp-dead"** means the native app crashes, hangs or never brings BLE up.

### 3a. Wisp Boot falls back to stock (built)

Wisp Boot (16.8 KB at `0x438000`) counts boots in `wisp/boot.rec`. After 3 unconfirmed boots, or a touchpad rescue hold, it copies `wisp/rescue.bin` to the staging file, sets the flag and resets, and the Even bootloader installs stock ([safety.md](safety.md#fallback-to-stock-designed-into-native-mode)). Rung 3 shows 26/26 in Renode against the real 2.2.6.10 and 2.4.0.24 bootloaders.

- **Covers:** Wisp-dead after Wisp Boot ran, a watchdog that never gets fed, an erased app slot, a corrupt boot record, and power cuts at any point of the rescue.
- **Does not cover:**
  - A crash or hang inside Wisp Boot itself. Its real NOR driver, MSPI timing, clocks and power state have never run on glasses, and our NOR part is unknown (MX25U25643G vs GD25LE256H; the Renode model answers MX).
  - A missing or corrupt `rescue.bin` (rule 11).
  - A broken bootloader or SBL.
  - A NOR so corrupt that littlefs won't mount.
- **Provable on hardware before rung 4?** **No.** Stock is linked to `0x438000`, so no image can run Wisp Boot in front of stock. Wisp Boot's first run on hardware is the first native flash. Rung 4's forced-fault test proves it there, which is too late to count as the net for that same flash.

### 3b. Wisp Boot falls back to a minimal Wisp recovery image

The same mechanism, but `rescue.bin` is a small Wisp image (BLE + update service only) instead of stock.

- **Covers:** the same as 3a, and stays inside Wisp (W17 allows that).
- **Does not cover:** everything 3a misses. In addition, the recovery image depends on **our own BLE stack working on real hardware**: Zephyr `hci_ambiq` against Even's EM9305 build, with rule 8's EM9305 reflash hazard. That is the least proven part of native mode. Stock's BLE OTA path is proven (rung 1).
- **Verdict:** worse than 3a as the first net. It is worth having later as a second tier (stock first, then a Wisp recovery image) once native BLE is proven.

### 3c. Ambiq SBL wired update and MRAM recovery

The SBL can take a "secure wired update" over UART or SPI and has "MRAM recovery" from external flash or a wired host, started by a GPIO pin or by an invalid image. Every successful recovery burns one bit of the OTP counter `MRAM_RCVY_CNT` [C, datasheet §5.5, hal_ambiq `am_hal_mram_recovery.c`, `am_hal_secure_ota.h`]. Whether a temple offers it depends on per-device provisioning:

- INFOC `SECURITY.CUST_SECBOOT` (0x2 = on, 0x5 = off) and `SEC_POL.AUTH_ENFORCE`/`ENC_ENFORCE`. When these are on, images must be signed, and maybe encrypted, with Even's keys [I, from field docs].
- INFOC `BOOT_OVERRIDE` (override GPIO and polarity) and `WIRED_CONFIG` (UART enable and module).
- INFO0 `SECURITY_WIRED_IFC_CFG0-5` (baud and pins), `WIRED_TIMEOUT`, `MRAM_RCVY_CTRL` (`MRAM_RCVY_EN` = 0x6, `WIRED_RCVY_EN`, the GPIO pin).

For the pogo route to work, INFO0 would have to hold config word `0x0F4240C0` (1 Mbaud 8N1) and pin word `0x00002A2C` (GPIO44/42), and INFOC would need wired UART enabled [webflasher's hypothesis]. Evidence so far says it does not: drdaeman writes that Even "have not enabled any debugging and firmware-updating facilities on the pogo pins". openCFW sent the Ambiq wired HELLO `14559de900000800` through a case-RAM bridge and never got an answer, though its three attempts were cut short by setup issues.

- **Covers (if provisioned and unsigned):** everything above the SBL, including a broken Even bootloader.
- **Does not cover:** anything if it is not provisioned. A secure-boot policy needs Even's keys.
- **Verdict:** unlikely, but cheap to settle **once INFOC/INFO0 are read**. Reading them needs code on the temple (3d, or SWD).

### 3d. Patched bootloader: drdaeman's UART2 RAM loader through the case (MIT)

[drdaeman/g2-bootloader-patch](https://github.com/drdaeman/g2-bootloader-patch) at `1d22097`, MIT, so its code may be reused with credit (W10). Facts from its README and PROTOCOL.md:

- It patches the stock **2.3.2.14** bootloader, checked by SHA-256. 2.3.2.14 differs from 2.4.0.24's bootloader in one NOR helper and has the GD25LE256H driver (hardware.md). It is installed through the **stock BLE OTA** as a type-1 component, so the main app must be working at install time. The tool then reads back the installed bootloader's CRC twice through the case.
- At boot the patched loader sends a `HELO` beacon on UART2. The host has **500 ms** to answer with an HMAC-SHA256 `HOLD`; the default key is `DEFAULTNOTSECRET`, and a private key is optional. It then runs position-independent RAM programs (2–512 bytes; API v2 adds a streaming `recv`), and `CONT` releases boot into the main app.
- The **case relay** is a RAM program loaded into the case (case firmware **1.2.57**). It resets the temple with the stock reset waveform and relays UART2 to USB. **Case flash does not change.** The 2.4.0.24 bundle we pin carries case 1.2.57 [C, strings], and openCFW saw a retail case report "B200 1.2.57" [C].
- `tools/recover.py` writes a main app **straight to MRAM** (body first, then the vectors once the body's CRC checks out), bypassing littlefs and the NOR.
- **Hardware-tested:** loader, `HELO`/`HOLD`/`CONT`, echo, checksum, dump, on both temples of a hardware-5 pair with app 2.4.0.24. `recv` and the writer were tested on the right temple: streamed input, CRC rejection, and program, read back and restore of an unused 1 KiB MRAM range. **Full application replacement has not been hardware-tested.**
- Install risk, in its own words: flashing a bootloader "MAY IRREPAIRABLY BRICK YOUR GLASSES". The bootloader component is copied straight to `0x410000`, with no second copy, so a power loss or crash during that copy (about 150 KB) leaves only SWD [C, webflasher README].

- **Covers:** every failure above the bootloader. That includes the cases 3a misses: Wisp Boot hanging, a missing `rescue.bin`, a NOR that won't mount (the writer doesn't use it), and an app that never brings BLE up. No opening, no probe, only the case and a USB cable. It also lets us **run Wisp code from RAM on real hardware** (Wisp Boot's NOR driver, clock and power state) **without writing MRAM**, which is how Wisp Boot can be qualified before rung 4. And it can **dump INFOC, INFO0 and the DCU state** (a `dump.bin`-style program; OTP needs power first), which settles 3c and whether SWD is open.
- **Does not cover:**
  - A broken bootloader or SBL. The install itself is the one window where that can happen.
  - A temple that doesn't seat in the case, or dirty contacts (the README warns the link gets flaky).
  - A main app that disturbs UART2 before the loader runs. It can't: the loader runs before the app.
- **Conflicts with Wisp rules:** W1 (keep the Even bootloader stock), safety rule 1 (never write the bootloader) and rule 2 (never send type 1). Using it needs a new decision by Jan (proposed W18 below). `wisp-ota` would keep refusing type 1; drdaeman's own `flash.py` on the Mac would do the one install.

### 3e. Wisp Boot listens on UART2 (our own, no bootloader change)

The same case relay, with the listener in Wisp Boot instead of the bootloader. Wisp Boot opens a short window on UART2 at every boot (like the 500 ms `HELO`/`HOLD`). In that window the host can stream a stock main image into the staging file and set the flag (the Even bootloader installs it), or into `wisp/rescue.bin`.

- **Covers:** Wisp-dead, a missing or corrupt `rescue.bin`, and BLE never coming up, all through the case with no bootloader write. W1 and rules 1–2 stay as they are.
- **Does not cover:** Wisp Boot itself being broken (the same gap as 3a), a NOR that won't mount, a broken bootloader. It also can't be proven on hardware before rung 4.
- **Verdict:** a good second layer under native, and cheap to add to Wisp Boot (UART2 PIO, no interrupts, keeps Wisp Boot minimal). It can't be the proof that W17 asks for.

### 3f. Even support

No public brick reports or RMA experiences [C, not found]. Even's support articles only cover failed updates (restart in the case, factory reset). Not a plan.

### Ranking

| Route                              | Safety of using it                                            | Work                                        | Proven on hardware before rung 4? | Gap it leaves                          |
| ---------------------------------- | ------------------------------------------------------------- | ------------------------------------------- | --------------------------------- | -------------------------------------- |
| 3d patched bootloader + case relay | high once installed; **one risky install** (bootloader write) | low (exists, MIT); we add the qualification | **yes**                           | bootloader/SBL broken                  |
| 3a Wisp Boot → stock               | high                                                          | done                                        | no (first run = rung 4)           | Wisp Boot broken, no `rescue.bin`, NOR |
| 3e Wisp Boot UART2 listener        | high                                                          | small                                       | no                                | Wisp Boot broken, NOR                  |
| 3b Wisp Boot → Wisp recovery image | medium (depends on our BLE)                                   | medium                                      | no                                | as 3a plus our BLE stack               |
| SWD (section 2)                    | destructive to reach                                          | high, unknown pads                          | only by opening a temple          | debug may be locked                    |
| 3c Ambiq SBL wired/MRAM recovery   | n/a                                                           | n/a                                         | probably not provisioned          | everything, unless INFO says otherwise |

## Recommendation

**Prove 3d first**, as the one recovery path that can be proven on real hardware before any native code runs from MRAM. Keep 3a (and later 3e) as layers above it. Order:

0. **No temple writes, no purchases.** On t3-worker, port the case relay's host side and pin drdaeman at `1d22097`. On the Mac, with Jan, load the relay into the case's RAM and exchange one read-only stock `5A A5 FF` frame with the left temple's main app. This proves the USB → case RAM → UART2 → temple link on Jan's case and confirms its firmware is 1.2.57. The case's RAM program goes away with a case power cycle. Risk: low, to the case only. **Tool: [`apps/wisp-recovery`](../../apps/wisp-recovery/README.md).** drdaeman's relay itself always resets the temple and waits for the patched loader's `HELO`, so step 0 loads the program it extends instead: the webflasher's unmodified 1,720-byte read-only bridge, through the same STM32 ROM path. The temple gets one 5-byte version query (`24 00 01 00 a7`) and answers with a `5A A5 FF` frame. **Passed 2026-11-06** on Jan's left temple: case 1.2.57 (flash SHA-256 `773b6d4c…`), the reviewed bridge stopped at a zero-write baseline check (register 8 = `0x33`, a per-case identity byte), the pinned observed-33 variant (`3ca8ed1d…`) then went through. The temple answered `5aa5ff0924010305020400180557` = main app 2.4.0.24, hardware revision 5. Pogo switch registers restored, SRAM zeroed, case back on 1.2.57. No flash, option-byte or MRAM writes anywhere.
1. **Jan decides W18** (proposed below): one bootloader write per temple, left first, accepted as the price of a permanent cable-free recovery path.
2. **Install** the patched 2.3.2.14 bootloader on the left temple: drdaeman's `flash.py` from the Mac, case on USB power, battery > 80 %, nothing near that can bump the case (openCFW once lost a temple's link to a bumped case), an explicit per-flash go (rule 4). Then check that the main app still boots and the Even app works.
3. **Prove it:** `HELO`/`HOLD`/`CONT` through the case; `checksum` of the bootloader; **dump INFOC, INFO0 and the DCU state** into the hardware log (this answers 3c and whether SWD is open).
4. **Prove recovery:** `recover.py` writes pure stock 2.4.0.24's main app over the identical installed app. Full replacement, with the readback CRC checked; then boot, BLE and the Even app work. This is the step drdaeman has not run on hardware. Only after this has passed may rung 4 open.
5. Then qualify Wisp Boot from RAM through the loader (NOR ID, littlefs mount, a `boot.rec` round trip) before its first MRAM run, and add the 3e listener to Wisp Boot.

**What Jan has to do or buy:** nothing to buy for this path: the case, a USB-C cable to the Mac, and his time for steps 0 and 2–4. Only if he also wants the SWD route: a J-Link EDU Mini ($76), magnet wire, flux and a fine tip (~$30), magnification, **and a donor G2 to open**.

**If Jan says no to W18:** no recovery path can be proven on hardware before rung 4. The only nets are 3a and 3e, both unproven on hardware, and SWD is a destructive last resort. In that case I would not open rung 4 on Jan's pair.

### Decision W18 (Jan, 2026-11-06: **accepted, option A**)

> Allow exactly one bootloader write per temple: drdaeman's patched 2.3.2.14 bootloader (MIT, pinned at `1d22097`, SHA-256 of the output pinned in the hardware log), installed with its own tool, left temple first. Purpose: a UART2 recovery loader reachable through the case. After it, safety rules 1–2 apply again unchanged: Wisp never writes the bootloader, `wisp-ota` never sends type 1.

## Open questions

- Jan's case firmware version (1.2.57 expected) and the temples' hardware version (drdaeman tested hardware 5).
- Whether the bootloader in MRAM is the 2.4.0.24 one. It doesn't matter for 3d, which replaces it entirely.
- INFOC / INFO0 / DCU contents: is SWD open, is SBL wired recovery provisioned, is secure boot off? Step 3 answers this.
- How long `recover.py` takes for 3.6 MB at 1 Mbaud through the relay (about 40 s raw at best [I]) and whether the temple stays powered and seated throughout.
- The pogo pin count and the 1.8 V/3.3 V levels on the UART lines (the case's YHM2510 level-shifts them).
- The SWD pad map: needs a donor teardown, and nobody has published one.
- The "AM308C" QFN on the second board (unidentified; probably not relevant).

## Sources

- FCC ID 2BFKR-G2: <https://fccid.io/2BFKR-G2>; internal photos <https://fccid.io/2BFKR-G2/Internal-Photos/Internal-photos-8787893.pdf>; grantee list <https://fccid.io/2BFKR>; G1: <https://fccid.io/2BFKR-G1>, <https://fccid.io/2BFKR-G1CASE>.
- drdaeman/g2-bootloader-patch (MIT) at `1d22097`: README.md, PROTOCOL.md — <https://github.com/drdaeman/g2-bootloader-patch>.
- AM-Guru/evenRealities-webflasher (MIT) at `2fcdb88`: README (pogo UART route, "not a dead-temple recovery tool", INFOC/INFO0 recovery fields, "OMIT FROM POGO") — <https://github.com/AM-Guru/evenRealities-webflasher>.
- kalanihelekunihi/evenRealities-openCFW (MIT) at `55c7582e`: `g2/docs/reference/hardware-validation-notes.md` (case interruption, Ambiq HELLO attempts), `docs/hardware/g2-glasses.md`, `docs/tooling.md`, `docs/hardware/regulatory.md` — <https://github.com/kalanihelekunihi/evenRealities-openCFW>.
- ithinkthisiscool/g2emu (MIT): `apollo510-m1-stream.repl` (UART2 = case link).
- Ambiq Apollo510 SoC datasheet DS-A510-1p1p0: <https://contentportal.ambiq.com/documents/20123/2877485/Apollo510-SoC-Datasheet.pdf>; SecureSPOT comparison guide: <https://contentportal.ambiq.com/documents/20123/1374765/Ambiq-SecureSPOT-Feature-Comparison-Guide.pdf>. Not read (login required): Apollo5 Secure Update and MRAM Recovery user's guides.
- AmbiqMicro/ambiqhal*ambiq at `d3278ec`, `mcu/apollo510/`: `hal/am_hal_dcu.{h,c}`, `hal/am_hal_security.{h,c}`, `hal/am_hal_info.h`, `hal/mcu/am_hal_secure_ota.h`, `hal/mcu/am_hal_mram_recovery.c`, `regs/am_mcu_apollo510*{otpinfoc,mraminfo0,mraminfo1}.h` — <https://github.com/AmbiqMicro/ambiqhal_ambiq>.
- SEGGER: <https://www.segger.com/supported-devices/ambiqmicro/apollo5/>, <https://kb.segger.com/Apollo5>, J-Link EDU Mini <https://shop-us.segger.com/product/j-link-edu-mini-8-08-91/>.
- Stock bootloader 2.4.0.24: local static analysis (strings, vector table, objdump) of the copy in `.wisp-cache/`, never committed.
- g2flash and faceclaw (GPL-3.0): facts only, no code.
