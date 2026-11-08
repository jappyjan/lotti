# SPDX-License-Identifier: MIT
"""What `install-wisp` checks before it writes a Wisp native image through the case loader
(docs/wisp/rung4.md §3, G1, decision R4-1). Nothing here talks to hardware.

- `resolve`: the image must be listed in pins.WISP_IMAGES, and R4-1 must be approved
  (pins.R4_1_APPROVED). Both are off in the repository, so every image is refused. The ELF and
  map files must match their pins, the build must have passed the gates the pin records, and
  the first 64 KiB (Wisp Boot) must be a build that passed both rung-3 suites R4-1 names.
- `rule3`: safety.md rule 3 on the bytes the writer is about to send, in both implementations
  (R4-1). The payload is what wisp-ota's `wrapMainImage` would make of the image. (1) A port of
  wisp-ota's `checkMainPayload` (packages/wisp-ota/src/guards.ts, the same guard ids), with two
  CRC-32 implementations (zlib and a table of our own). (2) wisp-ota's own `checkMainPayload`,
  run by Node from its build (packages/wisp-ota/dist; its sources use TypeScript syntax Node cannot
  strip, so `pnpm nx run wisp-ota:build` first). Both must pass every guard; a missing build
  refuses. The two are also cross-checked offline: wisp-ota's test suite and
  tests/test_install_wisp.py run the same vectors
  (packages/wisp-ota/src/testing/main-payload-vectors.json) and must agree guard by guard.
- `elf_matches`: every loadable ELF segment placed in MRAM lies inside the image and equals its
  bytes there.
"""

from __future__ import annotations

import json
import shutil
import struct
import subprocess
import zlib
from pathlib import Path

from . import image, pins

# wisp-ota constants.ts, restated (rule 3 wants an independent second implementation).
PREAMBLE_SIZE = 0x20
PREAMBLE_FLAGS = 0x04
PREAMBLE_DATA_TYPE = 0xCB
PREAMBLE_MAX_SIZE = 0x00FF_FFFF
MAIN_LOAD_ADDRESS = 0x0043_8000
MIN_VECTOR_TABLE_SIZE = 0x40
SBL_START = 0x0040_0000
EVEN_BOOTLOADER_END = 0x0043_8000
APP_END_CEILING = 0x007F_8000
UPDATE_FLAG_ADDRESS = 0x007F_E000
SRAM_START = 0x2000_0000
SRAM_END = 0x2038_0000

GUARD_IDS = ("preamble-format", "load-address", "preamble-size", "image-size", "app-end",
             "protected-regions", "sp-vector", "reset-vector", "preamble-crc")


class NativeRefused(ValueError):
    """install-wisp refuses: nothing was sent and the case was not touched."""


# --- CRC-32 (zlib's), a second implementation ---------------------------------------------------

def _crc32_table() -> list[int]:
    table = []
    for byte in range(256):
        crc = byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
        table.append(crc)
    return table


_CRC32 = _crc32_table()


def crc32_table(data: bytes) -> int:
    crc = 0xFFFFFFFF
    table = _CRC32
    for byte in data:
        crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
    return crc ^ 0xFFFFFFFF


# --- rule 3, ported from wisp-ota ---------------------------------------------------------------

def wrap_main_image(app: bytes) -> bytes:
    """wisp-ota `wrapMainImage`: the 32-byte main preamble in front of an image linked at
    0x438000, as the stock OTA path would stage it."""
    total = PREAMBLE_SIZE + len(app)
    if total > PREAMBLE_MAX_SIZE:
        raise NativeRefused(f"image of {len(app)} bytes overflows the 24-bit preamble size field")
    payload = bytearray(total)
    struct.pack_into("<I", payload, 0x00, (PREAMBLE_FLAGS << 24) | total)
    struct.pack_into("<I", payload, 0x10, PREAMBLE_DATA_TYPE)
    struct.pack_into("<I", payload, 0x14, MAIN_LOAD_ADDRESS)
    payload[PREAMBLE_SIZE:] = app
    struct.pack_into("<I", payload, 0x04, zlib.crc32(payload[8:]))
    return bytes(payload)


def check_main_payload(payload: bytes) -> list[dict]:
    """wisp-ota `checkMainPayload`: every guard on a main payload, each {id, ok, detail}."""
    if len(payload) < PREAMBLE_SIZE + 8:
        return [{"id": g, "ok": False, "detail": f"not evaluated: main payload is {len(payload)} bytes; too short "
                 "for preamble + vectors"} for g in GUARD_IDS]
    word0, stored_crc, r0, r1, data_type, load, r2, r3 = struct.unpack_from("<8I", payload)
    flags, declared = word0 >> 24, word0 & 0x00FF_FFFF
    sp, reset = struct.unpack_from("<II", payload, PREAMBLE_SIZE)
    installed = len(payload) - PREAMBLE_SIZE
    app_end = load + installed
    declared_end = load + declared - PREAMBLE_SIZE
    out = []

    def guard(gid: str, ok: bool, detail: str) -> None:
        out.append({"id": gid, "ok": bool(ok), "detail": detail})

    problems = []
    if flags != PREAMBLE_FLAGS:
        problems.append(f"flags {flags:#x}")
    if data_type != PREAMBLE_DATA_TYPE:
        problems.append(f"data type {data_type:#010x}")
    if any((r0, r1, r2, r3)):
        problems.append("reserved words nonzero")
    guard("preamble-format", not problems, ", ".join(problems) or "flags 0x04, type 0xcb")
    guard("load-address", load == MAIN_LOAD_ADDRESS, f"load address {load:#010x}")
    guard("preamble-size", declared == len(payload), f"declared {declared}, payload {len(payload)}")
    smallest = PREAMBLE_SIZE + MIN_VECTOR_TABLE_SIZE
    guard("image-size", smallest <= len(payload) <= PREAMBLE_MAX_SIZE,
          f"payload {len(payload)} bytes (allowed {smallest}..{PREAMBLE_MAX_SIZE})")
    end = max(app_end, declared_end)
    guard("app-end", end <= APP_END_CEILING,
          f"app end {app_end:#010x}, declared end {declared_end:#010x}, ceiling {APP_END_CEILING:#010x}")
    inside = load >= EVEN_BOOTLOADER_END and end <= UPDATE_FLAG_ADDRESS and load < end
    touched = []
    if load < EVEN_BOOTLOADER_END and end > SBL_START:
        touched.append("SBL / Even bootloader")
    if end > UPDATE_FLAG_ADDRESS:
        touched.append("update flag / NV area")
    guard("protected-regions", inside,
          f"installs [{load:#010x}, {end:#010x})" + (f", overlaps {' and '.join(touched)}" if touched else ""))
    guard("sp-vector", SRAM_START < sp <= SRAM_END and sp % 8 == 0, f"initial SP {sp:#010x}")
    handler = reset & ~1
    guard("reset-vector", bool(reset & 1) and load == MAIN_LOAD_ADDRESS
          and MAIN_LOAD_ADDRESS + MIN_VECTOR_TABLE_SIZE <= handler < app_end,
          f"reset {reset:#010x} ({'Thumb' if reset & 1 else 'not Thumb'}), image [{MAIN_LOAD_ADDRESS:#010x}, "
          f"{app_end:#010x})")
    covered = payload[8:]
    table, ours = zlib.crc32(covered), crc32_table(covered)
    guard("preamble-crc", stored_crc == table == ours,
          f"stored {stored_crc:#010x}, zlib {table:#010x}, table {ours:#010x}")
    return out


WISP_OTA_GUARDS = image.REPO / "packages/wisp-ota/dist/guards.js"
_NODE_SCRIPT = """
const { checkMainPayload } = await import(process.argv[1]);
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const results = checkMainPayload(new Uint8Array(Buffer.concat(chunks)));
process.stdout.write(JSON.stringify(results.map((r) => ({ id: r.id, ok: r.ok, detail: r.detail }))));
"""


def wisp_ota_guards(payload: bytes) -> list[dict]:
    """wisp-ota's own `checkMainPayload` on `payload`, through Node and wisp-ota's build."""
    node = shutil.which("node")
    if node is None or not WISP_OTA_GUARDS.exists():
        raise NativeRefused(f"wisp-ota's rule-3 checks are not available (needs node and {WISP_OTA_GUARDS}; run "
                            "`pnpm nx run wisp-ota:build`); nothing was sent")
    run = subprocess.run([node, "--input-type=module", "-e", _NODE_SCRIPT, WISP_OTA_GUARDS.as_uri()], input=payload,
                         capture_output=True, timeout=120)
    if run.returncode:
        raise NativeRefused(f"wisp-ota's rule-3 checks failed to run: {run.stderr.decode(errors='replace')[-300:]}")
    return [{"id": r["id"], "ok": bool(r["ok"]), "detail": r["detail"]} for r in json.loads(run.stdout)]


def rule3(sent: bytes) -> list[dict]:
    """Rule 3 on the exact bytes the loader is about to write at 0x438000, in both
    implementations. Raises unless every guard passes in both and they agree; returns the
    results for the report (`by` says which implementation)."""
    payload = wrap_main_image(sent)
    ours, theirs = check_main_payload(payload), wisp_ota_guards(payload)
    failed = []
    for by, results in (("port", ours), ("wisp-ota", theirs)):
        failed += [f"{by}: {r['id']} ({r['detail']})" for r in results if not r["ok"]]
        if sorted(r["id"] for r in results) != sorted(GUARD_IDS):
            failed.append(f"{by}: guard set differs from {', '.join(GUARD_IDS)}")
    if failed:
        raise NativeRefused("rule 3 failed on the bytes to send: " + "; ".join(failed))
    return [{**r, "by": "port"} for r in ours] + [{**r, "by": "wisp-ota"} for r in theirs]


# --- ELF ----------------------------------------------------------------------------------------

def elf_segments(elf: bytes) -> list[tuple[int, bytes]]:
    """(load address, file bytes) of every PT_LOAD segment with file contents (ELF32 LE)."""
    if len(elf) < 52 or elf[:4] != b"\x7fELF" or elf[4] != 1 or elf[5] != 1:
        raise NativeRefused("--elf is not a 32-bit little-endian ELF")
    try:
        phoff, = struct.unpack_from("<I", elf, 0x1C)
        phentsize, phnum = struct.unpack_from("<HH", elf, 0x2A)
        if phentsize < 20:
            raise NativeRefused("--elf has a malformed program header table")
        out = []
        for i in range(phnum):
            p_type, p_offset, _vaddr, p_paddr, p_filesz = struct.unpack_from("<5I", elf, phoff + i * phentsize)
            if p_type == 1 and p_filesz:
                if p_offset + p_filesz > len(elf):
                    raise NativeRefused("--elf has a segment past its end")
                out.append((p_paddr, elf[p_offset : p_offset + p_filesz]))
    except struct.error as error:
        raise NativeRefused(f"--elf is truncated ({error})") from None
    return out


def elf_matches(elf: bytes, data: bytes) -> int:
    """Every loadable segment placed in MRAM lies inside [0x438000, image end) and equals the
    image there. Returns how many segments were compared; refuses if none was."""
    compared = 0
    for address, content in elf_segments(elf):
        if not 0x0040_0000 <= address < 0x0080_0000:
            continue  # RAM-only (no load address in MRAM)
        at = address - pins.APP_BASE
        if at < 0 or at + len(content) > len(data):
            raise NativeRefused(f"--elf places {len(content)} bytes at {address:#x}, outside the image")
        if data[at : at + len(content)] != content:
            raise NativeRefused(f"--elf segment at {address:#x} differs from the image")
        compared += 1
    if not compared:
        raise NativeRefused("--elf has no segment in MRAM")
    return compared


# --- the pin gate -------------------------------------------------------------------------------

def find_pin(sha256: str) -> tuple[str, dict] | None:
    for name, pin in pins.WISP_IMAGES.items():
        if pin["image_sha256"] == sha256:
            return name, pin
    return None


def resolve(data: bytes, elf: bytes, map_text: bytes, expect: str) -> dict:
    """Every check install-wisp makes before it touches the case. Returns the facts for the
    report; raises NativeRefused with the reason otherwise."""
    digest = image.sha(data)
    if not pins.R4_1_APPROVED or not pins.WISP_IMAGES:
        raise NativeRefused(
            "install-wisp writes only Wisp images pinned in wisp_w18/pins.py (WISP_IMAGES). The table stays "
            "empty until Jan approves R4-1 (docs/wisp/rung4.md, safety.md rule 1) and a reviewed commit pins "
            f"a built native-0 image. This image ({digest[:16]}...) is not pinned. Nothing was sent and the "
            "case was not touched.")
    found = find_pin(digest)
    if found is None:
        raise NativeRefused(f"image {digest[:16]}... is not in pins.WISP_IMAGES; nothing was sent")
    name, pin = found
    if len(expect) < 12 or not digest.startswith(expect.lower()):
        raise NativeRefused(f"--expect must be at least the first 12 hex digits of the image's SHA-256 "
                            f"({digest[:12]} for {name}); nothing was sent")
    if len(data) != pin["image_bytes"]:
        raise NativeRefused(f"{name}: {len(data)} bytes, pinned {pin['image_bytes']}")
    if image.sha(elf) != pin["elf_sha256"]:
        raise NativeRefused(f"{name}: --elf is not the pinned ELF")
    if image.sha(map_text) != pin["map_sha256"]:
        raise NativeRefused(f"{name}: --map is not the pinned map file")
    missing = [g for g in pins.WISP_GATES if g not in pin.get("gates", ())]
    if missing:
        raise NativeRefused(f"{name}: the pin records no pass of {', '.join(missing)}")
    if len(data) <= pins.WISP_BOOT_SLOT_BYTES:
        raise NativeRefused(f"{name}: {len(data)} bytes is no larger than Wisp Boot's 64 KiB slot")
    boot = image.sha(data[: pins.WISP_BOOT_SLOT_BYTES])
    passed = pins.WISP_BOOT_PASSED.get(boot)
    if passed is None:
        raise NativeRefused(f"{name}: its Wisp Boot ({boot[:16]}...) is not a build that passed rung 3")
    suites = [s for s in pins.WISP_BOOT_SUITES if s not in passed.get("suites", {})]
    if suites:
        raise NativeRefused(f"{name}: its Wisp Boot ({boot[:16]}...) has not passed {', '.join(suites)}")
    end = pins.APP_BASE + ((len(data) + 15) & ~15)
    if end > pins.APP_END_CEILING:
        raise NativeRefused(f"{name}: ends at {end:#x}, past 0x7F8000")
    segments = elf_matches(elf, data)
    rule3(data)  # once here, on the file; the writer reruns it on the bytes it sends
    return {"name": name, "image_sha256": digest, "bytes": len(data), "end": f"{end:#x}",
            "elf_sha256": pin["elf_sha256"], "map_sha256": pin["map_sha256"], "elf_segments_checked": segments,
            "gates": list(pin["gates"]), "wisp_boot_sha256": boot, "wisp_boot": passed}


def parse_battery(value: str) -> dict:
    """`--battery`: a percentage read in the Even app while on stock (>= 80), or millivolts read
    from Wisp's status while native, written with "mV" (>= 3900). rung4.md R4-4."""
    text = value.strip().lower()
    try:
        if text.endswith("mv"):
            mv = int(text[:-2].strip())
            return {"mV": mv, "ok": pins.BATTERY_MIN_MV <= mv <= 4500}  # above a full Li-ion cell: a typo
        percent = int(text.rstrip("%").strip())
        return {"percent": percent, "ok": pins.BATTERY_MIN_PERCENT <= percent <= 100}
    except ValueError:
        return {"value": value, "ok": False}


def read(path: str | None, what: str) -> bytes:
    if not path:
        raise NativeRefused(f"{what} is required")
    return Path(path).read_bytes()
