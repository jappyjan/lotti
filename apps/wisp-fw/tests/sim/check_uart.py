# SPDX-License-Identifier: MIT
"""Assert on the UART1 capture of a Renode run (scripts/sim.sh): banner, then a steady
heartbeat, and no fatal error. Usage: check_uart.py <uart1.txt> <min_heartbeats>"""

import re
import sys
from pathlib import Path


def check(text: str, min_beats: int) -> list[str]:
    errors = []
    for needle in ("*** Booting Zephyr OS build", "*** Wisp native ",
                   "wisp: board wisp_g2, Zephyr ", "image @ 0x438000",
                   "bluetooth off (safety rule 8)", "wisp: hal power ok", "wisp: hal display ok",
                   "wisp: hal input ok", "wisp: hal sensors ok"):
        if needle not in text:
            errors.append(f"missing {needle!r}")
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
        # k_msleep(1000) then print: about 1000 ms apart in virtual time, the first one after
        # the bring-up (well under a second: touch reset 110 ms, I2C probes)
        lo, hi = (1000, 1500) if i == 0 else (beats[i - 1][1] + 1000, beats[i - 1][1] + 1050)
        if not lo <= t <= hi:
            errors.append(f"heartbeat {n} at {t} ms, want {lo}..{hi}")
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
