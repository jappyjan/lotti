# Wisp — brick safety policy

The G2 has a single-slot main app, no rollback, and its BLE + OTA live in that app ([hardware.md](hardware.md#boot-and-update-chain-stock)). **An image that crashes before BLE is up turns a temple into an SWD-only repair.** This file is the rulebook. It overrides convenience, deadlines and every other Wisp document.

## Hard rules (no exceptions, enforced in tooling)

1. **Never write** the Ambiq SBL (`0x400000–0x410000`), the Even bootloader (`0x410000–0x438000`), or anything at or past `0x7FE000` except the documented update-flag record ([hardware.md](hardware.md#update-flag-record-0x7fe000-16-bytes): `{0x55555555, ~0, ~0, ~0}` = install, `{~0 ×4}` = clear, written through the boot-ROM helper like stock does). Wisp tooling refuses to build such an image. On the device, Wisp Boot's only MRAM write is the install record (one function, constant address and value); rung 3 checks this from the boot-ROM log in every case.
2. **Never send** component types 1 (bootloader), 3 (touch), 4 (codec), 5 (EM9305) or 6 (case). Wisp bundles are **main-only** (type 0). `wisp-ota` rejects anything else.
3. Main-app image checks, all in `wisp-ota`, all mandatory: load address `0x438000`; preamble size = payload size; app end ≤ `0x7F8000`; SP vector points into SRAM; reset vector inside the image and Thumb; both CRC layers recomputed and re-verified by an independent second implementation.
4. **No flash without an explicit, per-flash "go" from the hardware owner (Jan)** in chat. An earlier "go" never covers a later flash. Agents never flash on their own initiative, never on a schedule.
5. **One temple at a time, left first.** The right temple stays on stock until the left one has passed a full round trip (flash → boots → reflash stock over BLE → boots).
6. Before every flash: battery > 80 %, temples out of the case, nothing on the table that can bump them, only the flashing phone near, Even app force-quit.
7. Keep the exact stock bundle for the installed version (SHA-256 pinned) available offline before the first flash.
8. **Never let firmware reflash a co-processor.** Ambiq's Zephyr EM9305 driver (`am_devices_em9305_init()` in hal_ambiq `am_devices_em9305.c`) erases and reflashes the EM9305's NVM when the device version is older than **or equal to** the bundled `ble_fw_image_em9305.h` (equal = CRC-verify, reflash on mismatch), when the version can't be read, and when the controller fails to boot — unless the caller sets `skip_fw_update`. Even ships its own EM9305 build, so that would wipe or brick the radio. On the fork (`ambiq-stable` 89c8a36) **no caller sets it safely**: the HCI driver `apollox_blue.c` leaves it `false` whenever `CONFIG_BT` is on, and the evb's `board.c` EXTREF init (`CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT`, default y whenever the HCI node is enabled) sets it to `IS_ENABLED(CONFIG_BT)`, i.e. `false` when BT is off. `skip_fw_update` is also only a runtime flag: the 234 KB image and the erase/write code stay linked even when it is set. So Wisp native builds keep BT and the EM9305 driver out until the driver is patched to compile the update, recovery and NVM-trim paths out and every caller forces `skip_fw_update = true`; `apps/wisp-fw` fails the build otherwise (Kconfig gate + post-build check of sources, symbols, map and raw image bytes, see its README). The same applies to the PSoC touch controller and the GX8002 codec: Wisp never contains their firmware images.
9. **Never commit Even's firmware** (copyright). Stock bundles are fetched or copied into a git-ignored local cache (`.wisp-cache/`), pinned by SHA-256; tests use synthetic bundles.
10. Never copy GPL code into Wisp (licensing, not bricking — but it is a rule too). Facts and offsets from GPL projects are fine with credit.
11. **No native flash without a verified rescue image.** Before rung 4 and before every later native install, `wisp/rescue.bin` must be on the temple's NOR, read back over BLE and checked (size, preamble, zlib CRC = the pinned stock main payload of the installed version). Wisp Boot without a valid rescue image cannot fall back.
12. **Every change to Wisp Boot reruns `wisp-fw:boot-test`** (rung 3) before it may be flashed; a native image is only flashed with a Wisp Boot whose build passed it.

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

The Even bootloader installs whatever valid main image is staged in `ota/s200_firmware_ota.bin` when word 0 of the flag is `0x55555555` ([hardware.md](hardware.md#what-the-22610-bootloader-does-step-by-step-rung-3)). Wisp uses that as its parachute:

1. Before the first native flash, the phone stores a pristine stock main image on the NOR littlefs as `wisp/rescue.bin` (written through the stock OTA file path while still on stock, or by Wisp host mode) and **verifies it on the glasses** (size, preamble, CRC) — see rule 11.
2. **Wisp Boot**, a tiny stage at `0x438000` (the image's entry), runs before anything else: it counts boot attempts in a record on the NOR (`wisp/boot.rec`), and if the app failed to confirm 3 boots in a row (or the touchpad rescue hold is seen at boot), it copies `wisp/rescue.bin` to `ota/s200_firmware_ota.bin`, verifies the copy's CRC, writes the flag record and resets. The Even bootloader then installs stock. A rescue interrupted by a power cut resumes on the next boot.
3. The native app confirms a boot only after BLE is advertising and a phone session completed `HELLO`. A watchdog, armed and locked by Wisp Boot, covers hangs.

Wisp Boot is small (16.8 KB: MSPI NOR PIO driver, littlefs, CRC, one flag write, watchdog), changes rarely, and is fault-tested in Renode against the real bootloader before it ever runs on glasses (rung 3, `pnpm nx run wisp-fw:boot-test`, [apps/wisp-fw/README.md](../../apps/wisp-fw/README.md#rung-3-fallback-to-stock-with-the-real-even-bootloader-wisp-fwboot-test)). Everything else in the native image may crash and the temple comes back as stock.

Verified in rung 3 (was "still to verify"): the flag record (only word 0 is read; hardware.md), that the bootloader rereads the staged file after an interrupted install (yes: the flag stays set until the app clears it, and the install restarts from the file), and the littlefs geometry on the NOR.

What fallback-to-stock **cannot** do (terminal states):

- With `rescue.bin` missing or corrupt, Wisp Boot never stages it and never writes the flag; the Wisp app keeps booting (degraded every third boot). Without a working BLE path in that app this is an SWD-only repair. Rule 11 exists for this. (Rung 3 cases `rescue-corrupt`, `rescue-missing`.)
- After 4 rescue attempts that did not end in stock, Wisp Boot stops resetting and runs the app degraded. (Host unit tests only: no rung-3 case makes the real bootloader refuse a verified copy.)
- A crash inside Wisp Boot before it records the attempt loops forever. Not injected in rung 3. Hence: Wisp Boot stays minimal, has no BLE and no interrupts, and every change to it reruns rung 3 (rule 12).

### Rung 3 status (2026-11-06)

Emulation only (t3-worker, Renode), stock **2.2.6.10** bootloader running unmodified, Wisp Boot `8dd8fd69ef4b…`: **26/26 runs end in their expected state** (table in [apps/wisp-fw/README.md](../../apps/wisp-fw/README.md#rung-3-fallback-to-stock-with-the-real-even-bootloader-wisp-fwboot-test)). Every injected app fault (hang, fault in the reset handler, crash after 300 ms, watchdog never fed, erased app slot, corrupt boot record) and every power cut along the rescue path (before the copy, at 2/25/50/75/98 % of it, after it committed, before and right after the flag write, inside and right after the bootloader's own install) ends with stock running from `0x438000`, installed by the Even bootloader. A corrupt or missing `rescue.bin` ends in the documented safe state instead (no flag, Wisp keeps booting). In every run the bootloader region is unchanged and Wisp's only MRAM write is the flag record.

**Not called passed yet.** Open before Jan signs rung 3 off: review of the terminal states and rules 11–12; the same suite on the bootloader version actually installed on the temples (only 2.2.6.10 was run); the real native app (Zephyr) behind Wisp Boot instead of bare-metal fault apps. Model limits that stay (README "What Renode lacks"): NOR/MRAM operations are atomic (no cut inside a page program or erase), no core lockup, no SBL, SRAM pessimistically lost on every reset.

## Hardware log

| Date | Temple | Rung | Image (SHA-256, short) | Result              |
| ---- | ------ | ---- | ---------------------- | ------------------- |
| —    | —      | —    | —                      | nothing flashed yet |
