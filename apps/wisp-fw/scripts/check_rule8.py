#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Post-build gate for safety rule 8: the image must never be able to reflash the EM9305.

Independent looks at the build (any one failing fails the build):

  config   .config: no EXTREF-init / crystal-trim / public-address VSC; BT only with
           CONFIG_WISP_BT_ALLOWED and CONFIG_WISP_EM9305_SKIP_FW_UPDATE.
  sources  compile_commands.json: with BT off, no EM9305 driver source is compiled at all.
           With BT on, every compiled caller of am_devices_em9305_init() sets
           skip_fw_update = true and never anything else.
  units    BT on: the EM9305 driver and every caller, preprocessed with their exact compile
           commands (so this is the code the compiler saw): the driver carries Wisp's patch,
           no unit includes ble_fw_image_em9305.h, none contains an update / recovery /
           NVM-write function or the NVM write / erase opcodes, and callers force
           skip_fw_update = true.
  symbols  `nm` over the ELF (local symbols too): none of the update / recovery / NVM-write
           functions and no ble_fw_image_bin_* array. With BT off, no am_devices_em9305_*
           symbol at all.
  map      BT off: no EM9305 object in the final image. BT on: no input section of a
           forbidden function or array.
  code     BT on: no instruction in the disassembly loads an NVM write / erase opcode.
  bytes    none of the EM9305 firmware arrays from the HAL's ble_fw_image_em9305.h occurs
           in zephyr.bin — this catches the image even when symbols are stripped or renamed.

Run by CMake after every link (see CMakeLists.txt); wisp-fw:test also proves it fires.
"""

import argparse
import json
import re
import shlex
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
    r"fw_crc32_request",
    r"fw_check_programmed",
    r"fw_exit_cm_mode",
    r"am_devices_em9305_register_cm_gpio",
    r"am_devices_em9305_register_cm_pwm_ops",
    r"\w*em9305_cm_pwm_ctrl",
    r"\w*em9305_set_cm",
    r"g_cm_pwm_ctrl",
    r"g_fw_image_records",
    r"g_fw_erase_pages\w*",
]
# Identifiers that must not occur at all in a preprocessed EM9305 unit (BT on).
DENY_IDENTS = [
    "ble_fw_image_bin_", "image_records", "erase_pages", "am_devices_em9305_update_fw",
    "em9305_nvm_recovery_reflash", "fw_write_image", "fw_write_data_cmd", "fw_erase_nvm_main",
    "fw_erase_page_cmd", "fw_update_version", "fw_verify_image", "fw_enter_cm_mode",
    "crystal_trim_set", "register_cm_pwm_ops", "register_cm_gpio", "cm_pwm_ctrl",
]
# Vendor commands that write or erase EM9305 NVM (and the public-address one, whose
# persistence is unknown). Their values are read from the driver sources.
DENY_OPCODES = [
    "HCI_VSC_WRITE_AT_ADDRESS_OPCODE",
    "HCI_VSC_NVM_ERASE_NVM_MAIN_OPCODE",
    "HCI_VSC_NVM_ERASE_PAGE_OPCODE",
    "HCI_VSC_SET_DEV_PUB_ADDR_CMD_OPCODE",
]
PATCH_MARKER = "WISP_EM9305_NO_NVM_WRITE"
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
    if y("CONFIG_BT_HCI_SET_PUBLIC_ADDR"):
        errors.append("CONFIG_BT_HCI_SET_PUBLIC_ADDR=y (EM9305 vendor command, persistence "
                      "unknown)")
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


def opcode_values(hal: Path, zephyr: Path | None) -> dict[str, int]:
    """The forbidden opcodes' values, from the #defines in the driver sources."""
    sources = [hal / "components" / "bluetooth" / "am_devices_em9305.c"]
    if zephyr:
        sources.append(zephyr / "drivers" / "bluetooth" / "hci" / "apollox_blue.c")
    values = {}
    for src in sources:
        if not src.exists():
            continue
        for name, val in re.findall(r"#define\s+(HCI_VSC_\w+)\s+(0x[0-9A-Fa-f]+)U?", src.read_text()):
            if name in DENY_OPCODES:
                values[name] = int(val, 16)
    missing = [n for n in DENY_OPCODES if n not in values]
    if missing:
        raise SystemExit(f"check_rule8: cannot find the opcode values of {missing}")
    return values


def preprocess(entry: dict) -> str:
    """Runs one compile_commands entry with -E instead of -c (line markers kept)."""
    args = entry["arguments"] if "arguments" in entry else shlex.split(entry["command"])
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
            continue
        if a in ("-o", "-MF", "-MT", "-MQ"):
            skip = True
            continue
        if a in ("-c", "-MD", "-MMD") or a.startswith(("-o", "-MF", "-MT")) and len(a) > 3:
            continue
        out.append(a)
    out += ["-E", "-o", "-"]
    r = subprocess.run(out, cwd=entry.get("directory"), capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"check_rule8: preprocessing {entry['file']} failed:\n{r.stderr[-2000:]}")
    return r.stdout


def strip_line_markers(text: str) -> tuple[str, set[str]]:
    included, code = set(), []
    for line in text.splitlines():
        m = re.match(r'#\s*\d+\s+"([^"]+)"', line)
        if m:
            included.add(Path(m.group(1)).name)
        elif not line.startswith("#"):
            code.append(line)
    return "\n".join(code), included


def check_units(compile_commands: Path, opcodes: dict[str, int]) -> list[str]:
    errors = []
    entries = json.loads(compile_commands.read_text())
    units = []
    for e in entries:
        f = Path(e["file"])
        if EM9305_SOURCES.search(f.name):
            units.append((e, True))
            continue
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        if "am_devices_em9305" in text or "ble_fw_image" in text:
            units.append((e, False))
    if not any(driver for _, driver in units):
        errors.append("Bluetooth on but am_devices_em9305.c is not compiled (unexpected build)")
    op_re = {n: re.compile(r"\b0x0*%x[uUlL]*\b" % v, re.I) for n, v in opcodes.items()}
    for e, driver in units:
        f = Path(e["file"])
        if driver and PATCH_MARKER not in f.read_text(errors="replace"):
            errors.append(f"{f}: Wisp's EM9305 patch is not in the compiled driver")
        code, included = strip_line_markers(preprocess(e))
        if "ble_fw_image_em9305.h" in included:
            errors.append(f"{f}: includes ble_fw_image_em9305.h (the bundled EM9305 image)")
        for ident in DENY_IDENTS:
            if re.search(r"\b\w*%s\w*" % re.escape(ident), code):
                errors.append(f"{f}: compiled unit contains '{ident}' (EM9305 update path)")
        for name, rx in op_re.items():
            if rx.search(code):
                errors.append(f"{f}: compiled unit uses {name} (0x{opcodes[name]:04X})")
        calls = len(re.findall(r"\bam_devices_em9305_init\s*\(", code)) - len(
            re.findall(r"\bam_devices_em9305_init\s*\(\s*am_devices_em9305_callback_t\b", code))
        if not driver and calls > 0:
            values = [v.strip() for v in SKIP_ASSIGN.findall(code)]
            if not values or any(v not in ("true", "1") for v in values):
                errors.append(f"{f}: compiled caller of am_devices_em9305_init() does not "
                              f"force skip_fw_update = true (found {values or 'nothing'})")
    return errors


def check_code(objdump: str, elf: Path, opcodes: dict[str, int]) -> list[str]:
    """No instruction materialises an NVM write / erase opcode (movw #imm, cmp, literals)."""
    out = subprocess.run([objdump, "-d", str(elf)], check=True, capture_output=True,
                         text=True).stdout
    errors, fn = [], "?"
    imm = {v: n for n, v in opcodes.items()}
    for line in out.splitlines():
        m = re.match(r"^[0-9a-f]+ <([^>]+)>:", line)
        if m:
            fn = m.group(1)
            continue
        for v in re.findall(r"#(\d+)\b", line):
            if int(v) in imm:
                errors.append(f"instruction loads {imm[int(v)]} (0x{int(v):04X}) in {fn}: "
                              f"{line.strip()}")
        m = re.search(r"\.word\s+0x([0-9a-f]+)", line)
        if m and int(m.group(1), 16) in imm:
            errors.append(f"literal {imm[int(m.group(1), 16)]} in {fn}: {line.strip()}")
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


def check_map(map_path: Path, bt: bool = False) -> list[str]:
    text = map_path.read_text(errors="replace")
    marker = text.find("Linker script and memory map")
    linked = text[marker:] if marker >= 0 else text
    if not bt:
        hits = sorted({m.group(0) for m in EM9305_OBJECTS.finditer(linked)})
        return [f"EM9305 object in the linked image (map): {h}" for h in hits]
    deny = re.compile(r"^\s*\.(?:text|rodata|data|bss)\.(%s)(?:\.\w+)*\b" % "|".join(DENY_SYMBOLS),
                      re.M)
    return [f"section of a forbidden function / array in the linked image (map): .{m.group(1)}"
            for m in deny.finditer(linked)]


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
    ap.add_argument("--zephyr", type=Path, help="Zephyr base (for apollox_blue.c's opcodes)")
    ap.add_argument("--nm", default="arm-none-eabi-nm")
    ap.add_argument("--objdump", default="arm-none-eabi-objdump")
    args = ap.parse_args()

    cfg = parse_config(args.config)
    bt = cfg.get("CONFIG_BT") == "y" or cfg.get("CONFIG_AMBIQ_COMPONENT_USE_BT") == "y"
    names = elf_symbols(args.nm, args.elf)
    sigs = image_signatures(args.hal)

    errors = (check_config(cfg) + check_sources(args.compile_commands, bt)
              + check_symbols(names, bt) + check_map(args.map, bt)
              + check_bytes(args.bin.read_bytes(), sigs))
    extra = ""
    if bt:
        opcodes = opcode_values(args.hal, args.zephyr)
        errors += check_units(args.compile_commands, opcodes)
        errors += check_code(args.objdump, args.elf, opcodes)
        extra = (f", EM9305 units preprocessed clean, no NVM write/erase opcode in "
                 f"{len(opcodes)} checked")
    if errors:
        for e in errors:
            print(f"check_rule8: FAIL: {e}", file=sys.stderr)
        print(f"check_rule8: image rejected — {RULE}", file=sys.stderr)
        return 1
    print(f"check_rule8: OK bt={'on' if bt else 'off'}, {len(names)} symbols, "
          f"no forbidden symbols, map clean, {len(sigs)} EM9305 image signatures absent{extra}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
