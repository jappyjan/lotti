#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The host side of the case-UART protocol (tests/boot/case_uart.py) against the same golden
vectors as the firmware codec's host test (tests/case/test_case_proto.c)."""
import struct
import sys
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "boot"))
import case_uart as c  # noqa: E402


class Codec(unittest.TestCase):
    def test_requests(self):
        self.assertEqual(c.ident_request().hex(), "7e0001045753500104")
        self.assertEqual(c.read_request(1, 0).hex(), "7e000114575350020100001100000000000000000000000037")
        self.assertEqual(c.read_request(2, 595).hex(), "7e00011457535002025302110000000000000000000000008d")
        self.assertEqual(c.reset_request().hex(), "7e000114575350035253455400000000000000000000000064")

    def test_relay_shapes(self):
        """Exactly what apps/wisp-recovery status.py lets through the relay (PR #73)."""
        def request_ok(f):
            return not f or (len(f) in (9, 25, 32) and f[:4] == bytes((0x7E, 0, 1, len(f) - 5)))
        for f in (c.ident_request(), c.read_request(2, 0), c.reset_request()):
            self.assertTrue(request_ok(f), f.hex())
        self.assertFalse(request_ok(c.STOCK_VERSION_QUERY))
        # The loader's and stock's request check, the same formula: stock's own queries pass it.
        for stock in ("24000100a7", "13000001e4017d", "13000101e4017e"):
            b = bytes.fromhex(stock)
            self.assertEqual(b[-1], (len(b) + 0x7D + sum(b[:-1])) & 0xFF, stock)

    def test_boot_report(self):
        """The BOOTREP vectors of tests/case/test_case_proto.c (rung4.md W24 analysis, D2)."""
        self.assertEqual(c.bootrep_request().hex(), "7e0001045753500407")
        st, data = c.decode_reply(bytes.fromhex(
            "5aa5ff1b5753508400000d0318400000008c23000000000000000000000000ae"), c.OP_BOOTREP)
        r = c.decode_boot_report(data)
        self.assertEqual((st, r["source"], r["boot"], r["prev_stage"], r["prev_stage_ms"], r["reset_cause_names"],
                          r["prev_fault"]), (0, "wisp-boot", 3, "boot-handoff", 9100, ["watchdog"], None))
        self.assertEqual(r["flags"], ["prev-valid", "kick-ok", "stimer-xt"])

    def test_diag_record_and_v2_status(self):
        rec = bytearray(64)
        struct.pack_into("<IHHIIIHHIIIIIIIII", rec, 0, c.DIAG_MAGIC, 1, 64, 5, 0x40, 1000, 0x45, 1, 32768,
                         0x448100, 0x448001, 0x61000000, 0x20000, 0, 0, 0, 0xFFFFFFF9)
        struct.pack_into("<I", rec, 60, zlib.crc32(bytes(rec[:60])))
        d = c.decode_diag_record(bytes(rec))
        self.assertEqual((d["boots"], d["stage"], d["stage_ms"], d["fault"]["pc"]), (5, "s0-loop", 1000, 0x448100))
        bad = bytearray(rec)
        bad[10] ^= 1
        with self.assertRaises(ValueError):
            c.decode_diag_record(bytes(bad))
        b = bytearray(c.BOOT_STATUS_SIZE)
        struct.pack_into("<IHHIIiii", b, 0, 0x54534257, 2, c.BOOT_STATUS_SIZE, 1, 0x3925C2, 0, 0, -2)
        struct.pack_into("<IIHHBBBB", b, 608, 0x40, 0, 2, 300, 1, 0, 3, 0)
        b[624:688] = rec
        struct.pack_into("<I", b, 688, zlib.crc32(bytes(b[:688])))
        s = c.decode_boot_status(bytes(b))
        self.assertEqual((s["version"], s["reset_cause_names"], s["window_answers"], s["prev"]["boots"]),
                         (2, ["watchdog"], 2, 5))

    def test_version(self):
        v = c.decode_version(bytes.fromhex("5aa5ff0924575350000102000028"))
        self.assertTrue(v["wisp"])
        self.assertEqual(v["version"], (0, 1, 2, 0))
        stock = c.decode_version(bytes.fromhex("5aa5ff0924010305020400180557"))  # step 0, left temple
        self.assertFalse(stock["wisp"])
        self.assertEqual(stock["firmware"], "2.4.0.24")

    def test_replies(self):
        self.assertEqual(c.decode_reply(bytes.fromhex("5aa5ff08575350830000000083"), c.OP_RESET)[0], 0)
        with self.assertRaises(ValueError):
            c.decode_reply(bytes.fromhex("5aa5ff08575350830000000084"), c.OP_RESET)
        with self.assertRaises(ValueError):
            c.decode_reply(bytes.fromhex("5aa5ff08575350830000000083"), c.OP_IDENT)
        st, data = c.decode_reply(bytes.fromhex("5aa5ff10575350810000010200053b930ffbff0068"), c.OP_IDENT)
        i = c.decode_ident(data)
        self.assertEqual((st, i["version"], i["stage"], i["battery_mv"], i["bt_result"]),
                         (0, (0, 1, 2), "bt-failed", 3987, -5))

    def test_read_block_and_hook(self):
        block = bytes(range(256)) * 3
        block = block[:c.BOOT_STATUS_SIZE]

        def temple(req):
            p = req[4:-1]
            op = p[3]
            if op == c.OP_IDENT:
                return c.frame(b"WSP\x81\x00" + bytes((0, 0, 0, 0, 5, 0x3B)) + struct.pack("<Hh", 3987, -5) + b"\0")
            blk, off, n = struct.unpack_from("<BHB", p, 4)
            data = (bytes(56) if blk == 1 else block)
            chunk = data[off:off + n]
            payload = b"WSP\x82\x00" + struct.pack("<BHH", blk, off, len(data)) + chunk
            return c.frame(payload + bytes(27 - len(payload)) if len(payload) > 24 else payload + bytes(24 - len(payload)))
        self.assertEqual(c.read_block(temple, c.BLOCK_BOOT), block)
        hook = c.WispStatus()
        answers = []
        for i in range(60):
            a = hook.decode(temple(hook.request(i)))
            answers.append(a)
            if hook.complete(answers):
                break
        self.assertTrue(hook.complete(answers))
        self.assertEqual(i, 1 + 4 + -(-c.BOOT_STATUS_SIZE // c.READ_MAX) - 1)  # IDENT, 4 + 41 READs
        self.assertIsNone(hook.decode(bytes.fromhex("5aa5ff0924010305020400180557")))

    def test_status(self):
        body = bytes([1, 5]) + struct.pack("<h", -5) + bytes([0x13, 0x3B]) + struct.pack("<H", 3987) + \
            bytes([0, 0, 0, 0]) + struct.pack("<IIIIIIHhHH", 0, 0x01020304, 7, 0, 0, 0, 0, 0x7FFF, 612, 0) + \
            b"abcdef0123\0\0"
        s = c.decode_status(body)
        self.assertEqual((s["stage"], s["bt_result"], s["battery_mv"], s["confirm_result"], s["rev"]),
                         ("bt-failed", -5, 3987, None, "abcdef0123"))
        self.assertEqual(s["flags"], ["battery", "vbus", "pmic-wdt", "boot-services", "boot-status"])

    def test_boot_status(self):
        b = bytearray(612)
        struct.pack_into("<IHHIIiii", b, 0, 0x54534257, 1, 612, 1, 0x3925C2, 0, 0, -2)
        b[44:52] = bytes([6, 1, 0, 0, 0, 1, 1, 0])
        struct.pack_into("<IIIIi", b, 52, 0x971F4516, 3700100, 0, 0, 0)
        b[72:72 + 9] = b"touch.bin"
        struct.pack_into("<IIi", b, 72 + 32, 34720, 0xBEA43830, 0)
        struct.pack_into("<I", b, 608, zlib.crc32(bytes(b[:608])))
        s = c.decode_boot_status(bytes(b))
        self.assertEqual((s["observe"], s["staging_id"], s["inventory"][0]["name"], s["action"]),
                         (True, 0x971F4516, "touch.bin", "run-app"))
        b[100] ^= 1
        with self.assertRaises(ValueError):
            c.decode_boot_status(bytes(b))



if __name__ == "__main__":
    unittest.main()
