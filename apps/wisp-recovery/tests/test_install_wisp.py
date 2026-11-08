# SPDX-License-Identifier: MIT
"""install-wisp (docs/wisp/rung4.md §3, G1, decision R4-1) against fakes. No hardware.

R4-1 is approved (2026-11-08) and W23 pinned exactly one image, the reviewed native-0 of commit
8374f9a, committed in wisp_w18/data/native-0/. `Pinned` runs the real command's whole gate on
those files (and a full fake install of them), and shows that a one-byte change to any of them is
refused before the case is touched. Every other test pins a synthetic image for its duration
(`PinnedWisp`): a 64 KiB "Wisp Boot" slot and a small "app", an ELF whose segments are those
bytes, a map file, and a Wisp Boot entry with both rung-3 suites.
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

import rule3_vectors
from fake_temple import FakeLoaderLink
from test_session_guard import Case
from test_w18 import FAKE_PATCHED, temple
from wisp_w18 import cli, image, native, pins, session

APP_PART = 0x48000 - 0x38000  # the app part starts at 0x448000


def wisp_image(app_bytes=4096, sp=0x2037_FF00, reset=pins.APP_BASE + 0x201) -> bytes:
    """A synthetic native image: Wisp Boot's slot (vectors, code, 0xFF padding to 64 KiB), then
    an app linked at 0x448000. Nothing in it is meant to run."""
    boot = bytearray(b"\xff" * pins.WISP_BOOT_SLOT_BYTES)
    struct.pack_into("<II", boot, 0, sp, reset)
    for i in range(8, 0x40, 4):
        struct.pack_into("<I", boot, i, pins.APP_BASE + 0x301)
    boot[0x200:0x1200] = bytes((i * 7 + 3) & 255 for i in range(0x1000))
    app = bytearray((i * 11 + 1) & 255 for i in range(app_bytes))
    struct.pack_into("<II", app, 0, 0x2007_FB00, 0x0044_8201)
    return bytes(boot + app)


def elf32(segments: list[tuple[int, int, bytes]]) -> bytes:
    """A minimal ELF32 LE with one PT_LOAD per (paddr, vaddr, bytes)."""
    header_size, ph_size = 52, 32
    data_at = header_size + ph_size * len(segments)
    out = bytearray(b"\x7fELF\x01\x01\x01" + bytes(9))
    out += struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0, header_size, 0, 0x05000200, header_size, ph_size,
                       len(segments), 40, 0, 0)
    blobs = b""
    for paddr, vaddr, content in segments:
        out += struct.pack("<8I", 1, data_at + len(blobs), vaddr, paddr, len(content), len(content), 5, 4)
        blobs += content
    return bytes(out + blobs)


def with_sections(elf: bytes, sections: list[tuple[int, int, int, int]]) -> bytes:
    """`elf` plus a section header table: (sh_type, sh_flags, file offset, size) per section,
    after a null section."""
    out = bytearray(elf)
    shoff = len(out)
    out += bytes(40)
    for sh_type, flags, offset, size in sections:
        out += struct.pack("<10I", 0, sh_type, flags, 0, offset, size, 0, 0, 4, 0)
    struct.pack_into("<I", out, 0x20, shoff)
    struct.pack_into("<HHH", out, 0x2E, 40, len(sections) + 1, 0)
    return bytes(out)


def app_elf(data: bytes) -> bytes:
    app = data[APP_PART:]
    return elf32([(0x0044_8000, 0x0044_8000, app[:3072]), (0x0044_8000 + 3072, 0x2000_0000, app[3072:]),
                  (0x2000_1000, 0x2000_1000, b"")])


class PinnedWisp:
    """Pins `data` (and its ELF and map) as `native-test`, approves R4-1 and registers its Wisp
    Boot as having passed both suites, for the duration of the block; writes the three files."""

    def __init__(self, data: bytes, elf: bytes | None = None, map_text=b"native-test.map\n", gates=pins.WISP_GATES,
                 suites=pins.WISP_BOOT_SUITES, approved=True):
        self.data, self.elf, self.map = data, elf if elf is not None else app_elf(data), map_text
        self.gates, self.suites, self.approved = gates, suites, approved

    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.paths = {"image": d / "native.bin", "elf": d / "zephyr.elf", "map": d / "zephyr.map"}
        self.paths["image"].write_bytes(self.data)
        self.paths["elf"].write_bytes(self.elf)
        self.paths["map"].write_bytes(self.map)
        boot = image.sha(self.data[: pins.WISP_BOOT_SLOT_BYTES])
        pin = {"image_sha256": image.sha(self.data), "image_bytes": len(self.data), "elf_sha256": image.sha(self.elf),
               "map_sha256": image.sha(self.map), "gates": tuple(self.gates)}
        self.patches = [
            mock.patch.object(pins, "R4_1_APPROVED", self.approved),
            mock.patch.object(pins, "WISP_IMAGES", {"native-test": pin}),
            mock.patch.object(pins, "WISP_BOOT_PASSED",
                              {boot: {"build": "test", "suites": {s: "synthetic" for s in self.suites}}}),
        ]
        for p in self.patches:
            p.start()
        return self

    def argv(self, *extra, expect=None, battery="90"):
        return ["install-wisp", "--side", "left", "--image", str(self.paths["image"]), "--elf", str(self.paths["elf"]),
                "--map", str(self.paths["map"]), "--expect", expect or image.sha(self.data)[:12],
                "--battery", battery, *extra]

    def __exit__(self, *a):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()


def run(argv, case=None):
    """The CLI on `case` (test_session_guard.Case: a relay model per session), or with a link
    factory that fails the test if anything tries to reach the case."""
    reports = []

    def no_case(_args):
        raise AssertionError("install-wisp touched the case")

    with mock.patch.object(cli, "make_link", case.link if case else no_case), \
            mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED), \
            mock.patch.object(cli, "save", lambda report, name: reports.append(report) or Path(name)), \
            mock.patch("sys.stdout"), mock.patch("sys.stderr") as err:
        code = cli.main(argv)
    stderr = "".join(str(c.args[0]) for c in err.write.call_args_list if c.args)
    return code, (reports[0] if reports else None), stderr


def running_app():
    """What the left temple holds before the first native flash: a running app (non-zero vectors)."""
    data = bytearray((i * 5 + 9) & 255 for i in range(0x12000))
    struct.pack_into("<II", data, 0, 0x2007_FB00, pins.APP_BASE + 0x101)
    return bytes(data)


NATIVE_0 = native.NATIVE_0_FILES
NATIVE_0_SHA = "5d373fd8874275a3a59d18306536a4b73a4f4361e92050ee22583faedfd60bba"


def native_0_argv(paths=None, expect=NATIVE_0_SHA[:12], battery="95"):
    paths = paths or NATIVE_0
    return ["install-wisp", "--side", "left", "--image", str(paths["image"]), "--elf", str(paths["elf"]),
            "--map", str(paths["map"]), "--expect", expect, "--battery", battery]


class ReachedTheCase(Exception):
    """make_link was called: every check before the case passed."""


def run_until_case(argv):
    """The real command, stopped where it would open the case link. Returns (reached, stderr):
    reached is True if every check before the case passed, else the exit code."""
    reached = []

    def stop(_args):
        reached.append(True)
        raise ReachedTheCase

    with mock.patch.object(cli, "make_link", stop), mock.patch("sys.stdout"), \
            mock.patch.object(image, "build_patched_bootloader", lambda cache=None: FAKE_PATCHED), \
            mock.patch("sys.stderr") as err, mock.patch.object(cli, "save", lambda report, name: Path(name)):
        code = cli.main(argv)
    stderr = "".join(str(c.args[0]) for c in err.write.call_args_list if c.args)
    return (True if reached else code), stderr


class Pinned(unittest.TestCase):
    """W23: the one pinned image, the reviewed native-0, and its committed files."""

    def test_exactly_native_0_and_its_wisp_boot_are_pinned(self):
        self.assertTrue(pins.R4_1_APPROVED)
        self.assertEqual(set(pins.WISP_IMAGES), {"native-0"})
        pin = pins.WISP_IMAGES["native-0"]
        self.assertEqual(pin["image_sha256"], NATIVE_0_SHA)
        self.assertEqual(pin["image_bytes"], 230_428)
        self.assertEqual(pin["map_sha256"][:8], "28fcb218")
        self.assertEqual(set(pin["gates"]), set(pins.WISP_GATES))
        slot = "16616d9d82ebc934f1460112b5ac62c481c66ed57a8881d1837dcf59e7c27816"
        self.assertEqual(set(pins.WISP_BOOT_PASSED), {slot})
        self.assertEqual(set(pins.WISP_BOOT_PASSED[slot]["suites"]), set(pins.WISP_BOOT_SUITES))

    def test_the_committed_files_are_the_pinned_ones(self):
        pin = pins.WISP_IMAGES["native-0"]
        data = NATIVE_0["image"].read_bytes()
        self.assertEqual(image.sha(data), pin["image_sha256"])
        self.assertEqual(len(data), pin["image_bytes"])
        self.assertEqual(zlib.crc32(data), pin["crc32"])
        self.assertEqual(image.sha(data[: pins.WISP_BOOT_SLOT_BYTES]), pin["wisp_boot_slot_sha256"])
        self.assertEqual(image.sha(NATIVE_0["elf"].read_bytes()), pin["elf_sha256"])
        self.assertEqual(image.sha(NATIVE_0["map"].read_bytes()), pin["map_sha256"])
        manifest = __import__("json").loads((native.NATIVE_0_DIR / "manifest.json").read_text())
        self.assertEqual((manifest["image_sha256"], manifest["bytes"], manifest["app_map_sha256"]),
                         (pin["image_sha256"], pin["image_bytes"], pin["map_sha256"]))
        self.assertEqual(manifest["wisp_boot_slot_sha256"], pin["wisp_boot_slot_sha256"])
        self.assertEqual(int(manifest["image_crc32"], 16), pin["crc32"])
        self.assertTrue(manifest["app_hardware_image"] and manifest["wisp_boot_observe_only"])
        # The debug-stripped ELF names no build machine path.
        for f in ("elf",):
            raw = NATIVE_0[f].read_bytes()
            for needle in (b"/home/", b"/nix/store/", b"/tmp/"):
                self.assertNotIn(needle, raw, f)

    def test_resolve_accepts_the_committed_image(self):
        facts = native.resolve(NATIVE_0["image"].read_bytes(), NATIVE_0["elf"].read_bytes(),
                               NATIVE_0["map"].read_bytes(), NATIVE_0_SHA[:12])
        self.assertEqual(facts["name"], "native-0")
        self.assertEqual(facts["end"], "0x470420")
        self.assertGreaterEqual(facts["elf_segments_checked"], 1)
        self.assertEqual(facts["wisp_boot"]["wisp_boot_bin_sha256"][:8], "d793a93e")

    def test_the_whole_gate_before_the_case_accepts_it(self):
        reached, stderr = run_until_case(native_0_argv())
        self.assertIs(reached, True, stderr)
        reached, stderr = run_until_case(native_0_argv(battery="3950mV"))
        self.assertIs(reached, True, stderr)

    def test_a_one_byte_change_to_any_file_is_refused_before_the_case(self):
        for which, at in (("image", 0x2_0000), ("image", 230_427), ("image", 0x100), ("elf", None),
                          ("map", None)):
            with self.subTest(which=which, at=at), tempfile.TemporaryDirectory() as tmp:
                paths = {k: Path(tmp) / v.name for k, v in NATIVE_0.items()}
                for k, v in NATIVE_0.items():
                    paths[k].write_bytes(v.read_bytes())
                raw = bytearray(paths[which].read_bytes())
                i = at if at is not None else len(raw) // 2
                raw[i] ^= 0x01
                paths[which].write_bytes(raw)
                code, stderr = run_until_case(native_0_argv(paths))
                self.assertEqual(code, 2, stderr)
                self.assertIn("REFUSED", stderr)

    def test_expect_and_battery_are_still_required(self):
        for argv in (native_0_argv(expect="5d373fd8"), native_0_argv(expect="5d373fd88743"),
                     native_0_argv(battery="79"), native_0_argv(battery="3800mV")):
            with self.subTest(argv=argv[-4:]):
                code, stderr = run_until_case(argv)
                self.assertEqual(code, 2, stderr)

    def test_a_fake_install_of_native_0_writes_it_whole(self):
        data = NATIVE_0["image"].read_bytes()
        mram = temple(running_app())
        case = Case(mram)
        code, report, stderr = run(native_0_argv(), case)
        self.assertEqual(code, 0, stderr)
        self.assertEqual(mram.read(pins.APP_BASE, len(data)), data)
        self.assertEqual(report["image"]["name"], "native-0")
        self.assertTrue(all(r["ok"] for r in report["rule3"]))


class Gate(unittest.TestCase):
    def test_an_image_not_in_the_table_is_refused_before_touching_the_case(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "native.bin"
            data = wisp_image()
            path.write_bytes(data)
            code, report, stderr = run(["install-wisp", "--side", "left", "--image", str(path), "--elf", str(path),
                                        "--map", str(path), "--expect", image.sha(data)[:12], "--battery", "95"])
        self.assertEqual(code, 2)
        self.assertIsNone(report)
        self.assertIn("REFUSED", stderr)
        self.assertIn("WISP_IMAGES", stderr)
        self.assertIn("nothing was sent", stderr)

    def test_a_pinned_table_without_the_approval_still_refuses(self):
        with PinnedWisp(wisp_image(), approved=False) as w:
            code, _, stderr = run(w.argv())
        self.assertEqual(code, 2)
        self.assertIn("R4-1", stderr)


class Install(unittest.TestCase):
    def test_a_pinned_image_goes_in_vectors_zeroed_first_and_written_last(self):
        data = wisp_image()
        mram = temple(running_app())
        case = Case(mram)
        sent_to_check = []
        real_rule3 = native.rule3

        def rule3(sent):
            sent_to_check.append((sent, len(mram.writes)))
            return real_rule3(sent)

        with PinnedWisp(data) as w, mock.patch.object(native, "rule3", rule3):
            code, report, stderr = run(w.argv(), case)
        self.assertEqual(code, 0, stderr)
        end = pins.APP_BASE + len(data)
        self.assertEqual(mram.read(pins.APP_BASE, len(data)), data)
        writes = mram.writes
        self.assertEqual(writes[0], (pins.APP_BASE, 16))
        self.assertEqual(writes[-1], (pins.APP_BASE, 16))
        self.assertEqual(writes.count((pins.APP_BASE, 16)), 2)
        self.assertTrue(all(pins.APP_BASE <= a and a + n <= end for a, n in writes))
        # Rule 3 ran on the file, then again on the bytes the writer sends, before its first write.
        self.assertEqual([s for s, _ in sent_to_check], [data, data])
        self.assertEqual(sent_to_check[-1][1], 0)
        self.assertTrue(all(r["ok"] for r in report["rule3"]))
        for by in ("port", "wisp-ota"):  # both implementations, every guard
            self.assertEqual({r["id"] for r in report["rule3"] if r["by"] == by}, set(native.GUARD_IDS))
        self.assertEqual(report["image"]["name"], "native-test")
        self.assertEqual(report["image"]["elf_segments_checked"], 2)
        self.assertEqual(report["loader_hello"], {"bootloader_crc32": f"{zlib.crc32(FAKE_PATCHED):08x}",
                                                  "flag": "0xffffffff"})
        self.assertEqual(report["battery"], {"percent": 90, "ok": True})
        self.assertTrue(report["vectors_zeroed"])
        self.assertEqual(report["crc_after"], f"{zlib.crc32(mram.read(pins.APP_BASE, len(data))):08x}")
        self.assertTrue(report["success"])

    def test_an_image_length_off_the_16_byte_unit(self):
        data = wisp_image(4100)
        mram = temple(running_app())
        with PinnedWisp(data) as w:
            code, report, stderr = run(w.argv(), Case(mram))
        self.assertEqual(code, 0, stderr)
        self.assertEqual(mram.read(pins.APP_BASE, len(data)), data)
        self.assertEqual(report["image"]["end"], f"{pins.APP_BASE + len(data) + 12:#x}")
        self.assertTrue(all(a + n <= pins.APP_BASE + len(data) + 12 for a, n in mram.writes))
        self.assertEqual(mram.read(pins.APP_BASE + len(data), 12), running_app()[len(data) : len(data) + 12])

    def test_a_set_update_flag_stops_the_session_before_any_write(self):
        mram = temple(running_app(), {0x7FE000: struct.pack("<4I", 0x55555555, ~0 & 0xFFFFFFFF, ~0 & 0xFFFFFFFF,
                                                           ~0 & 0xFFFFFFFF)})
        with PinnedWisp(wisp_image()) as w:
            code, report, _ = run(w.argv(), Case(mram))
        self.assertEqual(code, 1)
        self.assertIn("not clear", report["error"])
        self.assertEqual(mram.writes, [])

    def test_a_stop_leaves_zero_vectors_and_resumes_without_zeroing_again(self):
        data = wisp_image(8192)
        mram = temple(running_app())
        case = Case(mram, hang_after_exchanges=2500)
        with PinnedWisp(data) as w:
            code, report, _ = run(w.argv("--max-session-s", "0"), case)
            self.assertEqual(code, 1)
            self.assertEqual(mram.read(pins.APP_BASE, 16), bytes(16))
            self.assertTrue(report["vectors_zeroed"])
            self.assertFalse(report["vectors_written"])
            self.assertEqual(report["body_verified"], 0)  # one session: the body is CRC-checked at its end
            # A budget splits the write into resumable parts; stop that one in its second session.
            calls = [0]
            original = case.link

            def link(args=None):
                calls[0] += 1
                case.model = {"hang_after_exchanges": 200} if calls[0] == 2 else {}
                return original(args)

            case.link = link
            code, report, _ = run(w.argv("--max-session-s", "600"), case)
            self.assertEqual(code, 1)
            done = report["body_verified"]
            self.assertGreater(done, 0)
            self.assertIn("install-wisp", report["resume_with"])
            self.assertIn(f"--resume-at {done}", report["resume_with"])
            zeroings = mram.writes.count((pins.APP_BASE, 16))
            self.assertEqual(zeroings, 1)  # the first run zeroed them; the second found them zero
            case.link = original
            case.model = {}
            code, report, stderr = run(w.argv("--resume-at", str(done), "--max-session-s", "600"), case)
        self.assertEqual(code, 0, stderr)
        self.assertEqual(mram.read(pins.APP_BASE, len(data)), data)
        self.assertEqual(mram.writes.count((pins.APP_BASE, 16)), zeroings + 1)  # only the real vectors
        self.assertFalse(report["vectors_zeroed"])


class Refusals(unittest.TestCase):
    """Each refusal comes before anything reaches the case (the link factory would fail)."""

    def refused(self, pinned: PinnedWisp, *extra, **kw) -> str:
        with pinned as w:
            code, report, stderr = run(w.argv(*extra, **kw))
        self.assertEqual(code, 2, stderr)
        self.assertIsNone(report)
        self.assertIn("REFUSED", stderr)
        return stderr

    def test_expect_must_name_the_image(self):
        self.assertIn("--expect", self.refused(PinnedWisp(wisp_image()), expect="0" * 12))
        data = wisp_image()
        self.assertIn("--expect", self.refused(PinnedWisp(data), expect=image.sha(data)[:8]))

    def test_an_image_missing_from_a_non_empty_table(self):
        pinned = PinnedWisp(wisp_image())
        with pinned as w:
            w.paths["image"].write_bytes(wisp_image(4112))
            code, _, stderr = run(w.argv())
        self.assertEqual(code, 2)
        self.assertIn("is not in pins.WISP_IMAGES", stderr)

    def test_elf_and_map_must_match_their_pins(self):
        pinned = PinnedWisp(wisp_image())
        with pinned as w:
            w.paths["elf"].write_bytes(w.elf + b"\0")
            code, _, stderr = run(w.argv())
        self.assertEqual(code, 2)
        self.assertIn("not the pinned ELF", stderr)
        with pinned as w:
            w.paths["map"].write_bytes(b"other")
            code, _, stderr = run(w.argv())
        self.assertIn("not the pinned map", stderr)

    def test_the_elf_must_be_the_image(self):
        data = wisp_image()
        wrong = bytearray(data[APP_PART:])
        wrong[100] ^= 1
        self.assertIn("differs from the image", self.refused(PinnedWisp(data, elf=elf32([(0x448000, 0x448000, bytes(wrong))]))))
        outside = elf32([(0x0044_8000 + 8192, 0x0044_8000, b"\1" * 16)])
        self.assertIn("outside the image", self.refused(PinnedWisp(data, elf=outside)))
        ram_only = elf32([(0x2000_0000, 0x2000_0000, b"\1" * 16)])
        self.assertIn("no segment in MRAM", self.refused(PinnedWisp(data, elf=ram_only)))

    def test_padding_between_sections_is_not_compared(self):
        """Zephyr's zephyr.bin fills the alignment gaps between sections with 0xFF, while the ELF's
        segment holds zeros there (native-0: 4 bytes at 0x469084, before rodata)."""
        data = bytearray(wisp_image())
        data[APP_PART + 1000 : APP_PART + 1004] = b"\xff" * 4  # the image's gap fill
        segment = bytearray(data[APP_PART : APP_PART + 3072])
        segment[1000:1004] = bytes(4)  # the ELF's padding
        elf = elf32([(0x448000, 0x448000, bytes(segment))])
        at = 52 + 32  # the one segment's file offset
        alloc, progbits, nobits = 0x2, 1, 8
        sections = [(progbits, alloc, at, 1000), (progbits, alloc, at + 1004, 3072 - 1004),
                    (nobits, alloc, at + 3072, 512), (progbits, 0, 0, 16)]
        self.assertEqual(native.elf_matches(with_sections(elf, sections), bytes(data)), 1)
        # Without section headers the whole segment is compared, padding included.
        with self.assertRaisesRegex(native.NativeRefused, "differs from the image at 0x4483e8"):
            native.elf_matches(elf, bytes(data))
        # A difference inside a section is still refused.
        data[APP_PART + 2000] ^= 1
        with self.assertRaisesRegex(native.NativeRefused, "differs from the image at 0x4487d0"):
            native.elf_matches(with_sections(elf, sections), bytes(data))
        # A segment that no section covers compares nothing: refused.
        with self.assertRaisesRegex(native.NativeRefused, "holds no section"):
            native.elf_matches(with_sections(elf, [(progbits, alloc, at + 3072, 16)]), bytes(data))

    def test_the_build_gates_must_be_recorded(self):
        self.assertIn("no-mram-write", self.refused(PinnedWisp(wisp_image(), gates=("check_rule8",))))

    def test_wisp_boot_must_have_passed_both_suites(self):
        self.assertIn("patched-87e2d4e0", self.refused(PinnedWisp(wisp_image(), suites=("stock-2.4.0.24",))))
        data = wisp_image()
        with PinnedWisp(data) as w, mock.patch.object(pins, "WISP_BOOT_PASSED", {}):
            code, _, stderr = run(w.argv())
        self.assertEqual(code, 2)
        self.assertIn("not a build that passed rung 3", stderr)

    def test_rule_3_uses_the_strict_sram_bound(self):
        stderr = self.refused(PinnedWisp(wisp_image(sp=0x2040_0000)))
        self.assertIn("sp-vector", stderr)
        self.assertIn("reset-vector", self.refused(PinnedWisp(wisp_image(reset=pins.APP_BASE + 0x200))))

    def test_battery(self):
        self.assertIn("--battery", self.refused(PinnedWisp(wisp_image()), battery="79"))
        self.assertIn("--battery", self.refused(PinnedWisp(wisp_image()), battery="3850mV"))
        self.assertIn("--battery", self.refused(PinnedWisp(wisp_image()), battery="lots"))
        self.assertEqual(native.parse_battery("3900mV"), {"mV": 3900, "ok": True})
        self.assertEqual(native.parse_battery("80%"), {"percent": 80, "ok": True})
        self.assertFalse(native.parse_battery("101")["ok"])

    def test_the_writer_refuses_an_image_that_is_not_its_pin(self):
        data = wisp_image()
        with PinnedWisp(data):
            with self.assertRaises(session.RefusedError):
                session.AppImage("x", data[:-16], image.sha(data[:-16]), pins.APP_BASE + len(data) - 16)
            with self.assertRaises(session.RefusedError):
                session.AppImage("x", data[:-16], image.sha(data), pins.APP_BASE + len(data))
            with self.assertRaises(session.RefusedError):
                session.AppImage("x", data, image.sha(data), pins.APP_BASE + len(data) + 16)
            session.AppImage("x", data, image.sha(data), pins.APP_BASE + len(data))

    def test_the_writer_itself_refuses_a_wisp_image_without_r4_1(self):
        """Whatever a caller checked: the repository's pins refuse any non-stock AppImage."""
        data = wisp_image()
        with self.assertRaises(session.RefusedError) as caught:
            session.AppImage("x", data, image.sha(data), pins.APP_BASE + len(data))
        self.assertIn("R4-1", str(caught.exception))
        with PinnedWisp(data, approved=False), self.assertRaises(session.RefusedError):
            session.AppImage("x", data, image.sha(data), pins.APP_BASE + len(data))

    def test_without_wisp_otas_build_rule_3_refuses(self):
        with mock.patch.object(native, "WISP_OTA_GUARDS", Path("/nonexistent/guards.js")):
            self.assertIn("wisp-ota:build", self.refused(PinnedWisp(wisp_image())))

    def test_both_implementations_must_pass(self):
        def disagree(payload):
            return [{**r, "ok": r["ok"] and r["id"] != "app-end"} for r in native.check_main_payload(payload)]
        with mock.patch.object(native, "wisp_ota_guards", disagree):
            self.assertIn("wisp-ota: app-end", self.refused(PinnedWisp(wisp_image())))

    def test_a_malformed_elf_is_a_refusal(self):
        for elf in (b"\x7fELF", b"\x7fELF\x01\x01" + bytes(14), b"\x7fELF\x01\x01" + bytes(22) + b"\xff" * 30):
            self.assertIn("--elf", self.refused(PinnedWisp(wisp_image(), elf=elf)))


class Rule3Port(unittest.TestCase):
    def test_the_shared_vectors_are_current(self):
        self.assertEqual(rule3_vectors.JSON.read_text(), rule3_vectors.text())

    def test_the_port_flags_exactly_what_the_vectors_say(self):
        import json
        vectors = json.loads(rule3_vectors.JSON.read_text())["vectors"]
        self.assertGreater(len(vectors), 20)
        for v in vectors:
            results = native.check_main_payload(rule3_vectors.expand(v))
            self.assertEqual(sorted(r["id"] for r in results), sorted(native.GUARD_IDS), v["name"])
            self.assertEqual(sorted(r["id"] for r in results if not r["ok"]), v["failed"], v["name"])

    def test_wrap_matches_wisp_ota(self):
        data = wisp_image()
        payload = native.wrap_main_image(data)
        word0, crc = struct.unpack_from("<II", payload)
        self.assertEqual((word0 >> 24, word0 & 0xFFFFFF), (4, len(payload)))
        self.assertEqual(struct.unpack_from("<II", payload, 0x10), (0xCB, 0x438000))
        self.assertEqual(crc, zlib.crc32(payload[8:]))
        self.assertEqual(payload[32:], data)

    def test_the_second_crc_implementation(self):
        for blob in (b"", b"123456789", bytes(range(256)) * 9, hashlib.sha256(b"x").digest() * 100):
            self.assertEqual(native.crc32_table(blob), zlib.crc32(blob))
        self.assertEqual(native.crc32_table(b"123456789"), 0xCBF43926)


if __name__ == "__main__":
    unittest.main()
