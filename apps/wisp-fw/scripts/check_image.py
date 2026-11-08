#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Post-build image gate (safety rules 1 and 3, docs/wisp/safety.md).

Fails the build unless the image
  - is linked to run from APP_LOAD_ADDR (0x438000), with nothing loaded below it (--part image:
    Wisp Boot, or a whole native image = Wisp Boot + app), or from WISP_MAIN_BASE (0x448000)
    (--part app: the Wisp app, entered by Wisp Boot; its RAM and initial SP also stay below
    Wisp Boot's RAM at 0x20370000),
  - ends at or before APP_END_LIMIT (0x7F8000), with nothing loaded past it,
  - starts with a vector table whose initial SP points into SRAM (and is 8-byte aligned)
    and whose reset vector is Thumb (bit 0 set) and inside the image.
wisp-ota re-checks the same rules independently on the packed bundle.
"""

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import wisp_layout as L  # noqa: E402


def check_vectors(load_addr: int, image: bytes, base: int = L.APP_LOAD_ADDR,
                  sp_limit: int = L.SRAM_END) -> list[str]:
    """Rule 3 checks on a flat image that starts at load_addr. Returns failures."""
    errors = []
    if load_addr != base:
        errors.append(f"load address 0x{load_addr:08x} != 0x{base:08x}")
    end = load_addr + len(image)
    if end > L.APP_END_LIMIT:
        errors.append(
            f"image end 0x{end:08x} > limit 0x{L.APP_END_LIMIT:08x} "
            f"({end - L.APP_END_LIMIT} bytes over)")
    if len(image) < 8:
        errors.append(f"image too small for a vector table ({len(image)} bytes)")
        return errors
    sp, reset = struct.unpack_from("<II", image, 0)
    if not (L.SRAM_START < sp <= sp_limit):
        errors.append(
            f"initial SP 0x{sp:08x} not in SRAM (0x{L.SRAM_START:08x}, 0x{sp_limit:08x}]")
    elif sp & 7:
        errors.append(f"initial SP 0x{sp:08x} not 8-byte aligned")
    if not reset & 1:
        errors.append(f"reset vector 0x{reset:08x} is not Thumb (bit 0 clear)")
    if not (load_addr <= (reset & ~1) < end):
        errors.append(
            f"reset vector 0x{reset:08x} outside the image [0x{load_addr:08x}, 0x{end:08x})")
    return errors


def check_segments(segments: list[tuple[int, int]]) -> list[str]:
    """segments: (lma, filesz) of every PT_LOAD with file content. Rule 1: MRAM writes only
    inside [APP_LOAD_ADDR, APP_END_LIMIT)."""
    errors = []
    for lma, size in segments:
        if size == 0:
            continue
        end = lma + size
        in_mram = lma < L.MRAM_END and end > L.SBL_START
        if in_mram and (lma < L.APP_LOAD_ADDR or end > L.APP_END_LIMIT):
            errors.append(
                f"loadable segment [0x{lma:08x}, 0x{end:08x}) leaves the app region "
                f"[0x{L.APP_LOAD_ADDR:08x}, 0x{L.APP_END_LIMIT:08x})")
        elif not in_mram:
            errors.append(f"loadable segment [0x{lma:08x}, 0x{end:08x}) is not in MRAM")
    return errors


def check_ram(sections: list[tuple[str, int, int]]) -> list[str]:
    """The app's RAM (every allocated section in SRAM) must end at or below Wisp Boot's RAM."""
    return [f"section {name} [0x{addr:08x}, 0x{addr + size:08x}) reaches into Wisp Boot's RAM "
            f"(0x{L.WISP_BOOT_RAM_BASE:08x}+)"
            for name, addr, size in sections
            if size and L.SRAM_START <= addr < L.SRAM_END + 0x80000 and addr + size > L.WISP_BOOT_RAM_BASE]


def elf_ram_sections(elf_path: Path) -> list[tuple[str, int, int]]:
    from elftools.elf.elffile import ELFFile

    with elf_path.open("rb") as f:
        elf = ELFFile(f)
        return [(s.name, s["sh_addr"], s["sh_size"]) for s in elf.iter_sections()
                if s["sh_flags"] & 0x2]  # SHF_ALLOC


def elf_segments(elf_path: Path) -> list[tuple[int, int]]:
    from elftools.elf.elffile import ELFFile

    with elf_path.open("rb") as f:
        elf = ELFFile(f)
        return [(s["p_paddr"], s["p_filesz"]) for s in elf.iter_segments()
                if s["p_type"] == "PT_LOAD"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--elf", type=Path, required=True)
    ap.add_argument("--bin", type=Path, required=True)
    ap.add_argument("--part", choices=("image", "app"), default="image",
                    help="image: runs from 0x438000 (Wisp Boot, a whole native image); "
                         "app: the Wisp app at 0x448000 behind Wisp Boot")
    args = ap.parse_args()

    segments = elf_segments(args.elf)
    loaded = [s for s in segments if s[1]]
    load_addr = min(lma for lma, _ in loaded) if loaded else 0
    image = args.bin.read_bytes()

    if args.part == "app":
        errors = (check_segments(segments) +
                  check_vectors(load_addr, image, L.WISP_MAIN_BASE, L.WISP_BOOT_RAM_BASE) +
                  check_ram(elf_ram_sections(args.elf)))
    else:
        errors = check_segments(segments) + check_vectors(load_addr, image)
    end = load_addr + len(image)
    if errors:
        for e in errors:
            print(f"check_image: FAIL: {e}", file=sys.stderr)
        print("check_image: image rejected (docs/wisp/safety.md rules 1 and 3)", file=sys.stderr)
        return 1
    sp, reset = struct.unpack_from("<II", image, 0)
    print(f"check_image: OK load 0x{load_addr:08x} end 0x{end:08x} "
          f"({L.APP_END_LIMIT - end} bytes free) SP 0x{sp:08x} reset 0x{reset:08x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
