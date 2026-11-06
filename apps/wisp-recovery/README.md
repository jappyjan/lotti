# wisp-recovery: recovery step 0 through the charging case

Step 0 of [docs/wisp/recovery.md](../../docs/wisp/recovery.md#recommendation): prove the link **USB → case RAM bridge → pogo UART2 → temple** on Jan's case with one read-only version query to the running left temple. **Nothing writes flash, option bytes or MRAM**, on the case or on the temple.

```sh
python3 -I apps/wisp-recovery/step0.py --plan                         # what it sends; touches nothing
uv run --with pyserial==3.5 python -I apps/wisp-recovery/step0.py --side left
uv run --with pyserial==3.5 python -I apps/wisp-recovery/step0.py --restore   # reset the case into its own app
pnpm nx run wisp-recovery:test                                       # no hardware
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
