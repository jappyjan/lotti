# SPDX-License-Identifier: MIT
"""stage-0 (docs/wisp/rung4.md W24b), the committed but unpinned files in wisp_w18/data/stage-0/:
install-wisp's gate refuses them until a reviewed commit pins them, they agree with their
manifest, and they pass rule 3 in both implementations. No hardware."""

import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from wisp_w18 import image, native, pins

DIR = Path(__file__).resolve().parents[1] / "wisp_w18/data/stage-0"


class Stage0(unittest.TestCase):
    def setUp(self):
        self.data = (DIR / "stage-0.bin").read_bytes()
        self.elf = (DIR / "stage0.elf").read_bytes()
        self.map = (DIR / "stage0.map").read_bytes()
        self.manifest = json.loads((DIR / "manifest.json").read_text())

    def test_not_pinned_so_install_wisp_refuses_it(self):
        self.assertNotIn(image.sha(self.data), [p["image_sha256"] for p in pins.WISP_IMAGES.values()])
        with self.assertRaises(native.NativeRefused) as refused:
            native.resolve(self.data, self.elf, self.map, image.sha(self.data)[:12])
        self.assertIn("not in pins.WISP_IMAGES", str(refused.exception))

    def test_files_match_the_manifest(self):
        m = self.manifest
        self.assertEqual((m["image"], m["bytes"], m["image_sha256"]), ("stage-0", len(self.data), image.sha(self.data)))
        self.assertEqual(m["app_map_sha256"], hashlib.sha256(self.map).hexdigest())
        self.assertTrue(m["wisp_boot_observe_only"] and m["app_bare_metal"])
        self.assertEqual(m["wisp_boot_slot_sha256"], image.sha(self.data[: pins.WISP_BOOT_SLOT_BYTES]))
        self.assertGreater(native.elf_matches(self.elf, self.data), 0)

    def test_rule3_in_both_implementations(self):
        checks = native.rule3(self.data)
        self.assertTrue(checks and all(c["ok"] for c in checks), checks)


if __name__ == "__main__":
    unittest.main()
