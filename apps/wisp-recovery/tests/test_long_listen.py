# SPDX-License-Identifier: MIT
"""`loader-hello --long-listen`: the relay whose HELO wait is 20x longer, and the host that waits for it.

The case relay gives up on a silent temple about 29 s after its reset (observed-33-feed). A temple
whose bootloader takes minutes to come up (drdaeman, g2-bootloader-patch issue 1: a NOR reformat
delays the HELO) was therefore never heard. The listen profile changes one literal of the pinned
relay and nothing else; the host reads the beacon with a matching timeout."""

import struct
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_session_guard import Case, run_cli
from test_w18 import temple
from wisp_case.rom import RomError
from wisp_w18 import cli, image, links, pins

BASE = "observed-33-feed"
LISTEN = pins.LISTEN_PROFILE


def relays():
    try:
        return image.build_relay(BASE), image.build_relay(LISTEN)
    except (OSError, image.ImageError) as error:  # no cached case firmware: the pins cannot be rebuilt
        raise unittest.SkipTest(f"case firmware not cached: {error}")


class Profile(unittest.TestCase):
    def test_one_literal_differs(self):
        base, listen = relays()
        diff = [i for i in range(len(base)) if base[i] != listen[i]]
        at = pins.RELAY_POLL_LITERAL - pins.RELAY_ADDRESS
        self.assertEqual(diff, [at + 1, at + 2, at + 3])  # 0x03D09000 -> 0x4C4B4000: byte 0 stays 0x00
        self.assertEqual(struct.unpack_from("<I", base, at)[0], 64_000_000)
        self.assertEqual(struct.unpack_from("<I", listen, at)[0], 64_000_000 * 20)
        self.assertEqual(len(base), len(listen))

    def test_only_the_two_wait_loops_read_the_literal(self):
        # recovery.md: the HELO wait (ldr at 0x20010744) and the temple-frame wait (0x200108AE)
        # load it pc-relative; the same count appears once more, at 0x200109D8, a separate literal.
        base, _ = relays()
        found = [0x2001_0000 + i for i in range(0, len(base) - 3, 4) if struct.unpack_from("<I", base, i)[0] == 64_000_000]
        self.assertEqual(found, [0x2001_0994, 0x2001_09D8])

    def test_pinned_and_selectable(self):
        self.assertIn(LISTEN, pins.RELAY_SHA256)
        self.assertTrue(LISTEN.startswith(BASE))

    def test_unknown_base_is_refused(self):
        with self.assertRaises(image.ImageError):
            image.build_relay("nope" + pins.RELAY_LISTEN_SUFFIX)

    def test_a_changed_pin_is_refused(self):
        relays()
        with mock.patch.dict(pins.RELAY_SHA256, {LISTEN: "0" * 64}), self.assertRaises(image.ImageError):
            image.build_relay(LISTEN)


class FakePort:
    """The USB serial port of a relay that arms, then sends the HELO `helo_after_s` later: the port
    only checks that the host's timeout covers that."""

    def __init__(self, helo_after_s):
        self.helo_after_s, self.timeout = helo_after_s, 6.0
        self.stream = [(pins.RELAY_BANNER, 0.0), (b"\0" * 16, 0.0), (b"G2U2_ARMED\n", 0.0),
                       (b"\x5a\xa5\xff\x10" + b"\0" * 17, helo_after_s), (b"G2RAM_READY\n", 0.0)]
        self.buffer, self.timeouts = b"", []

    def read(self, n):
        if not self.buffer:
            data, delay = self.stream.pop(0)
            self.timeouts.append(self.timeout)
            if delay > self.timeout:
                return b""
            self.buffer = data
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def write(self, data):
        pass

    def flush(self):
        pass


class Framing(unittest.TestCase):
    def arm(self, late_s, listen):
        class Probe(links._RelayFraming):
            sleep = staticmethod(lambda s: None)
            log = lambda self, event: None  # noqa: E731

        probe = Probe()
        probe._init_recent()
        probe.port = FakePort(late_s)
        if listen:
            probe.BEACON_TIMEOUT = pins.LISTEN_BEACON_TIMEOUT_S
        return probe, probe._arm()

    def test_default_host_gives_up_on_a_late_helo(self):
        with self.assertRaises(RomError):
            self.arm(300.0, listen=False)

    def test_listen_host_hears_a_helo_four_minutes_late(self):
        probe, beacon = self.arm(240.0, listen=True)
        self.assertEqual(len(beacon), 21)
        self.assertEqual(probe.port.timeouts[3], pins.LISTEN_BEACON_TIMEOUT_S)  # the beacon read
        self.assertEqual(probe.port.timeout, 60.0)  # and back to normal after it

    def test_listen_host_still_gives_up_after_its_bound(self):
        with self.assertRaises(RomError):
            self.arm(pins.LISTEN_BEACON_TIMEOUT_S + 1, listen=True)

    def test_relay_bound_is_inside_the_host_bound(self):
        # ~29 s with the feed, x20: the host must outwait the relay's own give-up
        self.assertGreater(pins.LISTEN_BEACON_TIMEOUT_S, 29 * pins.RELAY_LISTEN_FACTOR)


class Cli(unittest.TestCase):
    def test_long_listen_selects_the_listen_relay_and_reports_the_wait(self):
        case = Case(temple())
        seen = {}
        original = case.link

        def link(args):
            seen["profile"] = args.case_profile
            return original(args)

        case.link = link
        code, report = run_cli(["loader-hello", "--side", "left", "--long-listen"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(seen["profile"], LISTEN)
        self.assertIn("helo_after_relay_s", report)

    def test_plain_loader_hello_keeps_the_default_relay(self):
        case = Case(temple())
        seen = {}
        original = case.link

        def link(args):
            seen["profile"] = args.case_profile
            return original(args)

        case.link = link
        code, report = run_cli(["loader-hello", "--side", "left"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(seen["profile"], pins.DEFAULT_CASE_PROFILE)
        self.assertNotIn("helo_after_relay_s", report)

    def test_the_read_only_command_writes_nothing(self):
        mram = temple()
        code, _report = run_cli(["loader-hello", "--side", "left", "--long-listen"], Case(mram))
        self.assertEqual(code, 0)
        self.assertEqual(mram.writes, [])


if __name__ == "__main__":
    unittest.main()
