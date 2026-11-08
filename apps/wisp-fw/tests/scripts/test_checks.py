# SPDX-License-Identifier: MIT
"""Unit tests for the post-build gates (scripts/check_image.py, scripts/check_rule8.py,
scripts/check_no_mram_write.py, scripts/check_native.py) on synthetic inputs. Run by
scripts/test.sh."""

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import check_image as ci  # noqa: E402
import check_native as cn  # noqa: E402
import check_no_mram_write as nm  # noqa: E402
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

    def test_map_bt_on(self):
        with tempfile.TemporaryDirectory() as d:
            m = Path(d) / "zephyr.map"
            m.write_text("Linker script and memory map\n .text.am_devices_em9305_init\n"
                         "                0x00440000       0x40 libhal.a(am_devices_em9305.c.obj)\n")
            self.assertEqual(r8.check_map(m, bt=True), [])
            for sec in (".text.fw_erase_nvm_main", ".rodata.ble_fw_image_bin_00302400",
                        ".text.am_devices_em9305_update_fw.constprop.0", ".bss.g_cm_pwm_ctrl"):
                m.write_text(f"Linker script and memory map\n {sec}\n   0x440000 0x10 x.o\n")
                self.assertTrue(r8.check_map(m, bt=True), sec)

    def test_config_public_addr(self):
        ok = {"CONFIG_BT": "y", "CONFIG_WISP_BT_ALLOWED": "y", "CONFIG_WISP_EM9305_SKIP_FW_UPDATE": "y"}
        self.assertEqual(r8.check_config(ok), [])
        self.assertTrue(r8.check_config({**ok, "CONFIG_BT_HCI_SET_PUBLIC_ADDR": "y"}))

    def test_units(self):
        """Preprocessed units: the compiled code, not the source text, decides."""
        opcodes = {"HCI_VSC_WRITE_AT_ADDRESS_OPCODE": 0xFD03, "HCI_VSC_NVM_ERASE_NVM_MAIN_OPCODE": 0xFD06,
                   "HCI_VSC_NVM_ERASE_PAGE_OPCODE": 0xFD07, "HCI_VSC_SET_DEV_PUB_ADDR_CMD_OPCODE": 0xFC43}
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "ble_fw_image_em9305.h").write_text("static const int ble_fw_image_bin_0 = 1;\n")
            (d / "am_devices_em9305.h").write_text(
                "typedef struct { int skip_fw_update; } am_devices_em9305_callback_t;\n"
                "unsigned am_devices_em9305_init(am_devices_em9305_callback_t *cb);\n")
            patched = d / "am_devices_em9305.c"
            caller = d / "caller.c"
            cc = d / "compile_commands.json"

            def run(driver_src, caller_src):
                patched.write_text(driver_src)
                caller.write_text(caller_src)
                cc.write_text(json.dumps([
                    {"directory": str(d), "file": str(f), "arguments": ["cc", f"-I{d}", "-c", str(f), "-o", str(f) + ".o"]}
                    for f in (patched, caller)]))
                return r8.check_units(cc, opcodes)

            good_driver = ('#include "am_devices_em9305.h"\n#define WISP_EM9305_NO_NVM_WRITE 1\n'
                           '#if defined(WISP_EM9305_NVM_WRITE)\n#include "ble_fw_image_em9305.h"\n'
                           'static void fw_erase_nvm_main(void) { int op = 0xFD06U; }\n#endif\n'
                           'unsigned am_devices_em9305_init(am_devices_em9305_callback_t *cb) '
                           '{ cb->skip_fw_update = 1; return 0; }\n')
            good_caller = ('#include "am_devices_em9305.h"\nvoid f(void) { am_devices_em9305_callback_t cb = '
                           '{ .skip_fw_update = true }; am_devices_em9305_init(&cb); }\n')
            self.assertEqual(run(good_driver, good_caller.replace("true", "1")), [])

            # the unpatched driver: no marker, includes the image, erase code and opcode compiled
            bad = good_driver.replace("#define WISP_EM9305_NO_NVM_WRITE 1\n", "").replace(
                "#if defined(WISP_EM9305_NVM_WRITE)\n", "").replace("#endif\n", "")
            errs = run(bad, good_caller.replace("true", "1"))
            for want in ("patch is not in", "includes ble_fw_image_em9305.h", "fw_erase_nvm_main",
                         "HCI_VSC_NVM_ERASE_NVM_MAIN_OPCODE"):
                self.assertTrue(any(want in e for e in errs), (want, errs))

            # a caller that leaves skip_fw_update unset, or sets it at run time
            for src in ('#include "am_devices_em9305.h"\nvoid f(void) { am_devices_em9305_callback_t cb = {0};'
                        ' am_devices_em9305_init(&cb); }\n',
                        '#include "am_devices_em9305.h"\nint bt; void f(void) { am_devices_em9305_callback_t cb;'
                        ' cb.skip_fw_update = bt; am_devices_em9305_init(&cb); }\n'):
                self.assertTrue(any("force skip_fw_update" in e for e in run(good_driver, src)), src)

            # a macro that hides the value from a text search is still seen after preprocessing
            sneaky = ('#include "am_devices_em9305.h"\n#define NO 0\nvoid f(void) { am_devices_em9305_callback_t cb'
                      ' = { .skip_fw_update = NO }; am_devices_em9305_init(&cb); }\n')
            self.assertTrue(any("force skip_fw_update" in e for e in run(good_driver, sneaky)))

            # a caller that sends the public-address vendor command
            vsc = good_caller.replace("true", "1").replace("}\n", " int op = 0xFC43; }\n")
            self.assertTrue(any("HCI_VSC_SET_DEV_PUB_ADDR_CMD_OPCODE" in e for e in run(good_driver, vsc)))

    def test_code(self):
        opcodes = {"HCI_VSC_NVM_ERASE_NVM_MAIN_OPCODE": 0xFD06}
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d) / "objdump"

            def run(listing):
                fake.write_text("#!/bin/sh\ncat <<'X'\n" + listing + "X\n")
                fake.chmod(0o755)
                return r8.check_code(str(fake), Path(d) / "zephyr.elf", opcodes)

            clean = "00440000 <f>:\n  440000:\tf64f 5303 \tmovw\tr3, #64771\t@ 0xfd03\n"
            self.assertEqual(run(clean), [])
            self.assertTrue(run("00440000 <g>:\n  440000:\tf64f 5306 \tmovw\tr3, #64774\t@ 0xfd06\n"))
            self.assertTrue(run("00440000 <h>:\n  440010:\t0000fd06 \t.word\t0x0000fd06\n"))

    def test_bytes(self):
        sig = bytes(range(64))
        self.assertEqual(r8.check_bytes(b"\0" * 256, [("x", sig)]), [])
        self.assertTrue(r8.check_bytes(b"\0" * 100 + sig + b"\0", [("x", sig)]))



class CheckAppPart(unittest.TestCase):
    """--part app: the Wisp app at 0x448000, its SP and RAM below Wisp Boot's (rung4.md G6)."""

    def test_app_base(self):
        app = image(sp=0x2009_2c18, reset=0x0044_8a69)
        self.assertEqual(ci.check_vectors(L.WISP_MAIN_BASE, app, L.WISP_MAIN_BASE, L.WISP_BOOT_RAM_BASE), [])
        self.assertTrue(ci.check_vectors(L.APP_LOAD_ADDR, app, L.WISP_MAIN_BASE, L.WISP_BOOT_RAM_BASE))

    def test_app_sp_in_boot_ram(self):
        app = image(sp=0x2037_8000, reset=0x0044_8101)
        self.assertTrue(ci.check_vectors(L.WISP_MAIN_BASE, app, L.WISP_MAIN_BASE, L.WISP_BOOT_RAM_BASE))

    def test_ram_sections(self):
        self.assertEqual(ci.check_ram([("bss", 0x2008_0000, 0x1000), ("nocache", 0x2020_0000, 0x17_0000)]), [])
        self.assertTrue(ci.check_ram([("noinit", 0x2036_ff00, 0x200)]))
        self.assertEqual(ci.check_ram([("text", 0x0044_8000, 0x8000)]), [])


class CheckNative(unittest.TestCase):
    def test_combined(self):
        boot = image(sp=0x2038_0000, reset=0x0043_8475, size=0x2000)
        app = image(sp=0x2009_0000, reset=0x0044_9001, size=0x3000)
        img = boot + b"\xff" * (0x10000 - len(boot)) + app
        self.assertEqual(cn.check(img, boot, app), [])
        self.assertTrue(cn.check(img[:-1], boot, app))                       # app cut
        self.assertTrue(cn.check(boot + b"\0" * (0x10000 - len(boot)) + app, boot, app))  # padding
        bad_app = image(sp=0x2037_0008, reset=0x0044_9001, size=0x3000)
        self.assertTrue(cn.check(boot + b"\xff" * (0x10000 - len(boot)) + bad_app, boot, bad_app))


class CheckNativeFacts(unittest.TestCase):
    def test_app_config(self):
        good = "CONFIG_WISP_HW_IMAGE=y\nCONFIG_WISP_IMAGE_KIND=0\nCONFIG_DT_HAS_AMBIQ_UART_ENABLED=y\n"
        self.assertEqual(cn.check_app_config(good), [])
        self.assertTrue(cn.check_app_config("CONFIG_WISP_IMAGE_KIND=0\n"))
        self.assertTrue(cn.check_app_config(good.replace("=0", "=255")))
        self.assertTrue(cn.check_app_config(good + "CONFIG_DT_HAS_NORDIC_NPM1300_CHARGER_ENABLED=y\n"))
        self.assertTrue(cn.check_app_config(good + "CONFIG_DT_HAS_AMBIQ_MSPI_CONTROLLER_ENABLED=y\n"))

    def test_boot_symbols(self):
        self.assertEqual(cn.check_boot_symbols(["nor_read", "lfs_file_read", "wisp_boot_main"]), [])
        for bad in ("nor_prog", "lfs_file_write", "hw_flag_set_install", "rescue_copy.constprop.0"):
            self.assertTrue(cn.check_boot_symbols([bad]), bad)


class CheckNoMramWrite(unittest.TestCase):
    def test_symbols(self):
        self.assertEqual(nm.check_symbols(["main", "am_hal_iom_enable", "wisp_boot_link_confirm"]), [])
        for bad in ("am_hal_mram_main_program", "nv_program_main2", "g_am_hal_bootrom_helper",
                    "am_hal_bootrom_helper_init", "am_hal_info0_program", "otp_program_info_area",
                    "flash_ambiq_write", "hw_flag_set_install", "am_hal_mram_main_fill.constprop.0"):
            self.assertTrue(nm.check_symbols([bad]), bad)

    def test_map(self):
        text = ("Discarded input sections\n .text 0x0 0x40 lib.a(am_hal_mram.c.obj)\n"
                "Linker script and memory map\n"
                " .debug_info   0x00000000  0x100 lib.a(am_hal_mram.c.obj)\n"
                " .text.am_hal_info1_read\n                0x0045ba44       0x1a lib.a(am_hal_info.c.obj)\n")
        self.assertEqual(nm.check_map(text), [])
        bad = text + " .text.am_hal_mram_main_program\n                0x00450000       0x80 lib.a(am_hal_mram.c.obj)\n"
        self.assertTrue(nm.check_map(bad))
        bad = text + " .rodata.g_am_hal_bootrom_helper\n                0x00460000       0x20 lib.a(am_hal_bootrom_helper.c.obj)\n"
        self.assertTrue(nm.check_map(bad))

    def test_config(self):
        self.assertEqual(nm.check_config("CONFIG_DT_HAS_AMBIQ_FLASH_CONTROLLER_ENABLED=y\nCONFIG_FLASH_BASE_ADDRESS=0x410000\n"), [])
        self.assertTrue(nm.check_config("CONFIG_FLASH_AMBIQ=y\n"))
        self.assertTrue(nm.check_config("CONFIG_SOC_FLASH_AMBIQ=y\n"))
        self.assertTrue(nm.check_config("CONFIG_AMBIQ_MRAM_WRITE=y\n"))

    def test_bytes(self):
        self.assertEqual(nm.check_bytes(bytes(64)), [])
        for v in (0x12344321, 0x0200FF21, 0x0200FF0D, 0x0200FF54):
            self.assertTrue(nm.check_bytes(b"\x01\x02\x03" + struct.pack("<I", v) + b"\0"), hex(v))
        self.assertEqual(nm.check_bytes(struct.pack("<I", 0x12344321), skip=1), [])

    def test_code(self):
        good = ("00449000 <f>:\n  449000:\tmovw\tr3, #17185\t@ 0x4321\n  449004:\tmovt\tr3, #4661\t@ 0x1235\n")
        self.assertEqual(nm.check_code(good), [])
        bad = ("00449000 <f>:\n  449000:\tmovw\tr3, #17185\t@ 0x4321\n  449004:\tmovt\tr3, #4660\t@ 0x1234\n")
        self.assertTrue(nm.check_code(bad))
        helper = ("00449000 <f>:\n  449000:\tmovw\tip, #65313\n  449004:\tmovt\tip, #512\n")
        self.assertTrue(nm.check_code(helper))
        split = ("00449000 <f>:\n  449000:\tmovw\tr3, #17185\n00449010 <g>:\n  449010:\tmovt\tr3, #4660\n")
        self.assertEqual(nm.check_code(split), [])


if __name__ == "__main__":
    unittest.main()
