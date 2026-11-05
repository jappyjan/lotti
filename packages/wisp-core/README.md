# wisp-core

The portable C core of [Wisp](../../docs/wisp/README.md): the [protocol](../../docs/wisp/protocol.md) codec, frames and flow control, pixel codecs and the glasses-side session. The same code runs on the glasses (Cortex-M55 under an RTOS), in the desktop simulator and in WASM.

Rules for everything in here: C11, no hardware dependencies, no `malloc`, no globals (state lives in context structs the caller owns), caller-provided buffers, and no libc beyond `memcpy`, `memset` and `memcmp` (`build-arm` checks this).

## Modules

| Header           | What                                                                                                                                                 |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wisp/crc.h`     | CRC-16/CCITT-FALSE (frames), CRC-32C MSB-first (EVENOTA), zlib CRC-32. Nibble tables, 192 bytes                                                      |
| `wisp/frame.h`   | `wisp_frame_encode`; `wisp_rx` streaming receiver (any chunking, resync, duplicate drop); `wisp_tx` sender credit window with retransmit from a ring |
| `wisp/msg.h`     | message header, error codes, the table-driven payload codec (`wisp_pack` / `wisp_unpack`, append-only rules)                                         |
| `wisp/msgs.h`    | generated: a struct and a `wisp_desc` per message, op and service ids                                                                                |
| `wisp/codec.h`   | RLE4 encode/decode, LZ4 block decode and a small greedy encoder, XOR delta, `wisp_pixels_decode` for any codec                                       |
| `wisp/session.h` | session state machine: `HELLO` gating (error 7 before it), `PING`, `TIME_SYNC`, `CREDIT`/`RESYNC` events, timeout                                    |

A receive loop on the glasses, roughly:

```c
do {
    size_t n = wisp_rx_feed(&rx, data, len, &ev, &f);
    data += n; len -= n;
    if (ev == WISP_RX_RESYNC) send_resync(rx.last_good_seq);
    if (ev != WISP_RX_FRAME) continue;
    wisp_session_rx(&session, f.svc, f.body, f.len, now_us, reply, sizeof reply, &r);
    if (r.reply_len) wisp_tx_send(&tx, f.svc, 0, reply, r.reply_len);
    switch (r.event) {
    case WISP_SESSION_STARTED: wisp_tx_set_peer(&tx, session.max_frame, session.peer_window); break;
    case WISP_SESSION_CREDIT: wisp_tx_ack(&tx, r.seq); break;
    case WISP_SESSION_RESYNC: wisp_tx_resync(&tx, r.seq); break;
    case WISP_SESSION_DISPATCH: /* display, resource, … */ break;
    default: break;
    }
} while (ev != WISP_RX_NONE);
```

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
```

Needs CMake ≥ 3.20, a C11 compiler and Python 3; `build-arm` needs `arm-none-eabi-gcc`. On a Nix host the targets fetch missing tools through `nix shell` by themselves (`tools/with-tools.sh`).

The randomized tests run a sender and a receiver over a link that corrupts, truncates and drops chunks (with CREDIT and RESYNC going back) and require every message exactly once and in order, including across a seq wrap.

## License

MIT, see [LICENSE](LICENSE). The LZ4 code is written from the LZ4 block format description; no upstream code is vendored.
