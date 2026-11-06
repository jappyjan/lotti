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


def case_banner(device: str, opener, sleep=time.sleep, clock=time.monotonic, timeout: float = 6.0) -> dict:
    """Reset the case into its normal application and read its boot banner (no bytes sent)."""
    port = opener(device, pins.CONSOLE_BAUD, "N", dtr=True, rts=True, timeout=0.2)
    try:
        sleep(0.05)
        port.rts = False
        deadline = clock() + timeout
        text = bytearray()
        while clock() < deadline:
            text += port.read(4096)
            match = re.search(pins.CONSOLE_BANNER, text)
            if match and pins.CONSOLE_POWER_UP in text:
                return {"version": match.group(1).decode(), "banner": bytes(text).decode("ascii", "replace")}
        return {"version": None, "banner": bytes(text).decode("ascii", "replace")}
    finally:
        port.close()
