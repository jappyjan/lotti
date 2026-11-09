# SPDX-License-Identifier: MIT
"""Host side of the Wisp case-UART status protocol (docs/wisp/case-uart.md), for the Renode
harnesses (tests/boot/rung3.py, tests/boot/w18.py) and as the reference the host tools follow.
Pure Python, no I/O: requests to bytes, bytes to decoded replies. The firmware side is
src/case/wisp_case_proto.c; tests/case/ checks both against the same golden vectors.

Every request and reply fits the pinned case relay (apps/wisp-recovery wisp_w18/status.py):
requests of 9, 25 or 32 bytes in the loader's host framing `7E 00 01 n`, replies `5A A5 FF` of
13, 21, 29 or 32 bytes. `WispStatus` has the shape of status.py's `StatusProtocol` hook (request,
decode, complete), so boot-watch can register it as is.
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

STAGES = {1: "kernel", 2: "hal", 3: "bt-start", 4: "bt-up", 5: "bt-failed", 6: "bare-metal"}
DISPLAY_STATES = {0: "none", 1: "on", 2: "off", 3: "refused", 4: "failed"}
FLAGS = {0x01: "battery", 0x02: "vbus", 0x04: "charging", 0x08: "pmic-wdt", 0x10: "boot-services",
         0x20: "boot-status", 0x40: "boot-observe", 0x80: "session"}


def frame(payload: bytes) -> bytes:
    """A temple frame: 5A A5 FF L payload s, s = the sum of every byte before it."""
    head = b"\x5a\xa5\xff" + bytes([len(payload)]) + payload
    return head + bytes([sum(head) & 0xFF])


def host_request(op: int, args: bytes = b"") -> bytes:
    """7E 00 01 n 'WSP' op args c: the loader's host framing (c = len + 0x7D + sum)."""
    body = bytes((0x7E, 0, 1, 4 + len(args))) + MARKER + bytes((op,)) + args
    out = body + bytes(((len(body) + 1 + 0x7D + sum(body)) & 0xFF,))
    assert len(out) in REQUEST_LENGTHS, len(out)
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


def read_block(ask, block: int) -> bytes | None:
    """A whole block through `ask(request) -> reply frame`; None if the temple has none."""
    out, total = b"", None
    while total is None or len(out) < total:
        status, data = decode_reply(ask(read_request(block, len(out))), OP_READ)
        if status != OK:
            return None
        _b, offset, total, chunk = decode_read(data)
        if offset != len(out):
            raise ValueError(f"READ answered offset {offset}, asked {len(out)}")
        out += chunk[:min(READ_MAX, total - offset)]
    return out


STATUS_FMT = "<BBhBBHBBBbIIIIIIHhHBb12s"
assert struct.calcsize(STATUS_FMT) == 56


def decode_status(body: bytes) -> dict:
    (version, stage, bt, sensors, flags, mv, chg, vbus, kind, pmic_last, reset_cause, uptime, kicks, errors,
     feeds, sessions, confirms, confirm_result, block, display, display_err, rev) = struct.unpack(STATUS_FMT, body[:56])
    if version != 1:
        raise ValueError(f"status version {version}")
    return {
        "stage": STAGES.get(stage, stage), "bt_result": None if bt == 0x7FFF else bt, "sensors": sensors,
        "flags": [name for bit, name in FLAGS.items() if flags & bit], "flags_raw": flags,
        "battery_mv": mv, "charger_status": chg, "vbus_status": vbus, "image_kind": kind,
        "pmic_last": pmic_last, "reset_cause": reset_cause, "uptime_ms": uptime, "pmic_kicks": kicks,
        "pmic_errors": errors, "apollo_feeds": feeds, "sessions": sessions, "confirm_calls": confirms,
        "confirm_result": None if confirm_result == 0x7FFF else confirm_result, "boot_block_size": block,
        "display": DISPLAY_STATES.get(display, display), "display_err": display_err,
        "rev": rev.rstrip(b"\0").decode(errors="replace"),
    }


# --- diagnostics (rung4.md, "W24 result and analysis", D1/D2; src/boot/wisp_diag.h) -------------

OP_BOOTREP = 0x04
BLOCK_CLOCK, BLOCK_DIAG = 3, 4  # stage-0: its clock measurements, this boot's diagnostics record
IMAGE_KIND_STAGE0 = 16
RSTGEN_STAT_BITS = {0x1: "external", 0x2: "power-on", 0x4: "brown-out", 0x8: "sw-por", 0x10: "sw-poi",
                    0x20: "debugger", 0x40: "watchdog", 0x80: "bo-unregulated", 0x100: "bo-vddc",
                    0x200: "bo-vddf", 0x400: "bo-vdds", 0x1000: "sysresetreq"}
DIAG_STAGES = {0x00: "none", 0x10: "boot-start", 0x11: "boot-pmic-kick", 0x12: "boot-window",
               0x13: "boot-window-end", 0x14: "boot-nor", 0x15: "boot-mounted", 0x16: "boot-inputs",
               0x17: "boot-decided", 0x18: "boot-handoff", 0x19: "boot-reset", 0x1F: "boot-fault",
               0x40: "s0-reset", 0x41: "s0-init", 0x42: "s0-uart", 0x43: "s0-feed", 0x44: "s0-kick",
               0x45: "s0-loop", 0x46: "s0-measure", 0x47: "s0-reset-request", 0x4F: "s0-fault",
               0x80: "app-soc", 0x81: "app-soc-done", 0x82: "app-pre1", 0x83: "app-pre1-end", 0x84: "app-pre2",
               0x85: "app-stimer-ok", 0x86: "app-post", 0x87: "app-post-buses", 0x88: "app-post-end",
               0x89: "app-pmic-thread", 0x8A: "app-pmic-armed", 0x8B: "app-main", 0x8C: "app-case",
               0x8D: "app-hal", 0x8E: "app-display", 0x8F: "app-bt-start", 0x90: "app-bt-up",
               0x91: "app-bt-failed", 0x92: "app-idle", 0x93: "app-session", 0x9E: "app-stimer-dead",
               0x9F: "app-fault", 0xA0: "app-reset-request", 0xA1: "app-wdt-starved"}
REPORT_SOURCES = {0: "wisp-boot", 1: "app"}
REPORT_FLAGS = {0x01: "prev-valid", 0x02: "prev-fault", 0x04: "kick-ok", 0x08: "stimer-xt"}
DIAG_MAGIC = 0x47414457  # "WDAG"
DIAG_FMT = "<IHHIIIHHIIIIIIIIII"
DIAG_SIZE = struct.calcsize(DIAG_FMT)  # 64
CLOCK_FMT = "<BBBBIIIIIIIIIIIB3x"
CLOCK_SIZE = struct.calcsize(CLOCK_FMT)  # 52
TIMEBASES = {1: "stimer-xt", 2: "systick-assumed-96MHz"}
CLOCK_RESULTS = {0: "ok", 1: "watchdog COUNT never moved", 2: "16 ticks took over 3 s", 3: "not measured yet",
                 4: "implausible: LFRC outside 500-2000 Hz"}
COUNT_DIRECTIONS = {0: "not seen", 1: "down", 2: "up", 3: "both"}


def bootrep_request() -> bytes:
    return host_request(OP_BOOTREP)


def rstgen_stat_names(v: int) -> list[str]:
    return [n for bit, n in RSTGEN_STAT_BITS.items() if v & bit]


def diag_stage(code: int) -> str:
    return DIAG_STAGES.get(code, f"{code:#04x}")


def decode_boot_report(data: bytes) -> dict:
    """The 22 data bytes of a BOOTREP reply: why the previous boot ended and how far it got."""
    src, flags, boot, prev_stage, stat, ms, pc, lr, cfsr = struct.unpack_from("<BBBBIHIII", data, 0)
    prev_valid = bool(flags & 0x01)
    return {"source": REPORT_SOURCES.get(src, src), "flags": [n for bit, n in REPORT_FLAGS.items() if flags & bit],
            "boot": boot, "reset_cause": stat, "reset_cause_names": rstgen_stat_names(stat),
            "prev_stage": diag_stage(prev_stage) if prev_valid else None,
            "prev_stage_ms": (None if ms == 0xFFFF else ms) if prev_valid else None,
            "prev_fault": {"pc": pc, "lr": lr, "cfsr": cfsr} if flags & 0x02 else None}


def decode_diag_record(b: bytes, check: bool = True) -> dict:
    """wisp_diag.h's 64-byte record. With check, a bad magic or CRC raises ValueError."""
    (magic, version, size, boots, stat, stimer_start, stage, flags, stage_ticks, pc, lr, xpsr, cfsr, hfsr, bfar,
     mmfar, exc_return, crc) = struct.unpack(DIAG_FMT, b[:DIAG_SIZE])
    valid = magic == DIAG_MAGIC and version == 1 and size == DIAG_SIZE and zlib.crc32(b[:60]) & 0xFFFFFFFF == crc
    if check and not valid:
        raise ValueError(f"diagnostics record not valid (magic {magic:#x}, v{version}, size {size})")
    out = {"valid": valid, "boots": boots, "reset_cause": stat, "reset_cause_names": rstgen_stat_names(stat),
           "stimer_start": stimer_start, "stage": diag_stage(stage), "stage_ticks": stage_ticks,
           "stage_ms": stage_ticks * 1000 // 32768, "fault": None}
    if flags & 1:
        out["fault"] = {"pc": pc, "lr": lr, "xpsr": xpsr, "cfsr": cfsr, "hfsr": hfsr, "bfar": bfar, "mmfar": mmfar,
                        "exc_return": exc_return}
    return out


def decode_clock(b: bytes) -> dict:
    """stage-0's clock block (READ block 3, version 1, 52 bytes)."""
    (version, timebase, count, result, stcfg, wdt_cfg, probe, xt_ticks, core_cycles, lfrc_mhz, core_hz, wdt_ms,
     lfrc_min, lfrc_max, kick_last, direction) = struct.unpack(CLOCK_FMT, b[:CLOCK_SIZE])
    if version != 1:
        raise ValueError(f"clock block version {version}")
    return {"timebase": TIMEBASES.get(timebase, timebase), "measurements": count,
            "result": CLOCK_RESULTS.get(result, result), "stcfg": stcfg, "stimer_clksel": stcfg & 0xF,
            "wdt_cfg": wdt_cfg, "wdt_resval": (wdt_cfg >> 8) & 0xFF, "wdt_clksel": (wdt_cfg >> 24) & 7,
            "stimer_probe_ticks": probe, "window_xt_ticks": xt_ticks, "window_core_cycles": core_cycles,
            "lfrc_hz": lfrc_mhz / 1000, "core_hz": core_hz, "wdt_period_ms": wdt_ms,
            "lfrc_hz_min": lfrc_min / 1000, "lfrc_hz_max": lfrc_max / 1000, "pmic_kick_last": kick_last,
            "wdt_count_direction": COUNT_DIRECTIONS.get(direction, direction)}


# Wisp Boot's status block (apps/wisp-fw/src/boot/wisp_boot_status.h): version 1 is 612 bytes
# (native-0's Wisp Boot), version 2 692 (adds the diagnostics before the CRC).
BOOT_STATUS_SIZE_V1 = 612
BOOT_STATUS_SIZE = 692
BOOT_STATUS_SIZES = {1: BOOT_STATUS_SIZE_V1, 2: BOOT_STATUS_SIZE}
ACTIONS = {0: "run-app", 1: "rescue", 2: "run-app-degraded"}


def decode_boot_status(b: bytes) -> dict:
    if len(b) not in BOOT_STATUS_SIZES.values():
        raise ValueError(f"boot status is {len(b)} bytes")
    magic, version, size, build, nor_id, nor_res, mount, rec_res = struct.unpack_from("<IHHIIiii", b, 0)
    if magic != 0x54534257 or BOOT_STATUS_SIZES.get(version) != size or size != len(b):
        raise ValueError(f"boot status header {magic:#x} v{version} {size}")
    crc = struct.unpack_from("<I", b, size - 4)[0]
    if zlib.crc32(b[:size - 4]) & 0xFFFFFFFF != crc:
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
    out = {
        "version": version, "observe": bool(build & 1), "log": bool(build & 2), "nor_id": nor_id,
        "nor_result": nor_res, "mount_result": mount, "record_result": rec_res, "record": record.hex(), "stage": stage,
        "staging_present": bool(staging_present), "staging_id": staging_id, "staging_size": staging_size,
        "rescue_ok": bool(rescue_ok), "rescue_id": rescue_id, "rescue_size": rescue_size,
        "action": ACTIONS.get(action, action), "would_action": ACTIONS.get(would, would), "reason": reason,
        "inventory": inv, "inventory_truncated": bool(inv_trunc), "inventory_result": inv_res,
        "confirm_calls": confirm_calls, "confirm_result": confirm_result,
    }
    if version >= 2:
        stat, kick, answers, window_ms, prev_valid, uart, clksel, _res = struct.unpack_from("<IIHHBBBB", b, 608)
        out.update(rstgen_stat=stat, reset_cause_names=rstgen_stat_names(stat), pmic_kick=kick,
                   window_answers=answers, window_ms=window_ms, uart_result=uart, stimer_clksel=clksel,
                   prev_valid=bool(prev_valid),
                   prev=decode_diag_record(b[624:688], check=False) if prev_valid else None)
    return out


class WispStatus:
    """boot-watch's hook (apps/wisp-recovery wisp_w18/status.py StatusProtocol): asks IDENT until
    the app answers, then reads the app status (4 READs) and Wisp Boot's block (36 READs) once,
    then keeps asking IDENT. decode() returns None for frames that are not Wisp replies."""

    name = "wisp"

    def __init__(self):
        self.plan: list[bytes] = []

    def request(self, index: int) -> bytes:
        if self.plan:
            return self.plan.pop(0)
        return ident_request()

    def decode(self, f: bytes) -> dict | None:
        try:
            p = check_frame(f)
        except ValueError:
            return None
        if p[:3] != MARKER or len(f) not in REPLY_LENGTHS:
            return None
        op, status, data = p[3] & 0x7F, p[4], p[5:]
        out = {"op": op, "status": status}
        if status == OK and op == OP_IDENT:
            out.update(decode_ident(data))
            if not getattr(self, "_planned", False):
                self._planned = True
                self.plan = [read_request(BLOCK_STATUS, o) for o in range(0, 56, READ_MAX)] + \
                    [read_request(BLOCK_BOOT, o) for o in range(0, BOOT_STATUS_SIZE, READ_MAX)]
        elif status == OK and op == OP_READ:
            block, offset, total, chunk = decode_read(data)
            out.update(block=block, offset=offset, total=total,
                       data=chunk[:min(READ_MAX, total - offset)].hex())
        return out

    def complete(self, answers: list[dict]) -> bool:
        """Done once both blocks are complete (or Wisp Boot's is not available)."""
        got = {}
        for a in answers:
            if a.get("op") == OP_READ and a.get("status") == OK:
                got.setdefault(a["block"], {})[a["offset"]] = bytes.fromhex(a["data"])
            if a.get("op") == OP_READ and a.get("status") == E_NOTAVAIL:
                got.setdefault(BLOCK_BOOT, None)
        def full(block, size):
            parts = got.get(block)
            return parts is not None and sum(len(v) for v in parts.values()) >= size
        boot_done = BLOCK_BOOT in got and (got[BLOCK_BOOT] is None or full(BLOCK_BOOT, BOOT_STATUS_SIZE))
        return full(BLOCK_STATUS, 56) and boot_done
