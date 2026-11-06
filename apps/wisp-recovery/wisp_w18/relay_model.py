# SPDX-License-Identifier: MIT
"""A model of the charging case running drdaeman's relay, behind a pyserial-like port, for
tests and the Renode W18 harness. Emulation only; it never touches hardware.

The relay loop is a port of drdaeman/g2-bootloader-patch @ 1d22097 src/case/case_exchange.c
(MIT): the same frame checks, the same breaks, one temple reply per G2TX, status 1/2. Around
it, what the pinned bridge does (our disassembly of case.bin): the G2_POGO_BRIDGE_V1 banner,
the G2RQ check, the USART registers and G2U2_ARMED, and on exit the route restore, its 160-byte
retained record and the G2RS answer. tests/test_relay.py checks the model against the real
relay binary running under Unicorn.

The temple behind it is anything with start() -> HELO frame and exchange(frame) -> frame: the
Python loader (tests/fake_temple.FakeLoaderLink) or Renode's real loader (links.SocketLink).

`hang_when(frame) -> bool` models the hardware failure of step F: the case stops for good while
it hands that host frame to the temple. Nothing answers after that, not even G2EX, and the
record stays in its "bridge running" state, as the record read back on 2026-11-06 shows.
"""

from __future__ import annotations

import struct

from . import pins

REGISTERS = struct.pack("<4I", 0x5, 0x0, 0x40, 0x4000C0)  # what Jan's case reported in step F
# YHM2510 registers as Jan's case reported them in step F (left route); registers 1 and 2 are
# status bits that change by themselves when a route is selected. Right: by analogy.
YHM_IDLE = bytes.fromhex("811104afaf03812033ff")
YHM_SELECTED = {0: bytes.fromhex("81100ca6af03c10333ff"), 1: bytes.fromhex("81100cafa603c10533ff")}


class RelayModel:
    def __init__(self, temple, hang_when=None):
        self.temple = temple
        self.hang_when = hang_when
        self.timeout = 6.0
        self.is_open = True
        self.state = "rq"
        self.inbox = bytearray()
        self.outbox = bytearray()
        self.sent = 0  # host frames handed to the temple
        self.route = 0
        self.record = bytearray(160)
        self.outbox += pins.RELAY_BANNER

    # --- the port the host sees ---
    def write(self, data: bytes) -> None:
        if self.state in ("hung", "reset"):
            return
        self.inbox += data
        self._run()

    def read(self, n: int) -> bytes:
        out = bytes(self.outbox[:n])
        del self.outbox[:n]
        return out  # nothing pending reads as a timeout, at once

    def flush(self) -> None:
        pass

    def close(self) -> None:
        """The host closed the port; the case has left the pogo line to the temple (for the
        Renode SocketLink: detach, so the temple runs on by itself)."""
        self.is_open = False
        if hasattr(self.temple, "close"):
            self.temple.close()

    # --- the retained record, laid out as the bridge's ---
    def _word(self, index: int, value: int) -> None:
        struct.pack_into("<I", self.record, 4 * index, value)

    def _take(self, n: int) -> bytes | None:
        if len(self.inbox) < n:
            return None
        out = bytes(self.inbox[:n])
        del self.inbox[:n]
        return out

    def _run(self) -> None:
        while True:
            if self.state == "rq":
                header = self._take(10)
                if header is None:
                    return
                if (header[:4] != b"G2RQ" or header[4] != 1 or header[8] != 0
                        or header[9] != sum(header[:9]) & 255 or header[5] != 2 or header[6] > 1):
                    self._exit(1 if header[:4] != b"G2RQ" else 2, restore=False)
                    return
                self.route = header[6]
                for i, v in enumerate((0x47524247, 1, header[5], header[6], header[7], 0, 0x3FF, 0x3FF, 0, 0xF)):
                    self._word(i, v)
                self.record[56:66] = YHM_IDLE
                self.record[66:76] = YHM_SELECTED[self.route]
                self.outbox += REGISTERS + b"G2U2_ARMED\n"
                beacon = self.temple.start()
                if len(beacon) != 21:
                    self._exit(6)
                    return
                self.outbox += beacon + b"G2RAM_READY\n"
                self.state = "loop"
            elif self.state == "loop":
                if len(self.inbox) < 4:
                    return
                head = bytes(self.inbox[:4])
                if head[:2] != b"G2" or head == b"G2EX" or head != b"G2TX":
                    del self.inbox[:4]
                    self._exit(6)
                    return
                if len(self.inbox) < 5 or len(self.inbox) < 6 + self.inbox[4]:
                    return
                n = self.inbox[4]
                if n not in (0, 9, 25, 32):
                    self._exit(6)
                    return
                packet = self._take(6 + n)
                frame = packet[5:5 + n]
                if packet[-1] != sum(packet[:-1]) & 255:
                    self._exit(6)
                    return
                if n and frame[:4] != bytes((0x7E, 0, 1, n - 5)):
                    self._exit(6)
                    return
                status = 0
                reply = b""
                if n:
                    if self.hang_when is not None and self.hang_when(frame):
                        self.state = "hung"
                        return
                    self.sent += 1
                    reply = self.temple.exchange(frame)
                    self._word(10, n)
                elif hasattr(self.temple, "next_frame"):
                    reply = self.temple.next_frame()
                if not (len(reply) >= 4 and reply[:3] == b"\x5a\xa5\xff" and reply[3] in (8, 16, 24, 27)
                        and len(reply) == reply[3] + 5):
                    reply, status = b"", 2
                else:
                    self.record[86:86 + len(reply)] = reply
                console = b"G2RX" + bytes((status, len(reply))) + reply
                self.outbox += console + bytes((sum(console) & 255,))
            else:
                return

    def _exit(self, status: int, restore: bool = True) -> None:
        """Back in the bridge: restore the route, record, G2RS, then the bridge resets the case."""
        if restore:
            self._word(8, 0x3FF)
            self._word(9, 0x1FF)
            self.record[76:86] = YHM_IDLE
        self._word(1, 2)
        self._word(5, status)
        head = bytearray(b"G2RS\x01" + bytes((2, self.route, pins.RELAY_SEQUENCE, status, 0, 0, 0)))
        self.outbox += bytes(head) + bytes((sum(head) & 255,))
        self.state = "reset"
