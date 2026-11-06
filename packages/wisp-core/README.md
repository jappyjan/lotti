# wisp-core

The portable C core of [Wisp](../../docs/wisp/README.md): the [protocol](../../docs/wisp/protocol.md) codec, frames and flow control, pixel codecs, the glasses-side session, and the display engine (layers and compositor, resources, text, animation, input). The same code runs on the glasses (Cortex-M55 under an RTOS), in the desktop simulator and in WASM.

Rules for everything in here: C11, no hardware dependencies, no `malloc`, no globals (state lives in context structs the caller owns), caller-provided buffers, and no libc beyond `memcpy`, `memmove`, `memset` and `memcmp` (`build-arm` checks this).

## Modules

| Header            | What                                                                                                                                                                                                  |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wisp/crc.h`      | CRC-16/CCITT-FALSE (frames), CRC-32C MSB-first (EVENOTA), zlib CRC-32. Nibble tables, 192 bytes                                                                                                       |
| `wisp/frame.h`    | `wisp_frame_encode`; `wisp_rx` streaming receiver (any chunking, resync, control frames, duplicates); `wisp_tx` sender credit window with retransmit from a ring, control-frame queue and ack timeout |
| `wisp/msg.h`      | message header, error codes, the table-driven payload codec (`wisp_pack` / `wisp_unpack`, append-only rules, counted lists)                                                                           |
| `wisp/msgs.h`     | generated: a struct and a `wisp_desc` per message, op and service ids                                                                                                                                 |
| `wisp/codec.h`    | RLE4 encode/decode, LZ4 block decode and a small greedy encoder, XOR delta, `wisp_pixels_decode` for any codec                                                                                        |
| `wisp/session.h`  | session state machine: `HELLO` gating (error 7 before it), `PING`, `TIME_SYNC`, `BYE`, `CREDIT`/`RESYNC` events in any state, timeout                                                                 |
| `wisp/engine.h`   | the glasses side in one struct: session + display + resource + input + wear + system services, one caller-provided arena, HAL callbacks                                                               |
| `wisp/display.h`  | layers (z, blend over/max/additive, alpha, view rect over a content buffer, free scroll), draw ops, dirty rects, the strip compositor                                                                 |
| `wisp/resource.h` | resources per `app_id`: `PUT_*` with SHA-256/16 check, "already present", `DELETE`/`LIST`, persist through a HAL storage, LRU cache eviction                                                          |
| `wisp/text.h`     | UTF-8 text with Wisp bitmap fonts: wrapping, `\n`, paging (`chars_drawn`)                                                                                                                             |
| `wisp/anim.h`     | animation players (key + XOR delta frames, per-frame durations, loops, `ANIM_DONE`) and tweens (linear / in / out / in-out)                                                                           |
| `wisp/input.h`    | touch → gestures: tap, double tap, long press start/end, swipes                                                                                                                                       |
| `wisp/pool.h`     | compacting block pool with owner back-pointers (no fragmentation failures, no malloc)                                                                                                                 |
| `wisp/sha256.h`   | SHA-256 (FIPS 180-4), for resource hashes                                                                                                                                                             |

A receive loop on the glasses, roughly:

```c
do {
    size_t n = wisp_rx_feed(&rx, data, len, &ev, &f);
    data += n; len -= n;
    if (ev == WISP_RX_RESYNC) wisp_tx_queue_resync(&tx, rx.last_good_seq);
    if (ev == WISP_RX_DUPLICATE) wisp_tx_queue_credit(&tx, rx.last_good_seq);
    if (ev != WISP_RX_FRAME && ev != WISP_RX_CONTROL) continue;
    wisp_session_rx(&session, f.svc, f.body, f.len, now_us, reply, sizeof reply, &r);
    if (r.reply_len) wisp_tx_send(&tx, f.svc, 0, reply, r.reply_len);
    switch (r.event) {
    case WISP_SESSION_STARTED: wisp_tx_set_peer(&tx, session.max_frame, session.peer_window); break;
    case WISP_SESSION_CREDIT: wisp_tx_ack(&tx, r.seq); break;
    case WISP_SESSION_RESYNC: wisp_tx_resync(&tx, r.seq); break;
    case WISP_SESSION_DISPATCH: /* display, resource, …: answer every req != 0 once */ break;
    default: break;
    }
} while (ev != WISP_RX_NONE);
/* elsewhere: queue a coalesced CREDIT after consuming frames, call wisp_tx_tick(&tx, now_ms)
 * every few ms (ack timeout), and pull bytes for the link with wisp_tx_pull */
```

## The engine

```c
wisp_engine_config cfg;
wisp_engine_defaults(&cfg);              /* 640×480, 16 layers, 1 MiB resources, 1 MiB graphics, … */
cfg.lens = 1;
static uint8_t arena[3u << 20];          /* wisp_engine_arena_size(&cfg) bytes */
wisp_hal hal = {ctx, present, frame_done, send, display_power, brightness, &storage};
wisp_engine_init(&engine, &cfg, &hal, arena, sizeof arena);

/* in the receive loop above, for every frame: */
wisp_engine_rx(&engine, f.svc, f.body, f.len, now_us, &r);   /* replies go out through hal.send */
/* every few ms (or when wisp_engine_busy()): animations, tweens, gesture timers, timeout */
wisp_engine_tick(&engine, now_us);
```

Memory is one arena with explicit limits: `max_layers` and `res_bytes` (the resource pool) are what `HELLO` reports; layer buffers, animation frame buffers and decode scratch come from a separate graphics pool (`gfx_bytes`). Both pools compact instead of fragmenting. Nothing calls `malloc`.

Drawing goes into layer content buffers and marks damage in canvas coordinates; `COMMIT` composes only the damaged rects (merged, at most 16) back to front, in strips of `strip_rows` rows, and hands each strip to `present()`. So updates are tear-free. Animations and tweens commit by themselves, composing only what they changed (pending draws of the app inside those rects show early; elsewhere they wait for `COMMIT`). Composition works on packed 4 bpp bytes: 64-bit SWAR for over / max / additive blends, nibble realignment eight bytes at a time, one 256-byte alpha table per translucent layer and commit; no per-pixel calls.

Host timings (`pnpm nx run wisp-core:bench`, `-O2`, Intel N150, best of 5; a noisy shared machine varies ±25 %):

| compose + present                         | time       |
| ----------------------------------------- | ---------- |
| full frame, 1 layer                       | 45–60 µs   |
| 64×32 dirty rect, 1 layer                 | 1.1–1.5 µs |
| full frame, 3 layers (odd offset, max, α) | 300–380 µs |
| 64×32 dirty rect, 3 layers                | 5–6 µs     |
| full frame, 5 layers                      | 370–450 µs |

`wisp-sim` runs this engine in WebAssembly; `tests/test_engine.c` checks the compositor against a per-pixel reference model on random scenes (layers, blends, alpha, odd offsets, scroll, clipping) and against golden frame hashes.

## Message table and vectors

[`tools/spec.py`](tools/spec.py) is the message table, transcribed from protocol.md. Two generators read it:

- `tools/gen_c.py` writes `include/wisp/msgs.h` and `src/msgs.c` (checked in).
- `tools/gen_vectors.py` writes the golden vectors in [`packages/wisp-proto/vectors`](../wisp-proto/vectors). It is an independent Python implementation (own CRCs, packer, RLE4, LZ4 assembler, reference receiver), so the vector test cross-checks two implementations of the spec. One LZ4 case comes from upstream liblz4.

Changing the protocol: edit protocol.md, then `spec.py`, then `pnpm nx run wisp-core:generate`. The tests fail if generated files are stale.

## Build and test

```sh
pnpm nx run wisp-core:build      # CMake, host, with ASan + UBSan
pnpm nx run wisp-core:test       # ctest: unit + randomized tests, golden vectors, generated files fresh
pnpm nx run wisp-core:build-arm  # arm-none-eabi-gcc -mcpu=cortex-m55 -Os -Werror, libc-subset check, size
pnpm nx run wisp-core:generate   # regenerate msgs.h/msgs.c and the vectors
pnpm nx run wisp-core:bench      # compose timings (-O2, no sanitizers)
```

Needs CMake ≥ 3.20, a C11 compiler and Python 3; `build-arm` needs `arm-none-eabi-gcc`. On a Nix host the targets fetch missing tools through `nix shell` by themselves (`tools/with-tools.sh`).

The randomized tests run two endpoints over a link that corrupts, truncates and drops chunks in both directions, so CREDIT and RESYNC control frames get lost and damaged as well; recovery relies on RESYNC, a CREDIT for every duplicate and the ack timeout. They require every message exactly once and in order, including across a seq wrap.

## License

MIT, see [LICENSE](LICENSE). The LZ4 code is written from the LZ4 block format description and SHA-256 from FIPS 180-4; no upstream code is vendored.
