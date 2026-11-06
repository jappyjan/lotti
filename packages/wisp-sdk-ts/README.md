# @wisp/sdk

TypeScript SDK for [Wisp](../../docs/wisp/README.md), the open firmware for the Even Realities G2 glasses. It speaks the [Wisp protocol v0](../../docs/wisp/protocol.md) and runs in browsers, Node and React Native: no runtime dependencies, no Node or DOM APIs in the core (only `Uint8Array`, `DataView` and timers).

Status: M0 (protocol draft 0.2). The API will change with the protocol until 1.0.

## Example

```ts
import { WebBluetoothTransport, WispGlasses, toRaw4 } from '@wisp/sdk';

const transport = await WebBluetoothTransport.request(); // needs a user gesture
const glasses = await WispGlasses.connect(transport, {
  appId: 'com.example.hello',
});

const { width, height } = glasses.capabilities.canvas;
const bg = glasses.layers.create({ w: width, h: height });
bg.fill(0);

// Any RGBA or greyscale pixels, e.g. a canvas' ImageData.
const logo = toRaw4(ctx.getImageData(0, 0, 128, 64), {
  dither: 'floyd-steinberg',
});
const res = await glasses.resources.put(logo, { id: 1, persist: true }); // skipped if already there
bg.blit(res, { x: 256, y: 200 });
await glasses.commit(); // resolves when the frame is on the panel

await glasses.input.configure({ gestures: true });
glasses.input.on('gesture', (g) => console.log(g.kind, 'on lens', g.lens));

await glasses.sensors.subscribe('accelerometer', { rateHz: 50, batchMs: 200 });
glasses.sensors.on('accelerometer', ({ samples }) =>
  console.log(samples.at(-1)),
);

await glasses.close(); // BYE: the glasses stop everything this session started
```

Against the simulator: `await WebSocketTransport.connect('ws://localhost:…')`.

## API

**`WispGlasses.connect(transport, { appId, clientName?, keepalive?, sha256?, maxFrame?, rxWindow?, requestTimeoutMs? })`** sends `HELLO`, applies the glasses' frame size and window, and keeps the session alive with `PING`s at a third of `session_timeout_ms`.

| member                 | what                                                                                                                                                                                                  |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `capabilities`         | typed `HELLO`: canvas, firmware, limits, `has('lz4')`, supported `codecs`                                                                                                                             |
| `layers.create(props)` | a `Layer` (`LAYER_SET`); `set`, `move`, `scrollTo`, `fill`, `blit`, `image` (inline, smallest codec, split into strips), `text`, `textMeasured`, `scroll`, `tween`, `play`, `delete`                  |
| `layers.clear()`       | `CLEAR_ALL`                                                                                                                                                                                           |
| `commit({ wait })`     | `COMMIT`; with `wait` (default) resolves with `{ frame, glassUs }` once on the panel                                                                                                                  |
| `resources`            | `put(image \| animation \| font \| blob, { id, persist })` hashes, skips the upload when `PUT_BEGIN` says it exists, switches to the bulk link profile for big uploads; `delete`, `deleteAll`, `list` |
| `input`                | `configure({ touch, gestures, … })`; events `touch`, `gesture`                                                                                                                                        |
| `sensors`              | `subscribe(name, { rateHz, batchMs })`, `unsubscribe`, `read`; one typed event per sensor (`accelerometer`, `battery`, …)                                                                             |
| `audio`                | `startMic`, `stopMic`, `tone`; event `mic`                                                                                                                                                            |
| `system`               | `info`, `stats`, `brightness`, `displayPower`, `linkProfile`, `reboot`, `setLogLevel`; event `log`                                                                                                    |
| `syncClock()`, `clock` | `TIME_SYNC` rounds; `clock.toGlassUs(Date.now())`, `clock.driftPpm`                                                                                                                                   |
| `link`                 | the `WispLink` underneath, for anything the high-level API doesn't cover                                                                                                                              |

Event emitters: `on(type, fn)` returns an unsubscribe function.

### Layers below

- **`protocol/`**: CRC-16/CCITT-FALSE, `encodeFrame` and the streaming `FrameDecoder` (any chunking, resync on bad magic, length or CRC), message headers and a typed layout for every message in the spec (`Messages.display.fill.request.encode({...})`). Decoders follow the append-only rule: trailing bytes are ignored, missing trailing fields get their defaults, and a field cut in half throws `PayloadError` (error 2). Lists (`LIST` entries, `TONE` steps, sensor samples) are counted: `count` is authoritative and items are (remaining / count) bytes, so they can grow.
- **`link/`**: `Transport` (a byte stream with an MTU) and `WispLink`: byte-credit window (one default frame until `HELLO` is answered), `CREDIT` and `RESYNC` as unsequenced control frames, coalesced `CREDIT`s plus one for every duplicate, `RESYNC` and retransmission, an ack timeout (`ackTimeoutMs`, default 1 s) that resends unacknowledged frames, gap handling (`FrameReceiver`), request/response by `req` with timeouts (every request with `req ≠ 0` gets exactly one response), events, keepalive. `link.call(Messages.system.stats)` returns a typed response.
- **`transports/`**: `WebBluetoothTransport` (GATT, writes chunked to MTU − 3), `WebSocketTransport` (simulator), `createLoopbackPair` (tests, with fault injection). Node BLE (e.g. noble) isn't included yet: implement `Transport` by writing chunks of `mtu` bytes to the RX characteristic without response and feeding TX notifications to `onData`.
- **`image/`**: `toRaw4` (RGBA or greyscale, optional Floyd–Steinberg or ordered dithering), RLE4 and LZ4 block encoders and decoders, `encodeSmallest`, `xorFrames` for delta frames, image and animation resource payloads, `resourceHash` (first 16 bytes of SHA-256 via WebCrypto; `setSha256()` or the `sha256` option where WebCrypto is missing, e.g. React Native).

## Development

```sh
pnpm nx run wisp-sdk-ts:test       # unit tests + golden vectors in packages/wisp-proto/vectors
pnpm nx run wisp-sdk-ts:typecheck  # core checked without Node or DOM types
pnpm nx run wisp-sdk-ts:build
```

The golden-vector test reads every file in `packages/wisp-proto/vectors/` (or `$WISP_VECTORS`) and skips when there are none.

The LZ4 coder is written from the [LZ4 block format description](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) (BSD-2-Clause); no code was copied.

## License

MIT, see [LICENSE](LICENSE).
