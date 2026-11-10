#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The facts install-wisp's pin would need for a packaged native image (rung4.md, "W24d: stage-0b", "W24e: stage-0c").

    python3 -I apps/wisp-fw/scripts/propose_pin.py stage-0c --commit <sha> [--cache .wisp-cache]

Reads apps/wisp-recovery/wisp_w18/data/<image>/ (as scripts/package_native.sh left it) and writes
proposed-pin.json next to the files: the WISP_IMAGES entry (image, stripped ELF and map hashes, the
build's gates, crc32 of the image, crc32_aligned_over_stock = the final CRC install-wisp reports when
it writes the image over the stock 2.4.0.24 main, the Wisp Boot slot), and, outside the pin entry,
the final CRC install-wisp reports when it writes the image over each pinned Wisp image installed on
top of stock (`crc32_aligned_over`: a temple left with stage-0b installed, rung4.md W24e), the Wisp Boot slot's
WISP_BOOT_PASSED entry with the suites still to be filled in by the review, and the address of Wisp
Boot's status block `st` for pins.PEEK_REGIONS["wisp-boot-status"]. It pins nothing: the pin table
(wisp_w18/pins.py) changes only in a reviewed commit. The Renode harness (tests/boot/w18.py) loads
this file into the pin tables in memory to run install-wisp's gate on the committed files.
"""
import argparse
import hashlib
import json
import subprocess
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "apps/wisp-recovery"))
from wisp_w18 import image, pins  # noqa: E402

APPS = {"stage-0b": ("stage-0b.bin", "stage0.elf", "stage0.map"), "stage-0c": ("stage-0c.bin", "stage0.elf", "stage0.map")}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def symbol(elf: Path, name: str) -> int:
    out = subprocess.run(["arm-none-eabi-nm", str(elf)], check=True, capture_output=True, text=True).stdout
    found = [int(p[0], 16) for p in (l.split() for l in out.splitlines()) if len(p) == 3 and p[2] == name]
    if len(found) != 1:
        raise SystemExit(f"{elf}: symbol {name}: {found}")
    return found[0]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("image", choices=sorted(APPS))
    ap.add_argument("--commit", required=True, help="the source commit the files were built from")
    ap.add_argument("--cache", type=Path, default=REPO / ".wisp-cache")
    a = ap.parse_args()
    d = REPO / "apps/wisp-recovery/wisp_w18/data" / a.image
    bin_name, elf_name, map_name = APPS[a.image]
    data = (d / bin_name).read_bytes()
    manifest = json.loads((d / "manifest.json").read_text())
    if manifest["image_sha256"] != sha(data):
        raise SystemExit("manifest.json is not this image's")
    slot = data[: pins.WISP_BOOT_SLOT_BYTES]
    end = pins.APP_BASE + ((len(data) + 15) & ~15)
    stock = image.stock_main(a.cache / "stock")
    over_stock = data + stock[len(data): end - pins.APP_BASE]
    # install-wisp keeps whatever follows the image in its last 16-byte unit (session.py AppWriter),
    # so over a Wisp image that was itself written over stock, those bytes are that image's or stock's.
    over = {"stock": f"{zlib.crc32(over_stock):#010x}"}
    for name, pin in sorted(pins.WISP_IMAGES.items()):
        prev_path = REPO / "apps/wisp-recovery/wisp_w18/data" / name / f"{name}.bin"
        if name == a.image or not prev_path.exists():
            continue
        region = bytearray(stock[: max(end - pins.APP_BASE, len(stock))])
        prev = prev_path.read_bytes()
        if image.sha(prev) != pin["image_sha256"]:
            raise SystemExit(f"{prev_path} is not the pinned {name}")
        region[: len(prev)] = prev
        over[name] = f"{zlib.crc32(data + bytes(region[len(data): end - pins.APP_BASE])):#010x}"
    out = {
        "note": "PROPOSED, NOT PINNED: copy `image` into wisp_w18/pins.py only in the reviewed pinning commit "
                "(rung4.md W24d, W24e). The suites below are the builder's rule-12 runs; the review reruns them.",
        "image": {
            "commit": a.commit,
            "image_sha256": sha(data),
            "image_bytes": len(data),
            "elf_sha256": sha((d / elf_name).read_bytes()),
            "map_sha256": sha((d / map_name).read_bytes()),
            "gates": ["check_rule8", "no-mram-write"],
            "crc32": f"{zlib.crc32(data):#010x}",
            "crc32_aligned_over_stock": f"{zlib.crc32(over_stock):#010x}",
            "wisp_boot_slot_sha256": sha(slot),
        },
        "wisp_boot": {
            "build": f"observe-only (-DWISP_BOOT_OBSERVE=ON -DWISP_BOOT_LOG=OFF), commit {a.commit}",
            "wisp_boot_bin_sha256": manifest["wisp_boot_bin_sha256"],
            "suites": {
                "stock-2.4.0.24": f"observe suite: see rung4.md {'W24e' if a.image == 'stage-0c' else 'W24d'}",
                "patched-87e2d4e0": f"observe suite: see rung4.md {'W24e' if a.image == 'stage-0c' else 'W24d'}",
            },
        },
        "crc32_aligned_over": over,  # install-wisp's final CRC by what the region held before (stock or a pin)
        "write_bound": f"{end:#x}",  # install-wisp's end bound; manifest.json's "end" is the image's own end
        "peek_wisp_boot_status": f"{symbol(d / 'wisp_boot.elf', 'st'):#x}",
    }
    (d / "proposed-pin.json").write_text(json.dumps(out, indent=2) + "\n")
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
