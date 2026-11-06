#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Post-build image gate (safety rules 1 and 3, docs/wisp/safety.md).

Fails the build unless the image
  - is linked to run from APP_LOAD_ADDR (0x438000), with nothing loaded below it,
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


def check_vectors(load_addr: int, image: bytes) -> list[str]:
    """Rule 3 checks on a flat image that starts at load_addr. Returns failures."""
    errors = []
    if load_addr != L.APP_LOAD_ADDR:
        errors.append(f"load address 0x{load_addr:08x} != 0x{L.APP_LOAD_ADDR:08x}")
    end = load_addr + len(image)
    if end > L.APP_END_LIMIT:
        errors.append(
            f"image end 0x{end:08x} > limit 0x{L.APP_END_LIMIT:08x} "
            f"({end - L.APP_END_LIMIT} bytes over)")
    if len(image) < 8:
        errors.append(f"image too small for a vector table ({len(image)} bytes)")
        return errors
    sp, reset = struct.unpack_from("<II", image, 0)
    if not (L.SRAM_START < sp <= L.SRAM_END):
        errors.append(
            f"initial SP 0x{sp:08x} not in SRAM (0x{L.SRAM_START:08x}, 0x{L.SRAM_END:08x}]")
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
    args = ap.parse_args()

    segments = elf_segments(args.elf)
    loaded = [s for s in segments if s[1]]
    load_addr = min(lma for lma, _ in loaded) if loaded else 0
    image = args.bin.read_bytes()

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
