# SPDX-License-Identifier: MIT
"""The case's YHM4005 watchdog and the relay that feeds it (recovery.md, "Long relay sessions").

On hardware every long relay session stopped about 20 s after the relay started: the case's
YHM4005 reset the case, because only the case app pulses PB2. observed-33-feed (relay_feed.py,
data/case_relay_feed.S) pulses it from every loop the relay waits in.

- The patch itself: where it goes, what it replaces, what the added code may touch.
- The real relay binary under Unicorn (fake_case.py) with a YHM4005 on PB2 and emulated time:
  the old relay is reset 20 s after it starts, as on hardware; the new one survives a long idle,
  a long link-soak and a multi-minute recover through the real CaseRelayLink and cli; and the
  cleanup copies with a watchdog reset in the middle of its ROM session.
- The relay model (relay_model.py) with the same watchdog, for the session-level tests.
"""

import hashlib
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_temple import FakeClock, FakeLoaderLink
from test_w18 import FAKE_PATCHED, HAVE_CACHE, SmallStock, fake_stock, temple
from wisp_case import pins as case_pins
from wisp_case import rom
from wisp_w18 import cli, image, links, pins, relay_feed, relay_model, session

try:
    import fake_case as fc
except ImportError:  # unicorn missing
    fc = None

TEMPLATE = (image.DATA / "case_relay_template.bin").read_bytes()  # reviewed-22, waveform zeroed
FED = relay_feed.apply(TEMPLATE)
WATCHDOG_S = 20.0  # 4005 reg 5 = 0x3B on Jan's case (TIME_OUT 7)
EXCHANGE_S = 0.0175  # one relay exchange on hardware (F1)


def app_bytes(n):
    return bytes((i * 31 + 7) & 255 for i in range(n))


def thumb_bls(code: bytes, base: int):
    """(address, target) of every BL in a run of Thumb code."""
    out, at = [], 0
    while at < len(code) - 2:
        first, second = struct.unpack_from("<HH", code, at)
        if first & 0xF800 == 0xF000 and second & 0xD000 == 0xD000:
            out.append((base + at, image.bl_target(base + at, code[at : at + 4])))
            at += 4
        else:
            at += 2
    return out


class FeedPatch(unittest.TestCase):
    def test_sites_and_appended_code(self):
        self.assertEqual(len(FED), pins.RELAY_BYTES + relay_feed.BIN_BYTES)
        self.assertEqual(len(FED) % 4, 0)  # the ROM writes words
        self.assertLessEqual(pins.RELAY_ADDRESS + len(FED), relay_feed.LIMIT)  # the G2RQ buffer stays free
        self.assertLessEqual(pins.RELAY_ADDRESS + len(FED), case_pins.RESULT_ADDRESS)
        rom.sram_regions(FED)  # the tool's own overlap check accepts it
        changed = {address - pins.RELAY_ADDRESS + i for address, *_ in relay_feed.SITES for i in range(4)}
        for i in range(pins.RELAY_BYTES):  # drdaeman's bytes everywhere but the six sites
            if i not in changed:
                self.assertEqual(FED[i], TEMPLATE[i], hex(pins.RELAY_ADDRESS + i))
        for address, old, target, _what in relay_feed.SITES:
            at = address - pins.RELAY_ADDRESS
            self.assertEqual(TEMPLATE[at : at + 4], old)
            self.assertEqual(image.bl_target(address, FED[at : at + 4]), target)
            self.assertTrue(relay_feed.BASE <= target < relay_feed.END)
        self.assertEqual(FED[pins.RELAY_BYTES :], relay_feed.blob())

    def test_the_added_code_touches_only_rcc_gpiob_and_tim6(self):
        code = relay_feed.blob()
        for word in relay_feed.literals(code):
            if word >= 0x1_0000:  # an address, not a count
                self.assertIn(word, relay_feed.PERIPHERALS, hex(word))
        pool = len(code) - 4 * len(relay_feed.literals(code))
        for at, target in thumb_bls(code[:pool], relay_feed.BASE):
            self.assertIn(target, relay_feed.CALLS, f"{at:#x} calls {target:#x}")
        # No address in the case flash or its FLASH controller anywhere, and no `blx`.
        for word in relay_feed.literals(code):
            self.assertFalse(0x0800_0000 <= word < 0x0810_0000 or 0x4002_2000 <= word < 0x4002_2400)
        halfwords = struct.unpack_from(f"<{pool // 2}H", code)
        self.assertFalse(any(h & 0xFF87 == 0x4780 for h in halfwords))
        self.assertEqual(struct.unpack_from("<H", code, relay_feed.FED_DELAY_COUNTER - relay_feed.BASE)[0], 0x3C01)

    def test_apply_refuses_another_layout(self):
        moved = bytearray(TEMPLATE)
        moved[0x09BC] ^= 1
        with self.assertRaises(relay_feed.FeedError):
            relay_feed.apply(bytes(moved))
        with self.assertRaises(relay_feed.FeedError):
            relay_feed.apply(FED)  # never twice

    @unittest.skipUnless(HAVE_CACHE, "stock bundles not in .wisp-cache/stock")
    def test_pinned_relay_is_observed_33_plus_the_feed(self):
        old, new = image.build_relay("observed-33"), image.build_relay("observed-33-feed")
        self.assertEqual(image.sha(new), pins.RELAY_SHA256["observed-33-feed"])
        self.assertEqual(new, relay_feed.apply(old))
        self.assertEqual(pins.DEFAULT_CASE_PROFILE, "observed-33-feed")


class CliDefaults(unittest.TestCase):
    def run_recover(self, *extra):
        stock = fake_stock(4000)
        reports = []
        clock = FakeClock()
        mram = temple(b"\0" * 4000)

        def make_link(_args):
            return links.RelayPortLink(relay_model.RelayModel(FakeLoaderLink(mram), clock=clock), "left", clock=clock)

        with tempfile.TemporaryDirectory() as tmp, SmallStock(stock), \
                mock.patch.object(cli, "make_link", make_link), \
                mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED), \
                mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            raw = Path(tmp) / "stock.bin"
            raw.write_bytes(stock)
            code = cli.main(["recover", "--side", "left", "--image", str(raw), *extra])
        self.assertEqual(code, 0, reports[0].get("error"))
        return reports[0]

    def test_the_feeding_relay_is_the_default_and_sessions_follow_it(self):
        self.assertEqual(self.run_recover()["max_session_s"], cli.DEFAULT_MAX_SESSION_FEED_S)
        self.assertEqual(self.run_recover("--case-profile", "observed-33")["max_session_s"], cli.DEFAULT_MAX_SESSION_S)
        self.assertIsNone(self.run_recover("--max-session-s", "0")["max_session_s"])  # one session
        self.assertEqual(self.run_recover("--case-profile", "observed-33", "--max-session-s", "30")["max_session_s"], 30)


class ModelWatchdog(unittest.TestCase):
    """relay_model.RelayModel with the case's watchdog, behind the real framing and cli."""

    def soak(self, feeds, nbytes=65536):
        app = app_bytes(nbytes)
        mram = temple(app)
        clock = FakeClock()
        relays, reports = [], []

        def make_link(_args):
            relay = relay_model.RelayModel(FakeLoaderLink(mram), clock=clock, watchdog_s=WATCHDOG_S,
                                           feeds_watchdog=feeds)
            relays.append(relay)
            return links.RelayPortLink(relay, "left", clock=clock)

        with mock.patch.object(cli, "make_link", make_link), \
                mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED), \
                mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            code = cli.main(["link-soak", "--side", "left", "--bytes", str(nbytes)])
        return code, reports[0], relays, app

    def test_without_the_feed_one_session_stops_20_s_in(self):
        code, report, relays, _ = self.soak(False)
        self.assertEqual(code, 1)
        self.assertTrue(relays[0].watchdog_reset)
        self.assertAlmostEqual(report["stall"]["since_relay_start_s"], WATCHDOG_S, delta=0.1)

    def test_with_the_feed_one_long_session_passes(self):
        code, report, relays, app = self.soak(True)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(len(report["sessions"]), 1)
        self.assertGreater(report["seconds"], 3 * WATCHDOG_S)
        self.assertFalse(relays[0].watchdog_reset)
        self.assertEqual(report["crc32"], f"{zlib.crc32(app):08x}")


@unittest.skipUnless(fc, "install unicorn to run the relay under emulation")
class RealRelayWatchdog(unittest.TestCase):
    """The relay binary (template: Even's waveform is a hook) under Unicorn, with the YHM4005.
    Emulated time advances in poll steps of 50 ms, so a watchdog reset lands up to one step late."""

    STEP = 0.05

    @classmethod
    def setUpClass(cls):
        # The host thread and Unicorn's callbacks hand the GIL back and forth on every byte; the
        # default 5 ms switch interval makes an exchange cost ~12 ms of wall time instead of ~6.
        cls.switch = sys.getswitchinterval()
        sys.setswitchinterval(0.0001)

    @classmethod
    def tearDownClass(cls):
        sys.setswitchinterval(cls.switch)

    def case(self, mram, poll_step_s=0.05):
        case = fc.FakeCase(case_pins.CASE_IMAGE_LENGTH, yhm=fc.IDLE_YHM, wdt_timeout_s=WATCHDOG_S,
                           exchange_s=EXCHANGE_S, poll_step_s=poll_step_s)
        case.run_timeout_us = 3_000_000_000
        case.temples = {"left": fc.LinkTemple(FakeLoaderLink(mram)), "right": fc.LinkTemple(FakeLoaderLink(temple()))}
        return case

    def patches(self, case, relay):
        sha = hashlib.sha256(case.flash[: case_pins.CASE_IMAGE_LENGTH]).hexdigest()
        return [mock.patch.object(case_pins, "CASE_IMAGE_SHA256", sha),
                mock.patch.object(image, "build_relay", lambda profile, cache=None: relay),
                mock.patch("wisp_w18.pins.CASE_PRE_CHECKS", ())]

    def idle_session(self, relay, ticks, poll_step_s=0.05, read_cap_s=2.0):
        mram = temple()
        case = self.case(mram, poll_step_s)
        case.read_cap_s = read_cap_s
        patches = self.patches(case, relay)
        for p in patches:
            p.start()
        error = None
        try:
            link = links.CaseRelayLink("/dev/fake", "left", "x", opener=fc.opener_for(case), sleep=lambda s: None)
            with session.Session(link, log=lambda m: None) as s:
                s.require_patched_bootloader(FAKE_PATCHED)
                for _ in range(ticks):
                    self.assertEqual(link.idle()[:2], (2, b""))
                self.assertEqual(s.bootloader_crc(), zlib.crc32(FAKE_PATCHED))  # still in lockstep
        except Exception as caught:  # noqa: BLE001
            error = caught
        finally:
            for p in patches:
                p.stop()
        events = {k: v for e in link.events for k, v in e.items()}
        self.assertEqual(mram.writes, [])
        self.assertEqual(case.forbidden_writes, [])
        return case, link, events, error

    def assert_case_clean(self, case, relay):
        self.assertEqual(case.mode, "normal")  # back in its own app (banner seen)
        for base, length in ((case_pins.BRIDGE_ADDRESS, len(relay)), (case_pins.RESULT_ADDRESS, case_pins.RESULT_LENGTH)):
            self.assertEqual(bytes(case.uc.mem_read(base, length)), bytes(length), hex(base))

    def test_old_relay_is_reset_20_s_after_it_starts(self):
        case, link, events, error = self.idle_session(TEMPLATE, 2)
        self.assertIn("timeout reading relay response to an empty G2TX", repr(error))
        started = case.relay_started_at
        self.assertEqual(case.wdt_feeds, [round(started, 6)])  # the relay start drives PB2 low, then nothing
        self.assertAlmostEqual(case.wdt_resets[0] - started, WATCHDOG_S + self.STEP / 2, delta=self.STEP / 2)
        # The first empty G2TX came back after the relay's own poll bound, 18 s as on hardware.
        first = next(e for e in link.diagnostics()["recent"] if e.get("idle"))
        self.assertEqual(first["relay_status"], 2)
        record = events["relay_record_decoded"]
        self.assertEqual(record["phase"], 1)  # the exit path never ran: the hardware's record
        self.assertFalse(events["route_restored"])
        self.assertIn(("deaf", ord("G")), case.rom_log)  # the ROM heard G2TX/G2EX first, not 0x7F ...
        self.assert_case_clean(case, TEMPLATE)  # ... and the NRST in the cleanup still got a fresh one

    def test_new_relay_survives_a_long_idle(self):
        case, link, events, error = self.idle_session(FED, 3)
        self.assertIsNone(error)
        started = case.relay_started_at
        self.assertEqual(case.wdt_resets, [])
        self.assertGreaterEqual(case.now() - started, 3 * WATCHDOG_S)
        feeds = case.wdt_feeds
        self.assertLess(feeds[1] - started, 0.001)  # the first pulse of its own, at relay start
        gaps = [b - a for a, b in zip(feeds[1:], feeds[2:])]
        self.assertTrue(all(2.0 <= g <= 2.2 for g in gaps), gaps)  # 2.0 s + a poll step
        self.assertEqual(events["relay_exit_status"], 6)
        self.assertTrue(events["route_restored"])
        self.assert_case_clean(case, FED)

    def test_pulse_shape(self):
        # Small poll steps take a few seconds of wall time per idle tick.
        case, link, events, error = self.idle_session(FED, 1, poll_step_s=0.0005, read_cap_s=30.0)
        self.assertIsNone(error)
        edges = [(t, level) for t, level in case.pb2_edges if t > case.relay_started_at + 0.2]  # after the start
        lows = [b[0] - a[0] for a, b in zip(edges, edges[1:]) if a[1] == 0 and b[1] == 1]
        highs = [b[0] - a[0] for a, b in zip(edges, edges[1:]) if a[1] == 1 and b[1] == 0]
        self.assertGreater(len(lows), 10)
        self.assertTrue(all(0.0045 <= w <= 0.0051 for w in lows), lows)  # 4.5 ms (+ one 0.5 ms step)
        self.assertTrue(all(2.0 <= h <= 2.0011 for h in highs), highs)  # 2.0 s

    def cli_run(self, relay, argv, mram, setup=None):
        case = self.case(mram)
        if setup:
            setup(case)
        reports, made = [], []

        def make_link(args):
            made.append(links.CaseRelayLink("/dev/fake", args.side, args.case_profile, opener=fc.opener_for(case),
                                            sleep=lambda s: None))
            return made[-1]

        patches = self.patches(case, relay) + [
            mock.patch.object(cli, "make_link", make_link),
            mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED),
            mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)),
            mock.patch("sys.stdout"), mock.patch("sys.stderr")]
        for p in patches:
            p.start()
        try:
            code = cli.main(argv)
        finally:
            for p in patches:
                p.stop()
        self.assertEqual(case.forbidden_writes, [])
        return case, code, reports[0], made

    def test_long_link_soak_through_the_new_relay(self):
        app = app_bytes(65536)
        case, code, report, _ = self.cli_run(FED, ["link-soak", "--side", "left", "--bytes", "65536"], temple(app))
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["crc32"], f"{zlib.crc32(app):08x}")
        self.assertEqual(len(report["sessions"]), 1)
        self.assertGreater(report["exchanges"], 4000)
        self.assertGreater(case.now() - case.relay_started_at, 3 * WATCHDOG_S)
        self.assertEqual(case.wdt_resets, [])

    def test_the_same_soak_through_the_old_relay_stops_like_f1(self):
        app = app_bytes(65536)
        case, code, report, _ = self.cli_run(TEMPLATE, ["link-soak", "--side", "left", "--bytes", "65536"],
                                             temple(app))
        self.assertEqual(code, 1)
        self.assertIn("timeout reading relay response", report["error"])
        self.assertAlmostEqual(case.wdt_resets[0] - case.relay_started_at, WATCHDOG_S, delta=self.STEP)
        # F1 on hardware: 1,110 good exchanges at 17.5 ms, then silence.
        self.assertTrue(1050 <= report["stall"]["exchange"] <= 1150, report["stall"])

    def test_multi_minute_recover_through_the_new_relay(self):
        stock = fake_stock(110_000)  # about 7,300 exchanges: over two minutes at 17.5 ms
        mram = temple(b"\0" * 110_000)
        with tempfile.TemporaryDirectory() as tmp, SmallStock(stock):
            raw = Path(tmp) / "stock.bin"
            raw.write_bytes(stock)
            case, code, report, _ = self.cli_run(
                FED, ["recover", "--side", "left", "--image", str(raw), "--max-session-s", "0"], mram)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(mram.read(pins.APP_BASE, len(stock)), stock)
        self.assertEqual(len(report["sessions"]), 1)  # the whole write, vectors included, in one session
        self.assertGreater(case.now() - case.relay_started_at, 120)
        self.assertEqual(case.wdt_resets, [])
        self.assertEqual(mram.writes[-1], (pins.APP_BASE, 16))  # the vectors last

    def test_cleanup_retries_when_the_watchdog_cuts_its_rom_session(self):
        def setup(case):
            def first_reset(c):  # the stall; the 4005's next RST lands in the cleanup's ROM session
                c.on_wdt_reset = None
                c.rom_bytes_until_reset = 300

            case.on_wdt_reset = first_reset

        case, code, report, made = self.cli_run(
            TEMPLATE, ["link-soak", "--side", "left", "--bytes", "4096", "--idle-s", "30"], temple(app_bytes(4096)), setup)
        self.assertEqual(code, 1)
        self.assertTrue(report["stopped_in"].startswith("idle pause"), report["stopped_in"])
        self.assertEqual(len(case.wdt_resets), 2)
        events = {k: v for e in made[0].events for k, v in e.items()}
        self.assertIn("timeout", events["case_rom_cleanup_retry"])  # the first ROM session was cut ...
        self.assertTrue(events["case_sram_cleared"])  # ... the second, after a fresh NRST, finished
        close_error = report["cleanup_errors"][-1]
        self.assertIn("restoration header", close_error)  # G2EX to a case that had reset: no answer
        self.assertIn("case route restoration not verified", close_error)  # the old relay's record
        self.assertNotIn("memory at", close_error)
        self.assert_case_clean(case, TEMPLATE)


if __name__ == "__main__":
    unittest.main()
