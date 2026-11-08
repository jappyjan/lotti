# SPDX-License-Identifier: MIT
"""CH340 line handling for the G2 case.

The case wires the CH340's RTS to the STM32's reset and DTR to boot-select: DTR
deasserted at reset release starts the ROM loader, DTR asserted starts the normal case
application. The sequences below are drdaeman's hardware-tested ones (case_rom.py
open_rom_loader / restore_application, MIT).
"""

from __future__ import annotations

import glob
import re
import time

from . import pins
from .rom import RomError, RomLoader


def serial_opener(device: str, baudrate: int, parity: str, dtr: bool, rts: bool, timeout: float):
    import serial  # pyserial; only needed against real hardware

    port = serial.Serial()
    port.port = device
    port.baudrate = baudrate
    port.bytesize = serial.EIGHTBITS
    port.parity = {"E": serial.PARITY_EVEN, "N": serial.PARITY_NONE}[parity]
    port.stopbits = serial.STOPBITS_ONE
    port.timeout = timeout
    port.write_timeout = 3.0
    port.dtr = dtr
    port.rts = rts
    port.open()
    return port


def find_case_port() -> str:
    candidates = sorted(set(glob.glob("/dev/cu.wchusbserial*") + glob.glob("/dev/cu.usbserial*")))
    if len(candidates) != 1:
        raise SystemExit(
            f"expected exactly one CH340 serial port, found {candidates or 'none'}; pass --port"
        )
    return candidates[0]


def enter_rom(device: str, bridge: bytes, opener, sleep=time.sleep, log=None, attempts: int = 3):
    """Reset the case MCU into its ROM loader and synchronize. Returns (port, loader)."""
    last = None
    for attempt in range(1, attempts + 1):
        port = opener(device, pins.ROM_BAUD, "E", dtr=False, rts=True, timeout=3.0)
        try:
            sleep(0.05)
            port.rts = False
            sleep(0.15 * attempt)
            port.reset_input_buffer()
            loader = RomLoader(port, bridge, log)
            loader.sync()
            loader.identify()
            return port, loader
        except Exception as error:  # noqa: BLE001 - retried, then re-raised
            last = error
            port.close()
            if log:
                log({"rom_entry_retry": attempt, "error": repr(error)})
    raise RomError(f"case ROM loader did not answer after {attempts} resets: {last!r}")


def case_banner(device: str, opener, sleep=time.sleep, clock=time.monotonic, timeout: float = 6.0,
                listen_full: bool = False, settle_s: float = 0.0) -> dict:
    """Reset the case into its normal application and read its boot banner (no bytes sent).

    Returns the version (None if no fresh boot banner was seen), the full capture as
    timestamped chunks, and the exact CH340 line sequence with its timing. Times are
    seconds since just before the port was opened. A "fresh boot" needs both the
    `****** B200 x.y.z` banner and `Power up...`, which the case prints only at start-up;
    its periodic `B200 vol:...` status lines do not count.

    With `settle_s`, it keeps the case app running and listens that long after the banner before
    it returns (`settle`: how long, and when each `B200 vol:` status line came, in seconds after
    the banner). The W18 relay needs that between two sessions: right after two app restarts
    within about 2 s, the pogo switch (YHM2510) is not idle yet and the bridge refuses G2RQ with
    status 3 (hardware log, W18 F1d split).
    """
    t0 = clock()
    stamp = lambda: round(clock() - t0, 4)  # noqa: E731
    lines = [{"t": stamp(), "action": "open", "baud": pins.CONSOLE_BAUD, "dtr": True, "rts": True}]
    port = opener(device, pins.CONSOLE_BAUD, "N", dtr=True, rts=True, timeout=0.2)
    lines.append({"t": stamp(), "action": "opened (RTS asserted = reset held, DTR asserted = app boot)"})
    chunks: list[dict] = []
    text = bytearray()
    version = None
    banner_t = None
    try:
        sleep(0.05)
        port.rts = False
        lines.append({"t": stamp(), "action": "rts=False (reset released)", "dtr": True, "rts": False})
        deadline = clock() + timeout
        while clock() < deadline:
            chunk = port.read(4096)
            if not chunk:
                continue
            chunks.append({"t": stamp(), "n": len(chunk), "text": chunk.decode("ascii", "backslashreplace")})
            text += chunk
            match = re.search(pins.CONSOLE_BANNER, text)
            if version is None and match and pins.CONSOLE_POWER_UP in text:
                version, banner_t = match.group(1).decode(), chunks[-1]["t"]
                if not listen_full:
                    break
        if version is not None and settle_s:
            deadline = t0 + banner_t + settle_s
            while clock() < deadline:
                chunk = port.read(4096)
                if chunk:
                    chunks.append({"t": stamp(), "n": len(chunk), "text": chunk.decode("ascii", "backslashreplace")})
                    text += chunk
    finally:
        port.close()
        lines.append({"t": stamp(), "action": "close"})
    settle = None
    if version is not None and settle_s:
        # When each chunk with a status line arrived, in seconds after the banner: the hardware
        # run tells how soon the app prints its first one.
        settle = {"seconds": round(stamp() - banner_t, 3),
                  "status_line_t": [round(c["t"] - banner_t, 3) for c in chunks
                                    if c["t"] > banner_t and pins.CONSOLE_STATUS.decode() in c["text"]]}
    return {
        "settle": settle,
        "version": version,
        "fresh_boot": version is not None,
        "banner_t": banner_t,
        "banner": bytes(text).decode("ascii", "replace"),
        "chunks": chunks,
        "lines": lines,
    }
