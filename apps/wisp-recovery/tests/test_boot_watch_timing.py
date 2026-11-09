# SPDX-License-Identifier: MIT
"""boot-watch's timing against the real relay's blocking (rung4.md, "W24b results"). No hardware.

drdaeman's relay (case_exchange.c `relay_receive`) answers a G2TX only with the first temple frame
or after its poll bound: a request nobody answers holds the relay, deaf to the host, until the
temple sends something by itself (in a reboot loop, the loader's next HELO). W24b's boot-watch
asked BOOTREP once ~15 ms after CONT/HELO, inside the loader's own window, and the relay then held
that exchange until the next HELO, every boot: zero reports in 60 s. The old relay model answered
"no frame" after 17.5 ms instead, so the tests never saw it.

`WispBootTemple` is the timeline of one Wisp boot after the patched loader releases it (CONT, or
its 512 ms HELO window running out): the hand-off, Wisp Boot's report window (only BOOTREP is
answered; 300 ms, 100 ms more after each answer, at most 1 s), its NOR scan, stage-0's start-up,
then stage-0 answering everything, or (`alive=False`, W24b on silicon) nothing until the Apollo
watchdog resets it and the loader sends its next HELO. Requests that land anywhere else are lost,
and the relay model then waits for the temple's next frame or its poll bound."""

import struct
import sys
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import fake_status
from test_case_uart import bootrep_reply, read_reply, status_body, boot_block
from test_rung4_reads import BootCase
from test_session_guard import run_cli
from test_w18 import temple
from fake_temple import FakeClock
from wisp_w18 import case_uart as c
from wisp_w18 import cli, links, loader, relay_model, status

POLL_BOUND_S = 31.0  # the feeding relay's poll bound on hardware (recovery.md)


def boot_status_v2() -> bytes:
    b = bytearray(c.BOOT_STATUS_SIZE)
    b[:c.BOOT_STATUS_SIZE_V1 - 4] = boot_block()[:c.BOOT_STATUS_SIZE_V1 - 4]
    struct.pack_into("<HH", b, 4, 2, c.BOOT_STATUS_SIZE)
    struct.pack_into("<I", b, c.BOOT_STATUS_SIZE - 4, zlib.crc32(bytes(b[:-4])))
    return bytes(b)


def clock_block() -> bytes:
    return struct.pack(c.CLOCK_FMT, 1, 1, 1, 0, 0x103, 0x02008005, 900, 36409, 106_000_000, 900_123, 95_400_000,
                       9101, 900_123, 900_123, 0, 1)


def diag_record(boots: int) -> bytes:
    rec = bytearray(64)
    struct.pack_into("<IHHIIIHH", rec, 0, c.DIAG_MAGIC, 1, 64, boots, 0x40, 0, 0x45, 0)
    struct.pack_into("<I", rec, 60, zlib.crc32(bytes(rec[:60])))
    return bytes(rec)


class WispBootTemple(fake_status.BootingTemple):
    """The patched loader (FakeLoaderLink) for the session, then Wisp boots on the shared clock."""

    def __init__(self, mram, clock, alive=True, handoff_s=0.03, window_s=0.3, nor_s=0.4, app_init_s=0.05,
                 wdt_s=9.1, reset_to_helo_s=1.0, last_stage=0x42, **kw):
        super().__init__(mram, clock, boot_s=0.0, **kw)
        self.alive, self.handoff_s, self.window_s, self.nor_s = alive, handoff_s, window_s, nor_s
        self.app_init_s, self.wdt_s, self.reset_to_helo_s, self.last_stage = app_init_s, wdt_s, reset_to_helo_s, last_stage
        self.boots = 0
        self.log: list[tuple[float, str, str]] = []  # (time, phase, op) of every request that reached it
        self.helos_lost = 0

    # --- one boot's timeline, from its release ---
    def _begin(self, release: float) -> None:
        self.boots += 1
        self.release = release
        self.window_open = release + self.handoff_s
        self.window_end = self.window_open + self.window_s
        self.window_cap = self.window_open + 1.0

    def _app_start(self) -> float:
        return self.window_end + self.nor_s

    def _next_helo(self) -> float:
        """When this boot's watchdog reset brings the loader's HELO (only if stage-0 is dead: Wisp
        Boot's last feed is at its hand-off)."""
        return self._app_start() + self.wdt_s + self.reset_to_helo_s

    def _catch_up(self) -> None:
        """Boots that ended while no exchange was pending: their HELO went nowhere."""
        while not self.alive and self.clock() >= self._next_helo():
            self.helos_lost += 1
            self._begin(self._next_helo() + c.WispStatus.HELO_WINDOW_S)

    def _phase(self, t: float) -> str:
        if t < self.window_open:
            return "loader"
        if t < self.window_end:
            return "window"
        if t < self._app_start() + self.app_init_s:
            return "nor"
        return "app" if self.alive else "dead"

    def _answer(self, req: bytes, phase: str) -> bytes:
        op = req[7] if req[4:7] == b"WSP" else None
        if phase == "window" and op == c.OP_BOOTREP:
            t = self.clock()
            self.window_end = min(max(self.window_end, t + 0.1), self.window_cap)
            return bootrep_reply(boot=self.boots, prev_stage=self.last_stage if self.boots > 1 else 0,
                                 cause=0x40 if self.boots > 1 else 0x01, flags=0x0D if self.boots > 1 else 0x0C)
        if phase != "app" or op is None:
            return b""
        if op == c.OP_BOOTREP:
            return bootrep_reply(source=1, boot=self.boots, prev_stage=0, flags=0x0C, cause=0x01)
        if op == c.OP_IDENT:
            return c.frame(b"WSP\x81\x00" + bytes((0, 1, 0, 16, 6, 0x70)) + struct.pack("<Hh", 0, 0x7FFF) + bytes(1))
        if op == c.OP_READ:
            block, offset, _n = struct.unpack_from("<BHB", req, 8)
            data = {1: status_body(stage=6), 2: boot_status_v2(), 3: clock_block(), 4: diag_record(self.boots)}[block]
            return read_reply(block, data, offset)
        return b""

    def _app(self, frame: bytes) -> bytes:
        self._catch_up()
        if not frame:
            return b""
        self.app_frames.append(frame)
        phase = self._phase(self.clock())
        self.log.append((round(self.clock() - self.released_at, 3), phase, frame[4:8].hex()))
        return self._answer(frame, phase)

    def exchange(self, frame: bytes) -> bytes:
        reply = super().exchange(frame)
        if reply == loader.released() and self.boots == 0:
            self._begin(self.clock())  # CONT: the loader hands off at once
        return reply

    def wait_frame(self, bound_s: float) -> tuple[bytes, float]:
        """The relay waits for the temple: a dead stage-0's next HELO, if it comes within the bound."""
        self._catch_up()
        if self.alive or self.released_at is None:
            return b"", bound_s
        due = self._next_helo() - self.clock()
        if due > bound_s:
            return b"", bound_s
        self._begin(self._next_helo() + c.WispStatus.HELO_WINDOW_S)
        return loader.hello(self.challenge + self.boots), due


class TimingCase(BootCase):
    def link(self, _args=None):
        backend = WispBootTemple(self.mram, self.clock, **self.temple_kw)
        relay = relay_model.RelayModel(backend, clock=self.clock, idle_s=POLL_BOUND_S)
        self.relays.append(relay)
        made = links.RelayPortLink(relay, "left", clock=self.clock)
        self.links.append(made)
        return made


def watch(case, *extra):
    with mock.patch.object(cli, "WATCH_SLEEP", case.clock.advance):
        return run_cli(["boot-watch", "--side", "left", "--protocol", "wisp", "--interval-s", "0.1", *extra], case)


class RelayBlocks(unittest.TestCase):
    """The relay model now holds an unanswered request like case_exchange.c does."""

    def test_an_unanswered_request_costs_the_poll_bound(self):
        class Silent:
            def start(self):
                return loader.hello(0)

            def exchange(self, frame):
                return b""

        clock = FakeClock()
        relay = relay_model.RelayModel(Silent(), clock=clock, idle_s=POLL_BOUND_S)
        link = links.RelayPortLink(relay, "left", clock=clock)
        link.start()
        t0 = clock()
        code, frame, _s = link.query(c.ident_request())
        self.assertEqual((code, frame), (2, b""))
        self.assertAlmostEqual(clock() - t0, relay.exchange_s + POLL_BOUND_S)
        self.assertEqual(relay.waits, 1)

    def test_garbage_ends_the_wait_at_once(self):
        class Garbage:
            def start(self):
                return loader.hello(0)

            def exchange(self, frame):
                return b"\x00\x01\x02\x03"  # four bytes that are no frame header: relay status 2 at once

        clock = FakeClock()
        relay = relay_model.RelayModel(Garbage(), clock=clock, idle_s=POLL_BOUND_S)
        link = links.RelayPortLink(relay, "left", clock=clock)
        link.start()
        t0 = clock()
        self.assertEqual(link.query(c.ident_request())[0], 2)
        self.assertAlmostEqual(clock() - t0, relay.exchange_s)

    def test_a_frame_the_temple_sends_meanwhile_ends_the_wait(self):
        case = TimingCase(temple(), alive=False)
        link = case.link()
        link.start()
        backend = case.relays[0].temple
        backend.released_at = case.clock()
        backend._begin(case.clock())
        t0 = case.clock()
        code, frame, _s = link.query(c.ident_request())  # lands in the loader phase: nobody answers
        self.assertEqual(code, 0)
        self.assertTrue(status.is_loader_hello(frame))
        self.assertAlmostEqual(case.clock() - t0, backend.handoff_s + backend.window_s + backend.nor_s
                               + backend.wdt_s + backend.reset_to_helo_s, places=3)


class W24bReproduced(unittest.TestCase):
    def test_the_w24b_timing_gets_no_report_from_a_looping_temple(self):
        """W24b's tool: BOOTREP right after CONT/HELO (here: 0.497 s before the release, i.e. 15 ms
        after the HELO), once per boot. The relay holds it until the next HELO: zero reports, the
        six-boot loop of the hardware log."""
        case = TimingCase(temple(), alive=False)
        code, report = watch(case, "--watch-s", "60", "--report-at", "-0.497")
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertEqual(events["answers"], [])
        self.assertGreaterEqual(len(events["reboots_s"]), 4)
        backend = case.relays[0].temple
        self.assertTrue(all(phase == "loader" for _t, phase, _op in backend.log), backend.log)
        periods = [b - a for a, b in zip(events["reboots_s"], events["reboots_s"][1:])]
        self.assertTrue(all(abs(p - periods[0]) < 0.05 for p in periods), periods)


class AimedReport(unittest.TestCase):
    def test_a_looping_temple_reports_at_every_boot(self):
        case = TimingCase(temple(), alive=False, last_stage=0x42)
        code, report = watch(case, "--watch-s", "60")
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        reports = events["summary"]["boot_reports"]
        boots = 1 + len(events["reboots_s"])
        self.assertGreaterEqual(boots, 5)
        self.assertGreaterEqual(len(reports), boots - 1)  # the last boot may end the watch first
        self.assertTrue(all(r["source"] == "wisp-boot" for r in reports))
        self.assertEqual([r["boot"] for r in reports], list(range(1, len(reports) + 1)))
        for r in reports[1:]:
            self.assertEqual((r["prev_stage"], r["reset_cause_names"]), ("s0-uart", ["watchdog"]))
        backend = case.relays[0].temple
        self.assertEqual(backend.helos_lost, 0)  # every HELO came while an exchange was pending
        # Each boot: one BOOTREP in Wisp Boot's window, then IDENT after it, which blocks until the HELO.
        phases = [(phase, op) for _t, phase, op in backend.log]
        self.assertEqual(phases[0], ("window", "57535004"))
        self.assertNotIn(("loader", "57535004"), phases)
        self.assertTrue(all(p in ("window", "dead") for p, _ in phases), phases)

    def test_a_healthy_stage0_reports_then_answers_everything(self):
        case = TimingCase(temple(), alive=True)
        code, report = watch(case, "--watch-s", "60")
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertTrue(events["complete"])
        self.assertEqual(events["unanswered"], 0)
        s = events["summary"]
        self.assertEqual(s["boot_report"]["source"], "wisp-boot")
        self.assertEqual(s["ident"]["stage"], "bare-metal")
        self.assertEqual(s["clock"]["lfrc_hz"], 900.123)
        self.assertEqual(s["boot"]["version"], 2)
        self.assertLess(events["seconds"], 10)

    def test_a_late_window_is_found_on_a_later_boot_and_kept(self):
        """The window opens 0.6 s after the release (a slower hand-off than expected): the sweep
        finds it on the fourth boot and asks at that offset from then on."""
        case = TimingCase(temple(), alive=False, handoff_s=0.6)
        code, report = watch(case, "--watch-s", "80")
        self.assertEqual(code, 0, report.get("error"))
        reports = report["boot_watch"]["summary"]["boot_reports"]
        self.assertGreaterEqual(len(reports), 2)
        first = reports[0]["asked_s_after_release"]
        self.assertEqual(first, 0.75)
        self.assertTrue(all(r["asked_s_after_release"] == first for r in reports))

    def test_a_missed_window_on_a_healthy_temple_costs_one_poll_bound(self):
        """Asked during Wisp Boot's NOR scan (the window already closed): nobody answers, the relay
        holds the try for its whole poll bound, then IDENT, and stage-0's own report."""
        case = TimingCase(temple(), alive=True)
        code, report = watch(case, "--watch-s", "60", "--report-at", "0.5")
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertEqual(events["unanswered"], 1)
        self.assertGreaterEqual(events["answers"][0]["t"], POLL_BOUND_S)
        self.assertEqual(events["summary"]["boot_report"]["source"], "app")
        self.assertTrue(events["complete"])

    def test_report_at_is_checked(self):
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            cli.main(["boot-watch", "--side", "left", "--protocol", "wisp", "--report-at", "x"])


if __name__ == "__main__":
    unittest.main()
