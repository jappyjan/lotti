# wisp-ota

EVENOTA inspector, packer and verifier for Wisp (Even Realities G2). Every image that goes to real glasses passes through this package; it is the main brick-prevention layer (decision W14, [safety.md](../../docs/wisp/safety.md)).

- **Library** (`@wisp/ota`): TypeScript, zero runtime dependencies, `Uint8Array`/plain integers only. Runs in Node, browsers and React Native, so the phone app can install Wisp over stock with the same code.
- **CLI** (`wisp-ota`): a thin Node wrapper.
- **No BLE code.** Nothing in this package opens a radio. The stock OTA sender (`src/transfer/`) is a transport-agnostic state machine: the caller hands it a connected `StockLink`.

## Usage

```sh
pnpm nx run wisp-ota:build
alias wisp-ota="node packages/wisp-ota/dist/cli.js"

wisp-ota catalog                                  # pinned official releases
wisp-ota fetch 2.2.6.10                           # → .wisp-cache/stock/g2-2.2.6.10.bin (+ .json with SHA-256)
wisp-ota import ~/Downloads/some-bundle.bin       # same, from a file you already have
wisp-ota inspect .wisp-cache/stock/g2-2.2.6.10.bin
wisp-ota verify  .wisp-cache/stock/g2-2.2.6.10.bin [--json]
wisp-ota repack-main .wisp-cache/stock/g2-2.2.6.10.bin --version 2.2.6.19 -o .wisp-cache/out/rung1.bin
wisp-ota diff .wisp-cache/stock/g2-2.2.6.10.bin .wisp-cache/out/rung1.bin
wisp-ota pack-main app.bin --version 0.1.0.1 -o wisp.bin
```

| Command       | What it does                                                                                                                                                                                                                                       |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `inspect`     | Header, TOC, every component (type, storage type, path, offset, size, CRC-32C ok/bad), main-app preamble, vector table (SP, reset), install range and headroom, verdict.                                                                           |
| `verify`      | Runs every guard. `--json` prints the machine-readable report (`VerifyReport`, the same object the SDK gets from `verifyBundle`). Exit code **0** sendable, **2** valid but not sendable (a stock bundle: it carries types 1, 3–6), **1** invalid. |
| `repack-main` | Rung 1 image: the stock main payload with only its version string changed, both CRC layers recomputed, as a main-only bundle. Refuses unless the structural diff against stock is clean.                                                           |
| `diff`        | Structural diff of a stock bundle and its repack: lists every changed byte range and fails on anything that is not a version string or a CRC field.                                                                                                |
| `pack-main`   | Wraps a raw app image (linked at `0x438000`, vector table first) in the 32-byte preamble and a main-only bundle. For later Wisp images. `--version` is required.                                                                                   |
| `fetch`       | Downloads an official bundle from Even's CDN into the git-ignored `.wisp-cache/`, checks size, SHA-256 and the main-app end against the pinned catalog, and records the SHA-256 next to it. Nothing is cached on a mismatch.                       |
| `import`      | Caches a bundle you already have. A known version must match its pinned SHA-256; an unknown one is cached but marked "unverified origin".                                                                                                          |

Every command parses its options strictly: an unknown option is an error (exit 64). There is no option that disables, skips or relaxes a guard, and none will be added.

### Library

```ts
import { verifyBundle, packMain, repackMain, parseBundle } from '@wisp/ota';

const report = verifyBundle(bytes); // never throws; report.ok / report.sendable / report.guards
if (!report.sendable) throw new Error(report.failed.join(', '));
```

`packMain` and `repackMain` throw (`GuardError`, `PackError`) instead of returning anything unsafe. Both re-parse their own output from scratch and run every guard on it before returning.

## Guards

All guards are always evaluated, on everything `verify` sees and on everything the packer produces. Rules refer to the hard rules in [safety.md](../../docs/wisp/safety.md).

| Guard               | Check                                                                                                                                                            | safety.md rule                         |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `container`         | Stock EVENOTA layout: magic, TOC, `evenota\0` trailer, contiguous components closing exactly at EOF, `EVEN` component magic, reserved words, clean ASCII strings | 3 (image checks)                       |
| `bundle-size`       | Bundle ≤ 16 MiB                                                                                                                                                  | 1, 3 (output size sane)                |
| `component-crc`     | Every component: TOC CRC-32C = header CRC-32C = computed, by the table **and** the bitwise implementation                                                        | 3 (CRC layer 1, second implementation) |
| `main-only`         | Exactly one component, type 0. Types 1 (bootloader), 2 (font), 3 (touch), 4 (codec), 5 (EM9305), 6 (case) are never sendable                                     | 2                                      |
| `main-present`      | Exactly one type-0 component                                                                                                                                     | 2, 3                                   |
| `main-target`       | Main goes to the stock staging file `ota/s200_firmware_ota.bin`, storage type 3 (littlefs)                                                                       | 1 (only the stock install path)        |
| `preamble-format`   | Preamble flags `0x04`, data type `0xCB`, reserved words 0                                                                                                        | 3                                      |
| `load-address`      | Preamble load address = `0x438000`                                                                                                                               | 1, 3                                   |
| `preamble-size`     | Preamble size field = payload size                                                                                                                               | 3                                      |
| `image-size`        | Payload holds the preamble plus a full vector table and fits the 24-bit size field                                                                               | 3 (output size sane)                   |
| `app-end`           | App end ≤ `0x7F8000`, for the actual size and for the declared size (the bootloader trusts the declared one without a bounds check)                              | 3                                      |
| `protected-regions` | Installed range inside `[0x438000, 0x7FE000)`: never the SBL, the Even bootloader, the update flag at `0x7FE000` or anything after it                            | 1                                      |
| `sp-vector`         | Initial SP in SRAM `(0x20000000, 0x20380000]`, 8-byte aligned                                                                                                    | 3                                      |
| `reset-vector`      | Reset vector odd (Thumb), inside the installed image, past the vector table                                                                                      | 3                                      |
| `preamble-crc`      | Preamble zlib CRC-32 over `payload[8:]` matches, by the table **and** the bitwise implementation                                                                 | 3 (CRC layer 2, second implementation) |

On top of the guards, the packer checks that its output has exactly the expected size, and `repack-main` runs the structural diff and refuses unless the only changes are the version string and the CRC fields. Rules 4–8 (go from Jan, one temple at a time, pre-flash checklist, pinned stock offline, no co-processor reflash) are process and firmware rules; `fetch`/`import` cover the tooling side of rule 7, and `main-only` keeps co-processor images out of any bundle (rule 8).

Every guard has at least one failing test in `src/guards.test.ts`, and the pack-side refusals are in `src/pack.test.ts`.

## How `repack-main` changes the version

The version is the header string (`s200_v2.2.6.10` → `s200_v2.2.6.19`) **and** every standalone copy of the version inside the main image: word-aligned, NUL before and after (10 such copies in 2.2.6.10, 7 in 2.0.1.14). Copies that are part of another string (`master:v2.2.6.10-0-g…`, `Launch:2.3.2.14`) or that sit unaligned (inside compressed data) are left alone. The new version must have the same length, so no byte moves; it must also differ from stock, so the version the glasses report tells whether the repack was installed. Build date and time and the main entry id (6, or 5 in the five-component 2.2.0.24 / 2.2.4.34 bundles) are kept. The other stock components are dropped (rule 2).

## Stock OTA sender (rung 1)

`sendStockOta` / `StockOtaTransfer` (`src/transfer/`) send a bundle to **one** temple over the stock OTA import protocol, so a phone app can flash a `repack-main` image (rung 1 in [safety.md](../../docs/wisp/safety.md)) with no cable. It runs `verifyBundle` itself and refuses anything not **sendable** (main-only, every guard green), before touching the link; there is no override. The temple is a required `'left' | 'right'` and must match the link's temple; there is no "both".

```ts
import { sendStockOta } from '@wisp/ota';

const result = await sendStockOta({ temple: 'left', bundle, link, onProgress });
// result.outcome === 'staged': the glasses accepted the image and set the update flag;
// they reset and the Even bootloader installs it. Reconnect and read the version.
```

### Wire protocol

All OTA packets go to the OTA characteristic `…0001` (service `…1001`), replies come on `…0002`; a sid `0x80` heartbeat goes to the control characteristic `…5401` every 12 s. Packets use the stock TPL envelope (`AA 21 seq len total num sid 00 …`, CRC-16/CCITT-FALSE, 232-byte chunks). Replies are `AA 12 …` with payload `{subcommand, status}`.

| Step         | Phone sends                                                             | Glasses answer                                                                     |
| ------------ | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| START        | `C0 {00}`                                                               | `{0, status}`: resets the import state, heals the fs, fast conn params             |
| INFORMATION  | `C0 {01, 128-byte component header}`                                    | `{1, status}`: deletes and re-creates `ota/s200_firmware_ota.bin`                  |
| FILE         | per 4 KiB block: `C0 {02}` then the block as one `C1` message, same seq | `{2, status}` on `C1`, after the block is written and read back                    |
| RESULT_CHECK | `C0 {03}`                                                               | `{3, 8 UPDATING}` when size and CRC-32C match, else `{3, 7}` (file deleted)        |
| NOTIFY       | —                                                                       | `{4, 9 SYS_RESTART}` after writing flag `0x55555555`; disconnect + reset 3 s later |

Status codes: 0 success, 1 header, 2 path, 3 CRC, 4 timeout, 5 no resources, 6 flash write, 7 check fail, 8 updating, 9 restart, 10 fail.

### Failure handling

| Event                                          | What the sender does                                                                                                                                   |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| No reply to START (8 s)                        | resend START (idempotent), 3 tries, then `start-timeout`                                                                                               |
| START status ≠ 0                               | `start-rejected`                                                                                                                                       |
| INFORMATION status 1/2                         | `information-rejected` (deterministic)                                                                                                                 |
| Block NAK 3 / 4 / 5 (CRC, timeout, no buffer)  | the block never reached the parser: resend it in place, 3 tries                                                                                        |
| No block reply (4 s), bad-CRC reply, status 6  | the write outcome is unknown or the file is gone: **restart the component from INFORMATION** (never replay the block); 3 runs, then `component-failed` |
| RESULT_CHECK `{3, 7}`                          | stock deleted the file, flag clear: restart the component                                                                                              |
| RESULT_CHECK verdict lost                      | `{4, 9}` alone proves staging; with neither: `result-unknown` (`stockIntact: 'unknown'`). RESULT_CHECK is never resent                                 |
| Disconnect / write failure before RESULT_CHECK | `disconnected` / `write-failed`, `stockIntact: true`                                                                                                   |
| Disconnect after UPDATING                      | the expected reset: success                                                                                                                            |
| `abort()`                                      | allowed until RESULT_CHECK is sent; `aborted`, `stockIntact: true`                                                                                     |

**Why an interrupted transfer leaves stock intact:** the stock app writes the main image only into the littlefs staging file on the external NOR, never into MRAM. The Even bootloader installs that file only when the update flag reads `0x55555555`, and the app sets the flag in one place, after RESULT_CHECK has matched the closed file's size and CRC-32C against the header. Before RESULT_CHECK the flag cannot be set; the partial file is never read, and the next INFORMATION deletes it. This is also why the sender refuses to abort after RESULT_CHECK, and why a lost verdict is reported as unknown instead of retried.

### Preconditions (the `StockLink` guarantees them)

Connected to the named temple, services discovered, notifications on **both** `…0002` and `…5402`, the phone already bonded (stock never prompts; the Even app's bond is reused), the Even app force-quit (safety.md rule 6). No sid `0x80` auth handshake is needed for OTA: webflasher's hardware-validated path sends none, and the stock OTA transport's auth gate is compiled as constant-true (openCFW `ota_transport.c` `OTA_SendPacket`). After `staged`, reconnecting and checking the version is the caller's job (webflasher allows about 130 s for the install).

Tested against a fake stock temple (`src/testing/fake-stock-glasses.ts`, written from the documented receiver behaviour) with injected aborts, disconnects, lost and bad-CRC replies, corrupted and lost packets, flash-write and CRC-32C failures; after every failure the tests reset the fake and check that it still boots stock.

Sources: openCFW (MIT) `g2/src/apollo-main/app/a-02-ota-service/ota_service_file_parse.c` (`_fileCmdParse`, `_fileRawDataParse`), `a-12-ota-transport/ota_transport.c`, `g2/docs/reference/protocols.md` §3, §5–6; webflasher (MIT) `src/lib/g2BleOta.js` (`G2BleOtaSession`: characteristics, heartbeat, timeouts, NAK vs. timeout policy, status names); `docs/spikes/s1-ble.md` and `packages/lotti-kit` `G2Frame.swift` (framing). Facts only from GPL projects; none were needed here.

## Stock firmware

Even's firmware is never committed (rule 9). `wisp-ota fetch` downloads from Even's own CDN, `https://cdn.evenreal.co/firmware/<md5>.bin`, and pins each release by SHA-256. The pins and URLs come from the [webflasher](https://github.com/AM-Guru/evenRealities-webflasher) catalog (MIT); the URL scheme is also the one [g2flash](https://github.com/jimrandomh/g2flash)'s README and `build_cfw.sh` use (same URL for 2.3.0.24). `fetch` also cross-checks the main-app end webflasher computed for each release. All 18 releases from 2.0.1.14 to 2.3.2.14 fetch, verify and repack cleanly. Tests use synthetic bundles only (`src/testing/synthetic.ts`); `src/stock.test.ts` additionally runs over whatever is in `.wisp-cache/stock/` and is skipped when that is empty.

## Tests

```sh
pnpm nx run wisp-ota:test       # node:test, like apps/brain
pnpm nx run wisp-ota:typecheck  # also checks the library compiles with no Node types (portable)
```

## Credits

Format facts and the CRC-32C variant follow [openCFW](https://github.com/kalanihelekunihi/evenRealities-openCFW) (`g2/docs/reference/firmware-formats.md`, `g2/tools/open_cfw.py`, MIT); CRC check values were taken from `open_cfw.py`. Cross-checked against webflasher's `firmware.js` (MIT). The `0x7F8000` ceiling and the "no bounds check in the bootloader" fact are from g2flash (GPL-3.0; facts only, no code).

## License

MIT, see [LICENSE](LICENSE).
