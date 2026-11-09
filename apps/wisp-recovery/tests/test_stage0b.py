# SPDX-License-Identifier: MIT
"""stage-0b (docs/wisp/rung4.md W24d), built and committed but NOT pinned: an independent review and
the pinning commit come first. The committed files in wisp_w18/data/stage-0b/ agree with their
manifest and with proposed-pin.json and pass rule 3 in both implementations; install-wisp refuses
them before the case with the repository's pins; with the proposed pin added in memory (what the
pinning commit would do) its whole gate before the case accepts them, and a one-byte change is
still refused. No hardware."""

import json
import sys
import unittest
import zlib
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_install_wisp import run_until_case
from wisp_w18 import image, native, pins

DIR = native.STAGE_0_DIR.parent / "stage-0b"
FILES = {"image": DIR / "stage-0b.bin", "elf": DIR / "stage0.elf", "map": DIR / "stage0.map"}
PROPOSED = json.loads((DIR / "proposed-pin.json").read_text())


def argv(paths=None):
    paths = paths or FILES
    return ["install-wisp", "--side", "left", "--image", str(paths["image"]), "--elf", str(paths["elf"]),
            "--map", str(paths["map"]), "--expect", PROPOSED["image"]["image_sha256"][:12], "--battery", "95"]


def proposed_tables():
    """pins.WISP_IMAGES / WISP_BOOT_PASSED as the pinning commit would extend them."""
    p = PROPOSED["image"]
    pin = {k: (tuple(v) if k == "gates" else int(v, 16) if k.startswith("crc32") else v) for k, v in p.items()}
    passed = {**PROPOSED["wisp_boot"], "suites": {s: "proposed" for s in pins.WISP_BOOT_SUITES}}
    return ({**pins.WISP_IMAGES, "stage-0b": pin}, {**pins.WISP_BOOT_PASSED, pin["wisp_boot_slot_sha256"]: passed})


class Stage0b(unittest.TestCase):
    def setUp(self):
        self.data = FILES["image"].read_bytes()
        self.elf = FILES["elf"].read_bytes()
        self.map = FILES["map"].read_bytes()
        self.manifest = json.loads((DIR / "manifest.json").read_text())

    def test_not_pinned(self):
        self.assertNotIn("stage-0b", pins.WISP_IMAGES)
        self.assertIsNone(native.find_pin(image.sha(self.data)))
        self.assertNotIn(PROPOSED["image"]["wisp_boot_slot_sha256"], pins.WISP_BOOT_PASSED)

    def test_files_match_the_manifest_and_the_proposal(self):
        p, m = PROPOSED["image"], self.manifest
        self.assertEqual((m["image"], m["bytes"], m["image_sha256"]), ("stage-0b", len(self.data), image.sha(self.data)))
        self.assertEqual((p["image_sha256"], p["image_bytes"]), (image.sha(self.data), len(self.data)))
        self.assertEqual(p["elf_sha256"], image.sha(self.elf))
        self.assertEqual(p["map_sha256"], image.sha(self.map))
        self.assertEqual(m["app_map_sha256"], p["map_sha256"])
        self.assertEqual(int(p["crc32"], 16), zlib.crc32(self.data))
        self.assertEqual(int(m["image_crc32"], 16), zlib.crc32(self.data))
        self.assertEqual(p["wisp_boot_slot_sha256"], image.sha(self.data[: pins.WISP_BOOT_SLOT_BYTES]))
        self.assertEqual(m["wisp_boot_slot_sha256"], p["wisp_boot_slot_sha256"])
        self.assertEqual(PROPOSED["wisp_boot"]["wisp_boot_bin_sha256"], m["wisp_boot_bin_sha256"])
        self.assertTrue(m["wisp_boot_observe_only"] and m["app_bare_metal"] and m["app_hardware_image"])
        self.assertGreater(native.elf_matches(self.elf, self.data), 0)
        for needle in (b"/home/", b"/nix/store/", b"/tmp/"):
            self.assertNotIn(needle, self.elf)

    def test_rule3_in_both_implementations(self):
        checks = native.rule3(self.data)
        self.assertTrue(checks and all(c["ok"] for c in checks), checks)
        self.assertEqual({c["by"] for c in checks}, {"port", "wisp-ota"})

    def test_the_crc_install_wisp_would_report_over_stock(self):
        try:
            stock = image.stock_main()
        except (image.ImageError, OSError) as error:
            self.skipTest(f"no stock 2.4.0.24 bundle: {error}")
        end = (len(self.data) + 15) & ~15
        self.assertEqual(zlib.crc32(self.data + stock[len(self.data):end]),
                         int(PROPOSED["image"]["crc32_aligned_over_stock"], 16))

    def test_refused_before_the_case_until_pinned(self):
        code, stderr = run_until_case(argv())
        self.assertEqual(code, 2, stderr)
        self.assertIn("not in pins.WISP_IMAGES", stderr)

    def test_with_the_proposed_pin_the_gate_accepts_it(self):
        images, passed = proposed_tables()
        with mock.patch.object(pins, "WISP_IMAGES", images), mock.patch.object(pins, "WISP_BOOT_PASSED", passed):
            facts = native.resolve(self.data, self.elf, self.map, PROPOSED["image"]["image_sha256"][:12])
            self.assertEqual(facts["name"], "stage-0b")
            self.assertEqual(facts["end"], PROPOSED["end"])
            reached, stderr = run_until_case(argv())
            self.assertIs(reached, True, stderr)
            raw = bytearray(self.data)
            raw[0x100] ^= 1
            with self.assertRaises(native.NativeRefused):
                native.resolve(bytes(raw), self.elf, self.map, PROPOSED["image"]["image_sha256"][:12])


if __name__ == "__main__":
    unittest.main()
