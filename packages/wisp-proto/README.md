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

| kind      | meaning                                                                                                                        | `hex` is                |
| --------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------- |
| `message` | a message body (header + payload); `fields` are the decoded payload fields, named as in the spec                               | the body                |
| `frame`   | a whole frame: `svc`, `route`, `seq`, `body_hex`                                                                               | the frame, CRC included |
| `stream`  | `frames` (array of frame hex) split into `chunks` (array of hex) as a link would deliver them; for reassembly and resync tests | —                       |
| `codec`   | `codec` id, `w`, `h`, `pixels_hex` (RAW4)                                                                                      | the encoded data        |
| `crc`     | `algo` (`crc16-ccitt-false`, `crc32c-msb`, `crc32-zlib`), `input_hex`                                                          | the CRC, little-endian  |

Rules: lowercase hex, no spaces. `str16` fields are given as plain strings. A case may set `"decode_only": true` when the encoder is allowed to produce different bytes (for example LZ4, whose output isn't unique): then implementations must decode `hex` to the given input, and their own encoding must round-trip.

Adding a protocol feature means adding vectors here in the same change.
