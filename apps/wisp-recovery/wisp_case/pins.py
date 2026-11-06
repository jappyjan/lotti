# SPDX-License-Identifier: MIT
"""Pinned facts for recovery step 0. Every number here comes from a cited source.

Sources (both MIT; see ../NOTICE.md):
  [W] AM-Guru/evenRealities-webflasher @ 2fcdb88: src/lib/pogoBridge.js, src/lib/serial.js
  [D] drdaeman/g2-bootloader-patch @ 1d22097: tools/g2patch/case_rom.py, link.py, data/case.json
  [S] our own disassembly of the pinned bridge and of the case 1.2.57 image (docs/wisp/recovery.md)
"""

from __future__ import annotations

import hashlib
from pathlib import Path

DATA = Path(__file__).with_name("data")

# --- The case (STM32G0B1) and its immutable ROM loader [D case_rom.py, W serial.js] ---------
ROM_BAUD = 115_200  # 8E1
ROM_PROTOCOL_VERSION = 0x31
ROM_PRODUCT_ID = 0x0467  # STM32G0B1/G0C1
ROM_EXPECTED_COMMANDS = frozenset(
    (0x00, 0x01, 0x02, 0x11, 0x21, 0x31, 0x44, 0x63, 0x73, 0x82, 0x92)
)
ACK, NACK, SYNC = 0x79, 0x1F, 0x7F

# The only ROM commands this tool can ever emit. Everything else is refused before a byte
# is written: 0x43/0x44 erase, 0x63/0x73 write-(un)protect, 0x82/0x92 readout-(un)protect.
ROM_GET, ROM_GET_ID, ROM_READ_MEMORY, ROM_GO, ROM_WRITE_MEMORY = 0x00, 0x02, 0x11, 0x21, 0x31
ROM_COMMAND_ALLOWLIST = frozenset((ROM_GET, ROM_GET_ID, ROM_READ_MEMORY, ROM_GO, ROM_WRITE_MEMORY))

# The case application in flash: B200 1.2.57, the image shipped in every bundle from
# 2.2.0.24 to 2.3.2.14 (and unchanged in 2.4.0.24, docs/wisp/hardware.md). We hash the
# flash read back through the ROM and only jump into the bridge if it is exactly this,
# because the bridge calls nine functions inside it by address [S].
CASE_VERSION = "1.2.57"
CASE_IMAGE_BASE = 0x0800_0000
CASE_IMAGE_LENGTH = 55_752
CASE_IMAGE_SHA256 = "773b6d4cfdaf0a5a74a557e3babe8222a0ae813436b76a7437c1096d2c60d677"  # [D]

# Normal case console (after a reset with boot-select released) [D restore_application].
CONSOLE_BAUD = 1_000_000  # 8N1
CONSOLE_BANNER = rb"\*{6} B200 ([0-9]+\.[0-9]+\.[0-9]+) "
CONSOLE_POWER_UP = b"Power up..."

# --- The volatile bridge in case SRAM [W pogoBridge.js] -------------------------------------
BRIDGE_ADDRESS = 0x2001_0000
BRIDGE_LENGTH = 1720
BRIDGE_SHA256 = "e30e143d522e5a5d0b10a92a15610badcc6aef014333716a94eae183b14dc258"
BRIDGE_BANNER = b"G2_POGO_BRIDGE_V1\n"
RESULT_ADDRESS, RESULT_LENGTH = 0x2001_1A00, 160
PROOF_ADDRESS = 0x2001_1B00
PROOF = bytes.fromhex("47425250dec0dec0")  # "GBRP" + 0xC0DEC0DE, written just before its reset

# Exactly these SRAM ranges may be written through the ROM, nothing else. Flash
# (0x08000000...) and option bytes (0x1FFF7800) are outside them by construction.
SRAM_WRITE_REGIONS = (
    (BRIDGE_ADDRESS, BRIDGE_LENGTH),
    (RESULT_ADDRESS, RESULT_LENGTH),
    (PROOF_ADDRESS, len(PROOF)),
)

# Host request "G2RQ", v1, operation, route, sequence, 0, sum. Bridge operations [W]:
#   1 = temple status (0x13), 2 = temple version (0x24), 0x7F = no-contact exit self-test.
# Each operation makes the bridge transmit one fixed request embedded in its own image;
# no host byte ever reaches the temple. Offsets into the pinned bridge [S]:
BRIDGE_OP_VERSION = 2
TEMPLE_REQUESTS = {
    # bridge op: (offset in bridge, length, temple opcode, name)
    BRIDGE_OP_VERSION: (0x66C, 5, 0x24, "version"),
}
ROUTES = {"left": 0, "right": 1}

# Read-only allowlist, enforced in bridge.make_request and checked against the image bytes.
# 0x24 = "version": the temple's main app answers with its firmware version and hardware
# revision (5A A5 FF 09 24 .. v0 v1 v2 v3 hw sum). Hardware-observed by the webflasher on
# both temples [W README "Version 0x24"]. Status (0x13) is also a query, but its request
# carries bytes we cannot explain (e4 01), so it stays out.
TEMPLE_READ_ONLY_OPCODES = frozenset((0x24,))
BRIDGE_OPERATION_ALLOWLIST = frozenset(TEMPLE_REQUESTS)

BRIDGE_STATUS = {
    0: "ok",
    1: "bad host request",
    2: "operation or route rejected",
    3: "YHM baseline was not an allowlisted seated-idle state (zero writes, nothing sent)",
    4: "YHM route selection failed",
    5: "temple request transmission failed",
    6: "no framed temple response",
    7: "YHM baseline restoration failed",
    16: "host request timeout",
}


def bridge_image() -> bytes:
    image = (DATA / "pogo_bridge.bin").read_bytes()
    if len(image) != BRIDGE_LENGTH or hashlib.sha256(image).hexdigest() != BRIDGE_SHA256:
        raise ValueError("pinned bridge image failed its SHA-256 check")
    return image
