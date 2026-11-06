# SPDX-License-Identifier: MIT
"""Unit tests for the post-build gates (scripts/check_image.py, scripts/check_rule8.py) on
synthetic inputs. Run by scripts/test.sh."""

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import check_image as ci  # noqa: E402
import check_rule8 as r8  # noqa: E402
import wisp_layout as L  # noqa: E402


def image(sp=0x2008_1740, reset=0x0043_a375, size=0x4000):
    return struct.pack("<II", sp, reset) + bytes(size - 8)


class CheckImage(unittest.TestCase):
    def test_good(self):
        self.assertEqual(ci.check_vectors(L.APP_LOAD_ADDR, image()), [])

    def test_wrong_load_address(self):
        self.assertTrue(ci.check_vectors(0x0041_0000, image(reset=0x0041_0101)))

    def test_end_limit(self):
        size = L.APP_END_LIMIT - L.APP_LOAD_ADDR
        self.assertEqual(ci.check_vectors(L.APP_LOAD_ADDR, image(size=size)), [])
        errs = ci.check_vectors(L.APP_LOAD_ADDR, image(size=size + 4))
        self.assertTrue(any("image end" in e for e in errs), errs)

    def test_sp_outside_sram(self):
        for sp in (0x0043_8000, 0x2000_0000, 0x2038_0004, 0x6000_0000):
            self.assertTrue(ci.check_vectors(L.APP_LOAD_ADDR, image(sp=sp)), hex(sp))
        self.assertEqual(ci.check_vectors(L.APP_LOAD_ADDR, image(sp=0x2038_0000)), [])
        self.assertEqual(ci.check_vectors(L.APP_LOAD_ADDR, image(sp=0x2007_fb00)), [])

    def test_sp_misaligned(self):
        self.assertTrue(ci.check_vectors(L.APP_LOAD_ADDR, image(sp=0x2008_1744)))

    def test_reset_not_thumb(self):
        errs = ci.check_vectors(L.APP_LOAD_ADDR, image(reset=0x0043_a374))
        self.assertTrue(any("Thumb" in e for e in errs), errs)

    def test_reset_outside_image(self):
        for reset in (0x0041_0001, 0x0043_c001, 0x0000_0041):
            errs = ci.check_vectors(L.APP_LOAD_ADDR, image(reset=reset))
            self.assertTrue(any("outside" in e for e in errs), (hex(reset), errs))

    def test_segments(self):
        self.assertEqual(ci.check_segments([(0x0043_8000, 0x1000), (0x2008_0000, 0)]), [])
        self.assertTrue(ci.check_segments([(0x0041_0000, 0x10)]))      # Even bootloader
        self.assertTrue(ci.check_segments([(0x0043_7FE0, 0x20)]))      # preamble: wisp-ota's
        self.assertTrue(ci.check_segments([(0x007F_E000, 0x10)]))      # update flag
        self.assertTrue(ci.check_segments([(0x007F_7FF0, 0x20)]))      # crosses the ceiling
        self.assertTrue(ci.check_segments([(0x2008_0000, 0x10)]))      # loads into RAM


class CheckRule8(unittest.TestCase):
    def test_config(self):
        self.assertEqual(r8.check_config({"CONFIG_BT": "n"}), [])
        self.assertTrue(r8.check_config({"CONFIG_BT": "y"}))
        self.assertTrue(r8.check_config({"CONFIG_AMBIQ_COMPONENT_USE_BT": "y"}))
        self.assertTrue(r8.check_config({"CONFIG_SOC_APOLLO510B_EM9305_EXTREF_INIT": "y"}))
        self.assertTrue(r8.check_config({"CONFIG_BT_AMBIQ_EM9305_HF_CRYSTAL_CUSTOM_TRIM": "y"}))
        self.assertTrue(r8.check_config({"CONFIG_BT": "y", "CONFIG_WISP_BT_ALLOWED": "y"}))
        self.assertEqual(r8.check_config({"CONFIG_BT": "y", "CONFIG_WISP_BT_ALLOWED": "y",
                                          "CONFIG_WISP_EM9305_SKIP_FW_UPDATE": "y"}), [])

    def test_symbols(self):
        clean = ["main", "z_arm_reset", "uart_ambiq_init"]
        self.assertEqual(r8.check_symbols(clean, bt=False), [])
        for bad in ("ble_fw_image_bin_00302400", "am_devices_em9305_update_fw",
                    "fw_write_image.constprop.0", "em9305_nvm_recovery_reflash"):
            self.assertTrue(r8.check_symbols(clean + [bad], bt=True), bad)
        self.assertTrue(r8.check_symbols(["am_devices_em9305_init"], bt=False))
        self.assertEqual(r8.check_symbols(["am_devices_em9305_init"], bt=True), [])

    def test_sources(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            good = d / "good.c"
            good.write_text("am_devices_em9305_callback_t cb = {.skip_fw_update = true};\n"
                            "am_devices_em9305_init(&cb);\n")
            unset = d / "unset.c"
            unset.write_text("am_devices_em9305_callback_t cb = {.reset = r};\n"
                             "am_devices_em9305_init(&cb);\n")
            cond = d / "cond.c"
            cond.write_text("cb.skip_fw_update = IS_ENABLED(CONFIG_BT);\n"
                            "am_devices_em9305_init(&cb);\n")
            driver = d / "am_devices_em9305.c"
            driver.write_text("uint32_t am_devices_em9305_init(void) {}\n")
            cc = d / "compile_commands.json"

            def run(files, bt):
                cc.write_text(json.dumps([{"file": str(f)} for f in files]))
                return r8.check_sources(cc, bt)

            self.assertEqual(run([good], bt=True), [])
            self.assertTrue(run([unset], bt=True))
            self.assertTrue(run([cond], bt=True))
            self.assertTrue(run([driver], bt=False))
            self.assertEqual(run([driver, good], bt=True), [])

    def test_map(self):
        with tempfile.TemporaryDirectory() as d:
            m = Path(d) / "zephyr.map"
            m.write_text("Discarded input sections\n .text x am_devices_em9305.c.obj\n"
                         "Linker script and memory map\n .text 0x438000 main.c.obj\n")
            self.assertEqual(r8.check_map(m), [])
            m.write_text("Linker script and memory map\n .text 0x438000 "
                         "libhal.a(am_devices_em9305.c.obj)\n")
            self.assertTrue(r8.check_map(m))

    def test_bytes(self):
        sig = bytes(range(64))
        self.assertEqual(r8.check_bytes(b"\0" * 256, [("x", sig)]), [])
        self.assertTrue(r8.check_bytes(b"\0" * 100 + sig + b"\0", [("x", sig)]))


if __name__ == "__main__":
    unittest.main()
