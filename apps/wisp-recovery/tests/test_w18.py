# SPDX-License-Identifier: MIT
"""W18 tool tests against fakes (no hardware, no emulator). The Renode proof with the real
patched bootloader is apps/wisp-fw/tests/boot/w18.py (wisp-fw:w18-test)."""

import asyncio
import hashlib
import struct
import sys
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_temple import CuttingLink, FakeGatt, FakeLoaderLink, FakeMram
from wisp_w18 import ble, cli, image, loader, pins, session

CACHE = image.CACHE
HAVE_CACHE = (CACHE / "g2-2.3.2.14.bin").exists() and (CACHE / "g2-2.4.0.24.bin").exists()
FAKE_PATCHED = bytes((i * 7) & 255 for i in range(pins.PATCHED_BOOTLOADER_BYTES))


def fake_stock(n=4000):
    data = bytearray((i * 13 + 5) & 255 for i in range(n))
    struct.pack_into("<II", data, 0, 0x2007FB00, pins.APP_BASE + 0x101)
    return bytes(data)


class SmallStock:
    """Pins narrowed to a small synthetic 'stock' image so a full write runs in milliseconds."""

    def __init__(self, stock):
        self.stock = stock
        self.patches = [
            mock.patch.object(pins, "STOCK_MAIN_SHA256", hashlib.sha256(stock).hexdigest()),
            mock.patch.object(pins, "RECOVER_END", pins.APP_BASE + ((len(stock) + 15) & ~15)),
        ]

    def __enter__(self):
        for p in self.patches:
            p.start()
        return self

    def __exit__(self, *a):
        for p in self.patches:
            p.stop()


def temple(app=b"", extra=None):
    contents = {pins.BOOT_BASE: FAKE_PATCHED}
    if app:
        contents[pins.APP_BASE] = app
    contents.update(extra or {})
    return FakeMram(contents)


class Framing(unittest.TestCase):
    def test_drdaeman_wire_vector(self):
        frame = bytes.fromhex("5aa5ff100001030c48454c4f01000000454c52325c")  # [D test_tools.py]
        self.assertEqual(loader.decode_hello(frame), 0x32524C45)

    def test_tags_differ_by_direction(self):
        self.assertNotEqual(loader.tag(b"HOLD", 1), loader.tag(b"OKAY", 1))
        self.assertEqual(len(loader.hold(5)), 25)
        self.assertEqual(len(loader.okay(5)), 29)

    def test_bad_okay_is_rejected(self):
        with self.assertRaises(loader.LoaderError):
            loader.check_okay(loader.okay(1), 2)

    def test_bl_roundtrip(self):
        for pc, target in ((0x42E656, 0x43511C), (0x20011400, 0x20010000), (0x1000, 0x1000 + 4)):
            self.assertEqual(image.bl_target(pc, image.bl_encode(pc, target)), target)
        self.assertEqual(image.bl_encode(0x42E656, 0x43511C), pins.HOOK_NEW)
        self.assertEqual(image.bl_target(0x42E656, pins.HOOK_OLD), 0x42E56C)

    def test_crc32c_matches_slow_reference(self):
        data = bytes(range(256)) * 3
        self.assertEqual(image.crc32c_fast(data), image.crc32c_msb(data))

    def test_programs_are_pinned(self):
        for name in pins.PROGRAMS:
            image.program(name)


@unittest.skipUnless(HAVE_CACHE, "stock bundles not in .wisp-cache/stock")
class Images(unittest.TestCase):
    def test_patched_bootloader_reproduces_pin(self):
        patched = image.build_patched_bootloader()
        self.assertEqual(image.sha(patched), pins.PATCHED_BOOTLOADER_SHA256)
        self.assertEqual(len(patched) // 4096, 38)

    def test_tampered_bootloader_is_refused(self):
        patched = bytearray(image.build_patched_bootloader())
        for offset in (0, pins.HOOK_OFFSET, pins.STOCK_BOOTLOADER_BYTES + 10, len(patched) - 1):
            bad = bytearray(patched)
            bad[offset] ^= 1
            with self.assertRaises(image.ImageError):
                image.check_patched_bootloader(bytes(bad))

    def test_relay_reproduces_both_pins(self):
        for profile in pins.RELAY_SHA256:
            self.assertEqual(image.sha(image.build_relay(profile)), pins.RELAY_SHA256[profile])

    def test_stock_main_pin(self):
        self.assertEqual(len(image.stock_main()), pins.STOCK_MAIN_BYTES)


class Sessions(unittest.TestCase):
    def test_hello_reads_crc_and_releases(self):
        link = FakeLoaderLink(temple())
        with session.Session(link, log=lambda m: None) as s:
            s.require_patched_bootloader(FAKE_PATCHED)
            self.assertEqual(s.bootloader_crc(), zlib.crc32(FAKE_PATCHED))
            self.assertEqual(s.flag(), 0xFFFFFFFF)
        self.assertFalse(link.held)
        self.assertTrue(link.closed)
        self.assertEqual(link.mram.writes, [])

    def test_wrong_bootloader_stops_before_any_write(self):
        link = FakeLoaderLink(temple())
        with self.assertRaises(session.SessionError), session.Session(link, log=lambda m: None) as s:
            s.require_patched_bootloader(FAKE_PATCHED[:-1] + b"\0")
        self.assertFalse(link.held)  # released after the error
        self.assertEqual(link.mram.writes, [])

    def test_info_dump_skips_unpowered_otp(self):
        mram = temple()
        mram.io = {0x40020000: bytes(0x200), 0x40021004: struct.pack("<II", 0, 0),
                   0x42000000: bytes(range(256)) * 8}
        with session.Session(FakeLoaderLink(mram), log=lambda m: None) as s:
            info = s.info_dump()
        self.assertEqual(len(bytes.fromhex(info["info0"]["hex"])), 2048)
        self.assertIn("skipped", info["infoc"])
        self.assertIn("skipped", info["dcu"])

    def test_info_dump_reads_otp_and_dcu_when_powered(self):
        mram = temple()
        status = (1 << 27) | (1 << 21)
        mram.io = {0x40020000: bytes(0x200), 0x40021004: struct.pack("<II", status, status),
                   0x42000000: bytes(2048), 0x400C2000: bytes(1024), 0x400C1E00: bytes(32),
                   0x400C1F14: struct.pack("<I", 5)}
        with session.Session(FakeLoaderLink(mram), log=lambda m: None) as s:
            info = s.info_dump()
        self.assertEqual(info["dcu"]["LCSREG"], "0x00000005")
        self.assertEqual(len(bytes.fromhex(info["infoc"]["hex"])), 1024)

    def test_recover_writes_body_then_vectors(self):
        stock = fake_stock()
        dead = b"\0" * 4016
        link = FakeLoaderLink(temple(dead, {pins.APP_BASE + 4000: b"\xaa" * 16}))
        with SmallStock(stock), session.Session(link, log=lambda m: None) as s:
            result = s.write_app(stock)
        size = (len(stock) + 15) & ~15
        written = link.mram.read(pins.APP_BASE, size)
        self.assertEqual(written[: len(stock)], stock)
        self.assertEqual(written[len(stock):], b"\xaa" * (size - len(stock)))  # tail unit kept
        self.assertEqual(result["crc_after"], f"{zlib.crc32(written):08x}")
        self.assertEqual(link.mram.writes[-1], (pins.APP_BASE, 16))  # vectors last
        self.assertTrue(all(pins.APP_BASE <= a and a + n <= pins.APP_BASE + size for a, n in link.mram.writes))

    def test_recover_refuses_any_other_image(self):
        link = FakeLoaderLink(temple())
        with SmallStock(fake_stock()), self.assertRaises(session.RefusedError):
            with session.Session(link, log=lambda m: None) as s:
                s.write_app(fake_stock()[:-1] + b"\x01")
        self.assertEqual(link.mram.writes, [])

    def test_writes_outside_the_app_region_are_refused(self):
        with SmallStock(fake_stock()):
            for address in (pins.BOOT_BASE, pins.APP_BASE - 16, 0x7FE000, pins.RECOVER_END):
                link = FakeLoaderLink(temple())
                with self.assertRaises(session.RefusedError):
                    with session.Session(link, log=lambda m: None) as s:
                        s._write(address, bytes(16))
                self.assertEqual(link.mram.writes, [])

    def test_power_cut_mid_write_then_a_fresh_session_completes(self):
        stock = fake_stock(8000)
        mram = temple(b"\0" * 8000)
        link = CuttingLink(mram, cut_after_writes=10)
        with SmallStock(stock):
            with self.assertRaises(session.TempleReset), session.Session(link, log=lambda m: None) as s:
                s.write_app(stock)
            self.assertNotIn(loader.cont(), link.sent[-1:])  # nothing to release after a reset
            self.assertEqual(mram.read(pins.APP_BASE, 16), b"\0" * 16)  # vectors never committed
            with session.Session(FakeLoaderLink(mram), log=lambda m: None) as s:
                s.write_app(stock)
        self.assertEqual(mram.read(pins.APP_BASE, len(stock)), stock)


class BleInstall(unittest.TestCase):
    def run_install(self, gatt, payload):
        async def go():
            ota = ble.StockOta(gatt, log=lambda m: None)
            await ota.authenticate()
            return await ota.install(payload)
        return asyncio.run(go())

    @unittest.skipUnless(HAVE_CACHE, "stock bundles not in .wisp-cache/stock")
    def test_install_sends_exactly_the_pinned_component(self):
        patched = image.build_patched_bootloader()
        gatt = FakeGatt()
        self.assertEqual(self.run_install(gatt, patched), 8)
        self.assertEqual(gatt.ops, [0, 1] + [2] * 38 + [3])
        self.assertEqual(b"".join(gatt.blocks), patched)
        self.assertEqual(struct.unpack_from("<III", gatt.header, 8), (len(patched), image.crc32c_fast(patched), 0))
        self.assertEqual(struct.unpack_from("<II", gatt.header, 36), (1, 3))
        self.assertEqual(gatt.header[48:].split(b"\0")[0], b"ota/s200_bootloader.bin")

    def test_any_other_image_is_refused_before_sending(self):
        gatt = FakeGatt()
        with self.assertRaises(image.ImageError):
            self.run_install(gatt, b"\xff" * pins.PATCHED_BOOTLOADER_BYTES)
        self.assertEqual(gatt.ops, [])

    @unittest.skipUnless(HAVE_CACHE, "stock bundles not in .wisp-cache/stock")
    def test_block_rejection_stops_without_replay(self):
        gatt = FakeGatt(reject_block=5)
        with self.assertRaises(ble.OtaError):
            self.run_install(gatt, image.build_patched_bootloader())
        self.assertEqual(gatt.ops, [0, 1] + [2] * 6)

    @unittest.skipUnless(HAVE_CACHE, "stock bundles not in .wisp-cache/stock")
    def test_end_not_8_is_an_error(self):
        with self.assertRaises(ble.OtaError):
            self.run_install(FakeGatt(end_status=7), image.build_patched_bootloader())

    def test_side_from_advertised_name(self):
        self.assertEqual(ble.side_of("Even G2_L_abcdef"), "left")
        self.assertEqual(ble.side_of("Even G2_R_123abc"), "right")
        self.assertIsNone(ble.side_of("something"))


@unittest.skipUnless(HAVE_CACHE, "stock bundles not in .wisp-cache/stock")
class Cli(unittest.TestCase):
    def test_install_refuses_wrong_token_and_low_battery_before_ble(self):
        with mock.patch("wisp_w18.ble.BleakGatt", side_effect=AssertionError("BLE must not be touched")):
            self.assertEqual(cli.main(["bootloader-install", "--side", "left", "--address", "x",
                                       "--battery", "90", "--go", "W18-RIGHT-000000000000"]), 2)
            self.assertEqual(cli.main(["bootloader-install", "--side", "left", "--address", "x",
                                       "--battery", "70", "--go", pins.go_token("left")]), 2)

    def test_recover_refuses_a_non_pinned_image(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            bogus = Path(tmp) / "bogus.bin"
            bogus.write_bytes(fake_stock())
            self.assertEqual(cli.main(["recover", "--side", "left", "--image", str(bogus)]), 2)

    def test_plan_prints_the_token(self):
        self.assertEqual(cli.main(["bootloader-plan", "--side", "left"]), 0)

    def run_install(self, second):
        """bootloader-install over fake BLE; `second` is what the liveness reconnect meets."""
        gatts = [FakeGatt(), second]
        reports = []

        class Connection:
            def __init__(self, address, adapter=None):
                self.gatt = gatts.pop(0)

            async def __aenter__(self):
                if isinstance(self.gatt, Exception):
                    raise self.gatt
                return self.gatt

            async def __aexit__(self, *a):
                return False

        argv = ["bootloader-install", "--side", "left", "--address", "x", "--battery", "90",
                "--go", pins.go_token("left")]
        with mock.patch("wisp_w18.ble.BleakGatt", Connection), mock.patch.object(cli, "LIVENESS_DELAY", 0), \
                mock.patch.object(cli, "latest_step0", lambda side: {"report": "fake"}), \
                mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            code = cli.main(argv)
        return code, reports[0], gatts

    def test_install_liveness_reconnects(self):
        code, report, left = self.run_install(FakeGatt())
        self.assertEqual((code, report["end_status"], report["liveness"]), (0, 8, {"ok": True}))
        self.assertEqual(left, [])  # a second connection was made

    def test_install_liveness_without_answer_is_not_fatal(self):
        code, report, _ = self.run_install(ble.OtaError("temple not advertising"))
        self.assertEqual((code, report["success"], report["end_status"]), (0, True, 8))
        self.assertFalse(report["liveness"]["ok"])
        self.assertIn("not advertising", report["liveness"]["error"])


if __name__ == "__main__":
    unittest.main()
