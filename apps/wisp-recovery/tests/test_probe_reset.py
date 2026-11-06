# SPDX-License-Identifier: MIT
"""--probe-reset: one app-boot RTS pulse, listen, report. Never sends a byte, never enters ROM."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from wisp_case import pins  # noqa: E402
from wisp_case import step0  # noqa: E402

try:
    import fake_case as fc
except ImportError:
    fc = None

STATUS = (b"****** B200 vol:4196 pct:100, open:1, usb:1, cur:146, GLS_L:1, GLS_R:1 temp:210, "
          b"chEn:1, aging:0, otaGls:0\r\n")


class FakeClock:
    """Each call advances 0.5 s, so a 6 s listen ends after a few empty reads."""

    def __init__(self):
        self.now = 100.0

    def __call__(self):
        self.now += 0.5
        return self.now


@unittest.skipUnless(fc, "install unicorn")
class ProbeReset(unittest.TestCase):
    def probe(self, case):
        lines = []
        with tempfile.TemporaryDirectory() as out:
            code = step0.probe_reset("/dev/fake", Path(out), opener=fc.opener_for(case),
                                     sleep=lambda s: None, clock=FakeClock(), echo=lines.append)
            report = json.loads(next(Path(out).glob("probe-reset-*.json")).read_text())
        return code, report, lines

    def assert_untouched(self, case):
        self.assertEqual(case.rom_log, [])
        self.assertEqual(bytes(case.host_bytes), b"")
        self.assertNotIn("rom", case.mode)

    def test_reset_works(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH)
        code, report, lines = self.probe(case)
        self.assertEqual(code, 0)
        self.assertTrue(report["fresh_boot"])
        self.assertEqual(report["version"], "1.2.57")
        self.assertEqual([l["action"].split()[0] for l in report["lines"]],
                         ["open", "opened", "rts=False", "close"])
        self.assertEqual(report["lines"][0], {"t": report["lines"][0]["t"], "action": "open",
                                              "baud": 1_000_000, "dtr": True, "rts": True})
        self.assertTrue(all(c["t"] >= report["lines"][2]["t"] for c in report["chunks"]))
        self.assertIn("1.2.57", lines[-2])
        self.assertEqual(case.resets, 1)
        self.assert_untouched(case)

    def test_rts_ignored_only_status_lines(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH, rts_resets=False, status_line=STATUS)
        code, report, lines = self.probe(case)
        self.assertEqual(code, 2)
        self.assertFalse(report["fresh_boot"])
        self.assertIsNone(report["version"])
        self.assertEqual("".join(c["text"] for c in report["chunks"]),
                         STATUS.decode())  # full capture kept, not truncated
        self.assertIn("NO fresh boot banner", lines[-2])
        self.assert_untouched(case)

    def test_other_version(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH, rom_reply_banner=fc.BANNER.replace(b"1.2.57", b"1.2.58"))
        code, report, _ = self.probe(case)
        self.assertEqual((code, report["version"]), (3, "1.2.58"))
        self.assert_untouched(case)


@unittest.skipUnless(fc, "install unicorn")
class Step0KeepsFullFirstListen(unittest.TestCase):
    def test_status_lines_only(self):
        case = fc.FakeCase(pins.CASE_IMAGE_LENGTH, rts_resets=False, status_line=STATUS * 3)
        report = {}
        with self.assertRaises(step0.Step0Error):
            step0.run("/dev/fake", "left", opener=fc.opener_for(case), sleep=lambda s: None,
                      clock=FakeClock(), echo=lambda line: None, report=report)
        listen = report["events"][1]["case_listen_before"]
        self.assertEqual("".join(c["text"] for c in listen["chunks"]), (STATUS * 3).decode())
        self.assertEqual(listen["lines"][2]["action"], "rts=False (reset released)")
        self.assertEqual(case.rom_log, [])


if __name__ == "__main__":
    unittest.main()
