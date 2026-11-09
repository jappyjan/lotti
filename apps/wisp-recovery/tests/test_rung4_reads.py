# SPDX-License-Identifier: MIT
"""The rung-4 read-only tools (rung4.md §4 and §7: G2, G3, G25) against fakes. No hardware.

  - `peek`: only pins.PEEK_REGIONS, read through dump/dump_fed after the bootloader CRC; decoded.
  - `app-check`: bootloader CRC twice, the flag, the vectors, the app region's CRC against the
    pinned stock image, pinned Wisp images and --image files; exit 3 when nothing matches.
  - `loader-hello --no-release`: the session ends without CONT, the temple stays held.
  - `held-reset-test`: a held session, then a second one whose relay reset must bring the HELO
    back before the PMIC's watchdog could have; it stops when the reset does not.
  - `boot-watch`: CONT, then the status hook through the relay model; the relay's framing rules,
    the loader's HELO after a reboot, the listen-only protocol, the refusal without a protocol.
"""

import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import fake_status
from fake_temple import FakeClock, FakeLoaderLink
from test_session_guard import Case, run_cli
from test_w18 import FAKE_PATCHED, temple
from wisp_w18 import cli, image, links, loader, pins, relay_model, session, status


def wisp_record(boots=7, stage=0x42, stat=0x40) -> bytes:
    rec = bytearray(64)
    struct.pack_into("<IHHIIIHHI", rec, 0, 0x47414457, 1, 64, boots, stat, 1234, stage, 0, 3277)
    struct.pack_into("<I", rec, 60, zlib.crc32(bytes(rec[:60])))
    return bytes(rec)


def bootloader_ram(nor=0x0043_36A0, millivolts=180, flag=0xFFFF_FFFF, ssram=0x7) -> dict:
    """What the patched bootloader leaves in RAM at the hold, as the fake temple's readable memory,
    with what the last Wisp boot left in SSRAM group 2 and the two registers peek reads."""
    uart2 = struct.pack("<7I", 2, 0x2001_9000, 0x0043_4210, 0, 0, 0, 1)  # awake: the loader woke UART2
    return {"nor": struct.pack("<I", nor), "board": struct.pack("<BBHhH", 0, 0, 3, millivolts, 0),
            "uart2": uart2, "power-callbacks": bytes(8), "ssram-power": struct.pack("<I", ssram),
            "rstgen-stat": struct.pack("<I", 1), "wisp-record": wisp_record(), "wisp-boot-status": bytes(692),
            "wisp-boot-status-w24d": bytes(692)}


def ram_temple(app=b"", **ram):
    mram = temple(app)
    for name, data in bootloader_ram(**ram).items():
        mram.io[pins.PEEK_REGIONS[name][0]] = data
    return mram  # the NOR records (MRAM) are inside FAKE_PATCHED


def elf_symbols(path: Path) -> dict[str, tuple[int, int]]:
    """name -> (value, size) from a little-endian ELF32 .symtab."""
    b = path.read_bytes()
    shoff, = struct.unpack_from("<I", b, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", b, 0x2E)
    sections = [struct.unpack_from("<IIIIIIIIII", b, shoff + i * shentsize) for i in range(shnum)]
    out = {}
    for sec in sections:
        if sec[1] != 2:  # SHT_SYMTAB
            continue
        strtab = sections[sec[6]]
        for o in range(sec[4], sec[4] + sec[5], 16):
            name, value, size = struct.unpack_from("<III", b, o)
            start = strtab[4] + name
            out[b[start:b.index(b"\0", start)].decode()] = (value, size)
    return out


class Peek(unittest.TestCase):
    def test_peek_reads_and_decodes_the_allowlisted_regions(self):
        case = Case(ram_temple())
        code, report = run_cli(["peek", "--side", "left"], case)
        self.assertEqual(code, 0, report.get("error"))
        peek = report["peek"]
        self.assertEqual(set(peek), set(pins.PEEK_REGIONS))
        self.assertTrue(peek["nor"]["part"].startswith("MX25U25643G"))
        self.assertEqual((peek["board"]["strap_mV"], peek["board"]["app_hw_version"]), (180, 5))
        self.assertTrue(peek["uart2"]["loader_state"])
        self.assertTrue(peek["power-callbacks"]["zero"])
        self.assertEqual(peek["flag"]["word0"], "0xffffffff")
        self.assertTrue(peek["ssram-power"]["wisp_ram_powered"])
        self.assertEqual(peek["rstgen-stat"]["causes"], ["external"])
        record = peek["wisp-record"]["record"]
        self.assertTrue(record["valid"])
        self.assertEqual((record["boots"], record["stage"], record["reset_cause_names"], record["stage_ms"]),
                         (7, "s0-uart", ["watchdog"], 100))
        self.assertIn("not a sealed v2 status block", peek["wisp-boot-status"]["error"])  # all zero here
        self.assertEqual(case.mram.writes, [])
        reads = {(a0, a1) for a0, a1 in case.programs}
        for address, length, _what in pins.PEEK_REGIONS.values():
            self.assertIn((address, length), reads)

    def test_wisp_ram_is_read_only_while_ssram_group_2_is_powered(self):
        case = Case(ram_temple(ssram=0x1))
        code, report = run_cli(["peek", "--side", "left"], case)
        self.assertEqual(code, 0, report.get("error"))
        for name in pins.PEEK_SSRAM_GATED:
            self.assertIn("not powered", report["peek"][name]["refused"])
        reads = {(a0, a1) for a0, a1 in case.programs}
        for name in pins.PEEK_SSRAM_GATED:
            self.assertNotIn(pins.PEEK_REGIONS[name][:2], reads)  # never dumped
        self.assertEqual(case.mram.writes, [])

    def test_a_sealed_wisp_boot_status_block_is_decoded(self):
        from test_case_uart import boot_block
        from wisp_w18 import case_uart
        st = bytearray(case_uart.BOOT_STATUS_SIZE)
        st[:608] = boot_block()[:608]
        struct.pack_into("<HH", st, 4, 2, case_uart.BOOT_STATUS_SIZE)
        struct.pack_into("<IIHHBBBB", st, 608, 0x40, 0, 0, 300, 1, 0, 3, 0)
        st[624:688] = wisp_record(boots=6, stage=0x15)
        struct.pack_into("<I", st, 688, zlib.crc32(bytes(st[:688])))
        out = cli.describe_peek("wisp-boot-status", bytes(st))
        self.assertEqual(out["status"]["reset_cause_names"], ["watchdog"])
        self.assertEqual(out["status"]["window_ms"], 300)
        self.assertEqual((out["status"]["prev"]["boots"], out["status"]["prev"]["stage"]), (6, "boot-mounted"))

    def test_the_wisp_regions_are_the_pinned_stage0_boots(self):
        """wisp-record is wisp_diag_slot and wisp-boot-status is `st` (692 B) in the committed
        stage-0 Wisp Boot ELF; both inside Wisp Boot's RAM, the top 64 KiB of SSRAM group 2, and
        above the patched bootloader's only SSRAM use, its heap [0x20081000, 0x2013C800)."""
        symbols = elf_symbols(Path(__file__).resolve().parents[1] / "wisp_w18/data/stage-0/wisp_boot.elf")
        self.assertEqual(pins.PEEK_REGIONS["wisp-record"][:2], (symbols["wisp_diag_slot"][0], 64))
        self.assertEqual(pins.PEEK_REGIONS["wisp-boot-status"][:2], symbols["st"])
        for name in pins.PEEK_SSRAM_GATED:
            address, length, _ = pins.PEEK_REGIONS[name]
            self.assertTrue(0x2037_0000 <= address and address + length <= 0x2038_0000)
            self.assertGreaterEqual(address, 0x2013_C800)

    def test_gd_and_unknown_records(self):
        for pointer, part in ((0x0043_36B0, "GD25LE256H"), (0x1234, "neither record")):
            code, report = run_cli(["peek", "--side", "left", "--what", "nor"], Case(ram_temple(nor=pointer)))
            self.assertEqual(code, 0)
            self.assertTrue(report["peek"]["nor"]["part"].startswith(part))

    def test_anything_else_is_refused_before_the_temple(self):
        link = FakeLoaderLink(ram_temple())
        with session.Session(link, log=lambda m: None) as s:
            with self.assertRaises(session.RefusedError):
                s.peek("nor")  # bootloader not checked yet
            s.require_patched_bootloader(FAKE_PATCHED)
            with self.assertRaises(session.RefusedError):
                s.peek("otp")
        loads = [f for f in link.sent if len(f) == 32 and f[8] == loader.LOAD]
        self.assertEqual(len(loads), 1)  # the bootloader CRC only
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            cli.main(["peek", "--side", "left", "--what", "otp"])


class AppCheck(unittest.TestCase):
    def test_stock_matches_by_its_pinned_crc(self):
        stock = bytes((i * 3 + 1) & 255 for i in range(5000))
        with mock.patch.object(pins, "STOCK_MAIN_BYTES", len(stock)), \
                mock.patch.object(pins, "STOCK_MAIN_CRC32", zlib.crc32(stock)):
            case = Case(temple(stock))
            code, report = run_cli(["app-check", "--side", "left"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(report["matches"], [f"stock {pins.STOCK_MAIN_VERSION} main"])
        self.assertEqual((report["flag"], report["flag_meaning"]), ("0xffffffff", "clear"))
        self.assertFalse(report["vectors_zero"])
        self.assertEqual(report["bootloader_crc32"], f"{zlib.crc32(FAKE_PATCHED):08x}")
        self.assertEqual(case.mram.writes, [])

    def test_a_wisp_pin_and_an_image_file_are_compared_too_and_no_match_is_exit_3(self):
        app = bytes((i * 5 + 2) & 255 for i in range(3000))
        pin = {"image_sha256": image.sha(app), "image_bytes": len(app), "crc32": zlib.crc32(app)}
        with mock.patch.dict(pins.WISP_IMAGES, {"native-x": pin}):
            code, report = run_cli(["app-check", "--side", "left"], Case(temple(app)))
        self.assertEqual(code, 0)
        self.assertEqual(report["matches"], ["Wisp native-x"])
        with tempfile.TemporaryDirectory() as tmp:
            other = Path(tmp) / "other.bin"
            other.write_bytes(app[:-1] + b"\x00")
            code, report = run_cli(["app-check", "--side", "left", "--image", str(other)], Case(temple(app)))
        self.assertEqual(code, 3)
        self.assertEqual(report["matches"], [])
        self.assertEqual(report["images"][-1]["name"], str(other))

    def test_an_image_longer_than_the_app_region_is_refused_before_the_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            big = Path(tmp) / "big.bin"
            big.write_bytes(bytes(pins.APP_END_CEILING - pins.APP_BASE + 16))

            def no_case(_args):
                raise AssertionError("touched the case")

            with mock.patch.object(cli, "make_link", no_case), mock.patch("sys.stderr"), mock.patch("sys.stdout"):
                self.assertEqual(cli.main(["app-check", "--side", "left", "--image", str(big)]), 2)

    def test_zero_vectors_and_a_set_flag_are_reported(self):
        app = bytes(16) + bytes(range(200))
        mram = temple(app, {0x7FE000: struct.pack("<4I", 0x55555555, ~0 & 0xFFFFFFFF, ~0 & 0xFFFFFFFF,
                                                  ~0 & 0xFFFFFFFF)})
        code, report = run_cli(["app-check", "--side", "left"], Case(mram))
        self.assertEqual(code, 3)
        self.assertTrue(report["vectors_zero"])
        self.assertTrue(report["flag_meaning"].startswith("install pending"))


class HeldTemple(unittest.TestCase):
    def test_no_release_ends_without_cont(self):
        case = Case(temple())
        code, report = run_cli(["loader-hello", "--side", "left", "--no-release"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertTrue(report["held"])
        sent = case.relays[0].temple.sent
        self.assertNotIn(loader.cont(), sent)

    def test_an_error_still_releases(self):
        link = FakeLoaderLink(temple())
        with self.assertRaises(session.SessionError), session.Session(link, log=lambda m: None) as s:
            s.hold = True
            s.require_patched_bootloader(FAKE_PATCHED[:-1] + b"\0")
        self.assertIn(loader.cont(), link.sent)

    def test_held_reset_test_passes_when_the_reset_brings_helo_back(self):
        case = Case(temple())
        code, report = run_cli(["held-reset-test", "--side", "left"], case)
        self.assertEqual(code, 0, report.get("error"))
        self.assertEqual(len(report["sessions"]), 2)
        self.assertNotIn(loader.cont(), case.relays[0].temple.sent)  # session 0 held it
        self.assertIn(loader.cont(), case.relays[1].temple.sent)  # session 1 released it
        verdict = report["verdict"]
        self.assertLessEqual(verdict["helo_s_after_relay_start"], verdict["limits_s"][0])
        self.assertLess(verdict["helo_s_after_last_kick"], verdict["limits_s"][1])

    def test_held_reset_test_stops_when_the_held_temple_does_not_answer(self):
        case = Case(temple())
        made = case.link
        count = [0]

        def link(args=None):
            made_link = made(args)
            count[0] += 1
            if count[0] == 2:  # the relay's reset does not reach a temple held in its loader
                made_link.port.temple.start = lambda: b""
            return made_link

        case.link = link
        code, report = run_cli(["held-reset-test", "--side", "left"], case)
        self.assertEqual(code, 1)
        self.assertEqual(len(report["sessions"]), 2)
        self.assertNotIn("verdict", report)

    def test_a_helo_that_comes_late_is_not_taken_for_the_cases_reset(self):
        # The case's reset fails, and the PMIC's power cycle brings a HELO inside the relay's beacon
        # window, ~15 s after the relay started: well inside 30.72 s of the held session's last
        # kick, but not the 0.5-0.9 s the reset takes. That must not pass.
        case = Case(temple())
        made = case.link
        count = [0]

        def link(args=None):
            made_link = made(args)
            count[0] += 1
            if count[0] == 2:
                backend = made_link.port.temple
                original = backend.start

                def late():
                    case.clock.advance(15.0)
                    return original()

                backend.start = late
            return made_link

        case.link = link
        code, report = run_cli(["held-reset-test", "--side", "left"], case)
        self.assertEqual(code, 1)
        self.assertIn("STOP", report["error"])
        self.assertIn("PMIC", report["error"])
        self.assertNotIn("verdict", report)

    def test_held_reset_test_needs_the_temple_feed(self):
        def no_case(_args):
            raise AssertionError("touched the case")

        with mock.patch.object(cli, "make_link", no_case), mock.patch("sys.stderr"), mock.patch("sys.stdout"):
            self.assertEqual(cli.main(["held-reset-test", "--side", "left", "--no-temple-feed"]), 2)

    def test_held_reset_test_is_inconclusive_when_the_pmic_could_have_reset_it(self):
        case = Case(temple())
        made = case.link
        count = [0]

        def link(args=None):
            count[0] += 1
            if count[0] == 2:
                case.clock.advance(pins.PMIC_WATCHDOG_S)  # the second session came too late
            return made(args)

        case.link = link
        code, report = run_cli(["held-reset-test", "--side", "left"], case)
        self.assertEqual(code, 1)
        self.assertIn("INCONCLUSIVE", report["error"])


class BootCase(Case):
    """Case whose temple boots an app after CONT (fake_status.BootingTemple)."""

    def __init__(self, mram, **temple_kw):
        super().__init__(mram)
        self.temple_kw = temple_kw

    def link(self, _args=None):
        backend = fake_status.BootingTemple(self.mram, self.clock, **self.temple_kw)
        relay = relay_model.RelayModel(backend, clock=self.clock, idle_s=2.0)
        self.relays.append(relay)
        made = links.RelayPortLink(relay, "left", clock=self.clock)
        self.links.append(made)
        return made


def watch_cli(argv, case):
    with mock.patch.dict(status.PROTOCOLS, {"fake": fake_status.FakeStatus}), \
            mock.patch.object(cli, "WATCH_SLEEP", case.clock.advance):
        return run_cli(argv, case)


class BootWatch(unittest.TestCase):
    def test_cont_then_status_answers_until_the_app_is_up(self):
        case = BootCase(temple(), boot_s=3.0)
        code, report = watch_cli(["boot-watch", "--side", "left", "--protocol", "fake", "--watch-s", "30"], case)
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertTrue(events["complete"])
        self.assertEqual(events["answers"][-1]["stage"], 3)
        self.assertGreaterEqual(events["answers"][0]["t"], 3.0)
        self.assertGreater(events["unanswered"], 0)  # the app was still booting
        temple_ = case.relays[0].temple
        self.assertIsNotNone(temple_.released_at)
        self.assertTrue(all(f == fake_status.frame_9(fake_status.QUERY) for f in temple_.app_frames))
        self.assertEqual(case.mram.writes, [])

    def test_a_reboot_shows_as_the_loaders_helo(self):
        case = BootCase(temple(), boot_s=30.0, reboot_at_s=5.0)
        code, report = watch_cli(["boot-watch", "--side", "left", "--protocol", "fake", "--watch-s", "12"], case)
        self.assertEqual(code, 0)
        self.assertEqual(len(report["boot_watch"]["reboots_s"]), 1)
        self.assertEqual(report["boot_watch"]["answers"], [])

    def test_listen_only_sends_nothing_and_records_what_comes(self):
        chatter = fake_status.answer(1, 0)
        case = BootCase(temple(), boot_s=0.0, chatter=chatter)
        code, report = watch_cli(["boot-watch", "--side", "left", "--watch-s", "10"], case)
        self.assertEqual(code, 0, report.get("error"))
        events = report["boot_watch"]
        self.assertEqual(events["protocol"], "listen")
        self.assertEqual(case.relays[0].temple.app_frames, [])  # nothing reached the app
        self.assertTrue(events["answers"])
        self.assertEqual(events["answers"][0]["frame"], chatter.hex())

    def test_without_a_registered_protocol_nothing_is_sent(self):
        def no_case(_args):
            raise AssertionError("touched the case")

        with mock.patch.object(cli, "make_link", no_case), mock.patch("sys.stderr"), mock.patch("sys.stdout"):
            self.assertEqual(cli.main(["boot-watch", "--side", "left", "--protocol", "nope"]), 2)

    def test_listen_and_the_wisp_protocol_ship(self):
        self.assertEqual(set(status.PROTOCOLS), {"listen", "wisp"})

    def test_frames_the_relay_cannot_carry_are_refused(self):
        self.assertTrue(status.relay_request_ok(fake_status.frame_9(b"WSTQ")))
        self.assertTrue(status.relay_request_ok(b""))
        self.assertFalse(status.relay_request_ok(bytes.fromhex("240001 00a7")))  # the stock version query
        self.assertFalse(status.relay_request_ok(bytes((0x7E, 0, 1, 5)) + bytes(6)))  # 10 bytes
        self.assertTrue(status.relay_reply_ok(fake_status.answer(1, 2)))
        self.assertFalse(status.relay_reply_ok(bytes.fromhex("5aa5ff0924000000020400180536")))  # 14 bytes

        class Bad(fake_status.FakeStatus):
            def request(self, index):
                return bytes.fromhex("24000100a7")

        def no_case(_args):
            raise AssertionError("touched the case")

        with mock.patch.dict(status.PROTOCOLS, {"bad": Bad}), mock.patch.object(cli, "make_link", no_case), \
                mock.patch("sys.stderr"), mock.patch("sys.stdout"):
            self.assertEqual(cli.main(["boot-watch", "--side", "left", "--protocol", "bad"]), 2)

        class Later(fake_status.FakeStatus):  # a later request the relay cannot carry: stops the watch
            def request(self, index):
                return super().request(index) if index == 0 else bytes.fromhex("24000100a7")

        case = BootCase(temple(), boot_s=30.0)
        with mock.patch.dict(status.PROTOCOLS, {"later": Later}), mock.patch.object(cli, "WATCH_SLEEP",
                                                                                     case.clock.advance):
            code, report = run_cli(["boot-watch", "--side", "left", "--protocol", "later"], case)
        self.assertEqual(code, 1)
        self.assertIn("not a frame the case relay forwards", report["error"])
        self.assertEqual(case.relays[0].temple.app_frames, [fake_status.frame_9(fake_status.QUERY)])

    def test_an_undocumented_flag_stops_the_watch_and_the_session_ends_as_always(self):
        mram = temple(b"", {0x7FE000: struct.pack("<I", 0x12345678)})
        case = BootCase(mram)
        code, report = watch_cli(["boot-watch", "--side", "left", "--protocol", "fake"], case)
        self.assertEqual(code, 1)
        self.assertIn("undocumented", report["error"])
        self.assertNotIn("boot_watch", report)
        temple_ = case.relays[0].temple
        self.assertIn(loader.cont(), temple_.sent)  # the cleanup's CONT, as at the end of every session
        self.assertEqual(temple_.app_frames, [])  # but no query


class Clock(unittest.TestCase):
    def test_watch_ends_on_time_without_answers(self):
        clock = FakeClock()

        class Silent:
            def query(self, frame):
                clock.advance(2.0)
                return 2, b"", 2.0

        out = status.watch(Silent(), status.ListenOnly(), 10.0, 1.0, clock=clock, sleep=clock.advance,
                           log=lambda m: None)
        self.assertEqual(out["unanswered"], out["queries"])
        self.assertLessEqual(out["seconds"], 12.0)
