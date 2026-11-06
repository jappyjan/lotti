# SPDX-License-Identifier: MIT
"""Assert on the UART1 capture of a Renode run (scripts/sim.sh): banner, Bluetooth brought up
safely, then a steady heartbeat, and no fatal error. Usage: check_uart.py <uart1.txt> <min_beats>

Renode has no EM9305 model, so the controller never reports "active". That is the case where
the unpatched Ambiq driver starts its NVM recovery reflash (safety rule 8). The patched one must
give up instead: Bluetooth stays down, nothing is written to the controller, and the firmware
keeps running without a link."""

import re
import sys
from pathlib import Path

# What the unpatched driver logs on its update / recovery paths (am_devices_em9305.c).
FORBIDDEN = ("forcing NVM reflash", "Entering configuration mode", "Erasing NVM main area",
             "Writing firmware image", "updating to bundled FW", "verifying bundled FW",
             "attempting NVM recovery", "HF crystal trim")


def check(text: str, min_beats: int) -> list[str]:
    errors = []
    for needle in ("*** Booting Zephyr OS build", "*** Wisp native ",
                   "wisp: board wisp_g2, Zephyr ", "image @ 0x438000",
                   "EM9305 update path compiled out (safety rule 8)",
                   "E: EM9305 active state timeout",
                   "wisp: bluetooth unavailable, running without a link"):
        if needle not in text:
            errors.append(f"missing {needle!r}")
    for bad in FORBIDDEN:
        if bad in text:
            errors.append(f"EM9305 update / recovery path ran: {bad!r}")
    if "FATAL" in text or "fault" in text.lower():
        errors.append("fatal error / fault on the UART")

    beats = [(int(n), int(t)) for n, t in
             re.findall(r"^wisp: heartbeat (\d+) uptime (\d+) ms$", text, re.M)]
    if len(beats) < min_beats:
        errors.append(f"{len(beats)} heartbeats, want >= {min_beats}")
    for i, (n, t) in enumerate(beats):
        if n != i + 1:
            errors.append(f"heartbeat #{i + 1} numbered {n}")
            break
        # k_msleep(1000) then print: about 1000 ms apart in virtual time (the first comes after
        # bt_enable() gave up on the controller)
        if i and not (1000 <= t - beats[i - 1][1] <= 1050):
            errors.append(f"heartbeat {n} {t - beats[i - 1][1]} ms after the previous one")
            break
    return errors


def main() -> int:
    text = Path(sys.argv[1]).read_text(errors="replace")
    errors = check(text, int(sys.argv[2]))
    for e in errors:
        print(f"sim test: FAIL: {e}", file=sys.stderr)
    if errors:
        print("--- uart1.txt ---\n" + text, file=sys.stderr)
        return 1
    print(f"sim test: OK ({text.count('heartbeat')} heartbeats)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
