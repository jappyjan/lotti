"""Wisp protocol v0.2 message table, transcribed from docs/wisp/protocol.md.

The single source for the generated C structs (gen_c.py) and the golden
vectors (gen_vectors.py). Keep it in the spec's order and naming; append
fields only at the end of a message.

Field types: u8 i8 u16 i16 u32 i32 u64 (little-endian), str16 (16 bytes
UTF-8, zero-padded), hash16 (16 bytes), sha256 (32 bytes). The last field may
be a tail that takes the rest of the payload: bytes, utf8, or items:<struct>
(a run of structs). A tail with [field] after its type is a counted list:
`field` (an earlier field) holds the item count, which is authoritative,
and each item is remaining / count bytes; a remainder that isn't a multiple
of the count is malformed. Items may be longer than the struct we know
(readers skip the rest of each item) or shorter (missing fields read as 0).
bytes[field] is a counted list whose item layout the message doesn't fix
(sensor samples).
"""

SERVICES = {
    "session": 0x00,
    "system": 0x01,
    "display": 0x02,
    "resource": 0x03,
    "input": 0x04,
    "sensor": 0x05,
    "audio": 0x06,
    "update": 0x07,
}

# (service, op, kind, name, fields). kind: req (request), rsp (response
# payload), evt (unsolicited event). Ops whose response is a plain "ok" have
# no rsp entry: ok is an empty payload.
MESSAGES = [
    ("session", 1, "req", "hello", "proto_major u8, proto_minor u8, max_frame u16, rx_window u32, app_id str16, client_name str16"),
    ("session", 1, "rsp", "hello", "proto_major u8, proto_minor u8, max_frame u16, rx_window u32, fw_name str16, fw_version str16, lens u8, caps u32, "
                                   "canvas_w u16, canvas_h u16, bpp u8, max_layers u8, res_bytes u32, persist_bytes u32, session_timeout_ms u32, l2cap_psm u16"),
    ("session", 2, "req", "credit", "ack_seq u16"),
    ("session", 3, "req", "resync", "last_good_seq u16"),
    ("session", 4, "req", "ping", "token u32"),
    ("session", 4, "rsp", "ping", "token u32"),
    ("session", 5, "req", "time_sync", "phone_ms u64"),
    ("session", 5, "rsp", "time_sync", "phone_ms u64, glass_us u64"),
    ("session", 6, "req", "bye", ""),

    ("system", 1, "req", "info", ""),
    ("system", 1, "rsp", "info", "hw_rev str16, serial str16, panel u8, power_board u8, lens u8, boot_reason u8, boot_count u32, uptime_ms u32, build str16"),
    ("system", 2, "req", "brightness", "mode u8, level u8"),
    ("system", 3, "req", "display_power", "on u8, off_when_unworn u8, idle_off_ms u32"),
    ("system", 4, "req", "link_profile", "profile u8"),
    ("system", 5, "req", "reboot", "mode u8"),
    ("system", 6, "req", "log_config", "level u8"),
    ("system", 7, "evt", "log", "level u8, t_us u32, utf8 utf8"),
    ("system", 8, "req", "stats", ""),
    ("system", 8, "rsp", "stats", "heap_free u32, heap_min u32, cpu_pct u8, frames u32, rx_bytes u32, tx_bytes u32, resyncs u16"),

    ("display", 1, "req", "layer_set", "layer u8, z u8, flags u8, alpha u8, x i16, y i16, w u16, h u16, content_w u16, content_h u16, scroll_x i16, scroll_y i16"),
    ("display", 2, "req", "layer_del", "layer u8"),
    ("display", 3, "req", "fill", "layer u8, value u8, x i16, y i16, w u16, h u16"),
    ("display", 4, "req", "blit", "layer u8, flags u8, x i16, y i16, res u16, src_x u16, src_y u16, w u16, h u16"),
    ("display", 5, "req", "image", "layer u8, codec u8, x i16, y i16, w u16, h u16, data bytes"),
    ("display", 6, "req", "text", "layer u8, value u8, x i16, y i16, font u16, max_w u16, line_h u16, utf8 utf8"),
    ("display", 6, "rsp", "text", "w u16, h u16, chars_drawn u16"),
    ("display", 7, "req", "scroll", "layer u8, dx i16, dy i16, fill u8"),
    ("display", 8, "req", "commit", "flags u8"),
    ("display", 8, "rsp", "commit", "frame u32, glass_us u64"),
    ("display", 9, "req", "anim_play", "slot u8, layer u8, x i16, y i16, res u16, loops u16, flags u8"),
    ("display", 9, "evt", "anim_done", "slot u8"),
    ("display", 10, "req", "anim_stop", "slot u8"),
    ("display", 11, "req", "tween", "layer u8, prop u8, easing u8, to i16, duration_ms u16"),
    ("display", 12, "req", "clear_all", ""),

    ("resource", 1, "req", "put_begin", "res u16, type u8, flags u8, size u32, hash hash16"),
    ("resource", 1, "rsp", "put_begin", "status u8"),
    ("resource", 2, "req", "put_data", "res u16, offset u32, data bytes"),
    ("resource", 3, "req", "put_end", "res u16"),
    ("resource", 4, "req", "delete", "res u16"),
    ("resource", 5, "req", "list", ""),
    ("resource", 5, "rsp", "list", "count u16, entries items:list_entry[count]"),

    ("input", 1, "req", "config", "mask u8, tap_max_ms u16, double_gap_ms u16, long_ms u16"),
    ("input", 2, "evt", "touch", "lens u8, pad u8, phase u8, pos u16, t_us u32"),
    ("input", 3, "evt", "gesture", "lens u8, kind u8, t_us u32"),

    ("sensor", 1, "req", "subscribe", "sensor u8, rate_hz u16, batch_ms u16"),
    ("sensor", 2, "req", "unsubscribe", "sensor u8"),
    ("sensor", 3, "evt", "data", "sensor u8, count u8, t0_us u32, dt_us u32, samples bytes[count]"),
    ("sensor", 4, "req", "read", "sensor u8"),
    ("sensor", 4, "rsp", "read", "sample bytes"),

    ("audio", 1, "req", "mic_start", "codec u8, rate_hz u16, channels u8, frame_ms u8, lc3_bytes u8"),
    ("audio", 2, "req", "mic_stop", ""),
    ("audio", 3, "evt", "mic_data", "seq u16, t_us u32, data bytes"),
    ("audio", 4, "req", "tone", "count u8, steps items:tone_step[count]"),

    ("update", 1, "req", "begin", "size u32, sha256 sha256, version str16"),
    ("update", 2, "req", "data", "offset u32, data bytes"),
    ("update", 3, "req", "end", ""),
    ("update", 4, "req", "apply", ""),
    ("update", 5, "req", "status", ""),
    ("update", 5, "rsp", "status", "state u8, confirmed u8, version str16, rescue_present u8"),
]

# The payload of any response with mflags ERROR, whatever the service and op.
ERROR = "code u16, message utf8"

# Fixed structs that are not messages: array items and resource formats.
STRUCTS = {
    "list_entry": "res u16, type u8, flags u8, size u32, hash hash16",
    "tone_step": "freq_hz u16, duration_ms u16, duty u8",
    "res_image": "w u16, h u16, bpp u8, codec u8, data bytes",
    "res_anim": "w u16, h u16, frames u16, codec u8, data bytes",
    "res_anim_frame": "duration_ms u16, kind u8, size u32, data bytes",
    "res_font": "line_h u8, baseline u8, glyphs u16, data bytes",
    "res_glyph": "codepoint u32, w u8, h u8, x_off i8, y_off i8, advance u8, offset u32",
}

SIZES = {"u8": 1, "i8": 1, "u16": 2, "i16": 2, "u32": 4, "i32": 4, "u64": 8, "str16": 16, "hash16": 16, "sha256": 32}
TAILS = ("bytes", "utf8", "items")


def parse_fields(spec):
    """'a u8, b items:x[a]' -> [('a', 'u8', None, None), ('b', 'items', 'x', 'a')]"""
    out = []
    for part in filter(None, (p.strip() for p in spec.split(","))):
        name, ftype = part.split()
        item = count = None
        if ftype.endswith("]"):
            ftype, count = ftype[:-1].split("[")
        if ftype.startswith("items:"):
            ftype, item = ftype.split(":")
        assert ftype in SIZES or ftype in TAILS, part
        assert count is None or (ftype in ("items", "bytes") and count in [n for n, _, _, _ in out]), part
        out.append((name, ftype, item, count))
    for name, ftype, _, _ in out[:-1]:
        assert ftype not in TAILS, f"tail field {name} must be last"
    return out


def fixed_size(fields):
    return sum(SIZES.get(t, 0) for _, t, _, _ in fields)
