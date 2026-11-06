# SPDX-License-Identifier: MIT
"""The observed-33 bridge variant: derivation, pin, selection, and the run that uses it."""

import hashlib
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from wisp_case import pins  # noqa: E402
from wisp_case import step0  # noqa: E402
from wisp_case.rom import RefusedError, check_sram_write  # noqa: E402

try:
    import fake_case as fc
except ImportError:
    fc = None

REVIEWED = pins.bridge_image(pins.PROFILE_REVIEWED_22)
OBSERVED = pins.bridge_image(pins.PROFILE_OBSERVED_33)
JAN_BASELINE = "811104afaf03812033ff"  # read from Jan's case, 2026-11-06


def table(image):
    base = pins.BASELINE_TABLE_OFFSET
    return tuple(image[base + 10 * i : base + 10 * i + 10].hex() for i in range(5))


class Variant(unittest.TestCase):
    def test_pinned_hash(self):
        # Full hash, as in webflasher src/lib/pogoBridge.js POGO_BRIDGE_OBSERVED_33_SHA256.
        self.assertEqual(hashlib.sha256(OBSERVED).hexdigest(),
                         "3ca8ed1d8d37b2edef62dcb6915b5ec4b1d439160da0a89e93aa74901d760ef6")

    def test_exactly_four_bytes_differ(self):
        diff = [i for i in range(len(REVIEWED)) if REVIEWED[i] != OBSERVED[i]]
        self.assertEqual(diff, [1670, 1680, 1690, 1700])
        self.assertTrue(all((REVIEWED[i], OBSERVED[i]) == (0x22, 0x33) for i in diff))

    def test_tables_match_the_images(self):
        self.assertEqual(table(REVIEWED), pins.REVIEWED_22_BASELINES)
        self.assertEqual(table(OBSERVED), pins.profile_baselines(pins.PROFILE_OBSERVED_33))
        self.assertEqual(table(OBSERVED)[0], pins.REVIEWED_22_BASELINES[0])  # row 1 untouched

    def test_temple_request_unchanged(self):
        offset, length, _, _ = pins.TEMPLE_REQUESTS[2]
        self.assertEqual(OBSERVED[offset : offset + length].hex(), "24000100a7")

    def test_identify(self):
        self.assertEqual(pins.identify_profile(JAN_BASELINE), pins.PROFILE_OBSERVED_33)
        for row in pins.REVIEWED_22_BASELINES:
            self.assertEqual(pins.identify_profile(row), pins.PROFILE_REVIEWED_22)
        for other in ("811104afaf038d2033ff",  # row 1 with 0x33: webflasher's separate entry1 pin
                      "811104afaf03812045ff",  # register 8 = 0x45: not pinned here
                      "811104afaf03812133ff",  # another byte differs
                      "811104afaf03812033fe", "", "zz"):
            self.assertIsNone(pins.identify_profile(other), other)

    def test_sram_writes_must_match_the_loaded_variant(self):
        chunk = pins.BRIDGE_ADDRESS + 1536
        check_sram_write(chunk, OBSERVED[1536:1720], OBSERVED)
        with self.assertRaises(RefusedError):
            check_sram_write(chunk, OBSERVED[1536:1720], REVIEWED)
        with self.assertRaises(RefusedError):
            check_sram_write(chunk, REVIEWED[1536:1720], OBSERVED)


@unittest.skipUnless(fc, "install unicorn")
class RunWithJansBaseline(unittest.TestCase):
    def run_step0(self, case):
        sha = hashlib.sha256(case.flash[: pins.CASE_IMAGE_LENGTH]).hexdigest()
        report = {}
        with mock.patch.object(pins, "CASE_IMAGE_SHA256", sha):
            try:
                step0.run("/dev/fake", "left", opener=fc.opener_for(case), sleep=lambda s: None,
                          echo=lambda line: None, report=report)
                return report, None
            except Exception as error:  # noqa: BLE001
                return report, error

    def bridge_loads(self, case):
        """The bytes written to the bridge region, per load (zeroing excluded)."""
        loads, current = [], bytearray()
        for entry in case.rom_log:
            if entry[0] == "write" and entry[1] == pins.BRIDGE_ADDRESS and any(entry[2]):
                current = bytearray()
            if entry[0] == "write" and pins.BRIDGE_ADDRESS <= entry[1] < pins.BRIDGE_ADDRESS + 1720 and any(entry[2]):
                current += entry[2]
                if len(current) == 1720:
                    loads.append(bytes(current))
        return loads

    def test_switches_once_to_observed_33(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH, yhm=bytes.fromhex(JAN_BASELINE))
        report, error = self.run_step0(case)
        self.assertIsNone(error, report.get("error"))
        self.assertEqual(report["bridge_profile"], pins.PROFILE_OBSERVED_33)
        self.assertEqual(report["temple"], {"firmware": "2.4.0.24", "hardware_revision": 5})
        self.assertEqual(self.bridge_loads(case), [REVIEWED, OBSERVED])
        self.assertEqual([e for e in case.rom_log if e[0] == "go"], [("go", pins.BRIDGE_ADDRESS)] * 2)
        self.assertEqual(case.temples["left"].received, [bytes.fromhex("24000100a7")])
        self.assertEqual(bytes(case.yhm).hex(), JAN_BASELINE)
        # Each bridge_loaded line names the hash of the bytes that went into SRAM.
        loaded = [e["bridge_loaded"] for e in report["events"] if "bridge_loaded" in e]
        self.assertEqual(loaded, [hashlib.sha256(b).hexdigest() for b in self.bridge_loads(case)])
        self.assertEqual(loaded, [pins.BRIDGE_SHA256, pins.BRIDGE_VARIANTS[pins.PROFILE_OBSERVED_33][2]])
        self.assertEqual(case.mode, "normal")
        for base, length in pins.SRAM_WRITE_REGIONS:
            self.assertEqual(bytes(case.uc.mem_read(base, length)), bytes(length))

    def test_unknown_register8_stops_without_switching(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH, yhm=bytes.fromhex("811104afaf03812045ff"))
        report, error = self.run_step0(case)
        self.assertIsInstance(error, step0.Step0Error)
        self.assertEqual(report["bridge_status"], 3)
        self.assertEqual(report["bridge_profile"], pins.PROFILE_REVIEWED_22)
        self.assertEqual(self.bridge_loads(case), [REVIEWED])
        self.assertEqual(case.yhm_writes, [])
        self.assertEqual(case.temples["left"].received, [])
        self.assertEqual(case.mode, "normal")

    def test_reviewed_case_never_loads_the_variant(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH)
        report, error = self.run_step0(case)
        self.assertIsNone(error, report.get("error"))
        self.assertEqual(self.bridge_loads(case), [REVIEWED])


if __name__ == "__main__":
    unittest.main()
