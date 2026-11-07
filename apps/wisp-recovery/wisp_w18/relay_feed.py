# SPDX-License-Identifier: MIT
"""The case relay's YHM4005 feed: our own code (data/case_relay_feed.S, assembled to
data/case_relay_feed.bin), appended to drdaeman's relay, and the six places of the relay that
are pointed at it. docs/wisp/recovery.md, "The relay feeds the case watchdog".

The case's YHM4005 external watchdog resets the case 20 s (+-10 %) after the last falling edge
on PB2. The case app makes one every 5 s; the ROM loader and the relay made none, so every
relay session stalled about 20 s after the relay started. With this patch the relay drives PB2
low for 4.5 ms every 2.0 s, timed by TIM6, from inside every loop it can wait in.

`apply(relay)` works on any image with drdaeman's layout: the full relay (Even's waveform
filled in) or the repository's template (waveform zeroed), so the tests can run the patched
relay under emulation without the cached case firmware. Every site is checked for the exact
bytes it replaces, and nothing at or below the relay's own end moves: the retained record,
PROOF and the G2RQ buffer (0x20011900) stay where the tool and the bridge expect them.
"""

from __future__ import annotations

import hashlib
import struct
from pathlib import Path

from . import pins

DATA = Path(__file__).with_name("data")

BASE = 0x2001_1584  # = RELAY_ADDRESS + RELAY_BYTES: right after the relocated waveform stubs
LIMIT = 0x2001_1900  # the bridge's G2RQ buffer; the feed code must end before it
BIN_SHA256 = "e78a88bb83947ae05bae319635ec7a75d996a50c0818ecd055f99a939ab7e87b"
BIN_BYTES = 288

# Symbols of case_relay_feed.S as linked at BASE (arm-none-eabi-nm).
FEED_START = 0x2001_1584
FEED_TICK = 0x2001_15EC
POLL_BRIDGE_RX = 0x2001_1616
POLL_BEACON = 0x2001_162C
POLL_TEMPLE_RX = 0x2001_1642
POLL_HOST_RX = 0x2001_1658
FED_DELAY = 0x2001_166E
FED_DELAY_COUNTER = 0x2001_1680  # `subs r4, #1` of fed_delay's loop (the emulator fast-forwards it)
END = BASE + BIN_BYTES

# (relay address, the 4 bytes there in drdaeman's relay, the new target, what it was)
SITES = (
    (0x2001_0032, bytes.fromhex("00f0d9f9"), FEED_START, "bl 0x200103e8 (bridge init, at relay start)"),
    (0x2001_031C, bytes.fromhex("d0690f21"), POLL_BRIDGE_RX, "ldr r0, [r2, #28]; movs r1, #15 (bridge host read)"),
    (0x2001_074C, bytes.fromhex("d9690f24"), POLL_BEACON, "ldr r1, [r3, #28]; movs r4, #15 (HELO wait)"),
    (0x2001_08B2, bytes.fromhex("0220002b"), POLL_TEMPLE_RX, "movs r0, #2; cmp r3, #0 (temple frame wait)"),
    (0x2001_09BC, bytes.fromhex("26683707"), POLL_HOST_RX, "ldr r6, [r4, #0]; lsls r7, r6, #28 (relay host read)"),
    (0x2001_0232, bytes.fromhex("00f0f7f9"), FED_DELAY, "bl 0x20010624 (the wait before the bridge's reset)"),
)

# The only absolute addresses the feed code uses (its literal pool), and the only calls it makes.
PERIPHERALS = {0x4002_1034: "RCC_IOPENR (RCC_APBENR1 at +8)", 0x5000_0400: "GPIOB", 0x4000_1000: "TIM6",
               0x4000_1010: "TIM6_SR"}
CALLS = {0x2001_03E8: "the bridge's init", FEED_TICK: "feed_tick"}


class FeedError(ValueError):
    pass


def blob() -> bytes:
    data = (DATA / "case_relay_feed.bin").read_bytes()
    if hashlib.sha256(data).hexdigest() != BIN_SHA256 or len(data) != BIN_BYTES:
        raise FeedError("case_relay_feed.bin failed its pin")
    return data


def apply(relay: bytes) -> bytes:
    """drdaeman's relay (any YHM profile) -> the same relay feeding the case's YHM4005."""
    from .image import bl_encode

    if len(relay) != pins.RELAY_BYTES or pins.RELAY_ADDRESS + len(relay) != BASE:
        raise FeedError("not a relay with drdaeman's layout")
    image = bytearray(relay)
    for address, old, target, _what in SITES:
        at = address - pins.RELAY_ADDRESS
        if bytes(image[at : at + 4]) != old:
            raise FeedError(f"relay bytes at {address:#x} differ from the reviewed layout")
        image[at : at + 4] = bl_encode(address, target)
    image += blob()
    if pins.RELAY_ADDRESS + len(image) > LIMIT or len(image) % 4:
        raise FeedError("feed code overlaps the G2RQ buffer or is not word-sized")
    return bytes(image)


def literals(code: bytes | None = None) -> list[int]:
    """The literal pool at the end of the feed code (every word after the last instruction)."""
    code = code if code is not None else blob()
    pool = FED_DELAY_COUNTER + 6 - BASE  # subs, bne, pop {r4, pc}; then 2 bytes of padding
    pool += -pool % 4
    return list(struct.unpack_from(f"<{(len(code) - pool) // 4}I", code, pool))
