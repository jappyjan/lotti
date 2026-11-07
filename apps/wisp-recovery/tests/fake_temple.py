# SPDX-License-Identifier: MIT
"""A Python stand-in for the patched bootloader's UART2 loader (PROTOCOL.md semantics) with a
fake MRAM, and a stand-in for the stock app's BLE OTA service. No hardware, no emulator.

The RAM programs are recognised by their pinned SHA-256 and run as Python equivalents of
drdaeman's checksum.c, dump.c and recover.c."""

from __future__ import annotations

import asyncio
import hashlib
import struct
import zlib

from wisp_w18 import ble, loader, pins


class FakeMram:
    def __init__(self, contents: dict[int, bytes] | None = None):
        self.mem = bytearray(b"\xff" * 0x400000)  # 0x400000-0x800000
        self.io = {}  # other readable addresses: addr -> bytes
        self.writes: list[tuple[int, int]] = []
        for addr, data in (contents or {}).items():
            self.mem[addr - 0x400000 : addr - 0x400000 + len(data)] = data

    def read(self, addr: int, n: int) -> bytes:
        if 0x400000 <= addr and addr + n <= 0x800000:
            return bytes(self.mem[addr - 0x400000 : addr - 0x400000 + n])
        for base, data in self.io.items():
            if base <= addr and addr + n <= base + len(data):
                return data[addr - base : addr - base + n]
        raise AssertionError(f"fake bus fault at {addr:#x}+{n}")

    def program(self, addr: int, data: bytes) -> None:
        self.writes.append((addr, len(data)))
        self.mem[addr - 0x400000 : addr - 0x400000 + len(data)] = data


class FakeLoaderLink:
    """Implements the link interface (start/exchange/close) on top of a fake loader."""

    def __init__(self, mram: FakeMram, challenge: int = 0x1234, cut_after_writes: int | None = None):
        self.mram = mram
        self.challenge = challenge
        self.held = False
        self.code = None
        self.pending = None  # generator of a running program
        self.closed = False
        self.sent: list[bytes] = []
        self.cut_after_writes = cut_after_writes

    def start(self) -> bytes:
        return loader.hello(self.challenge)

    def close(self) -> None:
        self.closed = True

    def _reply(self, kind, status=0, data=b""):
        return loader.reply(kind, status, data)

    def exchange(self, frame: bytes) -> bytes:
        self.sent.append(frame)
        if not self.held:
            assert frame == loader.hold(self.challenge), "expected HOLD"
            self.held = True
            return loader.okay(self.challenge)
        if frame == loader.cont():
            self.held = False
            return loader.released()
        assert len(frame) == 32 and frame[4:8] == b"RQST"
        op, payload = frame[8], frame[9:31]
        if self.pending is not None:
            return self._step(op, payload)
        if op == loader.LOAD:
            length, _entry, a0, a1, crc = struct.unpack_from("<HHIII", payload)
            self.code = {"length": length, "args": (a0, a1), "crc": crc, "data": bytearray()}
            return self._reply(loader.ACK)
        if op == loader.DATA:
            n = payload[0]
            self.code["data"] += payload[1 : 1 + n]
            if len(self.code["data"]) < self.code["length"]:
                return self._reply(loader.ACK)
            if zlib.crc32(self.code["data"]) != self.code["crc"]:
                return self._reply(loader.ERROR, 3)
            return self._reply(loader.READY)
        if op == loader.RUN:
            code, self.code = self.code, None
            name = {v: k for k, v in pins.PROGRAMS.items()}.get(hashlib.sha256(code["data"]).hexdigest())
            assert name, "unknown RAM program"
            self.pending = getattr(self, f"_prog_{name}")(*code["args"])
            return self._step(None, None)
        return self._reply(loader.ERROR, 2)

    def _step(self, op, payload):
        try:
            if op is None:
                kind, data = next(self.pending)
            elif op == loader.OUTPUT_ACK:
                kind, data = self.pending.send(None)
            elif op == loader.INPUT_DATA:
                n = payload[0]
                chunk = payload[1 : 1 + n]
                assert zlib.crc32(chunk) == struct.unpack_from("<I", payload, 17)[0]
                kind, data = self.pending.send(chunk)
            else:
                raise AssertionError(f"unexpected op {op} during a program")
        except StopIteration as done:
            self.pending = None
            return self._reply(loader.RESULT, 0, struct.pack("<I", done.value))
        if kind == "out":
            return self._reply(loader.OUTPUT, len(data), data)
        return self._reply(loader.INPUT, data)

    # Python equivalents of the pinned programs (generators: yield ("out", bytes) / ("in", cap))
    def _prog_checksum(self, addr, n):
        return zlib.crc32(self.mram.read(addr, n))
        yield  # unreachable: makes this a generator

    def _prog_dump(self, addr, n):
        data = self.mram.read(addr, n)
        for i in range(0, n, 128):
            block = data[i : i + 128]
            for j in range(0, len(block), 16):
                yield "out", block[j : j + 16]
        return 0

    def _prog_recover(self, addr, n):
        if not n:
            return 0
        done = 0
        while done < n:
            size = min(256, n - done)
            buf = b""
            while len(buf) < size:
                chunk = yield "in", min(16, size - len(buf))
                if not chunk:
                    return 5
                buf += chunk
            self.mram.program(addr + done, buf)
            if self.cut_after_writes is not None and len(self.mram.writes) >= self.cut_after_writes:
                self.cut_after_writes = None
                self.pending = None
                raise _Cut()
            done += size
            progress = struct.pack("<I", done)
            yield "out", progress
        return 0


class _Cut(Exception):
    pass


class FakeClock:
    """Virtual seconds for the session-time guard: the relay model advances it per exchange."""

    def __init__(self, now: float = 1000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class CuttingLink(FakeLoaderLink):
    """A power cut during a write: the next reply is the HELO of the next boot."""

    def exchange(self, frame):
        try:
            return super().exchange(frame)
        except _Cut:
            self.held = False
            self.challenge += 1
            return loader.hello(self.challenge)


class FakeGatt:
    """The stock app's OTA service as seen over BLE, for ble.StockOta."""

    def __init__(self, name="Even G2_L_abcdef", mtu=247, end_status=8, reject_block=None):
        self.name, self.mtu = name, mtu
        self.notes: asyncio.Queue = asyncio.Queue()
        self.end_status = end_status
        self.reject_block = reject_block
        self.header = None
        self.blocks: list[bytes] = []
        self.ops: list[int] = []
        self._data = b""
        self._pending_sid = None

    def _notify(self, ch, sid, payload, seq=0):
        body = payload + ble.crc16(payload)
        frame = bytes((0xAA, 0x12, seq, len(body), 1, 1, sid, 0)) + body
        self.notes.put_nowait((ch, frame))

    async def write(self, characteristic, packet):
        sid, seq = packet[6], packet[2]
        body = packet[8:]
        count, index = packet[4], packet[5]
        self._data = (self._data if index > 1 else b"") + body
        if index < count:
            return
        payload, crc = self._data[:-2], self._data[-2:]
        assert ble.crc16(payload) == crc
        if sid == 0x80:
            prefix = payload[:4]
            self._notify(ble.CTRL[1], 0x80, prefix + b"\x1a\0", seq)
        elif sid == 0xC0:
            op = payload[0]
            self.ops.append(op)
            if op == 0:
                self._notify(ble.DATA[1], 0xC0, b"\x00\x00", seq)
            elif op == 1:
                self.header = payload[1:]
                self._notify(ble.DATA[1], 0xC0, b"\x01\x00", seq)
            elif op == 2:
                self._pending_sid = 2
            elif op == 3:
                self._notify(ble.DATA[1], 0xC0, bytes((3, self.end_status)), seq)
        elif sid == 0xC1:
            self.blocks.append(payload)
            status = 6 if self.reject_block == len(self.blocks) - 1 else 0
            self._notify(ble.DATA[1], 0xC0, bytes((2, status)), seq)
