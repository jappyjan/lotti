# SPDX-License-Identifier: MIT
"""Check one Renode driver-test run (scripts/drivers_test.sh).

Inputs in --run: uart1.txt (the self-test's printout), panel.log (every MSPI0 transaction as the
panel saw it: seq, DEVCFG0/XIPMIXED, op, address, dir, length, first 64 bytes), frame.bin (the
panel's frame memory at the end), iom.log (every I2C transaction: iom, address, W/R, bytes).

The expected panel traffic is written out here from the stock 2.4.0.24 facts in
docs/wisp/hardware.md, and the brightness values and the frame are computed here a second time,
independently of the C driver.
"""

import argparse
import re
import sys
from pathlib import Path

SERIAL, QUAD = "1/0", "1/5"  # DEVCFG0 / XIPMIXED: serial; 1-1-4 (data on four lines)
FRAME = 320 * 480 + 2


def frame_after_selftest() -> bytes:
    """Layer 0: 16 bands of 40 px, values 0..15; layer 1: box (100, 200) 64x32, last value 7."""
    px = [[(x // 40) & 15 for x in range(640)] for _ in range(480)]
    for y in range(200, 232):
        for x in range(100, 164):
            px[y][x] = 7
    out = bytearray()
    for row in px:
        for x in range(0, 640, 2):
            out.append(row[x] << 4 | row[x + 1])  # high nibble = left pixel
    return bytes(out)


# ---- stock brightness, reimplemented ------------------------------------------------------------

def jbd_level(level: int, m: int = 7100) -> tuple[int, int]:
    level = max(2, min(100, level))
    if level < 31:
        return 0, ((m - 333) * (level - 2) + 14) // 28 + 333
    return (36 * level - 1045) // 70, m


def lerp(t, x, step):
    i = x // step
    if i >= len(t) - 1:
        return t[-1]
    return t[i] + (t[i + 1] - t[i]) * (x - i * step) // step


def a6_level(level: int, coarse0: int) -> tuple[int, int]:
    m = lerp([-5, 1, 10, 13, 28, 41, 53, 69, 80, 94, 100], max(1, min(100, level)), 10)
    coarse = coarse0
    if level >= 40:
        fine = lerp([36, 50, 67, 91, 116, 152, 255], level - 40, 10)
    elif m < 26:
        fine, coarse = m + 5, max(0, coarse0 - (25 - m) // 3)
    elif m >= 100:
        fine = 255
    else:
        fine = (225 * m - 5588) // 75 + 30
    return coarse, max(0, min(255, fine))


# ---- expected panel traffic ---------------------------------------------------------------------

def cmd(op, data="", mode=SERIAL):
    return (mode, f"{op:02X}", "-", "tx", len(data) // 2, data)


def rd(op, n):
    return (SERIAL, f"{op:02X}", "-", "rx", n, None)


def jbd_bright(level, opened):
    cur, lum = jbd_level(level)
    lumb = f"{(lum >> 8) & 0xFF:02X}{(lum >> 16) & 0xFF:02X}"
    seq = [cmd(0x06), cmd(0xA9)] if opened else []
    return seq + [cmd(0x36, lumb), cmd(0x46, f"{cur & 0x3F:02X}"), cmd(0x31, "04"), cmd(0xA3),
                  cmd(0x97)]


def jbd_frame():
    return [(QUAD, "62", "00000000", "tx", FRAME, None), cmd(0x97)]


def jbd_expected():
    init = [cmd(0x66), cmd(0x99), cmd(0x06), cmd(0x01, "10")] + jbd_frame()
    for x, y in ((0, 0), (0, 20), (24, 0), (24, 20), (12, 10)):
        init += [cmd(0xC0, f"{x:02X}{y:02X}"), cmd(0x97)]
    init += [cmd(0x73), cmd(0x97)] * 2
    init += jbd_bright(50, False)
    init += [cmd(0xA9), cmd(0xC0, "0C0A"), cmd(0xA3), cmd(0x97), rd(0x9F, 4)]
    seq = init
    seq += jbd_frame()  # power-on: the HAL resends the (blank) frame
    seq += jbd_frame()  # frame 1: every row dirty -> one DMA
    rows = [(QUAD, "62", f"{(y << 18) | 0xFF:08X}", "tx", 322, None) for y in range(200, 232)]
    seq += rows + [cmd(0x97)]  # frame 2: rows 200..231, one PIO write each
    seq += jbd_bright(100, True)  # brightness 255 -> stock level 100
    seq += [rd(0x05, 1), rd(0x35, 1)]  # health
    return seq


def a6_wr(bank, reg, val):
    return (SERIAL, "-", "-", "tx", 3, f"{0x7A if bank else 0x78:02X}{reg:02X}{val:02X}")


def a6_rd(bank, reg):
    return (SERIAL, "-", f"0000{0x7B if bank else 0x79:02X}{reg:02X}", "rx", 1, None)


def a6_frame():
    return [(QUAD, "-", "32002C00", "tx", FRAME, None)]


def a6_expected(coarse0=0x08, ef=0x00, f0=0x28):
    seq = [a6_wr(1, 0x55, 0)]
    for b, r, v in ((0, 0xBE, 0x84), (1, 0x7E, 0x02), (1, 0xA5, 0x40), (0, 0xF1, 0x3F),
                    (0, 0xE2, 0xFF), (0, 0xF7, 0xFC), (0, 0x78, 0x0A), (0, 0x7C, 0x12),
                    (0, 0xB7, 0x80), (0, 0xB0, 0x80)):
        seq.append(a6_wr(b, r, v))
    seq += [a6_wr(0, 0xF0, 0x28), a6_rd(0, 0x00), a6_rd(0, 0x06)] + a6_frame()
    coarse, fine = a6_level(50, coarse0)
    seq += [a6_rd(0, 0xE7), a6_wr(0, 0xE7, coarse), a6_wr(0, 0xE2, fine)]
    for reg, cur, v in ((0xEF, ef, 8), (0xF0, f0, 8)):
        seq += [a6_rd(0, reg), a6_wr(0, reg, v + (cur & 0xE0)), a6_wr(0, 0xD9, 0xBF),
                a6_wr(0, 0xD9, 0xFF)]
    seq += a6_frame() * 3  # power-on resend, frame 1, frame 2 (no partial update on the A6N-G)
    coarse, fine = a6_level(100, coarse0)
    seq += [a6_wr(0, 0xE7, coarse), a6_wr(0, 0xE2, fine)]  # coarse is cached: no second read
    seq += [a6_rd(0, 0xBE), a6_rd(0, 0x62)]  # health
    return seq


def parse_panel(text):
    out = []
    for line in text.splitlines():
        f = line.split(" ")
        out.append((f[1], f[2], f[3], f[4], int(f[5]), f[6] if len(f) > 6 else ""))
    return out


def check_panel(variant, run, errors):
    got = parse_panel((run / "panel.log").read_text())
    want = jbd_expected() if variant == "jbd4010" else a6_expected()
    for i, w in enumerate(want):
        if i >= len(got):
            errors.append(f"panel: transaction {i} missing, want {w[:5]}")
            return
        g = got[i]
        if g[:5] != w[:5] or (w[5] is not None and g[5] != w[5]):
            errors.append(f"panel: transaction {i}: got {g[:5]} {g[5][:16]}, want {w[:5]} {w[5]}")
            return
    if len(got) != len(want):
        errors.append(f"panel: {len(got)} transactions, want {len(want)} (extra: {got[len(want)]})")
    frame = (run / "frame.bin").read_bytes()
    exp = frame_after_selftest()
    if frame != exp:
        diff = next(i for i in range(len(exp)) if frame[i] != exp[i])
        errors.append(f"frame: first difference at byte {diff} (row {diff // 320}, "
                      f"x {2 * (diff % 320)}): got {frame[diff]:02X}, want {exp[diff]:02X}")


# ---- I2C ----------------------------------------------------------------------------------------

def check_i2c(variant, run, errors):
    log = [ln.split(" ") for ln in (run / "iom.log").read_text().splitlines()]
    per = {}
    for f in log:
        per.setdefault((int(f[0]), f[1]), []).append((f[2], f[3] if len(f) > 3 else ""))

    def writes(bus, addr):
        return [d for k, d in per.get((bus, addr), []) if k == "W"]

    # Touch (IOM5 0x0C): only allowed command bytes; never 2 (DFU) or 7 (EEPROM write).
    tw = writes(5, "0C")
    cmds = [int(d[:2], 16) for d in tw if d]
    bad = [c for c in cmds if c not in (1, 3, 4, 5, 6, 8)]
    if bad:
        errors.append(f"touch: forbidden command bytes sent to the PSoC: {bad}")
    if cmds[:2] != [1, 8] or 3 not in cmds:
        errors.append(f"touch: commands {cmds}, want version (1), long press (8), then reports (3)")

    # IMU (IOM4 0x69): ID, soft reset, INT1 push-pull pulsed active-high, ±4 g / ±2000 dps codes,
    # 100 Hz accel in LP, and off (PWR_MGMT0 = 0) at the end.
    iw = writes(4, "69")
    for need, what in (("72", "WHO_AM_I read"), ("7F02", "soft reset"), ("1801", "INT1 config"),
                       ("1B39", "accel ±4 g, 100 Hz"), ("1002", "accel low-power on")):
        if need not in iw:
            errors.append(f"imu: no {what} ({need})")
    if not iw or iw[-1] != "1000":
        errors.append(f"imu: last write {iw[-1] if iw else None}, want PWR_MGMT0 = 0 (suspend)")

    # ALS (IOM2 0x45): IDs, shutdown at init, one single-shot conversion, nothing continuous.
    aw = writes(2, "45")
    cfgs = [d[2:] for d in aw if d.startswith("01") and len(d) == 6]
    if not cfgs or cfgs[0] != "C000":
        errors.append(f"als: first config {cfgs[:1]}, want C000 (shutdown)")
    if "C200" not in cfgs:
        errors.append(f"als: no single-shot conversion (C200) in {cfgs}")
    if any(int(c, 16) >> 9 & 3 >= 2 for c in cfgs):
        errors.append(f"als: continuous mode written ({cfgs})")

    # PMIC (IOM7 0x6B): every header is {base, offset} with a known base, i.e. the 16-bit
    # address went out high byte first (the byte-order fix in third_party/zephyr/i2c_ambiq.c).
    pw = writes(7, "6B")
    bases = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0A, 0x0B, 0x0E, 0x12}
    wrong = [d for d in pw if len(d) >= 4 and int(d[:2], 16) not in bases]
    if wrong:
        errors.append(f"pmic: register addresses with an unknown base (byte order?): {wrong[:5]}")
    for need, what in (("040A15", "BUCK2 3.1 V"), ("080C08", "LDSW1 1.8 V"), ("080801", "LDSW1 as LDO"),
                       ("070401", "watchdog kick"),
                       ("040001", "BUCK1 on (panel)"), ("040101", "BUCK1 off (panel)")):
        if need not in pw:
            errors.append(f"pmic: no {what} ({need})")
    # The watchdog stays armed with stock's own writes, in stock's order (rung4.md G27,
    # recovery.md "The temple's watchdog"), and is never stopped.
    arm = ["07050A", "0708003C00", "070301", "070001"]
    if [w for w in pw if w in arm][:4] != arm:
        errors.append(f"pmic: watchdog not armed with stock's sequence {arm}")
    if "070101" in pw:
        errors.append("pmic: Wisp stopped the PMIC watchdog")
    buck1 = "040801" if variant == "jbd4010" else "040808"
    if buck1 not in pw:
        errors.append(f"pmic: BUCK1 voltage {buck1} not programmed ({'1.1' if variant == 'jbd4010' else '1.8'} V)")
    if variant == "jbd4010":
        on, off = pw.index("080201") if "080201" in pw else -1, pw.index("040001")
        if on < 0 or on > off:
            errors.append("pmic: LDSW2 must come on before BUCK1 (JBD power-up)")
        if "080301" not in pw or pw.index("080301") < pw.index("040101"):
            errors.append("pmic: LDSW2 must go off after BUCK1 (JBD power-down)")
    elif "080201" in pw:
        errors.append("pmic: LDSW2 switched on for the A6N-G")


# ---- UART ---------------------------------------------------------------------------------------

def check_uart(run, errors):
    text = (run / "uart1.txt").read_text(errors="replace")
    for needle in ("wisp: hal power ok", "wisp: hal display ok", "wisp: hal input ok",
                   "wisp: hal sensors ok", "selftest: display power on (0)",
                   "selftest: frame 1 composed (0), flush frames 2 writes 2 rows 960",
                   "selftest: frame 2 composed (0), flush frames 3 writes 3 rows 992",
                   "selftest: brightness (0)", "selftest: panel health (0)",
                   "selftest: display power off (0)",
                   "selftest: imu accel 0.000000 0.000000 9.806650 m/s2 (0)",
                   "selftest: light 88.80 lux (0)", "selftest: touch report (0) wear 2",
                   "selftest: done", "wisp: heartbeat 1 "):
        if needle not in text:
            errors.append(f"uart: missing {needle!r}")
    for bad in ("<err>", "FATAL", "FAULT"):
        if bad in text:
            line = next(ln for ln in text.splitlines() if bad in ln)
            errors.append(f"uart: {line.strip()}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", required=True, choices=["a6ng", "jbd4010"])
    ap.add_argument("--run", required=True, type=Path)
    a = ap.parse_args()
    errors: list[str] = []
    check_uart(a.run, errors)
    check_panel(a.variant, a.run, errors)
    check_i2c(a.variant, a.run, errors)
    for e in errors:
        print(f"drivers test {a.variant}: FAIL: {e}", file=sys.stderr)
    if errors:
        print(f"(run dir: {a.run})", file=sys.stderr)
        return 1
    n = len((a.run / "panel.log").read_text().splitlines())
    m = len((a.run / "iom.log").read_text().splitlines())
    print(f"drivers test {a.variant}: OK ({n} panel transactions, {m} I2C transactions, frame matches)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
