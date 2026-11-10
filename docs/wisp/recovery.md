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
2. **Install** the patched 2.3.2.14 bootloader on the left temple over the stock BLE OTA, with an explicit per-flash go (rule 4). Then check that the main app still boots and the Even app works. **Exact steps: [W18 procedure](#w18-procedure), steps A–C.**
3. **Prove it:** `HELO`/`HOLD`/`CONT` through the case; a CRC of the bootloader region; **dump INFOC, INFO0 and the DCU state** into the hardware log (this answers 3c and whether SWD is open). Steps D–E.
4. **Prove recovery:** write pure stock 2.4.0.24's main app over the identical installed app through the loader. Full replacement, with the readback CRC checked; then boot, BLE and the Even app work. This is the step drdaeman has not run on hardware. Only after this has passed may rung 4 open. Step F.
5. Then qualify Wisp Boot from RAM through the loader (NOR ID, littlefs mount, a `boot.rec` round trip) before its first MRAM run, and add the 3e listener to Wisp Boot. _Revised in [rung4.md](rung4.md#4-pre-qualification-without-writing-mram) (2026-11-08): from RAM, only read-only probes (NOR ID, PMIC snapshot, panel variant); Wisp Boot's read path is qualified by an observe-only build in the first native image instead, and the 3e listener is dropped because the patched loader covers it._

**What Jan has to do or buy:** nothing to buy for this path: the case, a USB-C cable to the Mac, and his time for steps 0 and 2–4. Only if he also wants the SWD route: a J-Link EDU Mini ($76), magnet wire, flux and a fine tip (~$30), magnification, **and a donor G2 to open**.

**If Jan says no to W18:** no recovery path can be proven on hardware before rung 4. The only nets are 3a and 3e, both unproven on hardware, and SWD is a destructive last resort. In that case I would not open rung 4 on Jan's pair.

### Decision W18 (Jan, 2026-11-06: **accepted, option A**)

> Allow exactly one bootloader write per temple: drdaeman's patched 2.3.2.14 bootloader (MIT, pinned at `1d22097`, SHA-256 of the output pinned in the hardware log), installed with its own tool, left temple first. Purpose: a UART2 recovery loader reachable through the case. After it, safety rules 1–2 apply again unchanged: Wisp never writes the bootloader, `wisp-ota` never sends type 1.

"Its own tool" became `apps/wisp-recovery/w18.py bootloader-install`: drdaeman's `flash.py`/`ble_ota.py` logic (MIT, credited), narrowed to the one pinned image, with the preconditions below enforced in code. `wisp-ota` still refuses type 1.

## W18 procedure

Prepared and emulated on t3-worker on 2026-11-06. **Nothing in this section has run against hardware yet.** [C] = confirmed (source, our static analysis, or emulation as stated), [I] = inferred.

### What gets installed

|                       |                                                                                                                                                                                                                                                                                                                                                                                                              |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Source                | drdaeman/g2-bootloader-patch at `1d220973a3b2` (MIT). Every tool read: `flash.py`, `recover.py`, `boot.py`, `patch.py`, `g2patch/*` (`ble_ota`, `firmware`, `recovery`, `link`, `case_rom`, `protocol`, `handshake`, `auth`, `artifacts`), `src/bootloader.c`, `hook.S`, `boot.ld`, `platform.h`, `ram_invoke.h`, the examples, the case relay, `PROTOCOL.md`                                                |
| Base                  | the stock **2.3.2.14** bootloader, `ota/s200_bootloader.bin` from bundle `26b60676…` (149,760 B, SHA-256 `22a2b98e606b4d29…`). `patch.py` refuses anything else, including the 2.4.0.24 bootloader                                                                                                                                                                                                           |
| Changes [C, our diff] | **0x42E656**, 4 bytes: `bl 0x42E56C` (`is_need_updata_image`, in the DFU task) → `bl 0x43511C` (`boot_task_then_flag`: the UART2 loader, then the same stock flag check). **0x434900–0x435B6B**, 4,716 bytes appended (`patch.bin`, the loader, BearSSL HMAC-SHA256, the RAM-call trampoline). **0x435B6C–0x435FFF**: `0xFF` to the page. Every other byte equals stock 2.3.2.14                             |
| Output                | **155,648 B (38 × 4 KiB), SHA-256 `87e2d4e0a7a673ae68fdf47f022b2c1f45dbcb49844e5c88f8a0b1b91bd525c2`**, CRC-32 `63cd8dda`, CRC-32C (OTA header) `89e7b861`                                                                                                                                                                                                                                                   |
| Reproduced [C]        | with drdaeman's own Makefile and flake (clang 21.1.8): `patch.bin` = `d62460d2…` and `case.bin` = `7749131e…`, both equal to the pins in his `tests/test_tools.py` (he pins no hash for the final image; it is a deterministic function of `patch.bin` and the stock input). His 65 tests pass. `w18.py` rebuilds the same 155,648 bytes in pure Python from the cached bundle and the committed `patch.bin` |
| Case relay            | his `case.bin` (5,508 B: the webflasher bridge, his reset/claim/relay code, Even's 372-byte temple-reset waveform from case 1.2.57 flash). Jan's case needs the **observed-33** baseline table, as in step 0: same 4 bytes patched, SHA-256 `6beb9a5e131e3ac1…`. The repository holds the relay with the waveform zeroed; `w18.py` refills it from the cached case firmware and checks both hashes           |

**2.3.2.14 vs 2.4.0.24 bootloader** [C, instruction diff]: the code is the same except one NOR transfer helper (`0x41F918`), which gained a fourth argument that is stored in the transfer descriptor field that 2.3.2.14 sets to 0, and its only caller passes 0. Everything else is relocation (+0x10 after `0x41D1B0`) and the literal pools and data tables that move with it. Both carry the GD25LE256H driver. So installing a 2.3.2.14-based bootloader under app 2.4.0.24 changes no behaviour, which matches drdaeman's hardware test (hardware 5, app 2.4.0.24). In Renode the stock 2.3.2.14 bootloader boots stock 2.4.0.24 exactly like the 2.4.0.24 one does (`control-*` below).

**Which bootloader is in Jan's MRAM now: unknown, and not knowable read-only before the install** [C]. The stock bootloader has no receive path. The stock app reports the main-app version only (`0x24` reply, BLE sid `0x09`): no bootloader version, hash or MRAM read is exposed, and neither bootloader contains a version string (only `2.2.99`, a littlefs/EasyLogger constant in both). Probably 2.4.0.24 if the Even app sent full bundles [I]. It does not matter for the install, because the copy replaces all 38 pages. It does matter for what a cut mid-copy leaves behind (below). After the install, `loader-hello` proves what is there.

### How the install works (stock 2.4.0.24 app, static analysis [C])

The install is **not** a stream into MRAM and does not use the case. It is the stock main app's own BLE OTA, and the **main app itself** (Apollo510, code at `0x438000+`) copies a staged file from the NOR into MRAM:

1. Authentication (sid `0x80`), `BEGIN`, `FILE_CHECK` with the 128-byte component header: **type 1, storage 3, `ota/s200_bootloader.bin`**. For storage 3 + type 1 the app selects its MRAM device and records target **`0x410000`** (`0x446A1C`–`0x446A30`).
2. 38 DATA blocks of 4 KiB, one ack each, written into the littlefs file `ota/s200_bootloader.bin` on the NOR. **MRAM is untouched up to here.**
3. `END` (RESULT_CHECK): the app re-reads the whole staged file (size against the header, CRC-32C against the component CRC; `0x449C2C`) and answers **status 8**. On a mismatch it answers 7 and stops.
4. **Only after answering 8**, in the same OTA task and synchronously, `_evenOtaBootloaderWriteFile2MRAM` (`0x446E38`): open the file, then for each 4 KiB chunk, lowest address first: `fread` → buffered MRAM write (`0x446B74`: program the page through the device ops, then read it back and compare, `0x446AB4`). It logs `Write file to MRAM success, time = %d ms`.
5. No reset, no update-flag change, no further reply. The new bootloader runs at the next reset.

Weak points in that code [C]: the `fread` result and the per-page verify result are **ignored** (the function always returns 0, so the `ERR-Write bootloader to internal MRAM failed` branch is unreachable), and there is **no rollback and no second copy**. The only real verification is ours, afterwards: `loader-hello` reads the region's CRC twice through the new loader.

### The risk window, concretely

| Stage                                                                                                                                                     | What happens if power is lost, the temple resets, or the BLE link drops                                                                                                                                                                                                                                                                                                             |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Before `END` (auth, `BEGIN`, `FILE_CHECK`, 38 blocks; about 10–20 s over BLE)                                                                             | **Harmless.** Only the littlefs file changed. The tool never replays a block; rerun from the start later.                                                                                                                                                                                                                                                                           |
| `END` → status 8 (the app re-reads the 152 KiB file: under a second [I])                                                                                  | **Harmless.** MRAM is still untouched.                                                                                                                                                                                                                                                                                                                                              |
| **The copy: 38 × (4 KiB NOR read + 4 KiB MRAM program + 4 KiB compare), page `0x410000` first, about 1 s [I, not measured; the app logs the real value]** | **The window.** BLE drops don't matter (the copy is local and synchronous). A reset or power loss leaves k new pages followed by 38−k old pages. Each 4 KiB page write is the atomic unit we can rely on; the boot-ROM MRAM programming is per 16-byte unit [I], so a cut can also leave one page half written. What the mixed states do at the next boot: see the emulation below. |
| After the last chunk                                                                                                                                      | The old bootloader is gone and the new one is complete (or corrupt, if a read was silently short; only `loader-hello` can tell). Nothing runs it until the next reset; the app keeps running.                                                                                                                                                                                       |

There is **no verify-and-rollback and no stock-bootloader fallback**: the SBL jumps to `0x410000`, whatever is there. A broken bootloader means SWD (recovery.md §1/§2).

What can actually interrupt one second of a running, battery-powered temple: its battery browning out (hence ≥ 80 %), a watchdog reset (the stock app feeds it, and one second is far below the ~30 s watchdog), a crash elsewhere in the app during the copy (it is synchronous in the OTA task, but other tasks keep running), or **a reset from the case**: the case can reset a temple over the pogo pins, and in the case the app also exchanges UART2 traffic with it (2.4 even locks out BLE OTA while a case-UART OTA session runs). Hence the preconditions:

- **Temple out of the case** for the install, on the table, folded, nothing that can bump it. The case can then neither reset it nor talk to it. BLE, not the case UART: the BLE OTA is the path proven on this hardware (rung 1), and the case-UART OTA (`0x52`–`0x55`) is untested.
- **Battery ≥ 80 %** (Even app), phone Bluetooth off, the Even app and Lotti force-quit. The Mac is the only central.
- The temples are one pair of glasses, so both come out of the case: the whole pair on the table, folded. The case must not touch either temple during the install.

### Emulation proof (Renode, `pnpm nx run wisp-fw:w18-test`)

`apps/wisp-fw/tests/boot/w18.py` runs the **patched bootloader** (rebuilt by `w18.py` from the cache) on the rung-3 platform with the stock 2.4.0.24 main app, and replaces UART2 by `WispCaseLink` (`renode/models/WispCaseLink.cs`): a lockstep TCP bridge, so the **real `w18.py` host code** (`Session`, the loader protocol, the pinned RAM programs) drives the **real loader** byte for byte, as it would through the case relay. Virtual time stops while the host thinks, the deterministic equivalent of the relay's G2TX/G2RX exchange.

Results on 2026-11-06 (t3-worker, Renode 1.16.1, [C, emulation]): **all 34 runs end in their expected state** (7 session and boot cases, 27 install end states). `recover-relay` was added the same evening and passes; the other session and boot cases passed again with it. In that rerun, two install states over the 2.4.0.24 bootloader, k = 35 and 36, stopped Renode answering its monitor. The base branch's harness hangs the same way on k = 35. These cases run no host code, so the hang is unrelated to the relay changes; it is still open. On 2026-11-07, after the session-time guard: `hello`, `recover-relay`, `recover-cut-40pct` and the new `recover-split` pass again (the k = 35/36 install hang is unchanged and was not rerun); rung 3 (`wisp-fw:boot-test`) passes 26/26 on 2.4.0.24. Later on 2026-11-07, with IOM7 behind the nPM1300 watchdog model: `temple-wdt-unfed`, `temple-wdt-fed` and `recover-fed` pass, and `hello` passes again (the other cases were not rerun; the model is transparent until a case arms it).

| Case                                                                           | What runs                                                                                                                                                                                     | Result                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `control-2.4.0.24`, `control-2.3.2.14`                                         | the unmodified stock bootloaders + stock 2.4.0.24 app                                                                                                                                         | both boot stock; **no** UART2 frame (the stock bootloader never touches UART2)                                                                                                                                                                                                                       |
| `boot-nohost`                                                                  | patched bootloader, nobody on UART2                                                                                                                                                           | one `HELO`, unanswered; after the 512-tick window (tick 517) the stock flag check runs and the stock app boots                                                                                                                                                                                       |
| `hello`                                                                        | `loader-hello`'s session                                                                                                                                                                      | `HELO` → `HOLD` → `OKAY` (HMAC checked) → `checksum.bin` of `[0x410000, +155,648)` = `63cd8dda` twice → flag `0xFFFFFFFF` → `CONT` → `RLSD` → stock app boots                                                                                                                                        |
| `info`                                                                         | `info-dump`'s session, synthetic INFO0                                                                                                                                                        | MCUCTRL/PWRCTRL read, INFO0 2,048 B read back exactly, INFOC and DCU **skipped** because their domains are off, stock app boots                                                                                                                                                                      |
| `recover`                                                                      | app region **erased** (a dead temple), `recover` with the pinned stock image                                                                                                                  | the loader takes over before the (missing) app; 3,700,080 B streamed through `recover.bin` and the bootloader's MRAM routine, body CRC, vectors, full CRC `1c340963`; MRAM = stock, bootloader unchanged; release → **stock 2.4.0.24 boots**                                                         |
| `recover-relay`                                                                | the same, every frame through the case relay's framing                                                                                                                                        | `RelayPortLink` (the G2RQ, G2TX/G2RX and G2EX/G2RS code `CaseRelayLink` runs) over `relay_model.RelayModel` (drdaeman's `case_exchange.c` in Python): 245,795 exchanges, the same MRAM end state, relay exit status 6; stock 2.4.0.24 boots                                                          |
| `recover-cut-40pct`                                                            | the same, **power cut after ROM write 5,781** (about 40 %)                                                                                                                                    | session 1 sees a `HELO` instead of a reply and stops (`TempleReset`, no release). The temple reboots into the loader again because the app is still dead. A fresh session 2 writes and verifies everything; stock boots                                                                              |
| `recover-split`                                                                | the same dead temple, `recover`'s write split over relay sessions (`AppWriter`, 30 s budget of host wall time; parts are sized from the slowest rate seen), the temple reset between sessions | added 2026-11-07: every session after the first CRC-checks the body so far, then adds a part; 197 sessions on a loaded host, none over the budget (longest 26.3 s), relay exit status 6 each; the vectors in the last; MRAM = stock (CRC `1c340963`), bootloader unchanged; **stock 2.4.0.24 boots** |
| `temple-wdt-unfed`, `temple-wdt-fed` | the temple's nPM1300 watchdog (`WispPmicWdt` on IOM7, armed at power-on, period scaled to 2.5 s of virtual time); the same work with drdaeman's programs and with the feed | added 2026-11-07: unfed, the temple is power-cycled mid-session (`HELO` instead of a reply); fed, 5 kicks and nothing else to the PMIC, no power cycle; stock boots after both ([The temple's watchdog](#the-temples-watchdog-the-npm1300)) |
| `recover-fed` | a dead temple recovered in **one** session with `recover_fed.bin` under the armed watchdog | added 2026-11-07: 3,700,080 B, CRC `1c340963`, 11 kicks, no power cycle, bootloader unchanged, **stock 2.4.0.24 boots** |
| `install-over-2.4.0.24-k` (k = 0, 1, 2, 9, 10, 11, 19, 29, 30, 31, 36, 37, 38) | MRAM = first k of the 38 new pages, the rest the 2.4.0.24 bootloader                                                                                                                          | k = 0: boots stock. **k = 1 … 37: brick** (UsageFault loop in the bootloader, no `HELO`, no app). k = 38: boots stock with the loader's `HELO`                                                                                                                                                       |
| `install-over-2.3.2.14-k` (k = 0 … 38 as above, plus 35)                       | the same over a 2.3.2.14 bootloader                                                                                                                                                           | k ≤ 30: boots stock (those pages are byte-identical). **k = 31 … 37: brick** (the hook page `0x42E000` is new, the loader pages `0x434000`–`0x435FFF` aren't yet). k = 38: boots stock with `HELO`                                                                                                   |

So the window is every intermediate state: **37 of the 38 page boundaries** if the temple holds the 2.4.0.24 bootloader, **7 of 38** if it holds 2.3.2.14. Neither leaves a recoverable state, so the whole copy (~1 s) is the window. There is no partial state that the loader could repair.

Model limits, in addition to rung 3's ([apps/wisp-fw/README.md](../../apps/wisp-fw/README.md#what-renode-lacks-for-this-and-the-next-rungs)):

- Renode 1.16's Cortex-M55 has no MVE, so the trampoline's `vmrs r7, vpr` / `vmsr vpr, r7` (save/restore of the MVE predicate around a RAM program; valid on the Apollo510) would fault. `WispCaseLink.MveVprShim` emulates exactly those two instructions.
- The bootloader's short FreeRTOS delays overshoot more and more in Renode (+1 ms per ~10 calls under tickless idle on the STIMER model), which made a long session slow down quadratically. `WispCaseLink.PacingShim` returns at once from delays of ≤ 21 ticks called from the loader worker's `reply`/`receive`/`transmit`. The manager's 512-tick boot window and its hold loop keep their real delays. **Emulated timings therefore say nothing about hardware timings.**
- The install itself is emulated as its **end states**, not by running the stock app's BLE OTA (no BLE in the model). The stock copy order (4 KiB chunks, ascending) comes from the static analysis above.
- UART2 is ideal: no line errors, no half-duplex turnaround loss, no pogo bounce.

### Timing on hardware (estimates [I])

Each loader exchange costs the loader's 6-tick reply delay (~5.9 ms), 32 + 32 bytes at 1 Mbaud (~0.7 ms) and two CH340 USB round trips: estimated **7–10 ms per exchange**. `recover` streams the 3,700,064-byte body in 16-byte `INPUT_DATA` packets (231,254 exchanges) plus one progress report per 256 bytes (14,454), with the temple held in the bootloader (display off) in the case. `w18.py recover` skips drdaeman's full backup (the content to be replaced is checked by CRC instead), which would double that. `loader-hello` takes a few seconds; `info-dump` about 300 exchanges. **Measured on 2026-11-06 (F1): 17.5 ms per exchange [C].** A one-session `recover` would therefore take about 72 min, not 30–45. With the old relay, sessions stalled after about 20 s (the case's watchdog), so `recover` ran in 12 s sessions: about 3–3.5 h. The relay that feeds the case's watchdog and the programs that feed the temple's bring it back to **about 72 min in one session** ([Long relay sessions](#long-relay-sessions-the-cases-yhm4005-watchdog), [The temple's watchdog](#the-temples-watchdog-the-npm1300), F2 below). With the case fed but not the temple, the fallback is 20 s sessions: about 280 sessions, about 2.5 h.

### Tooling (`apps/wisp-recovery/w18.py`)

| Command                                                                                          | Touches                                                       | Refuses unless                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `bootloader-plan --side S`                                                                       | nothing                                                       | the image, the stock main and the relay all rebuild to their pins                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `bootloader-install --side S --address A --battery N --go TOKEN`                                 | **MRAM `0x410000–0x435FFF` of side S, via the stock BLE OTA** | `--go` is exactly `W18-LEFT-87e2d4e0a7a6` (or `-RIGHT-`); N ≥ 80; a passed step-0 report for side S from the last 24 h (case 1.2.57, app 2.4.0.24, hardware 5); every pin; the BLE name says side S; MTU ≥ 243; stock authentication passes. Sends only the pinned image, never replays a block, accepts only END status 8                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `loader-hello --side S`                                                                          | nothing (temple reset by the case)                            | the bootloader region's CRC is the pinned image's                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `info-dump --side S`                                                                             | nothing                                                       | as above. Reads MCUCTRL, PWRCTRL; INFO0 (MRAM or, if powered, OTP); INFOC and the DCU/LCS registers **only if their power domain is already on**; it never powers anything up                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `link-soak --side S [--bytes N] [--max-session-s T \| --idle-s P]`                               | nothing (temple reset by the case)                            | as `loader-hello`. Streams N bytes (default 1 MiB, about 65,536 exchanges) of the app region **out** with `dump`, checks them against `checksum` of the same range, and reports the exchange count and time per exchange. A session as long and dense as `recover`'s, without a write. `--max-session-s T` splits it into sessions that each end T s after the relay starts, every part CRC-checked. `--idle-s P` first keeps the relay running P s with empty `G2TX` (no temple traffic): the wall-time-or-exchanges experiment, and a quick check that the relay feeds the case watchdog                                                                                                                                                                                                           |
| `recover --side S --image .wisp-cache/stock/g2-2.4.0.24.bin [--max-session-s T] [--resume-at N]` | MRAM `0x438000–0x7BF56F` of side S, via the loader            | the image is the pinned stock 2.4.0.24 main (`df8cfddf…`); the bootloader CRC matches and the update flag is clear (else `--allow-pending-flag`), in every session; every write is inside the app region (the flag record and everything else are refused in code). Writes the body in one session by default (both watchdogs fed), or in parts, one per session ending T s after the relay starts (default 20 with `--no-temple-feed`, 12 with `--case-profile observed-33`; 0 = one session); each session first CRC-checks the body written so far, then CRC-checks its part. Before the first body byte the 16 vector bytes are zeroed and read back (unless they already read zero: a resumed run does not rewrite them; [rung4.md](rung4.md) R4-1); the real ones go last, once, in a session that has just CRC-checked the whole body; then the full CRC. A stop prints `--resume-at N`; a resumed run CRC-checks those N bytes before writing. A HELO in the middle (temple reset) stops the session without a release |
| `loader-hello --side S --no-release` | nothing (temple reset by the case) | as `loader-hello`; ends the session **without CONT**: the temple stays held in its loader until the next case reset (or the PMIC's watchdog, ~30 s after the last kick, if the stock app had armed it). An error still releases (G25) |
| `held-reset-test --side S` | nothing (temple reset by the case, twice) | two sessions: the first is `loader-hello --no-release`, the second must reset the held temple and get its `HELO` within 3 s of its relay start and less than 30.72 − 5 s after the first session's last PMIC kick (else "inconclusive": the PMIC could have brought it). Needs the temple feed. [Rung-4 reads](#rung-4-reads-peek-pmic_read-app-check-boot-watch-and-the-held-temple-reset) |
| `peek --side S [--what R …]` | nothing | as `loader-hello`; reads only `pins.PEEK_REGIONS` (the patched bootloader's NOR record, board strap, UART2 entry, power callbacks, the flag record, the NOR ops records) with `dump`/`dump_fed` |
| `pmic-read --side S [--compare REPORT]` | one PMIC watchdog kick; nothing else is written | as `loader-hello`; runs the pinned `pmic_read.bin` (58 nPM1300 registers, reads only). With `--compare`, exit 3 when a config register differs from that earlier report (the watchdog period and live status registers are listed apart; the watchdog's mode is config). **Its first run on hardware needs Jan's own go** |
| `app-check --side S [--image F …]` | nothing | as `loader-hello`; reports the flag (clear / install pending / undocumented), the vectors, and the app region's CRC over each known image's length: the pinned stock main (`9c66404b` over 3,700,068 B), pinned Wisp images with a `crc32`, and the files given. Exit 3 when nothing matches or the flag is undocumented |
| `boot-watch --side S [--protocol P] [--watch-s T] [--interval-s I]` | CONT (the boot is released) | P's first request is one the relay forwards (checked before the case is touched); as `loader-hello`; a documented flag (else it stops, and the session ends with `CONT` as always); then queries through the relay for T s before `G2EX`. P is a `wisp_w18/status.py` protocol: `listen` (the default: sends nothing, records what the temple sends) or `wisp` (native-0's case-UART status, [case-uart.md](case-uart.md): IDENT, the app's status and Wisp Boot's block, then IDENT until the BLE bring-up has ended; never RESET; use `--interval-s 0.1`). With `wisp` the report decodes both blocks (`summary`). The loader's `HELO` in the answers is reported as a reboot |
| `install-wisp --side S --image I --elf E --map M --expect H --battery N [--max-session-s T] [--resume-at N]` | MRAM `[0x438000, end of I)` of side S, via the loader | every image but the pinned `native-0` (W23: `5d373fd8…`, files in `apps/wisp-recovery/wisp_w18/data/native-0/`; nothing is sent and the case is not touched). For the pinned image: I, E and M match their pins; H is 12+ hex digits of I's SHA-256; the pin records the `check_rule8` and no-MRAM-write gates; I's first 64 KiB are a Wisp Boot that passed rung 3 on the stock 2.4.0.24 and the patched bootloader; every ELF segment in MRAM equals I there; rule 3 passes in both implementations (a Python port and wisp-ota's own checks, run from its build; SP ≤ `0x20380000`); N ≥ 80 % or ≥ 3,900 mV (`3950mV`). In every session, before any write, the `loader-hello` gate: bootloader CRC twice and a clear flag (no override). The writer reruns rule 3 on the bytes it sends, then writes as `recover` does (vectors zeroed first, last for real), bounded by I's own end ([rung4.md §3, G1](rung4.md#3-how-it-gets-onto-the-temple)) |

Every case command takes `--case-profile` (default `observed-33-feed`, the relay that feeds the case watchdog; `observed-33` is the old one) and feeds the temple's nPM1300 watchdog unless given `--no-temple-feed` ([The temple's watchdog](#the-temples-watchdog-the-npm1300)). Between two sessions of one command, the case app runs 5 s after its banner before the next ROM entry, and a relay start refused with status 3 (pogo switch not idle, zero writes) is reported at once and retried once after the same settle ([Between sessions: the pogo switch](#between-sessions-the-pogo-switch-status-3)). Hard-coded in `wisp_w18/pins.py`: every hash above, the only writable regions, the token. The RAM programs are drdaeman's `checksum`, `dump`, `recover` (pinned, MIT) and ours, `feed`, `dump_fed`, `recover_fed`, `pmic_read` (pinned, MIT, built by `wisp_w18/programs/build.sh`). Tests: `pnpm nx run wisp-recovery:test` (fakes, including a power cut in the middle of `recover`, and sessions through the relay framing on a relay model and on drdaeman's real relay binary under Unicorn, with and without the watchdog feed, against an emulated YHM4005) and `wisp-fw:w18-test` (Renode).

Every session's report keeps the error that stopped it, the step and write position, the cleanup failures beside it, and the last 16 exchanges (sent, received, time); the case's relay record is decoded. A relay exit status other than 6 is an error.

### Rung-4 reads: peek, pmic_read, app-check, boot-watch and the held-temple reset

Built on t3-worker on 2026-11-08 for rung 4's W20/W21/W24 ([rung4.md §4](rung4.md#4-pre-qualification-without-writing-mram), gaps G2, G3, G25), in emulation only. Nothing here has run on hardware. Each needs the usual setup of a case session; `pmic_read.bin` is a new program on the PMIC bus, so **its first hardware run needs Jan's own go** (rung4.md §7), and so does any later new temple program. The others run only pinned programs that have run on hardware before (`checksum`, `dump_fed`, `feed`). They fall under Jan's standing permission for read-only runs, except `boot-watch`, which releases the boot like every session's end.

**The held-temple reset test (`held-reset-test`, G25).** The first session is `loader-hello --no-release`: the bootloader CRC twice and the flag, then `G2EX` without `CONT`, so the temple stays in its loader. The second session follows after the usual settle (the case app runs 5 s after its banner, then ROM entry and relay load, roughly 15 s in all). Its relay reset must bring the loader's `HELO` back.

- **The `HELO` must be the reset's.** It has to arrive within 3 s of the relay start (the reset gives it in 0.5–0.9 s on hardware), and less than 25.72 s (30.72 − 5) after the first session's last PMIC kick, which is taken as the start of the last kicking program, earlier than the kick itself. A `HELO` later than 3 s after the relay start came from the PMIC's power cycle inside the relay's beacon window, not from the case's reset: the tool says `STOP`, which is the stop condition below. A second session that started too late (its `HELO` 25.72 s or more after the last kick) proves nothing either way: the tool says `INCONCLUSIVE` and asks for a rerun.
- **A missing `HELO` is rung4.md's first stop condition: stop the whole plan.** The temple then stays held until the PMIC's watchdog resets it (about 30 s after the last kick), and stock boots.
- That fallback exists only because the stock app armed the PMIC's watchdog, so **the test is valid only with stock having booted since the temple's last PMIC power cycle**, as on every bench session so far. It refuses `--no-temple-feed`, without which it cannot time the reset. W20's analysis ([hardware.md](hardware.md#rung-4-static-analysis-w20-2026-11-08)) supports both halves without proving them:

- The loader's precondition is the bootloader's own state, rebuilt at every boot.
- The case's reset is a pulse-coded signal on the pogo line that waits for nothing from the temple; case 1.2.57 uses it on a temple that has stopped answering.

**`peek` (G3)** reads only `pins.PEEK_REGIONS`, after the bootloader CRC, with `dump_fed`:

| Region | Address | Decoded as |
| --- | --- | --- |
| `nor` | `0x2000023C`, 4 B | `0x4336B0` = GD25LE256H; `0x4336A0` = MX25U25643G **or** an unknown ID or failed RDID read (the classifier's default is the MX record, so these cannot be told apart from RAM) |
| `board` | `0x20027018`, 8 B | the bootloader's HwConfig ADC record: class, code, the GPIO16 strap in mV, and the app's hw_version bin for it (100–250 mV = 5) |
| `uart2` | `0x20000490`, 28 B | UART2's table entry as the loader leaves it (handle set, pin table `0x434210`, no callback, awake 1: the loader checked awake = 0, then woke UART2) |
| `power-callbacks` | `0x20026E44`, 8 B | both zero |
| `flag` | `0x7FE000`, 16 B | the flag record |
| `ssram-power` | `0x40021028`, 4 B | `PWRCTRL.SSRAMPWRST`: which 1-MiB SSRAM groups are powered; group 2 (bit 2) holds Wisp Boot's RAM |
| `rstgen-stat` | `0x4000885C`, 4 B | `RSTGEN.STAT` in the held loader: the reset that started this session (a case reset: `external`), unless STAT accumulates |
| `wisp-record` | `0x20370000`, 64 B | Wisp's diagnostics record (rung4.md W24 D1): what the boot that the session's case reset interrupted left, its boot counter, reset cause, last stage and its time, fault. Read only if `ssram-power` shows group 2 on |
| `wisp-boot-status` | `0x20375330`, 692 B | Wisp Boot's status block (`st`) of the stage-0 Wisp Boot only (slot `7a5c399b…`); its `prev` is the record of the boot before. Same gate |
| `nor-records` | `0x4336A0`, 32 B | the two NOR ops records (MRAM) |

**`pmic_read.bin` (G3)**, 504 B, SHA-256 `491f98f55dc65a81…`, built by `programs/build.sh` with the other programs:

- It runs entirely inside one IOM7 power window of the bootloader's HAL (`power_ctrl` WAKE and DEEPSLEEP with retain, as `pmic_kick.h`). It first kicks the PMIC watchdog with the feed's own bytes (`07 04 01`) after the same I2C-table check, then makes one I2C write-read per register: a 2-byte address, a repeated start, one byte back.
- The 58 registers are baked into the image, in the order of `pins.PMIC_READ_REGISTERS`, and the host cannot name another. They are VBUS limits and status, the charger's enable, currents, termination, trickle, NTC thresholds, status and error, BUCK1/2 voltages, enable, PWM and status, LDSW1/2 configuration and voltages, the ADC NTC selection, GPIO0–4 modes and status, SHIP and LPRESET configuration, and the watchdog timer's mode and period.
- Task registers and ship/hibernate entry are not in the list (a test checks it). ERRLOG and POF are left out until their offsets are checked against the nPM1300 product specification [?].
- Under Unicorn (`tests/test_pmic_read.py`) the real binary makes exactly one kick and then the 58 reads in order, with no other PMIC transaction. IOM7 is powered up and down once. Its register footprint is the kick's plus `FIFOPOP`. Every failure code ends the program before anything is sent.
- The host prints the snapshot, and `--compare` diffs it against an earlier report: a config difference is a stop (rung4.md §8). The watchdog period and the live status registers are listed apart. The watchdog's mode counts as config: a mode that no longer resets the temple would remove the PMIC's power cycle, the fail-safe `native-0` keeps (G27).
- It runs in Renode against the real patched bootloader (`w18-test` case `rung4-reads`): 58 registers back through the bootloader's IOM HAL, and nothing but kicks written to the PMIC in the session. For that, our IOM7 model (`WispPmicWdt.cs`) now reports the receive FIFO's fill and hands offset-mode reads to g2emu's IOM as an address write (the stock app reads with an address write, then a READ; g2emu's model only knew that form). The values are the model's, not a temple's.

**`app-check` (G2)** is rung4.md exit item 5 minus the PMIC (run `pmic-read --compare` beside it): the bootloader CRC twice, the flag with its meaning, the 16 vector bytes (zero = an interrupted write), and the app region's CRC over each known image's own length. The pinned stock CRC is over the 3,700,068 image bytes. F2's final CRC `d9864941` was over the 16-byte-rounded 3,700,080 B, so it includes 12 bytes past the image.

The two Wisp regions read RAM that only Wisp writes, in the held loader after the case reset that started the session (rung4.md, "W24b results"): the patched bootloader's only SSRAM use is its heap, `[0x20081000, 0x2013C800)` (a memset and the heap init at `0x41FD70`; no literal in it points higher) [C, static]. Whether SRAM keeps its contents across the case reset, and what the SBL does, is for the record's magic and CRC to show [?]. In Renode the `stage-0` case of `w18-test` reads both after a held case reset.

**`boot-watch` (G2)** releases the boot (`CONT`, `RLSD`) and keeps the relay running: each `G2TX` hands one frame to the temple and returns the first `5A A5 FF` frame within the relay's poll bound. The questions are a pluggable `StatusProtocol` (`wisp_w18/status.py`).

- **A request nobody answers blocks the relay** (W24b; `case_exchange.c` `relay_receive`): after sending, the relay waits, without reading the host port, for the first four temple bytes, up to its poll bound (about 31 s with the feed). It ends early only on four bytes that are no frame header, or a UART error flag (status 2). In a reboot loop the next frame is the loader's `HELO`. The host must not send again meanwhile, and temple frames sent while no exchange is pending are lost. So a short window gets one try per boot, aimed: `--protocol wisp` asks the boot report at `--report-at` seconds after the loader's release (`CONT`, or `HELO` + 0.512 s), and IDENT 2 s after the report. `relay_model.RelayModel` now blocks the same way (an unanswered request costs the poll bound, or less if the fake temple sends a frame by itself), and `tests/test_boot_watch_timing.py` reproduces W24b with it.

- The relay constrains every protocol: requests are 9, 25 or 32 bytes starting `7E 00 01 n-5` (or empty: listen only), and replies are 13, 21, 29 or 32-byte `5A A5 FF` frames. The stock version query `24 00 01 00 a7` cannot go through this relay, so G10's Wisp protocol has to fit these shapes.
- Only `listen` is registered today. G10 (apps/wisp-fw) registers the Wisp protocol with its tests.
- The tests use a fake protocol and a fake app (`tests/fake_status.py`), including an app that reboots into the loader (its `HELO`) and protocols whose requests the relay cannot carry: a bad first request is refused before the case is touched, a bad later one stops the watch.
- An undocumented flag value stops `boot-watch` before any query; the session's cleanup still sends `CONT`, as every session's does.
- While the relay runs, the case app does not, so its 180-second no-reply reset (hardware.md) cannot interfere with a watch.

### Between sessions: the pogo switch (status 3)

**What happened (2026-11-07, W18 F1d split, [hardware log](safety.md#hardware-log)).** Session 0 of `link-soak --max-session-s 20 --no-temple-feed` passed. Session 1 was refused by the relay: the bridge reads the YHM2510 (the pogo switch) before it selects a route, and its registers did not match a seated-idle baseline. The case app had restarted twice within about 2 s (the cleanup's banner boot, then the next start's), and the switch was not idle yet. The bridge then selects nothing, writes nothing, answers `G2RQ` with a 13-byte `G2RS` of status 3 and resets the case [C: the record read back, and the same refusal from drdaeman's relay binary under Unicorn with a non-idle baseline]. The tool read those 13 bytes as the first part of the 16-byte UART register dump, waited out its read timeouts for the rest, and its cleanup then called the untouched route "case route restoration not verified". Nothing reached the temple. F1b's session 1 stalled during its relay start the same way ("got 13 of 16 bytes"), which reads as the same refusal [I].

**The fix (tooling, emulation only so far).**

- `CaseRelayLink` reads 12 bytes after `G2RQ` first. `G2RS` there is a refusal: status 3 raises `PogoNotIdle` at once ("the case's pogo switch was not idle; zero writes, nothing sent to the temple"), any other status a plain error.
- The cleanup then checks the case record as a zero-write record (status 3, no YHM write, no temple byte, no capture: `route_untouched`), not as a route restore.
- Every session after the first lets the case app run `SETTLE_S` = 5 s after its banner before the ROM entry (the app also feeds the case's YHM4005 every 5 s, so the ROM phase starts with a fresh window). The first session of a command is unchanged, as in every passed run. The listen records when the app's `B200 vol:` status lines came (`case_settle`), so the first hardware run tells how soon the app prints one; a fixed wait was chosen because nothing on record says how often it does.
- A refused session is retried once, after the same settle, and only when the record proved zero writes. A second refusal stops the command.
- Tests: `tests/test_pogo_settle.py` runs the real relay binary under Unicorn on a fake case whose switch is busy right after two quick app restarts: the refusal is recognised in well under a second, later sessions settle and are never refused, the old behaviour (no settle) is refused like the hardware, a retry after the settle passes, and a switch that never settles stops after one retry with the case clean.

### Step F on hardware: the stall of 2026-11-06

Both runs of `recover` on the left temple (19:30 and 19:37 UTC, the second after a reseat) stopped the same way. Everything up to the writer passed: `HELO`, hold, bootloader CRC `63cd8dda`, flag clear, app CRC `d9864941`. Then no reply came, three 60 s timeouts ran out, and the relay never answered `G2EX`. The temple was unharmed ([hardware log](safety.md)). The analysis below was done on t3-worker, from code, emulation and the relay record the tool read back. Nothing in it touched hardware.

**Root cause: not found with confidence.** (Follow-up: F1 stalled the same way. The MCU's own watchdog was ruled out. The cause is the case's external YHM4005 watchdog; see [Long relay sessions](#long-relay-sessions-the-cases-yhm4005-watchdog).) What is settled:

- **It is not our framing [C].** Every host frame is byte-identical to drdaeman's reference host code at `1d22097`. That covers `protocol.py` `request` (RQST, INPUT_DATA = count, 16 data bytes, CRC-32) and `link.py` `exchange` (G2TX length and checksum, the G2RX checks). In emulation, his real relay binary under Unicorn forwards a streamed write behind the unmodified `CaseRelayLink` (`tests/test_relay.py`). A full stock `recover` also passes in Renode through the relay framing: 245,795 exchanges (`recover-relay` above). His own hardware test of `recv` through the relay covered a 1 KiB range (programmed, read back, restored): a few hundred exchanges per session, not hundreds of thousands [C, PROTOCOL.md].
- **The case MCU stopped running the relay [C, relay record].** The record layout comes from our disassembly of the bridge and from `case_exchange.c`:
  - Word 1 = 1: the bridge's exit path (route restore, `G2RS`, reset) never ran.
  - YHM writes `0x00f` and reads-after-restore `0x000`: the route restore never started.
  - Word 10 = 32: the last frame the relay handed to the temple was a 32-byte request. So the cleanup's 9-byte `CONT` never reached it.
  - The capture holds `RESP INPUT 16`, and the UART error flags are 0.

  Every loop in the relay is bounded at 64,000,000 polls. That is about 15–20 s at 64 MHz, the clock that the bridge's `BRR = 556` for 115,200 Bd implies [I]. Every way out of those loops either sends a `G2RX` (status 2 when the temple is silent) or ends in `G2RS`. A host that waits 60 s, then sends `CONT`, then `G2EX`, would have seen one of them. So the case was stuck outside the relay's own loops, or it had reset.

- **The temple cannot cause that silence [C].** If the temple hangs, the relay answers status 2 within its poll bound. If the temple reboots, it sends a `HELO`; the relay forwards it, and the tool reports it as `temple rebooted`.
- **`relay_exit_status 6` (steps D, E) is the normal end [C].** It is the bridge's status for "extension returned, route restore verified, no step-0 capture", and the W18 relay always zeroes its capture count on exit. Status 7 would mean the restore did not verify. The tool now checks for 6.
- **Where in the stream it stopped is not known [I].** The record looks the same after every input exchange, because each one requests 16 bytes. The old tool printed progress only every 64 KiB, which is 4,352 exchanges. The two runs lasted 212 s and 273 s, of which 180 s were the three timeouts and about 20–30 s were setup and cleanup. So run 2 stopped within seconds of the first `INPUT_DATA`, and run 1 about a minute later, still before 64 KiB. It is not a fixed point in the stream.

Hypotheses, most likely first:

1. **The case hangs in stock case code that the relay calls on every exchange [I, mechanism not identified].** Per exchange, the relay calls into the case 1.2.57 flash with interrupts masked:
   - the UART3 re-init to TX-only and back to RX-only (`HAL_UART_DeInit`/`HAL_UART_Init`, `0x08006CF8`/`0x08006C80`);
   - `HAL_UART_Transmit` (through `0x08003BB0`, timeout `0xFFFF`).

   With interrupts masked, SysTick is frozen, so none of their HAL timeouts can expire. Their error path (`Error_Handler`, `0x08003E90`) is `cpsid i; b .`. A rare stall there would not show in sessions of a few hundred exchanges (steps D and E), but would likely show in one of thousands.

2. **The case MCU resets [I].** A brown-out or a fault through the ROM's vector table would reset it. With DTR released, it then boots its ROM loader, which says nothing to `G2TX` or `G2EX`. SRAM survives a reset, which fits the intact record.
3. **Something specific to `INPUT_DATA` [I, least likely].** This could be data patterns on the pogo line, or the first 256-byte MRAM program on the temple. No mechanism was found: the relay never looks at the data, and a temple-side fault would show as status 2 or a `HELO`.

**The cheapest experiment that decides between them is read-only:** `w18.py link-soak --side left`. It streams 1 MiB of the app region _out_ with `dump` and checks it against the temple's CRC of the same range. That is OUTPUT/OUTPUT_ACK, the same 32-byte frames in both directions and the same relay path per exchange, 65,536 exchanges, about 15–25 min. Nothing is written.

- If the soak stalls too, it is (1) or (2): long relay sessions are the problem, not `recv`. Its report says after how many exchanges and how many seconds. In that case `recover` must not run as one 45-minute session. The options are then shorter sessions (a write split over fresh claims, each part verified by CRC) or a relay that never calls case HAL code with interrupts masked.
- If the soak passes, it points at (3). Rerun `recover` with the new diagnostics, which name the exchange where it stopped.

**Fixed in the tool:**

- The error that ended a session is kept and reported. Cleanup failures are listed beside it (`cleanup_errors`, and as notes on the exception), not instead of it. Before, the restore timeout replaced it.
- Every report carries the step and write position, the exchange count, the last 16 exchanges (sent, received, time, error) and the decoded relay record. On failure, the last frames are also printed.
- `recover` prints its first progress line after the first verified 256-byte block, so a stall in the stream shows within seconds.
- The relay exit status is checked; 6 is expected.
- Step C's liveness check uses a new BLE connection and is informational: a missing answer is reported, not fatal.
- New tests: sessions through the relay framing, on the relay model (a port of `case_exchange.c`) and on drdaeman's real relay binary under Unicorn, both behind the code `CaseRelayLink` runs. Making the case stop while it forwards the first `INPUT_DATA` reproduces the hardware's relay record byte for byte in the model and field for field in the binary, and the report shows the original timeout with the cleanup failures beside it. `recover-relay` covers the same path in Renode.

### charge_on: the charger back on with stock's settings

**Why (2026-11-10).** The left temple sat in the case for about 17 h on stage-0b, then stopped answering the case altogether: no `HELO`, not one byte, in every session since (case firmware 1.2.57 healthy, both temples seen as seated). Reading of it [I]: the battery ran flat, the nPM1300 lost power and came back on its reset values with the charger off (`BCHARGER.ENABLE 0x00`, as after W24's watchdog power cycle, [rung4.md](rung4.md)), and stage-0b never programs the charger. On 5 V from the case the temple can run but does not charge, and when the case turns the pogo line round to UART the temple has no battery to run on. Stock heals itself here because its app programs the charger at every boot. A test image does not.

**`charge_on.bin`** (`wisp_w18/programs/charge_on.c`, 372 B, pinned in `pins.PROGRAMS`) runs from the patched loader like `pmic_read.bin` and uses the same bindings into the pinned bootloader. Every transfer is a 3-byte write sent exactly as the watchdog kick is sent. First the kick, then `pins.CHARGE_ON_WRITES`: W21's stock values for the NTC resistor and thresholds, termination (4.45 V / 4.10 V warm), charge current 96 mA, discharge limit `9b 00` (code 310, stock's own; Nordic documents only 84 = 200 mA and 415 = 1 A), the VBUS limit (500 mA, plus its update task; the PMIC returns to `ILIMSTARTUP` whenever VBUS goes away), low-battery charging (`BCHGVBATLOWCHARGE`), release the charger from an error state (`TASKRELEASEERR`, offset 0x00, Zephyr's `ERR_CLR`; `ERR_REASON` is not cleared, so the read-back still shows why it stopped), then charging on. These are the order and the registers of Zephyr's npm13xx charger driver; on a PMIC that already holds stock's settings every write leaves the register as it is. It writes no rail, timer, ship or GPIO register. It sends nothing; `w18.py charge-on` runs `pmic_read.bin` next in the same session and stops (exit 3) if a written register reads back different. Tests: `tests/test_charge_on.py` (the binary under Unicorn: exactly the kick and the writes, in order, no read, IOM7 powered up and down once; the values equal `pmic-baseline-w21.json`). Jan gave the go for this PMIC write on 2026-11-10.

**What it needs:** one loader session, so the temple must answer `HELO` once. With a flat battery that needs the temple powered while the case talks to it; how to get that is open (the case-side analysis of the YHM2510).

### Long relay sessions: the case's YHM4005 watchdog

**Resolved on 2026-11-07.** The stalls are the case's external watchdog, a YHM4005 that only the case app feeds. A case-only probe confirmed it on hardware. The relay now feeds it: [The relay feeds the case watchdog](#the-relay-feeds-the-case-watchdog). The history follows in order. The MCU's own watchdog (IWDG, ruled out below) is indeed not involved. The wall-time hypothesis (2) was right. [The ~30 s clock that survives case resets](#the-30-s-clock-that-survives-case-resets) found the chip.

On 2026-11-06 at 22:31 UTC the read-only `link-soak` (F1) stopped the same way as both `recover` runs. It made 1,110 good exchanges at 17.5 ms each, then exchange #1111 got no answer. The relay record was the step-F record again: phase 1, route restore never started, last temple send 32 bytes, capture = #1110's reply, UART error flags 0. Nothing was written, and the temple was fine after one `loader-hello`. So the problem is **long case relay sessions**, not `recv` or anything specific to writing. The analysis below was done on t3-worker from the reports, the Mac thread's transcript and disassembly. Nothing in it touched hardware.

**Lead hypothesis checked first: the case MCU's independent watchdog (IWDG). Verdict: refuted, with high confidence.** If the case firmware had started the IWDG, the ROM loader and our SRAM relay would never feed it, and the case would reset after the IWDG's maximum period, 4096 × 256 / 32 kHz ≈ 32.8 s. Two independent checks rule this out.

**1. The case firmware never touches a watchdog [C, disassembly of case 1.2.57].** The image is 55,752 B at `0x08000000`, SHA-256 `773b6d4c…` (the pinned one). The ROM reports product ID `0x467`, an STM32G0B1/G0C1 (Cortex-M0+).

- There is no literal `0x40003000` (IWDG) or `0x40002C00` (WWDG) anywhere in the image, and no key constant `0x5555`, `0xCCCC` or `0xAAAA`. The only `aa aa` bytes are a data table at `0x0800D9C0`. The peripheral bases it does reference are TIM1/3/4/14–17, RTC, USART1–5, PWR, SYSCFG, ADC, RCC, EXTI, FLASH and GPIO.
- It does program option bytes, but never the watchdog bits:
  - `main()` (`0x0800A5B6`–`0x0800A60A`) reads them (`HAL_FLASHEx_OBGetConfig`, `0x08004A00`, user mask `0x077F6000` at `0x08003EC0`). If `nBOOT_SEL` (OPTR bit 24) is set, or RDP isn't level 0, it writes RDP `0xAA` and the user bits it just read, with only bit 24 cleared (`0x0800A5DE`–`0x0800A5FE`, `HAL_FLASHEx_OBProgram` `0x08004A6C`, `FLASH_OB_OptrConfig` `0x08003ED4`, launch `0x08004B3C`). That is what lets the CH340's DTR line select the ROM.
  - The only other option-byte routine (`0x080038E0`–`0x08003954`) flips bit 20 (the bank swap of its dual-bank update [I]).
  - `IWDG_SW` (bit 16) and `WWDG_SW` (bit 19) are always written back unchanged.
- A hardware-mode watchdog is also excluded. With `IWDG_SW = 0` the IWDG starts at every reset with prescaler /4 and reload `0xFFF`, so it fires after about 0.5 s unless refreshed. A firmware that never refreshes would then reboot twice a second, but the case runs for hours and prints its periodic status lines. So the watchdogs are in software mode, and nothing starts them.
- And even a software-started IWDG would not survive our entry: the tool enters the ROM through NRST (the CH340's RTS), a system reset, which stops it.

**2. The timing does not fit [C, from the reports and the transcript].** The new tool's frame times count from the link's creation, before the case banner, and the relay start (Go) was not recorded. That is now fixed: `relay_started_t` and `stall.since_relay_start_s` are in every report. For F1 it can still be bounded:

| Run (left temple, 2026-11-06)                        | Shell start → report            | Stall, after the command started                     | Stall, after the relay started | Exchanges before the stall                |
| ---------------------------------------------------- | ------------------------------- | ---------------------------------------------------- | ------------------------------ | ----------------------------------------- |
| `recover` run 1 (old tool)                           | 19:30:21 → 19:34:54             | ≈ 89.6 s (273 s − 3 × 60 s timeouts − 3.4 s cleanup) | ≈ 80 s                         | ≈ 3,000–4,000 (no progress line < 64 KiB) |
| `recover` run 2 (old tool)                           | 19:37:49 → 19:41:21             | ≈ 28.6 s (212 s − 183.4 s)                           | ≈ 19–21 s                      | ≈ 800–1,000 [I]                           |
| `link-soak` F1                                       | 22:31:11 → 22:34:44             | t = 29.42 s on the link clock                        | **19.4–22.4 s**                | 1,110 good, #1111 unanswered              |
| `loader-hello` D, `info-dump` E, two `loader-hello`s | 13 s, 15 s, 14 s, 18 s in total | passed                                               | ≈ 1–6 s                        | ≈ 30–300                                  |

How F1's bound is derived:

- _Upper limit (19.4 s after the relay started at the earliest):_ the 1,111 exchanges took about 19.4 s at the measured 17.5 ms each, so the relay started at t ≤ 10.0 s.
- _Lower limit (22.4 s at the latest):_ before the relay can start, the case must print its banner (0.29 s in step 0's report) and reset into the ROM. Then 55,752 B of case flash must cross the ROM link at 115,200 Bd 8E1, at least 5.3 s on the wire. Writing and reading back the 5,508-B relay takes at least 1.1 s more. So t ≥ 7 s.
- _The `recover` rows:_ the old tool has no frame log. Their stall times come from each run's duration less the three 60 s timeouts and F1's cleanup time.

What the numbers say:

- The watchdog would need a period of at least 30.8 s (4096 × 256 / 34 kHz, the LSI's fastest). F1 stopped 19.4–22.4 s after the relay started, and run 1 about 80 s after.
- Even counted from the ROM entry, F1's stall at about 27–29 s is below 30.8 s.
- The ROM loader refreshes a running IWDG and sets its prescaler to the maximum (AN2606), so it would count from Go, not from the ROM entry.

**Hypotheses that remain, ranked.** Each fits the relay record, which cannot tell a hang from a reset.

1. **A per-exchange hang in stock case HAL code with interrupts masked [I].** Every exchange runs these through the case's flash:
   - the UART3 re-init, `RX_PROFILE` `0x08006C80` / `TX_PROFILE` `0x08006CF8`:
     - `HAL_UART_DeInit` `0x08005F00` → USART3 at 1 MBd, RX- or TX-only, overrun detection off;
     - `HAL_UART_Init` `0x08006240` → `MspInit` `0x08006308` (`HAL_RCCEx_PeriphCLKConfig` `0x08005128`, GPIO `0x08004D30`) → `UART_CheckIdleState` `0x0800867C` → `UART_WaitOnFlagUntilTimeout` `0x08008EC4`, which waits for TEACK/REACK;
     - the FIFO calls `0x08005EB6` / `0x08005E6E` / `0x08005E2E`;
   - `HAL_UART_Transmit` (`0x080066AC`, through `0x08003BB0` with timeout `0xFFFF`; the relay's 100 is ignored).

   Their timeouts read `uwTick` (`0x20000120`, `HAL_GetTick` `0x08004EAC`), which never advances with SysTick masked. So a flag that doesn't come is a hang forever, and any non-OK return goes to `Error_Handler` `0x08003E90` (`cpsid i; b .`). That is about 57 HAL sequences per second.

   This fits all three stalls as a rare random event (≈ 850, 1,111 and ≈ 3,500 exchanges), and the short sessions mostly passing. The exact flag or race is not identified.

2. **Wall time since the case left its own firmware [I].** The stalls of F1 and `recover` run 2 both came 19–22 s after the relay started (27–29 s after the ROM entry). Every passing session ended sooner. The cause would be outside the MCU's code: something the case firmware normally services and the ROM and relay don't, such as a charger or power-path timer, or a brown-out on the 5 V/pogo side. Run 1 (≈ 80 s) contradicts it, unless that run spent one more 60 s read waiting on a stray byte. Nothing in its log shows one.
3. **A hang at the start of the bridge's exit path [I, least likely].** If `exchange()` returns early (a framing or noise error on the host UART, which the record does not log), the bridge goes to the YHM restore (`0x200105D0`, then `0x20010510` → stock I2C write `0x08009108`). A hang in its first write leaves exactly this record. But every normal exit runs the same code without trouble.

**The cheapest read-only experiment that decides between 1 and 2.** It takes about 3 minutes:
`w18.py link-soak --side left --idle-s 45 --bytes 65536`

- _What it does:_ after the claim and the bootloader CRC, the relay is kept running for 45 s with no temple traffic. The tool sends empty `G2TX` frames, and the relay answers each one with status 2 after its own poll bound, so 3–4 stock UART re-inits replace about 2,500 exchanges. Then it streams 64 KiB (about 4,400 exchanges, about 77 s).
- _If it stops during the pause_ (`stopped_in: idle pause…`, `stall.since_relay_start_s` ≈ 20–30): it is wall time (2). Short sessions are the fix: `--max-session-s 12`.
- _If the pause passes and the stream stops later:_ it is per exchange (1 or 3). Short sessions only lower the odds, and the real fix is a relay that does its own register-level UART3 switching instead of calling the stock HAL. That would be a new relay build, pinned and reviewed like this one.
- _If everything passes:_ the cause is rarer than the stalls so far suggested. Run the split soak below to measure its rate.

Each pause tick also measures the relay's poll bound on real hardware. It is reported in `idle_ticks_s` and gives the case MCU's actual clock.

**Not done, and why:** the relay was not changed. Refreshing the IWDG (`0xAAAA` to `IWDG_KR`) would be harmless, but on this case it would do nothing, because the IWDG is never running. Changing a pinned, hardware-proven relay binary for no effect is risk without benefit. If the experiment points at (1), the next relay change is the HAL-free UART3 switch above, and the right temple will use the same relay.

**Fixed in the tool, whatever the cause:**

- **Session-time guard.** `recover` now splits its write into sessions that each end within `--max-session-s` seconds after the relay starts (default 12; 0 = one session).
  - Every session claims, checks the bootloader CRC and the update flag, and releases, with every existing gate. It CRC-checks the body written so far against the image before it adds a part (the resume check), and CRC-checks its part afterwards.
  - The 16 vector bytes are written only in a session that has just CRC-checked the whole body, never in a part, and once.
  - A stop at any point leaves the old vectors in place, and the report prints `--resume-at N`. A later run CRC-checks those N bytes before it writes anything, and refuses on a mismatch.
  - `link-soak` takes the same `--max-session-s` (default: one session).
- **Decision experiment.** `link-soak --idle-s S` (above).
- **Reports.** `relay_started_t` (on the frames' time base), `stall` (the first failed exchange and its time since the relay started), and each session's `relay_seconds` and exchange count.
- **Tests.** The relay model now has a virtual clock: 17.5 ms per exchange, 12 s per empty `G2TX`. It can stop by wall time or by exchange count.
  - A one-session soak in the model stops at exchange #1142, 20.0 s in, with the hardware's record.
  - Split runs pass, each session within the budget.
  - A split `recover` stopped in its third session leaves the old vectors and resumes only after the CRC check.
  - The idle pause separates the two causes.
  - drdaeman's real relay binary under Unicorn answers the empty `G2TX` with status 2 and carries on.
  - In Renode, `recover-split` writes stock 2.4.0.24 to a dead temple over many relay sessions, each resumed by CRC, with the real bootloader and loader (see the table above).

**Cost of the guard on hardware [I].** A 12 s session writes about 600 exchanges, about 8.7 KiB of body. Each session also pays about 12–16 s outside the relay: the banner, the ROM entry, the 55,752-B case flash hash and the relay load, then the cleanup. That puts a full `recover` at about 425 sessions, **about 3–3.5 h**, and the 1 MiB soak at about 120 sessions, about 50 min. It is slow but every step is checked. A relay without the stall would bring `recover` back to about 70 min in one session.

#### The ~30 s clock that survives case resets

The timing across five stalls fits one clock: time since the case's own 1.2.57 app last ran for more than a moment. Brief banner boots do not reset it. This analysis looked for an external chip that the app services and the ROM and relay do not. It was done on t3-worker from the pinned image (SHA-256 `773b6d4c…`), Capstone, Unicorn and the vendor datasheet. Nothing touched hardware. Tags: [C] checked in the code, [I] inferred, [D] datasheet.

**Verdict: the case has an external watchdog, a YHMICROS YHM4005, and the app arms it at every boot. Only the app feeds it.** It is the strongest candidate for the stalls (confirmed on hardware the same day: [The relay feeds the case watchdog](#the-relay-feeds-the-case-watchdog)). Its configured timeout is 20 s nominal, though, a little short of the observed 26.6–31.0 s (see "What does not fit yet").

**The chips and their buses [C].** The case has no hardware I2C. There is no I2C1/2/3 base literal, and every chip is bit-banged on GPIO.

| Chip (log name) | Bus and pins | Address | Identity check in the self-check |
| --- | --- | --- | --- |
| PMIC ("pmic") | I2C-like bit-bang on GPIOB: SCL = PB3, SDA = PB4 (`0x0800A550`/`0x0800A574`, pin order chosen by flag `0x20000114` = 0) | 8-bit `0x70`/`0x71`, so 7-bit `0x38` (read `0x0800292C`, write `0x08002A00`) | Reg `0x14` must read `0x14`. It is a marker the firmware writes, not a silicon ID. 0 means "pmic in shipmode". Any other value means "reset pmic register...": `0x080035F0` writes `0x13`=`0x90`, `0x16`=0, `0x19`=2, `0x17`=`0x28`, `0x18`=1, `0x1A`=0, `0x1B`=1, then `0x14`=`0x14`. |
| "2217" | the same PB3/PB4 bus | 8-bit `0xC8`/`0xC9`, so 7-bit `0x64` (`0x080028B4`, `0x080029A4`) | Reg 0 must read `0xA0`. It has an interrupt ("2217 int"), whose handler reads PMIC regs `0x10`/`0x11`. |
| YHM2510 (pogo switch) | YHMICROS "ACMD" single-wire on PA3 (`0x0800A19A`/`0x0800A24A`; transactions `0x08000310`, `0x080004C0`, `0x08000610`) | device byte `0x42` (read), `0x02` (fuse read) | Reg 0 must read `0x81`; reg `0xA4` gives adjVal. |
| YHM4005 (watchdog) | ACMD single-wire on **PB2** (`0x0800A188`/`0x0800A224`; read `0x08000420` via `0x08008FA8`, write `0x0800056C` via `0x08009004`) | device byte `0x5A` | Reg 0, high nibble must be 9. |

- The earlier note that the bridge's YHM restore is a "stock I2C write `0x08009108`" should read: an ACMD single-wire write to the 2510 on PA3.
- The PMIC's part number is still unknown. Its regs `0x10`–`0x1B` include boost enable (reg `0x15`: `0x09` on, `0x08` off, `0x08002C30`) and a ship mode. The banner's `d8 4c 00 90 14 08 00 28` matches what the firmware writes (`0x13`=`0x90`, `0x14`=`0x14`, `0x15`=`0x08`, `0x17`=`0x28`). No public register map for it, or for the "2217", was found. Neither chip has a watchdog write anywhere in the image [C].

**How the app arms the watchdog [C].** `0x08002C8E(en)` is the only writer:

- With `en` = 1 it writes 4005 reg 5 = `0x3B`, then reg 4 = `0x07`.
- With `en` = 0 it writes reg 4 = 0. Callers: standby (`0x08000B82`, `0x08007294`, `0x08007340`, `0x08007E70`), ship-mode failure in the self-check (`0x0800315C`), and console command `0xD0` ("%s watchdog 4005").
- With `en` = 1, the only caller is the boot self-check: `0x08003278`, right after the 4005 ID check at `0x08003260`.

Decoded with the datasheet [D]:

- Reg 4 (CTRL) = `0x07` sets EN_DOG (enable), RST_DOG (clear the timer now) and **EN_WDI: any falling edge on the ACMD pin feeds the dog**.
- Reg 5 (TIMER) = `0x3B` sets TIME_OUT[6:3] = 7, which is **tTOUT = 20 s** (±10%; the YHM4005C variant multiplies every time by 1.25, giving 25 s). It also sets RSTPL_TIME[2:0] = 3, a **500 ms reset pulse**.
- Reg 6 is never written [C], so RST keeps its defaults: push-pull, active low [D].
- The part powers up disabled and stays enabled until written. If no feed comes, it pulses RST at the end of every TIME_OUT slot.

**How the app feeds it [C].** The feed is in `pwrManagerTask` (entry `0x08007201`, created at `0x080069EC`):

- Each loop it increments a counter at `0x20000884`, which starts at 0. When `counter % 5 == 0` (`0x08007220`) and the flag at `0x200000BE` is set, it calls `0x08002CB8` → `0x0800A270`. The flag is 1 in the decompressed `.data`; console command `0xDF` ("%s dog feed") toggles it.
- `0x0800A270` drives PB2 as a push-pull output (init struct at `0x20000014`: pin mask 4, output, no pull, very high speed). It sets PB2 high for about 0.1 ms, low for about 4.4 ms (41 × a 350-iteration delay loop), then high again [C; the µs values are an estimate at 16 MHz, I; the case runs at 64 MHz, so about 1.5–2 ms low: see [the correction below](#the-relay-feeds-the-case-watchdog)].
- The loop ends with `osDelay(1000)` (`0x08007EDA`). The tick is 1 kHz: SysTick LOAD = SystemCoreClock / 1000 − 1 at `0x0800C078`, with SystemCoreClock = 16 MHz (its reset value; `SystemClock_Config` raises the clock to 64 MHz and the tick stays 1 kHz [I]). So **one feed every 5 loops, about every 5 s**, plus the loop body's own time.
- The first feed comes on the task's first loop. The arming in the self-check also clears the timer (RST_DOG). There is no other periodic action toward any chip: no timer ISR, and no charger re-write that looks like a kick.

**What happens in the ROM and the relay [C + I].**

- Neither the ROM nor the relay touches PB2. After NRST, PB2 is back in its reset state (analog), so no falling edge comes, and the 4005, which runs on its own supply and is not reset with the MCU, keeps counting [I].
- After tTOUT it pulses RST for 500 ms. SRAM survives a pin reset. The case comes back up in the ROM because the tool holds DTR. That matches the record exactly: intact relay record, case silent [I]. Where RST is wired is not visible in code. MCU NRST is the reading that fits.
- Because EN_DOG stays set, the 4005 would keep resetting the case every ~20.5 s while it sits in the ROM.

**Why brief boots do not reset the clock [C].**

- `case_banner` (`wisp_case/transport.py`) stops reading as soon as it has seen the `****** B200` banner and `Power up...`, and `enter_rom` holds reset again right after.
- But `main` prints `Power up...` (`0x0800A6BA`) **before** it calls the self-check `0x08002FC8` (`0x0800A6C6`).
- The self-check runs the 2217 ID, the PMIC check, `HAL_Delay(10)`, the 2510 ID, then the 4005 ID and arming, then `HAL_Delay(125)` (`0x080032BC`). Only after that come the PMIC reset and `osKernelStart`.
- So a banner-only boot is cut tens of milliseconds after `Power up...`. That is before the first pwrManagerTask feed, and probably before the arming write at `0x08003278` [I: it depends on the host's close/reopen latency].
- The data says brief boots do not reset the clock. That means the arming write, which sets RST_DOG and would reset the timer [D], did not run in them either. A full-listen capture (`probe-reset`) shows the whole self-check. A banner-only capture should end before `4005 self check done.`

**What does not fit yet [I].**

- The stall should come at the last feed + 20 s ± 2 s, plus up to 0.5 s of reset pulse. The last feed falls 0–5 s before the app is stopped. So the 4005 predicts a stall **15–22.5 s** after the app stopped (or 17.5–27.5 s for a YHM4005C).
- Observed: 26.6–31.0 s. The spread of 4.4 s matches the 5 s feed period well, but the offset is 5–9 s longer than the 20 s grade allows.
- Possible reasons:
  - The fitted reference point is earlier than the true last feed.
  - Detection lag: idle `G2TX` ticks are 12 s apart.
  - The part is a variant with a longer table.
  - The 4005 is not the cause.
- That leaves the hypothesis strong, not proven. The test below decides it.

**What a fix needs.**

1. **Relay-side feed (the real fix) [C + D].** While the relay runs, drive a falling edge on PB2 at least every 10 s (every 5 s, as the app does). That needs EN_WDI = 1, which the app has already set. Copy `0x0800A270` with plain register writes:
   - `RCC_IOPENR` (`0x40021034`) |= bit 1 (GPIOB clock);
   - `GPIOB_MODER` (`0x50000400`): bits 5:4 = `01` (output);
   - `GPIOB_BSRR` (`0x50000418`) = `0x00000004` (high), wait about 0.1 ms;
   - `GPIOB_BSRR` = `0x00040000` (low), wait about 4.4 ms, then `0x00000004` (high).

   This removes the session-time limit. It is a change to the pinned relay, so it needs the same review and pinning as any relay change. A one-time ACMD write of 4005 reg 4 = 0 (the app's own standby path) would disable the dog instead. But it means porting the parity single-wire protocol into the relay, which is more code for the same effect.
2. **Host-side, between sessions, through the ROM's Write Memory [I, not recommended].** AN3155's Write Memory only accepts RAM, flash and option-byte addresses, so peripheral registers cannot be poked directly. The host could load a small SRAM stub, Go to it (pulse PB2 as above), and have it reset back into the ROM. That costs a ROM re-sync, and it is a new code path that does nothing the relay change would not.
3. **Host-side, letting the app run before each session (no relay change).**
   - Before `enter_rom`, keep the app running until the console shows `4005 self check done.` That line comes after the arming write, which clears the timer (RST_DOG) [C + D]. Safer still, give it about 1.5 s after `Power up...`. The first pwrManagerTask feed follows within a few hundred ms [I].
   - From that point, a session must end within tTOUT_min = 18 s. ROM entry, the 55,752-B hash and the relay load take at least about 7 s.
   - **So keep the relay part ≤ 10 s** under the datasheet grade. The current 12 s default is only safe if the observed ≥ 26.6 s is the true margin.
   - The `case_banner` used by `start()` would need to wait for that line instead of `Power up...`. That is a tool change, not done here.

**Cheapest read-only test that decides it [I].**

- Boot the app fully, past `4005 self check done.`, then enter the ROM and load nothing. Send `GET` (`0x00 0xFF`) every 1 s and log when it stops being ACKed. After a reset, the ROM needs a new `0x7F` sync.
- If the 4005 is the cause, the ACKs stop about 20 s (or 25 s) after the self-check line. Re-syncing with `0x7F` then works again, and the next silence comes about 20.5 s (25.5 s) later.
- No relay and no temple traffic are involved, and nothing is written.

Sources: the YHM4005 product page, <http://www.yhmicros.com/productw.asp?id=136>, and the datasheet it links (V1.0, Dec 2024, `pdfjs/web/202697105331182.pdf` on that host, register map §5.1.4); STM32 AN3155 (Write Memory address check).

#### The relay feeds the case watchdog

**Confirmed on hardware (2026-11-07, case only, read-only; [hardware log](safety.md)).** The probe synced the case ROM and sent `GET` once a second, with no relay and no temple traffic. The case reset about 17–19 s after the ROM entry and then every ~20–21 s, whatever the app had run before (2 s or 30 s). After each reset the ROM needed a fresh `0x7F` sync. Log: `apps/wisp-recovery/runs/case-wdt-probe-20261107T162921Z.txt` (Mac). So the YHM4005 above is the cause of every long-session stall, with the timeout the app sets (reg 5 = `0x3B`, 20 s), fed by any falling edge on PB2 (reg 4 = `0x07`). Only the app's `pwrManagerTask` feeds it (`0x08007220` → `0x0800A270`, every 5 s). The ROM loader and drdaeman's relay never touch PB2.

**Two corrections to the analysis above [C].**

- **The case runs at 64 MHz, not 16 MHz.** `SystemClock_Config` (`0x08008438`) sets HSI16 × 8 / 2 = 64 MHz, AHB and APB ÷1. 16 MHz is only `SystemCoreClock`'s reset value. The bridge calls this function first, so the relay runs at 64 MHz too. Its own constants assume that clock (`BRR` = 556 for 115,200 Bd, 21,334 turns of a 3-cycle loop per millisecond). The measured 18.1 s empty-`G2TX` bound also fits: 64,000,000 polls of an 18-cycle loop at 64 MHz. So the app's feed pulse is about 1.5–2 ms low, not 4.4 ms.
- **What did not fit now does.** The relay stalls came 19.2–22.4 s after the relay started (F1, F1a), that is 20 s ± 10 % after the relay start, not after the app last ran. The relay start drives PB2 low once: the bridge's first calls into the case flash are `main()`'s own `HAL_Init`, `SystemClock_Config`, `MX_GPIO_Init` and the PMIC bus init. `MX_GPIO_Init` (`0x08006A40`) does `HAL_GPIO_WritePin(GPIOB, PB2, 0)` and then makes PB2 a push-pull output. If the line idles high while the MCU leaves it floating, as it does in the ROM, that is one falling edge, one feed, at every relay start [I]. The case-only probe (no relay) reset 17–19 s after the ROM entry, as the app's last feed plus 20 s predicts. A banner boot runs the same `MX_GPIO_Init` before `Power up...`, yet F1b suggests banner boots do not reset the clock. That difference is not explained. It does not matter for the fix.

**The fix: case relay `observed-33-feed` (the tool's new default, both temples).**

| | |
| --- | --- |
| Pin | `4c7475fada40e748e64d2a47d5d60fa8a189f23d7afd74f7cecd8f95844047d5`, 5,808 bytes (`pins.RELAY_SHA256["observed-33-feed"]`) |
| Built by | `image.build_relay("observed-33-feed")`: observed-33 (`6beb9a5e…`, rebuilt from the pinned template and the cached case firmware), then `relay_feed.apply()`. Six 4-byte sites are re-pointed, each checked for drdaeman's exact bytes, and 300 bytes of our code are appended at `0x20011584`. |
| Our code | `wisp_w18/data/case_relay_feed.S` (MIT), assembled with binutils 2.46 to `case_relay_feed.bin`, SHA-256 `ff1efaf733b52ba26975583c8e630411f15bf073cb498b64247da5c73c5983c3` (the commands are in the file's header) |
| Old relay | `--case-profile observed-33` still loads `6beb9a5e…`, for comparison |

What it does:

- **At relay start** (in place of the bridge's `bl 0x200103e8`, before the banner), after the bridge's own init:
  - `RCC_IOPENR` |= GPIOBEN and `RCC_APBENR1` |= TIM6EN, both read-modify-write.
  - PB2 is set up as the app's feed sets it up: first `BSRR` = PB2 high, then `OTYPER` push-pull, `PUPDR` no pull, `OSPEEDR` very high and `MODER` bits 5:4 = `01`. Each is a read-modify-write of PB2's bits only.
  - PB2 stays high for 100 µs, then goes low for a busy 4.5 ms and high again: the first feed, within a millisecond of Go. No UART traffic is possible yet, and the bridge busy-waits 0.1 s right after anyway.
  - TIM6 starts at 10 kHz (`PSC` = 6399), with `URS` set, in the 2.0 s high phase.
- **The feed itself:** PB2 is low for 4.5 ms (45 ticks), then high for 2.0 s (20,000 ticks), and so on. Each change happens at the first poll after TIM6 overflows, in `feed_tick`, so a stretch without polls (at most ~0.1 s, the temple reset waveform) lengthens that phase. A long low is harmless: the app's own boot holds PB2 low from `MX_GPIO_Init` to its first feed. One falling edge comes every 2.0045 s plus the time to that poll. The 4005 needs one within 18 s (20 s − 10 %).
- **Where it polls.** The check is one load and one bit test of TIM6's update flag. It sits in every loop the relay can wait in:

  | Loop | Site |
  | --- | --- |
  | the bridge's host read (`G2RQ`) | `0x2001031C` |
  | the wait for the temple's `HELO` | `0x2001074C` |
  | the wait for a temple frame (the per-exchange loop, and the empty-`G2TX` poll bound) | `0x200108B2` |
  | the relay's host read (`G2TX`, `G2EX`) | `0x200109BC` |
  | the bridge's 25 ms wait between `G2RS` and its reset, in a version that polls (`fed_delay`) | `0x20010232` |

  So the relay feeds right up to the bridge's own reset, 25 ms after `G2RS`. The case then waits unfed in its ROM for the host's cleanup: NRST 0.3 s later, about 2 s of ROM work, then the case app runs and feeds. That is at most about 4.5 s after the last feed.
- **Why TIM6.** The relay runs with interrupts masked and SysTick off: the bridge clears `SYST_CSR` and every NVIC enable. So the time source has to be polled.
  - TIM6 is a basic timer the case app never references (no `0x40001000` literal in 1.2.57). Its update flag is sticky: a stretch without polls (a stock UART re-init, a YHM2510 transaction, the ~0.1 s temple reset waveform) delays the next feed but never loses one, however long the stretch.
  - SysTick `COUNTFLAG` would wrap every 0.26 s at 64 MHz (2.1 s at HCLK/8). Any gap longer than one wrap would silently lose time, which is the unsafe direction.
  - The clock is the app's own 64 MHz. If it were ever 4× slower, the feeds would come every 8 s, still inside 18 s.
- **Why no busy pulse.** A 4.5 ms busy-wait would drop host bytes (USART1, a 1-byte receive register, 87 µs a byte) or temple bytes (USART3 at 1 Mbaud, overrun detection off). The pulse is started and ended by later polls, so a poll never waits. The temple path is unchanged: no frame, delay or waveform byte differs.
- **Not hooked, on purpose:**
  - **Even's temple reset waveform.** It takes about 0.1 s, and its delays (the relay's `case_reset_delay_ms`) must keep their exact timing. The `HELO` wait right after it polls.
  - **The bridge's 0.1 s delay before the banner.** It comes right after the first feed.
  - **The host transmit loops.** UART-bound, at most a few ms.
  - **The stock case HAL calls.** They take µs. If one hung with interrupts masked (hypothesis 1 above), nothing in SRAM could help. The 4005 would then reset the case about 20 s later, which the cleanup handles.
- **Layout.** Nothing the tool or the bridge relies on moves. The record stays at `0x20011A00`, `PROOF` at `0x20011B00`, the `G2RQ` buffer at `0x20011900` and the `G2RS` buffer at `0x20011C00`; the stack top is `0x2001F000`. The code uses `0x20011584`–`0x200116AF` of the free `0x20011584`–`0x200118FF`. The tool's SRAM allowlist (`rom.sram_regions`) admits the 5,808-byte program region because it ends below the record. As before, the ROM may only write the relay's own bytes or zeros.
- **Safety.** The added code addresses only `RCC_IOPENR`/`RCC_APBENR1`, GPIOB and TIM6. Its literal pool holds no other address, and it calls only the bridge's init and itself. It never calls into the case flash. Under emulation no instruction writes the case flash or the FLASH registers (checked in every new test). The ROM command allowlist and the SRAM allowlist are unchanged. The case flash is still never written.
- **Side effect: longer poll bounds [I, cycle counts from the listing].** Each poll now costs about 13 more cycles:

  | Wait | Before | Now |
  | --- | --- | --- |
  | `G2RQ` | ~14 s | ~27 s |
  | `HELO` | ~16 s | ~29 s |
  | temple frame, and the empty-`G2TX` answer | 18.1 s (measured) | ~31 s |
  | host byte | ~13 s | ~26 s |

  The host's timeouts (60 s per frame, 120 s per empty `G2TX`) still cover them. `link-soak --idle-s` ticks are about 30 s now.

The changed regions, disassembled (`arm-none-eabi-objdump`). Everything else is byte-identical to observed-33.

| Site | observed-33 | observed-33-feed |
| --- | --- | --- |
| `0x20010032` | `f000 f9d9  bl 0x200103e8` (bridge init) | `f001 faa7  bl 0x20011584 <feed_start>` |
| `0x20010232` | `f000 f9f7  bl 0x20010624` (the 25 ms wait before the reset) | `f001 fa20  bl 0x20011676 <fed_delay>` |
| `0x2001031C` | `69d0  ldr r0, [r2, #28]` / `210f  movs r1, #15` | `f001 f97f  bl 0x2001161e <poll_bridge_rx>` |
| `0x2001074C` | `69d9  ldr r1, [r3, #28]` / `240f  movs r4, #15` | `f000 ff72  bl 0x20011634 <poll_beacon>` |
| `0x200108B2` | `2002  movs r0, #2` / `2b00  cmp r3, #0` | `f000 feca  bl 0x2001164a <poll_temple_rx>` |
| `0x200109BC` | `6826  ldr r6, [r4, #0]` / `0737  lsls r7, r6, #28` | `f000 fe50  bl 0x20011660 <poll_host_rx>` |

No branch targets the second instruction of a displaced pair. Each enclosing function saved LR on entry, so the extra `bl` clobbers nothing live. Each hook runs the displaced pair last, so the flags the next branch tests are theirs.

<details>
<summary>The appended code, 0x20011584–0x200116AF (300 bytes)</summary>

```text
20011584 <feed_start>:
20011584:  b510       push    {r4, lr}
20011586:  f7fe ff2f  bl      200103e8 <bridge_init>
2001158a:  4841       ldr     r0, [pc, #260]  @ literal at 20011690
2001158c:  6801       ldr     r1, [r0, #0]
2001158e:  2202       movs    r2, #2
20011590:  4311       orrs    r1, r2
20011592:  6001       str     r1, [r0, #0]
20011594:  6881       ldr     r1, [r0, #8]
20011596:  2210       movs    r2, #16
20011598:  4311       orrs    r1, r2
2001159a:  6081       str     r1, [r0, #8]
2001159c:  6881       ldr     r1, [r0, #8]
2001159e:  483d       ldr     r0, [pc, #244]  @ literal at 20011694
200115a0:  2104       movs    r1, #4
200115a2:  6181       str     r1, [r0, #24]
200115a4:  6841       ldr     r1, [r0, #4]
200115a6:  2204       movs    r2, #4
200115a8:  4391       bics    r1, r2
200115aa:  6041       str     r1, [r0, #4]
200115ac:  68c1       ldr     r1, [r0, #12]
200115ae:  2230       movs    r2, #48 @ 0x30
200115b0:  4391       bics    r1, r2
200115b2:  60c1       str     r1, [r0, #12]
200115b4:  6881       ldr     r1, [r0, #8]
200115b6:  4311       orrs    r1, r2
200115b8:  6081       str     r1, [r0, #8]
200115ba:  6801       ldr     r1, [r0, #0]
200115bc:  4391       bics    r1, r2
200115be:  2210       movs    r2, #16
200115c0:  4311       orrs    r1, r2
200115c2:  6001       str     r1, [r0, #0]
200115c4:  4934       ldr     r1, [pc, #208]  @ literal at 20011698
200115c6:  3901       subs    r1, #1
200115c8:  d1fd       bne.n   200115c6 <feed_start+0x42>
200115ca:  2101       movs    r1, #1
200115cc:  0489       lsls    r1, r1, #18
200115ce:  6181       str     r1, [r0, #24]
200115d0:  4932       ldr     r1, [pc, #200]  @ literal at 2001169c
200115d2:  3901       subs    r1, #1
200115d4:  d1fd       bne.n   200115d2 <feed_start+0x4e>
200115d6:  2104       movs    r1, #4
200115d8:  6181       str     r1, [r0, #24]
200115da:  4b31       ldr     r3, [pc, #196]  @ literal at 200116a0
200115dc:  6019       str     r1, [r3, #0]
200115de:  4931       ldr     r1, [pc, #196]  @ literal at 200116a4
200115e0:  6299       str     r1, [r3, #40] @ 0x28
200115e2:  4931       ldr     r1, [pc, #196]  @ literal at 200116a8
200115e4:  62d9       str     r1, [r3, #44] @ 0x2c
200115e6:  2101       movs    r1, #1
200115e8:  6159       str     r1, [r3, #20]
200115ea:  2100       movs    r1, #0
200115ec:  6119       str     r1, [r3, #16]
200115ee:  2105       movs    r1, #5
200115f0:  6019       str     r1, [r3, #0]
200115f2:  bd10       pop     {r4, pc}

200115f4 <feed_tick>:
200115f4:  b407       push    {r0, r1, r2}
200115f6:  482a       ldr     r0, [pc, #168]  @ literal at 200116a0
200115f8:  4926       ldr     r1, [pc, #152]  @ literal at 20011694
200115fa:  694a       ldr     r2, [r1, #20]
200115fc:  0752       lsls    r2, r2, #29
200115fe:  d504       bpl.n   2001160a <feed_tick+0x16>
20011600:  2201       movs    r2, #1
20011602:  0492       lsls    r2, r2, #18
20011604:  618a       str     r2, [r1, #24]
20011606:  222c       movs    r2, #44 @ 0x2c
20011608:  e002       b.n     20011610 <feed_tick+0x1c>
2001160a:  2204       movs    r2, #4
2001160c:  618a       str     r2, [r1, #24]
2001160e:  4a26       ldr     r2, [pc, #152]  @ literal at 200116a8
20011610:  62c2       str     r2, [r0, #44] @ 0x2c
20011612:  2201       movs    r2, #1
20011614:  6142       str     r2, [r0, #20]
20011616:  2200       movs    r2, #0
20011618:  6102       str     r2, [r0, #16]
2001161a:  bc07       pop     {r0, r1, r2}
2001161c:  4770       bx      lr

2001161e <poll_bridge_rx>:
2001161e:  4923       ldr     r1, [pc, #140]  @ literal at 200116ac
20011620:  6809       ldr     r1, [r1, #0]
20011622:  0849       lsrs    r1, r1, #1
20011624:  d303       bcc.n   2001162e <poll_bridge_rx+0x10>
20011626:  4671       mov     r1, lr
20011628:  f7ff ffe4  bl      200115f4 <feed_tick>
2001162c:  468e       mov     lr, r1
2001162e:  69d0       ldr     r0, [r2, #28]
20011630:  210f       movs    r1, #15
20011632:  4770       bx      lr

20011634 <poll_beacon>:
20011634:  4c1d       ldr     r4, [pc, #116]  @ literal at 200116ac
20011636:  6824       ldr     r4, [r4, #0]
20011638:  0864       lsrs    r4, r4, #1
2001163a:  d303       bcc.n   20011644 <poll_beacon+0x10>
2001163c:  4674       mov     r4, lr
2001163e:  f7ff ffd9  bl      200115f4 <feed_tick>
20011642:  46a6       mov     lr, r4
20011644:  69d9       ldr     r1, [r3, #28]
20011646:  240f       movs    r4, #15
20011648:  4770       bx      lr

2001164a <poll_temple_rx>:
2001164a:  4818       ldr     r0, [pc, #96]  @ literal at 200116ac
2001164c:  6800       ldr     r0, [r0, #0]
2001164e:  0840       lsrs    r0, r0, #1
20011650:  d303       bcc.n   2001165a <poll_temple_rx+0x10>
20011652:  4670       mov     r0, lr
20011654:  f7ff ffce  bl      200115f4 <feed_tick>
20011658:  4686       mov     lr, r0
2001165a:  2002       movs    r0, #2
2001165c:  2b00       cmp     r3, #0
2001165e:  4770       bx      lr

20011660 <poll_host_rx>:
20011660:  4f12       ldr     r7, [pc, #72]  @ literal at 200116ac
20011662:  683f       ldr     r7, [r7, #0]
20011664:  087f       lsrs    r7, r7, #1
20011666:  d303       bcc.n   20011670 <poll_host_rx+0x10>
20011668:  4677       mov     r7, lr
2001166a:  f7ff ffc3  bl      200115f4 <feed_tick>
2001166e:  46be       mov     lr, r7
20011670:  6826       ldr     r6, [r4, #0]
20011672:  0737       lsls    r7, r6, #28
20011674:  4770       bx      lr

20011676 <fed_delay>:
20011676:  b510       push    {r4, lr}
20011678:  0884       lsrs    r4, r0, #2
2001167a:  d007       beq.n   2001168c <fed_delay+0x16>
2001167c:  480b       ldr     r0, [pc, #44]  @ literal at 200116ac
2001167e:  6800       ldr     r0, [r0, #0]
20011680:  0840       lsrs    r0, r0, #1
20011682:  d301       bcc.n   20011688 <fed_delay+0x12>
20011684:  f7ff ffb6  bl      200115f4 <feed_tick>
20011688:  3c01       subs    r4, #1
2001168a:  d1f7       bne.n   2001167c <fed_delay+0x6>
2001168c:  bd10       pop     {r4, pc}
2001168e:  0000       .short  0x0000
20011690:  40021034   .word   0x40021034
20011694:  50000400   .word   0x50000400
20011698:  00000855   .word   0x00000855
2001169c:  00017700   .word   0x00017700
200116a0:  40001000   .word   0x40001000
200116a4:  000018ff   .word   0x000018ff
200116a8:  00004e1f   .word   0x00004e1f
200116ac:  40001010   .word   0x40001010
```

</details>

**Verified in emulation (t3-worker, Unicorn 2.1.3; `tests/test_case_watchdog.py`, [C, emulation]).** `fake_case.py` now models emulated time, GPIOB, TIM6 and a YHM4005 on PB2. The 4005 resets the case 20 s after the last falling edge, keeps SRAM and leaves the case in its ROM. That ROM stays deaf until the next reset if its first byte is not `0x7F`. The relay binary under test is the template (Even's waveform is a hook), with and without the feed. It runs behind the real `CaseRelayLink`, `Session` and `cli`.

| Run | Old relay (observed-33 layout) | New relay (with the feed) |
| --- | --- | --- |
| idle, empty `G2TX`s only | the first is answered 18.16 s after the relay started (hardware: 18.1 s); the 4005 resets the case 20.01 s after the relay started; the next `G2TX` gets no answer; record phase 1 (the hardware's); the ROM hears `G2TX` first and stays deaf, and the cleanup's NRST still gets a fresh one | three `G2TX`s, 87 s in all; no reset; 42 feeds, one every 2.01–2.10 s (2.0045 s plus up to two 50 ms emulation steps); exit status 6, route restored |
| pulse shape (0.5 ms steps) | | 14 pulses: low 5.0 ms (4.5 ms plus one step), high 2.0001 s |
| `link-soak --bytes 65536`, 17.5 ms per exchange, one session | stops at exchange #1,133, the 4005 firing 20.00 s after the relay started (hardware F1: #1,111) | passes: 4,113 exchanges, 73 s, CRC matches, no reset |
| `recover --max-session-s 0`, 110,000 B, 17.5 ms per exchange | | passes in one session: 7,397 exchanges, 131 s; body, vectors last, final CRC |
| the 4005's next reset lands in the cleanup's ROM session | the cleanup's first ROM session is cut, the second (fresh NRST) reads the record and zeroes the SRAM; the case ends on its app | |
| every wait loop, given time (host thinks 3 s per write, `HELO` 3 s late) | | all four poll hooks call `feed_tick`; the 25 ms `fed_delay`, run alone with the flag set, feeds and returns cleanly |

`relay_model.RelayModel` has the same watchdog (`watchdog_s`, `feeds_watchdog`). Without the feed, one 64 KiB soak session stops 20 s in. With it, the soak passes in one session of more than 60 s. The session-guard tests keep the old relay (`--case-profile observed-33`), where the guard is what keeps a session alive.

**Cleanup after an unexpected case silence [C + I].** After a 4005 reset during a session, the host's next bytes (`G2TX`, `G2EX`) reach the case ROM before any `0x7F`. Its autobaud locks onto them, and it ignores syncs until the next reset.

- `close()` sends `G2EX`, gets no answer and records the timeout, as before.
- `enter_rom` then asserts RTS, that is NRST. That is a fresh ROM, which takes the `0x7F` sync, so **NRST is enough**.
- What NRST does not stop is the 4005 itself. On an unfed case it resets the MCU every ~20.5 s, and that can cut the cleanup's ~2 s ROM session. The ROM part of the cleanup (record read, SRAM clear) is therefore retried once from a fresh NRST (`case_rom_cleanup_retry` in the events). A retry does not read the record again if the first attempt already checked it, because the cut may have come after the first attempt had zeroed it.
- With the new relay the case was fed at most about 2.4 s before the host's NRST (2.0 s gap, the bridge's 25 ms, the host's 0.3 s), so the cleanup has more than 15 s.

**Tool changes.**

- `--case-profile` defaults to `observed-33-feed` for every W18 command, so for both sides. `bootloader-plan` and `bootloader-install` check its pin.
- `recover --max-session-s` defaulted to 600 s with a feeding relay (12 s with `observed-33`; 0 = one session). Superseded by [the temple's watchdog](#the-temples-watchdog-the-npm1300): 0 when the temple is fed too, 20 s without. `--resume-at` is unchanged.
- `link-soak` still defaults to one session.

**Remaining risk.**

- **Not on hardware yet.** Emulation runs our reading of the STM32G0B1 (RM0444: `RCC_APBENR1` TIM6EN = bit 4, TIM6 at `0x40001000`, GPIOB at `0x50000400`) and of the 4005 (any falling edge feeds). If TIM6 did not count, the relay would feed only at its start and stall about 20 s in, like the old one. That is no worse than today, and F1c below shows it within 20 s.
- **Pulse width.** The datasheet gives no minimum and says any falling edge feeds. Ours (4.5 ms) is longer than the app's (~1.5–2 ms at 64 MHz) and far longer than the app's ACMD bit pulses (23 and 90 delay-loop turns, start 350). It is the same kind of signal the app sends every 5 s.
- **Per-exchange stall.** The probe does not rule out hypothesis 1 (a rare hang in stock HAL code with interrupts masked). If it exists, F1c stops at a random exchange, and the 4005 resets the case about 20 s after the last feed (record phase 1). `recover`'s default 600 s parts and `--resume-at` bound the cost of that.
- **The unfed ROM time.** The ROM part before Go (case hash and relay load, ~7 s) and after `G2RS` is unfed. A session therefore has to start within ~18 s of the last feed. Back-to-back sessions start ~10 s apart. After a longer pause the case app runs and feeds.

### The temple's watchdog: the nPM1300

**Measured on hardware (2026-11-07, left temple, case watchdog fed; reported by the Mac thread).** With the case fed, a held temple now rebooted instead: the patched loader's `HELO` came back in the middle of the session. The relay's reset gives the temple a fresh boot 0.5–0.9 s after the relay starts.

| Run | Reboot after the relay started |
| --- | --- |
| idle (empty `G2TX`s) | 31.4 s |
| continuous `dump` traffic | 30.33 s, at exchange 1,571 |

Until then `recover --max-session-s 20` was the fallback: about 280 sessions, about 2.5 h. The analysis below was done on t3-worker from the pinned images, drdaeman's sources, Ambiq's HAL headers, Zephyr's nPM1300 drivers and Renode. Nothing in it touched hardware. Tags: [C] checked (code, disassembly, or emulation as stated), [I] inferred, [D] datasheet or vendor source.

**Verdict: the nPM1300 PMIC's watchdog, armed by the stock app. The temple's Apollo510 watchdog is not running.** The feed is now part of the tool: the RAM programs kick the PMIC's watchdog the way the stock app does, so a session can last as long as it needs.

#### Which watchdog

**The MCU [C value, D decoding].** Step E read `CHIPPN` = `0x10331220` (`MCUCTRL` `0x40020000`). The field layout is `apollo510.h`'s:

| Field | Bits | Value | Meaning |
| --- | --- | --- | --- |
| PN | 31:24 | `0x10` | Apollo5 family (Apollo510) |
| MRAMSIZE | 23:20 | 3 | 4 MB MRAM |
| SRAMSIZE | 19:16 | 3 | ITCM 256 KB, DTCM 512 KB, SSRAM 3 MB |
| REVMAJ/REVMIN | 15:8 | 1 / 2 | deprecated here; `CHIPREV` is the revision register |
| PKG | 7:6 | 0 | SiP |
| PINS | 5:3 | 4 | (the BGA-225 code) |

A SiP Apollo510 with 4 MB MRAM: the Apollo510B (Apollo510 with the EM9305 radio in the package), as [hardware.md](hardware.md) has it from openCFW.

**Not the Apollo510's own watchdog (WDT, `0x40024000`).**

- The patched bootloader never touches it [C]. Neither the stock 2.3.2.14 bootloader nor drdaeman's `patch.bin` holds a literal in `0x40024000`–`0x40024FFF` or builds one with `movw`/`movt`. In Renode its `CFG` reads 0 throughout a held session.
- The stock app's watchdog does not survive the relay's reset [D]. The app has one (`driver\wdt\watchdog.c`; WDT literals at `0x570DCC` in 2.4.0.24 [C]; about 30 s per [hardware.md](hardware.md)). But every Apollo510 reset resets the WDT: an external reset, AIRCR, a debugger reset, a WDT reset and a brown-out are all SWPOR level, "a reset of all blocks except for registers in clock gen, RTC, stimer, PMU" (hal_ambiq `am_hal_reset.h`).
- And the timing does not fit [I]. A watchdog started at the fresh boot with a fixed period would fire at the same time after the boot. With the boot 0.5–0.9 s after the relay start, the streaming run needs a period of 29.4–29.8 s and the idle run one of 30.5–30.9 s. No single period gives both.

**The nPM1300's watchdog [C for the stock app, D for the chip].** The PMIC sits on I2C7 (IOM7, GPIO22/23) at `0x6B` ([hardware.md](hardware.md#npm1300-pmic-battery-case)).

- **Who starts it:** the stock 2.4.0.24 app. It arms the PMIC's timer as a watchdog in reset mode with 30.72 s and kicks it every second from its device manager (strings `[npmx_driver]ERROR:enable npmx watchdog` / `kick npmx watchdog`). Not the patched bootloader [C]: it sets up IOM7 at boot (below) but sends nothing to the PMIC. In Renode, IOM7's `DEVCFG` never holds `0x6B` before our programs run. Not the relay's reset waveform [I]: it only restarts the Apollo510. If it power-cycled the PMIC, the timer would be off and no reboot would come. The ROM/SBL [I]: it has no reason to, and the observed reboot is explained without it.
- **Registers** [D: Nordic nPM1300 product specification; Zephyr `drivers/watchdog/wdt_npm13xx.c`, `drivers/mfd/mfd_npm13xx.c`]. TIMER base `0x07`, 16-bit register addresses sent high byte first:

  | Register | Address | Use |
  | --- | --- | --- |
  | TASKTIMEREN | `0x0700` | start |
  | TASKTIMERDIS | `0x0701` | stop |
  | TIMERTARGETSTROBE | `0x0703` | load the period |
  | **TASKWDOGKICK** | **`0x0704`** | **kick (write 1)** |
  | TIMERCONFIG | `0x0705` | mode (bits 2:0): 0 boot monitor, 1 watchdog warning, **2 watchdog reset**, 3 general purpose; prescaler (bit 3): 16 ms or 2 ms |
  | TIMERHI/MID/LO | `0x0708`–`0x070A` | 24-bit period in prescaler ticks |

  **The stock app's own writes, seen in Renode [C, emulation]** (`temple-wdt-fed`, the tap's PMIC log after the release, in the order the app sends them):

  | Write | Meaning |
  | --- | --- |
  | `07 05 0A` | mode 2 (watchdog reset) with the 2 ms prescaler [D for the bit meaning] |
  | `07 08 00 3C 00` | period `0x003C00` = 15,360 ticks |
  | `07 03 01` | load the period |
  | `07 00 01` | start, 146 ms of virtual time later |

  15,360 × 2 ms = **30.72 s**, as our static analysis had it. The app sends the register address as the first two data bytes, the same format as our kick.

- **Action:** in reset mode the timer's expiry raises the watchdog-warning event, then a full power cycle of the temple ("warn event, then full power cycle", Zephyr). The Apollo510 starts again from its SBL, so the patched loader's `HELO` is the next frame on UART2. That is what came back mid-stream.
- **The timing fits [I].** The app kicks every second, so at the relay's reset (0.5–0.9 s after the relay start) its last kick was 0–1 s earlier. The PMIC therefore fires 30.72 s after that, 30.2–31.6 s after the relay started. Measured: 30.33 s and 31.4 s. A spread of about one second is what a one-second kick interval gives.
- **Why it never showed before:** every earlier session ended sooner, at about 20 s (the case's watchdog) or within 6 s (`loader-hello`, `info-dump`).
- **In a real recovery** the app may be dead and may never have armed the timer. Then there is no limit. A temple with a working app, which covers every session so far and `recover` over a working app, has the limit.

#### How the loader runs our RAM programs [C, drdaeman's `src/bootloader.c` at `1d22097`]

- `boot_task_then_flag` (`0x43511C`) replaces the DFU task's call of `is_need_updata_image` (`0x42E656`). It creates the worker thread `u2-minimal` (priority 47, a 4 KiB stack inside the DFU task's frame) and waits in `while (held) DELAY(1)`. FreeRTOS and its tick (1,024 Hz) keep running for the whole hold.
- The worker receives `LOAD`/`DATA` into `code[512]` on its own stack, cleans the D-cache, invalidates the I-cache and calls `boot_ram_invoke`. That saves the context, calls `entry(api, arg0, arg1)` in the worker's thread context with interrupts as the task has them, and restores it. One program runs at a time, synchronously, from SRAM.
- `api->send` and `api->recv` are stop-and-wait: one loader exchange per 16 bytes, with a 2 s timeout each.
- So the long programs loop on the temple for the whole stream. A 1 MiB `dump` is **one** program call of 65,536 exchanges (about 19 min). `recover`'s body is one call of about 245,000 exchanges (about 72 min).
- Nothing in that path kicks anything. `checksum` is pure computation: about 1.1 s of Renode virtual time for the whole app region; its hardware time is not measured.

#### The design: the programs feed the PMIC's watchdog

Option (a) of the brief, adapted to the watchdog it really is. Writing `0xB2` to the Apollo510's `WDT->RSTRT` would do nothing, because that WDT is off. A "feed" is the I2C write the stock app makes once a second: `07 04 01` to `0x6B` (TASKWDOGKICK = 1).

- **One kick** (`programs/pmic_kick.h`) goes through the bootloader's own IOM7 set-up [C, disassembly and Renode]:
  - `HAL_I2CInit` (`0x430852`, called from board init `0x43053C`) initializes the IOM instances in its I2C table at `0x20000378`. Those are 2, 4, 5 and 7; entry 7 at `0x200003E8` is `{7, handle 0x200181F8, pins 0x4341F0, config 0x20000350}`. GPIO22/23 stay in their I2C function (`PINCFG` = `0x4200`: M7SCL/M7SDA, open drain, pull-up).
  - It then puts each IOM in deep sleep with its registers saved in the handle (`0x4307DE` → `am_hal_iom_power_ctrl(handle, DEEPSLEEP, retain)`).
  - The kick calls that same `am_hal_iom_power_ctrl` (`0x42CCD0`) with WAKE and retain. That powers IOM7 and restores exactly the registers the bootloader configured (`FIFOTHR`, `CLKCFG`, `MI2CCFG`, `SUBMODCTRL`, …).
  - It then runs `am_hal_iom_blocking_transfer`'s sequence for a 3-byte write without an offset: wait for `STATUS` idle, save `INTEN` and set it to 0, `INTCLR`, `DEVCFG` = `0x6B`, `OFFSETHI` = 0, one `FIFOPUSH` (`0x00010407`, low byte first on the wire), `CMD` = `0x301`, then wait for `INTSTAT` `CMDCMP` or an error and for `STATUS` idle, `INTCLR`, restore `INTEN`.
  - Finally it calls power_ctrl with DEEPSLEEP and retain, so on success IOM7 ends powered off with its state saved, as it started.
  - Every wait is bounded (200,000 polls). Any failure returns a code and leaves the watchdog unfed.
  - One failure latches: when the power-down is refused (IOM7 not idle after a busy start or a timeout, `0x200`/`0x400`, or `0x603`), IOM7 stays powered with no saved state. Every later power-up with retain is then refused (`0x107`, as at `0x42CD08`) until the temple resets.
  - The register address goes out as data bytes, low FIFO byte first. That is how Ambiq's HAL sends a byte buffer (`am_hal_iom.c` pushes it as little-endian words) [D], and how g2emu's IOM model, under which the stock app's PMIC driver runs in Renode, decodes it [C, emulation]. Two misreadings were checked. Only the two address bytes swapped would be `0x0407` = 1, TASKBUCK2PWMCLR [D, Zephyr `regulator_npm13xx.c`], which puts BUCK2 in auto mode, its stock setting. All three bytes reversed would be `0x0001` = 4, the MAIN TASKSWRESET register with bit 0 clear [D, `mfd_npm13xx.c`]; task registers trigger on 1, so probably nothing [I]. On hardware, `feed.bin`'s NAK check and the reboot time in F1d show whether the kick lands.
- **When:**
  - `feed.bin` kicks once and returns the status (0 = kicked). The tool runs it right after each session's bootloader CRC check, before every `checksum` and before every idle `G2TX`. A failure stops the session with `temple watchdog feed failed: feed.bin status …` before anything long runs, and before anything is written.
  - `dump_fed.bin` and `recover_fed.bin` are drdaeman's `dump.c` and `recover.c` with `pmic_kick_due()` before every `send`/`recv`, so before every exchange. It kicks when 1,024 ticks (one second, the stock app's rate) have passed since its last kick, and on its first call.
  - They stop when a kick cannot even power IOM7 (the latched state above, a foreign I2C table, or a refused clock). `dump_fed` returns 2; `recover_fed` returns 6 at its next due kick, within about a second (a few more 256-byte blocks may be written and verified first, with the last good kick still at most about 2 s old). The host reports `temple watchdog feed failed during the write/read`, rather than running on unfed until the PMIC cuts the power in the middle of a ROM programming call. They retry any other failure a second later: a NAK, or a write that never completes but leaves IOM7 idle. A NAK that leaves CMDACT set ends in a timeout and a refused power-down, so it latches, and the program stops cleanly. Only `feed.bin` reports every code (`pmic_kick.h`, `PK_DETAIL`). The long programs have to fit in 512 bytes, so for them a failure is either "stop" or "retry".
  - The longest gap without a kick is therefore about one second plus one exchange inside a stream (≤ 3 s even at the loader's 2 s exchange timeout), or one `checksum` between programs. Both are far below 30.72 s.
  - `dump_fed` sends 16 bytes per `send()` call instead of 128. `send()` splits into 16-byte replies anyway, so the frames on the wire are identical to `dump.bin`'s.
- **Footprint.** The calls into the bootloader:
  - `am_hal_iom_power_ctrl` `0x42CCD1`;
  - `xTaskGetTickCount` `0x4160E9` (drdaeman's `platform.h`);
  - and, in `recover_fed` only, the stock MRAM routine `0x42E83D` that `recover.bin` already calls.

  The reads: the I2C table entry (8 bytes). Between the two power_ctrl calls, IOM7 only (writes `INTEN`, `INTCLR`, `DEVCFG`, `OFFSETHI`, `FIFOPUSH`, `CMD`; reads `STATUS`, `FIFOPTR`, `INTSTAT`, `INTEN`). One PMIC register, a task register. Nothing else: no other peripheral, no other PMIC register, no MRAM beyond what `recover.bin` already writes. The period and the reset action are untouched.
- **Why not (b), a one-shot program that lengthens the period.** It writes PMIC configuration that outlives the session. If the host vanishes, the temple then stays held in the loader for the whole longer period instead of 30 s. And it still needs everything above for one I2C write. With (a), a host that stops answering stops the kicks with it: the loader's next exchange times out, the program returns, and the PMIC resets the temple about 30 s later, exactly as without the feed. The bootloader's recovery from a hung temple stays as it was.
- **Why the bootloader's HAL rather than raw registers.** The IOM7 clock, I2C timing and pins are what Even's bootloader set up for this bus, restored by its own function. Nothing is re-derived, and IOM7's power state is put back. It is the same kind of pinned binding as `recover.bin`'s MRAM routine: valid only for the 2.3.2.14-based patched bootloader, whose CRC every session checks before any of these programs runs. `feed` also checks the I2C table entry.
- **(c) without temple code:** none found. The case cannot reach the PMIC, and the bootloader in MRAM stays as installed. The host-side split remains the fallback (`--no-temple-feed`).

#### Pins and build

| Program | Size | SHA-256 | Source |
| --- | --- | --- | --- |
| `feed.bin` | 232 B | `bd72c6b14fee4fbeee890d14a9a8e9ccd33a5b8cb071b0f9b1aa00ea7a7409d9` | `programs/feed.c` + `pmic_kick.h` (ours, MIT) |
| `dump_fed.bin` | 280 B | `7ac581fd2028ff167ca0461ea9c844dc3dfd2842cabdfcc1637a332a28aafbc5` | `programs/dump_fed.c`: drdaeman's `dump.c` + the kick |
| `recover_fed.bin` | 508 B | `8f5cefb93786f676b8d5c8131b3c6999775dc36bd59b9a4990f2b40678d6f610` | `programs/recover_fed.c`: drdaeman's `recover.c` + the kick |

`apps/wisp-recovery/wisp_w18/programs/build.sh` builds them with drdaeman's compiler and flags: clang 21.1.8 from the nixpkgs revision his `flake.lock` pins (`c59305ba…`). Each is linked at 0 and at `0x1000`, and the two must be identical (position independent). `build.sh --verify` rebuilds and compares with `data/`. `build.sh --check-upstream <his checkout>` rebuilds his `checksum.c`, `dump.c` and `recover.c` with the same script: they match the pinned `checksum.bin`, `dump.bin` and `recover.bin` byte for byte [C]. `recover_fed.bin` is 4 bytes under the loader's 512-byte limit. The pins are in `pins.PROGRAMS`; the bootloader addresses they use are in `pins.py` next to them.

#### Verified in emulation [C, emulation]

- **The binaries under Unicorn** (`tests/temple_cpu.py`, `tests/test_temple_watchdog.py`). The real `.bin` files run with the bootloader functions and the loader's `send`/`recv` as stubs (18 RTOS ticks, 17.5 ms, per exchange), IOM7 and the PMIC as a model, and every access outside the program's own code, stack and `ram_api` recorded:
  - `feed` sends exactly `07 04 01` to `0x6B`. It calls power_ctrl `(0x200181F8, WAKE, retain)` and then `(…, DEEPSLEEP, retain)`. Its writes are exactly `INTEN`=0, `INTCLR`, `DEVCFG`, `OFFSETHI`, `FIFOPUSH`, `CMD`, `INTCLR`, `INTEN` restored, and the only other reads are the table entry.
  - Its failure codes: NAK `0x50010`, refused wake `0x107` (no transfer), refused sleep `0x603` (the one path that leaves IOM7 powered), no FIFO room `0x300`, busy `0x200`, foreign table `0x10` (no call at all).
  - The power_ctrl stub keeps the HAL's saved-state flag. After a refused power-down, `recover_fed` stops with 6 at its next kick, about a second later. A busy IOM7 is refused the power-down as in the bootloader (`0x42CE38`), so it latches too, and `dump_fed` stops with 2. A write that never completes but leaves IOM7 idle (`0x400`) is retried, not latched. With another bootloader's I2C table, the stream stops before its first frame and nothing is called. With a refused power-up from the start, `dump_fed` returns 2 and `recover_fed` returns 6, before any frame or write. Under constant NAKs that leave IOM7 idle, `dump_fed` completes, retrying each second.
  - `dump_fed` sends the same frames as `dump.bin` over 64 KiB and kicks first, then every 1,024–1,042 ticks.
  - `recover_fed` writes the same MRAM in the same MRAM-routine calls and sends the same progress reports as `recover.bin`, with the same kick spacing. Its API check, argument check and early end of input behave as `recover.c`'s.
  - drdaeman's binaries never touch IOM7 or the tick.
- **The tool against a fake temple with the PMIC watchdog** (`fake_temple.FakePmicWatchdog`: armed at every relay reset with the app's last kick 0.5 s earlier, 30.72 s, a power cycle answers the next exchange with a `HELO`). Through the relay model on one virtual clock (17.5 ms per exchange):
  - `link-soak --no-temple-feed`, 1 MiB, one session: the temple reboots **30.22 s after the relay started** (hardware: 30.33 s), reported as `temple_reset_since_relay_start_s`.
  - Default `link-soak`, 1 MiB: **one session of about 19 min**, CRC matches, no reboot, never more than 2 s without a kick.
  - `--idle-s 60`: survives with the feed; without it, it ends in a `HELO` during the pause.
  - Default `recover` (64 KiB synthetic image, 77 s): one session, no reboot.
  - `--no-temple-feed`: splits at 20 s (the new default), every session ≤ 20 s, no reboot.
  - `--no-temple-feed --max-session-s 0`: rebooted mid-write, vectors not written; a fed rerun completes.
  - A PMIC that NAKs every kick: `recover` stops with `temple watchdog feed failed … 0x50010` before anything is written.
  - IOM7 latching in the middle of a fed write: `recover` stops with `temple watchdog feed failed during the write`, before the PMIC fires.
- **Renode, against the real patched bootloader** (`wisp-fw:w18-test`, cases `temple-wdt-unfed`, `temple-wdt-fed`, `recover-fed`; model `renode/models/WispPmicWdt.cs` on IOM7). Renode runs an exchange in about 12 µs of virtual time, not 17.5 ms, so the model's period is scaled to 2.5 s of virtual time. The programs' one-second kick interval is real RTOS ticks. The model is armed at power-on, as the stock app leaves it. When it fires, the harness cuts power (`rstgen PowerCut`). A reset requested from inside the model, while a lockstep host was attached, left the emulation stalled after the host detached.

  The shared work for `temple-wdt-*`: three CRCs of the 3.7 MB app region and a 1 MiB dump. Results on 2026-11-07 (t3-worker, Renode 1.16.1, the final binaries):

  | Case | Result |
  | --- | --- |
  | `temple-wdt-unfed` (drdaeman's programs, the same work) | the PMIC model fires mid-session; the loader's `HELO` comes back as the answer to a `RUN` (the hardware's signature), the host stops with `temple rebooted mid-session`, no kick was ever written, and after the reboot the stock app boots |
  | `temple-wdt-fed` (the same work, fed) | 5 kicks in the session (4 by `feed.bin`, 1 by `dump_fed.bin`) and no other PMIC write; no power cycle; CRCs and dump correct; RLSD, the stock app boots |
  | `recover-fed` (a dead temple, `recover` in one session with `recover_fed.bin`, under the armed watchdog) | 3,700,080 B written and verified (CRC `1c340963`), 11 kicks and no other PMIC write in the session (4 by `feed.bin`), no power cycle, bootloader unchanged, the stock app boots |
  | `hello` (rerun with the tap on IOM7) | unchanged: passes |

  So the kick path works against the real bootloader's IOM HAL: power_ctrl accepts the handle, restores IOM7, the transfer completes, and IOM7 goes back to sleep, every time. Between kicks the session keeps running. The power-up/power-down is repeated more than ten times in one session without a failure.

#### Tool changes

- Every case command feeds the temple by default; `--no-temple-feed` runs drdaeman's programs only, as before.
- `recover --max-session-s` defaults to **0 (one session)** when both watchdogs are fed, **20** with `--no-temple-feed`, and 12 with the `observed-33` relay. The split path, its CRC resume and `--resume-at` are unchanged.
- Reports carry `temple_feed`, each session's `feeds` (runs of `feed.bin`), and on a mid-session reboot `temple_reset_since_relay_start_s`.
- `loader-hello` and `info-dump` also feed. That is one PMIC task write per program, the same write the stock app makes every second. MRAM stays read-only.

#### Remaining risks

- **Not on hardware yet.** Emulation runs our reading of the bootloader's IOM HAL and of the nPM1300's register map. If a kick does not reach the PMIC, one of two things happens:
  - `feed.bin` says so at the start of the session (NAK, timeout or a HAL status), and the tool stops before anything long runs;
  - or the temple reboots about 30 s in, exactly as today.

  Either shows within a minute of F1d, and neither writes anything.
- **The bus after the relay's reset.** If the reset hit the stock app in the middle of an I2C transfer, the PMIC could hold SDA low. `feed.bin` then fails (`0x50…` or `0x400`) and the session stops before anything long. There is no I2C bus-clear in the program. Rerunning resets the temple again.
- **A failure in the middle of a long program** (found by the second review). A latched IOM7 stops `dump_fed`/`recover_fed` cleanly (2/6). Failures that do not latch are retried each second without a limit: NAKs that leave IOM7 idle, or a missing FIFO room or completion. `recover_fed` is 508 of 512 bytes, so there is no room for a cap such as "stop after 20 s without a good kick". If such failures never clear, the PMIC resets the temple about 30 s after the last good kick, in the middle of the write, as without the feed. `feed.bin` at the start of the session (and of each part) catches a PMIC that does not answer at all. With the default one-session `recover` that costs the whole run (the old vectors stay; the next run starts over). `--max-session-s 600` bounds it to one part, and each part starts with a `feed.bin` that reports the code.
- **Calls into the bootloader** at pinned addresses (power_ctrl, the tick). They are valid for the patched 2.3.2.14 bootloader only, which each session's CRC check proves first. Their stack use adds to the worker's 4 KiB about as much as the loader's own `send` path does [I].
- **The stock app's parameters** (reset mode, 30.72 s, 1 s kicks) come from our static analysis of 2.4.0.24 [C]. If an app armed a much shorter period, the one-second kick would still cover anything above about 3 s.
- **What a kick cannot fix:** a program that hangs inside the loader without calling `send`/`recv` (a fault in our code) stops the kicks. The PMIC then resets the temple, which is the intended fail-safe.

### Step by step for Jan (Mac, left temple first)

Setup, once: on the Mac, in the repo, `git pull`, `pnpm nx run wisp-ota:build`, then `node packages/wisp-ota/dist/cli.js fetch 2.3.2.14` and `… fetch 2.4.0.24` (both SHA-256 checked into `.wisp-cache/stock/`). `uv` provides pyserial and bleak per command. Find the left temple's BLE identifier with the Even app closed, for example `uv run --with bleak==0.22.3 python -c "import asyncio, bleak; [print(d.address, d.name) for d in asyncio.run(bleak.BleakScanner.discover(10))]"`: its name ends `_L_xxxxxx` (on macOS the identifier is a UUID).

**A. Plan (touches nothing).**
`python3 -I apps/wisp-recovery/w18.py bootloader-plan --side left`
Success: it prints the image hash `87e2d4e0…`, 38 pages, the window, and the token `W18-LEFT-87e2d4e0a7a6`. Any `ImageError`: stop; the cache is not the pinned bundle.

**B. Step 0 again, the same day** (proves the case link and the app version; the install refuses without it):
`uv run --with pyserial==3.5 python -I apps/wisp-recovery/step0.py --side left`
Success: `OK: left temple firmware 2.4.0.24, hardware 5 …`. Stop on anything else (README step 0, safe stops).

**C. The install: Jan's go for this flash is the `--go` token.** Both temples out of the case (they are one pair), folded, flat on the table; battery ≥ 80 % read in the Even app; then force-quit the Even app and Lotti, phone Bluetooth off.
`uv run --with bleak==0.22.3 python -I apps/wisp-recovery/w18.py bootloader-install --side left --address <LEFT-ID> --battery <N> --go W18-LEFT-87e2d4e0a7a6`
Success: `38` lines `…/155648 bytes staged`, `END status 8: the app is copying…`, and a report under `apps/wisp-recovery/runs/`. After 5 s the tool opens a **new** BLE connection and authenticates as a liveness check: `main app still answers after the copy`, or a `NOTE: the liveness check got no answer`. That note alone is not a failure (on the same connection this check timed out on 2026-11-06 although the app was fine): END 8 was accepted, so leave the temple for a minute and go to D. Don't touch the temple during the ~1 s after `END status 8`.
Stops and what they mean:

- `REFUSED …`: nothing was sent. Fix the named precondition.
- Any error **before** `END status 8` (timeout, block rejected, disconnect): MRAM untouched. Check that the temple still works in the Even app. A retry is a new go.
- `END answered 7` or anything but 8: the app rejected the staged file; MRAM untouched.
- **If the install stops after END** (`END was accepted…`): the copy ran or is running. **Do not resend, do not reset or case the temple.** Leave it on the table for a minute so the app finishes, then go to D, which proves what is in MRAM. If D finds a wrong CRC, do not reset the temple again: while the app keeps running, a second install (a new go) can rewrite the bootloader over BLE. Once it resets with a wrong bootloader, only SWD helps.

**D. Prove the loader.** Put the left temple in the case (seated, lid open), case on USB.
`uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py loader-hello --side left`
The case resets the temple; the loader sends `HELO`; the tool claims it, reads the bootloader CRC twice, reads the flag, releases.
Success: `OK: patched loader answers on the left temple; bootloader CRC-32 63cd8dda twice; update flag 0xffffffff`, `relay_exit_status 6` (the normal end), the case back on 1.2.57, and the temple boots normally (Even app connects). Then add a hardware-log row in safety.md.
Stops:

- `relay failed to arm`, `relay did not arm` or a timeout reading the boot beacon: no `HELO`. The bootloader may have kept stock behaviour (drdaeman's loader silently falls back if the stock UART2 state is not as expected; W20 found that state to be the bootloader's own, rebuilt at every boot, [hardware.md](hardware.md#the-loaders-uart2-precondition)), or the temple isn't seated. The temple boots normally either way. Reseat and rerun once; then stop and report.
- `bootloader region CRC … (pinned image 63cd8dda)` mismatch: the MRAM copy is not the pinned image. **Do not reset or case the temple again.** Take it out of the case and see C, "If the install stops after END".
- `case relay status 1/2`: a pogo or seating problem. The temple stays held in the bootloader until the next reset; rerunning `loader-hello` resets it.
- `relay refused to start (status 3): the case's pogo switch was not idle`: nothing was sent and nothing written. The tool retries once after letting the case app run 5 s; if it stops anyway, wait a minute with the case on USB and rerun.

**E. Read-only INFO dump.** `… w18.py info-dump --side left`. Success: JSON with MCUCTRL, PWRCTRL, INFO0, and INFOC/DCU, or `skipped` for each domain that is powered off. Paste it into the hardware log. If the temple hangs in the loader (a read faulted; no reply), rerun `loader-hello`: the reset clears it.

**F. Prove recovery** (W17's proof). Two watchdogs stopped long relay sessions:

- the case's YHM4005, about 20 s after the relay started. The default relay feeds it ([The relay feeds the case watchdog](#the-relay-feeds-the-case-watchdog)).
- the temple's nPM1300, about 30 s after it. The tool now feeds it ([The temple's watchdog](#the-temples-watchdog-the-npm1300)).

F1 (2026-11-06), F1a and F1b (2026-11-07) ran with the old relay, and the case-only probe confirmed the YHM4005; they are in the [hardware log](safety.md). The runs of 2026-11-07 with the new relay rebooted the temple 30.33 s (streaming) and 31.4 s (idle) after the relay started.

Every step needs the temple seated, the lid open, the case on USB, and the Mac on its charger with `caffeinate`. `git pull` first. Every command below then:

- loads the relay `observed-33-feed` (`4c7475fa…`) by default, and the `bridge_loaded` line in its output names that hash;
- feeds the temple's watchdog, so the report says `"temple_feed": true` and each session's `feeds` is at least 1.

**F1d. One long session, read-only (about 20 min).**

1. `… w18.py loader-hello --side left` (a few seconds). Its first `feed.bin` run is the first time the kick meets the PMIC. A `temple watchdog feed failed: feed.bin status …` here means stop and send the report.
2. `… w18.py link-soak --side left`

The soak streams 1 MiB of the app region out with `dump_fed`, in **one** relay session of about 65,600 exchanges at 17.5 ms, and checks it against the temple's CRC. Nothing is written to MRAM. The only writes are the PMIC watchdog kicks, once a second, the same write the stock app makes. Before the temple feed, such a session was rebooted about 30 s in.
Success: `OK: 1048576 bytes streamed and matched the temple's CRC (…) in about 1150 s, … exchanges, about 17.5 ms each, 1 session(s)`, `relay_exit_status 6`, the case back on 1.2.57, and the temple boots normally. Add a hardware-log row.
Stops (nothing is written to MRAM either way; rerun `loader-hello` once afterwards):

- **`temple watchdog feed failed: feed.bin status 0x…`**: the kick does not reach the PMIC. The code says where (`pmic_kick.h`):
  - `0x1nn`: IOM7 power-up refused (HAL status nn);
  - `0x5nnnn`: I2C error (`INTSTAT` bits; `0x10` = NAK);
  - `0x400`: the write did not finish;
  - `0x10`: not the pinned bootloader's I2C table.

  Do not run F2 with the feed. Send the report. F2 can still run with `--no-temple-feed`.
- **`temple rebooted mid-session` with `temple_reset_since_relay_start_s` ≈ 30–32**: the kick reports success but does not reach the watchdog. Same fallback.
- **About 20 s in** (`stall.since_relay_start_s` ≈ 19–22, no `HELO`): the case's watchdog again. Send the report.
- **Later, at a random point:** something else stops the relay (case hypothesis 1, a rare hang in stock case code). Send the report. F2 can still run in resumable parts (`--max-session-s 600`).

**F2. Write** (only after F1d passed). About 72 min in one session.
`… w18.py recover --side left --image .wisp-cache/stock/g2-2.4.0.24.bin`

- **Default: one session**, with both watchdogs fed. That is 245,707 exchanges (231,253 `INPUT_DATA` plus 14,454 progress reports) at 17.5 ms each, plus about a minute of checks. A stop leaves the old vectors but nothing to resume from, because the body is CRC-checked only at the end. The next run starts over.
- **Resumable parts:** add `--max-session-s 600`.
  - The first session writes a 4 KiB part to measure the rate.
  - About eight sessions then write ~500 KiB each.
  - A last session writes the vectors, after a CRC of the whole body.
  - That makes about 10 sessions and about 75 min. Each adds about 15 s for the ROM entry, the case hash, the relay load and the cleanup. A stop costs at most one part.
- **Fallback without the temple feed:** `--no-temple-feed`. The default is then 20 s sessions: about 280 sessions, about 2.5 h. With `--case-profile observed-33` (the old relay) it is 12 s sessions: about 3–3.5 h.

Success:

- `app region CRC-32 before …`, then the first progress line after 256 body bytes, within seconds;
- with parts: one `session k: body …/3700064 bytes written and CRC-checked` line per session, each later session after a `resume check: … bytes already in MRAM match the image` line;
- in the last session, the vectors and `OK: stock 2.4.0.24 main app written and verified (<crc>) in N session(s)`;
- boot released, then the temple boots, and the Even app and Lotti work.

Stops:

- Any stop leaves **zero vectors** (since the rung-4 tooling, [rung4.md](rung4.md) R4-1): they are zeroed before the first body byte and written for real only in the last session, after a CRC of the whole body. The bootloader then does not hand off to the half-written image, so the temple stays in the loader and its boot window until the write completes. That holds for stock over stock too: a stopped `recover` now leaves a temple that does not boot until it is resumed (F2 ran before this change and left the old vectors). In a real recovery the app is dead either way, and the loader runs before it.
- The stop prints `N body bytes are written and CRC-verified; the vectors are not written` and the exact command to continue (`--resume-at N`). It CRC-checks those bytes first and refuses on any mismatch.
- `temple rebooted mid-session`: a reset or power cut; continue with the printed command.
- A `resume check failed` refusal, or any other stop: do not rerun. Send the report as it is.

**Then the right temple:** only after A–F passed on the left, with its own go: the same steps with `--side right`.

## Open questions

- Jan's case firmware version (1.2.57 expected) and the temples' hardware version (drdaeman tested hardware 5).
- Whether the bootloader in MRAM is the 2.4.0.24 one. It can't be read before the install ([W18 procedure](#what-gets-installed)); the install replaces it entirely.
- INFOC / INFO0 / DCU contents: is SWD open, is SBL wired recovery provisioned, is secure boot off? Step 3 answers this.
- Why long case relay sessions stalled: answered, the case's YHM4005 watchdog ([Long relay sessions](#long-relay-sessions-the-cases-yhm4005-watchdog)). The relay's feed works on hardware: on 2026-11-07, sessions ran past 30 s, until the temple's own watchdog rebooted the temple. Open: is there also a rarer per-exchange stall? F1d's 20-minute session shows it.
- Why a held temple rebooted about 30 s after the relay started once the case was fed: answered, the nPM1300's watchdog that the stock app arms ([The temple's watchdog](#the-temples-watchdog-the-npm1300)). Open: does the programs' kick reach the PMIC on hardware? F1d decides.
- Why a brief banner boot seems not to feed the case watchdog when a relay start does, though both run the case's `MX_GPIO_Init` ([The relay feeds the case watchdog](#the-relay-feeds-the-case-watchdog)). It does not affect the fix.
- How long a full `recover` takes on hardware: about 72–75 min at the measured 17.5 ms per exchange ([timing](#timing-on-hardware-estimates-i)), not 40 s: every 16 bytes costs one request/reply with a 6-tick delay in the loader. Whether the temple stays seated that long.
- How long the stock app's bootloader copy really takes (its log line `Write file to MRAM success, time = %d ms`; estimated about 1 s).
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
