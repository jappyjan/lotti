# SPDX-License-Identifier: MIT
"""The one W18 bootloader install: the stock main app's own BLE OTA service, one component
(type 1, storage 3, ota/s200_bootloader.bin), the pinned patched image only.

Ported from drdaeman/g2-bootloader-patch @ 1d22097 tools/g2patch/ble_ota.py (MIT): the frame
format (AA 21 seq len count index sid 0, CRC-16/IBM-3740), stock authentication (sid 0x80),
BEGIN / FILE_CHECK / 4 KiB DATA blocks / END on sid 0xC0/0xC1, no replay of any write.

What the stock 2.4.0.24 app does with it (docs/wisp/recovery.md, "How the install works"):
FILE_CHECK with type 1 + storage 3 selects the littlefs file and remembers MRAM 0x410000; the
blocks go into that file on the NOR; END re-reads the whole file (size, CRC-32C) and answers
status 8; only then does the app copy the file to MRAM 0x410000 in 4 KiB chunks, synchronously,
without a reset and without touching the update flag.
"""

from __future__ import annotations

import asyncio
import re
import time

from . import image

DATA = ("00002760-08c2-11e1-9073-0e8ac72e0001", "00002760-08c2-11e1-9073-0e8ac72e0002")
CTRL = ("00002760-08c2-11e1-9073-0e8ac72e5401", "00002760-08c2-11e1-9073-0e8ac72e5402")
BLOCK = 4096
END_OK = 8  # RESULT_CHECK passed (2.4.0.24 answers before its MRAM copy)


class OtaError(RuntimeError):
    pass


def crc16(data: bytes) -> bytes:
    crc = 0xFFFF  # CRC-16/IBM-3740 (CCITT-FALSE)
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc.to_bytes(2, "little")


def frames(sid: int, payload: bytes, sequence: int) -> list[bytes]:
    body = payload + crc16(payload)
    count = max(1, (len(body) + 231) // 232)
    return [
        bytes((0xAA, 0x21, sequence, len(body[i : i + 232]), count, i // 232 + 1, sid, 0)) + body[i : i + 232]
        for i in range(0, len(body), 232)
    ]


def unwrap(frame: bytes):
    if len(frame) < 10 or frame[:2] != b"\xaa\x12" or frame[3] != len(frame) - 8 or crc16(frame[8:-2]) != frame[-2:]:
        return None, b""
    return frame[6], frame[8:-2]


def side_of(name: str | None) -> str | None:
    match = re.search(r"_(L|R)_[0-9a-f]{6}$", name or "", re.IGNORECASE)
    return {"L": "left", "R": "right"}.get(match[1].upper()) if match else None


class StockOta:
    """`gatt` provides: async write(char, data); async notifications() queue of (char, bytes);
    name; mtu. BleakGatt below is the real one, tests pass a fake."""

    def __init__(self, gatt, log=print):
        self.gatt = gatt
        self.log = log
        self.sequence = 0
        self.end_status: int | None = None
        self.blocks_acked = 0

    def next_sequence(self) -> int:
        self.sequence = (self.sequence + 1) & 255
        return self.sequence

    async def send(self, characteristic: str, packets: list[bytes]) -> None:
        for packet in packets:
            await self.gatt.write(characteristic, packet)

    def drain(self) -> None:
        while not self.gatt.notes.empty():
            self.gatt.notes.get_nowait()

    async def wait(self, channel: str, predicate, timeout: float) -> bytes:
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise OtaError("stock BLE reply timeout; no write is ever replayed")
            try:
                ch, frame = await asyncio.wait_for(self.gatt.notes.get(), left)
            except TimeoutError:
                raise OtaError("stock BLE reply timeout; no write is ever replayed") from None
            sid, payload = unwrap(frame)
            if ch == channel and sid is not None and predicate(sid, payload):
                return payload

    async def authenticate(self) -> None:
        magic = self.next_sequence()
        encoded = bytes((magic,)) if magic < 128 else bytes(((magic & 127) | 128, magic >> 7))
        prefix = b"\x08\x04\x10" + encoded
        await self.send(CTRL[0], frames(0x80, prefix + b"\x1a\x04\x08\x01\x10\x04", magic))
        result = await self.wait(CTRL[1], lambda sid, p: sid == 0x80 and p.startswith(prefix), 10)
        if result != prefix + b"\x1a\0":
            raise OtaError("stock authentication rejected")

    async def command(self, operation: int, data: bytes = b"", timeout: float = 10) -> int:
        self.drain()
        await self.send(DATA[0], frames(0xC0, bytes((operation,)) + data, self.next_sequence()))
        reply = await self.wait(DATA[1], lambda sid, p: len(p) >= 2 and p[0] == operation, timeout)
        return reply[1]

    async def install(self, payload: bytes) -> int:
        """Send exactly the pinned patched bootloader. Returns the END status (8)."""
        image.check_patched_bootloader(payload)
        header = image.ota_component_header(payload)
        if len(payload) % BLOCK:
            raise OtaError("expected a page-aligned component")
        status = await self.command(0)
        if status:
            raise OtaError(f"stock BEGIN rejected ({status}); nothing staged")
        status = await self.command(1, header)
        if status:
            raise OtaError(f"stock FILE_CHECK rejected ({status}); nothing staged")
        for offset in range(0, len(payload), BLOCK):
            self.drain()
            sequence = self.next_sequence()
            packets = frames(0xC0, b"\x02", sequence) + frames(0xC1, payload[offset : offset + BLOCK], sequence)
            await self.send(DATA[0], packets)
            ack = await self.wait(DATA[1], lambda sid, p: len(p) >= 2 and p[0] == 2, 4)
            if ack[1]:
                raise OtaError(f"block at {offset} rejected (status {ack[1]}); MRAM untouched, no replay")
            self.blocks_acked += 1
            self.log(f"{offset + BLOCK}/{len(payload)} bytes staged in ota/s200_bootloader.bin")
        status = await self.command(3, timeout=30)
        self.end_status = status
        if status != END_OK:
            raise OtaError(f"END answered {status}, not {END_OK}: the app did not accept the staged file, "
                           "so it did not copy it to MRAM")
        return status


class BleakGatt:
    """The real BLE side (bleak). Only used on the Mac with Jan present."""

    def __init__(self, address: str, adapter: str | None = None):
        self.address, self.adapter = address, adapter
        self.notes: asyncio.Queue = asyncio.Queue()
        self.client = None
        self.name = None
        self.mtu = 0

    async def __aenter__(self):
        import sys

        from bleak import BleakClient, BleakScanner

        adapter = self.adapter if sys.platform.startswith("linux") else None
        kwargs = {"bluez": {"adapter": adapter}} if adapter else {}
        device = await BleakScanner.find_device_by_address(self.address, timeout=20, **kwargs)
        if device is None:
            raise OtaError("temple not advertising; release other clients and check the address")
        self.name = device.name
        self.client = BleakClient(device, timeout=30, **kwargs)
        await self.client.connect()
        try:
            if sys.platform.startswith("linux"):
                await self.client._backend._acquire_mtu()
            self.mtu = self.client.mtu_size
            for ch in (CTRL[1], DATA[1]):
                await self.client.start_notify(ch, lambda _s, data, ch=ch: self.notes.put_nowait((ch, bytes(data))))
            await asyncio.sleep(2.5)
            return self
        except BaseException:
            await self.client.disconnect()
            raise

    async def __aexit__(self, *args):
        if self.client:
            await self.client.disconnect()

    async def write(self, characteristic: str, data: bytes) -> None:
        await self.client.write_gatt_char(characteristic, data, response=False)


# --- rung 4, W24: is the native temple advertising? (read-only, no connection) -----------------

# native-0's advertising (apps/wisp-fw src/ble/wisp_ble.c): the Wisp service UUID in the
# advertisement, the name "Wisp" in the scan response (CONFIG_BT_DEVICE_NAME).
WISP_SERVICE_UUID = "cf099bf1-f34e-49e2-b353-7f20e02243bc"
WISP_NAME = "Wisp"
EVEN_NAME = re.compile(r"_([LR])_[0-9A-Za-z]{6}$")  # stock temples: ..._L_xxxxxx / ..._R_xxxxxx
GAP_S = 5.0  # a pause in a device's adverts longer than this is listed (e.g. the case's reset, G10b)


def classify(name: str | None, uuids) -> str | None:
    """"wisp", "stock-left", "stock-right", or None for anything else."""
    if WISP_SERVICE_UUID in {str(u).lower() for u in uuids or ()} or name == WISP_NAME:
        return "wisp"
    m = EVEN_NAME.search(name or "")
    return {"L": "stock-left", "R": "stock-right"}[m.group(1)] if m else None


async def scan(seconds: float, adapter: str | None = None, clock=time.monotonic) -> dict:
    """Listen to advertisements for `seconds` (active scan, so scan responses carry names).
    Never connects. Returns every Wisp or Even temple seen: address, name, kind, RSSI, when it
    was first and last seen, how many adverts, and the gaps longer than GAP_S."""
    import sys

    from bleak import BleakScanner

    started = clock()
    seen: dict[str, dict] = {}

    def on_advert(device, adv) -> None:
        name = getattr(adv, "local_name", None) or getattr(device, "name", None)
        entry = seen.get(device.address)
        kind = classify(name, getattr(adv, "service_uuids", ()))
        if entry is None:
            if kind is None:
                return
            entry = seen[device.address] = {"address": device.address, "name": name, "kind": kind, "adverts": 0,
                                            "first_s": round(clock() - started, 1), "rssi_max": None, "gaps_s": []}
        elif kind and entry["kind"] != "wisp":
            entry["kind"] = kind  # a name from a later scan response
        if name and not entry["name"]:
            entry["name"] = name
        t = round(clock() - started, 1)
        if entry["adverts"] and t - entry["last_s"] > GAP_S:
            entry["gaps_s"].append([entry["last_s"], t])
        entry["adverts"] += 1
        entry["last_s"] = t
        rssi = getattr(adv, "rssi", None)
        if rssi is not None and (entry["rssi_max"] is None or rssi > entry["rssi_max"]):
            entry["rssi_max"] = rssi

    kwargs = {"bluez": {"adapter": adapter}} if adapter and sys.platform.startswith("linux") else {}
    scanner = BleakScanner(detection_callback=on_advert, **kwargs)
    await scanner.start()
    try:
        await asyncio.sleep(seconds)
    finally:
        await scanner.stop()
    return {"seconds": round(clock() - started, 1), "devices": sorted(seen.values(), key=lambda e: e["first_s"])}
