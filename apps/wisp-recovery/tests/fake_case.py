# SPDX-License-Identifier: MIT
"""A fake G2 charging case behind a fake CH340, for tests without hardware.

- CH340 lines: RTS asserted holds the STM32 in reset; on release, DTR asserted boots the
  normal case app (prints its banner at 1 Mbaud 8N1), DTR released boots the ROM loader.
- ROM loader: an STM32 USART bootloader model (115200 8E1) over a synthetic flash image
  and the case SRAM. Every command is logged so tests can assert what was sent.
- Go: runs the *real* pinned bridge binary under Unicorn. Its calls into case flash are
  stubbed (YHM2510 I2C register file, USART3 transmit to a fake temple), its MMIO is
  modelled (USART1 to the host, USART3 from the temple), and its final SYSRESETREQ resets
  the fake case with SRAM retained, as on the STM32.
- The W18 relay (drdaeman's case.bin: the bridge plus his reset/claim/relay extension) runs the
  same way. Its reset waveform is Even's code and not in the repository, so the call into it is
  a hook that resets the fake temple (whose `reset()` returns its boot beacon, the HELO), and
  CASE_GPIO_INIT is one more stub. `hang_when(frame)` stops the emulated MCU for good while it
  hands that frame to the temple: the step-F failure as the hardware record shows it.
"""

from __future__ import annotations

import hashlib
import struct
import threading
from collections import deque

import unicorn as u
from unicorn.arm_const import UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3, UC_ARM_REG_SP

FLASH, FLASH_SIZE = 0x0800_0000, 0x2_0000
SRAM, SRAM_SIZE = 0x2000_0000, 0x2_4000
IDLE_YHM = bytes.fromhex("811104afaf03812022ff")  # third seated-idle profile in the bridge
STUB_INIT = (0x08004EEC, 0x08008438, 0x08006A40, 0x08002888, 0x08006CF8, 0x08006C80,
             0x08004D30)  # the last: CASE_GPIO_INIT, called by the W18 relay's temple reset
RELAY_WAVEFORM = 0x20011400  # W18 relay: Even's temple-reset waveform (zeroed in the template)
HOST_READ_POLLS = ((0x20010316, 0x2001033E), (0x200109AC, 0x200109D6))  # bridge, W18 relay
TEMPLE_POLL_COUNTERS = (0x200105C2, 0x2001090C)  # bridge capture, W18 relay_receive
STUB_I2C_READ, STUB_I2C_WRITE, STUB_UART3_TX = 0x08009040, 0x08009108, 0x08003BB0
BANNER = b"\r\n****** B200 1.2.57 0123456789abcdef01234567******\r\nPower up...\r\n"


def synthetic_flash(length: int) -> bytes:
    """Stand-in for the case image (Even firmware is never in the repo): pseudo-random
    bytes with `bx lr` at every function the bridge calls."""
    out = bytearray()
    seed = b"wisp-fake-case"
    while len(out) < length:
        seed = hashlib.sha256(seed).digest()
        out += seed
    out = out[:length]
    for address in (*STUB_INIT, STUB_I2C_READ, STUB_I2C_WRITE, STUB_UART3_TX):
        out[address - FLASH : address - FLASH + 2] = b"\x70\x47"
    return bytes(out)


def version_frame(version=(2, 4, 0, 24), hardware=5) -> bytes:
    frame = bytearray(b"\x5a\xa5\xff\x09\x24\x01\x03\x05" + bytes(version) + bytes((hardware,)))
    frame.append(sum(frame) & 0xFF)
    return bytes(frame)


class LinkTemple:
    """A temple for the W18 relay: a loader link (fake_temple.FakeLoaderLink, or anything with
    start() and exchange()) behind the case's pogo UART."""

    def __init__(self, link):
        self.link = link
        self.received: list[bytes] = []

    def reset(self) -> bytes:
        return self.link.start()

    def hear(self, data: bytes) -> bytes:
        self.received.append(data)
        return self.link.exchange(data)


class FakeTemple:
    def __init__(self, side, reply=None):
        self.side, self.reply = side, reply if reply is not None else version_frame()
        self.received: list[bytes] = []

    def hear(self, data: bytes) -> bytes:
        self.received.append(data)
        return self.reply if data == bytes.fromhex("24000100a7") else b""


class FakeCase:
    def __init__(self, flash_length, temples=None, yhm=IDLE_YHM, rom_reply_banner=BANNER,
                 rts_resets=True, status_line=None):
        # rts_resets=False models a driver whose RTS changes never reach the case: the app
        # keeps running and only prints its periodic status line (status_line) when listened to.
        self.rts_resets = rts_resets
        self.status_line = status_line
        self.host_bytes = bytearray()
        self.flash = synthetic_flash(flash_length)
        self.temples = temples or {"left": FakeTemple("left"), "right": FakeTemple("right")}
        self.yhm = bytearray(yhm)
        self.banner = rom_reply_banner
        self.dtr = self.rts = False
        self.mode = "off"
        self.port = None
        self.rom_log: list[tuple] = []
        self.yhm_writes: list[tuple[int, int]] = []
        self.resets = 0
        self.run_timeout_us = 20_000_000
        self.hang_when = None
        self.hung = False
        self.uc = u.Uc(u.UC_ARCH_ARM, u.UC_MODE_THUMB | u.UC_MODE_MCLASS)
        self.uc.mem_map(FLASH, FLASH_SIZE)
        self.uc.mem_write(FLASH, self.flash)
        self.uc.mem_map(SRAM, SRAM_SIZE)
        self.uc.mem_map(0x4000_0000, 0x3_0000)
        self.uc.mem_map(0x5000_0000, 0x2000)
        self.uc.mem_map(0xE000_0000, 0x10_0000)
        self.cond = threading.Condition()
        self.host_in: deque[int] = deque()  # host -> case USART1
        self.temple_rx: deque[int] = deque()  # temple -> case USART3
        self.thread = None
        self.stop = False
        self._install_hooks()

    # ---------------------------------------------------------------- CH340 lines
    def open(self, port):
        with self.cond:
            self.port = port
        self.set_lines(port.dtr, port.rts)
        if self.mode == "normal" and self.status_line:
            self._emit(self.status_line, need=(1_000_000, "N"))

    def set_lines(self, dtr, rts):
        if not self.rts_resets:
            self.mode = "normal"
            return
        was_reset = self.rts
        self.dtr, self.rts = dtr, rts
        if rts and not was_reset:
            self._halt()
            self.mode = "reset"
        elif was_reset and not rts:
            self._boot()

    def _halt(self):
        if self.thread:
            self.stop = True
            with self.cond:
                self.cond.notify_all()
            self.uc.emu_stop()
            self.thread.join(5)
            self.thread = None

    def _boot(self):
        self.resets += 1
        self.stop = False
        with self.cond:
            self.host_in.clear()
        if self.dtr:
            self.mode = "normal"
            self._emit(self.banner, need=(1_000_000, "N"))
        else:
            self.mode = "rom-wait-sync"
            self.rom = self._rom()
            next(self.rom)

    def _emit(self, data, need):
        port = self.port
        if port and port.is_open and (port.baudrate, port.parity) == need:
            port.deliver(data)

    # ---------------------------------------------------------------- host bytes in
    def receive(self, data: bytes):
        self.host_bytes += data
        if self.mode.startswith("rom") and (self.port.baudrate, self.port.parity) == (115_200, "E"):
            self.rom_in.extend(data)
            try:
                next(self.rom)
            except StopIteration:  # Go: the ROM loader has jumped
                pass
        elif self.mode == "bridge":
            with self.cond:
                self.host_in.extend(data)
                self.cond.notify_all()

    # ---------------------------------------------------------------- ROM loader
    def _rom(self):
        self.rom_in = deque()
        out = lambda b: self._emit(bytes(b), need=(115_200, "E"))  # noqa: E731

        def take(n):
            while len(self.rom_in) < n:
                yield
            return bytes(self.rom_in.popleft() for _ in range(n))

        def address():
            raw = yield from take(5)
            if raw[4] != raw[0] ^ raw[1] ^ raw[2] ^ raw[3]:
                out([0x1F])
                return None
            out([0x79])
            return int.from_bytes(raw[:4], "big")

        while (yield from take(1)) != b"\x7f":
            pass
        self.rom_log.append(("sync",))
        out([0x79])
        self.mode = "rom"
        while True:
            cmd, check = yield from take(2)
            if cmd ^ check != 0xFF:
                out([0x1F])
                continue
            self.rom_log.append(("cmd", cmd))
            if cmd == 0x00:
                cmds = bytes((0x31, 0x00, 0x01, 0x02, 0x11, 0x21, 0x31, 0x44, 0x63, 0x73, 0x82, 0x92))
                out([0x79, len(cmds) - 1, *cmds, 0x79])
            elif cmd == 0x02:
                out([0x79, 0x01, 0x04, 0x67, 0x79])
            elif cmd == 0x11:
                out([0x79])
                addr = yield from address()
                n, check = yield from take(2)
                out([0x79])
                self.rom_log.append(("read", addr, n + 1))
                out(self.uc.mem_read(addr, n + 1))
            elif cmd == 0x31:
                out([0x79])
                addr = yield from address()
                n = (yield from take(1))[0]
                body = yield from take(n + 2)
                data, check = body[:-1], body[-1]
                x = n
                for b in data:
                    x ^= b
                if x != check:
                    out([0x1F])
                    continue
                self.rom_log.append(("write", addr, bytes(data)))
                if not SRAM <= addr < SRAM + SRAM_SIZE:
                    raise AssertionError(f"fake case: write outside SRAM at {addr:#x}")
                self.uc.mem_write(addr, bytes(data))
                out([0x79])
            elif cmd == 0x21:
                out([0x79])
                addr = yield from address()
                self.rom_log.append(("go", addr))
                self._start_bridge(addr)
                return
            else:
                out([0x1F])

    # ---------------------------------------------------------------- bridge under Unicorn
    def _start_bridge(self, vector):
        sp, pc = struct.unpack("<II", self.uc.mem_read(vector, 8))
        self.mode = "bridge"
        self.uc.reg_write(UC_ARM_REG_SP, sp)

        def run():
            try:
                self.uc.emu_start(pc | 1, 0xFFFF_FFF0, timeout=self.run_timeout_us)
            except u.UcError as error:
                self.fault = error

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def _install_hooks(self):
        uc = self.uc
        ret = lambda c, value=None: (  # noqa: E731
            value is not None and c.reg_write(UC_ARM_REG_R0, value),
            c.reg_write(UC_ARM_REG_PC, c.reg_read(UC_ARM_REG_LR)),
        )

        def code(c, address, size, _):
            if address in STUB_INIT:
                ret(c)
            elif address == STUB_I2C_READ:
                reg, dst = c.reg_read(UC_ARM_REG_R0), c.reg_read(UC_ARM_REG_R2)
                c.mem_write(dst, bytes((self.yhm[reg],)))
                ret(c, 1)
            elif address == STUB_I2C_WRITE:
                reg, src = c.reg_read(UC_ARM_REG_R0), c.reg_read(UC_ARM_REG_R2)
                value = c.mem_read(src, 1)[0]
                self.yhm[reg] = value
                self.yhm_writes.append((reg, value))
                ret(c, 1)
            elif address == STUB_UART3_TX:
                data = bytes(c.mem_read(c.reg_read(UC_ARM_REG_R0), c.reg_read(UC_ARM_REG_R1)))
                if self.hang_when and self.hang_when(data):
                    self.hung = True  # the MCU never comes back from this call
                    c.emu_stop()
                    return
                side = self._routed_side()
                reply = self.temples[side].hear(data) if side else b""
                self.temple_rx.extend(reply)
                ret(c, 0)
            elif address == RELAY_WAVEFORM:
                side = self._routed_side()
                temple = self.temples.get(side)
                if temple is not None and hasattr(temple, "reset"):
                    self.temple_rx.extend(temple.reset())
                ret(c)
            elif address in (0x20010624, 0x2001062E):  # busy-wait delays
                ret(c)
            elif address in TEMPLE_POLL_COUNTERS and not self.temple_rx:  # temple poll: fast-forward
                c.reg_write(UC_ARM_REG_R3, 1)

        def mem_read(c, access, address, size, value, _):
            if address == 0x4001381C:  # USART1 ISR: TXE|TC, RXNE when host bytes wait
                with self.cond:
                    pc = c.reg_read(UC_ARM_REG_PC)
                    if any(lo <= pc < hi for lo, hi in HOST_READ_POLLS):
                        self.cond.wait_for(lambda: self.host_in or self.stop, timeout=10)
                    flags = 0xC0 | (0x20 if self.host_in else 0)
                c.mem_write(address, struct.pack("<I", flags))
            elif address == 0x40013824:
                with self.cond:
                    c.mem_write(address, struct.pack("<I", self.host_in.popleft()))
            elif address == 0x4000481C:
                c.mem_write(address, struct.pack("<I", 0x20 if self.temple_rx else 0))
            elif address == 0x40004824:
                c.mem_write(address, struct.pack("<I", self.temple_rx.popleft()))

        def mem_write(c, access, address, size, value, _):
            if address == 0x40013828:
                self._emit(bytes((value & 0xFF,)), need=(115_200, "E"))
            elif address == 0xE000ED0C and value == 0x05FA0004:
                c.emu_stop()
                threading.Thread(target=self._sysreset, daemon=True).start()

        uc.hook_add(u.UC_HOOK_CODE, code)
        uc.hook_add(u.UC_HOOK_MEM_READ, mem_read, begin=0x4000_0000, end=0x4002_FFFF)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, mem_write, begin=0x4001_3828, end=0x4001_382B)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, mem_write, begin=0xE000_ED0C, end=0xE000_ED0F)

    def _sysreset(self):
        if self.thread:
            self.thread.join(5)
            self.thread = None
        self.resets += 1
        self.mode = "rom-wait-sync" if not self.dtr else "normal"
        if self.dtr:
            self._emit(self.banner, need=(1_000_000, "N"))
        else:
            self.rom = self._rom()
            next(self.rom)

    def _routed_side(self):
        if self.yhm[3] == 0xA6 and self.yhm[7] == 3:
            return "left"
        if self.yhm[4] == 0xA6 and self.yhm[7] == 5:
            return "right"
        return None


class FakePort:
    """Just enough of pyserial.Serial for the tool."""

    def __init__(self, case, baudrate, parity, dtr, rts, timeout):
        self.case, self.baudrate, self.parity, self.timeout = case, baudrate, parity, timeout
        self._dtr, self._rts = dtr, rts
        self.buffer = bytearray()
        self.cond = threading.Condition()
        self.is_open = True
        case.open(self)

    @property
    def dtr(self):
        return self._dtr

    @property
    def rts(self):
        return self._rts

    @rts.setter
    def rts(self, value):
        self._rts = value
        self.case.set_lines(self._dtr, value)

    def deliver(self, data):
        with self.cond:
            self.buffer += data
            self.cond.notify_all()

    def read(self, n):
        with self.cond:
            self.cond.wait_for(lambda: self.buffer, timeout=min(self.timeout, 2.0))
            out = bytes(self.buffer[:n])
            del self.buffer[:n]
            return out

    def write(self, data):
        self.case.receive(bytes(data))

    def flush(self):
        pass

    def reset_input_buffer(self):
        with self.cond:
            self.buffer.clear()

    def close(self):
        self.is_open = False


def opener_for(case):
    def opener(device, baudrate, parity, dtr, rts, timeout):
        return FakePort(case, baudrate, parity, dtr, rts, timeout)

    return opener
