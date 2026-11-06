# SPDX-License-Identifier: MIT
"""W18 sessions through the case relay framing (G2RQ, G2TX/G2RX, G2EX/G2RS), not a direct link.

- RelayModel (wisp_w18/relay_model.py, a port of drdaeman's case_exchange.c) behind the same
  framing code CaseRelayLink runs, with the Python loader behind it: a full `recover`, and the
  step-F failure (the case stops while it forwards a frame).
- The real pinned relay binary under Unicorn (tests/fake_case.py) behind the unmodified
  CaseRelayLink, ROM bring-up included: the same session, and the same failure. The two must
  put the same bytes on the host link.
"""

import hashlib
import sys
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_temple import FakeLoaderLink
from test_w18 import FAKE_PATCHED, SmallStock, fake_stock, temple
from wisp_case import pins as case_pins
from wisp_w18 import cli, image, links, loader, relay_model, session

try:
    import fake_case as fc
except ImportError:  # unicorn missing
    fc = None

# What CaseRelayLink logged as `relay_record` after both step-F runs on 2026-11-06 (left temple).
STEP_F_RECORD = bytes.fromhex(
    "474252470100000002000000000000001f00000000000000ff030000ff030000000000000f0000002000000000000000"
    "0000000000000000811104afaf03812033ff81100ca6af03c10333ff000000000000000000005aa5ff1b000103175245"
    "535005100000000000000000000000000000000000830000000000000000000000000000000000000000000000000000"
    "00000000000000000000000000000000")


def first_input_data(frame: bytes) -> bool:
    return len(frame) == 32 and frame[4:8] == b"RQST" and frame[8] == loader.INPUT_DATA


def quiet(_message):
    pass


class RecordDecoding(unittest.TestCase):
    def test_step_f_record(self):
        d = links.decode_relay_record(STEP_F_RECORD)
        self.assertTrue(d["magic_ok"])
        self.assertEqual(d["phase"], 1)  # the bridge's exit path never ran
        self.assertNotIn("exit_status", d)
        self.assertEqual((d["operation"], d["route"], d["sequence"]), (2, 0, 31))
        self.assertEqual(d["yhm_reads_ok"], {"before": "0x3ff", "selected": "0x3ff", "restored": "0x000"})
        self.assertEqual(d["yhm_writes_ok"], "0x00f")  # route selected, restore never started
        self.assertEqual(d["last_temple_send"], 32)  # a RQST, not the cleanup's 9-byte CONT
        self.assertEqual(d["last_temple_frame_meaning"], "RESP INPUT status 16")
        self.assertEqual(d["uart_error_flags"], 0)

    def test_exit_status_6_is_the_normal_end(self):
        self.assertEqual(links.RELAY_EXIT_OK, 6)
        self.assertIn("normal", links.RELAY_EXIT_STATUS[6])


class ThroughRelayModel(unittest.TestCase):
    def session(self, mram, **model):
        backend = FakeLoaderLink(mram)
        relay = relay_model.RelayModel(backend, **model)
        link = links.RelayPortLink(relay, "left")
        return session.Session(link, log=quiet), link, relay, backend

    def test_recover_end_to_end(self):
        stock = fake_stock(6000)
        mram = temple(b"\0" * 6016)
        s, link, relay, backend = self.session(mram)
        with SmallStock(stock), s:
            s.require_patched_bootloader(FAKE_PATCHED)
            result = s.write_app(stock)
        self.assertEqual(mram.read(0x438000, len(stock)), stock)
        self.assertEqual(result["crc_after"], f"{zlib.crc32(mram.read(0x438000, 6000)):08x}")  # 6000 = 16-aligned
        self.assertEqual(relay.state, "reset")  # G2EX -> G2RS, exit status 6
        self.assertIn({"relay_exit_status": 6, "relay_exit_meaning": links.RELAY_EXIT_STATUS[6]}, link.events)
        self.assertFalse(backend.held)  # CONT -> RLSD before G2EX
        d = links.decode_relay_record(bytes(relay.record))
        self.assertEqual((d["phase"], d["exit_status"], d["yhm_writes_ok"]), (2, 6, "0x1ff"))
        self.assertGreater(link.recent.count, 6000 // 16)

    def test_case_hang_keeps_the_original_error(self):
        mram = temple(b"\0" * 6016)
        s, link, relay, backend = self.session(mram, hang_when=first_input_data)
        with SmallStock(fake_stock(6000)), self.assertRaises(Exception) as caught:
            with s:
                s.require_patched_bootloader(FAKE_PATCHED)
                s.write_app(fake_stock(6000))
        error = caught.exception
        # The error that stopped the session is the missing reply to INPUT_DATA ...
        self.assertIn("timeout reading relay response", repr(error))
        self.assertEqual(s.step, "write the app body (vectors not yet written)")
        self.assertEqual(s.position["sent"], 16)
        self.assertEqual(s.position["verified"], 0)
        # ... and the cleanup failures (CONT unanswered, G2EX unanswered) are attached, not instead.
        self.assertEqual(len(s.cleanup_errors), 2, s.cleanup_errors)
        self.assertIn("relay response", s.cleanup_errors[0])
        self.assertIn("restoration header", s.cleanup_errors[1])
        self.assertEqual(len(error.__notes__), 2)
        last = link.diagnostics()["recent"][-2]
        self.assertTrue(first_input_data(bytes.fromhex(last["sent"])))
        self.assertIsNone(last["received"])
        self.assertIn("timeout", last["error"])
        self.assertEqual(bytes.fromhex(link.diagnostics()["recent"][-1]["sent"]), loader.cont())
        self.assertEqual(mram.writes, [])  # nothing programmed: the first 256-byte block never filled
        # The case's retained record is the one the hardware left behind, byte for byte.
        self.assertEqual(bytes(relay.record), STEP_F_RECORD)

    def test_cleanup_failure_alone_still_raises(self):
        mram = temple()
        s, link, relay, _ = self.session(mram)
        with self.assertRaises(session.SessionError):
            with s:
                s.require_patched_bootloader(FAKE_PATCHED)
                relay.state = "hung"  # the case dies after the work; CONT goes unanswered
        self.assertEqual(len(s.cleanup_errors), 2)


class Cli(unittest.TestCase):
    """w18.py commands on a relay-model link: what a stopped session puts in its report."""

    def run_cli(self, argv, mram, **model):
        reports = []
        link = links.RelayPortLink(relay_model.RelayModel(FakeLoaderLink(mram), **model), "left")
        with mock.patch.object(cli, "make_link", lambda args: link), \
                mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED), \
                mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)), \
                mock.patch("sys.stdout"), mock.patch("sys.stderr"):
            code = cli.main(argv)
        return code, reports[0]

    def test_link_soak_streams_and_checks_the_crc(self):
        app = bytes((i * 31 + 7) & 255 for i in range(8192))
        code, report = self.run_cli(["link-soak", "--side", "left", "--bytes", "8192"], temple(app))
        self.assertEqual(code, 0, report)
        self.assertEqual(report["crc32"], f"{zlib.crc32(app):08x}")
        self.assertGreater(report["exchanges"], 8192 // 16)

    def test_link_soak_never_writes(self):
        mram = temple(b"\0" * 4096)
        self.run_cli(["link-soak", "--side", "left", "--bytes", "4096"], mram)
        self.assertEqual(mram.writes, [])

    def test_link_soak_refuses_a_range_outside_the_app_region(self):
        for value in ("0", "15", str(pins_size() + 16)):
            with mock.patch("sys.stderr"):
                self.assertEqual(cli.main(["link-soak", "--side", "left", "--bytes", value]), 2)

    def test_recover_report_after_a_case_hang(self):
        import tempfile

        stock = fake_stock(6000)
        with tempfile.TemporaryDirectory() as tmp, SmallStock(stock):
            raw = Path(tmp) / "stock.bin"
            raw.write_bytes(stock)
            code, report = self.run_cli(["recover", "--side", "left", "--image", str(raw)],
                                        temple(b"\0" * 6000), hang_when=first_input_data)
        self.assertEqual(code, 1)
        self.assertIn("timeout reading relay response", report["error"])
        self.assertNotIn("restoration header", report["error"])  # the cleanup error no longer masks it
        self.assertEqual(report["stopped_in"], "write the app body (vectors not yet written)")
        self.assertEqual(report["position"]["sent"], 16)
        self.assertEqual(len(report["cleanup_errors"]), 2)
        recent = report["link"]["recent"]
        self.assertTrue(first_input_data(bytes.fromhex(recent[-2]["sent"])))
        self.assertIn("timeout", recent[-2]["error"])
        self.assertEqual(loader.decode_reply(bytes.fromhex(recent[-3]["received"]))[:2], (loader.INPUT, 16))


def pins_size():
    from wisp_w18 import pins

    return pins.RECOVER_END - pins.RECOVER_BASE


@unittest.skipUnless(fc, "install unicorn to run the relay under emulation")
class ThroughRealRelayBinary(unittest.TestCase):
    """drdaeman's pinned case.bin (the template; Even's waveform is a hook) under Unicorn,
    behind the unmodified CaseRelayLink: ROM bring-up, G2RQ, every frame, G2EX, record check."""

    def run_session(self, mram, body, hang_when=None):
        case = fc.FakeCase(case_pins.CASE_IMAGE_LENGTH, yhm=fc.IDLE_YHM)
        case.run_timeout_us = 300_000_000
        backend = FakeLoaderLink(mram)
        case.temples = {"left": fc.LinkTemple(backend), "right": fc.LinkTemple(FakeLoaderLink(temple()))}
        case.hang_when = hang_when
        relay = (image.DATA / "case_relay_template.bin").read_bytes()  # reviewed-22, waveform zeroed
        sha = hashlib.sha256(case.flash[: case_pins.CASE_IMAGE_LENGTH]).hexdigest()
        with mock.patch.object(case_pins, "CASE_IMAGE_SHA256", sha), \
                mock.patch.object(image, "build_relay", lambda profile, cache=None: relay), \
                mock.patch("wisp_w18.pins.CASE_PRE_CHECKS", ()):
            link = links.CaseRelayLink("/dev/fake", "left", "reviewed-22", opener=fc.opener_for(case),
                                       sleep=lambda s: None)
            s = session.Session(link, log=quiet)
            error = None
            try:
                with s:
                    s.require_patched_bootloader(FAKE_PATCHED)
                    body(s)
            except Exception as caught:  # noqa: BLE001
                error = caught
        return case, link, s, error

    def assert_case_clean(self, case):
        self.assertEqual(case.mode, "normal")  # back in its own app (banner seen)
        for base, length in ((case_pins.BRIDGE_ADDRESS, 5508), (case_pins.RESULT_ADDRESS, case_pins.RESULT_LENGTH)):
            self.assertEqual(bytes(case.uc.mem_read(base, length)), bytes(length), hex(base))
        self.assertTrue(all(entry[1] in case_pins.ROM_COMMAND_ALLOWLIST for entry in case.rom_log if entry[0] == "cmd"))

    def test_recover_through_the_real_relay(self):
        stock = fake_stock(3000)
        mram = temple(b"\0" * 3008)
        with SmallStock(stock):
            case, link, s, error = self.run_session(mram, lambda s: s.write_app(stock))
        self.assertIsNone(error, error and getattr(error, "__notes__", None))
        self.assertEqual(mram.read(0x438000, len(stock)), stock)
        events = {k: v for e in link.events for k, v in e.items()}
        self.assertTrue(events["route_restored"])
        self.assertEqual(events["relay_exit_status"], 6)
        self.assertEqual(events["relay_record_decoded"]["phase"], 2)
        self.assert_case_clean(case)

        # The Python relay model puts the same frames on the host link.
        mram2 = temple(b"\0" * 3008)
        model_link = links.RelayPortLink(relay_model.RelayModel(FakeLoaderLink(mram2)), "left")
        with SmallStock(stock), session.Session(model_link, log=quiet) as s2:
            s2.require_patched_bootloader(FAKE_PATCHED)
            s2.write_app(stock)
        strip = lambda r: [(e["sent"], e["received"]) for e in r["recent"]]  # noqa: E731
        self.assertEqual(link.recent.count, model_link.recent.count)
        self.assertEqual(strip(link.diagnostics()), strip(model_link.diagnostics()))

    def test_case_hang_signature(self):
        stock = fake_stock(3000)
        mram = temple(b"\0" * 3008)
        with SmallStock(stock):
            case, link, s, error = self.run_session(mram, lambda s: s.write_app(stock), hang_when=first_input_data)
        self.assertTrue(case.hung)
        self.assertIn("timeout reading relay response", repr(error))  # the original error survives
        self.assertTrue(any("restoration header" in c for c in s.cleanup_errors), s.cleanup_errors)
        record = next(e["relay_record_decoded"] for e in link.events if "relay_record_decoded" in e)
        hardware = links.decode_relay_record(STEP_F_RECORD)
        for key in ("phase", "operation", "route", "sequence", "yhm_reads_ok", "yhm_writes_ok",
                    "last_temple_send", "last_temple_frame", "uart_error_flags"):
            self.assertEqual(record[key], hardware[key], key)
        self.assert_case_clean(case)  # the cleanup still zeroes the SRAM and boots the case app
        self.assertEqual(mram.writes, [])


if __name__ == "__main__":
    unittest.main()
