#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Checks a combined native image (Wisp Boot + app) and writes its manifest.

  - the image is Wisp Boot's binary, padded with 0xFF to exactly 64 KiB, followed by the app's
    binary, byte for byte (what tests/boot/app/combine.cmake produces);
  - rule 3 on the whole image from 0x438000 (Wisp Boot's vector table) and on the app part from
    0x448000 (its own vector table, SP below Wisp Boot's RAM), with check_image.py's functions;
  - the image ends at or before 0x7F8000;
  - with --app-config: the app is a hardware image (CONFIG_WISP_HW_IMAGE=y, an image kind other
    than 255, no enabled panel, MSPI controller or nPM13xx node);
  - with --boot-elf --observe: Wisp Boot is the observe-only build (no NOR program/erase, no
    littlefs write path, no flag write among its symbols);
  - with --bare-app-elf (stage-0): the app is bare metal, links none of those writers, and its only
    PMIC code is boot_pmic_kick (the fixed 07 04 01 kick): no I2C or HAL transfer function.

The manifest (JSON) holds the SHA-256 of the image, of Wisp Boot's binary and of its padded
64 KiB slot (what rung4.md R4-1 compares against a build that passed rung 3), of the app binary,
and of every --file name=path given (ELFs, maps): what W23 pins in wisp_w18/pins.py.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_image as ci  # noqa: E402
import wisp_layout as L  # noqa: E402


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def check(image: bytes, boot: bytes, app: bytes) -> list[str]:
    errors = []
    if len(boot) > L.WISP_BOOT_SIZE:
        errors.append(f"Wisp Boot is {len(boot)} bytes, its slot is {L.WISP_BOOT_SIZE}")
    slot = boot + b"\xff" * (L.WISP_BOOT_SIZE - len(boot))
    if image[:L.WISP_BOOT_SIZE] != slot:
        errors.append("the first 64 KiB are not Wisp Boot padded with 0xFF")
    if image[L.WISP_BOOT_SIZE:] != app:
        errors.append("the rest is not the app binary")
    errors += [f"image: {e}" for e in ci.check_vectors(L.APP_LOAD_ADDR, image)]
    errors += [f"app: {e}" for e in ci.check_vectors(L.WISP_MAIN_BASE, image[L.WISP_BOOT_SIZE:],
                                                     L.WISP_MAIN_BASE, L.WISP_BOOT_RAM_BASE)]
    return errors


HW_FORBIDDEN = re.compile(r"^CONFIG_DT_HAS_(EVEN_G2_ULED|AMBIQ_MSPI_CONTROLLER|NORDIC_NPM13\w*)_ENABLED=y$", re.M)
BOOT_WRITERS = ("nor_prog", "nor_erase_4k", "lfs_file_write", "lfs_format", "lfs_file_rawwrite",
                "lfs_mkdir", "hw_flag_set_install", "rescue_copy", "record_write", "bd_prog", "bd_erase")


def check_app_config(text: str) -> list[str]:
    errors = []
    if not re.search(r"^CONFIG_WISP_HW_IMAGE=y$", text, re.M):
        errors.append("the app is not a hardware image (CONFIG_WISP_HW_IMAGE)")
    kind = re.search(r"^CONFIG_WISP_IMAGE_KIND=(\d+)$", text, re.M)
    if not kind or kind.group(1) == "255":
        errors.append("the app's image kind is a development build")
    errors += [f"enabled in the app: {m.group(0)}" for m in HW_FORBIDDEN.finditer(text)]
    return errors


def check_boot_symbols(names: list[str]) -> list[str]:
    return [f"observe-only Wisp Boot links {n}" for n in sorted(set(names)) if n.split(".")[0] in BOOT_WRITERS]


BARE_FORBIDDEN = re.compile(r"^(z_|k_|am_hal_|i2c_|nrf|npm)", re.I)


def check_bare_app_symbols(names: list[str]) -> list[str]:
    errors = [f"bare app links {n}" for n in sorted(set(names)) if n.split(".")[0] in BOOT_WRITERS]
    errors += [f"bare app links {n} (Zephyr, HAL or I2C code)" for n in sorted(set(names))
               if BARE_FORBIDDEN.match(n)]
    if "boot_pmic_kick" not in names:
        errors.append("bare app has no boot_pmic_kick")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--image", type=Path, required=True)
    ap.add_argument("--boot", type=Path, required=True)
    ap.add_argument("--app", type=Path, required=True)
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--file", action="append", default=[], help="name=path to hash into the manifest")
    ap.add_argument("--app-config", type=Path, help="the app's zephyr/.config: require a hardware image")
    ap.add_argument("--boot-elf", type=Path, help="Wisp Boot's ELF (with --observe)")
    ap.add_argument("--observe", action="store_true", help="require the observe-only Wisp Boot")
    ap.add_argument("--bare-app-elf", type=Path, help="the app's ELF: require a bare-metal app (stage-0)")
    ap.add_argument("--nm", default="arm-none-eabi-nm")
    a = ap.parse_args()
    image, boot, app = a.image.read_bytes(), a.boot.read_bytes(), a.app.read_bytes()
    errors = check(image, boot, app)
    if a.app_config:
        errors += check_app_config(a.app_config.read_text())
    if a.observe:
        if not a.boot_elf:
            errors.append("--observe needs --boot-elf")
        else:
            nm = subprocess.run([a.nm, str(a.boot_elf)], check=True, capture_output=True, text=True).stdout
            errors += check_boot_symbols([p[-1] for p in (l.split() for l in nm.splitlines()) if p])
    if a.bare_app_elf:
        nm = subprocess.run([a.nm, str(a.bare_app_elf)], check=True, capture_output=True, text=True).stdout
        errors += check_bare_app_symbols([p[-1] for p in (l.split() for l in nm.splitlines()) if p])
    if errors:
        for e in errors:
            print(f"check_native: FAIL: {e}", file=sys.stderr)
        return 1
    slot = image[:L.WISP_BOOT_SIZE]
    manifest = {
        "image": a.name,
        "bytes": len(image),
        "end": f"{L.APP_LOAD_ADDR + len(image):#x}",
        "image_sha256": sha(image),
        "image_crc32": f"{zlib.crc32(image) & 0xFFFFFFFF:08x}",
        "wisp_boot_bin_sha256": sha(boot),
        "wisp_boot_bin_bytes": len(boot),
        "wisp_boot_slot_sha256": sha(slot),
        "app_bin_sha256": sha(app),
        "app_bin_bytes": len(app),
        "app_hardware_image": bool(a.app_config) or bool(a.bare_app_elf),
        "app_bare_metal": bool(a.bare_app_elf),
        "wisp_boot_observe_only": a.observe,
    }
    for item in a.file:
        name, path = item.split("=", 1)
        manifest[f"{name}_sha256"] = sha(Path(path).read_bytes())
    a.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"check_native: OK {a.name} {len(image)} B, end {manifest['end']}, Wisp Boot {len(boot)} B "
          f"in its 64 KiB slot, app {len(app)} B at {L.WISP_MAIN_BASE:#x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
