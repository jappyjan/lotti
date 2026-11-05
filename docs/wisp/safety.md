# Wisp — brick safety policy

The G2 has a single-slot main app, no rollback, and its BLE + OTA live in that app ([hardware.md](hardware.md#boot-and-update-chain-stock)). **An image that crashes before BLE is up turns a temple into an SWD-only repair.** This file is the rulebook. It overrides convenience, deadlines and every other Wisp document.

## Hard rules (no exceptions, enforced in tooling)

1. **Never write** the Ambiq SBL (`0x400000–0x410000`), the Even bootloader (`0x410000–0x438000`), or anything at or past `0x7FE000` except the documented update-flag value. Wisp tooling refuses to build such an image.
2. **Never send** component types 1 (bootloader), 3 (touch), 4 (codec), 5 (EM9305) or 6 (case). Wisp bundles are **main-only** (type 0). `wisp-ota` rejects anything else.
3. Main-app image checks, all in `wisp-ota`, all mandatory: load address `0x438000`; preamble size = payload size; app end ≤ `0x7F8000`; SP vector points into SRAM; reset vector inside the image and Thumb; both CRC layers recomputed and re-verified by an independent second implementation.
4. **No flash without an explicit, per-flash "go" from the hardware owner (Jan)** in chat. An earlier "go" never covers a later flash. Agents never flash on their own initiative, never on a schedule.
5. **One temple at a time, left first.** The right temple stays on stock until the left one has passed a full round trip (flash → boots → reflash stock over BLE → boots).
6. Before every flash: battery > 80 %, temples out of the case, nothing on the table that can bump them, only the flashing phone near, Even app force-quit.
7. Keep the exact stock bundle for the installed version (SHA-256 pinned) available offline before the first flash.
8. **Never let firmware reflash a co-processor.** Ambiq's Zephyr EM9305 driver erases and reflashes the EM9305's NVM when its version looks older than the bundled image, and when it fails to boot (`am_devices_em9305.c`). Even ships its own EM9305 build, so that would wipe or brick the radio. Wisp native builds set `skip_fw_update`, and a build check fails if the EM9305 image or the update path is linked in. The same applies to the PSoC touch controller and the GX8002 codec: Wisp never contains their firmware images.
9. **Never commit Even's firmware** (copyright). Stock bundles are fetched or copied into a git-ignored local cache (`.wisp-cache/`), pinned by SHA-256; tests use synthetic bundles.
10. Never copy GPL code into Wisp (licensing, not bricking — but it is a rule too). Facts and offsets from GPL projects are fine with credit.

## The ladder

Each rung must pass before the next one may start. A rung is "passed" when its exit check is green on real hardware and written into the hardware log at the end of this file.

| Rung | What gets flashed                                                                                                         | Brick risk                                                                            | Exit check                                                                                   | Precondition                                                                                    |
| ---- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 0    | Nothing. Offline tooling, simulator, Renode                                                                               | none                                                                                  | `wisp-ota verify` passes on the stock bundle; Renode boots the stock app                     | —                                                                                               |
| 1    | **Stock, repacked by `wisp-ota`** (only the version string changes, CRCs recomputed) to the left temple                   | very low (the stock OTA path is proven)                                               | boots, advertises, Even app works; reflash pure stock works                                  | rung 0                                                                                          |
| 2    | **Host mode:** stock + appended Wisp core, _disarmed at boot_; armed only by a phone lease (90 s, renewed)                | low: the boot path is stock; Wisp code runs only after BLE is up and only while armed | 10 cold boots OK; Wisp session works; lease expiry fully restores stock; reflash stock works | rung 1                                                                                          |
| 3    | **Wisp Boot dry-run in Renode** with the real Even bootloader and a littlefs image: fallback-to-stock proven in emulation | none                                                                                  | 100 % of injected boot faults end in a stock install                                         | rung 0                                                                                          |
| 4    | **Native Wisp** (Wisp Boot + native app) on the left temple                                                               | **high** for the first flash                                                          | as rung 2, plus fallback-to-stock exercised on hardware by a forced fault                    | rung 3 **and** SWD access proven on a temple (pads found, read-only attach and INFO0 dump done) |

Rung 4 stays closed until SWD works. That is the price of not bricking; there is no clever way around it for the first native flash.

## Fallback-to-stock (designed into native mode)

The Even bootloader installs whatever valid main image is staged in `ota/s200_firmware_ota.bin` when the flag is `0x55555555` ([hardware.md](hardware.md#boot-and-update-chain-stock)). Wisp uses that as its parachute:

1. Before the first native flash, the phone stores a pristine stock main image on the NOR littlefs as `wisp/rescue.bin` (written through the stock OTA file path while still on stock, or by Wisp host mode).
2. **Wisp Boot**, a tiny stage at `0x438000` (the image's entry), runs before anything else: it increments a boot-attempt counter in a retained record, and if the app failed to confirm 3 boots in a row (or the touchpad rescue hold is seen at boot), it copies `wisp/rescue.bin` to `ota/s200_firmware_ota.bin`, verifies its CRC, writes the flag and resets. The Even bootloader then installs stock.
3. The native app confirms a boot only after BLE is advertising and a phone session completed `HELLO`. A watchdog covers hangs.

Wisp Boot is small (MSPI NOR, littlefs read, CRC, one MRAM word write, watchdog), changes rarely, and is fault-tested in Renode against the real bootloader before it ever runs on glasses (rung 3). Everything else in the native image may crash and the temple comes back as stock.

Still to verify (rung 3 work): the exact 16-byte flag record, whether the bootloader rereads the staged file after an interrupted install, littlefs geometry on the NOR.

## Hardware log

| Date | Temple | Rung | Image (SHA-256, short) | Result              |
| ---- | ------ | ---- | ---------------------- | ------------------- |
| —    | —      | —    | —                      | nothing flashed yet |
