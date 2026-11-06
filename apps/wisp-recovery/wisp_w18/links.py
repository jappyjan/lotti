# SPDX-License-Identifier: MIT
"""Ways to reach a temple's patched loader, all with one interface:

    start() -> HELO frame     (the temple was reset and its loader sent its boot beacon)
    exchange(frame) -> frame  (one host frame to the temple, its one reply back)
    close()

CaseRelayLink: the real thing, the charging case on USB with drdaeman's relay in case SRAM.
Ported from drdaeman/g2-bootloader-patch @ 1d22097 tools/g2patch/link.py (MIT), on top of the
step-0 ROM client (wisp_case.rom, same allowlist: Get, Get ID, Read, Write SRAM, Go).

SocketLink: the Renode W18 model (apps/wisp-fw/renode/models/WispCaseLink.cs), lockstep.
"""

from __future__ import annotations

import hashlib
import socket
import struct
import time

from wisp_case import pins as case_pins
from wisp_case.rom import read_exact
from wisp_case.transport import case_banner, enter_rom, serial_opener

from . import pins


class LinkError(RuntimeError):
    pass


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
        return self._frame()

    def exchange(self, frame: bytes) -> bytes:
        self._send(frame)
        return self._frame()

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


class CaseRelayLink:
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
        self.port.write(packet)
        self.port.flush()
        head = read_exact(self.port, 6, "relay response")
        if head[:4] != b"G2RX" or head[5] > 32:
            raise LinkError("invalid relay header")
        tail = read_exact(self.port, head[5] + 1, "temple response")
        if tail[-1] != (sum(head) + sum(tail[:-1])) & 255:
            raise LinkError("relay checksum mismatch")
        if head[4]:
            raise LinkError(f"case relay status {head[4]}; the command outcome is unknown")
        return tail[:-1]

    def close(self) -> None:
        errors = []
        try:
            if self.ready and self.port is not None:
                port = self.port
                port.write(b"G2EX")
                port.flush()
                head = read_exact(port, 12, "restoration header")
                if head[:5] != b"G2RS\1" or head[9] > 64:
                    raise LinkError("invalid restoration response")
                tail = read_exact(port, head[9] + 1, "restoration tail")
                if (tail[-1] != (sum(head) + sum(tail[:-1])) & 255 or head[5:8] != bytes((2, self.route, pins.RELAY_SEQUENCE))
                        or head[9] or head[10]):
                    raise LinkError("invalid restoration framing")
                self.log({"relay_exit_status": head[8]})
        except Exception as error:  # noqa: BLE001 - collected, cleanup continues
            errors.append(repr(error))
        finally:
            if self.port is not None:
                self.port.close()
                self.port = None
            self.ready = False
        if self.touched:
            try:
                self.sleep(0.3)
                self.port, self.loader = enter_rom(self.device, self.image, self.opener, self.sleep, self.log)
                retained = self.loader.read_memory(case_pins.RESULT_ADDRESS, case_pins.RESULT_LENGTH)
                proof = self.loader.read_memory(case_pins.PROOF_ADDRESS, len(case_pins.PROOF))
                words = struct.unpack_from("<14I", retained)
                restored = (
                    proof == case_pins.PROOF and words[:5] == (0x47524247, 2, 2, self.route, pins.RELAY_SEQUENCE)
                    and words[6:9] == (0x3FF,) * 3 and words[9] == 0x1FF and words[13] == 0
                    and retained[56:66] == retained[76:86]
                )
                self.log({"route_restored": restored, "relay_record": retained.hex()})
                if not restored:
                    errors.append("case route restoration not verified")
                self.loader.clear_sram()
                self.log({"case_sram_cleared": True})
            except Exception as error:  # noqa: BLE001
                errors.append(repr(error))
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
