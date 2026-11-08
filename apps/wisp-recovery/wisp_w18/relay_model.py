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

Time, for the session-time guard: with a `clock` (tests.fake_temple.FakeClock or anything with
advance()), every exchange advances it by `exchange_s` (17.5 ms, as measured on hardware on
2026-11-06) and every empty G2TX by `idle_s` (the relay's poll bound). `hang_after_s` stops the
case that many seconds after the relay started (a wall-time cause), `hang_after_exchanges` after
that many temple exchanges (a per-exchange cause). Either way the stop looks like step F's.

The case's YHM4005 (recovery.md, "Long relay sessions"): with `watchdog_s` (20.0 on Jan's case)
the watchdog resets the case that many seconds after its last feed, which a relay start gives
(the bridge's first call into the case flash drives PB2 low). `feeds_watchdog` is the relay
variant: observed-33 never feeds it again, so the case stops `watchdog_s` after the relay
started, as on hardware; observed-33-feed feeds it every 2 s, so it never does. A watchdog reset
keeps SRAM and leaves the case in its ROM, which answers no relay frame: the same silence and
the same record as the stops above. `idle_s` stays the old relay's 12 s; the feeding relay's empty-G2TX
bound is about 31 s on hardware.

`not_idle` models the pogo switch read right after two quick case app restarts (W18 F1d split): the
bridge finds no seated-idle YHM baseline, selects no route, writes nothing and answers G2RQ with
the 13-byte G2RS of status 3, then resets the case.
"""

from __future__ import annotations

import struct

from . import pins

REGISTERS = struct.pack("<4I", 0x5, 0x0, 0x40, 0x4000C0)  # what Jan's case reported in step F
# YHM2510 registers as Jan's case reported them in step F (left route); registers 1 and 2 are
# status bits that change by themselves when a route is selected. Right: by analogy.
YHM_IDLE = bytes.fromhex("811104afaf03812033ff")
YHM_SELECTED = {0: bytes.fromhex("81100ca6af03c10333ff"), 1: bytes.fromhex("81100cafa603c10533ff")}
YHM_NOT_IDLE = bytes.fromhex("811004afaf03812033ff")  # register 1 not yet back to its idle 0x11


class RelayModel:
    def __init__(self, temple, hang_when=None, clock=None, exchange_s=0.0175, idle_s=12.0,
                 hang_after_s=None, hang_after_exchanges=None, watchdog_s=None, feeds_watchdog=False,
                 not_idle=False):
        self.temple = temple
        self.not_idle = not_idle
        self.hang_when = hang_when
        self.clock = clock
        self.exchange_s, self.idle_s = exchange_s, idle_s
        self.hang_after_s, self.hang_after_exchanges = hang_after_s, hang_after_exchanges
        self.watchdog_s, self.feeds_watchdog = watchdog_s, feeds_watchdog
        self.watchdog_reset = False
        self.t0 = clock() if clock else 0.0  # Go: the relay starts with its banner
        self.idles = 0
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
                if self.not_idle:  # baseline read, not allowlisted: no route, no write
                    for i, v in enumerate((0x47524247, 1, header[5], header[6], header[7], 0, 0x3FF)):
                        self._word(i, v)
                    self.record[56:66] = YHM_NOT_IDLE
                    self._exit(3, restore=False)
                    return
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
                if self._dies(frame):
                    self.state = "hung"
                    return
                if n:
                    self.sent += 1
                    reply = self.temple.exchange(frame)
                    self._word(10, n)
                elif hasattr(self.temple, "next_frame"):
                    reply = self.temple.next_frame()
                else:
                    self.idles += 1
                if not (len(reply) >= 4 and reply[:3] == b"\x5a\xa5\xff" and reply[3] in (8, 16, 24, 27)
                        and len(reply) == reply[3] + 5):
                    reply, status = b"", 2
                else:
                    self.record[86:86 + len(reply)] = reply
                console = b"G2RX" + bytes((status, len(reply))) + reply
                self.outbox += console + bytes((sum(console) & 255,))
            else:
                return

    def _dies(self, frame: bytes) -> bool:
        """Advance the clock by this exchange; True if the case stops during it."""
        if frame and self.hang_when is not None and self.hang_when(frame):
            return True
        if self.clock is not None:
            self.clock.advance(self.exchange_s if frame else self.idle_s)
            if self.hang_after_s is not None and self.clock() - self.t0 >= self.hang_after_s:
                return True
            if (self.watchdog_s is not None and not self.feeds_watchdog
                    and self.clock() - self.t0 >= self.watchdog_s):
                self.watchdog_reset = True  # last feed: the relay start
                return True
        return bool(frame) and self.hang_after_exchanges is not None and self.sent >= self.hang_after_exchanges

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
