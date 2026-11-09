# SPDX-License-Identifier: MIT
"""`boot-watch --protocol wisp` (wisp_w18/case_uart.py, rung4.md G10) against the firmware's
golden vectors (docs/wisp/case-uart.md; apps/wisp-fw/tests/case/), against the reference host
module apps/wisp-fw/tests/boot/case_uart.py, and end to end through the relay model with a fake
native-0 app that answers the protocol. No hardware."""

import importlib.util
import struct
import sys
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import fake_status
from test_rung4_reads import BootCase
from test_session_guard import run_cli
from test_w18 import temple
from wisp_w18 import case_uart as c
from wisp_w18 import cli, status

REFERENCE = Path(__file__).resolve().parents[3] / "apps/wisp-fw/tests/boot/case_uart.py"


def reference():
    spec = importlib.util.spec_from_file_location("wisp_fw_case_uart", REFERENCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# docs/wisp/case-uart.md "Examples", the golden vectors of apps/wisp-fw/tests/case/.
IDENT = "7e0001045753500104"
READ_STATUS_0 = "7e000114575350020100001100000000000000000000000037"
READ_BOOT_595 = "7e00011457535002025302110000000000000000000000008d"
RESET = "7e000114575350035253455400000000000000000000000064"
RESET_REPLY = "5aa5ff08575350830000000083"
IDENT_REPLY = "5aa5ff10575350810000010200053b930ffbff0068"  # 0.1.2, kind 0, stage 5, 3,987 mV, bt -5
VERSION_WISP = "5aa5ff0924575350000102000028"
VERSION_STOCK = "5aa5ff0924010305020400180557"  # step 0, left temple, 2.4.0.24


def status_body(stage=4, rev=b"8374f9a\0\0\0\0\0") -> bytes:
    return bytes([1, stage]) + struct.pack("<h", 0) + bytes([0x13, 0x7B]) + struct.pack("<H", 4012) + \
        bytes([0x02, 0x0C, 0, 0]) + struct.pack("<IIIIIIHhHH", 0x0001_0000, 61_234, 61, 0, 480, 0, 0, 0x7FFF, 612, 0) + rev


def boot_block(staging=c.STOCK_STAGING_CRC_WORD) -> bytes:
    b = bytearray(c.BOOT_STATUS_SIZE_V1)  # native-0's Wisp Boot: version 1
    struct.pack_into("<IHHIIiii", b, 0, 0x54534257, 1, 612, 1, 0x3925C2, 0, 0, -2)
    b[44:52] = bytes([6, 1, 0, 0, 0, 1, 2, 0])
    struct.pack_into("<IIIIi", b, 52, staging, 3_700_100, 0, 0, 0)
    for i, (name, size, crc) in enumerate((("touch.bin", 34_720, 0xBEA43830), ("box.bin", 51_200, 0x01020304))):
        o = 72 + 44 * i
        b[o:o + len(name)] = name.encode()
        struct.pack_into("<IIi", b, o + 32, size, crc, 0)
    struct.pack_into("<I", b, 608, zlib.crc32(bytes(b[:608])))
    return bytes(b)


class Vectors(unittest.TestCase):
    def test_requests(self):
        self.assertEqual(c.ident_request().hex(), IDENT)
        self.assertEqual(c.read_request(1, 0).hex(), READ_STATUS_0)
        self.assertEqual(c.read_request(2, 595).hex(), READ_BOOT_595)
        self.assertEqual(c.reset_request().hex(), RESET)
        for f in (c.ident_request(), c.read_request(2, 0), c.reset_request()):
            self.assertTrue(status.relay_request_ok(f), f.hex())
        self.assertFalse(status.relay_request_ok(c.STOCK_VERSION_QUERY))

    def test_replies(self):
        self.assertEqual(c.decode_reply(bytes.fromhex(RESET_REPLY), c.OP_RESET)[0], 0)
        self.assertTrue(status.relay_reply_ok(bytes.fromhex(RESET_REPLY)))
        st, data = c.decode_reply(bytes.fromhex(IDENT_REPLY), c.OP_IDENT)
        i = c.decode_ident(data)
        self.assertEqual((st, i["version"], i["stage"], i["battery_mv"], i["bt_result"]),
                         (0, (0, 1, 2), "bt-failed", 3987, -5))
        self.assertTrue(status.relay_reply_ok(bytes.fromhex(IDENT_REPLY)))
        with self.assertRaises(ValueError):
            c.decode_reply(bytes.fromhex(RESET_REPLY[:-2] + "84"), c.OP_RESET)
        with self.assertRaises(ValueError):
            c.decode_reply(bytes.fromhex(RESET_REPLY), c.OP_IDENT)

    def test_version(self):
        self.assertTrue(c.decode_version(bytes.fromhex(VERSION_WISP))["wisp"])
        stock = c.decode_version(bytes.fromhex(VERSION_STOCK))
        self.assertFalse(stock["wisp"])
        self.assertEqual(stock["firmware"], "2.4.0.24")

    def test_the_port_matches_the_firmware_reference(self):
        """Same bytes in, same results out, for every function both have."""
        ref = reference()
        for block in (1, 2):
            for offset in (0, 17, 51, 595):
                self.assertEqual(c.read_request(block, offset), ref.read_request(block, offset))
        self.assertEqual((c.ident_request(), c.reset_request()), (ref.ident_request(), ref.reset_request()))
        for f in (VERSION_WISP, VERSION_STOCK):
            self.assertEqual(c.decode_version(bytes.fromhex(f)), ref.decode_version(bytes.fromhex(f)))
        for f, op in ((IDENT_REPLY, c.OP_IDENT), (RESET_REPLY, c.OP_RESET)):
            self.assertEqual(c.decode_reply(bytes.fromhex(f), op), ref.decode_reply(bytes.fromhex(f), op))
        self.assertEqual(c.decode_ident(c.decode_reply(bytes.fromhex(IDENT_REPLY), 1)[1]),
                         ref.decode_ident(ref.decode_reply(bytes.fromhex(IDENT_REPLY), 1)[1]))
        self.assertEqual(c.decode_status(status_body()), ref.decode_status(status_body()))
        self.assertEqual(c.decode_boot_status(boot_block()), ref.decode_boot_status(boot_block()))
        self.assertEqual((c.STATUS_FMT, c.BOOT_STATUS_SIZE, c.STAGES, c.FLAGS, c.ACTIONS),
                         (ref.STATUS_FMT, ref.BOOT_STATUS_SIZE, ref.STAGES, ref.FLAGS, ref.ACTIONS))

    def test_a_corrupt_boot_block_is_refused(self):
        b = bytearray(boot_block())
        b[100] ^= 1
        with self.assertRaises(ValueError):
            c.decode_boot_status(bytes(b))


def bootrep_reply(source=0, flags=0x0D, boot=2, prev_stage=0x45, cause=0x08, ms=4592, fault=None) -> bytes:
    pc, lr, cfsr = fault or (0, 0, 0)
    return c.frame(b"WSP\x84\x00" + struct.pack("<BBBBIHIII", source, flags | (2 if fault else 0), boot, prev_stage,
                                              cause, ms, pc, lr, cfsr))


def read_reply(block: int, data: bytes, offset: int) -> bytes:
    chunk = data[offset:offset + 17]
    payload = b"WSP\x82\x00" + struct.pack("<BHH", block, offset, len(data)) + chunk
    return c.frame(payload + bytes((27 if len(payload) > 24 else 24) - len(payload)))


class Stage0Hook(unittest.TestCase):
    """boot-watch's wisp protocol against stage-0 (rung4.md W24b): the boot report at every boot,
    then IDENT and four blocks."""

    def answer(self, req: bytes, blocks: dict, report: bytes | None) -> bytes:
        op = req[7]
        if op == c.OP_BOOTREP:
            return report or b""
        if op == c.OP_IDENT:
            return c.frame(b"WSP\x81\x00" + bytes((0, 1, 0, 16, 6, 0x70)) + struct.pack("<Hh", 0, 0x7FFF) + bytes(1))
        block, offset, _n = struct.unpack_from("<BHB", req, 8)
        return read_reply(block, blocks[block], offset)

    def test_boot_reports_across_reboots_and_stage0_blocks(self):
        clock = struct.pack(c.CLOCK_FMT, 1, 1, 1, 0, 0x103, 0x02008005, 900, 36409, 106_000_000, 900_123,
                            95_400_000, 9101, 900_123, 900_123, 0, 1)
        rec = bytearray(64)
        struct.pack_into("<IHHIIIHH", rec, 0, c.DIAG_MAGIC, 1, 64, 2, 8, 0, 0x45, 0)
        struct.pack_into("<I", rec, 60, zlib.crc32(bytes(rec[:60])))
        blocks = {1: status_body(stage=6), 2: boot_block(), 3: clock, 4: bytes(rec)}
        hook = c.WispStatus()
        answers = []
        # Wisp Boot's window answers the one BOOTREP; then IDENT and every block.
        replies = [bootrep_reply()]
        for i in range(200):
            req = hook.request(i)
            self.assertTrue(status.relay_request_ok(req), req.hex())
            reply = replies.pop(0) if replies else self.answer(req, blocks, None)
            if i == 0:
                self.assertEqual(req, c.bootrep_request())
            d = hook.decode(reply) if reply else None
            if d:
                answers.append(d)
            if hook.complete(answers):
                break
        self.assertTrue(hook.complete(answers))
        s = hook.summary(answers)
        self.assertEqual(s["boot_report"]["source"], "wisp-boot")
        self.assertEqual(s["boot_report"]["prev_stage"], "s0-loop")
        self.assertEqual(s["clock"]["lfrc_hz"], 900.123)
        self.assertEqual(s["clock"]["wdt_period_ms"], 9101)
        self.assertEqual(s["clock"]["wdt_count_direction"], "down")
        self.assertEqual(s["diag"]["boots"], 2)
        # A reboot (the loader's HELO): the boot report again, first; both reports are kept.
        hook.reset()
        hook.reboots += 1
        self.assertEqual(hook.request(0), c.bootrep_request())
        hook.decode(bootrep_reply(boot=3, cause=0x40, prev_stage=0x46, fault=(0x448123, 0x448001, 0x20000)))
        self.assertFalse(hook.report_due())
        self.assertEqual([r["boot"] for r in hook.reports], [2, 3])
        self.assertEqual(hook.reports[1]["reset_cause_names"], ["watchdog"])
        self.assertEqual(hook.reports[1]["prev_fault"]["pc"], 0x448123)
        with mock.patch("builtins.print") as out:
            cli.print_summary(hook.summary())
        text = "\n".join(str(call.args[0]) for call in out.call_args_list)
        self.assertIn("boot report", text)
        self.assertIn("FAULT pc 0x00448123", text)

    def test_the_report_is_asked_once_per_boot_at_its_scheduled_time(self):
        """One BOOTREP per boot, timed from the release (CONT: t = 0; a HELO: + 512 ms), cycling
        through report_at until Wisp Boot answers; IDENT waits APP_AFTER_REPORT_S after the report."""
        hook = c.WispStatus()
        self.assertAlmostEqual(hook.wait(0.0), c.WispStatus.REPORT_AT_S[0])
        self.assertEqual(hook.request(0), c.bootrep_request())
        self.assertIsNone(hook.wait(0.2))  # missed (status 2 after the poll bound): IDENT at the interval
        self.assertEqual(hook.request(1), c.ident_request())
        hook.reset()
        hook.anchor(10.0, "helo")
        self.assertAlmostEqual(hook.wait(10.0), 0.512 + c.WispStatus.REPORT_AT_S[1])
        hook.request(2)
        hook.decode(bootrep_reply())
        self.assertAlmostEqual(hook.wait(10.9), hook.report_answered_at + c.WispStatus.APP_AFTER_REPORT_S - 10.9)
        hook.reset()
        hook.anchor(20.0, "helo")
        self.assertAlmostEqual(hook.wait(20.0), 0.512 + c.WispStatus.REPORT_AT_S[1])  # kept once it worked
        custom = c.WispStatus(report_at=(0.4,))
        self.assertAlmostEqual(custom.wait(0.0), 0.4)


class WispApp:
    """native-0's case-UART answers (src/case/wisp_case_proto.c), enough for boot-watch: IDENT,
    READ of both blocks, every request in the relay's shapes. `drop` = request numbers that get
    no answer (a lost exchange), `bt_s` = when the BLE bring-up finishes."""

    def __init__(self, drop=(), bt_s=0.0, boot=None, status=None):
        self.drop, self.bt_s = set(drop), bt_s
        self.blocks = {1: status or status_body(), 2: boot}
        self.count = 0
        self.requests: list[bytes] = []

    def answer(self, req: bytes, since: float) -> bytes:
        self.requests.append(req)
        self.count += 1
        if self.count in self.drop or req[4:7] != b"WSP":
            return b""
        op = req[7]
        stage = 4 if since >= self.bt_s else 3
        if op == c.OP_IDENT:
            return c.frame(b"WSP\x81\x00" + bytes((0, 1, 2, 0, stage, 0x7B)) + struct.pack("<Hh", 4012, 0)
                           + bytes(1))  # padded to L = 16
        if op == c.OP_READ:
            block, offset, n = struct.unpack_from("<BHB", req, 8)
            data = self.blocks.get(block)
            if data is None:
                return c.frame(b"WSP\x82\x03" + bytes(3))
            if block == 1:
                data = data[:1] + bytes([stage]) + data[2:]
            chunk = data[offset:offset + min(n, 17)]
            payload = b"WSP\x82\x00" + struct.pack("<BHH", block, offset, len(data)) + chunk
            return c.frame(payload + bytes((27 if len(payload) > 24 else 24) - len(payload)))
        return c.frame(b"WSP" + bytes((op | 0x80, 1)) + bytes(3))


class WispTemple(fake_status.BootingTemple):
    def __init__(self, mram, clock, app: WispApp, **kw):
        super().__init__(mram, clock, **kw)
        self.app = app

    def _app(self, frame: bytes) -> bytes:
        if frame:
            self.app_frames.append(frame)
        if self._since() < self.boot_s or not frame:
            return b""
        return self.app.answer(frame, self._since())


class WispCase(BootCase):
    def __init__(self, mram, app, **kw):
        super().__init__(mram, **kw)
        self.app = app

    def link(self, _args=None):
        from wisp_w18 import links, relay_model
        backend = WispTemple(self.mram, self.clock, self.app, **self.temple_kw)
        relay = relay_model.RelayModel(backend, clock=self.clock, idle_s=2.0)
        self.relays.append(relay)
        made = links.RelayPortLink(relay, "left", clock=self.clock)
        self.links.append(made)
        return made


def watch(case, *extra):
    with mock.patch.object(cli, "WATCH_SLEEP", case.clock.advance):
        return run_cli(["boot-watch", "--side", "left", "--protocol", "wisp", "--interval-s", "0.1", *extra], case)


class BootWatchWisp(unittest.TestCase):
    def test_reads_both_blocks_and_waits_for_the_ble_bring_up(self):
        app = WispApp(bt_s=8.0, boot=boot_block())
        case = WispCase(temple(), app, boot_s=2.0)
        code, report = watch(case, "--watch-s", "60")
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertTrue(events["complete"])
        self.assertGreaterEqual(events["seconds"], 6.0)  # not before the app reported bt-up
        summary = events["summary"]
        self.assertEqual(summary["ident"]["stage"], "bt-up")
        self.assertEqual(summary["status"]["rev"], "8374f9a")
        self.assertEqual(summary["status"]["battery_mv"], 4012)
        self.assertTrue(summary["boot"]["observe"])
        self.assertEqual(summary["boot"]["action"], "run-app")
        self.assertTrue(summary["staging_is_stock_2_4_0_24"])
        self.assertEqual(sorted(summary["inventory"]), ["box.bin", "touch.bin"])
        self.assertEqual(summary["inventory"]["touch.bin"]["crc32"], "bea43830")
        # Only Wisp requests in the relay's shapes reached the app; never RESET.
        for f in app.requests:
            self.assertTrue(status.relay_request_ok(f), f.hex())
            self.assertNotEqual(f[7], c.OP_RESET)
        self.assertEqual(case.mram.writes, [])

    def test_lost_answers_are_asked_again(self):
        app = WispApp(drop={3, 4, 9, 20, 21, 22, 40}, boot=boot_block())
        case = WispCase(temple(), app, boot_s=1.0)
        code, report = watch(case, "--watch-s", "60")
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertTrue(events["complete"])
        self.assertGreaterEqual(events["unanswered"], 7)
        self.assertEqual(events["summary"]["boot"]["staging_id"], c.STOCK_STAGING_CRC_WORD)

    def test_no_wisp_boot_block_ends_with_the_app_status(self):
        app = WispApp(boot=None)
        case = WispCase(temple(), app, boot_s=1.0)
        code, report = watch(case, "--watch-s", "30")
        self.assertEqual(code, 0, report.get("error"))
        summary = report["boot_watch"]["summary"]
        self.assertTrue(report["boot_watch"]["complete"])
        self.assertIn("not available", summary["boot_error"])
        self.assertIn("status", summary)

    def test_a_corrupt_boot_block_is_reported_not_trusted(self):
        bad = bytearray(boot_block())
        bad[300] ^= 0xFF
        case = WispCase(temple(), WispApp(boot=bytes(bad)), boot_s=1.0)
        code, report = watch(case, "--watch-s", "30")
        self.assertEqual(code, 0, report.get("error"))
        summary = report["boot_watch"]["summary"]
        self.assertIn("CRC", summary["boot_error"])
        self.assertNotIn("boot", summary)

    def test_a_stock_temple_answers_nothing(self):
        """Wisp requests to a temple that runs stock (or an app that never comes up): no answer,
        no complete, nothing written."""
        case = WispCase(temple(), WispApp(), boot_s=1e9)
        code, report = watch(case, "--watch-s", "10")
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertFalse(events.get("complete"))
        self.assertEqual(events["answers"], [])
        self.assertIsNone(events["summary"]["ident"])

    def test_the_app_status_is_read_again_after_the_bring_up(self):
        app = WispApp(bt_s=8.0, boot=boot_block())
        case = WispCase(temple(), app, boot_s=2.0)
        code, report = watch(case, "--watch-s", "60")
        self.assertEqual(code, 0, report.get("error"))
        summary = report["boot_watch"]["summary"]
        self.assertEqual(summary["status_early"]["stage"], "bt-start")
        self.assertEqual(summary["status"]["stage"], "bt-up")

    def test_a_short_reply_is_reported_not_fatal(self):
        hook = c.WispStatus()
        out = hook.decode(c.frame(b"WSP\x81\x00" + bytes(3)))  # 13 bytes: too short for IDENT's fields
        self.assertIn("error", out)
        self.assertIsNone(hook.ident)

    def test_a_reboot_mid_watch_starts_the_reads_again(self):
        hook = c.WispStatus()
        hook.decode(bytes.fromhex(IDENT_REPLY))
        hook.parts[c.BLOCK_STATUS][0] = bytes(17)
        hook.reset()
        self.assertIsNone(hook.ident)
        self.assertEqual(hook.parts[c.BLOCK_STATUS], {})
        self.assertEqual(hook.request(0), c.bootrep_request())  # every boot: the boot report first
        hook.decode(c.frame(b"WSP\x84\x01" + bytes(3)))  # native-0: unknown op
        self.assertEqual(hook.request(1), c.ident_request())

    def test_registered(self):
        self.assertIs(status.PROTOCOLS["wisp"], c.WispStatus)
        self.assertTrue(status.relay_request_ok(c.WispStatus().request(0)))


if __name__ == "__main__":
    unittest.main()
