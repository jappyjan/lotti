# SPDX-License-Identifier: MIT
"""STM32 ROM-loader client for the G2 case, restricted to RAM-only work.

Byte-level framing follows drdaeman/g2-bootloader-patch tools/g2patch/case_rom.py
(MIT, itself from evenRealities-webflasher, MIT). This version adds a hard allowlist:
it can only identify, read memory, write the three pinned SRAM regions (with the pinned
bridge bytes or zeros), and jump to the bridge. There is no code path that erases or
writes flash, writes option bytes, or changes read/write protection.
"""

from __future__ import annotations

import hashlib

from . import pins


class RomError(RuntimeError):
    """The ROM loader rejected, truncated or answered unexpectedly."""


class RefusedError(RuntimeError):
    """This tool refused to send something outside its read-only/RAM-only allowlist."""


def read_exact(port, count: int, what: str) -> bytes:
    data = bytearray()
    while len(data) < count:
        chunk = port.read(count - len(data))
        if not chunk:
            raise RomError(f"timeout reading {what}: got {len(data)} of {count} bytes")
        data.extend(chunk)
    return bytes(data)


def _xor(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
    return value


def sram_regions(bridge: bytes) -> tuple[tuple[int, int], ...]:
    """The SRAM ranges this tool may write: the program region (its exact length: the 1,720-byte
    step-0 bridge, or the 5,508-byte W18 case relay that embeds it) and the bridge's record."""
    regions = ((pins.BRIDGE_ADDRESS, len(bridge)),) + pins.SRAM_WRITE_REGIONS[1:]
    if pins.BRIDGE_ADDRESS + len(bridge) > pins.RESULT_ADDRESS:
        raise RefusedError("program image would overlap the bridge record")
    return regions


def check_sram_write(address: int, data: bytes, bridge: bytes) -> None:
    """Raise RefusedError unless this write is inside one pinned SRAM region and carries
    either the pinned bridge bytes for that offset or zeros."""
    if not data or len(data) > 256 or len(data) % 4 or address % 4:
        raise RefusedError("SRAM write must be 4..256 bytes, word aligned")
    for base, length in sram_regions(bridge):
        if base <= address and address + len(data) <= base + length:
            if data == bytes(len(data)):
                return
            if base == pins.BRIDGE_ADDRESS:
                offset = address - base
                if data == bridge[offset : offset + len(data)]:
                    return
            raise RefusedError(
                f"SRAM write at {address:#010x} carries bytes other than the pinned bridge or zeros"
            )
    raise RefusedError(f"write to {address:#010x}+{len(data)} is outside the pinned SRAM regions")


class RomLoader:
    """One synchronized ROM session on an open port (115200 8E1)."""

    def __init__(self, port, bridge: bytes, log=None):
        self.port = port
        self.bridge = bridge
        self.log = log or (lambda event: None)
        self.bridge_verified = False

    # Every command goes through here; nothing else writes a command byte.
    def _command(self, command: int, what: str) -> None:
        if command not in pins.ROM_COMMAND_ALLOWLIST:
            raise RefusedError(f"ROM command {command:#04x} is not on the allowlist")
        self.port.write(bytes((command, command ^ 0xFF)))
        self.port.flush()
        self._ack(f"{what} command")

    def _ack(self, what: str) -> None:
        value = read_exact(self.port, 1, f"{what} ACK")[0]
        if value == pins.NACK:
            raise RomError(f"NACK during {what}")
        if value != pins.ACK:
            raise RomError(f"unexpected {value:#04x} during {what}")

    def _address(self, address: int, what: str) -> None:
        raw = address.to_bytes(4, "big")
        self.port.write(raw + bytes((_xor(raw),)))
        self.port.flush()
        self._ack(f"{what} address")

    def sync(self) -> None:
        self.port.write(bytes((pins.SYNC,)))
        self.port.flush()
        self._ack("sync")

    def identify(self) -> dict:
        self._command(pins.ROM_GET, "Get")
        count = read_exact(self.port, 1, "Get length")[0] + 1
        body = read_exact(self.port, count, "Get body")
        self._ack("Get end")
        version, commands = body[0], frozenset(body[1:])
        self._command(pins.ROM_GET_ID, "Get ID")
        count = read_exact(self.port, 1, "Get ID length")[0] + 1
        product = int.from_bytes(read_exact(self.port, count, "Get ID body"), "big")
        self._ack("Get ID end")
        identity = {
            "protocol": version,
            "product_id": product,
            "commands": sorted(commands),
        }
        self.log({"rom_identity": identity})
        if version != pins.ROM_PROTOCOL_VERSION or product != pins.ROM_PRODUCT_ID:
            raise RomError(f"unexpected case ROM identity {identity}")
        if commands != pins.ROM_EXPECTED_COMMANDS:
            raise RomError(f"case ROM command table differs from the reviewed one: {identity}")
        return identity

    def read_memory(self, address: int, size: int) -> bytes:
        if not 1 <= size <= 256:
            raise RefusedError("ROM reads are 1..256 bytes")
        self._command(pins.ROM_READ_MEMORY, "Read Memory")
        self._address(address, "Read Memory")
        self.port.write(bytes((size - 1, (size - 1) ^ 0xFF)))
        self.port.flush()
        self._ack("Read Memory length")
        return read_exact(self.port, size, f"memory at {address:#010x}")

    def read_range(self, address: int, size: int) -> bytes:
        out = bytearray()
        while len(out) < size:
            step = min(256, size - len(out))
            out += self.read_memory(address + len(out), step)
        return bytes(out)

    def write_sram(self, address: int, data: bytes) -> None:
        check_sram_write(address, data, self.bridge)
        self._command(pins.ROM_WRITE_MEMORY, "Write Memory")
        self._address(address, "Write Memory")
        body = bytes((len(data) - 1,)) + data
        self.port.write(body + bytes((_xor(body),)))
        self.port.flush()
        self._ack("Write Memory data")

    def write_verified(self, address: int, data: bytes) -> None:
        for offset in range(0, len(data), 256):
            chunk = data[offset : offset + 256]
            self.write_sram(address + offset, chunk)
            if self.read_memory(address + offset, len(chunk)) != chunk:
                raise RomError(f"SRAM readback mismatch at {address + offset:#010x}")

    def load_bridge(self) -> None:
        self.write_verified(pins.PROOF_ADDRESS, bytes(len(pins.PROOF)))
        self.write_verified(pins.RESULT_ADDRESS, bytes(pins.RESULT_LENGTH))
        self.write_verified(pins.BRIDGE_ADDRESS, self.bridge)
        self.bridge_verified = True
        # The hash of the bytes just written and read back, not a constant: with the
        # observed-33 variant this is 3ca8ed1d..., not the reviewed e30e143d....
        self.log({"bridge_loaded": hashlib.sha256(self.bridge).hexdigest()})

    def clear_sram(self) -> None:
        """Zero every region this tool ever wrote, and read it back."""
        for base, length in sram_regions(self.bridge):
            self.write_verified(base, bytes(length))
        self.bridge_verified = False

    def go_bridge(self) -> None:
        if not self.bridge_verified:
            raise RefusedError("Go is only allowed after the pinned bridge was written and read back")
        self._command(pins.ROM_GO, "Go")
        self._address(pins.BRIDGE_ADDRESS, "Go")
        self.bridge_verified = False
