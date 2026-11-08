# Wisp — case-UART status protocol

What a native Wisp temple answers on the charging-case link, and how a host asks. This is the observation channel of rung 4 when BLE does not come up ([rung4.md §2](rung4.md#2-which-image-goes-on-first), gap G10). Firmware side: `apps/wisp-fw/src/case/` (codec `wisp_case_proto.c`, host-tested). Reference host side: `apps/wisp-fw/tests/boot/case_uart.py` (pure Python, no I/O), which the Renode harnesses use; its `WispStatus` class plugs into `boot-watch`'s `StatusProtocol` hook in `apps/wisp-recovery` (PR #73). Both are checked against the same golden vectors (`tests/case/`).

Status: **emulation only.** Built for `native-0` (W22) and exercised in Renode against the real stock and patched bootloaders (rung 3's observe suite, `w18-test native-0`). On W24 native-0 never answered (rung4.md, "W24 result and analysis"). Since then the protocol also carries the **boot report** (op `04`, below), answered by Wisp Boot itself in a short window after each reset and by the app, and `stage-0` (rung4.md W24b) answers it with its own blocks 3 and 4. Nothing here has run on a temple yet.

## Link

- The temple's **UART2**: GPIO42 TX → case PB9 (USART3 RX), GPIO44 RX ← case PB8 (USART3 TX), **1 000 000 baud, 8N1, no flow control**. The same wires and settings the stock main app and drdaeman's patched loader use ([recovery.md](recovery.md)).
- In the case: through a RAM program in the case's STM32 (drdaeman's relay `observed-33-feed`, or step 0's read-only bridge). The case's own firmware 1.2.57 polls seated temples in its own protocol ([below](#the-case-apps-0x13-poll-not-answered-by-native-0)).
- The app keeps UART2 powered for good (`pm_device_runtime_get` once at start; every other device starts runtime-suspended) and polls the receiver every 2 ms (`CONFIG_WISP_CASE_UART_POLL_MS`) from a low-priority thread. The PL011 FIFO holds 32 bytes and every request is shorter. A gap of more than 20 ms inside a request drops it.
- **The temple never sends anything unasked.** Every frame it sends answers one complete request. (drdaeman's loader sends `HELO` unasked, but that is the bootloader at every boot, before Wisp runs.)

## Frames

The pinned case relay (drdaeman's `case_exchange.c`, enforced again by `apps/wisp-recovery` `wisp_w18/status.py`) fixes the shapes [C, PR #73]:

- **requests** of 9, 25 or 32 bytes in the loader's host framing: `7E 00 01 n  body  c`, `n` = 4, 20 or 27;
- **replies** `5A A5 FF L  payload  s` with `L` = 8, 16, 24 or 27 (13, 21, 29 or 32 bytes in all). Any other temple frame reaches the host as "no frame" (relay status 2).

Checks: `s` = the low byte of the sum of every byte before it (from `5A`). `c` = (the request's length + `0x7D` + the sum of every byte before `c`) & `0xFF`. That is the loader's request check, and stock's own case requests carry it too: `24 00 01 00 A7` and the case app's `13 00 00 01 E4 01 7D` both satisfy it.

**The temple never sends anything unasked.** Every frame it sends answers one complete request. (drdaeman's loader sends `HELO` unasked, but that is the bootloader at every boot, before Wisp runs.)

## Requests

### 1. Wisp requests (through the relay)

```
request:  7E 00 01 n  57 53 50  op  args[n - 4]  c          57 53 50 = "WSP"
reply:    5A A5 FF L  57 53 50  op|80  status  data..  s   zero-padded to L = 8, 16, 24 or 27
```

| status | meaning |
| --- | --- |
| 0 | ok |
| 1 | unknown op |
| 2 | wrong arguments (length, range, block, the reset magic) |
| 3 | not available on this boot (no Wisp Boot status block) |

| op | name | request | data in the reply (status 0) |
| --- | --- | --- | --- |
| `01` | IDENT | 9 bytes, no args | 10 bytes: `major minor patch kind`, `stage u8`, `flags u8`, `battery_mv u16`, `bt_result i16` (the fields as in the [status block](#status-block-version-1)); 21-byte reply |
| `02` | READ | 25 bytes: `block u8`, `offset u16`, `length u8` (1–17), 12 zero bytes | `block u8`, `offset u16`, `total u16`, then min(length, total − offset) bytes; 32-byte reply at most |
| `03` | RESET | 25 bytes: `52 53 45 54` (`"RSET"`), 12 zero bytes | none; ~50 ms after the reply the app resets (`sys_reboot`, cold; stage-0: SWPOR). The patched loader's `HELO` is the next frame on the line, then Wisp Boot and the app boot again |
| `04` | BOOTREP | 9 bytes, no args | 22 bytes: the [boot report](#the-boot-report-op-04) (why the previous boot ended, how far it got); 32-byte reply. Status 1 from an app that predates it (native-0), 3 if the app finds no valid Wisp Boot block |

Blocks: **1** = the app's status (56 bytes, 4 READs), **2** = Wisp Boot's status block (612 bytes in version 1, native-0's Wisp Boot, 36 READs; 692 bytes in version 2, 41 READs), and for stage-0 only **3** = its clock measurements (52 bytes) and **4** = this boot's diagnostics record (64 bytes). An unknown block gets status 2. Little-endian throughout. A relay exchange takes about 17.5 ms, so IDENT plus blocks 1 and 2 is about 0.8 s.

The marker keeps these apart from the loader's requests (`HOLD`, `CONT`, … carry their own four-character marker, and `HOLD` an HMAC). A Wisp request that reaches the loader during its boot window is not one of its commands; a loader request that reaches the app is ignored.

Examples (also the golden vectors of `tests/case/`):

```
IDENT:                      7e 00 01 04 57 53 50 01 04
READ status block @0, 17:   7e 00 01 14 57 53 50 02 01 00 00 11 + 12 x 00 + 37
READ boot block @595, 17:   7e 00 01 14 57 53 50 02 02 53 02 11 + 12 x 00 + 8d
RESET:                      7e 00 01 14 57 53 50 03 52 53 45 54 + 12 x 00 + 64
RESET reply:                5a a5 ff 08 57 53 50 83 00 00 00 00 83
BOOTREP:                    7e 00 01 04 57 53 50 04 07
BOOTREP reply (Wisp Boot, prev-valid kick-ok stimer-xt, boot 3, previous stage 0x18 at 9,100 ms,
               reset cause WDRSTAT):
                            5a a5 ff 1b 57 53 50 84 00 00 0d 03 18 40 00 00 00 8c 23 + 12 x 00 + ae
IDENT reply (0.1.2, kind 0, stage 5, 3,987 mV, bt -5):
                            5a a5 ff 10 57 53 50 81 00 00 01 02 00 05 3b 93 0f fb ff 00 68
```

**boot-watch hook.** `tests/boot/case_uart.py` `WispStatus` has the shape of `status.py`'s `StatusProtocol` (`name`, `request(i)`, `decode(frame)`, `complete(answers)`): IDENT until the app answers, then the two blocks once, then IDENT again; `decode` returns `None` for anything that is not a Wisp reply (the loader's `HELO` is handled by `watch()` itself). `tests/case/test_case_uart.py` runs it against a fake temple. **Registered since W23** as `boot-watch --protocol wisp`: `apps/wisp-recovery/wisp_w18/case_uart.py` is a port of this module (the codec unchanged and cross-checked against it; its `WispStatus` asks a lost READ again, waits for the end of the BLE bring-up, and decodes both blocks for the report).

### The boot report (op `04`)

rung4.md, "W24 result and analysis", D1 and D2. native-0 rebooted every 10.4 s on W24 and said nothing; the boot report is built so that **every boot of a reboot loop says why the previous boot ended and how far it got**, whether or not the app ever runs.

- **The record (D1).** A 64-byte record at `0x20370000`, the first bytes of Wisp Boot's RAM, which no reset handler copies or zeroes (`src/boot/wisp_diag.h`). Wisp Boot reads the previous boot's record first thing, keeps a copy in its status block (`prev`), then starts a fresh one: magic `"WDAG"`, a boot counter, `RSTGEN.STAT` (the Apollo's reset cause, `0x4000885C`), the STIMER at its start, the last breadcrumb (stage code and its time) and, if a fault handler ran, the fault (PC, LR, xPSR, CFSR, HFSR, BFAR, MMFAR, EXC_RETURN), sealed by a CRC-32. Wisp Boot and stage-0 leave breadcrumbs in it (codes in `wisp_diag.h`; names in `case_uart.py` `DIAG_STAGES`); both fault handlers record the fault and then reset (SWPOR). Whether SRAM survives a watchdog reset or an SWPOR on this chip is open; the magic and the CRC tell (flag `prev-valid`).
- **Wisp Boot's window (D2).** Right after it arms the watchdog, kicks the PMIC watchdog and starts the record, Wisp Boot sets up UART2 itself (the patched loader's own values) and answers **only** BOOTREP: IDENT, READ, RESET and stock's version query get no answer from it, so neither the loader's nor the app's protocol sees anything from Wisp Boot. The window stays open about 300 ms with no request, 100 ms after the last answer, and never more than 1 s, timed by the STIMER on the 32 kHz crystal if it is selected and counting (else by a poll count), and capped at 2,000,000 polls whatever the clock says; the watchdog is fed while it is open. Wisp Boot writes GPIO PADKEY `0x73` around its pad writes, as the bootloader does.
- **The app** answers BOOTREP too (stage-0 does; native-0's codec answers status 1), built from Wisp Boot's status block, so a host that misses the window still gets it.
- **The host** (`boot-watch --protocol wisp`): at every boot, from `CONT` or after each loader `HELO`, the boot report on every exchange with no pause (about 17.5 ms apart) until one answers or 200 exchanges passed, then IDENT and the blocks as before. Every boot report of the watch is kept and printed (`boot_reports`).

The 22 data bytes:

| Offset | Type | Field |
| --- | --- | --- |
| 0 | u8 | source: 0 = Wisp Boot's window, 1 = the app |
| 1 | u8 | flags: `01` the previous record was valid, `02` it holds a fault, `04` this boot's PMIC watchdog kick by Wisp Boot succeeded, `08` the STIMER runs from the crystal |
| 2 | u8 | this boot's number, low byte |
| 3 | u8 | the previous boot's last stage (0 if no valid record) |
| 4 | u32 | `RSTGEN.STAT` at the start of this boot: `01` external (the case's reset line), `02` power-on, `08` SWPOR, `10` SWPOI, `40` watchdog, `1000` SYSRESETREQ |
| 8 | u16 | the previous boot's last stage time, ms after its Wisp Boot start (`FFFF` = later, or no crystal) |
| 10 | u32 | the previous boot's fault PC (0 = none) |
| 14 | u32 | ... LR |
| 18 | u32 | ... CFSR |

Reading it after a reboot loop: `prev-valid` with the previous stage `boot-handoff` and cause `40` = the app ran and the watchdog reset it without one breadcrumb from the app; a fault PC = a fault handler ran (stage-0 or Wisp Boot); cause `08` and stage `s0-reset-request` = a case-UART RESET; cause `01` = the case's reset line. No `prev-valid` at all after a warm reset = SRAM did not survive it, and only the cause is known.

### 2. Stock's version query (step 0's bridge only)

The 5 raw bytes `24 00 01 00 A7`, as step 0's read-only bridge sends them. The relay cannot carry this request (wrong shape), so through the relay IDENT replaces it. Reply, in stock's layout (14 bytes):

| Byte | Stock 2.4.0.24 (left temple, step 0) | Wisp |
| --- | --- | --- |
| 0–3 | `5A A5 FF 09` | `5A A5 FF 09` |
| 4 | `24` | `24` |
| 5–7 | `01 03 05` (unexplained) | **`57 53 50` = "WSP"**, the Wisp identity |
| 8–11 | `02 04 00 18` = 2.4.0.24 | `major minor patch kind`: the Wisp version, and the image kind (0 = `native-0`, 255 = a development build) |
| 12 | `05` = hardware revision | `00` (Wisp does not read the board strap yet) |
| 13 | sum | sum |

`wisp_case/bridge.py decode_version` decodes both unchanged; a host tells Wisp from stock by bytes 5–7.

### What the temple ignores

Anything else, silently: bytes before a request, a request with another marker (the loader's `CONT`, …), a bad check byte, a length other than 9, 25 or 32, a request cut by a gap of more than 20 ms, bytes with a framing, parity or overrun error (the app clears the PL011's latched error flags at once, so the next request is heard), and stock's other requests.

Who else sends `24 00 01 00 A7`: step 0's bridge. PR #73's list of the case app's own temple commands (status `0x13`, charging, aging, serial number, reset, its own update) has no version query, so the case app should never see Wisp's identity reply; if W20 finds otherwise, the reasoning of the next section applies to it too.

### The case app's `0x13` poll: not answered by `native-0`

Case 1.2.57 polls each seated temple with `13 00 0s 01 E4 01 c` (s = side) and resets a temple that has not answered with an opcode-`0x13` frame for 180 s [C, PR #73: hardware.md "The case's temple reset"]. **`native-0` does not answer it.** What stock puts in that reply, and what the case does with it, is not known yet: stock's handler sits in `pt_protocol_procsr` and was not extracted, and the case clearly consumes temple state (its log prints the temple's `soc`, `charge`, `lid`, `in_case`). A made-up reply could steer the case's charging and LEDs, which is the kind of guess the rules forbid; an unanswered poll only costs a reset. So, for `native-0`:

- **During a relay session** (install-wisp, boot-watch, `recover`) the case runs our relay, not its app: no polling, no reset.
- **With the case app running** (the temple seated, no relay), a native temple is reset about every 3 minutes (after 8 missed polls, then every 180 s). Harmless: the reset is a pogo waveform, the patched loader runs first, then Wisp Boot and the app again. But it ends every native boot within about 3 minutes.
- **Out of the case** nothing polls. W24 only scans for adverts from the Mac, right after `boot-watch` and inside the 3 minutes ([rung4.md, W24 runbook](rung4.md#w24-runbook-first-native-flash-left)); W25's BLE session from the Mac is done with the temple out of the case (or accepts the resets).

Answering `0x13` like stock is gap **G10b** in [rung4.md](rung4.md#gaps): it needs the reply layout from stock's handler (static analysis, W20 follow-up) and an emulation check against the case's parser.

## Status block, version 1

The app's own block (READ block 1), 56 bytes. `tests/boot/case_uart.py decode_status` is the reference decoder.

| Offset | Type | Field |
| --- | --- | --- |
| 0 | u8 | version = 1 |
| 1 | u8 | stage: 1 main() entered, 2 HAL up, 3 `bt_enable()` running (EM9305 bring-up), 4 BLE up and advertising, 5 BLE unavailable, 6 bare metal (stage-0: no BLE, no HAL) |
| 2 | i16 | `bt_enable()` result; `0x7FFF` = not returned yet |
| 4 | u8 | sensors present (`wisp_hal_sensors_present()`) |
| 5 | u8 | flags: `01` battery fields valid, `02` VBUS present (in the case), `04` charging, `08` PMIC watchdog armed with stock's settings, `10` Wisp Boot's services table found, `20` its status block valid, `40` that Wisp Boot is the observe-only build, `80` a BLE session is up |
| 6 | u16 | battery mV (nPM1300 ADC, one VBAT conversion per request) |
| 8 | u8 | nPM1300 charger status (BCHGCHARGESTATUS, raw) |
| 9 | u8 | nPM1300 VBUS status (VBUSINSTATUS, raw) |
| 10 | u8 | image kind (0 = `native-0`, 16 = `stage-0`, 255 = development) |
| 11 | i8 | the last PMIC watchdog write's result (0 or −errno) |
| 12 | u32 | Apollo510 `RSTGEN.STAT` as the app found it at start (the reset cause; the bootloader and Wisp Boot leave it) |
| 16 | u32 | uptime, ms |
| 20 | u32 | PMIC watchdog kicks since boot |
| 24 | u32 | PMIC write errors since boot |
| 28 | u32 | Apollo watchdog feeds since boot |
| 32 | u32 | BLE sessions (HELLO completed) since boot |
| 36 | u16 | `confirm()` calls through Wisp Boot's services |
| 38 | i16 | the last `confirm()` result; `0x7FFF` = never called |
| 40 | u16 | size of Wisp Boot's status block (0 = none) |
| 42 | u16 | reserved, 0 |
| 44 | char[12] | firmware git revision, NUL-padded |

Rule 6's case-session threshold for a native temple (battery ≥ 3,900 mV, [safety.md](safety.md)) is read from offset 6, or from IDENT. The percentage Wisp shows elsewhere is a coarse voltage estimate and reads high while charging; the threshold is still to be confirmed against stock's 80 % at W21.

## stage-0's blocks 3 and 4

**Block 3, the clock measurements** (version 1, 52 bytes; `case_uart.py decode_clock`). stage-0 times 16 watchdog ticks (1,024 LFRC cycles at Wisp Boot's LFRC/64) edge to edge against the STIMER (the 32 kHz crystal) and SysTick (the core clock), without feeding the watchdog in between, 2 s after it started and every 15 s after that. The watchdog's COUNT may count either way (the header does not say): each change adds the smaller of its two modular distances, and the block records which way it saw it move. The first 100 ms after the feed are skipped, and the PMIC is not kicked during a measurement (at most 3.6 s).

| Offset | Type | Field |
| --- | --- | --- |
| 0 | u8 | version = 1 |
| 1 | u8 | timebase: 1 = the STIMER on the crystal, 2 = SysTick at an assumed 96 MHz (the crystal did not count) |
| 2 | u8 | measurements done (saturating) |
| 3 | u8 | the last one: 0 ok, 1 the watchdog's COUNT never moved, 2 16 ticks took over 3 s, 3 not yet, 4 implausible (LFRC outside 500–2,000 Hz) |
| 4 | u32 | STIMER STCFG as found |
| 8 | u32 | the watchdog's CFG (Wisp Boot's, locked) |
| 12 | u32 | STIMER ticks across 2^22 core cycles at start (0 = the STIMER does not count) |
| 16 | u32 | the last window in STIMER ticks |
| 20 | u32 | the same window in core cycles |
| 24 | u32 | the LFRC in mHz, taking the crystal as 32,768 Hz |
| 28 | u32 | the core clock in Hz, same reference |
| 32 | u32 | the watchdog's reset period at that LFRC, ms (RESVAL x 64 / LFRC) |
| 36 | u32 | the lowest LFRC so far, mHz |
| 40 | u32 | the highest, mHz |
| 44 | u32 | the last PMIC kick's result code (`boot_pmic.h`) |
| 48 | u8 | which way COUNT moved: 1 down, 2 up, 3 both, 0 not seen |
| 49 | u8[3] | reserved, 0 |

In Renode the LFRC is modelled at 900 Hz and the STIMER's crystal at 32,000 Hz (Renode's Apollo4 model), so the block reads about 922 Hz there.

**Block 4** is this boot's diagnostics record as it stands (64 bytes, `wisp_diag.h`; `decode_diag_record`).

## Wisp Boot's status block, versions 1 and 2

READ block 2: 612 bytes (version 1) or 692 (version 2) (the app copies it when a READ at offset 0 arrives and serves the rest of the dump from that copy, so a dump that spans a `confirm()` stays one CRC-correct block) in Wisp Boot's own RAM (`0x20370000–0x20380000`), pointed to by its services table at `0x438200` (version 2: `magic "WBS1"`, `version`, `confirm`, `status`). Layout and every offset: `apps/wisp-fw/src/boot/wisp_boot_status.h` (`_Static_assert`s pin them); decoder `case_uart.py decode_boot_status`. In short:

- magic `"WBST"`, version, size; build flags (`1` observe-only, `2` UART1 log compiled in);
- the NOR's RDID and `nor_init()` result (−11 = not the MX25U25643G Wisp Boot drives), the littlefs mount result (1 = not attempted);
- `wisp/boot.rec` as read, and its read result;
- the staging file `ota/s200_firmware_ota.bin`: present, preamble CRC word, size;
- `wisp/rescue.bin`: its header + full CRC check (`rescue_ok`), CRC word, size;
- the stage reached, the **action taken** and the **action the fallback build would take** with these inputs, and its reason (`wisp_boot.h`);
- the `/firmware` inventory: up to 12 files, each with name (32 bytes), size, zlib CRC-32 of the whole file and a result; a truncation flag and the directory's open result;
- `confirm()` calls and the last result;
- version 2 only: `RSTGEN.STAT` at this boot's start, the PMIC watchdog kick's result, the boot-report window's answers and length, UART2's set-up result, the STIMER's clock select, and the previous boot's diagnostics record (`prev`, with `prev_valid`);
- a zlib CRC-32 over everything before it, resealed at every change. The app reports the block only when magic, size and CRC are right.

On the first native boot (W24) this is the known-answer test of the NOR read path: the left temple's staging file should still hold the pure stock 2.4.0.24 main (CRC word `0x971F4516` [I]), and the inventory should list `codec.bin`, `ble_em9305.bin`, `touch.bin` and `box.bin` with the sizes of the installed bundle.

## Host side: what `boot-watch` does

`boot-watch` (rung4.md G2, `apps/wisp-recovery`, PR #73) keeps the relay running after `CONT`/`RLSD` and asks its pluggable protocol: with `WispStatus`, IDENT about once a second until the app answers (the case-UART thread starts before the BLE bring-up, which blocks the app's main thread for up to 5 s), then both blocks, decoded with `decode_status` and `decode_boot_status` (check the boot block's CRC, compare the inventory with the pinned bundle and the staging CRC word with `0x971F4516`). Optionally RESET, then the loader's `HELO` proves the loader is reachable from a native state. While the relay runs the case app does not, so no `0x13` reset interferes. The temple's PMIC watchdog is kicked by the app itself, so a long watch needs no temple feed.

## Not yet

- The same reset over BLE: the protocol has `SYSTEM REBOOT` (service `0x01`, op 5, [protocol.md](protocol.md)), but the native app answers only the basic session so far. Planned with the update service (W26).
- Reading the board's hardware revision (byte 12 of the version reply).
- The `0x13` reply (G10b, above).
- Authentication: anything on the pogo pins can reset the temple. The pins are reachable only with the temple seated in a case running our RAM program or stock 1.2.57.
