# SPDX-License-Identifier: MIT
"""Host side of the webflasher's read-only pogo bridge (G2RQ/G2RS) and the temple reply.

Ported from evenRealities-webflasher src/lib/pogoBridge.js @ 2fcdb88 (MIT): request and
response framing, the retained-result proof, and the 5A A5 FF version frame.
"""

from __future__ import annotations

import struct

from . import pins
from .rom import RefusedError

SEQUENCE = 0x42


def temple_request(operation: int, bridge: bytes) -> bytes:
    """The exact bytes the pinned bridge puts on the temple's UART for this operation,
    read from the image itself. Refuses anything not on the read-only allowlist."""
    if operation not in pins.BRIDGE_OPERATION_ALLOWLIST:
        raise RefusedError(f"bridge operation {operation:#04x} is not on the read-only allowlist")
    offset, length, opcode, _name = pins.TEMPLE_REQUESTS[operation]
    request = bridge[offset : offset + length]
    if len(request) != length or request[0] != opcode:
        raise RefusedError("pinned bridge does not embed the expected temple request")
    if request[0] not in pins.TEMPLE_READ_ONLY_OPCODES:
        raise RefusedError(f"temple opcode {request[0]:#04x} is not on the read-only allowlist")
    return request


def make_request(operation: int, route: str, bridge: bytes, sequence: int = SEQUENCE) -> bytes:
    temple_request(operation, bridge)  # raises unless allowlisted
    if route not in pins.ROUTES:
        raise RefusedError(f"unknown route {route!r}")
    request = bytearray(b"G2RQ" + bytes((1, operation, pins.ROUTES[route], sequence, 0, 0)))
    request[9] = sum(request[:9]) & 0xFF
    return bytes(request)


def parse_response(head: bytes, tail: bytes, request: bytes) -> dict:
    raw = head + tail
    if len(head) != 12 or head[:5] != b"G2RS\x01":
        raise ValueError(f"invalid bridge response header {head.hex()}")
    stored = head[9]
    if stored > 64 or len(tail) != stored + 1:
        raise ValueError("invalid bridge capture length")
    if raw[-1] != sum(raw[:-1]) & 0xFF:
        raise ValueError("bridge response checksum mismatch")
    if raw[5:8] != request[5:8]:
        raise ValueError("bridge response does not echo the request")
    return {
        "raw": raw,
        "operation": raw[5],
        "route": raw[6],
        "sequence": raw[7],
        "status": raw[8],
        "status_text": pins.BRIDGE_STATUS.get(raw[8], "unknown"),
        "uart_errors": raw[10],
        "captured": raw[12 : 12 + stored],
    }


def validate_retained(result: bytes, proof: bytes, response: dict, operation: int, route: str) -> dict:
    """Check the bridge's own record in SRAM (read back after its reset) against the USB
    reply: same run, every YHM register restored, the expected number of temple bytes."""
    if proof != pins.PROOF:
        raise ValueError("bridge execution proof was not retained")
    if len(result) != pins.RESULT_LENGTH or result[:4] != b"GBRG":
        raise ValueError("retained bridge result magic is invalid")
    (progress, op, rt, seq, status, baseline_mask, selected_mask, restored_mask, write_mask,
     transmitted, total, stored, errors) = struct.unpack_from("<13I", result, 4)
    baseline, restored = result[56:66], result[76:86]
    if progress != 2:
        raise ValueError("retained bridge run is incomplete")
    if (op, rt) != (operation, pins.ROUTES[route]):
        raise ValueError("retained operation or route differs")
    if (seq, status, errors) != (response["sequence"], response["status"], response["uart_errors"]):
        raise ValueError("retained result differs from its USB response")
    if stored > 64 or result[86 : 86 + stored] != response["captured"]:
        raise ValueError("retained temple bytes differ from the USB response")
    summary = {
        "baseline": baseline.hex(),
        "restored": restored.hex(),
        "baseline_mask": baseline_mask,
        "selected_mask": selected_mask,
        "restored_mask": restored_mask,
        "write_mask": write_mask,
        "temple_bytes_sent": transmitted,
        "uart_errors": errors,
    }
    _offset, length, _opcode, _name = pins.TEMPLE_REQUESTS[operation]
    if status == 0:
        if (baseline_mask, selected_mask, restored_mask, write_mask) != (0x3FF, 0x3FF, 0x3FF, 0x1FF):
            raise ValueError(f"YHM register access incomplete: {summary}")
        if transmitted != length or total != stored or errors or baseline != restored:
            raise ValueError(f"YHM restoration or transport proof failed: {summary}")
        summary["yhm_restored"] = True
    elif status == 3:
        if (selected_mask, restored_mask, write_mask, transmitted, total, stored, errors) != (0,) * 7:
            raise ValueError(f"status 3 without a clean zero-write record: {summary}")
        summary["yhm_restored"] = "untouched"
    else:
        summary["yhm_restored"] = write_mask == 0 or (restored_mask == 0x3FF and baseline == restored)
    return summary


def decode_version(frame: bytes) -> dict:
    """5A A5 FF 09 24 xx xx xx v0 v1 v2 v3 hw sum (sum = byte sum of all before it)."""
    if len(frame) < 5 or frame[:3] != b"\x5a\xa5\xff":
        raise ValueError("temple reply is not a 5A A5 FF frame")
    if len(frame) != frame[3] + 5:
        raise ValueError("temple reply length does not match its header")
    if frame[-1] != sum(frame[:-1]) & 0xFF:
        raise ValueError("temple reply checksum mismatch")
    if len(frame) != 14 or frame[4] != 0x24:
        raise ValueError("temple reply is not a version (0x24) frame")
    return {
        "firmware": ".".join(str(b) for b in frame[8:12]),
        "hardware_revision": frame[12],
    }
