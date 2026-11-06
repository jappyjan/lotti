# SPDX-License-Identifier: MIT
"""Host side of the patched bootloader's UART2 RAM loader: HELO/HOLD/OKAY/CONT/RLSD and the
sequential, non-retrying LOAD/DATA/RUN protocol.

Ported from drdaeman/g2-bootloader-patch @ 1d22097 (MIT): tools/g2patch/handshake.py,
auth.py and protocol.py (PROTOCOL.md). Rules kept from there: one outstanding request, never
retry or replay a request, never repeat RUN, after any ambiguity send only CONTINUE.
"""

from __future__ import annotations

import hmac
import struct
import zlib

from . import pins

VERSION = 1
LOAD, DATA, RUN, OUTPUT_ACK, INPUT_DATA = 1, 2, 3, 4, 5
ACK, OUTPUT, RESULT, READY, ERROR, INPUT = 0, 1, 2, 3, 4, 5
ERRORS = {1: "UNAVAILABLE", 2: "BAD_REQUEST", 3: "BAD_CRC", 4: "ABORTED", 5: "IO_ERROR"}


class LoaderError(RuntimeError):
    pass


def tag(marker: bytes, challenge: int, key: bytes = pins.AUTH_KEY) -> bytes:
    message = b"G2BOOT" + struct.pack("<II", VERSION, challenge) + marker
    return hmac.digest(key, message, "sha256")[:16]


def announcement(marker: bytes, payload: bytes = b"") -> bytes:
    body = bytes((0, 1, 3, 4 + len(payload))) + marker + payload
    return b"\x5a\xa5\xff" + bytes((len(body),)) + body + bytes(((len(body) - 2 + sum(body)) & 255,))


def host_request(marker: bytes, payload: bytes = b"") -> bytes:
    body = bytes((0x7E, 0, 1, 4 + len(payload))) + marker + payload
    return body + bytes(((len(body) + 1 + 0x7D + sum(body)) & 255,))


def hello(challenge: int) -> bytes:
    return announcement(b"HELO", struct.pack("<II", VERSION, challenge))


def hold(challenge: int) -> bytes:
    return host_request(b"HOLD", tag(b"HOLD", challenge))


def okay(challenge: int) -> bytes:
    return announcement(b"OKAY", tag(b"OKAY", challenge))


def cont() -> bytes:
    return host_request(b"CONT")


def released() -> bytes:
    return announcement(b"RLSD")


def decode_hello(frame: bytes) -> int:
    if len(frame) != 21:
        raise LoaderError(f"expected a 21-byte HELO, got {frame.hex()}")
    version, challenge = struct.unpack_from("<II", frame, 12)
    if version != VERSION:
        raise LoaderError(f"unsupported loader protocol version {version}")
    if frame != hello(challenge):
        raise LoaderError("invalid HELO framing or checksum")
    return challenge


def check_okay(frame: bytes, challenge: int) -> None:
    if not hmac.compare_digest(frame, okay(challenge)):
        raise LoaderError("invalid OKAY framing, checksum or HMAC")


def request(operation: int, payload: bytes = b"") -> bytes:
    if len(payload) > 22:
        raise ValueError("request payload exceeds 22 bytes")
    body = bytes((0x7E, 0, 1, 27)) + b"RQST" + bytes((operation,)) + payload.ljust(22, b"\0")
    return body + bytes(((32 + 0x7D + sum(body)) & 255,))


def reply(kind: int, status: int = 0, data: bytes = b"") -> bytes:
    body = bytes((0, 1, 3, 23)) + b"RESP" + bytes((kind, status)) + data.ljust(16, b"\0") + b"\0"
    return bytes((0x5A, 0xA5, 255, 27)) + body + bytes(((25 + sum(body)) & 255,))


def decode_reply(frame: bytes) -> tuple[int, int, bytes]:
    if len(frame) != 32 or frame[:12] != bytes((0x5A, 0xA5, 255, 27, 0, 1, 3, 23)) + b"RESP":
        raise LoaderError(f"invalid loader reply {frame.hex()}")
    if frame[-1] != (25 + sum(frame[4:-1])) & 255:
        raise LoaderError("loader reply checksum failed")
    kind, status = frame[12:14]
    if kind > INPUT or (kind in (OUTPUT, INPUT) and not 1 <= status <= 16):
        raise LoaderError("invalid reply kind or count")
    if kind in (ACK, READY) and status:
        raise LoaderError("invalid acknowledgement status")
    return kind, status, frame[14 : 14 + status] if kind == OUTPUT else frame[14:30]


class RemoteError(LoaderError):
    def __init__(self, status: int, result: int | None = None):
        self.status, self.result = status, result
        super().__init__(f"loader error {ERRORS.get(status, status)}, program result {result}")


class Client:
    """One held session. `exchange(frame) -> frame` sends one host frame and returns the
    temple's one reply (the case relay's G2TX/G2RX, or the Renode model's lockstep)."""

    def __init__(self, exchange):
        self.exchange = exchange
        self.failed = False

    def _exchange(self, packet: bytes):
        if self.failed:
            raise LoaderError("session failed; only CONTINUE and a fresh boot may follow")
        try:
            kind, status, data = decode_reply(self.exchange(packet))
            if kind == ERROR:
                raise RemoteError(status)
            if kind == RESULT and status:
                raise RemoteError(status, struct.unpack_from("<I", data)[0])
            return kind, status, data
        except BaseException:
            self.failed = True
            raise

    def _expect(self, packet: bytes, expected: int) -> None:
        kind, _status, _data = self._exchange(packet)
        if kind != expected:
            self.failed = True
            raise LoaderError(f"expected reply {expected}, got {kind}")

    def upload(self, code: bytes, entry: int = 0, arg0: int = 0, arg1: int = 0) -> None:
        if not 2 <= len(code) <= 512 or (len(code) | entry) & 1 or not 0 <= entry < len(code):
            raise ValueError("expected even 2..512 code bytes and an aligned entry inside it")
        self._expect(request(LOAD, struct.pack("<HHIII", len(code), entry, arg0, arg1, zlib.crc32(code))), ACK)
        for offset in range(0, len(code), 16):
            chunk = code[offset : offset + 16]
            self._expect(
                request(DATA, bytes((len(chunk),)) + chunk),
                READY if offset + len(chunk) == len(code) else ACK,
            )

    def execute(self, callback=None, source=None) -> tuple[int, bytes]:
        output = bytearray()
        try:
            kind, status, data = self._exchange(request(RUN))
            while kind in (OUTPUT, INPUT):
                if kind == OUTPUT:
                    output += data
                    if callback:
                        callback(data)
                    packet = request(OUTPUT_ACK)
                else:
                    chunk = bytes(source(status)) if source else b""
                    if len(chunk) > status:
                        raise LoaderError("input source exceeded the requested chunk size")
                    packet = request(INPUT_DATA, struct.pack("<B16sI", len(chunk), chunk, zlib.crc32(chunk)))
                kind, status, data = self._exchange(packet)
            if kind != RESULT:
                raise LoaderError("RUN did not produce a result")
            return struct.unpack_from("<I", data)[0], bytes(output)
        except BaseException:
            self.failed = True
            raise
