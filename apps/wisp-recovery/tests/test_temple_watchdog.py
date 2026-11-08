# SPDX-License-Identifier: MIT
"""The temple's nPM1300 watchdog and the programs that feed it (recovery.md, "The temple's
watchdog").

On hardware (2026-11-07, case watchdog fed), a temple held by the patched loader was power-cycled
30.3-31.4 s after the relay started, idle or streaming: the nPM1300 watchdog the stock app arms
(30.72 s, kicked every second) keeps running through the relay's reset, and nothing kicked it.

Two levels:
  * The real binaries (feed.bin, dump_fed.bin, recover_fed.bin, and drdaeman's dump.bin and
    recover.bin for comparison) under Unicorn (temple_cpu.py): the I2C bytes, the bootloader
    calls, the rate of the kicks, the whole register footprint, the result codes, and that the
    streams are the same as drdaeman's on the wire.
  * The tool against the fake temple with a watchdog model, through the relay model on one virtual
    clock: drdaeman's programs are power-cycled about 30 s in, as on hardware; the feeding ones
    survive a long link-soak and a one-session recover; the split path still works without the
    feed; a broken feed stops a session before anything is written.
"""

import sys
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_temple import FakeLoaderLink, FakePmicWatchdog
from test_session_guard import Case, app_bytes, recover_cli, run_cli
from test_w18 import fake_stock, temple
from wisp_w18 import cli, image, pins

try:
    import temple_cpu
except ImportError:  # unicorn missing
    temple_cpu = None

HANDLE = pins.IOM7_HAL_HANDLE
TICKS_PER_S = 1024


@unittest.skipIf(temple_cpu is None, "unicorn not installed")
class Binaries(unittest.TestCase):
    def test_programs_fit_the_loader_and_match_their_pins(self):
        for name in ("feed", "dump_fed", "recover_fed"):
            code = image.program(name)
            self.assertTrue(2 <= len(code) <= 512 and len(code) % 2 == 0, name)

    def test_feed_kicks_once_through_the_bootloaders_iom7_and_puts_it_back(self):
        cpu = temple_cpu.TempleCpu()
        cpu.uc.mem_write(temple_cpu.IOM7 + 0x200, b"\x05\0\0\0")
        cpu._iom[0x200] = 5  # INTEN as power_ctrl restored it
        self.assertEqual(cpu.run("feed"), 0)
        self.assertEqual(cpu.wire, [(0x6B, bytes((0x07, 0x04, 0x01)), 0)])
        self.assertEqual([c[:3] for c in cpu.power_calls], [(HANDLE, 0, 1), (HANDLE, 2, 1)])
        self.assertFalse(cpu.iom_powered)
        self.assertEqual(cpu.violations, [])
        writes = [(a - temple_cpu.IOM7, v) for k, a, v in cpu.footprint if k == "w"]
        self.assertEqual(writes, [(0x200, 0), (0x208, 0xFFFFFFFF), (0x2C4, 0x6B), (0x128, 0), (0x10C, 0x00010407),
                                  (0x120, 0x301), (0x208, 0xFFFFFFFF), (0x200, 5)])
        # Reads outside IOM7: the I2C table entry only.
        others = {a for k, a, _ in cpu.footprint if k == "r" and not temple_cpu.IOM7 <= a < temple_cpu.IOM7 + 0x1000}
        self.assertEqual(others, {pins.I2C_TABLE_ENTRY_7, pins.I2C_TABLE_ENTRY_7 + 4})

    def test_feed_failures_return_a_code(self):
        cpu = temple_cpu.TempleCpu()
        cpu.nak = True
        self.assertEqual(cpu.run("feed"), 0x50010)  # NAK
        self.assertEqual([c[1] for c in cpu.power_calls], [0, 2])
        self.assertFalse(cpu.iom_powered)

        cpu = temple_cpu.TempleCpu()
        cpu.power_result[0] = 7  # WAKE with retain refused (no saved state)
        self.assertEqual(cpu.run("feed"), 0x107)
        self.assertEqual(cpu.wire, [])
        self.assertEqual([c[1] for c in cpu.power_calls], [0])

        cpu = temple_cpu.TempleCpu()
        cpu.power_result[2] = 3  # IN_USE: the kick went out, the power-down did not
        self.assertEqual(cpu.run("feed"), 0x603)
        self.assertEqual(len(cpu.kicks()), 1)
        self.assertTrue(cpu.iom_powered)  # the one path that leaves it on (the next WAKE is refused)

        cpu = temple_cpu.TempleCpu()
        cpu.fifo_room = 0
        self.assertEqual(cpu.run("feed"), 0x300)
        self.assertEqual(cpu.wire, [])
        self.assertFalse(cpu.iom_powered)

        cpu = temple_cpu.TempleCpu()
        cpu.uc.mem_write(pins.I2C_TABLE_ENTRY_7, bytes(8))  # not the pinned bootloader's table
        self.assertEqual(cpu.run("feed"), 0x10)
        self.assertEqual((cpu.power_calls, cpu.wire), ([], []))

    def test_feed_gives_up_on_a_busy_iom7(self):
        cpu = temple_cpu.TempleCpu()
        cpu.status_idle = False
        self.assertEqual(cpu.run("feed"), 0x200)  # busy; and the power-down is refused (IN_USE)
        self.assertEqual(cpu.wire, [])
        self.assertEqual([c[1] for c in cpu.power_calls], [0, 2])
        self.assertTrue(cpu.iom_powered)
        self.assertEqual(cpu.run("feed"), 0x107)  # the latch: no saved state to restore

    def test_a_write_that_never_completes_is_retried_and_does_not_latch(self):
        cpu = temple_cpu.TempleCpu()
        cpu.complete = False  # INTSTAT never reports CMDCMP; IOM7 stays idle, so it powers down
        self.assertEqual(cpu.run("feed"), 0x400)
        self.assertFalse(cpu.iom_powered)
        self.assertEqual(cpu.run("feed"), 0x400)  # retried: not latched

    def test_dump_fed_sends_what_dump_sends_and_kicks_once_a_second(self):
        data = app_bytes(64 * 1024 + 4)
        old, new = temple_cpu.TempleCpu(data), temple_cpu.TempleCpu(data)
        self.assertEqual(old.run("dump", 0x400000, len(data)), 0)
        self.assertEqual(new.run("dump_fed", 0x400000, len(data)), 0)
        self.assertEqual(new.sent, old.sent)  # the same 16-byte frames, in the same order
        self.assertEqual(b"".join(new.sent), data)
        self.assertEqual((old.wire, old.power_calls, old.tick_calls), ([], [], 0))
        kicks = new.kicks()
        self.assertEqual(kicks[0], 0)  # before the first frame
        gaps = [b - a for a, b in zip(kicks, kicks[1:])]
        self.assertTrue(all(TICKS_PER_S <= g <= TICKS_PER_S + new.ticks_per_exchange for g in gaps), gaps)
        self.assertGreaterEqual(len(kicks), new.ticks // (TICKS_PER_S + new.ticks_per_exchange))
        self.assertEqual(new.violations, [])
        self.assertEqual(len(new.power_calls), 2 * len(kicks))

    def test_recover_fed_writes_what_recover_writes_and_kicks_once_a_second(self):
        body = app_bytes(32 * 1024)
        target = 0x438000
        old, new = temple_cpu.TempleCpu(), temple_cpu.TempleCpu()
        for cpu, name in ((old, "recover"), (new, "recover_fed")):
            cpu.input[:] = body
            self.assertEqual(cpu.run(name, target, len(body)), 0)
            self.assertEqual(bytes(cpu.uc.mem_read(target, len(body))), body)
            self.assertEqual(cpu.violations, [])
        self.assertEqual(new.sent, old.sent)  # the same progress reports
        self.assertEqual(new.mram_writes, old.mram_writes)
        self.assertEqual(old.wire, [])
        kicks = new.kicks()
        self.assertEqual(kicks[0], 0)
        gaps = [b - a for a, b in zip(kicks, kicks[1:])]
        self.assertTrue(all(TICKS_PER_S <= g <= TICKS_PER_S + new.ticks_per_exchange for g in gaps), gaps)
        # The API check (length 0) and the argument checks behave as recover.c's: no kick, no write.
        cpu = temple_cpu.TempleCpu()
        self.assertEqual(cpu.run("recover_fed", 0, 0), 0)
        self.assertEqual(cpu.run("recover_fed", 0x438008, 16), 1)
        self.assertEqual((cpu.wire, cpu.mram_writes), ([], []))

    def test_long_programs_stop_when_iom7_cannot_be_powered_and_retry_a_nak(self):
        data = app_bytes(4096)
        cpu = temple_cpu.TempleCpu(data)
        cpu.power_result[0] = 7  # WAKE refused: what every kick gets after a refused power-down
        self.assertEqual(cpu.run("dump_fed", 0x400000, len(data)), 2)
        self.assertEqual(cpu.sent, [])
        cpu = temple_cpu.TempleCpu()
        cpu.power_result[0] = 7
        cpu.input[:] = data
        self.assertEqual(cpu.run("recover_fed", 0x438000, len(data)), 6)
        self.assertEqual((cpu.mram_writes, cpu.sent), ([], []))
        # A busy IOM7 latches (the power-down is refused): dump_fed stops at its next kick.
        cpu = temple_cpu.TempleCpu(data)
        cpu.status_idle = False
        self.assertEqual(cpu.run("dump_fed", 0x400000, len(data)), 2)
        self.assertLessEqual(len(cpu.sent), TICKS_PER_S // cpu.ticks_per_exchange + 1)
        # The I2C table of another bootloader: no call into it at all, the stream stops at once.
        cpu = temple_cpu.TempleCpu(data)
        cpu.uc.mem_write(pins.I2C_TABLE_ENTRY_7, bytes(8))
        self.assertEqual(cpu.run("dump_fed", 0x400000, len(data)), 2)
        self.assertEqual((cpu.sent, cpu.power_calls), ([], []))
        # A NAK that leaves IOM7 idle is not fatal for them: retried a second later, the stream completes.
        cpu = temple_cpu.TempleCpu(data)
        cpu.nak = True
        self.assertEqual(cpu.run("dump_fed", 0x400000, len(data)), 0)
        self.assertEqual(b"".join(cpu.sent), data)
        # A refused power-down leaves no saved state, so the next kick's power-up is refused, and
        # recover_fed stops there, at its next due kick, within about a second (a few more blocks).
        cpu = temple_cpu.TempleCpu()
        cpu.input[:] = app_bytes(32 * 1024)
        cpu.power_result[2] = 3
        self.assertEqual(cpu.run("recover_fed", 0x438000, 32 * 1024), 6)
        self.assertEqual(len(cpu.kicks()), 1)
        self.assertEqual([c[1] for c in cpu.power_calls], [0, 2, 0])
        self.assertLess(len(cpu.mram_writes), 32 * 1024 // 256)

    def test_recover_fed_stops_like_recover_when_the_input_ends(self):
        cpu = temple_cpu.TempleCpu()
        cpu.input[:] = bytes(100)
        self.assertEqual(cpu.run("recover_fed", 0x438000, 256), 5)
        self.assertEqual(cpu.mram_writes, [])


class Model(unittest.TestCase):
    def test_the_watchdog_fires_after_its_period_and_stops(self):
        clock = Case(temple()).clock
        pmic = FakePmicWatchdog(clock)
        pmic.relay_reset()
        clock.advance(30.0)
        self.assertFalse(pmic.expired())
        clock.advance(0.3)
        self.assertTrue(pmic.expired())
        clock.advance(60)
        self.assertFalse(pmic.expired())  # the power cycle stopped it


class FedCase(Case):
    """Case with the temple's watchdog: one PMIC for the temple, across every session."""

    def __init__(self, mram, pmic_kw=None, **model):
        super().__init__(mram, **model)
        self.pmic = FakePmicWatchdog(self.clock, **(pmic_kw or {}))

    def link(self, _args=None):
        link = super().link(_args)
        backend = self.relays[-1].temple
        backend.pmic = self.pmic
        backend.next_frame = backend._next_frame
        return link


def max_gap(times, start, end):
    points = [start, *times, end]
    return max(b - a for a, b in zip(points, points[1:]))


class Soak(unittest.TestCase):
    def test_without_the_feed_a_long_session_is_power_cycled_like_the_hardware(self):
        case = FedCase(temple(app_bytes(1 << 20)))
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", str(1 << 20), "--no-temple-feed"], case)
        self.assertEqual(code, 1)
        self.assertIn("temple rebooted mid-session", report["error"])
        self.assertTrue(report["stopped_in"].startswith("stream"), report["stopped_in"])
        # The app's last kick was 0.5 s before the relay's reset: power cycle 30.2 s in (hardware:
        # 30.3 s streaming, 31.4 s idle; the app kicks once a second, so 29.7-30.7 s after the reset).
        self.assertAlmostEqual(report["temple_reset_since_relay_start_s"], 30.22, delta=0.05)
        self.assertEqual(len(case.pmic.power_cycles), 1)
        self.assertFalse(report["temple_feed"])
        self.assertEqual(case.mram.writes, [])

    def test_with_the_feed_one_session_streams_a_mebibyte(self):
        app = app_bytes(1 << 20)
        case = FedCase(temple(app))
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", str(1 << 20)], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["crc32"], f"{zlib.crc32(app):08x}")
        self.assertEqual(len(report["sessions"]), 1)
        self.assertGreater(report["sessions"][0]["relay_seconds"], 1000)  # about 19 min on the clock
        self.assertTrue(report["temple_feed"])
        self.assertEqual(case.pmic.power_cycles, [])
        self.assertLess(max_gap(case.pmic.kicks, case.relays[0].t0, case.clock()), 2.0)
        self.assertGreaterEqual(report["sessions"][0]["feeds"], 1)
        self.assertEqual(case.mram.writes, [])

    def test_with_the_feed_the_idle_pause_survives_too(self):
        case = FedCase(temple(app_bytes(4096)))
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", "4096", "--idle-s", "60"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(case.pmic.power_cycles, [])

    def test_without_the_feed_the_idle_pause_ends_in_a_helo(self):
        case = FedCase(temple(app_bytes(4096)))
        code, report = run_cli(["link-soak", "--side", "left", "--bytes", "4096", "--idle-s", "60",
                                "--no-temple-feed"], case)
        self.assertEqual(code, 1)
        self.assertIn("temple rebooted during the idle pause", report["error"])


class Recover(unittest.TestCase):
    STOCK = fake_stock(64 * 1024)  # about 4,400 exchanges: 77 s on the clock, far past 30 s

    def test_with_the_feed_recover_writes_everything_in_one_session(self):
        case = FedCase(temple())
        code, report = recover_cli(self.STOCK, case, profile=pins.DEFAULT_CASE_PROFILE)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["sessions_used"], 1)
        self.assertIsNone(report["max_session_s"])
        self.assertGreater(report["sessions"][0]["relay_seconds"], 60)
        self.assertEqual(case.pmic.power_cycles, [])
        self.assertLess(max_gap(case.pmic.kicks, case.relays[0].t0, case.clock()), 2.0)
        self.assertEqual(case.mram.read(pins.APP_BASE, len(self.STOCK)), self.STOCK)

    def test_without_the_feed_the_split_write_still_works(self):
        case = FedCase(temple())
        code, report = recover_cli(self.STOCK, case, "--no-temple-feed", profile=pins.DEFAULT_CASE_PROFILE)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["max_session_s"], cli.DEFAULT_MAX_SESSION_UNFED_TEMPLE_S)
        self.assertGreater(report["sessions_used"], 3)
        self.assertTrue(all(s["relay_seconds"] <= 20.0 for s in report["sessions"]), report["sessions"])
        self.assertEqual(case.pmic.kicks, [])
        self.assertEqual(case.pmic.power_cycles, [])
        self.assertEqual(case.mram.read(pins.APP_BASE, len(self.STOCK)), self.STOCK)

    def test_without_the_feed_one_session_is_power_cycled_and_resumes_with_the_feed(self):
        case = FedCase(temple())
        code, report = recover_cli(self.STOCK, case, "--no-temple-feed", "--max-session-s", "0",
                                   profile=pins.DEFAULT_CASE_PROFILE)
        self.assertEqual(code, 1)
        self.assertIn("temple rebooted mid-session", report["error"])
        self.assertFalse(report["vectors_written"])
        self.assertEqual(len(case.pmic.power_cycles), 1)
        # Nothing of the part was CRC-checked, so there is nothing to resume from: start again, fed.
        self.assertEqual(report["body_verified"], 0)
        code, report = recover_cli(self.STOCK, case, profile=pins.DEFAULT_CASE_PROFILE)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(case.mram.read(pins.APP_BASE, len(self.STOCK)), self.STOCK)

    def test_a_broken_feed_stops_the_session_before_anything_is_written(self):
        case = FedCase(temple(), pmic_kw={"kick_status": 0x50010})
        code, report = recover_cli(self.STOCK, case, profile=pins.DEFAULT_CASE_PROFILE)
        self.assertEqual(code, 1)
        self.assertIn("temple watchdog feed failed", report["error"])
        self.assertIn("0x50010", report["error"])
        self.assertEqual(case.mram.writes, [])

    def test_feed_runs_only_after_the_bootloader_check(self):
        case = FedCase(temple(app_bytes(4096)))
        code, _report = run_cli(["loader-hello", "--side", "left"], case)
        self.assertEqual(code, 0)
        programs = [p for p in case.programs]
        # The first program is the bootloader CRC (checksum of the patched image), then feed.bin.
        self.assertEqual(programs[0], (pins.BOOT_BASE, pins.PATCHED_BOOTLOADER_BYTES))
        self.assertEqual(programs[1], (0, 0))

    def test_session_refuses_to_feed_before_the_bootloader_check(self):
        from wisp_w18 import session

        s = session.Session(FakeLoaderLink(temple()), log=lambda m: None, temple_feed=True)
        with s:
            with self.assertRaises(session.RefusedError):
                s.feed()


class KickFailure(unittest.TestCase):
    def test_a_refused_power_up_mid_write_stops_recover_cleanly(self):
        case = FedCase(temple())
        STOCK = Recover.STOCK
        original = FakeLoaderLink._prog_recover_fed

        def latch_after_feed(self, addr, n):  # feed.bin and the API check passed; IOM7 latches in a write
            if n:
                case.pmic.kick_status = 0x107
            return (yield from original(self, addr, n))
        from unittest import mock
        with mock.patch.object(FakeLoaderLink, "_prog_recover_fed", latch_after_feed):
            code, report = recover_cli(STOCK, case, profile=pins.DEFAULT_CASE_PROFILE)
        self.assertEqual(code, 1)
        self.assertIn("temple watchdog feed failed during the write", report["error"])
        self.assertEqual(case.pmic.power_cycles, [])  # stopped before the PMIC fired


class DumpKickFailure(unittest.TestCase):
    def test_a_latched_iom7_stops_a_fed_read_with_a_clear_error(self):
        case = FedCase(temple(app_bytes(1 << 20)))
        original = FakeLoaderLink._prog_dump_fed

        def latch_in_the_stream(self, addr, n):
            if n > 4096:
                case.pmic.kick_status = 0x107
            return (yield from original(self, addr, n))
        from unittest import mock
        with mock.patch.object(FakeLoaderLink, "_prog_dump_fed", latch_in_the_stream):
            code, report = run_cli(["link-soak", "--side", "left", "--bytes", str(1 << 20)], case)
        self.assertEqual(code, 1)
        self.assertIn("temple watchdog feed failed during the read", report["error"])
        self.assertEqual(case.pmic.power_cycles, [])


class Defaults(unittest.TestCase):
    def test_session_budget_defaults(self):
        self.assertEqual(cli.default_max_session_s("observed-33-feed"), 0.0)
        self.assertEqual(cli.default_max_session_s("observed-33-feed", temple_feed=False), 20.0)
        self.assertEqual(cli.default_max_session_s("observed-33"), cli.DEFAULT_MAX_SESSION_S)
        self.assertEqual(cli.default_max_session_s("observed-33", temple_feed=False), cli.DEFAULT_MAX_SESSION_S)


if __name__ == "__main__":
    unittest.main()
