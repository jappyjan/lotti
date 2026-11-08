# SPDX-License-Identifier: MIT
"""The W18 RAM programs as the patched loader runs them, under Unicorn (Thumb-2, M-profile): the
real binaries from wisp_w18/data/, called like boot_ram_invoke calls them (r0 = the ram_api, r1 =
arg0, r2 = arg1). No hardware.

Everything outside the program itself is a model, and every access the program makes outside its
code, its stack and the ram_api is recorded, so a test can check the whole footprint:
  - the loader's send()/recv(): one exchange per 16 bytes, each advancing the RTOS tick by
    `ticks_per_exchange` (18 ticks = 17.5 ms, the hardware's measured exchange time);
  - the bootloader functions the programs call at pinned addresses: xTaskGetTickCount, the IOM HAL's
    power_ctrl (with its saved-state flag: a refused DEEPSLEEP leaves no saved state, and WAKE with
    retain is then refused with 7, as at 0x42CD08 in the bootloader), the stock MRAM routine (as
    stubs that record their arguments);
  - IOM7's registers, with the nPM1300 behind it: STATUS idle, FIFOPTR with room, INTSTAT set by a
    command (CMDCMP, or NAK when `nak`); a write transaction to 0x6B is decoded to its wire bytes;
    a read (CMD READ with a 2-byte offset, OFFSETHI then OFFSETLO on the wire) is decoded to its
    register address, answered from `pmic_registers` into the receive FIFO, which FIFOPTR's
    FIFO1SIZ counts and FIFOPOP pops (`nak_reads`: reads NAK; `rx_bytes`: bytes a read returns).
    A read command or a FIFOPOP access is a violation unless the test sets `allow_reads`, so the
    programs that only kick keep their footprint (only pmic_read reads);
  - MRAM (0x400000-0x800000): readable; written only through the MRAM routine stub.
"""

from __future__ import annotations

import struct

import unicorn as u
from unicorn.arm_const import (UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2,
                               UC_ARM_REG_R3, UC_ARM_REG_SP)

from wisp_w18 import image, pins

MRAM, MRAM_SIZE = 0x0040_0000, 0x0040_0000
SRAM, SRAM_SIZE = 0x2000_0000, 0x0008_0000
CODE = 0x2007_0000  # where the loader's code[512] buffer would be; any RAM works (the code is PIC)
STACK_TOP = 0x2007_F000
API = 0x2006_0000  # the ram_api struct and the `failed` context word
SCRATCH = 0x2006_1000
STUBS, STUB_SIZE = 0x1000_0000, 0x1000
SEND, RECV, DONE = STUBS + 0x10, STUBS + 0x20, STUBS + 0x100
IOM7 = 0x4005_7000
SCB = 0xE000_E000
CACHE_CLEAN = 0xE000_EF5C  # DCIMVAC, written by recover(_fed) after each block
TICK = pins.TICK_COUNT & ~1
POWER = pins.IOM_POWER_CTRL & ~1
MRAM_WRAPPER = pins.MRAM_WRAPPER_2_3_2_14 & ~1
BL_STUBS = (TICK, POWER, MRAM_WRAPPER)

IOM7_WRITES = {0x200: "INTEN", 0x208: "INTCLR", 0x2C4: "DEVCFG", 0x128: "OFFSETHI", 0x10C: "FIFOPUSH",
               0x120: "CMD"}
IOM7_READS = {0x248: "STATUS", 0x100: "FIFOPTR", 0x204: "INTSTAT", 0x200: "INTEN", 0x108: "FIFOPOP"}


class TempleCpu:
    def __init__(self, mram: bytes = b"", ticks_per_exchange: int = 18):
        self.ticks = 0
        self.ticks_per_exchange = ticks_per_exchange
        self.sent: list[bytes] = []  # every exchange's payload, as the loader would frame it
        self.input = bytearray()  # recv() source
        self.received = 0
        self.power_calls: list[tuple[int, int, int, int]] = []  # (handle, state, retain, tick)
        self.power_result = {0: 0, 2: 0}  # power_ctrl's return value per state (0 = as the HAL)
        self.iom_powered = False
        self.saved_state = True  # HAL_I2CInit left IOM7 in DEEPSLEEP with retain
        self.nak = False
        self.complete = True  # False: a command never reports CMDCMP (a timeout, 0x400)
        self.status_idle = True
        self.fifo_room = 32
        self.wire: list[tuple[int, bytes, int]] = []  # (I2C address, bytes, tick) per write transaction
        self.reads: list[tuple[int, int, int]] = []  # (I2C address, register, bytes) per read transaction
        self.transactions: list[tuple] = []  # ("w", address, bytes) / ("r", address, register), in order
        self.pmic_registers: dict[int, int] = {}  # a read of a register not in it returns (reg * 7) & 0xFF
        self.allow_reads = False
        self.nak_reads = False
        self.rx_bytes = 1  # bytes the PMIC answers a 1-byte read with (0: none arrive)
        self.rx: list[int] = []  # IOM7's receive FIFO
        self.footprint: list[tuple[str, int, int]] = []  # ("r"/"w", address, value) outside the program
        self.violations: list[str] = []
        self.mram_writes: list[tuple[int, int]] = []
        self.tick_calls = 0
        self._push: list[int] = []
        self._iom = {0x200: 0, 0x204: 0, 0x2C4: 0, 0x128: 0}
        self.uc = uc = u.Uc(u.UC_ARCH_ARM, u.UC_MODE_THUMB | u.UC_MODE_MCLASS)
        uc.mem_map(MRAM, MRAM_SIZE)
        uc.mem_map(SRAM, SRAM_SIZE)
        uc.mem_map(STUBS, STUB_SIZE)
        uc.mem_map(IOM7, 0x1000)
        uc.mem_map(SCB, 0x1000)
        if mram:
            uc.mem_write(MRAM, mram)
        for stub in (SEND, RECV, DONE, *BL_STUBS):
            uc.mem_write(stub, b"\x70\x47")  # bx lr (never reached: the hooks return first)
        # The bootloader's I2C table entry 7 and the handle it points at, as HAL_I2CInit leaves them.
        uc.mem_write(pins.I2C_TABLE_ENTRY_7, struct.pack("<4I", 7, pins.IOM7_HAL_HANDLE, 0x4341F0, 0x20000350))
        uc.mem_write(API, struct.pack("<4I", 2, SEND | 1, API + 0x10, RECV | 1) + bytes(4))
        self._hooks()

    # --- the bootloader and the loader, as stubs ---
    def _ret(self, c, value):
        c.reg_write(UC_ARM_REG_R0, value & 0xFFFFFFFF)
        c.reg_write(UC_ARM_REG_PC, c.reg_read(UC_ARM_REG_LR))

    def _exchanges(self, n: int) -> None:
        self.ticks += self.ticks_per_exchange * max(1, -(-n // 16))

    def _code(self, c, address, size, _):
        r0, r1, r2, r3 = (c.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3))
        if address == DONE:
            c.emu_stop()
        elif address == SEND:
            data = bytes(c.mem_read(r1, r2))
            for i in range(0, len(data), 16):
                self.sent.append(data[i : i + 16])
                self._exchanges(16)
            self._ret(c, 0)
        elif address == RECV:
            chunk = bytes(self.input[self.received : self.received + min(r2, 16)])
            self.received += len(chunk)
            c.mem_write(r1, chunk)
            self._exchanges(16)
            self._ret(c, len(chunk))
        elif address == TICK:
            self.tick_calls += 1
            self._ret(c, self.ticks)
        elif address == POWER:
            state = r1 & 0xFF
            self.power_calls.append((r0, state, r2 & 0xFF, self.ticks))
            result = self.power_result.get(state, 6)
            if state == 0 and result == 0 and (r2 & 0xFF) and not self.saved_state:
                result = 7  # AM_HAL_STATUS_INVALID_OPERATION: nothing to restore
            if state == 2 and result == 0 and not self.status_idle:
                result = 3  # AM_HAL_STATUS_IN_USE: IOM7 not idle (0x42CE38-0x42CE54)
            if result == 0:
                self.iom_powered = state == 0
                self.saved_state = state == 2
            self._ret(c, result)
        elif address == MRAM_WRAPPER:
            if r0 != 0x12344321:
                self.violations.append(f"MRAM routine called with key {r0:#x}")
                self._ret(c, 1)
                return
            data = bytes(c.mem_read(r1, 4 * r3))
            c.mem_write(r2, data)
            self.mram_writes.append((r2, len(data)))
            self._ret(c, 0)

    # --- IOM7 and the PMIC ---
    def _iom_read(self, c, access, address, size, value, _):
        offset = address - IOM7
        if offset not in IOM7_READS:
            self.violations.append(f"IOM7 read at +{offset:#x}")
        if not self.iom_powered:
            self.violations.append(f"IOM7 read at +{offset:#x} while it is powered off")
        self.footprint.append(("r", address, 0))
        if offset == 0x248:
            v = 4 if self.status_idle else 2
        elif offset == 0x100:
            v = self.fifo_room << 8 | min(len(self.rx), 255) << 16
        elif offset == 0x108:
            if not self.allow_reads:
                self.violations.append("FIFOPOP read")
            popped, self.rx = self.rx[:4], self.rx[4:]
            v = int.from_bytes(bytes(popped).ljust(4, b"\0"), "little")
        else:
            v = self._iom.get(offset, 0)
        c.mem_write(address & ~3, struct.pack("<I", v))

    def _iom_write(self, c, access, address, size, value, _):
        offset = address - IOM7
        if offset not in IOM7_WRITES or size != 4:
            self.violations.append(f"IOM7 write at +{offset:#x} ({size} B)")
        if not self.iom_powered:
            self.violations.append(f"IOM7 write at +{offset:#x} while it is powered off")
        self.footprint.append(("w", address, value))
        if offset == 0x208:
            self._iom[0x204] &= ~value & 0xFFFFFFFF
        elif offset == 0x10C:
            self._push += list(struct.pack("<I", value))
        elif offset == 0x120:
            push, self._push = self._push, []
            if value & 0xF == 1:
                tsize, offset_count = (value >> 8) & 0xFFF, (value >> 4) & 7
                if offset_count:
                    self.violations.append("unexpected offset bytes in a PMIC write")
                self.wire.append((self._iom[0x2C4] & 0x7F, bytes(push[:tsize]), self.ticks))
                self.transactions.append(("w", self._iom[0x2C4] & 0x7F, bytes(push[:tsize])))
                if self.complete:
                    self._iom[0x204] |= 0x10 | 1 if self.nak else 1
            elif value & 0xF == 2:
                if not self.allow_reads:
                    self.violations.append("a read command")
                tsize, offset_count = (value >> 8) & 0xFFF, (value >> 4) & 7
                if push:
                    self.violations.append("bytes pushed before a read")
                if offset_count != 2:
                    self.violations.append(f"a PMIC read with {offset_count} offset bytes")
                register = (self._iom[0x128] & 0xFF) << 8 | value >> 24
                address = self._iom[0x2C4] & 0x7F
                self.reads.append((address, register, tsize))
                self.transactions.append(("r", address, register))
                if self.complete:
                    if self.nak_reads:
                        self._iom[0x204] |= 0x10 | 1
                    else:
                        byte = self.pmic_registers.get(register, (register * 7) & 0xFF)
                        self.rx += [byte] * min(tsize, self.rx_bytes)
                        self._iom[0x204] |= 1
            else:
                self.violations.append(f"IOM7 command {value:#x}")
        else:
            self._iom[offset] = value

    def _any(self, c, access, address, size, value, _):
        """Everything outside the program's own code, stack and ram_api."""
        inside = (CODE <= address < CODE + 0x1000 or STACK_TOP - 0x4000 <= address < STACK_TOP
                  or API <= address < API + 0x20 or SCRATCH <= address < SCRATCH + 0x1000)
        if inside or IOM7 <= address < IOM7 + 0x1000:
            return
        write = access == u.UC_MEM_WRITE
        self.footprint.append(("w" if write else "r", address, value if write else 0))
        if write and not (address == CACHE_CLEAN and size == 4):
            self.violations.append(f"write {value:#x} to {address:#x}")
        elif not write and not (MRAM <= address < MRAM + MRAM_SIZE
                                or pins.I2C_TABLE_ENTRY_7 <= address < pins.I2C_TABLE_ENTRY_7 + 8):
            self.violations.append(f"read at {address:#x}")

    def _hooks(self):
        uc = self.uc
        for address in (SEND, RECV, DONE, *BL_STUBS):
            uc.hook_add(u.UC_HOOK_CODE, self._code, begin=address, end=address)
        uc.hook_add(u.UC_HOOK_MEM_READ, self._iom_read, begin=IOM7, end=IOM7 + 0xFFF)
        uc.hook_add(u.UC_HOOK_MEM_WRITE, self._iom_write, begin=IOM7, end=IOM7 + 0xFFF)
        uc.hook_add(u.UC_HOOK_MEM_READ | u.UC_HOOK_MEM_WRITE, self._any)

    # --- running a program ---
    def run(self, name: str, arg0: int = 0, arg1: int = 0) -> int:
        code = image.program(name)  # checks its pin
        self.uc.mem_write(CODE, code)
        self.uc.reg_write(UC_ARM_REG_SP, STACK_TOP)
        self.uc.reg_write(UC_ARM_REG_LR, DONE | 1)
        self.uc.reg_write(UC_ARM_REG_R0, API)
        self.uc.reg_write(UC_ARM_REG_R1, arg0)
        self.uc.reg_write(UC_ARM_REG_R2, arg1)
        self.uc.emu_start(CODE | 1, DONE, count=200_000_000)
        if self.uc.reg_read(UC_ARM_REG_PC) & ~1 != DONE:
            raise AssertionError(f"{name} did not return (pc {self.uc.reg_read(UC_ARM_REG_PC):#x})")
        return self.uc.reg_read(UC_ARM_REG_R0)

    def kicks(self) -> list[int]:
        """Tick of every kick: the write 07 04 01 to the PMIC."""
        return [t for addr, data, t in self.wire if addr == 0x6B and data == pins.PMIC_KICK_WIRE]
