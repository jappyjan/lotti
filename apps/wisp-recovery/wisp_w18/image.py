# SPDX-License-Identifier: MIT
"""Builds every W18 image from the cached stock bundles and checks it against pins.py.

The patch and component layout follow drdaeman/g2-bootloader-patch @ 1d22097 (MIT),
tools/patch.py and tools/g2patch/firmware.py; the case relay assembly follows
tools/g2patch/artifacts.py prepare_case. Even's bytes are only ever read from the git-ignored
.wisp-cache/ and never written anywhere but RAM and the outputs the caller asks for.
"""

from __future__ import annotations

import hashlib
import struct
import zlib
from pathlib import Path

from . import pins

DATA = Path(__file__).with_name("data")
REPO = Path(__file__).resolve().parents[3]
CACHE = REPO / ".wisp-cache" / "stock"


class ImageError(ValueError):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def crc32c_msb(data: bytes) -> int:
    """EVENOTA component CRC: CRC-32/Castagnoli polynomial, MSB first, init 0, no xorout."""
    crc = 0
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1EDC6F41) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc


def _crc32c_table() -> list[int]:
    table = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x1EDC6F41) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
        table.append(c)
    return table


_TABLE = _crc32c_table()


def crc32c_fast(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _TABLE[(crc >> 24) ^ byte]
    return crc


def program(name: str) -> bytes:
    data = (DATA / f"{name}.bin").read_bytes()
    if sha(data) != pins.PROGRAMS[name] or not 2 <= len(data) <= 512 or len(data) & 1:
        raise ImageError(f"RAM program {name}.bin failed its pin")
    return data


# --- EVENOTA bundles ----------------------------------------------------------------------------

def bundle(version: str, cache: Path = CACHE) -> bytes:
    want = {"2.3.2.14": pins.BUNDLE_2_3_2_14_SHA256, "2.4.0.24": pins.BUNDLE_2_4_0_24_SHA256}[version]
    path = cache / f"g2-{version}.bin"
    if not path.exists():
        raise ImageError(f"{path} missing; run: node packages/wisp-ota/dist/cli.js fetch {version}")
    data = path.read_bytes()
    if sha(data) != want:
        raise ImageError(f"{path} is not the pinned {version} bundle")
    return data


def component(data: bytes, filename: bytes) -> bytes:
    """The payload of the one component with this path; every CRC layer checked."""
    if data[:8] != b"EVENOTA\0":
        raise ImageError("not an EVENOTA bundle")
    count = struct.unpack_from("<I", data, 8)[0]
    if not 1 <= count <= 64:
        raise ImageError("bad EVENOTA table")
    found = []
    for i in range(count):
        _id, offset, size, crc = struct.unpack_from("<4I", data, 64 + 16 * i)
        header = data[offset : offset + 128]
        if header[48:].split(b"\0")[0] != filename:
            continue
        length, header_crc = struct.unpack_from("<II", header, 8)
        payload = data[offset + 128 : offset + 128 + length]
        if length > size - 128 or crc32c_fast(payload) != crc or header_crc != crc:
            raise ImageError(f"{filename.decode()} component CRC mismatch")
        found.append(payload)
    if len(found) != 1:
        raise ImageError(f"expected exactly one {filename.decode()} component")
    return found[0]


def stock_bootloader(cache: Path = CACHE) -> bytes:
    boot = component(bundle("2.3.2.14", cache), pins.OTA_BOOT_FILENAME)
    if len(boot) != pins.STOCK_BOOTLOADER_BYTES or sha(boot) != pins.STOCK_BOOTLOADER_SHA256:
        raise ImageError("2.3.2.14 bootloader failed its pin")
    return boot


def stock_main(cache: Path = CACHE) -> bytes:
    """Stock 2.4.0.24 main app as it sits in MRAM at 0x438000 (preamble stripped, checked)."""
    return main_from_bundle(bundle("2.4.0.24", cache))


def main_from_bundle(data: bytes) -> bytes:
    if sha(data) != pins.BUNDLE_2_4_0_24_SHA256:
        raise ImageError("not the pinned 2.4.0.24 bundle")
    payload = component(data, b"ota/s200_firmware_ota.bin")
    if sha(payload) != pins.STOCK_MAIN_PAYLOAD_SHA256:
        raise ImageError("2.4.0.24 main payload failed its pin")
    declared, crc = struct.unpack_from("<II", payload)
    if declared & 0xFFFFFF != len(payload) or zlib.crc32(payload[8:]) != crc:
        raise ImageError("2.4.0.24 main preamble length/CRC mismatch")
    if struct.unpack_from("<I", payload, 20)[0] != pins.APP_BASE:
        raise ImageError("2.4.0.24 main has the wrong run base")
    image = payload[32:]
    if sha(image) != pins.STOCK_MAIN_SHA256 or len(image) != pins.STOCK_MAIN_BYTES:
        raise ImageError("2.4.0.24 main image failed its pin")
    sp, reset = struct.unpack_from("<II", image)
    if sp & 7 or not 0x20000000 < sp <= 0x20400000 or not reset & 1 or not (
        pins.APP_BASE <= reset & ~1 < pins.APP_BASE + len(image)
    ):
        raise ImageError("2.4.0.24 main vectors are invalid")
    return image


def case_firmware(cache: Path = CACHE) -> bytes:
    raw = component(bundle("2.3.2.14", cache), b"firmware/box.bin")[32:]
    if sha(raw) != pins.CASE_FIRMWARE_SHA256:
        raise ImageError("case 1.2.57 firmware failed its pin")
    return raw


# --- The patched bootloader [drdaeman tools/patch.py patch(), firmware.validate_image] ----------

def build_patched_bootloader(cache: Path = CACHE) -> bytes:
    stock = stock_bootloader(cache)
    blob = (DATA / "patch.bin").read_bytes()
    if sha(blob) != pins.PATCH_BIN_SHA256:
        raise ImageError("patch.bin failed its pin")
    image = bytearray(stock)
    if image[pins.HOOK_OFFSET : pins.HOOK_OFFSET + 4] != pins.HOOK_OLD:
        raise ImageError("stock call at the hook differs")
    image[pins.HOOK_OFFSET : pins.HOOK_OFFSET + 4] = pins.HOOK_NEW
    image += blob
    image += bytes(-len(image) % 4)
    raw = len(image)
    end = (raw + pins.PAGE_BYTES - 1) & -pins.PAGE_BYTES
    if end > pins.BOOT_PART_BYTES:
        raise ImageError("patch overlaps the main application")
    image += b"\xff" * (end - raw)
    image = bytes(image)
    check_patched_bootloader(image)
    return image


def check_patched_bootloader(image: bytes) -> None:
    if len(image) != pins.PATCHED_BOOTLOADER_BYTES or sha(image) != pins.PATCHED_BOOTLOADER_SHA256:
        raise ImageError("patched bootloader is not the pinned image")
    if sha(image[: pins.PATCHED_RAW_BYTES]) != pins.PATCHED_RAW_SHA256:
        raise ImageError("patched bootloader raw part differs")
    # Independent restatement of drdaeman's validate_image(): stock bytes everywhere except the
    # one BL, the BL lands inside the appended code, the appended code is the pinned patch.bin.
    prefix = bytearray(image[: pins.STOCK_BOOTLOADER_BYTES])
    hook = bytes(prefix[pins.HOOK_OFFSET : pins.HOOK_OFFSET + 4])
    prefix[pins.HOOK_OFFSET : pins.HOOK_OFFSET + 4] = pins.HOOK_OLD
    if sha(prefix) != pins.STOCK_BOOTLOADER_SHA256 or hook != pins.HOOK_NEW:
        raise ImageError("stock code changed outside the reviewed hook")
    target = bl_target(pins.BOOT_BASE + pins.HOOK_OFFSET, hook)
    if not pins.PATCH_BASE <= target < pins.BOOT_BASE + pins.PATCHED_RAW_BYTES:
        raise ImageError("hook target lies outside the appended code")
    blob = image[pins.STOCK_BOOTLOADER_BYTES : pins.STOCK_BOOTLOADER_BYTES + len((DATA / "patch.bin").read_bytes())]
    if sha(blob) != pins.PATCH_BIN_SHA256:
        raise ImageError("appended code is not patch.bin")
    if set(image[pins.PATCHED_RAW_BYTES :]) - {0xFF}:
        raise ImageError("padding is not erased bytes")


def ota_component_header(payload: bytes) -> bytes:
    """128-byte EVENOTA component header for the bootloader, as the stock bundles carry it."""
    return struct.pack(
        "<12I", 0, 0, len(payload), crc32c_fast(payload), 0, 0x4E455645, 0xFFFFFFFF, 0xFFFFFFFF,
        0, pins.OTA_BOOT_TYPE, pins.OTA_STORAGE_LITTLEFS, 0xFFFFFFFF,
    ) + pins.OTA_BOOT_FILENAME.ljust(80, b"\0")


# --- Thumb BL encode/decode -------------------------------------------------------------------

def bl_target(pc: int, insn: bytes) -> int:
    first, second = struct.unpack("<HH", insn)
    if first & 0xF800 != 0xF000 or second & 0xD000 != 0xD000:
        raise ImageError("not a Thumb BL")
    s = (first >> 10) & 1
    delta = (
        (s << 24) | ((1 ^ ((second >> 13) & 1) ^ s) << 23) | ((1 ^ ((second >> 11) & 1) ^ s) << 22)
        | ((first & 1023) << 12) | ((second & 2047) << 1)
    )
    if s:
        delta -= 1 << 25
    return pc + 4 + delta


def bl_encode(pc: int, target: int) -> bytes:
    delta = target - (pc + 4)
    if delta & 1 or not -(1 << 24) <= delta < (1 << 24):
        raise ImageError("BL target out of range")
    delta &= (1 << 25) - 1
    s = (delta >> 24) & 1
    i1, i2 = (delta >> 23) & 1, (delta >> 22) & 1
    j1, j2 = (1 ^ i1 ^ s), (1 ^ i2 ^ s)
    first = 0xF000 | (s << 10) | ((delta >> 12) & 1023)
    second = 0xD000 | (j1 << 13) | (j2 << 11) | ((delta >> 1) & 2047)
    return struct.pack("<HH", first, second)


# --- The case relay ---------------------------------------------------------------------------

def build_relay(profile: str, cache: Path = CACHE) -> bytes:
    """drdaeman's case.bin, rebuilt: the template plus the relocated reset waveform from the
    cached case 1.2.57 firmware, then the step-0 bridge variant for this case's YHM profile."""
    template = bytearray((DATA / "case_relay_template.bin").read_bytes())
    if sha(template) != pins.RELAY_TEMPLATE_SHA256 or len(template) != pins.RELAY_BYTES:
        raise ImageError("case relay template failed its pin")
    start, end = pins.RELAY_WAVEFORM_SOURCE
    wave = bytearray(case_firmware(cache)[start:end])
    if sha(wave) != pins.RELAY_WAVEFORM_SHA256:
        raise ImageError("case reset waveform failed its pin")
    calls = 0
    at = 0
    while at < len(wave) - 3:
        a, b = struct.unpack_from("<HH", wave, at)
        if a & 0xF800 == 0xF000 and b & 0xD000 == 0xD000:
            source = bl_target(0x0800_0000 + start + at, bytes(wave[at : at + 4]))
            if source not in pins.RELAY_BL_TARGETS:
                raise ImageError(f"unexpected waveform call target {source:#x}")
            pc = pins.RELAY_ADDRESS + pins.RELAY_WAVEFORM_OFFSET + at
            wave[at : at + 4] = bl_encode(pc, pins.RELAY_BL_TARGETS[source])
            calls += 1
            at += 4
        else:
            at += 2
    if calls != pins.RELAY_BL_COUNT:
        raise ImageError("waveform call coverage changed")
    o = pins.RELAY_WAVEFORM_OFFSET
    template[o : o + pins.RELAY_WAVEFORM_BYTES] = wave
    if sha(template) != pins.RELAY_SHA256["reviewed-22"]:
        raise ImageError("rebuilt case relay differs from drdaeman's pinned case.bin")
    if profile == "observed-33":
        for offset in (1670, 1680, 1690, 1700):
            if template[offset] != 0x22:
                raise ImageError("relay baseline table differs from the reviewed layout")
            template[offset] = 0x33
    elif profile != "reviewed-22":
        raise ImageError(f"unknown case profile {profile!r}")
    image = bytes(template)
    if sha(image) != pins.RELAY_SHA256[profile]:
        raise ImageError(f"{profile} case relay failed its pin")
    return image
