# SPDX-License-Identifier: MIT
"""The status-3 refusal of a split run's second session, and the settle that avoids it.

Hardware (safety.md hardware log, "W18 F1d split", 2026-11-07): session 1 of a split link-soak
came right after two case app restarts within about 2 s (the cleanup's banner boot, then the next
start's). The pogo switch (YHM2510) was not idle yet, so the bridge refused G2RQ with a 13-byte
G2RS of status 3 and wrote nothing. The tool read those 13 bytes as a truncated 16-byte UART
register dump ("got 13 of 16 bytes"), timed out, and then called the untouched route a failed
restore. Checked here: the refusal is recognised at once and reported as "pogo switch not idle,
zero writes"; the case record is checked as a zero-write record instead; later sessions let the
case app run SETTLE_S after its banner first; and a refused session is retried once after that
settle. The relay is drdaeman's real binary under Unicorn (tests/fake_case.py) and the relay model.
"""

import argparse
import hashlib
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_temple import FakeLoaderLink
from test_w18 import FAKE_PATCHED, temple
from wisp_case import pins as case_pins
from wisp_case.transport import case_banner
from wisp_w18 import cli, image, links, relay_model, session

try:
    import fake_case as fc
except ImportError:  # unicorn missing
    fc = None

RELAY = (image.DATA / "case_relay_template.bin").read_bytes()  # reviewed-22, Even's waveform zeroed


class StepClock:
    """The host's console clock: every call advances it by `step` s. `now` reads it without
    advancing (the fake case's view of the same time)."""

    def __init__(self, step=0.1):
        self.now, self.step = 100.0, step

    def __call__(self):
        self.now += self.step
        return self.now


class ModelRefusal(unittest.TestCase):
    def test_status_3_is_recognised_at_once(self):
        relay = relay_model.RelayModel(FakeLoaderLink(temple()), not_idle=True)
        link = links.RelayPortLink(relay, "left")
        with self.assertRaises(links.PogoNotIdle) as caught:
            link.start()
        self.assertIn("pogo switch was not idle; zero writes", str(caught.exception))
        refused = next(e for e in link.events if "relay_refused_status" in e)
        self.assertEqual(refused["relay_refused_status"], 3)
        self.assertEqual(len(bytes.fromhex(refused["g2rs"])), 13)
        self.assertEqual(relay.sent, 0)  # nothing reached the temple
        self.assertEqual(relay.state, "reset")
        link.close()  # nothing to exit: the relay never armed

    def test_any_other_refusal_is_a_plain_link_error(self):
        relay = relay_model.RelayModel(FakeLoaderLink(temple()))
        link = links.RelayPortLink(relay, "left")
        relay.inbox += b"x"  # corrupts the G2RQ header: status 1
        with self.assertRaises(links.LinkError) as caught:
            link.start()
        self.assertNotIsInstance(caught.exception, links.PogoNotIdle)
        self.assertIn("status 1", str(caught.exception))


class SettleListen(unittest.TestCase):
    @unittest.skipUnless(fc, "install unicorn")
    def test_case_banner_keeps_the_app_running_for_the_settle(self):
        clock = StepClock(0.5)
        case = fc.FakeCase(case_pins.CASE_IMAGE_LENGTH)
        result = case_banner("/dev/fake", fc.opener_for(case), lambda s: None, clock, settle_s=5.0)
        self.assertEqual(result["version"], "1.2.57")
        self.assertGreaterEqual(result["settle"]["seconds"], 5.0)
        self.assertEqual(case.mode, "normal")
        plain = case_banner("/dev/fake", fc.opener_for(case), lambda s: None, StepClock(0.5))
        self.assertIsNone(plain["settle"])


@unittest.skipUnless(fc, "install unicorn to run the relay under emulation")
class RealRelay(unittest.TestCase):
    def case(self, mram, clock, **kw):
        case = fc.FakeCase(case_pins.CASE_IMAGE_LENGTH, pogo_clock=lambda: clock.now, **kw)
        case.run_timeout_us = 300_000_000
        case.temples = {"left": fc.LinkTemple(FakeLoaderLink(mram)), "right": fc.LinkTemple(FakeLoaderLink(temple()))}
        return case

    def patches(self, case):
        sha = hashlib.sha256(case.flash[: case_pins.CASE_IMAGE_LENGTH]).hexdigest()
        return [mock.patch.object(case_pins, "CASE_IMAGE_SHA256", sha),
                mock.patch.object(image, "build_relay", lambda profile, cache=None: RELAY),
                mock.patch("wisp_w18.pins.CASE_PRE_CHECKS", ())]

    def run_commands(self, case, clock, sessions=2):
        """run_sessions with `sessions` read-only sessions (a bootloader CRC each), every link a
        CaseRelayLink to the fake case on the shared console clock."""
        reports, made = [], []

        def make_link(args):
            made.append(links.CaseRelayLink("/dev/fake", args.side, args.case_profile, opener=fc.opener_for(case),
                                            sleep=lambda s: None, console_clock=clock))
            return made[-1]

        def step(s, patched, index):
            return index + 1 >= sessions, {f"crc_{index}": s.bootloader_crc()}

        args = argparse.Namespace(side="left", case_profile="x", no_temple_feed=True)
        patches = self.patches(case) + [
            mock.patch.object(cli, "make_link", make_link),
            mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED),
            mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)),
            mock.patch("sys.stdout"), mock.patch("sys.stderr")]
        for p in patches:
            p.start()
        try:
            started = time.monotonic()
            code = cli.run_sessions(args, "settle-test", step)
            took = time.monotonic() - started
        finally:
            for p in patches:
                p.stop()
        self.assertEqual(case.forbidden_writes, [])
        return code, reports[0], made, took

    @staticmethod
    def events(link):
        return {k: v for e in link.events for k, v in e.items()}

    def assert_case_clean(self, case):
        self.assertEqual(case.mode, "normal")
        for base, length in ((case_pins.BRIDGE_ADDRESS, len(RELAY)), (case_pins.RESULT_ADDRESS, case_pins.RESULT_LENGTH)):
            self.assertEqual(bytes(case.uc.mem_read(base, length)), bytes(length), hex(base))

    def test_the_hardware_failure_is_recognised_at_once(self):
        """The baseline the hardware read: CaseRelayLink.start() gets the 13-byte G2RS at once
        and says so, and the cleanup checks a zero-write record, not a route restore."""
        clock = StepClock()
        mram = temple()
        case = self.case(mram, clock, yhm=fc.NOT_IDLE_YHM)
        for p in self.patches(case):
            p.start()
        try:
            link = links.CaseRelayLink("/dev/fake", "left", "x", opener=fc.opener_for(case), sleep=lambda s: None,
                                       console_clock=clock)
            started = time.monotonic()
            with self.assertRaises(links.PogoNotIdle):
                link.start()
            self.assertLess(time.monotonic() - started, 5.0)  # no 60 s read timeout
            link.close()  # no error: an untouched route is not a failed restore
        finally:
            mock.patch.stopall()
        events = self.events(link)
        self.assertEqual(events["relay_refused_status"], 3)
        self.assertTrue(events["route_untouched"])
        self.assertNotIn("route_restored", events)
        self.assertEqual(events["relay_record_decoded"]["exit_status"], 3)
        self.assertEqual(case.yhm_writes, [])  # no route selected
        self.assertEqual(case.temples["left"].received, [])  # nothing reached the temple
        self.assertEqual(mram.writes, [])
        self.assert_case_clean(case)

    def test_later_sessions_settle_first_and_are_never_refused(self):
        clock = StepClock()
        case = self.case(temple(), clock, pogo_window_s=2.0, pogo_settle_s=3.0)
        code, report, made, _ = self.run_commands(case, clock, sessions=3)
        self.assertEqual(code, 0, report.get("error"))
        self.assertNotIn("pogo_not_idle", report)
        self.assertEqual([s.get("settle_s") for s in report["sessions"]], [None, cli.SETTLE_S, cli.SETTLE_S])
        self.assertTrue(all(idle for _t, idle in case.rom_entries))
        for link in made[1:]:
            self.assertGreaterEqual(self.events(link)["case_settle"]["seconds"], cli.SETTLE_S)
        self.assertNotIn("case_settle", self.events(made[0]))  # the first session's start is unchanged
        self.assert_case_clean(case)

    def test_without_the_settle_session_1_is_refused_like_the_hardware_then_retried(self):
        clock = StepClock()
        case = self.case(temple(), clock, pogo_window_s=2.0, pogo_settle_s=3.0)
        with mock.patch.object(cli, "SETTLE_S", 0.0):  # the old tool: no settle between sessions ...
            code, report, made, _ = self.run_commands(case, clock)
        self.assertEqual(code, 1)  # ... and its retry without a settle is refused again
        self.assertEqual(report["pogo_not_idle"], 2)
        self.assertIn("PogoNotIdle", report["error"])
        self.assertEqual(report["cleanup_errors"], [])  # not a failed route restore
        self.assertTrue(case.rom_entries[0][1])  # the first session's ROM entry found the switch idle
        self.assertIn(False, [idle for _t, idle in case.rom_entries])
        self.assert_case_clean(case)

        clock = StepClock()
        case = self.case(temple(), clock, pogo_window_s=2.0, pogo_settle_s=3.0)
        case.app_boots.append(clock.now)  # the case app restarted just before this command
        code, report, made, _ = self.run_commands(case, clock, sessions=1)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["pogo_not_idle"], 1)
        first, retry = report["sessions"]
        self.assertTrue(first["pogo_not_idle"])
        self.assertEqual((first["index"], retry["index"]), (0, 0))
        self.assertEqual(retry["settle_s"], cli.SETTLE_S)
        self.assertTrue(self.events(made[0])["route_untouched"])
        self.assertTrue(self.events(made[1])["route_restored"])
        self.assertGreaterEqual(self.events(made[1])["case_settle"]["seconds"], cli.SETTLE_S)
        self.assert_case_clean(case)

    def test_a_switch_that_never_settles_stops_after_one_retry(self):
        clock = StepClock()
        mram = temple()
        case = self.case(mram, clock, yhm=fc.NOT_IDLE_YHM)
        code, report, made, took = self.run_commands(case, clock, sessions=1)
        self.assertEqual(code, 1)
        self.assertEqual(report["pogo_not_idle"], 1 + cli.POGO_RETRIES)
        self.assertEqual(len(made), 1 + cli.POGO_RETRIES)
        self.assertIn("pogo switch was not idle; zero writes", report["error"])
        self.assertEqual(report["cleanup_errors"], [])
        self.assertLess(took, 30.0)  # two quick refusals, not two read timeouts
        self.assertEqual(mram.writes, [])
        self.assertEqual(case.temples["left"].received, [])
        self.assert_case_clean(case)


if __name__ == "__main__":
    unittest.main()
