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


# --- YHM2510 baseline profiles [W yhmProfiles.js, pogoBridge.js] ----------------------------
# The bridge only touches the pogo route if the 10 registers it reads first equal one of five
# rows baked into its image at 0x674 (10 bytes each). Register 8 (the 9th byte) is, per the
# webflasher, a per-case YHM2510 identity byte that stays constant through charging and
# resets: unrelated cases ship 0x22, 0x33 or 0x45. The reviewed bridge carries 0x22. The
# "observed-33" variant is the same bridge with register 8 patched to 0x33 in rows 2-5,
# exactly as getVerifiedPogoBridgePayload() derives it, and pinned to the webflasher's
# POGO_BRIDGE_OBSERVED_33_SHA256. Jan's case read 811104afaf03812033ff on 2026-11-06.
PROFILE_REVIEWED_22 = "reviewed-22"
PROFILE_OBSERVED_33 = "observed-33"
BASELINE_TABLE_OFFSET = 0x674  # = 1660, row 1
REVIEWED_22_BASELINES = (
    "811104afaf038d2022ff",
    "810004aeae03812022ff",
    "811104afaf03812022ff",
    "810104afae03812022ff",
    "811004aeaf03812022ff",
)
BRIDGE_VARIANTS = {
    # profile: (register-8 value, offsets patched from 0x22, SHA-256 of the result)
    PROFILE_REVIEWED_22: (0x22, (), BRIDGE_SHA256),
    PROFILE_OBSERVED_33: (
        0x33,
        (1670, 1680, 1690, 1700),
        "3ca8ed1d8d37b2edef62dcb6915b5ec4b1d439160da0a89e93aa74901d760ef6",
    ),
}


def profile_baselines(profile: str) -> tuple[str, ...]:
    register8, offsets, _sha = BRIDGE_VARIANTS[profile]
    rows = list(REVIEWED_22_BASELINES)
    for offset in offsets:
        row = (offset - BASELINE_TABLE_OFFSET) // 10
        rows[row] = rows[row][:-4] + f"{register8:02x}ff"
    return tuple(rows)


def identify_profile(baseline_hex: str) -> str | None:
    """The bridge variant whose table holds this exact baseline, or None (fail closed).
    Only the two pinned variants exist; any other register-8 value, or any other byte
    differing, gives None."""
    for profile in BRIDGE_VARIANTS:
        if baseline_hex.lower() in profile_baselines(profile):
            return profile
    return None


def bridge_image(profile: str = PROFILE_REVIEWED_22) -> bytes:
    image = bytearray((DATA / "pogo_bridge.bin").read_bytes())
    if len(image) != BRIDGE_LENGTH or hashlib.sha256(image).hexdigest() != BRIDGE_SHA256:
        raise ValueError("pinned bridge image failed its SHA-256 check")
    register8, offsets, sha = BRIDGE_VARIANTS[profile]
    for offset in offsets:
        if image[offset] != 0x22:
            raise ValueError("bridge baseline table differs from the reviewed layout")
        image[offset] = register8
    if hashlib.sha256(image).hexdigest() != sha:
        raise ValueError(f"{profile} bridge failed its SHA-256 check")
    return bytes(image)
