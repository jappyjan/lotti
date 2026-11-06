# SPDX-License-Identifier: MIT
"""The whole step-0 run against a fake case that executes the real pinned bridge."""

import hashlib
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from wisp_case import pins  # noqa: E402
from wisp_case import step0  # noqa: E402

try:
    import fake_case as fc
except ImportError:  # unicorn missing
    fc = None

BASELINE = fc.IDLE_YHM if fc else b""


@unittest.skipUnless(fc, "install unicorn to run the bridge under emulation")
class Step0AgainstFakeCase(unittest.TestCase):
    def run_step0(self, case, side="left"):
        sha = hashlib.sha256(case.flash[: pins.CASE_IMAGE_LENGTH]).hexdigest()
        report = {}
        with mock.patch.object(pins, "CASE_IMAGE_SHA256", sha):
            try:
                step0.run("/dev/fake", side, opener=fc.opener_for(case), sleep=lambda s: None,
                          echo=lambda line: None, report=report)
                error = None
            except Exception as caught:  # noqa: BLE001
                error = caught
        return report, error

    def assert_stock_and_clean(self, case):
        self.assertEqual(case.mode, "normal")
        self.assertEqual(bytes(case.yhm), BASELINE)
        for base, length in pins.SRAM_WRITE_REGIONS:
            self.assertEqual(bytes(case.uc.mem_read(base, length)), bytes(length), hex(base))

    def assert_rom_traffic_allowed(self, case):
        for entry in case.rom_log:
            if entry[0] == "cmd":
                self.assertIn(entry[1], pins.ROM_COMMAND_ALLOWLIST)
            elif entry[0] == "write":
                _, address, data = entry
                self.assertTrue(any(b <= address and address + len(data) <= b + n
                                    for b, n in pins.SRAM_WRITE_REGIONS), hex(address))
            elif entry[0] == "go":
                self.assertEqual(entry[1], pins.BRIDGE_ADDRESS)

    def test_left_version(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH)
        report, error = self.run_step0(case)
        self.assertIsNone(error, report.get("error"))
        self.assertTrue(report["success"])
        self.assertEqual(report["temple"], {"firmware": "2.4.0.24", "hardware_revision": 5})
        self.assertEqual(report["temple_raw"], fc.version_frame().hex())
        self.assertEqual(report["case_version_before"], "1.2.57")
        self.assertEqual(report["case_version_after"], "1.2.57")
        self.assertTrue(report["bridge_record"]["yhm_restored"])
        # The temple heard exactly one 5-byte version query; the other temple nothing.
        self.assertEqual(case.temples["left"].received, [bytes.fromhex("24000100a7")])
        self.assertEqual(case.temples["right"].received, [])
        # Route select (5, 6, 3, 7) and restore (7, 6, 5, 3, 4): nine volatile YHM writes.
        self.assertEqual([r for r, _ in case.yhm_writes], [5, 6, 3, 7, 7, 6, 5, 3, 4])
        self.assertEqual([e for e in case.rom_log if e[0] == "go"], [("go", pins.BRIDGE_ADDRESS)])
        self.assert_rom_traffic_allowed(case)
        self.assert_stock_and_clean(case)

    def test_right_route(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH)
        report, error = self.run_step0(case, "right")
        self.assertIsNone(error, report.get("error"))
        self.assertEqual(case.temples["right"].received, [bytes.fromhex("24000100a7")])
        self.assertEqual(case.temples["left"].received, [])

    def test_not_seated_idle_stops_with_zero_writes(self):
        busy = bytes.fromhex("811004a6a603030022ff")  # not one of the bridge's profiles
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH, yhm=busy)
        report, error = self.run_step0(case)
        self.assertIsInstance(error, step0.Step0Error)
        self.assertEqual(report["bridge_status"], 3)
        self.assertEqual(case.yhm_writes, [])
        self.assertEqual(case.temples["left"].received, [])
        self.assertEqual(bytes(case.yhm), busy)
        self.assertEqual(case.mode, "normal")
        self.assert_rom_traffic_allowed(case)

    def test_silent_temple(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH,
                           temples={"left": fc.FakeTemple("left", reply=b""),
                                    "right": fc.FakeTemple("right")})
        report, error = self.run_step0(case)
        self.assertIsInstance(error, step0.Step0Error)
        self.assertEqual(report["bridge_status"], 6)
        self.assertTrue(report["bridge_record"]["yhm_restored"])
        self.assert_stock_and_clean(case)

    def test_wrong_case_image_never_loads_the_bridge(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH)
        report = {}
        with mock.patch.object(pins, "CASE_IMAGE_SHA256", "0" * 64):
            with self.assertRaises(step0.Step0Error):
                step0.run("/dev/fake", "left", opener=fc.opener_for(case), sleep=lambda s: None,
                          echo=lambda line: None, report=report)
        self.assertFalse([e for e in case.rom_log if e[0] in ("write", "go")])
        self.assertEqual(case.mode, "normal")

    def test_wrong_case_version_never_enters_rom(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH,
                           rom_reply_banner=fc.BANNER.replace(b"1.2.57", b"1.2.58"))
        report, error = self.run_step0(case)
        self.assertIsInstance(error, step0.Step0Error)
        self.assertEqual(case.rom_log, [])


if __name__ == "__main__":
    unittest.main()
