#!/usr/bin/env python3
"""Generates the golden vectors in packages/wisp-proto/vectors/.

Written independently of the C core (own CRCs, packer, codecs and a
reference receiver), so the C tests cross-check two implementations of
docs/wisp/protocol.md. Deterministic: no clock, own PRNG.

usage: gen_vectors.py [--check]   (--check fails if the checked-in files are stale)
"""
import json
import pathlib
import struct
import sys

from spec import ERROR, MESSAGES, SERVICES, STRUCTS, parse_fields

OUT = pathlib.Path(__file__).resolve().parents[2] / "wisp-proto" / "vectors"
MAGIC = 0x57
MAX_BODY = 4096
CTRL = 0x01  # fflags bit 0; bits 1-7 reserved
FFLAGS_RESERVED = 0xFE
ROUTE_RESERVED = 0xF0

# ---- checksums (bitwise, straight from the definitions) ----


def crc16_ccitt_false(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def crc32c_msb(data):
    crc = 0
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1EDC6F41) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def crc32_zlib(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
    return crc ^ 0xFFFFFFFF


class Rng:
    """xorshift32, so vectors don't depend on Python's random module."""

    def __init__(self, seed):
        self.s = seed

    def next(self, n):
        s = self.s
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        self.s = s
        return s % n

    def bytes(self, n):
        return bytes(self.next(256) for _ in range(n))


# ---- frames ----


def frame(svc, seq, body, route=0, fflags=0):
    head = struct.pack("<BBBBHH", MAGIC, svc, route, fflags, len(body), seq) + body
    return head + struct.pack("<H", crc16_ccitt_false(head))


def control(op, seq, route=0, frame_seq=0):
    """A CREDIT (op 2) or RESYNC (op 3) control frame."""
    return frame(0, frame_seq, struct.pack("<BBHH", op, 0, 0, seq), route, CTRL)


class Receiver:
    """Reference stream receiver: in-order delivery, control frames passed on
    in any state, a CREDIT for every duplicate, one RESYNC per run of
    discarded bytes and one per gap while in sync."""

    def __init__(self):
        self.buf = bytearray()
        self.last = 0xFFFF
        self.recovering = False
        self.bad_run = False
        self.frames, self.resyncs, self.controls, self.credits = [], [], [], []

    def bad(self):
        if not self.bad_run:
            self.bad_run = self.recovering = True
            self.resyncs.append(self.last)

    def skip(self):
        i = 1
        while i < len(self.buf) and self.buf[i] != MAGIC:
            i += 1
        del self.buf[:i]
        self.bad()

    def feed(self, chunk):
        self.buf += chunk
        while self.buf:
            if self.buf[0] != MAGIC:
                self.skip()
                continue
            if len(self.buf) < 8:
                return
            body_len = struct.unpack_from("<H", self.buf, 4)[0]
            if body_len > MAX_BODY or self.buf[2] & ROUTE_RESERVED or self.buf[3] & FFLAGS_RESERVED:
                self.skip()
                continue
            need = body_len + 10
            if len(self.buf) < need:
                return
            if crc16_ccitt_false(self.buf[: need - 2]) != struct.unpack_from("<H", self.buf, need - 2)[0]:
                self.skip()
                continue
            self.bad_run = False
            seq = struct.unpack_from("<H", self.buf, 6)[0]
            data = bytes(self.buf[:need])
            del self.buf[:need]
            ahead = (seq - self.last - 1) & 0xFFFF
            if data[3] & CTRL:
                self.controls.append(data)
            elif ahead == 0:
                self.last, self.recovering = seq, False
                self.frames.append(data)
            elif ahead >= 0x8000:
                self.credits.append(self.last)
            elif not self.recovering:
                self.recovering = True
                self.resyncs.append(self.last)


# ---- messages ----

INT_FMT = {"u8": "B", "i8": "b", "u16": "H", "i16": "h", "u32": "I", "i32": "i", "u64": "Q"}
MFLAGS = {"req": 0, "rsp": 1, "evt": 4, "err": 3}
STRUCT_FIELDS = {name: parse_fields(f) for name, f in STRUCTS.items()}


def pack(fields, values):
    out = b""
    for name, ftype, item, _ in fields:
        v = values[name]
        if ftype in INT_FMT:
            out += struct.pack("<" + INT_FMT[ftype], v)
        elif ftype == "str16":
            b = v.encode()
            assert len(b) <= 16, v
            out += b.ljust(16, b"\0")
        elif ftype in ("hash16", "sha256", "bytes"):
            out += bytes.fromhex(v)
        elif ftype == "utf8":
            out += v.encode()
        elif ftype == "items":
            out += b"".join(pack(STRUCT_FIELDS[item], it) for it in v)
    return out


def default(ftype):
    return {"str16": "", "hash16": "00" * 16, "sha256": "00" * 32, "bytes": "", "utf8": "", "items": []}.get(ftype, 0)


def sample(fields, k=0):
    """Distinct, byte-order-revealing values for every field."""
    vals = {}
    for i, (name, ftype, item, _) in enumerate(fields):
        n = k + i
        vals[name] = {
            "u8": 0x10 + n,
            "i8": -(n + 2),
            "u16": 0x0102 + 0x0303 * n,
            "i16": -(0x0123 + 0x0101 * n),
            "u32": (0x01020304 + 0x04030201 * n) & 0xFFFFFFFF,
            "i32": -(0x01020304 + n),
            "u64": 0x000A0B0C0D0E0F10 + n,
            "str16": f"{name}-{n}"[:16],
            "hash16": bytes(range(n, n + 16)).hex(),
            "sha256": bytes(range(0xA0 + n, 0xC0 + n)).hex(),
            "bytes": bytes(range(0xF0, 0xF0 + 5 + n % 4)).hex(),
            "utf8": "Wisp ✓ grüße",
        }.get(ftype) if ftype != "items" else [sample(STRUCT_FIELDS[item], n + j) for j in range(2)]
    for name, ftype, _, count in fields:  # counts are authoritative: make them match
        if count and ftype == "bytes":
            vals[name], vals[count] = bytes(range(0xE0, 0xEC)).hex(), 2
        elif count:
            vals[count] = len(vals[name])
    return vals


# Realistic values where the generic samples would be meaningless.
OVERRIDES = {
    ("session", "hello", "req"): {"proto_major": 0, "proto_minor": 2, "max_frame": 4096, "rx_window": 16384,
                                  "app_id": "dev.wisp.demo", "client_name": "wisp-sdk-ts"},
    ("session", "hello", "rsp"): {"proto_major": 0, "proto_minor": 2, "max_frame": 4096, "rx_window": 32768,
                                  "fw_name": "wisp", "fw_version": "0.1.0", "lens": 2, "caps": 0x000E07FF,
                                  "canvas_w": 640, "canvas_h": 480, "bpp": 4, "max_layers": 16,
                                  "res_bytes": 1048576, "persist_bytes": 8388608, "session_timeout_ms": 10000,
                                  "l2cap_psm": 0x0080},
    ("session", "credit", "req"): {"ack_seq": 0xFFFF},
    ("session", "resync", "req"): {"last_good_seq": 41},
    ("session", "ping", "req"): {"token": 0xDEADBEEF},
    ("session", "ping", "rsp"): {"token": 0xDEADBEEF},
    ("session", "time_sync", "req"): {"phone_ms": 1762300800123},
    ("session", "time_sync", "rsp"): {"phone_ms": 1762300800123, "glass_us": 9007199254740991},
}
NO_RESPONSE = {("session", "credit"), ("session", "resync")}


def message_case(name, svc, op, mflags, req, fields, values, hex_override=None, decode_only=False):
    body = struct.pack("<BBH", op, mflags, req) + (pack(fields, values) if hex_override is None else b"")
    case = {"name": name, "kind": "message", "svc": svc, "op": op, "mflags": mflags, "req": req, "fields": values,
            "hex": hex_override or body.hex()}
    if decode_only:
        case["decode_only"] = True
    return case


def message_vectors():
    files = {svc: [] for svc in SERVICES}
    kind_word = {"req": "request", "rsp": "response", "evt": "event"}
    for i, (svc, op, kind, name, spec) in enumerate(MESSAGES):
        fields = parse_fields(spec)
        values = OVERRIDES.get((svc, name, kind)) or sample(fields)
        req = 0 if kind == "evt" or (svc, name) in NO_RESPONSE else 0x0100 + i
        case_name = f"{svc}/{name.replace('_', '-')}-{kind_word[kind]}"
        files[svc].append(message_case(case_name, SERVICES[svc], op, MFLAGS[kind], req, fields, values))

    # Append-only rule: missing trailing fields read as defaults, unknown trailing bytes are ignored.
    hello = parse_fields(MESSAGES[0][4])
    full = OVERRIDES[("session", "hello", "req")]
    short = {n: (full[n] if i < 4 else default(t)) for i, (n, t, _, _) in enumerate(hello)}
    body = struct.pack("<BBH", 1, 0, 7) + pack(hello[:4], full)
    files["session"].append(message_case("session/hello-request-truncated", 0, 1, 0, 7, hello, short,
                                         body.hex(), decode_only=True))
    empty = {n: default(t) for n, t, _, _ in hello}
    files["session"].append(message_case("session/hello-request-empty", 0, 1, 0, 8, hello, empty,
                                         "01000800", decode_only=True))
    ping = parse_fields("token u32")
    body = struct.pack("<BBHI", 4, 0, 9, 0x01020304) + bytes.fromhex("aabbccdd")
    files["session"].append(message_case("session/ping-request-extra-bytes", 0, 4, 0, 9, ping, {"token": 0x01020304},
                                         body.hex(), decode_only=True))
    files["session"].append(message_case("session/hello-request-full-str16", 0, 1, 0, 10, hello,
                                         dict(full, app_id="0123456789abcdef", client_name="")))

    files["resource"] += list_vectors()
    files["audio"] += tone_vectors()
    files["sensor"] += sensor_vectors()
    files["session"].append(malformed_case("session/ping-request-field-cut-in-half", 0, 4, 0, 11, "aabb"))
    files["session"].append(malformed_case("session/hello-request-cut-inside-str16", 0, 1, 0, 12,
                                           pack(hello[:4], full).hex() + b"dev.wisp".hex()))

    err = parse_fields(ERROR)
    errors = [
        message_case("error/not-allowed-before-hello", 2, 3, MFLAGS["err"], 0x0042, err, {"code": 7, "message": ""}),
        message_case("error/unsupported-with-message", 0, 0x7F, MFLAGS["err"], 0x0043, err,
                     {"code": 1, "message": "unsupported op"}),
        message_case("error/hash-mismatch", 3, 3, MFLAGS["err"], 0xFFFF, err, {"code": 6, "message": "résumé ✗"}),
        malformed_case("error/code-cut-in-half", 2, 3, MFLAGS["err"], 0x0044, "07"),
    ]
    return {f"{svc}.json": cases for svc, cases in files.items()} | {"errors.json": errors}


def malformed_case(name, svc, op, mflags, req, payload_hex):
    """A body every decoder must reject as a bad payload (error 2)."""
    return {"name": name, "kind": "message", "svc": svc, "op": op, "mflags": mflags, "req": req, "malformed": True,
            "hex": (struct.pack("<BBH", op, mflags, req) + bytes.fromhex(payload_hex)).hex()}


def counted(prefix, items, stride_pad=0):
    """Items packed at their size plus stride_pad bytes (negative: cut short)."""
    out = b""
    for it in items:
        b = it + bytes(range(0xA0, 0xA0 + max(stride_pad, 0)))
        out += b[:len(it) + stride_pad] if stride_pad < 0 else b
    return prefix + out


# Lists: count is authoritative and each item is remaining / count bytes, so items can grow
# (readers skip what they don't know) or be shorter (missing fields read as 0).
def list_vectors():
    svc, op = SERVICES["resource"], 5
    fields = parse_fields(next(m[4] for m in MESSAGES if m[:4] == ("resource", 5, "rsp", "list")))
    entry = STRUCT_FIELDS["list_entry"]
    entries = [sample(entry, 3), sample(entry, 9)]
    packed = [pack(entry, e) for e in entries]
    head = struct.pack("<BBHH", op, MFLAGS["rsp"], 0x0201, 2)
    grown = message_case("resource/list-response-grown-items", svc, op, MFLAGS["rsp"], 0x0201, fields,
                         {"count": 2, "entries": entries}, counted(head, packed, 6).hex(), decode_only=True)
    short = [dict(e, size=0, hash="00" * 16) for e in entries]
    head = struct.pack("<BBHH", op, MFLAGS["rsp"], 0x0202, 2)
    shorter = message_case("resource/list-response-short-items", svc, op, MFLAGS["rsp"], 0x0202, fields,
                           {"count": 2, "entries": short}, counted(head, packed, -20).hex(), decode_only=True)
    empty = message_case("resource/list-response-empty", svc, op, MFLAGS["rsp"], 0x0203, fields,
                         {"count": 0, "entries": []})
    rsp = MFLAGS["rsp"]
    return [grown, shorter, empty,
            malformed_case("resource/list-response-count-doesnt-divide", svc, op, rsp, 0x0204,
                           struct.pack("<H", 5).hex() + b"".join(packed).hex()),
            malformed_case("resource/list-response-count-0-with-items", svc, op, rsp, 0x0205,
                           struct.pack("<H", 0).hex() + packed[0].hex()),
            malformed_case("resource/list-response-item-field-cut-in-half", svc, op, rsp, 0x0206,
                           struct.pack("<H", 2).hex() + counted(b"", packed, -19).hex())]


def tone_vectors():
    svc, op = SERVICES["audio"], 4
    fields = parse_fields(next(m[4] for m in MESSAGES if m[:4] == ("audio", 4, "req", "tone")))
    step = STRUCT_FIELDS["tone_step"]
    steps = [{"freq_hz": 2000, "duration_ms": 100, "duty": 50}, {"freq_hz": 0, "duration_ms": 50, "duty": 0},
             {"freq_hz": 3000, "duration_ms": 200, "duty": 30}]
    packed = [pack(step, x) for x in steps]
    head = struct.pack("<BBHB", op, 0, 0x0301, 3)
    return [message_case("audio/tone-request-grown-steps", svc, op, 0, 0x0301, fields,
                         {"count": 3, "steps": steps}, counted(head, packed, 3).hex(), decode_only=True),
            malformed_case("audio/tone-request-count-doesnt-divide", svc, op, 0, 0x0302,
                           "02" + b"".join(packed[:2]).hex()[:-2])]


def sensor_vectors():
    svc, op = SERVICES["sensor"], 3
    fields = parse_fields(next(m[4] for m in MESSAGES if m[:4] == ("sensor", 3, "evt", "data")))
    accel = struct.pack("<hhhH", 12, -980, 33, 0xBEEF) + struct.pack("<hhhH", 10, -990, 31, 0xBEEF)
    values = {"sensor": 1, "count": 2, "t0_us": 5000, "dt_us": 10000, "samples": accel.hex()}
    return [message_case("sensor/data-event-grown-samples", svc, op, MFLAGS["evt"], 0, fields, values),
            malformed_case("sensor/data-event-count-doesnt-divide", svc, op, MFLAGS["evt"], 0,
                           struct.pack("<BBII", 1, 4, 5000, 10000).hex() + accel[:6].hex())]


# ---- crc, frames, streams ----


def crc_vectors():
    inputs = [b"", b"123456789", b"\x00", b"\xff" * 4, bytes(range(256)), b"W" * 37]
    algos = {"crc16-ccitt-false": (crc16_ccitt_false, "<H"), "crc32c-msb": (crc32c_msb, "<I"),
             "crc32-zlib": (crc32_zlib, "<I")}
    cases = []
    for algo, (fn, fmt) in algos.items():
        for data in inputs:
            label = data.decode() if data == b"123456789" else f"{len(data)}-bytes-{data[:1].hex() or 'empty'}"
            cases.append({"name": f"crc/{algo}/{label}", "kind": "crc", "algo": algo, "input_hex": data.hex(),
                          "hex": struct.pack(fmt, fn(data)).hex()})
    return cases


def ping_body(token, req=1):
    return struct.pack("<BBHI", 4, 0, req, token)


def frame_vectors():
    rng = Rng(0x57495350)
    specs = [
        ("control-credit", 0, 0, 0, struct.pack("<BBHH", 2, 0, 0, 0x1234), CTRL),
        ("control-resync-from-right", 0, 0b1000, 0, struct.pack("<BBHH", 3, 0, 0, 0xFFFF), CTRL),
    ]
    specs += [(*x, 0) for x in [
        ("ping", 0, 0, 0, ping_body(0xDEADBEEF)),
        ("empty-body", 0, 0, 1, b""),
        ("route-right-from-left", 2, 0b0110, 2, struct.pack("<BBHB", 8, 0, 3, 0)),
        ("route-both", 2, 3, 0x1234, struct.pack("<BBHB", 12, 0, 0, 0)),
        ("seq-wrap", 0, 0, 0xFFFF, ping_body(1)),
        ("extension-svc", 0x80, 0, 5, b"\x01\x00\x00\x00" + rng.bytes(12)),
        ("magic-and-crc-lookalikes-in-body", 3, 0, 6, b"\x02\x00\x00\x00" + bytes([MAGIC]) * 9 + b"\x00\x57"),
        ("max-frame-body", 3, 0, 7, b"\x02\x00\x00\x00" + rng.bytes(MAX_BODY - 4)),
    ]]
    return [{"name": f"frame/{name}", "kind": "frame", "svc": svc, "route": route, "fflags": fflags, "seq": seq,
             "body_hex": body.hex(), "hex": frame(svc, seq, body, route, fflags).hex()}
            for name, svc, route, seq, body, fflags in specs]


def split(data, rng, max_chunk):
    out, i = [], 0
    while i < len(data):
        n = 1 + rng.next(max_chunk)
        out.append(data[i:i + n])
        i += n
    return out


def stream_vectors():
    rng = Rng(0xC0FFEE)
    f = [frame(0, s, ping_body(0x1000 + s, req=s + 1)) for s in range(8)]
    f += [frame(3, 8, b"\x02\x00\x00\x00" + bytes([MAGIC, 0, 0, 0, 0x10, 0, 9, 0]) + rng.bytes(40))]

    def flip(fr, i):
        b = bytearray(fr)
        b[i] ^= 0x5A
        return bytes(b)

    def with_len(fr, n):
        b = bytearray(fr)
        struct.pack_into("<H", b, 4, n)
        return bytes(b)

    def with_header(fr, i, v):
        """Header byte i set to v, CRC fixed up: only the header check can reject it."""
        b = bytearray(fr[:-2])
        b[i] = v
        return bytes(b) + struct.pack("<H", crc16_ccitt_false(b))

    credit = lambda seq, **kw: control(2, seq, **kw)  # noqa: E731
    resync = lambda seq, **kw: control(3, seq, **kw)  # noqa: E731

    # Magic bytes whose would-be headers fail on len or CRC.
    garbage = bytes([0x00, 0x13, MAGIC, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x08, MAGIC, MAGIC, 0x22])
    cases = [
        ("one-chunk", [b"".join(f[:4])], 4),
        ("byte-by-byte", [bytes([b]) for b in b"".join(f[:3])], 3),
        ("random-split", split(b"".join(f), rng, 23), 9),
        ("frame-spanning-chunks", [f[0][:3], f[0][3:] + f[1][:9], f[1][9:] + f[2], f[3][:-1], f[3][-1:]], 4),
        ("garbage-before-first-frame", split(garbage + b"".join(f[:3]), rng, 11), 3),
        ("duplicates-answered-with-credit", [f[0], f[1], f[1], f[0], f[2], f[2]], 3),
        ("bad-crc-then-retransmit", split(b"".join([f[0], f[1], flip(f[2], 12), f[3], f[4]] + f[2:6]), rng, 31), 6),
        ("bad-magic-then-retransmit", split(b"".join([f[0], flip(f[1], 0), f[2]] + f[1:4]), rng, 17), 4),
        ("lost-frame-gap-then-retransmit", [f[0], f[1], f[3], f[4], f[2], f[3], f[4], f[5]], 6),
        ("len-too-big-then-retransmit", split(b"".join([f[0], with_len(f[1], 0xFFFF), f[2], f[1], f[2]]), rng, 13), 3),
        # A corrupted len that still fits swallows the following frames until its CRC fails;
        # they're rescanned from the buffer.
        ("len-corrupted-swallows-frames", split(b"".join([f[0], with_len(f[1], 60)] + f[2:8] + f[1:8]), rng, 29), 8),
        # Frame 8's body holds a fake frame header; the rescan after its bad CRC must not trust it.
        ("magic-in-body-after-corruption", split(b"".join(f[:8] + [flip(f[8], 9), f[8]]), rng, 19), 9),
        ("truncated-frame-then-good", [f[0], f[1][:7], f[1], f[2]], 3),
        # 0.2: control frames are outside the sequence and act in any state.
        ("control-frames-interleaved", [f[0], credit(7), f[1], resync(3, frame_seq=0x4242), f[2]], 3),
        ("control-frames-during-recovery",
         split(b"".join([f[0], flip(f[1], 12), credit(5), f[2], resync(0), f[3], f[1], f[2], f[3]]), rng, 21), 4),
        ("control-frames-after-gap", [f[0], f[2], credit(9), f[3], resync(1), f[1], f[2], credit(10), f[3]], 4),
        ("control-frame-bad-crc-is-discarded", [f[0], flip(credit(4), 9), f[1], f[1]], 2),
        # The sender's window was full and our CREDIT got lost: its ack timeout resends everything
        # unacknowledged, and every duplicate is answered with a fresh CREDIT.
        ("lost-credit-full-window-timeout-resend", [b"".join(f[:4]), b"".join(f[:4]), f[4]], 5),
        ("reserved-fflags-bit-is-bad-frame", [f[0], with_header(f[1], 3, 0x02), f[2], f[1], f[2]], 3),
        ("reserved-route-bits-are-bad-frame", [f[0], with_header(f[1], 2, 0x10), f[1]], 2),
        ("reserved-bits-in-control-frame", [f[0], with_header(credit(0), 3, 0x81), f[1]], 2),
    ]
    out = []
    for name, chunks, delivered in cases:
        rx = Receiver()
        for c in chunks:
            rx.feed(c)
        assert len(rx.frames) == delivered, (name, len(rx.frames))
        out.append({"name": f"stream/{name}", "kind": "stream", "frames": [x.hex() for x in rx.frames],
                    "chunks": [c.hex() for c in chunks], "resyncs": rx.resyncs,
                    "controls": [x.hex() for x in rx.controls], "credits": rx.credits})
    return out


# ---- codecs ----


def raw4(px, w):
    stride = (w + 1) // 2
    rows = []
    for row in px:
        row = row + [0] * (stride * 2 - w)
        rows.append(bytes(row[i] << 4 | row[i + 1] for i in range(0, stride * 2, 2)))
    return b"".join(rows)


def rle4(px):
    flat = [v for row in px for v in row]
    out, i = bytearray(), 0
    while i < len(flat):
        n = 1
        while n < 16 and i + n < len(flat) and flat[i + n] == flat[i]:
            n += 1
        out.append((n - 1) << 4 | flat[i])
        i += n
    return bytes(out)


def lz4_assemble(seqs):
    """seqs: [(literals, offset, match_len)], the last one (literals, 0, 0)."""
    out = bytearray()

    def length(n):
        while n >= 255:
            out.append(255)
            n -= 255
        out.append(n)

    for lit, off, ml in seqs:
        m = ml - 4 if ml else 0
        out.append(min(len(lit), 15) << 4 | min(m, 15))
        if len(lit) >= 15:
            length(len(lit) - 15)
        out += lit
        if ml:
            out += struct.pack("<H", off)
            if m >= 15:
                length(m - 15)
    return bytes(out)


def lz4_decode(data):
    out, i = bytearray(), 0
    while True:
        tok = data[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                lit += data[i]
                i += 1
                if data[i - 1] != 255:
                    break
        out += data[i:i + lit]
        i += lit
        if i == len(data):
            return bytes(out)
        off = struct.unpack_from("<H", data, i)[0]
        i += 2
        ml = tok & 15
        if ml == 15:
            while True:
                ml += data[i]
                i += 1
                if data[i - 1] != 255:
                    break
        for _ in range(ml + 4):
            out.append(out[-off])


def lz4_naive(data):
    """Greedy longest-match LZ4 block, O(n^2); obeys the end-of-block rules."""
    seqs, anchor, i = [], 0, 0
    while i + 12 <= len(data):
        best, off = 0, 0
        for ref in range(max(0, i - 0xFFFF), i):
            n = 0
            while i + n < len(data) - 5 and data[ref + n] == data[i + n]:
                n += 1
            if n > best:
                best, off = n, i - ref
        if best >= 4:
            seqs.append((data[anchor:i], off, best))
            i += best
            anchor = i
        else:
            i += 1
    block = lz4_assemble(seqs + [(data[anchor:], 0, 0)])
    assert lz4_decode(block) == data
    return block


def box_image():
    w, h = 32, 16
    px = [[0] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            if y in (0, h - 1) or x in (0, w - 1):
                px[y][x] = 15
            elif x // 2 == y:
                px[y][x] = 8
            elif 4 <= y <= 6 and 10 <= x <= 25:
                px[y][x] = x - 10
    return px, w, h


# The box image compressed by upstream liblz4 1.9.4 (LZ4_compress_HC, block format).
LIBLZ4_BOX = ("1bff010038f0880001004b0ff0008810002b00881000a300880123456789abcdef10002b008810002a01881000064400"
              "0410002b008810002b008810002b008810002b008810002b008810002b008810003700880feb0050ffffffffff")


def codec_vectors():
    rng = Rng(0xB0B)
    images = {
        "single-pixel": [[9]],
        "odd-width-padding": [[1, 2, 3], [4, 5, 6]],
        "blank-64x8": [[0] * 64 for _ in range(8)],
        "runs-cross-rows": [[7] * 5, [7] * 5, [7, 7, 3, 3, 3]],
        "run-of-17": [[15] * 17],
        "gradient-16x2": [list(range(16)), list(range(15, -1, -1))],
        "noise-7x5": [[rng.next(16) for _ in range(7)] for _ in range(5)],
        "sparse-text-like": [[(15 if (x * 7 + y * 3) % 11 == 0 else 0) for x in range(40)] for y in range(6)],
    }
    cases = []
    bad_rle = {  # runs must cover exactly w x h pixels, never RAW4's padding nibble
        "runs-cover-padding-nibble": (3, 2, "0102030004050600"),
        "one-pixel-short": (3, 2, "010203040506"[:-2]),
        "one-pixel-too-many": (3, 2, "01020304050606"),
        "last-run-too-long": (4, 1, "f7"),
        "empty": (1, 1, ""),
    }
    for name, (w, h, hexdata) in bad_rle.items():
        cases.append({"name": f"rle4/{name}", "kind": "codec", "codec": 1, "w": w, "h": h, "malformed": True,
                      "hex": hexdata})
    for name, px in images.items():
        w, h = len(px[0]), len(px)
        pixels = raw4(px, w).hex()
        cases.append({"name": f"raw4/{name}", "kind": "codec", "codec": 0, "w": w, "h": h, "pixels_hex": pixels,
                      "hex": pixels})
        cases.append({"name": f"rle4/{name}", "kind": "codec", "codec": 1, "w": w, "h": h, "pixels_hex": pixels,
                      "hex": rle4(px).hex()})

    def lz4_case(name, codec, block, w, h, pixels):
        cases.append({"name": f"{'lz4' if codec == 2 else 'lz4-rle'}/{name}", "kind": "codec", "codec": codec,
                      "w": w, "h": h, "pixels_hex": pixels.hex(), "hex": block.hex(), "decode_only": True})

    lit = bytes(range(0x10, 0x10 + 40))
    blocks = {
        "literals-only": [(bytes.fromhex("0123456789abcdef"), 0, 0)],
        "literal-length-exactly-15": [(lit[:15], 0, 0)],
        "literal-length-270": [(rng.bytes(270), 0, 0)],
        "overlapping-match-offset-1": [(b"\xab", 1, 31), (b"\x00" * 8, 0, 0)],
        "match-length-19": [(lit[:20], 20, 19), (lit[:5], 0, 0)],
        "match-length-300": [(b"\x12\x34", 2, 300), (b"\x00" * 6, 0, 0)],
        "offset-above-255": [(bytes(range(256)) + bytes(range(44)), 300, 20), (b"\xee" * 12, 0, 0)],
    }
    for name, seqs in blocks.items():
        block = lz4_assemble(seqs)
        out = lz4_decode(block)
        lz4_case(name, 2, block, 2 * len(out), 1, out)

    px, w, h = box_image()
    box = raw4(px, w)
    assert lz4_decode(bytes.fromhex(LIBLZ4_BOX)) == box
    lz4_case("liblz4-box-32x16", 2, bytes.fromhex(LIBLZ4_BOX), w, h, box)

    lz4_case("naive-box-32x16", 2, lz4_naive(box), w, h, box)
    block = lz4_naive(rle4(px))
    assert lz4_decode(block) == rle4(px)
    lz4_case("box-32x16", 3, block, w, h, box)
    return cases


def main():
    files = {"crc.json": crc_vectors(), "frames.json": frame_vectors(), "streams.json": stream_vectors(),
             "codecs.json": codec_vectors()} | message_vectors()
    texts = {OUT / name: json.dumps(cases, indent=2, ensure_ascii=False) + "\n" for name, cases in files.items()}
    if "--check" in sys.argv:
        stale = [p.name for p, t in texts.items() if not p.exists() or p.read_text(encoding="utf-8") != t]
        if stale:
            sys.exit("stale vectors, run tools/gen_vectors.py: " + ", ".join(stale))
        return
    OUT.mkdir(parents=True, exist_ok=True)
    for path, text in texts.items():
        path.write_text(text, encoding="utf-8")
    print(f"wrote {sum(len(c) for c in files.values())} cases to {OUT}")


if __name__ == "__main__":
    main()
