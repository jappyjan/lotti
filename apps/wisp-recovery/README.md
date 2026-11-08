# wisp-recovery: recovery through the charging case (step 0 and W18)

Two tools. `step0.py` (below) is the read-only case link test, passed on 2026-11-06. `w18.py` prepares and runs decision W18: the one install of drdaeman's patched bootloader per temple, then its UART2 loader through the case ([W18 tools](#w18-patched-bootloader-and-case-loader); the runbook is [recovery.md, W18 procedure](../../docs/wisp/recovery.md#w18-procedure)).

Step 0 of [docs/wisp/recovery.md](../../docs/wisp/recovery.md#recommendation): prove the link **USB → case RAM bridge → pogo UART2 → temple** on Jan's case with one read-only version query to the running left temple. **Nothing writes flash, option bytes or MRAM**, on the case or on the temple.

```sh
python3 -I apps/wisp-recovery/step0.py --plan                         # what it sends; touches nothing
uv run --with pyserial==3.5 python -I apps/wisp-recovery/step0.py --side left
uv run --with pyserial==3.5 python -I apps/wisp-recovery/step0.py --restore   # reset the case into its own app
pnpm nx run wisp-recovery:test                                       # no hardware
uv run --with pyserial==3.5 python -I apps/wisp-recovery/step0.py --probe-reset  # diagnostic, see below
```

## Why not drdaeman's relay as-is

drdaeman/g2-bootloader-patch (MIT, `1d22097`) loads its relay into case SRAM through the **STM32 ROM loader** (CH340 DTR = boot select, RTS = reset), never through the case firmware's own update path. But its relay (`src/case/case_reset_loader.c`) always **resets the temple** with Even's reset waveform (372 bytes copied out of the case firmware) and then waits for the patched bootloader's `HELO`. A stock temple never sends `HELO`, and a temple reset is not a read-only request, so that program is out for step 0.

Its relay is an extension of a smaller program: the **read-only pogo bridge** from evenRealities-webflasher (MIT, `2fcdb88`), 1,720 bytes, SHA-256 `e30e143d…`. Unmodified, that bridge asks a **running** temple for its version or status and does nothing else. The webflasher validated it on hardware on both temples. Step 0 uses that bridge unmodified, loaded the same way.

## What gets sent (`--plan` prints this)

| #   | To                  | What                                                                                                                                                             | Class                                  |
| --- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 1   | case                | RTS reset, DTR asserted → case app; listen for `****** B200 1.2.57` at 1 Mbaud. No bytes sent.                                                                   | case MCU reset; read-only              |
| 2   | case ROM            | RTS reset, DTR released → STM32 ROM loader; `0x7F` sync, Get `0x00`, Get ID `0x02` (require protocol `0x31`, product `0x467`, the reviewed command table)        | case MCU reset; read-only              |
| 3   | case ROM            | Read Memory `0x11` of `0x08000000` + 55,752 B; SHA-256 must be `773b6d4c…` (B200 1.2.57). Hashed in RAM, never stored.                                           | read-only                              |
| 4   | case ROM            | Write Memory `0x31` into SRAM only: zeros to `0x20011B00` (8 B) and `0x20011A00` (160 B), the pinned bridge to `0x20010000`; each block read back                | RAM-only                               |
| 5   | case ROM            | Go `0x21` to `0x20010000`                                                                                                                                        | RAM-only                               |
| 6   | bridge              | `G2RQ` op 2 (version), route left: `47 32 52 51 01 02 00 42 00 61`                                                                                               | RAM-only                               |
| 6a  | case YHM2510 (I²C)  | read 10 registers; **stop with status 3, zero writes, nothing sent** unless they match one of 5 seated-idle profiles                                             | read-only                              |
| 6b  | case YHM2510, GPIO  | select the route: regs 5, 6, 3 (left) or 4 (right), 7; PA3 high                                                                                                  | volatile register writes, undone in 6e |
| 6c  | **left temple**     | `24 00 01 00 a7`, the stock version query, embedded in the bridge image                                                                                          | **read-only query**                    |
| 6d  | case USART3         | capture the temple's `5A A5 FF` reply (~1 s)                                                                                                                     | read-only                              |
| 6e  | case YHM2510, GPIO  | write regs 7, 6, 5, 3, 4 back from the baseline, PA3 low, re-read all 10                                                                                         | volatile register writes (restore)     |
| 6f  | bridge → host, case | `G2RS` reply; record + proof into SRAM; `SYSRESETREQ`                                                                                                            | case MCU reset                         |
| 7   | case ROM            | RTS reset into the ROM; Get, Get ID; read the bridge record and proof; check every YHM register was restored; write zeros over all three SRAM regions, read back | case MCU reset; RAM-only               |
| 8   | case                | RTS reset, DTR asserted → case app; require the `B200 1.2.57` banner again                                                                                       | case MCU reset; read-only              |

The temple receives exactly 5 bytes. No temple reset, no OTA (`0x52`–`0x55`), no bootloader traffic. Note: requests _to_ the temple are not `5A A5 FF`-framed in stock; the temple's _reply_ is (`5A A5 FF 09 24 … v0 v1 v2 v3 hw sum`).

### Enforced in code (`tests/test_allowlist.py`)

- ROM commands: only Get, Get ID, Read Memory, Write Memory, Go. Erase (`0x43/0x44`), write-protect (`0x63/0x73`) and readout-protect (`0x82/0x92`) raise before a byte is sent.
- Write Memory: only inside the three SRAM regions, and only the pinned bridge's own bytes at that offset or zeros. Flash (`0x08…`), option bytes (`0x1FFF7800`) and any other SRAM are refused.
- Go: only to `0x20010000`, only after the whole bridge was written and read back.
- Bridge operations: only version (op 2 → temple opcode `0x24`), checked against the bytes inside the pinned image. Status (op 1, whose request carries bytes we can't explain), the exit self-test and anything else are refused.
- The bridge only runs if the case flash hashes to the exact 1.2.57 image, because it calls nine functions inside it by address. Our reachability scan from those nine (capstone, 70 functions) finds no flash programming: the only flash-controller access is `FLASH_ACR` (wait states, offset 0); no `KEYR`, `CR` or option-byte registers. Nine indirect calls in the I²C driver were not followed [I].

## Hardware setup (Jan)

1. MacBook Air, case on a **USB-C data cable**. Check `ls /dev/cu.*`: exactly one `cu.usbserial-*` or `cu.wchusbserial*` (CH340) should appear.
2. Glasses folded and **both temples seated**, the way the Even app shows them as in the case; lid open. Case flat on the table where it won't be bumped.
3. Even app and Lotti force-quit; phone Bluetooth off.
4. Run the step-0 command above. It takes about 15 s. Run it once.

**Success** ends with a line like `OK: left temple firmware 2.4.0.24, hardware 5; raw 5aa5ff0924…; case 1.2.57 restored`, plus a JSON report under `apps/wisp-recovery/runs/` (git-ignored; it contains the case serial from the banner).

**Safe stops** (no harm done, the case is put back):

- `bridge status 3`: the case's pogo switch isn't in a known idle state (for example still negotiating charging). Nothing was written, nothing sent. Wait a few minutes, rerun.
- `bridge status 6`: the route was selected, the query went out, the temple didn't answer; every register was restored. Check seating and lid, rerun.
- `case reports …, expected 1.2.57` or `case flash is not the pinned … image`: stops before anything is loaded.
- ROM sync fails: macOS's built-in CH34x driver may not do even parity; the WCH driver does.

**Undo**: the tool resets the case into its own application at the end, also after an error. The bridge lives only in case SRAM (and is zeroed anyway); a reset ends it. By hand: `step0.py --restore`. The case has a battery, so unplugging USB alone does not restart it; if a run was cut off mid-way, plug back in and run `--restore`.

## `--probe-reset` (diagnostic)

Does only step 1: opens the port at 1 Mbaud with DTR asserted (app boot) and RTS asserted (reset held), releases RTS after 50 ms, and listens for 6 s. It sends no bytes and never enters the ROM loader. It reports every line change and every received chunk with timestamps, and whether a **fresh boot** appeared: the `****** B200 x.y.z <serial>******` banner plus `Power up...`, which the case prints only at start-up. Its periodic `****** B200 vol:…` status lines don't count. Exit 0 = fresh boot on 1.2.57, 2 = no fresh boot, 3 = another version. Step 0's own first listen keeps the same full capture in its report.

First hardware run (2026-11-06, Apple's built-in CH34x driver): step 0 saw only status lines and stopped before the ROM loader. `--probe-reset` exists to tell "RTS doesn't reset the case on this driver" apart from "the banner was missed".

## The "observed-33" bridge variant

The bridge only selects a pogo route if the 10 YHM2510 registers it reads first equal one of five rows baked into its image (offset 1660). Register 8 is, per the webflasher (`src/lib/yhmProfiles.js`), a per-case identity byte that stays constant through charging and resets; cases ship `0x22`, `0x33` or `0x45`. The reviewed bridge carries `0x22`. Jan's case reads `811104afaf03812033ff` (register 8 = `0x33`), so the reviewed bridge stops with status 3 there, with zero writes.

The "observed-33" variant is the reviewed bridge with the bytes at 1670, 1680, 1690 and 1700 changed from `0x22` to `0x33` (rows 2–5; row 1 unchanged), exactly as the webflasher's `getVerifiedPogoBridgePayload()` derives it. `pins.bridge_image()` derives it from the vendored file and requires SHA-256 `3ca8ed1d8d37b2edef62dcb6915b5ec4b1d439160da0a89e93aa74901d760ef6`, the webflasher's `POGO_BRIDGE_OBSERVED_33_SHA256`.

Step 0 always starts with the reviewed bridge. It switches to observed-33 once, and only when the reviewed bridge's retained record proves a zero-write, zero-transmission stop (status 3) and the baseline it read is exactly a row of the observed-33 table. Any other baseline (another register-8 value, any other byte different, the webflasher's separate row-1 `0x8d/0x33` variant) stops. Everything else, including the SRAM write allowlist, applies to the variant unchanged: writes must carry the bytes of the variant actually being loaded.

## W18: patched bootloader and case loader

```sh
python3 -I apps/wisp-recovery/w18.py bootloader-plan --side left            # touches nothing
uv run --with bleak==0.22.3 python -I apps/wisp-recovery/w18.py bootloader-install --side left \
    --address <BLE id> --battery <N> --go W18-LEFT-87e2d4e0a7a6                # the one bootloader write
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py loader-hello --side left   # read-only
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py info-dump --side left      # read-only
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py link-soak --side left   # read-only, 1 MiB, one session
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py recover --side left \
    --image .wisp-cache/stock/g2-2.4.0.24.bin                                  # stock main app, 600 s parts
    # after a stop: the same command plus the printed --resume-at N (CRC-checked first)
    # --max-session-s 0: one session; --case-profile observed-33: the old relay (keep sessions <= 12 s)
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py install-wisp --side left \
    --image <native.bin> --elf <zephyr.elf> --map <zephyr.map> --expect <sha256 prefix> --battery <N | NmV>
    # rung 4 (docs/wisp/rung4.md, G1): REFUSES every image until W23 pins one; see "install-wisp" below
# rung 4's reads (rung4.md §4, W21/W24; "Rung-4 reads" below):
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py held-reset-test --side left  # read-only, 2 sessions
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py peek --side left             # read-only
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py pmic-read --side left        # first run: Jan's go
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py app-check --side left        # read-only
uv run --with pyserial==3.5 python -I apps/wisp-recovery/w18.py boot-watch --side left       # CONT, then listen
pnpm nx run wisp-recovery:test     # fakes, no hardware
pnpm nx run wisp-fw:w18-test       # the real patched bootloader in Renode
```

Needs `.wisp-cache/stock/g2-2.3.2.14.bin` and `g2-2.4.0.24.bin` (`wisp-ota fetch`, SHA-256 checked). Every image is rebuilt from those and must match `wisp_w18/pins.py`: patched bootloader `87e2d4e0…` (155,648 B), stock 2.4.0.24 main `df8cfddf…`, case relay `4c7475fa…` (observed-33-feed, the default: observed-33 plus our YHM4005 feed, 5,808 B), `6beb9a5e…` (observed-33) or `7749131e…` (reviewed-22).

| Module                    | What it does                                                                                                                                                                                                                                                       |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `wisp_w18/pins.py`        | every hash, the writable regions, the `--go` token                                                                                                                                                                                                                 |
| `wisp_w18/image.py`       | EVENOTA parsing; the patched bootloader (drdaeman's `patch.py`, in Python); the OTA component header; the case relay rebuilt from the template plus Even's reset waveform out of the cached case firmware                                                          |
| `wisp_w18/relay_feed.py`  | our YHM4005 feed for the case relay: the six relay sites it re-points (each checked for drdaeman's bytes) and the pinned code it appends at `0x20011584` (`data/case_relay_feed.S`, assembled to `case_relay_feed.bin`)                                         |
| `wisp_w18/ble.py`         | the stock BLE OTA install (drdaeman's `ble_ota.py`): only type 1, only the pinned image, no replay, END must be 8                                                                                                                                                  |
| `wisp_w18/loader.py`      | HELO/HOLD/OKAY/CONT/RLSD and LOAD/DATA/RUN (drdaeman's `handshake.py`, `protocol.py`)                                                                                                                                                                              |
| `wisp_w18/links.py`       | `CaseRelayLink` (case ROM → relay in case SRAM → temple; step 0's ROM allowlist, widened to the relay's own bytes), `RelayPortLink` (the same relay framing on a model) and `SocketLink` (Renode); the last 16 exchanges of each session; the relay record decoder |
| `wisp_w18/relay_model.py` | emulation and tests only: drdaeman's relay loop (`case_exchange.c`) and the bridge's G2RQ/G2RS wrapper in Python, behind a pyserial-like port, with case-stall faults (on a frame, after N seconds of a virtual clock, after N exchanges) and the case's YHM4005 (`watchdog_s`, `feeds_watchdog`) |
| `wisp_w18/session.py`     | claim/release, CRC, dump, `info_dump`, the idle pause, and `AppWriter`/`write_app`, the only write path: an `AppImage` (the pinned stock main, or a pinned Wisp image) with its end bound; vectors zeroed → body in parts, each session CRC-checking the body so far first → whole-body CRC → vectors → CRC |
| `wisp_w18/status.py`      | `boot-watch`'s status hook: the `StatusProtocol` interface, the relay's framing rules every protocol must fit, the built-in `listen`, and `watch()`; the Wisp case-UART protocol is G10's (apps/wisp-fw) and registers itself in `PROTOCOLS` |
| `wisp_w18/native.py`      | `install-wisp`'s gate: the Wisp pin table, the ELF and map pins, the build gates, the Wisp Boot allowlist, the battery; rule 3 ported from wisp-ota's `checkMainPayload` (cross-checked by shared vectors), and the ELF-against-image check |
| `wisp_w18/data/`          | drdaeman's compiled MIT programs, pinned: `patch.bin`, `checksum.bin`, `dump.bin`, `recover.bin`, and `case_relay_template.bin` (his `case.bin` with Even's 372 waveform bytes zeroed); our `case_relay_feed.S` and its pinned build `case_relay_feed.bin`; our temple programs `feed.bin`, `dump_fed.bin`, `recover_fed.bin`, `pmic_read.bin` |
| `wisp_w18/programs/`      | the sources of `feed.bin`, `dump_fed.bin`, `recover_fed.bin` (they kick the temple's nPM1300 watchdog, `pmic_kick.h`) and `pmic_read.bin` (one kick, then 58 nPM1300 registers read), and `build.sh`, which builds them with drdaeman's pinned toolchain (`--verify` compares with `data/`) |

**Write order (rung4.md R4-1, both `recover` and `install-wisp`).** Before the first body byte, the 16 vector bytes at `0x438000` are zeroed (and read back), unless they already read zero. Then the body, its CRC, the real vectors, the final CRC. A write cut at any point leaves zero vectors, so the bootloader does not hand off to a half-written image; the patched loader still runs first, and the same command with the printed `--resume-at N` (or a fresh run) completes it. A resumed run finds the vectors zero and does not write them again. Reports carry `vectors_zeroed`.

**`install-wisp` (rung 4, G1).** Writes a Wisp native image (Wisp Boot's 64 KiB slot + the app, linked at `0x438000`) through the same writer. It refuses every image today: Jan approved R4-1 on 2026-11-08, so `pins.R4_1_APPROVED` is `True`, but `pins.WISP_IMAGES` and `pins.WISP_BOOT_PASSED` stay empty until W23, a reviewed commit that pins a built `native-0` (a test keeps both empty). With a pinned image, before it touches the case it checks: the image, ELF and map SHA-256 against the pin; `--expect` (12+ hex digits of the image hash, the image Jan's go names); the build gates the pin records (`check_rule8`, `no-mram-write`); that the first 64 KiB are a Wisp Boot listed in `pins.WISP_BOOT_PASSED` with both rung-3 suites (`stock-2.4.0.24`, `patched-87e2d4e0`); that every ELF segment placed in MRAM equals the image there; rule 3 on the image with wisp-ota's strict SP bound (`0x20380000`), in both implementations: the Python port and wisp-ota's own `checkMainPayload`, run by Node from wisp-ota's build (`pnpm nx run wisp-ota:build` first; without it the command refuses); and `--battery` (≥ 80 %, or ≥ 3,900 mV written as `3900mV`). The end bound of every write is the image's own end. In each session it runs the `loader-hello` gate before any write (the bootloader CRC twice and a clear update flag; there is no `--allow-pending-flag`), and the writer reruns rule 3 on the exact bytes it is about to send. The writer has its own gate too: `AppImage` refuses any image that is not the stock pin or, with R4-1 approved, listed in `WISP_IMAGES`, whoever calls it. The report has the image facts, the rule-3 results of both implementations, the gate's reads, the battery and the CRCs. The two implementations are also cross-checked offline: both test suites run the same vectors (`packages/wisp-ota/src/testing/main-payload-vectors.json`, made by `tests/rule3_vectors.py`) and must flag the same guards.

**Between sessions (the status-3 fix).** On hardware the second session of a split run was refused: two case app restarts within about 2 s left the pogo switch (YHM2510) not idle, and the bridge answered `G2RQ` with a 13-byte `G2RS`, status 3, zero writes. The tool now recognises that answer at once (`PogoNotIdle`: "pogo switch not idle; zero writes"), checks the case record as a zero-write record (`route_untouched`) instead of calling it a failed route restore, and retries the session once. Every session after the first, and every retry, first lets the case app run 5 s after its banner (`cli.SETTLE_S`; the console listen records when its `B200 vol:` status lines came, `case_settle`). Reports count `pogo_not_idle`.

A failed session's report keeps the error that stopped it (`error`), where (`stopped_in`, `position`), what the cleanup ran into afterwards (`cleanup_errors`), and the link's last frames and exchange count (`link`), with `link.relay_started_t` and `stall.since_relay_start_s` (when the relay started, and how long after it the first exchange failed). Every report lists its sessions (`relay_seconds`, `exchanges`). Long relay sessions stalled on hardware because the case's YHM4005 watchdog reset the case about 20 s after the relay started; the default relay feeds it ([recovery.md, Long relay sessions](../../docs/wisp/recovery.md#long-relay-sessions-the-cases-yhm4005-watchdog)). Then the temple's nPM1300 watchdog, armed by the stock app, power-cycled a held temple about 30 s after the relay started; by default every session feeds it (`feed.bin`, `dump_fed.bin`, `recover_fed.bin`; [recovery.md, The temple's watchdog](../../docs/wisp/recovery.md#the-temples-watchdog-the-npm1300)), and reports carry `temple_feed`, each session's `feeds` and, after a mid-session reboot, `temple_reset_since_relay_start_s`. `recover` (default: one session with both feeds, 20 s parts with `--no-temple-feed`, 12 s with observed-33) and `link-soak` (`--max-session-s`) can still split their work into sessions that end within a budget, each resumed by CRC. For the case, the events include the decoded relay record ([recovery.md, Step F on hardware](../../docs/wisp/recovery.md#step-f-on-hardware-the-stall-of-2026-11-06)).

Tests: `tests/test_relay.py` runs sessions through the relay framing: on `relay_model.RelayModel`, and on drdaeman's real relay binary under Unicorn (`tests/fake_case.py`) behind the unmodified `CaseRelayLink`, including a case that stops mid-stream. `tests/test_session_guard.py` covers the split sessions, the resume check, the vectors-last rule and the idle pause on a virtual clock (a case that stops after 20 s or after N exchanges), and the real relay's answer to an empty `G2TX`. `tests/test_install_wisp.py` covers `install-wisp`: the refusal with the repository's empty pin table, a synthetic pinned image written through the relay model (vectors zeroed first and last, rule 3 rerun on the sent bytes before the first write), every refusal before the case is touched, a set flag, and a stop and resume. `tests/test_pogo_settle.py` reproduces the status-3 refusal with the real relay binary under Unicorn (a fake case whose pogo switch is busy after two quick app restarts) and checks the settle and the retry. `tests/test_case_watchdog.py` checks the feed patch and runs both relays under Unicorn with emulated time and a YHM4005 on PB2: the old relay is reset 20 s after it starts; the feeding one survives a long idle, a 64 KiB `link-soak` and a two-minute `recover` in one session (about 2 min of wall time for that file).

What the case receives is step 0's sequence with the 5,808-byte relay (drdaeman's 5,508 bytes plus our feed) in place of the 1,720-byte bridge (the relay embeds that bridge). The relay pulses PB2 for the case's watchdog every 2 s, resets the selected temple with Even's waveform, forwards its `HELO`, then relays one temple frame per `G2TX`. `G2EX` ends it: the bridge restores the YHM route and resets the case. The tool reads the retained record back through the ROM, zeroes the SRAM and resets the case into 1.2.57. Case flash is never written.

## Rung-4 reads (G2, G3, G25)

Built for rung 4's pre-qualification and first flash ([rung4.md §4 and §7](../../docs/wisp/rung4.md#4-pre-qualification-without-writing-mram), [recovery.md, Rung-4 reads](../../docs/wisp/recovery.md#rung-4-reads-peek-pmic_read-app-check-boot-watch-and-the-held-temple-reset)), in emulation only. Nothing in them writes MRAM. **`pmic_read.bin` is a new program on the PMIC bus: its first run on hardware needs Jan's own go**, as will every new temple program after it.

| Command | What it does |
| --- | --- |
| `loader-hello --no-release` | `loader-hello`, then ends the session without `CONT`: the temple stays held in its loader (an error still releases) |
| `held-reset-test` | W21's held-temple reset test in one command: session 1 holds the temple, session 2 must reset it and get its `HELO` less than 25.72 s after session 1's last PMIC kick (else `INCONCLUSIVE`). A missing `HELO` is rung4.md's first stop |
| `peek [--what …]` | reads only `pins.PEEK_REGIONS` (the patched bootloader's NOR ops record, board strap record, UART2 table entry, power callbacks; the flag record; the NOR ops records) and decodes them |
| `pmic-read [--compare REPORT]` | runs `pmic_read.bin`: one watchdog kick, then one I2C write-read per register of `pins.PMIC_READ_REGISTERS` (58, baked into the pinned image). `--compare` diffs against an earlier report and exits 3 on a config difference (timer and status registers listed apart) |
| `app-check [--image F …]` | bootloader CRC twice, the flag and its meaning, the vectors, and the app region's CRC over each known image: the pinned stock main (`pins.STOCK_MAIN_CRC32`), Wisp pins with a `crc32`, the files given. Exit 3 when nothing matches or the flag is undocumented |
| `boot-watch [--protocol P] [--watch-s T]` | releases the boot, then asks the booting app P's questions through the relay for T s before `G2EX`; the loader's `HELO` among the answers is a reboot. Only `listen` (send nothing, record what comes) is registered; the Wisp protocol is G10's. Requests must be frames the pinned relay forwards (9/25/32 bytes, `7E 00 01 n-5`) and answers 13/21/29/32-byte `5A A5 FF` frames: the stock `24 00 01 00 a7` query cannot go through it |

Tests: `tests/test_pmic_read.py` (the real `pmic_read.bin` under Unicorn: the kick, the 58 reads in order and nothing else, the failure codes; the CLI and `--compare` on the fake temple), `tests/test_rung4_reads.py` (`peek`, `app-check`, `--no-release`, `held-reset-test` including a held temple that does not come back and a second session that came too late, `boot-watch` with `tests/fake_status.py`'s fake protocol and booting app), and the Renode case `rung4-reads` in `wisp-fw:w18-test` (`peek` and `pmic_read` against the real patched bootloader).
