# SPDX-License-Identifier: MIT
"""The read-only / RAM-only allowlists refuse everything else, before a byte is sent."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from wisp_case import bridge as br  # noqa: E402
from wisp_case import pins  # noqa: E402
from wisp_case.rom import RefusedError, RomLoader, check_sram_write  # noqa: E402

BRIDGE = pins.bridge_image()


class RecordingPort:
    def __init__(self):
        self.written = bytearray()

    def write(self, data):
        self.written += data

    def flush(self):
        pass

    def read(self, n):
        return b"\x79" * n  # would ACK anything: refusal must happen before sending


class RomCommandAllowlist(unittest.TestCase):
    def test_only_five_commands(self):
        self.assertEqual(pins.ROM_COMMAND_ALLOWLIST, {0x00, 0x02, 0x11, 0x21, 0x31})

    def test_destructive_commands_refused_without_a_byte_sent(self):
        # erase, extended erase, write-protect, write-unprotect, readout-protect/unprotect,
        # plus Get Version (unused) and a few arbitrary values.
        for command in (0x43, 0x44, 0x63, 0x73, 0x82, 0x92, 0x01, 0x03, 0xFF):
            port = RecordingPort()
            with self.assertRaises(RefusedError, msg=hex(command)):
                RomLoader(port, BRIDGE)._command(command, "test")
            self.assertEqual(port.written, b"", hex(command))

    def test_go_only_after_verified_bridge(self):
        port = RecordingPort()
        with self.assertRaises(RefusedError):
            RomLoader(port, BRIDGE).go_bridge()
        self.assertEqual(port.written, b"")


class SramWriteAllowlist(unittest.TestCase):
    def refused(self, address, data):
        with self.assertRaises(RefusedError):
            check_sram_write(address, data, BRIDGE)
        port = RecordingPort()
        with self.assertRaises(RefusedError):
            RomLoader(port, BRIDGE).write_sram(address, data)
        self.assertEqual(port.written, b"")

    def test_flash_and_option_bytes_refused(self):
        self.refused(0x0800_0000, bytes(256))  # case application flash, bank 1
        self.refused(0x0804_0000, bytes(4))  # bank 2
        self.refused(0x1FFF_7800, bytes(4))  # option bytes
        self.refused(0x1FFF_0000, bytes(4))  # system memory

    def test_other_sram_refused(self):
        self.refused(0x2000_0000, bytes(4))  # case app variables
        self.refused(pins.BRIDGE_ADDRESS - 4, bytes(8))  # straddles the start
        self.refused(pins.BRIDGE_ADDRESS + pins.BRIDGE_LENGTH - 4, bytes(8))  # straddles the end
        self.refused(pins.RESULT_ADDRESS + 156, bytes(8))
        self.refused(pins.PROOF_ADDRESS + 8, bytes(4))

    def test_content_must_be_bridge_or_zeros(self):
        self.refused(pins.BRIDGE_ADDRESS, bytes(BRIDGE[4:8]) + bytes(BRIDGE[4:8]))
        patched = bytearray(BRIDGE[:256])
        patched[0x80] ^= 1
        self.refused(pins.BRIDGE_ADDRESS, bytes(patched))
        self.refused(pins.RESULT_ADDRESS, b"\x01\x00\x00\x00")
        self.refused(pins.PROOF_ADDRESS, pins.PROOF)  # only the bridge itself writes its proof

    def test_alignment_and_size(self):
        self.refused(pins.RESULT_ADDRESS + 2, bytes(4))
        self.refused(pins.RESULT_ADDRESS, bytes(3))
        self.refused(pins.RESULT_ADDRESS, b"")

    def test_allowed(self):
        for offset in range(0, pins.BRIDGE_LENGTH, 256):
            chunk = BRIDGE[offset : offset + 256]
            check_sram_write(pins.BRIDGE_ADDRESS + offset, chunk, BRIDGE)
            check_sram_write(pins.BRIDGE_ADDRESS + offset, bytes(len(chunk)), BRIDGE)
        check_sram_write(pins.RESULT_ADDRESS, bytes(160), BRIDGE)
        check_sram_write(pins.PROOF_ADDRESS, bytes(8), BRIDGE)


class BridgeOperationAllowlist(unittest.TestCase):
    def test_only_version(self):
        self.assertEqual(pins.BRIDGE_OPERATION_ALLOWLIST, {2})
        self.assertEqual(pins.TEMPLE_READ_ONLY_OPCODES, {0x24})

    def test_other_operations_refused(self):
        # 1 = status, 0x7F = exit self-test, anything else is not a bridge operation;
        # 0x52..0x55 are the temple's OTA commands and must never get near the bridge.
        for operation in (0, 1, 3, 0x13, 0x52, 0x53, 0x54, 0x55, 0x7F, 0xFF):
            with self.assertRaises(RefusedError, msg=hex(operation)):
                br.make_request(operation, "left", BRIDGE)

    def test_routes(self):
        with self.assertRaises(RefusedError):
            br.make_request(2, "both", BRIDGE)

    def test_version_request_bytes(self):
        # Same vector as evenRealities-webflasher tests/firmware.test.mjs.
        self.assertEqual(br.make_request(2, "left", BRIDGE).hex(), "4732525101020042" "0061")
        self.assertEqual(br.make_request(2, "right", BRIDGE)[6], 1)

    def test_temple_bytes_come_from_the_pinned_image(self):
        self.assertEqual(br.temple_request(2, BRIDGE).hex(), "24000100a7")

    def test_tampered_image_refused(self):
        offset = pins.TEMPLE_REQUESTS[2][0]
        for opcode in (0x52, 0x13, 0x00):
            tampered = bytearray(BRIDGE)
            tampered[offset] = opcode
            with self.assertRaises(RefusedError, msg=hex(opcode)):
                br.make_request(2, "left", bytes(tampered))


class Pins(unittest.TestCase):
    def test_bridge_pin(self):
        self.assertEqual(len(BRIDGE), 1720)
        self.assertEqual(BRIDGE[0x648 : 0x648 + 18], pins.BRIDGE_BANNER)

    def test_regions_disjoint_and_in_sram(self):
        spans = sorted(pins.SRAM_WRITE_REGIONS)
        for (a, n), (b, _m) in zip(spans, spans[1:]):
            self.assertLessEqual(a + n, b)
        for a, n in spans:
            self.assertTrue(0x2000_0000 <= a and a + n <= 0x2002_4000)


if __name__ == "__main__":
    unittest.main()
