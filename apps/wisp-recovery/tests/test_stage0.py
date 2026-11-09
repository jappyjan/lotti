# SPDX-License-Identifier: MIT
"""stage-0 (docs/wisp/rung4.md W24b), pinned at W24b-0 after its independent review: the committed
files in wisp_w18/data/stage-0/ are the pinned ones, agree with their manifest and pass rule 3 in
both implementations; install-wisp's whole gate before the case accepts them, and a one-byte
change to any of them is refused before the case. No hardware."""

import hashlib
import json
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_install_wisp import Case, run, run_until_case, running_app, temple
from wisp_w18 import image, native, pins

STAGE_0 = native.STAGE_0_FILES
STAGE_0_SHA = "fc267e0b0de465f229afa5aab739ea20dc9c8b71856a7b13c65a1d446fe85c40"
SLOT = "7a5c399bdfeb05a0683f8ef9fba4452cc4147e22b57de55e2c9754227117b185"


def stage_0_argv(paths=None, expect="fc267e0b0de4", battery="95"):
    paths = paths or STAGE_0
    return ["install-wisp", "--side", "left", "--image", str(paths["image"]), "--elf", str(paths["elf"]),
            "--map", str(paths["map"]), "--expect", expect, "--battery", battery]


class Stage0(unittest.TestCase):
    def setUp(self):
        self.data = STAGE_0["image"].read_bytes()
        self.elf = STAGE_0["elf"].read_bytes()
        self.map = STAGE_0["map"].read_bytes()
        self.manifest = json.loads((native.STAGE_0_DIR / "manifest.json").read_text())

    def test_pinned_with_its_wisp_boot(self):
        pin = pins.WISP_IMAGES["stage-0"]
        self.assertEqual(pin["image_sha256"], STAGE_0_SHA)
        self.assertEqual(pin["image_bytes"], 70_744)
        self.assertEqual(set(pin["gates"]), set(pins.WISP_GATES))
        self.assertEqual(pin["wisp_boot_slot_sha256"], SLOT)
        self.assertEqual(set(pins.WISP_BOOT_PASSED[SLOT]["suites"]), set(pins.WISP_BOOT_SUITES))
        self.assertEqual(pins.WISP_BOOT_PASSED[SLOT]["wisp_boot_bin_sha256"], self.manifest["wisp_boot_bin_sha256"])

    def test_the_committed_files_are_the_pinned_ones(self):
        pin = pins.WISP_IMAGES["stage-0"]
        self.assertEqual(image.sha(self.data), pin["image_sha256"])
        self.assertEqual(len(self.data), pin["image_bytes"])
        self.assertEqual(zlib.crc32(self.data), pin["crc32"])
        self.assertEqual(image.sha(self.data[: pins.WISP_BOOT_SLOT_BYTES]), pin["wisp_boot_slot_sha256"])
        self.assertEqual(image.sha(self.elf), pin["elf_sha256"])
        self.assertEqual(image.sha(self.map), pin["map_sha256"])
        for needle in (b"/home/", b"/nix/store/", b"/tmp/"):  # the stripped ELF names no build path
            self.assertNotIn(needle, self.elf)

    def test_files_match_the_manifest(self):
        m, pin = self.manifest, pins.WISP_IMAGES["stage-0"]
        self.assertEqual((m["image"], m["bytes"], m["image_sha256"]), ("stage-0", len(self.data), image.sha(self.data)))
        self.assertEqual(m["app_map_sha256"], hashlib.sha256(self.map).hexdigest())
        self.assertEqual(int(m["image_crc32"], 16), pin["crc32"])
        self.assertTrue(m["wisp_boot_observe_only"] and m["app_bare_metal"] and m["app_hardware_image"])
        self.assertEqual(m["wisp_boot_slot_sha256"], image.sha(self.data[: pins.WISP_BOOT_SLOT_BYTES]))
        self.assertGreater(native.elf_matches(self.elf, self.data), 0)

    def test_rule3_in_both_implementations(self):
        checks = native.rule3(self.data)
        self.assertTrue(checks and all(c["ok"] for c in checks), checks)
        self.assertEqual({c["by"] for c in checks}, {"port", "wisp-ota"})

    def test_the_crc_install_wisp_reports_over_stock(self):
        """19b3e002: stage-0 plus the 8 stock bytes after it, the aligned region install-wisp
        CRCs at the end of W24b step 4. Needs the stock bundle in .wisp-cache (rule 9)."""
        try:
            stock = image.stock_main()
        except (image.ImageError, OSError) as error:
            self.skipTest(f"no stock 2.4.0.24 bundle: {error}")
        end = (len(self.data) + 15) & ~15
        self.assertEqual(zlib.crc32(self.data + stock[len(self.data):end]),
                         pins.WISP_IMAGES["stage-0"]["crc32_aligned_over_stock"])

    def test_resolve_accepts_the_committed_image(self):
        facts = native.resolve(self.data, self.elf, self.map, STAGE_0_SHA[:12])
        self.assertEqual(facts["name"], "stage-0")
        self.assertEqual(facts["end"], "0x449460")
        self.assertEqual(facts["wisp_boot_sha256"], SLOT)
        self.assertEqual(facts["wisp_boot"]["wisp_boot_bin_sha256"][:8], "b54ee856")

    def test_the_whole_gate_before_the_case_accepts_it(self):
        for argv in (stage_0_argv(), stage_0_argv(battery="3950mV")):
            reached, stderr = run_until_case(argv)
            self.assertIs(reached, True, stderr)

    def test_a_one_byte_change_to_any_file_is_refused_before_the_case(self):
        for which, at in (("image", 0x100), ("image", 0x2C00), ("image", 0xFFFF), ("image", 0x1_0000),
                          ("image", 70_743), ("elf", None), ("map", None)):
            with self.subTest(which=which, at=at), tempfile.TemporaryDirectory() as tmp:
                paths = {k: Path(tmp) / v.name for k, v in STAGE_0.items()}
                for k, v in STAGE_0.items():
                    paths[k].write_bytes(v.read_bytes())
                raw = bytearray(paths[which].read_bytes())
                raw[at if at is not None else len(raw) // 2] ^= 0x01
                paths[which].write_bytes(raw)
                code, stderr = run_until_case(stage_0_argv(paths))
                self.assertEqual(code, 2, stderr)
                self.assertIn("REFUSED", stderr)

    def test_expect_and_battery_are_still_required(self):
        for argv in (stage_0_argv(expect="fc267e0b"), stage_0_argv(expect="fc267e0b0de5"),
                     stage_0_argv(expect=STAGE_0_SHA[:11]), stage_0_argv(battery="79"),
                     stage_0_argv(battery="3800mV")):
            with self.subTest(argv=argv[-4:]):
                code, stderr = run_until_case(argv)
                self.assertEqual(code, 2, stderr)

    def test_a_fake_install_writes_it_whole(self):
        mram = temple(running_app())
        code, report, stderr = run(stage_0_argv(), Case(mram))
        self.assertEqual(code, 0, stderr)
        self.assertEqual(mram.read(pins.APP_BASE, len(self.data)), self.data)
        self.assertEqual(report["image"]["name"], "stage-0")
        self.assertTrue(all(r["ok"] for r in report["rule3"]))


if __name__ == "__main__":
    unittest.main()
