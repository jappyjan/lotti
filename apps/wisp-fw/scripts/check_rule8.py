#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Post-build gate for safety rule 8: the image must never be able to reflash the EM9305.

Four independent looks at the build (any one failing fails the build):

  config   .config: no EXTREF-init / crystal-trim; BT only with CONFIG_WISP_BT_ALLOWED and
           CONFIG_WISP_EM9305_SKIP_FW_UPDATE.
  sources  compile_commands.json: with BT off, no EM9305 driver source is compiled at all.
           With BT on, every compiled caller of am_devices_em9305_init() sets
           skip_fw_update = true and never anything else.
  symbols  `nm` over the ELF (local symbols too): none of the update / recovery / NVM-write
           functions and no ble_fw_image_bin_* array. With BT off, no am_devices_em9305_*
           symbol at all.
  map +    the linker map shows no EM9305 object in the final image (BT off), and none of the
  bytes    EM9305 firmware arrays from the HAL's ble_fw_image_em9305.h occur in zephyr.bin —
           this catches the image even when symbols are stripped or renamed.

Run by CMake after every link (see CMakeLists.txt); wisp-fw:test also proves it fires.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

RULE = "WISP SAFETY RULE 8 (docs/wisp/safety.md)"

# Functions that erase/write EM9305 NVM, and the bundled image. Static in
# am_devices_em9305.c, so they show up as local symbols unless inlined (hence the byte check).
DENY_SYMBOLS = [
    r"ble_fw_image_bin_\w*",
    r"image_records",
    r"erase_pages",
    r"am_devices_em9305_update_fw",
    r"em9305_nvm_recovery_reflash",
    r"fw_write_image",
    r"fw_write_data_cmd",
    r"fw_erase_nvm_main",
    r"fw_erase_page_cmd",
    r"fw_update_version",
    r"fw_verify_image",
    r"fw_enter_cm_mode",
    r"am_devices_em9305_crystal_trim_set",
    r"fw_update_info_page2_seq_dig",
]
# With BT off nothing of the driver may be present.
DENY_SYMBOLS_BT_OFF = [r"am_devices_em9305_\w+", r"am_util_ble_em9305\w*"]

EM9305_SOURCES = re.compile(r"(am_devices_em9305|am_util_ble_em9305)\.c$")
EM9305_OBJECTS = re.compile(r"(am_devices_em9305|am_util_ble_em9305)\.c\.obj")
SIGNATURE_LEN = 64


def parse_config(path: Path) -> dict[str, str]:
    cfg = {}
    for line in path.read_text().splitlines():
        m = re.match(r"(CONFIG_\w+)=(.*)", line)
        if m:
            cfg[m.group(1)] = m.group(2).strip('"')
    return cfg


def check_config(cfg: dict[str, str]) -> list[str]:
    y = lambda k: cfg.get(k) == "y"  # noqa: E731
    errors = []
    if y("CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT"):
        errors.append("CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT=y (evb path inits the EM9305 "
                      "with skip_fw_update=false when BT is off)")
    if y("CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM"):
        errors.append("CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM=y (writes EM9305 NVM)")
    if y("CONFIG_BT") or y("CONFIG_AMBIQ_COMPONENT_USE_BT"):
        if not y("CONFIG_WISP_BT_ALLOWED"):
            errors.append("Bluetooth enabled but CONFIG_WISP_BT_ALLOWED is not set "
                          "(BT stays off until milestone M6)")
        if not y("CONFIG_WISP_EM9305_SKIP_FW_UPDATE"):
            errors.append("Bluetooth enabled without CONFIG_WISP_EM9305_SKIP_FW_UPDATE=y")
    return errors


SKIP_ASSIGN = re.compile(r"\bskip_fw_update\s*=\s*([^;,}\n]+)")


def check_sources(compile_commands: Path, bt: bool) -> list[str]:
    errors = []
    files = {Path(e["file"]) for e in json.loads(compile_commands.read_text())}
    for f in sorted(files):
        if EM9305_SOURCES.search(f.name):
            if not bt:
                errors.append(f"EM9305 driver compiled with Bluetooth off: {f}")
            continue  # the driver itself: covered by the symbol and byte checks
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        if "am_devices_em9305_init" not in text:
            continue
        values = [v.strip() for v in SKIP_ASSIGN.findall(text)]
        if not values:
            errors.append(f"{f}: calls am_devices_em9305_init() without setting "
                          "skip_fw_update (defaults to false = reflash)")
        for v in values:
            if v not in ("true", "1"):
                errors.append(f"{f}: skip_fw_update = {v} (must be forced to true)")
    return errors


def elf_symbols(nm: str, elf: Path) -> list[str]:
    out = subprocess.run([nm, "--defined-only", str(elf)], check=True, capture_output=True,
                         text=True).stdout
    names = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            names.append(parts[2])
    return names


def check_symbols(names: list[str], bt: bool) -> list[str]:
    patterns = DENY_SYMBOLS + ([] if bt else DENY_SYMBOLS_BT_OFF)
    deny = re.compile(r"^(?:%s)(?:\.\w+)*$" % "|".join(patterns))  # .constprop.0 etc.
    return [f"forbidden symbol linked: {n}" for n in sorted(set(names)) if deny.match(n)]


def check_map(map_path: Path) -> list[str]:
    text = map_path.read_text(errors="replace")
    marker = text.find("Linker script and memory map")
    linked = text[marker:] if marker >= 0 else text
    hits = sorted({m.group(0) for m in EM9305_OBJECTS.finditer(linked)})
    return [f"EM9305 object in the linked image (map): {h}" for h in hits]


ARRAY = re.compile(r"ble_fw_image_bin_(\w+)\s*\[\]\s*=\s*\{(.*?)\};", re.S)


def image_signatures(hal: Path) -> list[tuple[str, bytes]]:
    header = hal / "components" / "bluetooth" / "ble_fw_image_em9305.h"
    if not header.exists():
        raise SystemExit(f"check_rule8: cannot find {header} (needed for the byte check)")
    sigs = []
    for name, body in ARRAY.findall(header.read_text()):
        data = bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", body))
        if len(data) >= 32:
            sigs.append((f"ble_fw_image_bin_{name}[0:{min(len(data), SIGNATURE_LEN)}]",
                         data[:SIGNATURE_LEN]))
            if len(data) >= 4 * SIGNATURE_LEN:
                mid = len(data) // 2
                sigs.append((f"ble_fw_image_bin_{name}[{mid}:{mid + SIGNATURE_LEN}]",
                             data[mid:mid + SIGNATURE_LEN]))
    if not sigs:
        raise SystemExit(f"check_rule8: no firmware arrays parsed from {header}")
    return sigs


def check_bytes(image: bytes, sigs: list[tuple[str, bytes]]) -> list[str]:
    return [f"EM9305 firmware bytes found in zephyr.bin: {name} at offset 0x{image.find(s):x}"
            for name, s in sigs if s in image]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--elf", type=Path, required=True)
    ap.add_argument("--bin", type=Path, required=True)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--config", type=Path, required=True)
    ap.add_argument("--compile-commands", type=Path, required=True)
    ap.add_argument("--hal", type=Path, required=True, help="hal_ambiq module directory")
    ap.add_argument("--nm", default="arm-none-eabi-nm")
    args = ap.parse_args()

    cfg = parse_config(args.config)
    bt = cfg.get("CONFIG_BT") == "y" or cfg.get("CONFIG_AMBIQ_COMPONENT_USE_BT") == "y"
    names = elf_symbols(args.nm, args.elf)
    sigs = image_signatures(args.hal)

    errors = (check_config(cfg) + check_sources(args.compile_commands, bt)
              + check_symbols(names, bt) + (check_map(args.map) if not bt else [])
              + check_bytes(args.bin.read_bytes(), sigs))
    if errors:
        for e in errors:
            print(f"check_rule8: FAIL: {e}", file=sys.stderr)
        print(f"check_rule8: image rejected — {RULE}", file=sys.stderr)
        return 1
    print(f"check_rule8: OK bt={'on' if bt else 'off'}, {len(names)} symbols, "
          f"no forbidden symbols, map clean, {len(sigs)} EM9305 image signatures absent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
