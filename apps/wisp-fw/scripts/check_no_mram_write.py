#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""No-MRAM-write gate (docs/wisp/rung4.md G13, safety.md rule 1: "the native app links no MRAM
write path at all").

The bootloader region is the one thing case recovery cannot repair, so the Wisp app (and the
observe-only Wisp Boot) must be unable to write MRAM. Every MRAM write on the Apollo510 goes
through the boot ROM's helpers (nv_program_main2 at 0x0200FF20, nv_program_info_area at
0x0200FF0C, otp_program_info_area at 0x0200FF54, ...) with the program key 0x12344321, usually
wrapped by hal_ambiq's am_hal_mram_* or Zephyr's Ambiq flash driver. This gate looks at what got
linked, five ways, and fails on any hit:

  1. symbols  (nm, locals included): am_hal_mram_*, nv_program_*, am_hal_bootrom_*,
              g_am_hal_bootrom_helper, *_program_info*, am_hal_info*_program*, flash_ambiq_*,
              hw_flag_set_install (Wisp Boot's flag write)
  2. map      no input section (code or data) of am_hal_mram.c, am_hal_bootrom_helper.c or the
              Ambiq flash driver in the linked image
  3. config   no Ambiq flash driver Kconfig (CONFIG_FLASH_AMBIQ, CONFIG_SOC_FLASH_AMBIQ, ...)
  4. bytes    the raw image holds neither the program key nor an address in the boot ROM's helper
              table [0x0200FF00, 0x0200FF80) as a little-endian word at any byte offset (catches
              literal pools with symbols stripped)
  5. code     no movw/movt pair in the disassembly builds one of those values in a register

Usage: check_no_mram_write.py --elf X.elf --bin X.bin [--map X.map] [--config .config]
       [--objdump arm-none-eabi-objdump] [--nm arm-none-eabi-nm] [--skip BYTES]
--skip leaves the first BYTES of the .bin out of the byte look (a combined image's Wisp Boot part,
which is gated on its own).
"""
import argparse
import re
import struct
import subprocess
import sys
from pathlib import Path

PROGRAM_KEY = 0x12344321
HELPER_LO, HELPER_HI = 0x0200FF00, 0x0200FF80

DENY_SYMBOLS = re.compile(
    r"^(?:am_hal_mram_\w*|nv_program_\w*|am_hal_bootrom_\w*|g_am_hal_bootrom_helper|"
    r"\w*_program_info\w*|am_hal_info\w*_program\w*|flash_ambiq_\w*|hw_flag_set_install)"
    r"(?:\.\w+)*$")
DENY_OBJECTS = re.compile(r"\b(am_hal_mram\.c\.obj|am_hal_bootrom_helper\.c\.obj|flash_ambiq\w*\.c\.obj)")
# Driver switches only: CONFIG_DT_HAS_* says a devicetree node exists, not that a driver is built.
DENY_CONFIG = re.compile(r"^((?!CONFIG_DT_HAS_)(?:CONFIG_\w*FLASH\w*AMBIQ\w*|CONFIG_\w*AMBIQ\w*FLASH\w*|"
                         r"CONFIG_\w*MRAM\w*))=y", re.M)


def forbidden_value(v: int) -> bool:
    v &= 0xFFFFFFFF
    return v == PROGRAM_KEY or HELPER_LO <= (v & ~1) < HELPER_HI


def check_symbols(names) -> list[str]:
    return [f"MRAM write symbol linked: {n}" for n in sorted(set(names)) if DENY_SYMBOLS.match(n)]


def check_map(text: str) -> list[str]:
    marker = text.find("Linker script and memory map")
    linked = text[marker:] if marker >= 0 else text
    out = set()
    lines = linked.splitlines()
    for i, line in enumerate(lines):
        m = DENY_OBJECTS.search(line)
        if not m:
            continue
        # An input-section line: " .text.foo  0xADDR  0xSIZE  obj", or the name on the line before.
        head = line if line.lstrip().startswith(".") else (lines[i - 1] if i else "")
        sec = head.split()[0] if head.split() else ""
        if sec.startswith(".debug") or sec.startswith(".comment") or sec.startswith(".ARM.attributes"):
            continue
        sizes = re.findall(r"0x([0-9a-fA-F]+)", line)
        if len(sizes) >= 2 and int(sizes[1], 16) == 0:
            continue
        out.add(f"MRAM write object in the linked image (map): {sec} from {m.group(1)}")
    return sorted(out)


def check_config(text: str) -> list[str]:
    return [f"MRAM / flash driver enabled: {m.group(1)}" for m in DENY_CONFIG.finditer(text)]


def check_bytes(data: bytes, skip: int = 0) -> list[str]:
    hits = []
    for off in range(skip, len(data) - 3):
        v = struct.unpack_from("<I", data, off)[0]
        if forbidden_value(v):
            hits.append(f"forbidden word {v:#010x} at image offset {off:#x}")
            if len(hits) > 20:
                break
    return hits


MOV = re.compile(r"^\s*([0-9a-f]+):.*?\bmov([wt])(?:\.w)?\s+(r\d+|ip|lr|sl|fp),\s*#(\d+|0x[0-9a-f]+)", re.I)


def check_code(disasm: str) -> list[str]:
    """movw rX, #lo ... movt rX, #hi pairs (within the same straight run of code)."""
    hits = []
    low: dict[str, tuple[int, str]] = {}
    for line in disasm.splitlines():
        if re.match(r"^[0-9a-f]+ <", line):  # a new function
            low.clear()
            continue
        m = MOV.match(line)
        if not m:
            continue
        addr, kind, reg, imm = m.group(1), m.group(2).lower(), m.group(3), int(m.group(4), 0)
        if kind == "w":
            low[reg] = (imm & 0xFFFF, addr)
        elif reg in low:
            v = (imm & 0xFFFF) << 16 | low[reg][0]
            if forbidden_value(v):
                hits.append(f"movw/movt builds {v:#010x} in {reg} at {low[reg][1]}..{addr}")
    return hits


def run(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--elf", type=Path, required=True)
    ap.add_argument("--bin", type=Path, required=True)
    ap.add_argument("--map", type=Path)
    ap.add_argument("--config", type=Path)
    ap.add_argument("--nm", default="arm-none-eabi-nm")
    ap.add_argument("--objdump", default="arm-none-eabi-objdump")
    ap.add_argument("--skip", type=lambda s: int(s, 0), default=0)
    a = ap.parse_args(argv)
    errors = []
    nm = subprocess.run([a.nm, "--defined-only", str(a.elf)], check=True, capture_output=True, text=True).stdout
    names = [p[2] for p in (l.split() for l in nm.splitlines()) if len(p) == 3]
    errors += check_symbols(names)
    if a.map:
        errors += check_map(a.map.read_text(errors="replace"))
    if a.config:
        errors += check_config(a.config.read_text())
    errors += check_bytes(a.bin.read_bytes(), a.skip)
    dis = subprocess.run([a.objdump, "-d", "--no-show-raw-insn", str(a.elf)], check=True, capture_output=True,
                         text=True).stdout
    errors += check_code(dis)
    if errors:
        print("check_no_mram_write: FAILED (rung4.md G13: the app must link no MRAM write path)", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    print(f"check_no_mram_write: OK {len(names)} symbols, map clean, no program key or boot-ROM helper "
          f"address in {len(a.bin.read_bytes()) - a.skip} bytes or built by movw/movt")
    return 0


if __name__ == "__main__":
    sys.exit(run())
