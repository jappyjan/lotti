# SPDX-License-Identifier: MIT
"""`w18.py ble-scan` (rung4.md W24: is the native temple advertising?) against a fake bleak
scanner. Read-only: it never connects and never touches the case. No hardware."""

import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from wisp_w18 import ble, cli


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


def fake_bleak(adverts, clock):
    """A bleak module whose scanner replays `adverts`: (t, address, local name, service UUIDs, rssi)."""

    class BleakScanner:
        def __init__(self, detection_callback, **_kw):
            self.cb = detection_callback

        async def start(self):
            for t, address, name, uuids, rssi in adverts:
                clock.t = t
                self.cb(types.SimpleNamespace(address=address, name=None),
                        types.SimpleNamespace(local_name=name, service_uuids=uuids, rssi=rssi))

        async def stop(self):
            pass

    return types.SimpleNamespace(BleakScanner=BleakScanner)


def run(adverts, seconds="0.01"):
    clock = Clock()
    reports = []
    real_scan = ble.scan

    async def scan(s, adapter=None):
        return await real_scan(s, adapter, clock=clock)

    with mock.patch.dict(sys.modules, {"bleak": fake_bleak(adverts, clock)}), \
            mock.patch.object(ble, "scan", scan), \
            mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)), \
            mock.patch.object(cli, "make_link", side_effect=AssertionError("touched the case")), \
            mock.patch("sys.stdout"), mock.patch("sys.stderr"):
        code = cli.main(["ble-scan", "--side", "left", "--seconds", seconds])
    return code, reports[0]


class Classify(unittest.TestCase):
    def test_names_and_uuid(self):
        self.assertEqual(ble.classify(None, [ble.WISP_SERVICE_UUID.upper()]), "wisp")
        self.assertEqual(ble.classify("Wisp", []), "wisp")
        self.assertEqual(ble.classify("Even G2_L_A1B2C3", []), "stock-left")
        self.assertEqual(ble.classify("Even G2_R_A1B2C3", []), "stock-right")
        self.assertIsNone(ble.classify("Jan's iPhone", []))
        self.assertIsNone(ble.classify(None, []))


class Scan(unittest.TestCase):
    def test_a_native_left_and_a_stock_right(self):
        adverts = [(0.5, "AA", None, [ble.WISP_SERVICE_UUID], -60), (0.6, "AA", "Wisp", [], -58),
                   (0.7, "BB", "Even G2_R_123456", [], -50), (1.0, "CC", "Jan's iPhone", [], -40),
                   (2.0, "AA", None, [ble.WISP_SERVICE_UUID], -61),
                   # the case reset the native temple (G10b): adverts stop for a while, then resume
                   (19.0, "AA", None, [ble.WISP_SERVICE_UUID], -59)]
        code, report = run(adverts)
        self.assertEqual(code, 0)
        self.assertTrue(report["wisp_seen"])
        by = {d["address"]: d for d in report["devices"]}
        self.assertEqual(set(by), {"AA", "BB"})
        self.assertEqual((by["AA"]["kind"], by["AA"]["name"], by["AA"]["adverts"], by["AA"]["rssi_max"]),
                         ("wisp", "Wisp", 4, -58))
        self.assertEqual(by["AA"]["gaps_s"], [[2.0, 19.0]])
        self.assertEqual(by["BB"]["kind"], "stock-right")

    def test_no_wisp_advertiser_is_exit_3(self):
        code, report = run([(0.7, "BB", "Even G2_R_123456", [], -50), (0.8, "DD", "Even G2_L_654321", [], -52)])
        self.assertEqual(code, 3)
        self.assertFalse(report["wisp_seen"])
        self.assertEqual([d["kind"] for d in report["devices"]], ["stock-right", "stock-left"])


if __name__ == "__main__":
    unittest.main()
