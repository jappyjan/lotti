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

Known limits of the reads (the firmware's, not this module's): the app fills its 56-byte block
afresh for every READ, so `uptime_ms` (bytes 16-19) and `sessions` (32-35), which cross a 17-byte
boundary, can be torn by a few ms or one count. Wisp Boot's block is copied once per READ at
offset 0; a lost offset-0 READ asked again later takes a new copy, and the block CRC then shows
whether the parts belong together.
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


STATUS_FMT = "<BBhBBHBBBbIIIIIIHhHBb12s"
STATUS_SIZE = struct.calcsize(STATUS_FMT)  # 56


def decode_status(body: bytes) -> dict:
    (version, stage, bt, sensors, flags, mv, chg, vbus, kind, pmic_last, reset_cause, uptime, kicks, errors,
     feeds, sessions, confirms, confirm_result, block, display, display_err, rev) = struct.unpack(STATUS_FMT, body[:STATUS_SIZE])
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


BLOCK_SIZES = {BLOCK_STATUS: STATUS_SIZE, BLOCK_BOOT: BOOT_STATUS_SIZE, BLOCK_CLOCK: CLOCK_SIZE, BLOCK_DIAG: DIAG_SIZE}
TERMINAL_STAGES = ("bt-up", "bt-failed", "bare-metal")


class WispStatus:
    """boot-watch's hook (status.StatusProtocol). First, at every boot, the boot report (BOOTREP,
    rung4.md W24 analysis D2): Wisp Boot answers it in a window of about 300 ms (until 100 ms after
    its last answer, at most 1 s) that opens right after the loader hands off, the app later; a temple that reboots
    in a loop thus says, at each boot, why the previous one ended. Then IDENT until the app answers,
    then every READ of the app's status block and Wisp Boot's block (and, for stage-0, its clock
    block and diagnostics record) that has no answer yet (a lost one is asked again on the next
    pass), then IDENT again. Complete once the blocks are whole (or Wisp Boot's is not available on
    this boot) and the app reported a finished bring-up (BLE up or failed, or stage-0's bare-metal
    stage). Every boot report of the watch is kept in `reports`, across reboots.

    Timing (rung4.md, "W24b results"): the relay blocks on a request nobody answers (status.py), so
    there is one try per boot at Wisp Boot's window, and it has to be aimed. The loader hands off
    at once after CONT, and `HELO_WINDOW_S` after its HELO when nobody holds it; Wisp Boot opens its
    window a few ms after the hand-off (watchdog arm, record, PMIC kick, UART2 set-up). The report
    is asked `report_at[k]` s after that release, k = the boots so far whose try went unanswered,
    cycling, until Wisp Boot answers one; then that offset is kept. IDENT waits `APP_AFTER_REPORT_S` after the report, so it
    does not land in Wisp Boot's window (which ignores it) or in its NOR scan before the hand-off.
    If Wisp Boot stops answering at a kept offset on two boots in a row, the sweep resumes.
    W24b's tool asked ~15 ms after each HELO, inside the loader's window (after CONT: before Wisp
    Boot's UART set-up), and never again on that boot."""

    name = "wisp"

    # The patched loader's HELO window: PROBE_WAIT_TICKS = 512 ticks of its 1 kHz FreeRTOS tick
    # (drdaeman's bootloader.c; W24 measured the first HELO after CONT ~0.5 s early).
    HELO_WINDOW_S = 0.512
    # When to ask after the release, per boot, cycling: each try hits a window that opened up to
    # 0.3 s before it, so these cover a window start from about -0.15 to 0.95 s after the release.
    REPORT_AT_S = (0.15, 0.35, 0.55, 0.75, 0.95)
    # After the report: Wisp Boot's window stays 100 ms, its NOR scan follows, then the hand-off and
    # stage-0's UART set-up. A request in between is lost and blocks the relay.
    APP_AFTER_REPORT_S = 2.0

    def __init__(self, report_at: tuple[float, ...] | None = None):
        self.report_at = tuple(report_at) if report_at else self.REPORT_AT_S
        self.reports: list[dict] = []
        self.report_locked: float | None = None  # the offset that got an answer
        self.misses = 0  # boots whose one report try got no answer: each moves report_at on by one
        self.locked_misses = 0  # misses in a row at the kept offset
        self.report_asked = 0
        self.report_missed = False
        self.report = None
        self.reset()
        self.reboots = 0
        self.anchor(0.0, "cont")

    def reset(self) -> None:
        """Forget everything read so far: status.watch calls it when the loader's HELO shows that
        the temple rebooted, so the summary never mixes two boots."""
        if self.report_asked and self.report is None:
            self._missed()
        self.report_missed = False
        self.ident: dict | None = None
        self.report: dict | None = None  # this boot's boot report
        self.report_asked = 0
        self.report_offset: float | None = None
        self.report_answered_at: float | None = None
        self.report_late_asked = False  # BOOTREP asked once more after an app's IDENT
        self.early_status: bytes | None = None  # block 1 as read before the BLE bring-up ended
        self.parts: dict[int, dict[int, bytes]] = {BLOCK_STATUS: {}, BLOCK_BOOT: {}, BLOCK_CLOCK: {}, BLOCK_DIAG: {}}
        self.totals = dict(BLOCK_SIZES)
        self.unavailable: set[int] = set()
        self.stage = None
        self._cursor = 0

    # --- timing (status.watch's scheduling hooks) ---
    def anchor(self, t: float, kind: str) -> None:
        """A boot: released by CONT at t (kind "cont", the watch's first) or a loader HELO received
        at t (each one a new boot)."""
        self.boot_index = self.boot_index + 1 if kind == "helo" else 0
        self.released = t + (self.HELO_WINDOW_S if kind == "helo" else 0.0)
        self.now = t

    def _offset(self) -> float:
        if self.report_locked is not None:
            return self.report_locked
        return self.report_at[self.misses % len(self.report_at)]

    def _missed(self) -> None:
        if not self.report_missed:
            self.report_missed = True
            self.misses += 1
            if self.report_locked is not None:
                self.locked_misses += 1
                if self.locked_misses >= 2:  # the kept offset was marginal: sweep again
                    self.report_locked, self.locked_misses = None, 0

    def at(self, t: float) -> None:
        """status.watch: an answer came at t (decode follows)."""
        self.now = t

    def report_due(self) -> bool:
        return self.report is None and self.report_asked == 0

    def wait(self, t: float) -> float | None:
        """Seconds to wait before the next request, or None for the plain interval."""
        self.now = t
        if self.report_due():
            return self.released + self._offset() - t
        if self.report_answered_at is not None and self.ident is None:
            due = self.report_answered_at + self.APP_AFTER_REPORT_S - t
            return due if due > 0 else None
        return None

    def no_answer(self, t: float) -> None:
        """The exchange ended without a frame (the relay's poll bound): the temple is up and silent,
        so whatever the report try missed, go on with IDENT."""
        self.now = t
        if self.report_asked and self.report is None:
            self._missed()

    def _blocks(self) -> tuple[int, ...]:
        if self.ident and self.ident.get("image_kind") == IMAGE_KIND_STAGE0:
            return (BLOCK_STATUS, BLOCK_BOOT, BLOCK_CLOCK, BLOCK_DIAG)
        return (BLOCK_STATUS, BLOCK_BOOT)

    def _missing(self) -> list[tuple[int, int]]:
        out = []
        for block in self._blocks():
            if block in self.unavailable:
                continue
            out += [(block, o) for o in range(0, self.totals[block], READ_MAX) if o not in self.parts[block]]
        return out

    def request(self, index: int) -> bytes:
        if self.report_due():
            self.report_asked += 1
            self.report_offset = self._offset()
            return bootrep_request()
        if self.ident is None:
            return ident_request()
        if self.report is None and not self.report_late_asked and self.ident.get("image_kind") == IMAGE_KIND_STAGE0:
            # Wisp Boot's window was missed: stage-0 answers the report too.
            self.report_late_asked = True
            return bootrep_request()
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
        try:
            if status == OK and op == OP_BOOTREP:
                out.update(decode_boot_report(data))
                self.report = out
                self.report_answered_at = self.now
                if out["source"] == "wisp-boot" and self.report_offset is not None:
                    self.report_locked, self.locked_misses = self.report_offset, 0
                    out["asked_s_after_release"] = round(self.report_offset, 3)
                out["reboots_before"] = self.reboots
                self.reports.append(out)  # status.watch adds its time ("t") to this same dict
                return out
            if op == OP_BOOTREP:
                # An app without the boot report (native-0's codec answers status 1) or without a
                # Wisp Boot block (status 3): nothing more to ask on this boot.
                return out
            if status == OK and op == OP_IDENT:
                out.update(decode_ident(data))
            elif op == OP_READ and status == OK:
                block, offset, total, chunk = decode_read(data)
        except struct.error:
            return {**out, "error": f"reply too short: {f.hex()}"}
        if status == OK and op == OP_IDENT:
            self.ident = out
            if out["stage"] in TERMINAL_STAGES and self.stage not in TERMINAL_STAGES and self.parts[BLOCK_STATUS]:
                # The app's block was (partly) read during the bring-up: read it again, so the
                # summary has its counters after the bring-up too (the first read is kept).
                self.early_status = self.block(BLOCK_STATUS)
                self.parts[BLOCK_STATUS] = {}
            self.stage = out["stage"]
        elif op == OP_READ and status == OK:
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
        out: dict = {"ident": self.ident, "reboots_reset": self.reboots, "boot_report": self.report,
                     "boot_reports": self.reports}
        for key, raw in (("status", self.block(BLOCK_STATUS)), ("status_early", self.early_status)):
            if raw is not None:
                try:
                    out[key] = decode_status(raw)
                except ValueError as error:
                    out[f"{key}_error"] = str(error)
        if BLOCK_BOOT in self.unavailable:
            out["boot_error"] = "not available on this boot (no Wisp Boot status block)"
        else:
            raw = self.block(BLOCK_BOOT)
            if raw is not None:
                try:
                    out["boot"] = decode_boot_status(raw)
                except ValueError as error:
                    out["boot_error"] = str(error)
        for key, block, decoder in (("clock", BLOCK_CLOCK, decode_clock), ("diag", BLOCK_DIAG, decode_diag_record)):
            if block in self._blocks():
                raw = self.block(block)
                if raw is not None:
                    try:
                        out[key] = decoder(raw)
                    except ValueError as error:
                        out[f"{key}_error"] = str(error)
        boot = out.get("boot")
        if boot:
            out["staging_is_stock_2_4_0_24"] = boot["staging_present"] and boot["staging_id"] == STOCK_STAGING_CRC_WORD
            out["inventory"] = {f["name"]: {"size": f["size"], "crc32": f"{f['crc']:08x}", "result": f["result"]}
                                for f in boot["inventory"]}
        return out
