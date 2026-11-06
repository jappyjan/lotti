# SPDX-License-Identifier: MIT
"""Bridge reply, retained record and temple frame, on frames recorded in public sources."""

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from wisp_case import bridge as br  # noqa: E402
from wisp_case import pins  # noqa: E402

BRIDGE = pins.bridge_image()
# Left temple, stock 2.2.6.10, hardware 5: the reply in evenRealities-webflasher's tests.
RECORDED = bytes.fromhex("5aa5ff09240103050202060a054d")
BASELINE = bytes.fromhex("811004a6a603030022ff")


def response(captured, status=0, route=0):
    head = bytes((0x47, 0x32, 0x52, 0x53, 1, 2, route, 0x42, status, len(captured), 0, 0))
    raw = head + captured
    return head, captured + bytes((sum(raw) & 0xFF,))


def retained(captured, status=0, **overrides):
    words = dict(progress=2, op=2, route=0, seq=0x42, status=status, baseline=0x3FF,
                 selected=0x3FF, restored=0x3FF, write=0x1FF, sent=5,
                 total=len(captured), stored=len(captured), errors=0)
    words.update(overrides)
    result = bytearray(160)
    result[:4] = b"GBRG"
    struct.pack_into("<13I", result, 4, *words.values())
    result[56:66] = BASELINE
    result[76:86] = BASELINE
    result[86 : 86 + len(captured)] = captured
    return bytes(result)


class Codec(unittest.TestCase):
    def setUp(self):
        self.request = br.make_request(2, "left", BRIDGE)

    def test_recorded_version_reply(self):
        parsed = br.parse_response(*response(RECORDED), self.request)
        self.assertEqual(parsed["status"], 0)
        self.assertEqual(br.decode_version(parsed["captured"]),
                         {"firmware": "2.2.6.10", "hardware_revision": 5})
        proof = br.validate_retained(retained(RECORDED), pins.PROOF, parsed, 2, "left")
        self.assertTrue(proof["yhm_restored"])

    def test_bad_checksums(self):
        head, tail = response(RECORDED)
        with self.assertRaises(ValueError):
            br.parse_response(head, tail[:-1] + bytes(((tail[-1] + 1) & 0xFF,)), self.request)
        bad = bytearray(RECORDED)
        bad[-1] ^= 1
        with self.assertRaises(ValueError):
            br.decode_version(bytes(bad))

    def test_reply_must_echo_request(self):
        with self.assertRaises(ValueError):
            br.parse_response(*response(RECORDED, route=1), self.request)

    def test_not_a_version_frame(self):
        status = bytearray(b"\x5a\xa5\xff\x0a\x13" + bytes(9))
        status.append(sum(status) & 0xFF)
        with self.assertRaises(ValueError):
            br.decode_version(bytes(status))

    def test_retained_must_prove_restoration(self):
        parsed = br.parse_response(*response(RECORDED), self.request)
        for override in (dict(write=0x0FF), dict(restored=0x1FF), dict(sent=7), dict(progress=1)):
            with self.assertRaises(ValueError, msg=override):
                br.validate_retained(retained(RECORDED, **override), pins.PROOF, parsed, 2, "left")
        unrestored = bytearray(retained(RECORDED))
        unrestored[76 + 3] = 0xAF
        with self.assertRaises(ValueError):
            br.validate_retained(bytes(unrestored), pins.PROOF, parsed, 2, "left")
        with self.assertRaises(ValueError):
            br.validate_retained(retained(RECORDED), bytes(8), parsed, 2, "left")

    def test_zero_write_stop(self):
        parsed = br.parse_response(*response(b"", status=3), self.request)
        record = retained(b"", status=3, selected=0, restored=0, write=0, sent=0)
        record = record[:76] + bytes(10) + record[86:]
        self.assertEqual(br.validate_retained(record, pins.PROOF, parsed, 2, "left")["yhm_restored"],
                         "untouched")


if __name__ == "__main__":
    unittest.main()
