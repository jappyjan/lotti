# SPDX-License-Identifier: MIT
"""Ways to reach a temple's patched loader, all with one interface:

    start() -> HELO frame     (the temple was reset and its loader sent its boot beacon)
    exchange(frame) -> frame  (one host frame to the temple, its one reply back)
    close()

CaseRelayLink: the real thing, the charging case on USB with drdaeman's relay in case SRAM.
Ported from drdaeman/g2-bootloader-patch @ 1d22097 tools/g2patch/link.py (MIT), on top of the
step-0 ROM client (wisp_case.rom, same allowlist: Get, Get ID, Read, Write SRAM, Go).

RelayPortLink: the same relay framing (G2RQ, G2TX/G2RX, G2EX/G2RS, byte for byte the code
CaseRelayLink runs) on a port that already speaks it: relay_model.RelayModel in tests and in
the Renode W18 harness. Only the ROM bring-up and the ROM-side record check are left out.

SocketLink: the Renode W18 model (apps/wisp-fw/renode/models/WispCaseLink.cs), lockstep.

Every link keeps its last frames (`recent`) and an exchange count, so a failed session can
report where it stopped even when the cleanup fails too (`diagnostics()`). It also records when
the relay (or, without a case, the link) started: `relay_started` on the link's clock, and the
same moment as `relay_started_t` in the diagnostics, on the time base of the frames' `t`. The
session-time guard (`--max-session-s`) measures from there.
"""

from __future__ import annotations

import hashlib
import socket
import struct
import time
from collections import deque

from wisp_case import pins as case_pins
from wisp_case.rom import read_exact
from wisp_case.transport import case_banner, enter_rom, serial_opener

from . import pins


class LinkError(RuntimeError):
    pass


RECENT = 16  # exchanges kept for the error report

# Exit status the pinned bridge reports in G2RS (and in its retained record, word 5) after the
# extension returns; from our disassembly of drdaeman's case.bin (bridge at 0x20010000).
RELAY_EXIT_STATUS = {
    0: "step-0 reply captured",
    1: "invalid G2RQ header",
    2: "unsupported G2RQ operation or route",
    3: "YHM read failed or its baseline is not allowlisted",
    4: "route selection failed; route restored",
    5: "step-0 temple request not sent; route restored",
    6: "relay ended, route restored (the normal end of a W18 relay session: the relay leaves no "
       "step-0 capture behind)",
    7: "route restore did not verify",
    16: "no G2RQ from the host",
}
RELAY_EXIT_OK = 6


class _Recent:
    """Ring buffer of the last exchanges: what was sent, what came back, when."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.t0 = clock()
        self.count = 0
        self.items: deque[dict] = deque(maxlen=RECENT)

    def begin(self, sent: bytes) -> dict:
        entry = {"n": self.count, "t": round(self.clock() - self.t0, 3), "sent": sent.hex(), "received": None}
        self.count += 1
        self.items.append(entry)
        return entry

    def report(self, relay_started: float | None = None) -> dict:
        out = {"exchanges": self.count, "seconds": round(self.clock() - self.t0, 1), "recent": list(self.items)}
        if relay_started is not None:
            out["relay_started_t"] = round(relay_started - self.t0, 3)
        return out


def decode_relay_record(retained: bytes) -> dict:
    """The pinned bridge's 160-byte retained record (case SRAM 0x20011A00), read back through
    the ROM after the session. Layout from our disassembly of the bridge and drdaeman's
    case_exchange.c: words 0..13, then the YHM2510 registers before / after route selection /
    after restore (10 bytes each) and the relay's capture of the last temple frame."""
    words = struct.unpack_from("<14I", retained)
    capture = retained[86:150]
    out = {
        "magic_ok": words[0] == 0x47524247,
        "phase": words[1],
        "phase_meaning": {1: "bridge running: its exit path (route restore, G2RS) never completed",
                          2: "bridge exit path ran"}.get(words[1], "unknown"),
        "operation": words[2], "route": words[3], "sequence": words[4],
        "yhm_reads_ok": {"before": f"{words[6]:#05x}", "selected": f"{words[7]:#05x}", "restored": f"{words[8]:#05x}"},
        "yhm_writes_ok": f"{words[9]:#05x}",  # bits 0-3 route selection, 4-8 restore
        "last_temple_send": words[10],  # bytes the relay last handed to the temple UART
        "capture_count": words[11],
        "uart_error_flags": words[13],
        "yhm": {"before": retained[56:66].hex(), "selected": retained[66:76].hex(), "restored": retained[76:86].hex()},
    }
    if words[1] == 2:
        out["exit_status"] = words[5]
        out["exit_meaning"] = RELAY_EXIT_STATUS.get(words[5], "unknown")
    if capture[:3] == b"\x5a\xa5\xff" and capture[3] in (8, 16, 24, 27):
        frame = capture[: capture[3] + 5]
        out["last_temple_frame"] = frame.hex()
        if frame[8:12] == b"RESP":
            kinds = ("ACK", "OUTPUT", "RESULT", "READY", "ERROR", "INPUT")
            out["last_temple_frame_meaning"] = f"RESP {kinds[frame[12]] if frame[12] < 6 else frame[12]} status {frame[13]}"
        else:
            out["last_temple_frame_meaning"] = frame[8:12].decode("ascii", "replace")
    if words[1] == 1:
        out["interpretation"] = (
            f"the case stopped executing the relay or the bridge: the last frame it handed to the temple was "
            f"{words[10]} bytes, and it forwarded nothing after that")
    return out


class SocketLink:
    """Lockstep TCP link to WispCaseLink in Renode: every temple frame is answered by exactly
    one host message (a frame, nothing, or detach)."""

    def __init__(self, port: int, host: str = "127.0.0.1", timeout: float = 600.0, connect_timeout: float = 120.0,
                 trace=None):
        deadline = time.monotonic() + connect_timeout
        while True:
            try:
                self.sock = socket.create_connection((host, port), timeout=timeout)
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(0.1)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.trace = trace  # optional open text file: one line per frame each way
        self.recent = _Recent()
        self.relay_started = None

    def _read(self, n: int) -> bytes:
        out = bytearray()
        while len(out) < n:
            chunk = self.sock.recv(n - len(out))
            if not chunk:
                raise LinkError("Renode closed the case link")
            out += chunk
        return bytes(out)

    def _frame(self) -> bytes:
        (n,) = struct.unpack("<H", self._read(2))
        frame = self._read(n)
        if self.trace:
            self.trace.write(f"< {frame.hex()}\n")
            self.trace.flush()
        return frame

    def _send(self, data: bytes) -> None:
        if self.trace:
            self.trace.write(f"> {data.hex()}\n")
            self.trace.flush()
        self.sock.sendall(struct.pack("<H", len(data)) + data)

    def start(self) -> bytes:
        self.relay_started = self.recent.clock()
        return self._frame()

    def exchange(self, frame: bytes) -> bytes:
        entry = self.recent.begin(frame)
        try:
            self._send(frame)
            reply = self._frame()
        except BaseException as error:
            entry["error"] = repr(error)
            raise
        entry["received"] = reply.hex()
        return reply

    def diagnostics(self) -> dict:
        return self.recent.report(self.relay_started)

    def next_frame(self) -> bytes:
        """Answer the pending temple frame with nothing and wait for the next one."""
        self._send(b"")
        return self._frame()

    def close(self) -> None:
        try:
            self.sock.sendall(struct.pack("<H", 0xFFFF))
        except OSError:
            pass
        self.sock.close()


class _RelayFraming:
    """Host side of drdaeman's case relay protocol on an open byte stream (`self.port`):
    G2RQ arms the relay, G2TX/G2RX carries one temple frame each way, G2EX ends it and the
    bridge answers G2RS [D link.py, PROTOCOL.md "Optional case USB relay"]."""

    port = None
    ready = False
    route = 0
    relay_started = None
    sleep = staticmethod(time.sleep)
    IDLE_TIMEOUT = 120.0  # s; the relay answers an empty G2TX after its own poll bound (18 s; ~31 s with the feed)

    def _init_recent(self, clock=time.monotonic) -> None:
        self.recent = _Recent(clock)

    def _arm(self) -> bytes:
        port = self.port
        port.timeout = 6.0
        if read_exact(port, len(pins.RELAY_BANNER), "relay banner") != pins.RELAY_BANNER:
            raise LinkError("relay banner mismatch")
        header = bytearray(b"G2RQ" + bytes((1, 2, self.route, pins.RELAY_SEQUENCE, 0, 0)))
        header[9] = sum(header[:9]) & 255
        port.write(bytes(header[:5]))
        port.flush()
        self.sleep(0.005)
        port.write(bytes(header[5:]))
        port.flush()
        port.timeout = 60.0
        registers = struct.unpack("<4I", read_exact(port, 16, "UART registers"))
        self.log({"case_uart_registers": [hex(r) for r in registers]})
        if read_exact(port, 11, "arm marker") != b"G2U2_ARMED\n":
            raise LinkError("relay did not arm (route not selected?)")
        beacon = read_exact(port, 21, "boot beacon")
        if read_exact(port, 12, "relay ready") != b"G2RAM_READY\n":
            raise LinkError("relay failed to arm")
        self.ready = True
        self.log({"helo": beacon.hex()})
        # Allow the temple to turn its half-duplex pins from TX to RX before HOLD [D link.py].
        self.sleep(0.03)
        return beacon

    def exchange(self, frame: bytes) -> bytes:
        if self.port is None or not self.ready:
            raise LinkError("relay is not running")
        if len(frame) not in (0, 9, 25, 32):
            raise ValueError("unsupported frame length")
        packet = b"G2TX" + bytes((len(frame),)) + frame
        packet += bytes((sum(packet) & 255,))
        entry = self.recent.begin(frame)
        try:
            self.port.write(packet)
            self.port.flush()
            head = read_exact(self.port, 6, "relay response")
            if head[:4] != b"G2RX" or head[5] > 32:
                raise LinkError(f"invalid relay header {head.hex()}")
            tail = read_exact(self.port, head[5] + 1, "temple response")
            entry["received"], entry["relay_status"] = tail[:-1].hex(), head[4]
            if tail[-1] != (sum(head) + sum(tail[:-1])) & 255:
                raise LinkError("relay checksum mismatch")
            if head[4]:
                raise LinkError(f"case relay status {head[4]}; the command outcome is unknown")
            return tail[:-1]
        except BaseException as error:
            entry["error"] = repr(error)
            raise

    def idle(self) -> tuple[int, bytes, float]:
        """One empty G2TX: the relay hands nothing to the temple, re-arms its pogo receiver (the
        same stock UART re-init as every exchange) and waits for a temple frame up to its poll
        bound. A held loader sends nothing, so the normal answer is G2RX status 2 with no frame.
        Keeps the relay running without temple traffic; returns (status, frame, seconds)."""
        if self.port is None or not self.ready:
            raise LinkError("relay is not running")
        packet = b"G2TX\0"
        packet += bytes((sum(packet) & 255,))
        entry = self.recent.begin(b"")
        entry["idle"] = True
        start = self.recent.clock()
        timeout, self.port.timeout = self.port.timeout, self.IDLE_TIMEOUT
        try:
            self.port.write(packet)
            self.port.flush()
            head = read_exact(self.port, 6, "relay response to an empty G2TX")
            if head[:4] != b"G2RX" or head[5] > 32:
                raise LinkError(f"invalid relay header {head.hex()}")
            tail = read_exact(self.port, head[5] + 1, "temple response")
            if tail[-1] != (sum(head) + sum(tail[:-1])) & 255:
                raise LinkError("relay checksum mismatch")
            entry["received"], entry["relay_status"] = tail[:-1].hex(), head[4]
            seconds = self.recent.clock() - start
            entry["seconds"] = round(seconds, 3)
            return head[4], tail[:-1], seconds
        except BaseException as error:
            entry["error"] = repr(error)
            raise
        finally:
            if self.port is not None:
                self.port.timeout = timeout

    def _exit_relay(self) -> int:
        """G2EX; the bridge restores the YHM route and answers G2RS. Returns its exit status."""
        port = self.port
        port.write(b"G2EX")
        port.flush()
        head = read_exact(port, 12, "restoration header")
        if head[:5] != b"G2RS\1" or head[9] > 64:
            raise LinkError(f"invalid restoration response {head.hex()}")
        tail = read_exact(port, head[9] + 1, "restoration tail")
        if (tail[-1] != (sum(head) + sum(tail[:-1])) & 255 or head[5:8] != bytes((2, self.route, pins.RELAY_SEQUENCE))
                or head[9] or head[10]):
            raise LinkError("invalid restoration framing")
        status = head[8]
        self.log({"relay_exit_status": status, "relay_exit_meaning": RELAY_EXIT_STATUS.get(status, "unknown")})
        if status != RELAY_EXIT_OK:
            raise LinkError(f"relay exit status {status}: {RELAY_EXIT_STATUS.get(status, 'unknown')}")
        return status

    def diagnostics(self) -> dict:
        return {**self.recent.report(self.relay_started), "events": list(getattr(self, "events", []))}


class RelayPortLink(_RelayFraming):
    """The relay framing on a port that already runs the relay (relay_model.RelayModel)."""

    def __init__(self, port, side: str = "left", log=None, clock=time.monotonic):
        self.port, self.route = port, case_pins.ROUTES[side]
        self.events: list[dict] = []
        self._log = log or (lambda event: None)
        self._init_recent(clock)

    def log(self, event: dict) -> None:
        self.events.append(event)
        self._log(event)

    def start(self) -> bytes:
        self.relay_started = self.recent.clock()  # the port already runs the relay
        return self._arm()

    def close(self) -> None:
        try:
            if self.ready:
                self._exit_relay()
        finally:
            self.ready = False
            self.port.close()


class CaseRelayLink(_RelayFraming):
    """USB -> case ROM -> drdaeman's relay in case SRAM -> pogo UART2 -> temple loader.

    start(): case app banner (1.2.57), ROM entry, case image hash, the pinned relay into SRAM
    (each block read back), Go; G2RQ selects the route; the relay resets the temple with Even's
    reset waveform and forwards its HELO. close(): G2EX, the bridge restores the YHM route and
    resets the case; ROM entry, the retained record is checked, the relay SRAM zeroed, the case
    reset into its own app (banner again). The case flash is never written."""

    def __init__(self, device: str, side: str, profile: str, image_cache=None, opener=serial_opener,
                 sleep=time.sleep, log=None):
        from .image import CACHE, build_relay

        if side not in pins.SIDES:
            raise ValueError("side must be left or right")
        self.device, self.side, self.route = device, side, case_pins.ROUTES[side]
        self.image = build_relay(profile, image_cache or CACHE)
        self.profile = profile
        self.opener, self.sleep = opener, sleep
        self.events: list[dict] = []
        self.port = None
        self.loader = None
        self.ready = False
        self.touched = False
        self._log = log or (lambda event: None)
        self._init_recent()

    def log(self, event: dict) -> None:
        self.events.append(event)
        self._log(event)

    def start(self) -> bytes:
        before = case_banner(self.device, self.opener, self.sleep)
        self.log({"case_version_before": before["version"]})
        if before["version"] != case_pins.CASE_VERSION:
            raise LinkError(f"case reports {before['version']!r}, expected {case_pins.CASE_VERSION}; nothing loaded")
        self.touched = True
        self.port, self.loader = enter_rom(self.device, self.image, self.opener, self.sleep, self.log)
        flash = self.loader.read_range(case_pins.CASE_IMAGE_BASE, case_pins.CASE_IMAGE_LENGTH)
        digest = hashlib.sha256(flash).hexdigest()
        self.log({"case_image_sha256": digest})
        if digest != case_pins.CASE_IMAGE_SHA256:
            raise LinkError("case flash is not the pinned B200 1.2.57 image; relay not loaded")
        for address, length, want in pins.CASE_PRE_CHECKS:
            if hashlib.sha256(flash[address - case_pins.CASE_IMAGE_BASE :][:length]).hexdigest() != want:
                raise LinkError(f"case flash differs at {address:#x}")
        self.loader.load_bridge()  # writes the relay (allowlisted: its own bytes or zeros)
        self.loader.go_bridge()
        # From here the case runs the relay from SRAM, not its flash firmware or its ROM.
        self.relay_started = self.recent.clock()
        self.log({"relay_started_t": round(self.relay_started - self.recent.t0, 3)})
        return self._arm()

    def close(self) -> None:
        errors = []
        try:
            if self.ready and self.port is not None:
                self._exit_relay()
        except Exception as error:  # noqa: BLE001 - collected, cleanup continues
            errors.append(repr(error))
        finally:
            if self.port is not None:
                self.port.close()
                self.port = None
            self.ready = False
        if self.touched:
            # The ROM part is retried once from a fresh NRST: the case's YHM4005 keeps resetting an
            # unfed case every ~20.5 s (relay stopped, or the old observed-33 relay), and a reset in
            # the middle of this ROM session cuts it. NRST alone always gives a ROM that takes a
            # fresh 0x7F sync, whatever the host sent the silent case before (G2TX, G2EX).
            # A retry reads the record only if the first attempt had not: that one may have zeroed it.
            checked = False
            for attempt in (1, 2):
                try:
                    self.sleep(0.3)
                    self.port, self.loader = enter_rom(self.device, self.image, self.opener, self.sleep, self.log)
                    if not checked:
                        retained = self.loader.read_memory(case_pins.RESULT_ADDRESS, case_pins.RESULT_LENGTH)
                        proof = self.loader.read_memory(case_pins.PROOF_ADDRESS, len(case_pins.PROOF))
                        words = struct.unpack_from("<14I", retained)
                        restored = (
                            proof == case_pins.PROOF
                            and words[:5] == (0x47524247, 2, 2, self.route, pins.RELAY_SEQUENCE)
                            and words[6:9] == (0x3FF,) * 3 and words[9] == 0x1FF and words[13] == 0
                            and retained[56:66] == retained[76:86]
                        )
                        self.log({"route_restored": restored, "relay_record": retained.hex(),
                                  "relay_record_decoded": decode_relay_record(retained)})
                        checked = True
                        if not restored:
                            errors.append("case route restoration not verified")
                    self.loader.clear_sram()
                    self.log({"case_sram_cleared": True})
                    break
                except Exception as error:  # noqa: BLE001
                    if attempt == 2:
                        errors.append(repr(error))
                    else:
                        self.log({"case_rom_cleanup_retry": repr(error)})
                finally:
                    if self.port is not None:
                        self.port.close()
                        self.port = None
            after = case_banner(self.device, self.opener, self.sleep)
            self.log({"case_version_after": after["version"]})
            if after["version"] != case_pins.CASE_VERSION:
                errors.append("case did not come back with its 1.2.57 banner")
        if errors:
            raise LinkError("; ".join(errors))
