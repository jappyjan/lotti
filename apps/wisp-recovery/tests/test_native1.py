# SPDX-License-Identifier: MIT
"""native-1 (docs/wisp/rung4.md W25): the committed files and install-wisp over a non-stock app.

native-1 is NOT pinned here (its independent review and pin are a separate step), so install-wisp
refuses it as committed; these tests pin it in memory (PinnedWisp) to show that the writer itself
does not assume stock underneath: it goes in whole over a temple that runs native-0 or stage-0,
and the 16-byte unit at its end keeps what was there."""
import json
import struct
import sys
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_install_wisp import PinnedWisp, run  # noqa: E402
from test_rung4_reads import elf_symbols  # noqa: E402
from test_session_guard import Case  # noqa: E402
from test_w18 import temple  # noqa: E402
from wisp_w18 import image, native, pins  # noqa: E402

DIR = Path(native.__file__).resolve().parent / "data/native-1"


def files() -> dict:
    return {k: (DIR / n).read_bytes() for k, n in (("image", "native-1.bin"), ("elf", "zephyr.elf"),
                                                   ("map", "zephyr.map"))}


class Native1(unittest.TestCase):
    def test_not_pinned_so_install_wisp_refuses_it_as_committed(self):
        f = files()
        self.assertNotIn(image.sha(f["image"]), {p["image_sha256"] for p in pins.WISP_IMAGES.values()})
        with self.assertRaises(native.NativeRefused):
            native.resolve(f["image"], f["elf"], f["map"], image.sha(f["image"])[:12])

    def test_manifest_matches_the_committed_image(self):
        f = files()
        m = json.loads((DIR / "manifest.json").read_text())
        self.assertEqual(m["image"], "native-1")
        self.assertEqual(m["image_sha256"], image.sha(f["image"]))
        self.assertEqual(m["bytes"], len(f["image"]))
        self.assertTrue(m["app_hardware_image"] and m["wisp_boot_observe_only"])
        self.assertEqual(m["wisp_boot_slot_sha256"], image.sha(f["image"][:pins.WISP_BOOT_SLOT_BYTES]))

    def test_the_whole_gate_accepts_it_once_pinned(self):
        f = files()
        with PinnedWisp(f["image"], elf=f["elf"], map_text=f["map"]):
            facts = native.resolve(f["image"], f["elf"], f["map"], image.sha(f["image"])[:12])
        self.assertEqual(facts["bytes"], len(f["image"]))
        self.assertGreaterEqual(facts["elf_segments_checked"], 1)

    def test_peek_finds_native1s_record_and_status_block(self):
        """native-1's Wisp Boot is stage-0b's (W24d, PR #88): its record is `peek`'s wisp-record, and
        its status block `st` sits where stage-0b's does (0x2037533C), and the move of
        PEEK_REGIONS["wisp-boot-status"] that stage-0b's pin made (#88) covers native-1 too."""
        symbols = elf_symbols(DIR / "wisp_boot.elf")
        stage0b = elf_symbols(DIR.parent / "stage-0b" / "wisp_boot.elf")
        self.assertEqual(pins.PEEK_REGIONS["wisp-record"][:2], (symbols["wisp_diag_slot"][0], 64))
        self.assertEqual(symbols["st"], stage0b["st"])
        self.assertEqual(symbols["st"], (0x2037_533C, 692))
        self.assertEqual(pins.PEEK_REGIONS["wisp-boot-status"][:2], symbols["st"])  # since #88's pin

    def test_installs_over_a_temple_running_another_wisp_image(self):
        f = files()
        data = f["image"]
        end = pins.APP_BASE + ((len(data) + 15) & ~15)
        for under in (native.NATIVE_0_FILES["image"], native.STAGE_0_FILES["image"]):
            with self.subTest(under=under.parent.name):
                old = under.read_bytes()
                # Whatever lies past the old image (stock's bytes on the left temple) stays too.
                old = old + bytes((i * 7 + 3) & 255 for i in range(max(0, end - pins.APP_BASE - len(old) + 64)))
                mram = temple(old)
                with PinnedWisp(data, elf=f["elf"], map_text=f["map"]) as w:
                    code, report, stderr = run(w.argv(), Case(mram))
                self.assertEqual(code, 0, stderr)
                self.assertEqual(mram.read(pins.APP_BASE, len(data)), data)
                region = mram.read(pins.APP_BASE, end - pins.APP_BASE)
                self.assertEqual(region[len(data):], old[len(data):end - pins.APP_BASE])
                self.assertEqual(report["crc_after"], f"{zlib.crc32(region):08x}")
                self.assertEqual(mram.writes[0], (pins.APP_BASE, 16))
                self.assertEqual(mram.writes[-1], (pins.APP_BASE, 16))
                self.assertTrue(all(pins.APP_BASE <= a and a + n <= end for a, n in mram.writes))
                sp, pc = struct.unpack_from("<II", mram.read(pins.APP_BASE, 8))
                self.assertEqual((sp, pc), struct.unpack_from("<II", data))


if __name__ == "__main__":
    unittest.main()
