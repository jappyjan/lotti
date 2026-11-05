# Wisp protocol v0 (draft)

The contract between a phone (any app, through `wisp-sdk`) and glasses running Wisp, in host mode or native mode. Firmware, simulator and SDKs are built against this file. **Change it first, then the code**, and add golden vectors for every change (`packages/wisp-proto/vectors/`).

Status: draft 0.1 (2026-11-05). Nothing is frozen until protocol 1.0; before that, minor versions may break.

## Principles

- **Mechanism, not policy.** The firmware draws what the app says, streams what the app subscribed to, and nothing else. No built-in widgets, menus, fonts or gestures that the app can't replace.
- **Everything off by default.** Sensors, mic, gesture recognition, display: nothing runs until an app asks. A session that goes away stops everything it started (battery).
- **Do work on the glasses only when it saves radio time.** Animations, scrolling and text layout run on the glasses so a frame costs no BLE traffic; pixels are sent once and cached.
- **Little-endian, fixed layouts, append-only.** Every message payload is a fixed C-like struct. New fields are only appended; a receiver ignores trailing bytes it doesn't know and uses defaults for missing trailing fields.
- **Capabilities, not versions, decide features.** `HELLO` returns capability bits and limits; SDKs check those.

## Layers

```
app ─ wisp-sdk ─┬─ messages (service, op, payload)        this file
                ├─ frames   (stream, flow control, CRC)    this file
                └─ link     (GATT | L2CAP CoC | host-mode tunnel | WebSocket for the simulator)
```

### Links

| Link            | Where     | Notes                                                                                                                                                                                                                                                                          |
| --------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| GATT            | native    | Service `cf099bf1-f34e-49e2-b353-7f20e02243bc`; **RX** `cf099bf2-f34e-49e2-b353-7f20e02243bc` (write without response, phone → glasses); **TX** `cf099bf3-f34e-49e2-b353-7f20e02243bc` (notify, glasses → phone). MTU 247 requested. Works everywhere, Web Bluetooth included. |
| L2CAP CoC       | native    | PSM in `HELLO` caps. Faster (no ATT overhead, credit flow in the controller). Optional; same frames.                                                                                                                                                                           |
| Host tunnel     | host mode | Frames tunnelled inside stock TPL packets on a private sid (to be fixed by the host-mode spike).                                                                                                                                                                               |
| WebSocket / TCP | simulator | Binary messages carry the same byte stream.                                                                                                                                                                                                                                    |

A link is a **byte stream** per temple connection. Frames are concatenated; one GATT write may carry several frames or part of one.

### Topology

Each temple is its own peripheral. An SDK may connect to both temples (two streams, double bandwidth, true stereo) or only to the right temple and let it forward to the left one over the inter-temple link (one radio, less phone battery). The `route` byte in each frame says which lens a frame is for or from, so both topologies use the same messages.

## Frames

| Offset | Size  | Field    |                                                                                                                                                                                    |
| ------ | ----- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0      | 1     | `magic`  | `0x57` (`W`)                                                                                                                                                                       |
| 1      | 1     | `svc`    | service id (below)                                                                                                                                                                 |
| 2      | 1     | `route`  | bits 0–1 destination lens (`0` = the lens you're connected to, `1` left, `2` right, `3` both); bits 2–3 source lens on glasses → phone (`1` left, `2` right); bits 4–7 reserved, 0 |
| 3      | 1     | `fflags` | reserved, 0 (later: frame compression)                                                                                                                                             |
| 4      | 2     | `len`    | body length, ≤ `max_frame`                                                                                                                                                         |
| 6      | 2     | `seq`    | per direction and connection, starts at 0, +1 per frame, wraps                                                                                                                     |
| 8      | `len` | body     | one message                                                                                                                                                                        |
| 8+len  | 2     | `crc`    | CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over bytes 0 … 7+len                                                                                                                 |

Overhead: 10 bytes per frame. `max_frame` defaults to 4096 and is negotiated in `HELLO` (≤ 65535).

### Flow control and recovery

- Credits in bytes. Each side announces `rx_window` in `HELLO`. A sender keeps the sum of frame sizes sent but not yet acknowledged ≤ the peer's window.
- The receiver acknowledges with `CREDIT {ack_seq}` (session service) when it has consumed frames; it coalesces (at most every 25 % of its window or 20 ms, whichever comes first).
- A frame with a bad magic, a `len` above `max_frame` or a bad CRC: the receiver drops bytes until the next `magic` that starts a frame with a valid CRC, and sends `RESYNC {last_good_seq}`. The sender resends every frame after `last_good_seq` (it still holds them: they're inside the window). BLE already retransmits on the air; this covers buffer overruns and firmware bugs.
- The receiver accepts only `seq = last_good_seq + 1` (before the first frame, `last_good_seq` is `0xFFFF`). A frame behind that is a duplicate and is dropped silently. A frame ahead of it means one went missing: it's dropped and, unless a `RESYNC` is already outstanding, answered with `RESYNC`. So messages are always handled in order.
- One `RESYNC` per run of discarded bytes; frames that arrive in the meantime (sent before the sender saw the `RESYNC`) are dropped without another one. The next in-order frame ends the recovery.
- A sender that holds unacknowledged frames and hears no `CREDIT` for a while (SDK default 1 s) resends all of them. That recovers a lost or corrupted last frame, which no later frame would expose.

## Messages

Body = message header + payload:

| Offset | Size | Field    |                                                                                      |
| ------ | ---- | -------- | ------------------------------------------------------------------------------------ |
| 0      | 1    | `op`     | operation within the service                                                         |
| 1      | 1    | `mflags` | bit 0 `RESPONSE`, bit 1 `ERROR`, bit 2 `EVENT` (unsolicited)                         |
| 2      | 2    | `req`    | correlation id. A request with `req = 0` wants no response. A response echoes `req`. |
| 4      | …    | payload  |                                                                                      |

`mflags` picks the payload layout: `ERROR` → the error payload below, else `EVENT` → the event, else `RESPONSE` → the response, else the request. A plain "ok" response has an empty payload. Responses, errors included, are only sent for requests with `req ≠ 0`.

Append-only decoding: a missing trailing field reads as 0 (unless the field says otherwise); a field cut in half is error `2`.

An `ERROR` response's payload is `{code u16, message utf8…}`. Codes: `1` unsupported op, `2` bad payload, `3` no such id, `4` out of memory, `5` busy, `6` hash mismatch, `7` not allowed, `8` exists.

### Services

| id          | service    |                                                                                    |
| ----------- | ---------- | ---------------------------------------------------------------------------------- |
| `0x00`      | session    | hello, credit, resync, ping, time sync, keepalive                                  |
| `0x01`      | system     | device info, battery, brightness, display power, link profile, reboot, logs, stats |
| `0x02`      | display    | layers, drawing, commit, animation                                                 |
| `0x03`      | resource   | upload, persist, delete images, animations, fonts, blobs                           |
| `0x04`      | input      | touch and gesture events                                                           |
| `0x05`      | sensor     | IMU, magnetometer, light, wear, battery, temperature subscriptions                 |
| `0x06`      | audio      | mic stream, buzzer                                                                 |
| `0x07`      | update     | firmware update (native mode)                                                      |
| `0x80–0xFE` | extensions | firmware modules; listed in `HELLO` caps                                           |

Types below: `u8 u16 u32 u64 i16 i32` little-endian; `str16` = 16 bytes UTF-8, zero-padded; `hash16` = first 16 bytes of SHA-256; `…` = rest of the payload.

### 0x00 session

| op  | name        | request                                                                                         | response / event                                                                                                                                                                                                                               |
| --- | ----------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `HELLO`     | `proto_major u8, proto_minor u8, max_frame u16, rx_window u32, app_id str16, client_name str16` | `proto_major u8, proto_minor u8, max_frame u16, rx_window u32, fw_name str16, fw_version str16, lens u8, caps u32, canvas_w u16, canvas_h u16, bpp u8, max_layers u8, res_bytes u32, persist_bytes u32, session_timeout_ms u32, l2cap_psm u16` |
| 2   | `CREDIT`    | `ack_seq u16` (no response)                                                                     | —                                                                                                                                                                                                                                              |
| 3   | `RESYNC`    | `last_good_seq u16` (no response)                                                               | —                                                                                                                                                                                                                                              |
| 4   | `PING`      | `token u32`                                                                                     | `token u32`                                                                                                                                                                                                                                    |
| 5   | `TIME_SYNC` | `phone_ms u64`                                                                                  | `phone_ms u64, glass_us u64` — the SDK estimates offset and drift (stock clocks drift 1–2 %)                                                                                                                                                   |
| 6   | `BYE`       | —                                                                                               | — (ends the session; same effect as a timeout)                                                                                                                                                                                                 |

In `HELLO`, `max_frame 0` means 4096 and `rx_window 0` means 16384. Each side uses the smaller `max_frame` of the two.

`HELLO` must be the first message on a connection; everything else before it gets error `7`. **Session timeout:** if the glasses receive nothing for `session_timeout_ms` (default 10 s; any frame counts, `PING` is the keepalive), the session ends: subscriptions stop, mic stops, animations stop, non-persisted resources may be freed, and the display state stays as it was until the display policy turns it off. `app_id` namespaces persisted resources.

`caps` bits: 0 display, 1 animation, 2 tween, 3 text, 4 persist, 5 touch raw, 6 gestures, 7 IMU, 8 magnetometer, 9 ambient light, 10 wear, 11 mic PCM, 12 mic LC3, 13 buzzer, 14 update, 15 L2CAP, 16 forward to other lens, 17 RLE4, 18 LZ4, 19 delta frames.

### 0x02 display

The canvas is `canvas_w × canvas_h` at `bpp` (4 on the G2: 16 grey levels, 0 = off/transparent). The panel shows the **composition of layers**, back to front by `z`. Draw operations write into a layer's own buffer; the panel only changes on `COMMIT`, so updates are tear-free and a whole frame's changes cost one radio burst.

| op  | name        | payload                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| --- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `LAYER_SET` | `layer u8, z u8, flags u8, alpha u8 (0–15), x i16, y i16, w u16, h u16, content_w u16, content_h u16, scroll_x i16, scroll_y i16`. Creates or updates. `w,h` = view rect on screen; `content_w,h` = buffer size (≥ view; 0 = same as view); `scroll_x,y` = view origin inside the content. Changing only position, alpha or scroll is free (no redraw). `flags`: bit 0 visible, bits 1–2 blend (`0` over: nonzero pixels replace, `1` max, `2` additive saturate). |
| 2   | `LAYER_DEL` | `layer u8`                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| 3   | `FILL`      | `layer u8, value u8, x i16, y i16, w u16, h u16` (content coordinates)                                                                                                                                                                                                                                                                                                                                                                                             |
| 4   | `BLIT`      | `layer u8, flags u8, x i16, y i16, res u16, src_x u16, src_y u16, w u16, h u16` — from an image resource; `w = 0` = whole image. `flags` bit 0: treat 0 as transparent.                                                                                                                                                                                                                                                                                            |
| 5   | `IMAGE`     | `layer u8, codec u8, x i16, y i16, w u16, h u16, data…` — inline, not cached (streaming, video)                                                                                                                                                                                                                                                                                                                                                                    |
| 6   | `TEXT`      | `layer u8, value u8, x i16, y i16, font u16, max_w u16, line_h u16, utf8…` — renders with a font resource; wraps at `max_w` (0 = no wrap). Response (if `req ≠ 0`): `w u16, h u16, chars_drawn u16`.                                                                                                                                                                                                                                                               |
| 7   | `SCROLL`    | `layer u8, dx i16, dy i16, fill u8` — shifts the content buffer (terminals, teleprompters)                                                                                                                                                                                                                                                                                                                                                                         |
| 8   | `COMMIT`    | `flags u8` — composes and pushes dirty regions. Response (if `req ≠ 0`) when the frame is on the panel: `frame u32, glass_us u64`. Use it to pace frames.                                                                                                                                                                                                                                                                                                          |
| 9   | `ANIM_PLAY` | `slot u8, layer u8, x i16, y i16, res u16, loops u16 (0 = forever), flags u8` — plays an animation resource into a layer and commits by itself. Event `ANIM_DONE {slot}` (op 9, `EVENT`).                                                                                                                                                                                                                                                                          |
| 10  | `ANIM_STOP` | `slot u8`                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 11  | `TWEEN`     | `layer u8, prop u8 (0 x, 1 y, 2 alpha, 3 scroll_x, 4 scroll_y), easing u8 (0 linear, 1 in, 2 out, 3 in-out), to i16, duration_ms u16` — on-glass property animation, no traffic per frame                                                                                                                                                                                                                                                                          |
| 12  | `CLEAR_ALL` | — deletes every layer of this session                                                                                                                                                                                                                                                                                                                                                                                                                              |

With `route` both lenses get the same operations; send different operations per lens for stereo or per-eye layouts.

### 0x03 resource

Resources are referenced by `res u16`, scoped to the session's `app_id`. **Persisted** resources survive reboots (NOR littlefs, LRU-evicted when `persist_bytes` is exhausted, never evicted while in use); others live in RAM until the session ends or memory is needed.

| op  | name        | payload                                                                       | response                                                                                        |
| --- | ----------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| 1   | `PUT_BEGIN` | `res u16, type u8, codec u8, flags u8 (bit 0 persist), size u32, hash hash16` | `status u8` — `0` send data, `1` **already present with this hash** (skip the upload), or error |
| 2   | `PUT_DATA`  | `res u16, offset u32, data…`                                                  | none (flow control covers it)                                                                   |
| 3   | `PUT_END`   | `res u16`                                                                     | ok, or error `6` hash mismatch                                                                  |
| 4   | `DELETE`    | `res u16` (`0xFFFF` = all of this app)                                        | ok                                                                                              |
| 5   | `LIST`      | —                                                                             | `count u16, entries {res u16, type u8, flags u8, size u32, hash hash16}…`                       |

Resource types:

- **`1` image:** `w u16, h u16, bpp u8, codec u8, data…`
- **`2` animation:** `w u16, h u16, frames u16, codec u8, {duration_ms u16, kind u8 (0 key, 1 delta: XOR with the previous frame), size u32, data…}…`
- **`3` font:** Wisp bitmap font: `line_h u8, baseline u8, glyphs u16, {codepoint u32, w u8, h u8, x_off i8, y_off i8, advance u8, offset u32}…` sorted by codepoint, then 4 bpp glyph bitmaps (RAW4). Any script, any size: fonts are the app's choice.
- **`4` blob:** opaque bytes for extensions.

**Codecs** (pixel data, all 4 bpp, rows top to bottom, high nibble = left pixel):

| id  | codec     |                                                                                                                                                                                      |
| --- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 0   | `RAW4`    | packed, stride `ceil(w/2)`; the padding nibble of an odd width is 0                                                                                                                  |
| 1   | `RLE4`    | one byte per run: high nibble = run length − 1 (1–16 pixels), low nibble = value. Runs may cross rows. Encoders emit greedy maximal runs; the runs must cover exactly `w × h` pixels |
| 2   | `LZ4`     | LZ4 _block_ format over the `RAW4` bytes                                                                                                                                             |
| 3   | `LZ4_RLE` | LZ4 block over `RLE4` bytes                                                                                                                                                          |

Every decoded image must have exactly the size `w`, `h` and the codec imply. Codec support is listed in `caps`; the SDK picks the smallest that the glasses support.

### 0x04 input

| op  | name              | payload                                                                                                      |
| --- | ----------------- | ------------------------------------------------------------------------------------------------------------ |
| 1   | `CONFIG`          | `mask u8` (bit 0 raw touch, bit 1 gestures), `tap_max_ms u16, double_gap_ms u16, long_ms u16` (0 = defaults) |
| 2   | `TOUCH` (event)   | `lens u8, pad u8, phase u8 (0 down, 1 move, 2 up), pos u16, t_us u32`                                        |
| 3   | `GESTURE` (event) | `lens u8, kind u8 (1 tap, 2 double tap, 3 long start, 4 long end, 5 swipe forward, 6 swipe back), t_us u32`  |

Default: nothing is sent until `CONFIG`. Gestures are recognised on the glasses only to save radio wakeups; apps that want their own recognizer take raw touch.

### 0x05 sensor

| op  | name           | payload                                                                                                                                                |
| --- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `SUBSCRIBE`    | `sensor u8, rate_hz u16, batch_ms u16` — `rate_hz 0` = on change. Samples are buffered on the glasses and sent every `batch_ms` (fewer radio wakeups). |
| 2   | `UNSUBSCRIBE`  | `sensor u8`                                                                                                                                            |
| 3   | `DATA` (event) | `sensor u8, count u8, t0_us u32, dt_us u32, samples…`                                                                                                  |
| 4   | `READ`         | `sensor u8` → response `sample…` (one sample)                                                                                                          |

| sensor        | id  | sample                            |
| ------------- | --- | --------------------------------- |
| accelerometer | 1   | `x,y,z i16` (mg)                  |
| gyroscope     | 2   | `x,y,z i16` (0.1 °/s)             |
| magnetometer  | 3   | `x,y,z i16` (0.1 µT)              |
| ambient light | 4   | `lux u32`                         |
| wear          | 5   | `worn u8`                         |
| battery       | 6   | `soc u8 (%), mv u16, charging u8` |
| temperature   | 7   | `centi_c i16`                     |

### 0x06 audio

| op  | name               | payload                                                                                             |
| --- | ------------------ | --------------------------------------------------------------------------------------------------- |
| 1   | `MIC_START`        | `codec u8 (0 PCM16, 1 LC3), rate_hz u16, channels u8 (bit mask of mics), frame_ms u8, lc3_bytes u8` |
| 2   | `MIC_STOP`         | —                                                                                                   |
| 3   | `MIC_DATA` (event) | `seq u16, t_us u32, data…`                                                                          |
| 4   | `TONE`             | `count u8, steps {freq_hz u16, duration_ms u16, duty u8 (0–100)}…` (buzzer; `freq_hz 0` = pause)    |

### 0x01 system

| op  | name            | payload                                                                                                                                               | response                                                                                                                    |
| --- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| 1   | `INFO`          | —                                                                                                                                                     | `hw_rev str16, serial str16, panel u8, power_board u8, lens u8, boot_reason u8, boot_count u32, uptime_ms u32, build str16` |
| 2   | `BRIGHTNESS`    | `mode u8 (0 manual, 1 auto), level u8 (0–255)`                                                                                                        | ok                                                                                                                          |
| 3   | `DISPLAY_POWER` | `on u8, off_when_unworn u8, idle_off_ms u32 (0 = never)`                                                                                              | ok                                                                                                                          |
| 4   | `LINK_PROFILE`  | `profile u8 (0 idle, 1 interactive, 2 bulk)` — the firmware picks connection interval, latency and PHY; the SDK switches to bulk for uploads and back | ok                                                                                                                          |
| 5   | `REBOOT`        | `mode u8 (0 normal, 1 rescue)`                                                                                                                        | ok, then reboot                                                                                                             |
| 6   | `LOG_CONFIG`    | `level u8 (0 off … 4 debug)`                                                                                                                          | ok                                                                                                                          |
| 7   | `LOG` (event)   | `level u8, t_us u32, utf8…`                                                                                                                           | —                                                                                                                           |
| 8   | `STATS`         | —                                                                                                                                                     | `heap_free u32, heap_min u32, cpu_pct u8, frames u32, rx_bytes u32, tx_bytes u32, resyncs u16`                              |

### 0x07 update (native mode)

Host mode updates go through the stock OTA service (`wisp-ota` builds the bundle). Native mode:

| op  | name     | payload                                                                                                                                                                          |
| --- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `BEGIN`  | `size u32, sha256 [32], version str16` → ok / error                                                                                                                              |
| 2   | `DATA`   | `offset u32, data…`                                                                                                                                                              |
| 3   | `END`    | — → ok after the staged image's SHA-256 and the [image checks](safety.md#hard-rules-no-exceptions-enforced-in-tooling) pass                                                      |
| 4   | `APPLY`  | — reboots into the new image. It must confirm itself (BLE up, a `HELLO` completed) or Wisp Boot falls back ([safety.md](safety.md#fallback-to-stock-designed-into-native-mode)). |
| 5   | `STATUS` | — → `state u8, confirmed u8, version str16, rescue_present u8`                                                                                                                   |

## Open questions

- Host-mode tunnel sid and how stock's own traffic coexists.
- Whether forwarding over the inter-temple UART is fast enough for full-frame content (baud unknown).
- LC3 frame parameters supported by the GX8002 path.
- Dirty-rectangle granularity of the panel (whole-frame push measured at 1.2–6.6 ms).
