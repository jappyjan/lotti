#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Checks nPM1300 writes against W21's register snapshot (images/pmic-baseline-w21.json;
rung4.md G12): a native image may write a configuration register only with the value stock left
in it, and otherwise only the listed tasks (value 1). Used by the Renode harnesses on every PMIC
write the app makes (tests/boot/rung3.py, tests/boot/w18.py) and, as a report, by the driver test.

A write is its wire bytes: register address high, low, then data bytes for consecutive registers
(the nPM1300 auto-increments). Two bytes alone are the address phase of a read and are skipped.

  pmic_baseline.py --log <iom.log or pmic.log>     prints every difference (exit 1 if any)
"""
import json
import re
import sys
from pathlib import Path

BASELINE = Path(__file__).resolve().parents[1] / "images" / "pmic-baseline-w21.json"


def load(path: Path = BASELINE) -> tuple[dict[int, tuple[str, int]], dict[int, str]]:
    doc = json.loads(path.read_text())
    regs = {int(a, 16): (r["name"], int(r["value"], 16)) for a, r in doc["registers"].items()}
    tasks = {int(a, 16): name for a, name in doc["tasks"].items()}
    return regs, tasks


def check(writes: list[bytes], baseline=None) -> list[str]:
    """Every difference from the snapshot, one line each (empty: all writes match)."""
    regs, tasks = baseline or load()
    out = []
    for w in writes:
        if len(w) <= 2:
            continue
        base = w[0] << 8 | w[1]
        for i, value in enumerate(w[2:]):
            addr = base + i
            if addr in regs:
                name, want = regs[addr]
                if value != want:
                    out.append(f"{name} (0x{addr:04x}) written 0x{value:02x}, stock 0x{want:02x}")
            elif addr in tasks:
                if value != 1:
                    out.append(f"{tasks[addr]} (0x{addr:04x}) written 0x{value:02x}, a task takes 1")
            else:
                out.append(f"0x{addr:04x} written 0x{value:02x}: not a register of the snapshot nor an allowed task")
    return out


def parse_log(text: str) -> list[bytes]:
    """PMIC writes from WispPmicWdt's PmicLog ('<ms> ms write 07 04 01') or WispIom's log
    ('7 6B W 070401')."""
    writes = []
    for line in text.splitlines():
        m = re.search(r" ms write ([0-9a-f ]+)$", line.strip())
        if m:
            writes.append(bytes.fromhex(m.group(1).replace(" ", "")))
            continue
        m = re.match(r"^7 6B W ([0-9A-Fa-f]+)$", line.strip())
        if m:
            writes.append(bytes.fromhex(m.group(1)))
    return writes


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] != "--log":
        print(__doc__, file=sys.stderr)
        return 2
    diffs = check(parse_log(Path(sys.argv[2]).read_text()))
    for d in diffs:
        print(d)
    print(f"pmic_baseline: {len(diffs)} difference(s) from W21's snapshot")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
