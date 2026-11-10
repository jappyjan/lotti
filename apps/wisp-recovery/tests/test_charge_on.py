# SPDX-License-Identifier: MIT
"""charge_on.bin (recovery.md, "charge_on"): the stock charger settings and charging on, through the
patched bootloader's IOM7, and `w18.py charge-on`. No hardware.

The real binary runs under Unicorn (temple_cpu.py) with IOM7 and the PMIC as a model: one watchdog
kick, then exactly pins.CHARGE_ON_WRITES as 3-byte writes in that order; no read, nothing else on
the bus, nothing sent, IOM7 powered up and down once. The values are W21's stock snapshot. Then the
tool against the fake temple, which reads everything back with pmic_read.
"""

import json
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_session_guard import Case, run_cli
from test_w18 import temple
from wisp_w18 import image, pins, session

try:
    import temple_cpu
except ImportError:  # unicorn missing
    temple_cpu = None

HANDLE = pins.IOM7_HAL_HANDLE
ROOT = Path(__file__).resolve().parents[3]
WRITES = [bytes((address >> 8, address & 0xFF, value)) for address, value, _name in pins.CHARGE_ON_WRITES]
TASKS = {0x0200, 0x0300}  # VBUS limit update, release the charger from an error state


def cpu():
    made = temple_cpu.TempleCpu()
    made.allow_reads = True
    return made


class Values(unittest.TestCase):
    def test_every_configuration_write_is_the_stock_value(self):
        baseline = json.loads((ROOT / "apps/wisp-fw/images/pmic-baseline-w21.json").read_text())["registers"]
        for address, value, name in pins.CHARGE_ON_WRITES:
            if address in TASKS:
                continue
            entry = baseline[f"{address:#06x}".upper().replace("0X", "0x")]
            self.assertEqual(int(entry["value"], 16), value, name)

    def test_only_charger_vbus_and_ntc_registers_and_charging_on_last(self):
        for address, _value, name in pins.CHARGE_ON_WRITES:
            self.assertIn(address >> 8, (0x02, 0x03, 0x05), name)  # VBUSIN, BCHARGER, ADC
            if address >> 8 == 0x05:
                self.assertEqual(address, 0x050A)  # NTCR_SEL only, no ADC task
        self.assertEqual(pins.CHARGE_ON_WRITES[-1][:2], (0x0304, 0x01))
        written = [a for a, _v, _n in pins.CHARGE_ON_WRITES]
        # the thresholds, currents and termination are set before charging is switched on
        self.assertLess(max(written.index(a) for a in (0x050A, 0x0317, 0x030C, 0x0308)), written.index(0x0304))
        self.assertEqual(len(set(written)), len(written))


@unittest.skipIf(temple_cpu is None, "unicorn not installed")
class Binary(unittest.TestCase):
    def test_it_fits_the_loader_and_matches_its_pin(self):
        code = image.program("charge_on")
        self.assertTrue(2 <= len(code) <= 512 and len(code) % 2 == 0)

    def test_one_kick_then_exactly_the_writes_in_order(self):
        c = temple_cpu.TempleCpu()  # reads not allowed: it must not read
        self.assertEqual(c.run("charge_on"), 0)
        self.assertEqual(c.violations, [])
        self.assertEqual(c.transactions, [("w", 0x6B, pins.PMIC_KICK_WIRE)] + [("w", 0x6B, w) for w in WRITES])
        self.assertEqual((c.reads, c.sent), ([], []))
        for address, value, name in pins.CHARGE_ON_WRITES:
            self.assertEqual(c.pmic_registers[address], value, name)
        self.assertEqual([p[:3] for p in c.power_calls], [(HANDLE, 0, 1), (HANDLE, 2, 1)])
        self.assertFalse(c.iom_powered)
        iom_writes = {a - temple_cpu.IOM7 for k, a, _ in c.footprint if k == "w"}
        self.assertEqual(iom_writes, {0x200, 0x208, 0x2C4, 0x128, 0x10C, 0x120})
        offsethi = {v for k, a, v in c.footprint if k == "w" and a - temple_cpu.IOM7 == 0x128}
        self.assertEqual(offsethi, {0})
        others = {a for k, a, _ in c.footprint if k == "r" and not temple_cpu.IOM7 <= a < temple_cpu.IOM7 + 0x1000}
        self.assertEqual(others, {pins.I2C_TABLE_ENTRY_7, pins.I2C_TABLE_ENTRY_7 + 4})

    def test_failures_stop_the_writes(self):
        c = temple_cpu.TempleCpu()
        c.nak = True  # the kick NAKs: no write follows
        self.assertEqual(c.run("charge_on"), 0x50010)
        self.assertEqual(len(c.wire), 1)
        self.assertFalse(c.iom_powered)

        c = temple_cpu.TempleCpu()
        c.power_result[0] = 7  # WAKE with retain refused: nothing on the bus
        self.assertEqual(c.run("charge_on"), 0x107)
        self.assertEqual(c.wire, [])

        c = temple_cpu.TempleCpu()
        c.power_result[2] = 3  # power-down refused after every write
        self.assertEqual(c.run("charge_on"), 0x603)
        self.assertEqual(len(c.wire), 1 + len(WRITES))

        c = temple_cpu.TempleCpu()
        c.complete = False
        self.assertEqual(c.run("charge_on"), 0x400)
        self.assertEqual(len(c.wire), 1)

        c = temple_cpu.TempleCpu()
        c.status_idle = False
        self.assertEqual(c.run("charge_on"), 0x200)
        self.assertEqual(c.wire, [])

        c = temple_cpu.TempleCpu()
        c.fifo_room = 0
        self.assertEqual(c.run("charge_on"), 0x300)
        self.assertEqual(c.wire, [])

        c = temple_cpu.TempleCpu()
        c.uc.mem_write(pins.I2C_TABLE_ENTRY_7, bytes(8))
        self.assertEqual(c.run("charge_on"), 0x10)
        self.assertEqual((c.power_calls, c.wire), ([], []))

    def test_a_failed_write_names_the_register(self):
        self.assertIn("BCHARGER.ENABLE (0x0304) = 0x01",
                      session.describe_charge_on((len(WRITES) << 24) | 0x50010))
        self.assertIn("watchdog kick", session.describe_charge_on(0x400))
        self.assertIn("after the writes", session.describe_charge_on(0x603))
        self.assertTrue(session.describe_charge_on((3 << 24) | 0x200).endswith("failed: IOM7 not idle"))


class Tool(unittest.TestCase):
    def test_charge_on_writes_then_reads_everything_back(self):
        case = Case(temple())
        code, report = run_cli(["charge-on", "--side", "left"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["pmic"]["0x0304"]["value"], "0x01")
        self.assertEqual(report["pmic"]["0x030c"]["value"], "0x0d")
        self.assertEqual(len(report["pmic"]), len(pins.PMIC_READ_REGISTERS))
        self.assertEqual(case.mram.writes, [])

    def test_a_register_that_reads_back_different_stops_with_exit_3(self):
        from fake_temple import FakeLoaderLink
        original = FakeLoaderLink._prog_charge_on

        def enable_ignored(self, a0, a1):
            result = yield from original(self, a0, a1)
            self.pmic_registers[0x0304] = 0x00  # the charger did not take EN_SET
            return result

        with mock.patch.object(FakeLoaderLink, "_prog_charge_on", enable_ignored):
            code, report = run_cli(["charge-on", "--side", "left"], Case(temple()))
        self.assertEqual(code, 3)
        self.assertEqual(report["pmic"]["0x0304"]["value"], "0x00")

    def test_charge_on_needs_the_bootloader_checked_first(self):
        from fake_temple import FakeLoaderLink
        link = FakeLoaderLink(temple())
        with self.assertRaises(session.RefusedError), session.Session(link, log=lambda m: None) as s:
            s.charge_on()


if __name__ == "__main__":
    unittest.main()
