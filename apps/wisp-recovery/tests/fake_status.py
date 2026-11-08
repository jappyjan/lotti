# SPDX-License-Identifier: MIT
"""A stand-in for the Wisp case-UART status protocol (G10 defines the real one in apps/wisp-fw)
and for a temple app that answers it, for boot-watch's tests. No hardware.

`FakeStatus` is a `wisp_w18.status.StatusProtocol`: it asks with a 9-byte frame in the loader's
request framing (the only shape the pinned case relay forwards besides 25 and 32 bytes) and reads
21-byte 5A A5 FF answers carrying a boot stage and an uptime. `BootingTemple` is the fake loader
of fake_temple.py whose app, once released by CONT, boots for `boot_s` seconds of the shared
virtual clock (answering nothing), then answers every status query, optionally sending frames by
itself or rebooting into the loader (its HELO) at `reboot_at_s`.
"""

from __future__ import annotations

import struct

from fake_temple import FakeLoaderLink
from wisp_w18 import loader, status

QUERY = b"WSTQ"
ANSWER = b"WSTA"


def frame_9(marker: bytes) -> bytes:
    body = bytes((0x7E, 0, 1, 4)) + marker
    return body + bytes((sum(body) & 255,))


def answer(stage: int, uptime_ms: int) -> bytes:
    body = bytes((0, 1, 3, 12)) + ANSWER + struct.pack("<II", stage, uptime_ms)
    frame = b"\x5a\xa5\xff" + bytes((len(body),)) + body
    return frame + bytes((sum(frame) & 255,))


class FakeStatus(status.StatusProtocol):
    name = "fake"

    def __init__(self, ready_stage: int = 3):
        self.ready_stage = ready_stage

    def request(self, index: int) -> bytes:
        return frame_9(QUERY)

    def decode(self, frame: bytes) -> dict | None:
        if len(frame) != 21 or frame[8:12] != ANSWER or frame[-1] != sum(frame[:-1]) & 255:
            return None
        stage, uptime = struct.unpack_from("<II", frame, 12)
        return {"stage": stage, "uptime_ms": uptime}

    def complete(self, answers: list[dict]) -> bool:
        return any(a["stage"] >= self.ready_stage for a in answers)


class BootingTemple(FakeLoaderLink):
    def __init__(self, mram, clock, boot_s: float = 2.0, reboot_at_s: float | None = None, chatter: bytes = b"",
                 **kw):
        super().__init__(mram, **kw)
        self.clock, self.boot_s, self.reboot_at_s, self.chatter = clock, boot_s, reboot_at_s, chatter
        self.released_at: float | None = None
        self.app_frames: list[bytes] = []

    def _since(self) -> float:
        return self.clock() - self.released_at

    def _app(self, frame: bytes) -> bytes:
        if self.reboot_at_s is not None and self._since() >= self.reboot_at_s:
            self.reboot_at_s = None
            self.released_at = self.clock()  # nobody holds it: the loader's window passes, the app boots again
            return loader.hello(self.challenge + 1)
        if frame:
            self.app_frames.append(frame)
        if self._since() < self.boot_s:
            return b""
        if frame == frame_9(QUERY):
            return answer(3, int(self._since() * 1000))
        return self.chatter

    def exchange(self, frame: bytes) -> bytes:
        if self.released_at is not None:
            return self._app(frame)
        reply = super().exchange(frame)
        if reply == loader.released():
            self.released_at = self.clock()
        return reply

    def next_frame(self) -> bytes:  # an empty G2TX: anything the app sends by itself
        return self._app(b"") if self.released_at is not None else b""
