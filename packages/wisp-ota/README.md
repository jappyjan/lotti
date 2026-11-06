# wisp-ota

EVENOTA inspector, packer and verifier for Wisp (Even Realities G2). Every image that goes to real glasses passes through this package; it is the main brick-prevention layer (decision W14, [safety.md](../../docs/wisp/safety.md)).

- **Library** (`@wisp/ota`): TypeScript, zero runtime dependencies, `Uint8Array`/plain integers only. Runs in Node, browsers and React Native, so the phone app can install Wisp over stock with the same code.
- **CLI** (`wisp-ota`): a thin Node wrapper.
- **No BLE, no transfer code.** Nothing in this package talks to glasses.

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
