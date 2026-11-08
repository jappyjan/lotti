# SPDX-License-Identifier: MIT
"""The Wisp case-UART status protocol (docs/wisp/case-uart.md, rung4.md G10), host side, for
`boot-watch --protocol wisp`. Pure Python, no I/O.

A port of apps/wisp-fw/tests/boot/case_uart.py, the reference the firmware's codec
(src/case/wisp_case_proto.c) is tested against. The codec part is the same code; tests check it
against the same golden vectors and against the reference module itself, frame by frame.
`WispStatus` differs from the reference's hook in what a real relay needs: a READ that got no
answer is asked again (the reference asks each offset once and never completes if one is lost),
the watch ends only once both blocks are read and the BLE bring-up has finished (stage bt-up or
bt-failed), and `summary` decodes the blocks for the report.

Every request and reply fits the pinned case relay (status.py): requests of 9, 25 or 32 bytes in
the loader's host framing `7E 00 01 n`, replies `5A A5 FF` of 13, 21, 29 or 32 bytes. Nothing
here sends RESET: boot-watch only reads.
"""

from __future__ import annotations

import struct
import zlib

STOCK_VERSION_QUERY = bytes.fromhex("24000100a7")
MARKER = b"WSP"
OP_IDENT, OP_READ, OP_RESET = 0x01, 0x02, 0x03
BLOCK_STATUS, BLOCK_BOOT = 1, 2
OK, E_UNKNOWN, E_ARGS, E_NOTAVAIL = 0, 1, 2, 3
READ_MAX = 17
REQUEST_LENGTHS = (9, 25, 32)
REPLY_LENGTHS = (13, 21, 29, 32)

STAGES = {1: "kernel", 2: "hal", 3: "bt-start", 4: "bt-up", 5: "bt-failed"}
FLAGS = {0x01: "battery", 0x02: "vbus", 0x04: "charging", 0x08: "pmic-wdt", 0x10: "boot-services",
         0x20: "boot-status", 0x40: "boot-observe", 0x80: "session"}
# The left temple's staging file should still hold the pure stock 2.4.0.24 main from rung 1's
# return trip (rung4.md §2) [I]: Wisp Boot's block reports its preamble CRC word.
STOCK_STAGING_CRC_WORD = 0x971F4516


def frame(payload: bytes) -> bytes:
    """A temple frame: 5A A5 FF L payload s, s = the sum of every byte before it."""
    head = b"\x5a\xa5\xff" + bytes([len(payload)]) + payload
    return head + bytes([sum(head) & 0xFF])


def host_request(op: int, args: bytes = b"") -> bytes:
    """7E 00 01 n 'WSP' op args c: the loader's host framing (c = len + 0x7D + sum)."""
    body = bytes((0x7E, 0, 1, 4 + len(args))) + MARKER + bytes((op,)) + args
    out = body + bytes(((len(body) + 1 + 0x7D + sum(body)) & 0xFF,))
    if len(out) not in REQUEST_LENGTHS:
        raise ValueError(f"a {len(out)}-byte request does not fit the relay")
    return out


def ident_request() -> bytes:
    return host_request(OP_IDENT)


def read_request(block: int, offset: int, length: int = READ_MAX) -> bytes:
    return host_request(OP_READ, struct.pack("<BHB", block, offset, length) + bytes(12))


def reset_request() -> bytes:
    return host_request(OP_RESET, b"RSET" + bytes(12))


def check_frame(f: bytes) -> bytes:
    if len(f) < 5 or f[:3] != b"\x5a\xa5\xff" or len(f) != f[3] + 5 or f[-1] != sum(f[:-1]) & 0xFF:
        raise ValueError(f"not a 5A A5 FF frame: {f.hex()}")
    return f[4:-1]


def decode_version(f: bytes) -> dict:
    """The reply to stock's 0x24 query (stock layout). wisp = identity bytes 'WSP' (stock: 01 03 05)."""
    p = check_frame(f)
    if len(p) != 9 or p[0] != 0x24:
        raise ValueError(f"not a version frame: {f.hex()}")
    return {"wisp": p[1:4] == MARKER, "id": p[1:4].hex(), "version": tuple(p[4:8]), "hardware": p[8],
            "firmware": ".".join(str(b) for b in p[4:8])}


def decode_reply(f: bytes, op: int) -> tuple[int, bytes]:
    """(status, data) of a Wisp reply to `op`; the zero padding stays on data."""
    p = check_frame(f)
    if len(f) not in REPLY_LENGTHS or p[:3] != MARKER or p[3] != (op | 0x80):
        raise ValueError(f"not the Wisp reply to op {op:#x}: {f.hex()}")
    return p[4], p[5:]


def decode_ident(data: bytes) -> dict:
    major, minor, patch, kind, stage, flags, mv, bt = struct.unpack_from("<BBBBBBHh", data, 0)
    return {"version": (major, minor, patch), "image_kind": kind, "stage": STAGES.get(stage, stage),
            "flags": [n for bit, n in FLAGS.items() if flags & bit], "battery_mv": mv,
            "bt_result": None if bt == 0x7FFF else bt}


def decode_read(data: bytes) -> tuple[int, int, int, bytes]:
    """(block, offset, total, the bytes). The count is min(asked, total - offset)."""
    block, offset, total = struct.unpack_from("<BHH", data, 0)
    return block, offset, total, data[5:]


STATUS_FMT = "<BBhBBHBBBbIIIIIIHhHH12s"
STATUS_SIZE = struct.calcsize(STATUS_FMT)  # 56


def decode_status(body: bytes) -> dict:
    (version, stage, bt, sensors, flags, mv, chg, vbus, kind, pmic_last, reset_cause, uptime, kicks, errors,
     feeds, sessions, confirms, confirm_result, block, _res, rev) = struct.unpack(STATUS_FMT, body[:STATUS_SIZE])
    if version != 1:
        raise ValueError(f"status version {version}")
    return {
        "stage": STAGES.get(stage, stage), "bt_result": None if bt == 0x7FFF else bt, "sensors": sensors,
        "flags": [name for bit, name in FLAGS.items() if flags & bit], "flags_raw": flags,
        "battery_mv": mv, "charger_status": chg, "vbus_status": vbus, "image_kind": kind,
        "pmic_last": pmic_last, "reset_cause": reset_cause, "uptime_ms": uptime, "pmic_kicks": kicks,
        "pmic_errors": errors, "apollo_feeds": feeds, "sessions": sessions, "confirm_calls": confirms,
        "confirm_result": None if confirm_result == 0x7FFF else confirm_result, "boot_block_size": block,
        "rev": rev.rstrip(b"\0").decode(errors="replace"),
    }


# Wisp Boot's status block (apps/wisp-fw/src/boot/wisp_boot_status.h), 612 bytes.
BOOT_STATUS_SIZE = 612
ACTIONS = {0: "run-app", 1: "rescue", 2: "run-app-degraded"}


def decode_boot_status(b: bytes) -> dict:
    if len(b) != BOOT_STATUS_SIZE:
        raise ValueError(f"boot status is {len(b)} bytes")
    magic, version, size, build, nor_id, nor_res, mount, rec_res = struct.unpack_from("<IHHIIiii", b, 0)
    if magic != 0x54534257 or version != 1 or size != BOOT_STATUS_SIZE:
        raise ValueError(f"boot status header {magic:#x} v{version} {size}")
    crc = struct.unpack_from("<I", b, 608)[0]
    if zlib.crc32(b[:608]) & 0xFFFFFFFF != crc:
        raise ValueError("boot status CRC mismatch")
    record = b[28:44]
    stage, staging_present, rescue_ok, action, would, reason, inv_count, inv_trunc = b[44:52]
    staging_id, staging_size, rescue_id, rescue_size, inv_res = struct.unpack_from("<IIIIi", b, 52)
    inv = []
    for i in range(min(inv_count, 12)):
        o = 72 + 44 * i
        name = b[o:o + 32].rstrip(b"\0").decode(errors="replace")
        size_, crc_, res = struct.unpack_from("<IIi", b, o + 32)
        inv.append({"name": name, "size": size_, "crc": crc_, "result": res})
    confirm_calls, confirm_result = struct.unpack_from("<Ii", b, 600)
    return {
        "observe": bool(build & 1), "log": bool(build & 2), "nor_id": nor_id, "nor_result": nor_res,
        "mount_result": mount, "record_result": rec_res, "record": record.hex(), "stage": stage,
        "staging_present": bool(staging_present), "staging_id": staging_id, "staging_size": staging_size,
        "rescue_ok": bool(rescue_ok), "rescue_id": rescue_id, "rescue_size": rescue_size,
        "action": ACTIONS.get(action, action), "would_action": ACTIONS.get(would, would), "reason": reason,
        "inventory": inv, "inventory_truncated": bool(inv_trunc), "inventory_result": inv_res,
        "confirm_calls": confirm_calls, "confirm_result": confirm_result,
    }


BLOCK_SIZES = {BLOCK_STATUS: STATUS_SIZE, BLOCK_BOOT: BOOT_STATUS_SIZE}
TERMINAL_STAGES = ("bt-up", "bt-failed")


class WispStatus:
    """boot-watch's hook (status.StatusProtocol): IDENT until the app answers, then every READ
    of the app's status block and Wisp Boot's block that has no answer yet (a lost one is asked
    again on the next pass), then IDENT again. Complete once both blocks are whole (or Wisp Boot's
    is not available on this boot) and the app reported a finished BLE bring-up."""

    name = "wisp"

    def __init__(self):
        self.ident: dict | None = None
        self.parts: dict[int, dict[int, bytes]] = {BLOCK_STATUS: {}, BLOCK_BOOT: {}}
        self.totals = dict(BLOCK_SIZES)
        self.unavailable: set[int] = set()
        self.stage = None
        self._cursor = 0

    def _missing(self) -> list[tuple[int, int]]:
        out = []
        for block in (BLOCK_STATUS, BLOCK_BOOT):
            if block in self.unavailable:
                continue
            out += [(block, o) for o in range(0, self.totals[block], READ_MAX) if o not in self.parts[block]]
        return out

    def request(self, index: int) -> bytes:
        if self.ident is None:
            return ident_request()
        missing = self._missing()
        if not missing:
            return ident_request()
        # Round robin over what is still missing, so a lost answer is asked again after the rest.
        block, offset = missing[self._cursor % len(missing)]
        self._cursor += 1
        return read_request(block, offset)

    def decode(self, f: bytes) -> dict | None:
        try:
            p = check_frame(f)
        except ValueError:
            return None
        if p[:3] != MARKER or len(f) not in REPLY_LENGTHS or not p[3] & 0x80:
            return None
        op, status, data = p[3] & 0x7F, p[4], p[5:]
        out = {"op": op, "status": status}
        if status == OK and op == OP_IDENT:
            out.update(decode_ident(data))
            self.ident = out
            self.stage = out["stage"]
        elif op == OP_READ and status == OK:
            block, offset, total, chunk = decode_read(data)
            if block not in self.parts or offset % READ_MAX or offset >= total:
                return {**out, "error": f"unexpected READ answer: block {block}, offset {offset}, total {total}"}
            n = min(READ_MAX, total - offset)
            self.totals[block] = total
            self.parts[block][offset] = chunk[:n]
            self._cursor = 0
            out.update(block=block, offset=offset, total=total, data=chunk[:n].hex())
        elif op == OP_READ and status == E_NOTAVAIL:
            self.unavailable.add(BLOCK_BOOT)  # the app has no Wisp Boot block on this boot
        return out

    def block(self, block: int) -> bytes | None:
        """The whole block, or None while a part is missing."""
        parts = self.parts[block]
        if block in self.unavailable or any(o not in parts for o in range(0, self.totals[block], READ_MAX)):
            return None
        return b"".join(parts[o] for o in sorted(parts))[: self.totals[block]]

    def complete(self, answers: list[dict]) -> bool:
        return self.ident is not None and not self._missing() and self.stage in TERMINAL_STAGES

    def summary(self, answers: list[dict] | None = None) -> dict:
        """What the watch learned, decoded: IDENT, the app's status, Wisp Boot's block (with its
        CRC checked), and the facts W24 compares (rung4.md, the W24 runbook)."""
        out: dict = {"ident": self.ident}
        raw = self.block(BLOCK_STATUS)
        if raw is not None:
            try:
                out["status"] = decode_status(raw)
            except ValueError as error:
                out["status_error"] = str(error)
        if BLOCK_BOOT in self.unavailable:
            out["boot_error"] = "not available on this boot (no Wisp Boot status block)"
        else:
            raw = self.block(BLOCK_BOOT)
            if raw is not None:
                try:
                    out["boot"] = decode_boot_status(raw)
                except ValueError as error:
                    out["boot_error"] = str(error)
        boot = out.get("boot")
        if boot:
            out["staging_is_stock_2_4_0_24"] = boot["staging_present"] and boot["staging_id"] == STOCK_STAGING_CRC_WORD
            out["inventory"] = {f["name"]: {"size": f["size"], "crc32": f"{f['crc']:08x}", "result": f["result"]}
                                for f in boot["inventory"]}
        return out
