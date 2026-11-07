# SPDX-License-Identifier: MIT
"""A fake G2 charging case behind a fake CH340, for tests without hardware.

- CH340 lines: RTS asserted holds the STM32 in reset; on release, DTR asserted boots the
  normal case app (prints its banner at 1 Mbaud 8N1), DTR released boots the ROM loader.
- ROM loader: an STM32 USART bootloader model (115200 8E1) over a synthetic flash image
  and the case SRAM. Every command is logged so tests can assert what was sent. Its first byte
  after a reset must be the 0x7F sync: anything else and it stays deaf until the next reset, as
  the real ROM's autobaud does.
- Go: runs the *real* pinned bridge binary under Unicorn. Its calls into case flash are
  stubbed (YHM2510 I2C register file, USART3 transmit to a fake temple), its MMIO is
  modelled (USART1 to the host, USART3 from the temple), and its final SYSRESETREQ resets
  the fake case with SRAM retained, as on the STM32.
- The W18 relay (drdaeman's case.bin: the bridge plus his reset/claim/relay extension) runs the
  same way. Its reset waveform is Even's code and not in the repository, so the call into it is
  a hook that resets the fake temple (whose `reset()` returns its boot beacon, the HELO), and
  CASE_GPIO_INIT is one more stub. `hang_when(frame)` stops the emulated MCU for good while it
  hands that frame to the temple: the step-F failure as the hardware record shows it.

Emulated time and the case's YHM4005 watchdog (recovery.md, "Long relay sessions"):

- The clock is event-driven: the poll turns the fake skips (in steps of `poll_step_s`, so the
  code inside the loop still runs between steps) at each loop's cycle count from the listings
  (1.5 cycles per instruction, 64 MHz: the relay's 64,000,000-poll temple wait takes 18 s, as
  measured on hardware), the relay's busy-wait delays, ROM bytes at 115200 8E1, and `exchange_s`
  per frame the relay hands to the temple (the temple's turnaround and the host's USB time: 17.5
  ms per exchange on hardware). The few thousand instructions an exchange executes otherwise
  (well under 0.1 ms) and the host's think time do not count: lockstep, as in Renode.
- GPIOB (MODER, ODR, BSRR, BRR) and TIM6 (CR1 CEN/URS, PSC, ARR, EGR UG, SR UIF; no CNT) are
  modelled. PB2 reads as high unless it is an output
  driven low; MX_GPIO_Init (a stub) does to PB2 what the real one does: output, low.
- The YHM4005: armed, `wdt_timeout_s` (20 s) after the last falling edge on PB2 it resets the
  case (SRAM kept, the ROM again because DTR is released) and does so again every
  `wdt_timeout_s` while nothing feeds it. A banner boot does not feed it (hardware, F1b).
  `wdt_feeds` and `wdt_resets` record when; `pb2_edges` every level change.
- `forbidden_writes` lists any write to the case flash or its FLASH registers (there must be none).
"""

from __future__ import annotations

import hashlib
import struct
import sys
import threading
from collections import deque
from pathlib import Path

import unicorn as u
from unicorn.arm_const import (UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2,
                               UC_ARM_REG_R3, UC_ARM_REG_R4, UC_ARM_REG_SP)

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from wisp_w18 import relay_feed  # noqa: E402

FLASH, FLASH_SIZE = 0x0800_0000, 0x2_0000
SRAM, SRAM_SIZE = 0x2000_0000, 0x2_4000
IDLE_YHM = bytes.fromhex("811104afaf03812022ff")  # third seated-idle profile in the bridge
MX_GPIO_INIT = 0x08006A40
STUB_INIT = (0x08004EEC, 0x08008438, MX_GPIO_INIT, 0x08002888, 0x08006CF8, 0x08006C80,
             0x08004D30)  # the last: CASE_GPIO_INIT, called by the W18 relay's temple reset
RELAY_WAVEFORM = 0x20011400  # W18 relay: Even's temple-reset waveform (zeroed in the template)
HOST_READ_POLLS = (  # where the relay reads USART1's ISR while it waits for the host
    (0x20010316, 0x2001033E), (0x200109AC, 0x200109D6),  # bridge, W18 relay
    (relay_feed.POLL_BRIDGE_RX, relay_feed.POLL_BEACON), (relay_feed.POLL_HOST_RX, relay_feed.FED_DELAY),  # -feed
)
# Poll-loop counters the fake fast-forwards: address of the decrement -> (counter register,
# only while no temple byte waits, instructions per turn of drdaeman's loop, of the -feed one)
POLL_COUNTERS = {
    0x200105C2: (UC_ARM_REG_R3, True, 6, 6),  # bridge capture
    0x2001090C: (UC_ARM_REG_R3, True, 12, 19),  # W18 relay_receive (the temple frame wait): +bl, 4, bx
    relay_feed.FED_DELAY_COUNTER: (UC_ARM_REG_R4, False, 6, 6),  # -feed: the wait before the reset
}
FED_SITE = relay_feed.SITES[3][0]  # 0x200108b2: `movs r0, #2` in drdaeman's relay, a `bl` with the feed
DELAY_LOOP, DELAY_YHM = 0x20010624, 0x2001062E  # the bridge's busy waits: 3 cycles per turn
STUB_I2C_READ, STUB_I2C_WRITE, STUB_UART3_TX = 0x08009040, 0x08009108, 0x08003BB0
BANNER = b"\r\n****** B200 1.2.57 0123456789abcdef01234567******\r\nPower up...\r\n"

CPU_HZ = 64_000_000  # the case app's clock, which the bridge sets up (SystemClock_Config)
CYCLES_PER_INSN = 1.5
ROM_BYTE_S = 11 / 115_200
GPIOB, TIM6, RCC_APBENR1 = 0x5000_0400, 0x4000_1000, 0x4002_103C
FLASH_REGS = (0x4002_2000, 0x4002_23FF)


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
                 rts_resets=True, status_line=None, wdt_timeout_s=None, exchange_s=0.0, poll_step_s=0.05):
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
        # Emulated time, the YHM4005 on PB2, TIM6 (see the module docstring).
        self.clock_s = 0.0
        self.exchange_s, self.poll_step_s = exchange_s, poll_step_s
        self.wdt_timeout_s = wdt_timeout_s
        self.wdt_last_feed = 0.0
        self.wdt_feeds: list[float] = []
        self.wdt_resets: list[float] = []
        self.pb2_edges: list[tuple[float, int]] = []
        self.read_cap_s = 2.0  # the longest a FakePort read waits, whatever its timeout
        self.rom_bytes_until_reset = None  # tests: a watchdog reset after this many more ROM bytes
        self.on_wdt_reset = None
        self.relay_started_at = None  # emulated time of the last Go
        self.forbidden_writes: list[tuple[int, int]] = []
        self._reset_peripherals_state()
        self.uc = u.Uc(u.UC_ARCH_ARM, u.UC_MODE_THUMB | u.UC_MODE_MCLASS)
        self.uc.mem_map(FLASH, FLASH_SIZE)
        self.uc.mem_write(FLASH, self.flash)
        self.uc.mem_map(SRAM, SRAM_SIZE)
        self.uc.mem_map(0x4000_0000, 0x3_0000)
        self.uc.mem_map(0x5000_0000, 0x2000)
        self.uc.mem_map(0xE000_0000, 0x10_0000)
        self._reset_peripherals()
        self.cond = threading.Condition()
        self.host_in: deque[int] = deque()  # host -> case USART1
        self.temple_rx: deque[int] = deque()  # temple -> case USART3
        self.thread = None
        self.stop = False
        self._install_hooks()

    # ---------------------------------------------------------------- emulated time, YHM4005
    def now(self) -> float:
        return self.clock_s

    def _wdt_due(self) -> bool:
        return (self.wdt_timeout_s is not None and self.mode != "normal"
                and self.now() - self.wdt_last_feed >= self.wdt_timeout_s)

    def _wdt_reset(self):
        """The 4005's RST pulse: an MCU reset with SRAM kept. Its timer starts the next slot."""
        self.wdt_resets.append(round(self.now(), 4))
        self.wdt_last_feed = self.now()
        if self.on_wdt_reset:
            self.on_wdt_reset(self)

    # ---------------------------------------------------------------- GPIOB, TIM6
    def _reset_peripherals_state(self):
        self.gpiob_moder, self.gpiob_odr, self.pb2 = 0xFFFFFFFF, 0, 1
        self.tim = {"cr1": 0, "psc": 0, "psc_active": 0, "arr": 0xFFFF, "sr": 0, "t0": 0.0}

    def _reset_peripherals(self):
        """What an MCU reset does to the modelled peripherals (GPIOB analog, TIM6 off)."""
        self._reset_peripherals_state()
        self.uc.mem_write(GPIOB, struct.pack("<8I", 0xFFFFFFFF, 0, 0, 0, 0, 0, 0, 0))
        self.uc.mem_write(TIM6, bytes(0x30))
        self.uc.mem_write(0x4002_1034, bytes(12))  # RCC IOPENR, AHBENR, APBENR1

    def _pb2_update(self):
        level = 0 if ((self.gpiob_moder >> 4) & 3) == 1 and not self.gpiob_odr & 4 else 1
        if level != self.pb2:
            t = self.now()
            self.pb2_edges.append((round(t, 6), level))
            if level == 0:  # falling edge: EN_WDI feeds the dog
                self.wdt_feeds.append(round(t, 6))
                self.wdt_last_feed = t
            self.pb2 = level

    def _tim_update(self):
        tim = self.tim
        clocked = struct.unpack("<I", self.uc.mem_read(RCC_APBENR1, 4))[0] & 0x10
        if not (tim["cr1"] & 1 and clocked):
            return
        period = (tim["arr"] + 1) * (tim["psc_active"] + 1) / CPU_HZ
        elapsed = self.now() - tim["t0"]
        if elapsed >= period:
            tim["t0"] += int(elapsed // period) * period
            tim["sr"] |= 1
            tim["psc_active"] = tim["psc"]

    def _tim_sync(self, c):
        """TIM6 lives in memory; its update flag only changes when emulated time moves (or the
        relay writes TIM6), so it is brought up to date there, not on every read."""
        self._tim_update()
        c.mem_write(TIM6 + 0x10, struct.pack("<I", self.tim["sr"]))

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
        self._reset_peripherals()
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
            self.clock_s += len(data) * ROM_BYTE_S
            if self.rom_bytes_until_reset is not None:
                self.rom_bytes_until_reset -= len(data)
                if self.rom_bytes_until_reset <= 0:
                    self.rom_bytes_until_reset = None
                    self._wdt_reset()
                    self._reset_to_rom()
                    return
            if self._wdt_due():
                self._wdt_reset()
                self._reset_to_rom()
                return  # these bytes arrived while the case was in reset
            self.rom_in.extend(data)
            try:
                next(self.rom)
            except StopIteration:  # Go: the ROM loader has jumped
                pass
        elif self.mode == "bridge":
            with self.cond:
                self.host_in.extend(data)
                self.cond.notify_all()

    def _reset_to_rom(self):
        """An external reset (the 4005's RST) while the host holds DTR released: the ROM again."""
        self.resets += 1
        self._reset_peripherals()
        with self.cond:
            self.host_in.clear()
        self.mode = "rom-wait-sync"
        self.rom = self._rom()
        next(self.rom)

    # ---------------------------------------------------------------- ROM loader
    def _rom(self):
        self.rom_in = deque()

        def out(b):
            self.clock_s += len(b) * ROM_BYTE_S
            self._emit(bytes(b), need=(115_200, "E"))

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

        first = yield from take(1)
        if first != b"\x7f":  # autobaud locked onto something else: deaf until the next reset
            self.rom_log.append(("deaf", first[0]))
            while True:
                yield from take(1)
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
        self.relay_started_at = self.now()
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

        def wdt_check(c):
            if self._wdt_due():
                self._wdt_reset()
                c.emu_stop()
                threading.Thread(target=self._sysreset, args=("wdt",), daemon=True).start()
                return True
            return False

        def advance(c, seconds):
            self.clock_s += seconds
            self._tim_sync(c)
            return wdt_check(c)

        def code(c, address, size, _):
            if address in STUB_INIT:
                if address == MX_GPIO_INIT:  # the PB2 part of the real one: WritePin low, then output
                    self.gpiob_odr &= ~4
                    self.gpiob_moder = (self.gpiob_moder & ~0x30) | 0x10
                    c.mem_write(GPIOB, struct.pack("<I", self.gpiob_moder))
                    c.mem_write(GPIOB + 0x14, struct.pack("<I", self.gpiob_odr))
                    self._pb2_update()
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
                if advance(c, self.exchange_s):
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
            elif address == DELAY_LOOP:
                turns = c.reg_read(UC_ARM_REG_R0)
                ret(c)
                advance(c, 3 * turns / CPU_HZ)
            elif address == DELAY_YHM:
                ret(c)
                advance(c, 3 * 30 * 20000 / CPU_HZ)
            elif address in POLL_COUNTERS:
                register, needs_quiet, plain, fed = POLL_COUNTERS[address]
                if needs_quiet and self.temple_rx:
                    return
                count = c.reg_read(register)
                feeding = struct.unpack("<H", c.mem_read(FED_SITE, 2))[0] != 0x2002
                seconds = (fed if feeding else plain) * CYCLES_PER_INSN / CPU_HZ
                step = min(count - 1, max(1, int(self.poll_step_s / seconds)))
                if step > 0:  # skip `step` turns of the loop; the next turn runs for real
                    c.reg_write(register, count - step)
                    advance(c, step * seconds)

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

        def gpiob_write(c, access, address, size, value, _):
            offset = address - GPIOB
            if offset == 0x00:
                self.gpiob_moder = value
            elif offset == 0x14:
                self.gpiob_odr = value & 0xFFFF
            elif offset == 0x18:  # BSRR: set the low half, reset the high half
                self.gpiob_odr = (self.gpiob_odr | (value & 0xFFFF)) & ~(value >> 16) & 0xFFFF
                c.mem_write(GPIOB + 0x14, struct.pack("<I", self.gpiob_odr))
            elif offset == 0x28:  # BRR
                self.gpiob_odr &= ~value & 0xFFFF
                c.mem_write(GPIOB + 0x14, struct.pack("<I", self.gpiob_odr))
            self._pb2_update()

        def tim6_write(c, access, address, size, value, _):
            tim, offset = self.tim, address - TIM6
            self._tim_update()
            if offset == 0x00:
                if value & 1 and not tim["cr1"] & 1:
                    tim["t0"] = self.now()
                tim["cr1"] = value
            elif offset == 0x10:  # rc_w0
                tim["sr"] &= value
            elif offset == 0x14 and value & 1:  # UG
                tim["t0"], tim["psc_active"] = self.now(), tim["psc"]
                if not tim["cr1"] & 4:  # URS = 0: UG sets the update flag too
                    tim["sr"] |= 1
            elif offset == 0x28:
                tim["psc"] = value & 0xFFFF
            elif offset == 0x2C:
                tim["arr"] = value & 0xFFFF
            if offset != 0x10:  # (an SR write lands in memory itself, right after this hook)
                c.mem_write(TIM6 + 0x10, struct.pack("<I", tim["sr"]))

        def forbidden(c, access, address, size, value, _):
            self.forbidden_writes.append((address, value))

        for address in (*STUB_INIT, STUB_I2C_READ, STUB_I2C_WRITE, STUB_UART3_TX, RELAY_WAVEFORM, DELAY_LOOP,
                        DELAY_YHM, *POLL_COUNTERS):
            uc.hook_add(u.UC_HOOK_CODE, code, begin=address, end=address)
        uc.hook_add(u.UC_HOOK_MEM_READ, mem_read, begin=0x4000_4800, end=0x4000_482F)  # USART3
        uc.hook_add(u.UC_HOOK_MEM_READ, mem_read, begin=0x4001_3800, end=0x4001_382F)  # USART1
        uc.hook_add(u.UC_HOOK_MEM_WRITE, mem_write, begin=0x4001_3828, end=0x4001_382B)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, mem_write, begin=0xE000_ED0C, end=0xE000_ED0F)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, gpiob_write, begin=GPIOB, end=GPIOB + 0x2B)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, tim6_write, begin=TIM6, end=TIM6 + 0x2F)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, forbidden, begin=FLASH, end=FLASH + FLASH_SIZE - 1)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, forbidden, begin=FLASH_REGS[0], end=FLASH_REGS[1])

    def _sysreset(self, cause="sysresetreq"):
        """A reset from inside the emulation (the bridge's SYSRESETREQ, or the 4005 firing while the
        relay runs): SRAM retained, the ROM or the app by DTR."""
        if self.thread:
            self.thread.join(5)
            self.thread = None
        if self.mode != "bridge":  # the host reset the case meanwhile (NRST); nothing left to do
            return
        self.resets += 1
        self._reset_peripherals()
        with self.cond:
            self.host_in.clear()
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
        self.want = 1
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
            if len(self.buffer) >= self.want:
                self.cond.notify_all()

    def read(self, n):
        """As pyserial: up to n bytes, waiting until there are n or the timeout (capped, 2 s)."""
        with self.cond:
            self.want = n
            self.cond.wait_for(lambda: len(self.buffer) >= n, timeout=min(self.timeout, self.case.read_cap_s))
            self.want = 1
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
