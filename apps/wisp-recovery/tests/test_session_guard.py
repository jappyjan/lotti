# SPDX-License-Identifier: MIT
"""The session-time guard and the multi-session write (recovery.md, "Long relay sessions").

On hardware, case relay sessions stopped dead after about 20 s (1,000-4,000 exchanges); short
sessions passed. The relay model here can fail the same way, by wall time since the relay
started (`hang_after_s`) or by exchange count (`hang_after_exchanges`), on a virtual clock that
every exchange advances by the measured 17.5 ms. Checked: link-soak and recover split into
sessions that end inside --max-session-s; each recover session CRC-checks the body written so
far before it adds to it; the vectors are written once, last, after a whole-body CRC; a stopped
split write resumes (--resume-at) only after its CRC check; the idle pause (--idle-s) tells the
two failure models apart. And drdaeman's real relay binary answers the empty G2TX the idle pause
sends."""

import hashlib
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_temple import FakeClock, FakeLoaderLink
from test_w18 import FAKE_PATCHED, SmallStock, fake_stock, temple
from wisp_case import pins as case_pins
from wisp_case.rom import RomError
from wisp_w18 import cli, image, links, loader, pins, relay_model, session

try:
    import fake_case as fc
except ImportError:  # unicorn missing
    fc = None

BODY = pins.APP_BASE + 16


class Case:
    """A fresh relay model (the case reset and reloaded) per session, on one temple and clock."""

    def __init__(self, mram, **model):
        self.mram, self.model, self.clock = mram, model, FakeClock()
        self.relays: list[relay_model.RelayModel] = []
        self.links: list[links.RelayPortLink] = []
        self.programs: list[tuple] = []  # (program sha prefix, arg0, arg1) of every LOAD

    def link(self, _args=None):
        backend = FakeLoaderLink(self.mram)
        original = backend.exchange

        def exchange(frame, backend=backend):
            if len(frame) == 32 and frame[4:8] == b"RQST" and frame[8] == loader.LOAD:
                import struct
                _length, _entry, a0, a1, _crc = struct.unpack_from("<HHIII", frame[9:31])
                self.programs.append((a0, a1))
            return original(frame)

        backend.exchange = exchange
        relay = relay_model.RelayModel(backend, clock=self.clock, **self.model)
        self.relays.append(relay)
        link = links.RelayPortLink(relay, "left", clock=self.clock)
        self.links.append(link)
        return link


def run_cli(argv, case):
    reports = []
    with mock.patch.object(cli, "make_link", case.link), \
            mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED), \
            mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)), \
            mock.patch("sys.stdout"), mock.patch("sys.stderr"):
        code = cli.main(argv)
    return code, reports[0]


def recover_cli(stock, case, *extra):
    with tempfile.TemporaryDirectory() as tmp, SmallStock(stock):
        raw = Path(tmp) / "stock.bin"
        raw.write_bytes(stock)
        return run_cli(["recover", "--side", "left", "--image", str(raw), *extra], case)


def app_bytes(n):
    return bytes((i * 31 + 7) & 255 for i in range(n))


class SoakGuard(unittest.TestCase):
    def test_one_long_session_stalls_like_the_hardware(self):
        case = Case(temple(app_bytes(65536)), hang_after_s=20.0)
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", "65536"], case)
        self.assertEqual(code, 1)
        self.assertIn("timeout reading relay response", report["error"])
        self.assertTrue(report["stopped_in"].startswith("stream"))
        self.assertAlmostEqual(report["stall"]["since_relay_start_s"], 20.0, delta=0.1)
        self.assertEqual(report["link"]["relay_started_t"], 0.0)
        self.assertEqual(case.mram.writes, [])
        # The model's record is the hardware's: phase 1, route never restored.
        d = links.decode_relay_record(bytes(case.relays[0].record))
        self.assertEqual((d["phase"], d["yhm_writes_ok"], d["last_temple_send"]), (1, "0x00f", 32))

    def test_split_soak_passes_and_every_session_ends_inside_the_budget(self):
        app = app_bytes(65536)
        case = Case(temple(app), hang_after_s=20.0)
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", "65536", "--max-session-s", "12"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["crc32"], f"{zlib.crc32(app):08x}")
        self.assertGreater(len(report["sessions"]), 3)
        self.assertTrue(all(s["relay_seconds"] <= 12.0 for s in report["sessions"]), report["sessions"])
        self.assertTrue(all(r.state == "reset" for r in case.relays))  # every relay exited normally
        self.assertEqual(case.mram.writes, [])

    def test_idle_pause_with_a_wall_time_cause_stops_in_the_pause(self):
        case = Case(temple(app_bytes(4096)), hang_after_s=20.0)
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", "4096", "--idle-s", "45"], case)
        self.assertEqual(code, 1)
        self.assertTrue(report["stopped_in"].startswith("idle pause"), report["stopped_in"])
        self.assertLess(report["stall"]["since_relay_start_s"], 25.0)
        self.assertEqual(case.mram.writes, [])

    def test_idle_pause_with_a_per_exchange_cause_passes_the_pause(self):
        case = Case(temple(app_bytes(65536)), hang_after_exchanges=1111)
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", "65536", "--idle-s", "45"], case)
        self.assertEqual(code, 1)
        self.assertTrue(report["stopped_in"].startswith("stream"), report["stopped_in"])
        self.assertGreaterEqual(report["stall"]["since_relay_start_s"], 45.0)
        self.assertEqual(case.relays[0].idles, 4)  # 4 x 12 s of the relay's own poll bound
        self.assertEqual(case.relays[0].sent, 1111)

    def test_idle_pause_passes_when_nothing_fails(self):
        app = app_bytes(4096)
        case = Case(temple(app))
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", "4096", "--idle-s", "45"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["idle_ticks_s"], [12.0, 12.0, 12.0, 12.0])
        self.assertEqual(report["crc32"], f"{zlib.crc32(app):08x}")

    def test_idle_and_split_are_exclusive(self):
        with mock.patch("sys.stderr"):
            self.assertEqual(cli.main(["link-soak", "--side", "left", "--idle-s", "30", "--max-session-s", "12"]), 2)


class RecoverGuard(unittest.TestCase):
    STOCK = fake_stock(40000)  # 2,500 body exchanges at 17.5 ms: one session runs past 20 s

    def dead(self):
        return temple(b"\0" * 40000)

    def test_one_session_stalls_and_never_writes_the_vectors(self):
        case = Case(self.dead(), hang_after_s=20.0)
        code, report = recover_cli(self.STOCK, case, "--max-session-s", "0")
        self.assertEqual(code, 1)
        self.assertIn("timeout reading relay response", report["error"])
        self.assertEqual(report["stopped_in"], "write the app body (vectors not yet written)")
        self.assertFalse(report["vectors_written"])
        self.assertEqual(case.mram.read(pins.APP_BASE, 16), b"\0" * 16)
        self.assertNotIn((pins.APP_BASE, 16), case.mram.writes)

    def test_split_recover_completes_with_the_vectors_last(self):
        case = Case(self.dead(), hang_after_s=20.0)
        code, report = recover_cli(self.STOCK, case)  # default --max-session-s
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(case.mram.read(pins.APP_BASE, len(self.STOCK)), self.STOCK)
        sessions = report["sessions"]
        self.assertGreater(len(sessions), 2)
        self.assertTrue(all(s["relay_seconds"] <= cli.DEFAULT_MAX_SESSION_S for s in sessions), sessions)
        writes = case.mram.writes
        self.assertEqual(writes[-1], (pins.APP_BASE, 16))  # the vectors: last ...
        self.assertEqual(writes.count((pins.APP_BASE, 16)), 1)  # ... and once
        self.assertTrue(all(a >= BODY for a, _ in writes[:-1]))  # no part touches them
        # Every session after the first CRC-checked the body written so far before writing.
        checks = [(a0, a1) for a0, a1 in case.programs if a0 == BODY]
        self.assertGreaterEqual(len(checks), len(sessions) - 1)
        self.assertEqual(report["crc_after"], f"{zlib.crc32(case.mram.read(pins.APP_BASE, 40000)):08x}")

    def stop_mid_split(self):
        """Session 3 dies in the middle of its part (a per-exchange failure)."""
        case = Case(self.dead())
        calls = [0]
        original = case.link

        def link(args=None):
            calls[0] += 1
            if calls[0] == 3:
                case.model = {"hang_after_exchanges": 200}
            else:
                case.model = {}
            return original(args)

        case.link = link
        code, report = recover_cli(self.STOCK, case)
        return case, code, report

    def test_a_stop_mid_split_leaves_old_vectors_and_a_resume_hint(self):
        case, code, report = self.stop_mid_split()
        self.assertEqual(code, 1)
        self.assertEqual(len(report["sessions"]), 3)
        done = report["body_verified"]
        self.assertGreater(done, 0)
        self.assertIn(f"--resume-at {done}", report["resume_with"])
        self.assertEqual(case.mram.read(pins.APP_BASE, 16), b"\0" * 16)
        # Everything it calls verified is the image.
        self.assertEqual(case.mram.read(BODY, done), self.STOCK[16 : 16 + done])

    def test_resume_checks_first_then_completes(self):
        case, _code, report = self.stop_mid_split()
        done = report["body_verified"]
        case.programs.clear()
        case.link = Case.link.__get__(case)
        case.model = {"hang_after_s": 20.0}
        before = len(case.mram.writes)
        code, report2 = recover_cli(self.STOCK, case, "--resume-at", str(done))
        self.assertEqual(code, 0, report2.get("error"))
        self.assertEqual(case.mram.read(pins.APP_BASE, len(self.STOCK)), self.STOCK)
        # The first program over the body is the CRC of the resumed range, before any write.
        self.assertIn((BODY, done), case.programs)
        first_write = case.mram.writes[before]
        self.assertEqual(first_write[0], BODY + done)
        self.assertEqual(case.mram.writes[-1], (pins.APP_BASE, 16))

    def test_resume_refuses_bytes_that_do_not_match(self):
        case = Case(self.dead())
        code, report = recover_cli(self.STOCK, case, "--resume-at", "4096")
        self.assertEqual(code, 1)
        self.assertIn("resume check failed", report["error"])
        self.assertEqual(case.mram.writes, [])

    def test_resume_at_must_be_aligned(self):
        case = Case(self.dead())
        with tempfile.TemporaryDirectory() as tmp, SmallStock(self.STOCK), mock.patch("sys.stderr"):
            raw = Path(tmp) / "stock.bin"
            raw.write_bytes(self.STOCK)
            self.assertEqual(cli.main(["recover", "--side", "left", "--image", str(raw), "--resume-at", "8"]), 2)
        self.assertEqual(case.mram.writes, [])

    def test_parts_are_sized_by_the_slowest_rate_seen(self):
        """A link that slows down mid-run (the case, or an emulator under load) must not make a
        later session overrun because the last part happened to be fast."""
        case = Case(self.dead())
        speeds = iter([0.0175, 0.05, 0.0175, 0.0175, 0.0175, 0.0175, 0.0175, 0.0175, 0.0175, 0.0175, 0.0175, 0.0175])
        original = case.link

        def link(args=None):
            case.model = {"exchange_s": next(speeds, 0.0175)}
            return original(args)

        case.link = link
        code, report = recover_cli(self.STOCK, case)
        self.assertEqual(code, 0, report.get("error"))
        after_slow = report["sessions"][2:]
        self.assertTrue(all(s["relay_seconds"] <= cli.DEFAULT_MAX_SESSION_S for s in after_slow), after_slow)

    def test_single_session_write_app_is_unchanged(self):
        """Session.write_app (the Renode harness's path) still writes everything in one session."""
        mram = self.dead()
        link = FakeLoaderLink(mram)
        with SmallStock(self.STOCK), session.Session(link, log=lambda m: None) as s:
            result = s.write_app(self.STOCK)
        self.assertEqual(mram.writes[-1], (pins.APP_BASE, 16))
        self.assertEqual(sum(n for a, n in mram.writes[:-1]), 40000 - 16)
        self.assertEqual(len(mram.writes) - 1, (40000 - 16 + 255) // 256)
        self.assertEqual(result["bytes"], 40000)


@unittest.skipUnless(fc, "install unicorn to run the relay under emulation")
class StubLink:
    """A link whose start or HOLD fails, recording the cleanup the session runs."""

    def __init__(self, start_error=None, okay=True):
        self.start_error, self.okay = start_error, okay
        self.sent: list[bytes] = []
        self.closed = 0

    def start(self) -> bytes:
        if self.start_error:
            raise self.start_error
        return loader.hello(0x1234)

    def exchange(self, frame: bytes) -> bytes:
        self.sent.append(frame)
        if frame == loader.cont():
            return loader.released()
        return b"\0" * 32  # not a valid OKAY

    def close(self) -> None:
        self.closed += 1


class StartFailureCleanup(unittest.TestCase):
    """F1b session 1 (2026-11-07): the relay start failed inside Session.__enter__, so __exit__
    never ran and the case was left in the relay. Failures while entering clean up too."""

    def test_link_start_failure_closes_the_link(self):
        link = StubLink(start_error=RomError("timeout reading UART registers: got 13 of 16 bytes"))
        held = session.Session(link, log=lambda _line: None)
        with self.assertRaises(RomError):
            with held:
                self.fail("the body must not run")
        self.assertEqual(link.closed, 1)
        self.assertEqual(link.sent, [])  # nothing sent: never claimed, no CONTINUE

    def test_close_failure_after_start_failure_keeps_the_original_error(self):
        link = StubLink(start_error=RomError("start"))
        link.close = mock.Mock(side_effect=links.LinkError("route restoration not verified"))
        held = session.Session(link, log=lambda _line: None)
        with self.assertRaises(RomError) as caught:
            held.__enter__()
        self.assertIn("route restoration not verified", held.cleanup_errors[0])
        self.assertTrue(any("cleanup after this error" in note for note in caught.exception.__notes__))

    def test_bad_okay_releases_once_then_closes(self):
        link = StubLink()
        held = session.Session(link, log=lambda _line: None)
        with self.assertRaises(loader.LoaderError):
            held.__enter__()
        self.assertEqual(link.sent.count(loader.cont()), 1)
        self.assertTrue(held.released)
        self.assertEqual(link.closed, 1)


class RealRelayIdle(unittest.TestCase):
    def test_empty_g2tx_is_answered_with_status_2_and_the_session_goes_on(self):
        case = fc.FakeCase(case_pins.CASE_IMAGE_LENGTH, yhm=fc.IDLE_YHM)
        case.run_timeout_us = 300_000_000
        mram = temple()
        case.temples = {"left": fc.LinkTemple(FakeLoaderLink(mram)), "right": fc.LinkTemple(FakeLoaderLink(temple()))}
        relay = (image.DATA / "case_relay_template.bin").read_bytes()
        sha = hashlib.sha256(case.flash[: case_pins.CASE_IMAGE_LENGTH]).hexdigest()
        with mock.patch.object(case_pins, "CASE_IMAGE_SHA256", sha), \
                mock.patch.object(image, "build_relay", lambda profile, cache=None: relay), \
                mock.patch("wisp_w18.pins.CASE_PRE_CHECKS", ()):
            link = links.CaseRelayLink("/dev/fake", "left", "reviewed-22", opener=fc.opener_for(case),
                                       sleep=lambda s: None)
            with session.Session(link, log=lambda m: None) as s:
                s.require_patched_bootloader(FAKE_PATCHED)
                status, frame, _ = link.idle()
                self.assertEqual((status, frame), (2, b""))
                self.assertEqual(s.bootloader_crc(), zlib.crc32(FAKE_PATCHED))  # still in lockstep
        events = {k: v for e in link.events for k, v in e.items()}
        self.assertEqual(events["relay_exit_status"], 6)
        self.assertTrue(events["route_restored"])
        self.assertIsNotNone(link.diagnostics()["relay_started_t"])
        self.assertEqual(mram.writes, [])


if __name__ == "__main__":
    unittest.main()
