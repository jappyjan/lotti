# wisp-proto — golden vectors

Shared test data for every Wisp protocol implementation (C core, TypeScript SDK, Swift SDK, …). The spec is [docs/wisp/protocol.md](../../docs/wisp/protocol.md); these files pin it down byte for byte. Every implementation's tests load all files here and must pass all of them.

## Format

One JSON file per area (`frames.json`, `session.json`, `display.json`, `codecs.json`, …), each an array of cases:

```json
{
  "name": "session/hello-request-minimal",
  "kind": "message",
  "svc": 0,
  "op": 1,
  "mflags": 0,
  "req": 1,
  "fields": {
    "proto_major": 0,
    "proto_minor": 1,
    "max_frame": 4096,
    "rx_window": 16384,
    "app_id": "demo",
    "client_name": "test"
  },
  "hex": "01000100…"
}
```

| kind      | meaning                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | `hex` is                |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| `message` | a message body (header + payload); `fields` are the decoded payload fields, named as in the spec                                                                                                                                                                                                                                                                                                                                                                                                     | the body                |
| `frame`   | a whole frame: `svc`, `route`, `fflags`, `seq`, `body_hex`                                                                                                                                                                                                                                                                                                                                                                                                                                           | the frame, CRC included |
| `stream`  | `chunks` (array of hex) as a link delivers them, possibly corrupted; `frames` (array of frame hex) the frames a receiver delivers, in order; `controls` the control frames (`fflags.CTRL`) it passes on, in order; `resyncs` the `last_good_seq` of each `RESYNC` it asks for; `credits` the `last_good_seq` of the `CREDIT` that answers each duplicate. The receiver starts fresh (expects seq 0) with `max_frame` 4096. Coalesced acks for consumed frames are policy and not part of the vectors | —                       |
| `codec`   | `codec` id, `w`, `h`, `pixels_hex` (RAW4)                                                                                                                                                                                                                                                                                                                                                                                                                                                            | the encoded data        |
| `crc`     | `algo` (`crc16-ccitt-false`, `crc32c-msb`, `crc32-zlib`), `input_hex`                                                                                                                                                                                                                                                                                                                                                                                                                                | the CRC, little-endian  |

Rules: lowercase hex, no spaces. `str16` fields are given as plain strings.

Fields: integers are JSON numbers (`u64` values stay below 2^53); `str16` and `utf8…` are strings; `hash16`, `sha256 [32]` and `data…`-style byte tails are hex strings; `{…}…` runs are arrays of objects (`entries`, `steps`) holding the fields the layout knows; sensor `samples` stay hex. A `decode_only` list case may carry items longer than the known fields (readers skip the rest) or shorter (missing fields are 0). Every field of the layout is present, with its default (0, `""`, zero hash, `[]`) when a `decode_only` case leaves it off the wire. `mflags` picks the layout (`ERROR` → `{code, message}`), so `errors.json` cases carry the failed request's `svc` and `op`.

The vectors are generated by `packages/wisp-core/tools/gen_vectors.py` (Python, stdlib only, deterministic) from the message table in `packages/wisp-core/tools/spec.py`; regenerate with `pnpm nx run wisp-core:generate`. Don't edit the JSON by hand. A case may set `"decode_only": true` when the encoder is allowed to produce different bytes (for example LZ4, whose output isn't unique): then implementations must decode `hex` to the given input, and their own encoding must round-trip.

A case with `"malformed": true` must be rejected: a `message` payload is a bad payload (error `2`: a field cut in half, or a counted list whose remainder isn't a multiple of its `count`), a `codec` input doesn't decode (for example RLE4 runs that don't cover exactly `w × h`). Those cases carry no `fields` or `pixels_hex`.

Adding a protocol feature means adding vectors here in the same change.
