# SPDX-License-Identifier: MIT
"""What `boot-watch` asks a booting temple app through the case relay (rung4.md §3, G2).

After CONT the patched loader hands off to the app in MRAM, and the case relay stays up until
G2EX: every G2TX hands one frame to the temple and returns the first temple frame within the
relay's poll bound. `boot-watch` uses that to watch the boot before it ends the session.

The questions are a pluggable `StatusProtocol`. The Wisp case-UART status protocol is G10's
(docs/wisp/case-uart.md, firmware in apps/wisp-fw): `wisp`, in case_uart.py, asks IDENT, reads the
app's status and Wisp Boot's block, and never sends RESET. This module only fixes what any
protocol must respect, because the pinned relay (drdaeman's case_exchange.c) enforces it in the
case:

  - a request is empty (listen only) or 9, 25 or 32 bytes starting 7E 00 01 n-5 (the loader's
    request framing); the stock version query `24 00 01 00 a7` cannot be sent this way;
  - a reply is a 5A A5 FF frame whose length byte is 8, 16, 24 or 27 (13, 21, 29 or 32 bytes in
    all); anything else reaches the host as "no frame" (relay status 2);
  - **a request without an answer blocks** (case_exchange.c `relay_receive`): the relay re-arms its
    temple receiver after sending and then waits, without reading the host port, for the first four
    temple bytes, up to its poll bound (64,000,000 polls: about 31 s with the YHM4005 feed, 18 s
    without). It ends early only on four bytes that are not a frame header or a UART error flag
    (status 2). So an unanswered request costs the rest of a boot in a reboot loop (the next frame
    is the loader's `HELO`) or the whole poll bound if the temple stays silent, and the host gets
    exactly one try per boot at a short window. The host must not send again before the answer:
    the relay would see the bytes only after the wait, and USART1 has a one-byte receive register.
    Bytes the temple sends while no exchange is pending are lost (the next exchange re-arms first).

A protocol can therefore schedule its requests: `anchor(t, kind)` is told when the boot was
released (`cont`, t = 0) and when each loader `HELO` came; `wait(t)` returns how long to wait
before the next request (None: the plain interval); `no_answer(t)` is told when an exchange ended
without a frame (status 2: the poll bound passed, or garbage).

Built in: `listen`, which sends nothing and records any frame the temple sends by itself. It is
safe against any temple. The loader's own HELO is recognised whatever the protocol: after CONT it
means the temple rebooted (a crash loop, a watchdog, or the PMIC's power cycle).

tests/fake_status.py has a fake protocol and the fake app that answers it.
"""

from __future__ import annotations

import time
from typing import Callable

from . import case_uart, loader

RELAY_REQUEST_LENGTHS = (9, 25, 32)
RELAY_REPLY_LENGTHS = (13, 21, 29, 32)


def relay_request_ok(frame: bytes) -> bool:
    """A frame the pinned relay hands to the temple (or b"", listen only)."""
    return not frame or (len(frame) in RELAY_REQUEST_LENGTHS and frame[:4] == bytes((0x7E, 0, 1, len(frame) - 5)))


def relay_reply_ok(frame: bytes) -> bool:
    """A temple frame the pinned relay passes back to the host."""
    return (len(frame) in RELAY_REPLY_LENGTHS and frame[:3] == b"\x5a\xa5\xff"
            and len(frame) == frame[3] + 5)


def is_loader_hello(frame: bytes) -> bool:
    return len(frame) == 21 and frame[:12] == loader.hello(0)[:12]


class StatusProtocol:
    """The hook. `request(i)` is the i-th frame to send (b"" = listen only), `decode(frame)` turns
    one temple frame into fields, or None if the frame is not this protocol's, and
    `complete(answers)` says when boot-watch has seen enough and may end the session early."""

    name = "?"

    def request(self, index: int) -> bytes:
        raise NotImplementedError

    def decode(self, frame: bytes) -> dict | None:
        raise NotImplementedError

    def complete(self, answers: list[dict]) -> bool:
        return False


class ListenOnly(StatusProtocol):
    """Sends nothing; records whatever 5A A5 FF frame the temple sends by itself."""

    name = "listen"

    def request(self, index: int) -> bytes:
        return b""

    def decode(self, frame: bytes) -> dict | None:
        return {"frame": frame.hex()}


# name -> factory. `wisp` is native-0's case-UART status (G10; tests/test_case_uart.py).
PROTOCOLS: dict[str, Callable[[], StatusProtocol]] = {"listen": ListenOnly, "wisp": case_uart.WispStatus}


def watch(link, protocol: StatusProtocol, duration_s: float, interval_s: float = 1.0, clock=time.monotonic,
          sleep=time.sleep, log=print) -> dict:
    """Ask `protocol`'s questions through the relay for `duration_s`, at most one every
    `interval_s`. Returns the events: each answer with its time since the watch started, the
    unanswered queries, and every loader HELO (a reboot)."""
    started = clock()
    out: dict = {"protocol": protocol.name, "answers": [], "unanswered": 0, "reboots_s": [], "foreign": []}
    index = 0
    if hasattr(protocol, "anchor"):
        protocol.anchor(0.0, "cont")
    first = protocol.wait(0.0) if hasattr(protocol, "wait") else None
    if first:
        sleep(min(first, duration_s))
    while clock() - started < duration_s:
        frame = protocol.request(index)
        if not relay_request_ok(frame):
            raise ValueError(f"{protocol.name}: request {frame.hex()} is not a frame the case relay forwards; "
                             "nothing sent")
        asked = clock()
        status, reply, _seconds = link.query(frame)
        t = round(clock() - started, 3)
        index += 1
        if status == 1:
            raise RuntimeError(f"the relay could not send query {index - 1} to the temple (status 1)")
        if status == 0 and is_loader_hello(reply):
            out["reboots_s"].append(t)
            if hasattr(protocol, "reset"):  # what it read so far belongs to the boot that ended
                protocol.reset()
                protocol.reboots = getattr(protocol, "reboots", 0) + 1
            if hasattr(protocol, "anchor"):
                protocol.anchor(t, "helo")
            log(f"boot-watch: t = {t:.1f} s: the loader's HELO, the temple rebooted")
        elif status == 0:
            decoded = protocol.decode(reply)
            if decoded is None:
                out["foreign"].append({"t": t, "frame": reply.hex()})
            else:
                decoded.setdefault("t", t)
                out["answers"].append({"t": t, **decoded})
                log(f"boot-watch: t = {t:.1f} s: {decoded}")
                if protocol.complete(out["answers"]):
                    out["complete"] = True
                    break
        else:
            out["unanswered"] += 1
            if hasattr(protocol, "no_answer"):
                protocol.no_answer(t)
        # The protocol may time its next request (a boot window it must hit), else the interval.
        scheduled = protocol.wait(clock() - started) if hasattr(protocol, "wait") else None
        wait = max(interval_s - (clock() - asked), 0.0) if scheduled is None else max(scheduled, 0.0)
        if clock() - started + wait >= duration_s:
            break
        if wait:
            sleep(wait)
    out["seconds"] = round(clock() - started, 1)
    out["queries"] = index
    if hasattr(protocol, "summary"):
        out["summary"] = protocol.summary(out["answers"])
    return out
