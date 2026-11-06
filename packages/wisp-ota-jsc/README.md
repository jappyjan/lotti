# wisp-ota-jsc

`@wisp/ota` bundled for **JavaScriptCore**, so the Lotti iOS app's "Wisp update" screen runs the same guards, repacker, structural diff and stock OTA sender as the `wisp-ota` CLI. Nothing is ported to Swift; this package is glue only.

```sh
pnpm nx run wisp-ota-jsc:bundle   # → dist/wisp-ota.js, dist/wisp-ota-fake-temple.js
pnpm nx run wisp-ota-jsc:test     # runs the built bundles in bare vm contexts
```

| File                           | What                                                                                                                                    | Ships in                                                        |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `dist/wisp-ota.js`             | One IIFE, `globalThis.WispOta.create(host)`. No imports, no Node or DOM globals: timers, writes and results go through the host object. | the iOS app (copied in by `apps/ios/scripts/xcode.sh`)          |
| `dist/wisp-ota-fake-temple.js` | wisp-ota's fake stock temple (`testing/fake-stock-glasses.ts`) and synthetic bundles, `globalThis.WispFakeTemple.create(host)`.         | LottiKit tests, iOS Simulator builds only; never a device build |

## The host seam (`src/host.ts`)

Swift (`LottiKit/Wisp/WispOtaEngine.swift`) provides `setTimeout/clearTimeout/now`, `write(transfer, channel, bytes, writeId)` (answered with `writeDone`), `progress` and `finished`. The API it gets back:

- `catalog()` — the pinned releases with CDN URLs.
- `checkStock(release, bytes, sha256)` — the `wisp-ota fetch` checks for a host that hashed the bytes itself (size, SHA-256, header version, main-app end, integrity guards), plus `pinnedOfficial`.
- `prepareRung1(stock, version)` — `repackMain`, then `verifyBundle` on a fresh copy and `diffRepack` again; `sendable` only if both pass.
- `prepareStockBack(stock)` — `stockMainOnly` (the unchanged stock main as a main-only bundle), same checks, zero changed bytes required.
- `startTransfer(temple, linkTemple, bundle, timing)` → id, then `run(id)` — the stock OTA sender; it re-verifies the bundle and refuses anything not sendable or a temple mismatch before the first write. `abort(id)` (only before RESULT_CHECK), `packet`, `disconnected`, `writeDone`, `timerFired`.

Results end as `staged` / `failed` with `stockIntact: true` / `failed` with `stockIntact: 'unknown'`, which the app shows as **success**, **failed, stock intact** and **result unknown**.

## Why JavaScriptCore works here

The library was already written for it: `Uint8Array` and integers only, no `Buffer`/`TextDecoder`/`crypto`, timers injected through `Scheduler`. JSC drains Promise jobs at the end of every call from Swift, so the sender's `async` flow runs unchanged. The one sharp edge found: `JSObjectGetTypedArrayBytesPtr` points at the start of the backing buffer, so the Swift side adds `JSObjectGetTypedArrayByteOffset` (covered by a subarray test). SHA-256 is computed in Swift (CryptoKit) and checked here against the pin.

## Tests

`src/bundle.test.ts` loads the **built** files into bare `vm` contexts (no timers, no `process`, like a fresh `JSContext`), puts the sender and the fake temple in separate contexts, and moves packets between them through a host that delivers notifications asynchronously. It covers the rung-1 → stock round trip, abort before RESULT_CHECK, abort refused after it, a mid-block disconnect, a lost block reply, a lost verdict (`result unknown`), refusals before any write (full stock bundle, temple mismatch, "both"), and every `checkStock` refusal. The Swift side has the same scenarios in `packages/lotti-kit/Tests/LottiKitTests/WispOtaEngineTests.swift` and `apps/ios/LottiTests/WispUpdateModelTests.swift`.

## License

MIT, see [LICENSE](LICENSE).
