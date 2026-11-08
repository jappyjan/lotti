# SPDX-License-Identifier: MIT
"""pmic_read.bin (rung4.md §4, G3): a read-only nPM1300 snapshot through the patched bootloader's
IOM7, and `w18.py pmic-read`. No hardware.

The real binary runs under Unicorn (temple_cpu.py) with IOM7 and the PMIC as a model, every access
outside the program recorded: one watchdog kick (the feed's three bytes), then exactly one
write-read per register of pins.PMIC_READ_REGISTERS, in that order, each a 2-byte register address
and one byte back; no other PMIC transaction, no other register, IOM7 powered up and down once
through the bootloader's power_ctrl. Its failure codes. Then the tool against the fake temple:
the report, the comparison with an earlier snapshot, and the refusals.
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

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
ADDRESSES = [address for address, _name, _kind in pins.PMIC_READ_REGISTERS]


def reader():
    """The temple model with reads allowed (only pmic_read reads)."""
    cpu = temple_cpu.TempleCpu()
    cpu.allow_reads = True
    return cpu


@unittest.skipIf(temple_cpu is None, "unicorn not installed")
class Binary(unittest.TestCase):
    def test_the_kicking_programs_still_may_not_read(self):
        cpu = temple_cpu.TempleCpu()  # reads not allowed
        cpu.run("pmic_read")
        self.assertIn("a read command", cpu.violations)

    def test_it_fits_the_loader_and_matches_its_pin(self):
        code = image.program("pmic_read")
        self.assertTrue(2 <= len(code) <= 512 and len(code) % 2 == 0)

    def test_one_kick_then_one_write_read_per_allowlisted_register(self):
        cpu = reader()
        cpu.pmic_registers = {address: (i * 37 + 5) & 0xFF for i, address in enumerate(ADDRESSES)}
        self.assertEqual(cpu.run("pmic_read"), 0)
        self.assertEqual(cpu.violations, [])
        self.assertEqual(cpu.transactions[0], ("w", 0x6B, pins.PMIC_KICK_WIRE))
        self.assertEqual(cpu.transactions[1:], [("r", 0x6B, address) for address in ADDRESSES])
        self.assertEqual(cpu.reads, [(0x6B, address, 1) for address in ADDRESSES])  # one byte each
        self.assertEqual(len(set(ADDRESSES)), len(ADDRESSES))
        self.assertEqual(b"".join(cpu.sent), bytes(cpu.pmic_registers[a] for a in ADDRESSES))
        self.assertEqual([len(c) for c in cpu.sent], [16, 16, 16, 10])
        self.assertEqual([c[:3] for c in cpu.power_calls], [(HANDLE, 0, 1), (HANDLE, 2, 1)])
        self.assertFalse(cpu.iom_powered)
        writes = {a - temple_cpu.IOM7 for k, a, _ in cpu.footprint if k == "w"}
        # INTEN, INTCLR, DEVCFG, OFFSETHI, FIFOPUSH, CMD
        self.assertEqual(writes, {0x200, 0x208, 0x2C4, 0x128, 0x10C, 0x120})
        pushes = [v for k, a, v in cpu.footprint if k == "w" and a - temple_cpu.IOM7 == 0x10C]
        self.assertEqual(pushes, [0x00010407])  # the kick's bytes; the reads push nothing
        others = {a for k, a, _ in cpu.footprint if k == "r" and not temple_cpu.IOM7 <= a < temple_cpu.IOM7 + 0x1000}
        self.assertEqual(others, {pins.I2C_TABLE_ENTRY_7, pins.I2C_TABLE_ENTRY_7 + 4})

    def test_the_allowlist_holds_no_task_or_ship_entry_register(self):
        # Writes to these would act (tasks, ship/hibernate entry, the watchdog kick and timer
        # control); the reads never name them.
        forbidden = {0x0B00, 0x0B01, 0x0B02, 0x0700, 0x0701, 0x0703, 0x0704, 0x0400, 0x0401, 0x0402, 0x0403,
                     0x0800, 0x0801, 0x0802, 0x0803, 0x0001}
        self.assertFalse(forbidden & set(ADDRESSES))

    def test_failures_return_a_code_and_send_nothing(self):
        cpu = reader()
        cpu.nak = True  # the kick NAKs: nothing read
        self.assertEqual(cpu.run("pmic_read"), 0x50010)
        self.assertEqual((cpu.reads, cpu.sent), ([], []))
        self.assertEqual([c[1] for c in cpu.power_calls], [0, 2])

        cpu = reader()
        cpu.nak_reads = True  # the first read NAKs
        result = cpu.run("pmic_read")
        self.assertEqual(result, (1 << 24) | 0x50010)
        self.assertIn("(NAK)", session.describe_pmic_read(result))
        self.assertIn("VBUSIN.ILIM", session.describe_pmic_read(result))
        self.assertEqual((len(cpu.reads), cpu.sent), (1, []))
        self.assertFalse(cpu.iom_powered)

        cpu = reader()
        cpu.rx_bytes = 0  # the read completes but no byte arrives
        self.assertEqual(cpu.run("pmic_read"), (1 << 24) | 0x800)
        self.assertEqual(cpu.sent, [])

        cpu = reader()
        cpu.power_result[0] = 7  # WAKE with retain refused
        self.assertEqual(cpu.run("pmic_read"), 0x107)
        self.assertEqual((cpu.wire, cpu.reads), ([], []))

        cpu = reader()
        cpu.power_result[2] = 3  # the power-down refused after every transfer succeeded
        self.assertEqual(cpu.run("pmic_read"), 0x603)
        self.assertEqual(cpu.sent, [])

        cpu = reader()
        cpu.status_idle = False  # busy from the start
        self.assertEqual(cpu.run("pmic_read"), 0x200)
        self.assertEqual((cpu.wire, cpu.reads), ([], []))

        cpu = reader()
        cpu.complete = False  # no transfer ever completes
        self.assertEqual(cpu.run("pmic_read"), 0x400)

        cpu = reader()
        cpu.uc.mem_write(pins.I2C_TABLE_ENTRY_7, bytes(8))  # not the pinned bootloader's table
        self.assertEqual(cpu.run("pmic_read"), 0x10)
        self.assertEqual((cpu.power_calls, cpu.wire, cpu.reads), ([], [], []))


def snapshot(registers=None):
    mram = temple()
    case = Case(mram)
    real = case.link

    def link(args=None):
        made = real(args)
        made.port.temple.pmic_registers = registers or {}
        return made

    case.link = link
    return case


class Tool(unittest.TestCase):
    def test_pmic_read_reports_every_register(self):
        values = {address: i for i, address in enumerate(ADDRESSES)}
        case = snapshot(values)
        code, report = run_cli(["pmic-read", "--side", "left"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(len(report["pmic"]), len(ADDRESSES))
        self.assertEqual(report["pmic"]["0x0408"], {"name": "BUCK1.VOUT_NORM", "kind": "config",
                                                    "value": f"{values[0x0408]:#04x}"})
        self.assertEqual(case.mram.writes, [])

    def test_compare_stops_on_a_config_difference_only(self):
        values = {address: 1 for address in ADDRESSES}
        code, first = run_cli(["pmic-read", "--side", "left"], snapshot(values))
        self.assertEqual(code, 0)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "snap.json"
            path.write_text(json.dumps(first))
            changed = {**values, 0x0708: 9, 0x0207: 3}  # watchdog timer and VBUS status only
            code, report = run_cli(["pmic-read", "--side", "left", "--compare", str(path)], snapshot(changed))
            self.assertEqual(code, 0)
            self.assertEqual(report["diff"]["config"], {})
            self.assertEqual(set(report["diff"]["watchdog"]), {"TIMER.TARGET_HI"})
            self.assertEqual(set(report["diff"]["status"]), {"VBUSIN.STATUS"})
            changed[0x0408] = 8  # BUCK1 voltage code
            code, report = run_cli(["pmic-read", "--side", "left", "--compare", str(path)], snapshot(changed))
            self.assertEqual(code, 3)
            self.assertEqual(report["diff"]["config"], {"BUCK1.VOUT_NORM": {"before": "0x01", "now": "0x08"}})

    def test_a_bad_compare_file_is_refused_before_the_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.json"
            path.write_text("{}")

            def no_case(_args):
                raise AssertionError("touched the case")

            case = Case(temple())
            case.link = no_case
            from unittest import mock
            from wisp_w18 import cli
            with mock.patch.object(cli, "make_link", no_case), mock.patch("sys.stderr"), mock.patch("sys.stdout"):
                self.assertEqual(cli.main(["pmic-read", "--side", "left", "--compare", str(path)]), 2)

    def test_pmic_read_needs_the_bootloader_checked_first(self):
        from fake_temple import FakeLoaderLink
        link = FakeLoaderLink(temple())
        with self.assertRaises(session.RefusedError), session.Session(link, log=lambda m: None) as s:
            s.pmic_read()
