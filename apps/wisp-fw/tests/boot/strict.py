# SPDX-License-Identifier: MIT
"""Strict start-up checks for the Renode harnesses (rung3.py, w18.py), after W24 (docs/wisp/rung4.md,
"W24 result and analysis", "Renode changes that would have caught it").

native-0 passed every Renode case and reboot-looped on silicon. Renode runs a register without a
model as plain storage ("reads 0, writes ignored"), so the Ambiq start-up's trims, SIMO buck and
clock settings "succeeded" by construction. Two records from the models close that gap:

  - the strict record (renode/models/WispTrace.cs, WispStrict; `probe StrictFrom "wisp_boot_main"`,
    `probe StrictDump`): every access Wisp code makes to a register no model acts on, with its PC,
    from Wisp Boot's entry to the next reset. A write in a power, clock or trim block (rstgen,
    clkgen, otp, mcuctrl, pwrctrl) fails a native case unless strict_allowlist.json lists it with
    a reason;
  - the PMIC write log with PCs (WispPmicWdt `PmicPcLog`): which code wrote what to the nPM1300. Wisp
    Boot's only write may be the kick 07 04 01.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
ALLOWLIST = HERE / "strict_allowlist.json"
POWER_CLOCK_TRIM = ("rstgen", "clkgen", "otp", "mcuctrl", "pwrctrl")
WISP_BOOT = (0x438000, 0x448000)
KICK = "07 04 01"
LINE = re.compile(r"(\S+) ([RW]) 0x([0-9A-F]+) 0x([0-9A-F]+) pc 0x([0-9A-F]+) x(\d+)")
PMIC_LINE = re.compile(r"(\d+) pc 0x([0-9A-F]+) wb=([01]) write (.*)")


def owner(pc: int) -> str:
    if WISP_BOOT[0] <= pc < WISP_BOOT[1]:
        return "wisp-boot"
    if 0x448000 <= pc < 0x7F8000:
        return "app"
    if pc < 0x40000:
        return "itcm"
    return f"{pc:#x}"


def parse(dump: str) -> list[dict]:
    out = []
    for line in dump.splitlines():
        m = LINE.match(line.strip())
        if m:
            out.append({"block": m[1], "rw": m[2], "address": int(m[3], 16), "value": int(m[4], 16),
                        "pc": int(m[5], 16), "count": int(m[6]), "owner": owner(int(m[5], 16))})
    return out


def allowlist() -> list[dict]:
    return json.loads(ALLOWLIST.read_text())["entries"]


def allowed(entry: dict, rules: list[dict]) -> bool:
    for r in rules:
        if r["block"] != entry["block"] or int(r["address"], 16) != entry["address"]:
            continue
        if r.get("value", "*") == "*" or int(r["value"], 16) == entry["value"]:
            return True
    return False


def unallowed_writes(entries: list[dict], owners=None, rules=None) -> list[dict]:
    """Writes to a power, clock or trim block that no model acts on and no allowlist entry covers."""
    rules = allowlist() if rules is None else rules
    return [e for e in entries if e["rw"] == "W" and e["block"] in POWER_CLOCK_TRIM
            and (owners is None or e["owner"] in owners) and not allowed(e, rules)]


def describe(entries: list[dict], limit: int = 12) -> str:
    seen = []
    for e in entries:
        s = f"{e['block']} {e['address']:#010x}<-{e['value']:#x} by {e['owner']} pc {e['pc']:#x}"
        if s not in seen:
            seen.append(s)
    more = f" (+{len(seen) - limit} more)" if len(seen) > limit else ""
    return "; ".join(seen[:limit]) + more


def pmic_writes(log: str) -> list[dict]:
    out = []
    for line in log.splitlines():
        m = PMIC_LINE.match(line.strip())
        if m:
            pc = int(m[2], 16)
            out.append({"ms": int(m[1]), "pc": pc, "wisp_boot": m[3] == "1" and WISP_BOOT[0] <= pc < WISP_BOOT[1],
                        "bytes": m[4].strip()})
    return out


def wisp_boot_pmic(log: str) -> tuple[int, list[str]]:
    """(Wisp Boot's kicks, Wisp Boot's PMIC writes that are not the kick)."""
    w = [e for e in pmic_writes(log) if e["wisp_boot"]]
    return sum(e["bytes"] == KICK for e in w), sorted({e["bytes"] for e in w if e["bytes"] != KICK})
