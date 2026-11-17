# SPDX-License-Identifier: MIT
"""The Mac's real radio as session.mts's GATT central (rung4.md G14, W25), with bleak.

The same JSON-lines protocol as bumble_bridge.py (in: connect, write, scan, disconnect; out:
connected, notify, scanned, disconnected, error), so the SDK runs unchanged over either. Finds the
temple by the Wisp service UUID (or --address), connects, subscribes to TX and writes RX without
response. Touches nothing but the Wisp GATT service; never an Even characteristic.

    uv run --with bleak==0.22.3 python -I apps/wisp-fw/tests/ble/bleak_bridge.py [--address <id>]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys

SERVICE = "cf099bf1-f34e-49e2-b353-7f20e02243bc"
RX = "cf099bf2-f34e-49e2-b353-7f20e02243bc"
TX = "cf099bf3-f34e-49e2-b353-7f20e02243bc"


def emit(**msg) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


class Central:
    def __init__(self, bleak, address: str | None):
        self.bleak = bleak
        self.address = address
        self.client = None

    def is_wisp(self, device, adv) -> bool:
        if self.address:
            return device.address.lower() == self.address.lower()
        return SERVICE in [u.lower() for u in (adv.service_uuids or [])]

    async def connect(self, timeout: float = 20.0) -> None:
        device = await self.bleak.BleakScanner.find_device_by_filter(self.is_wisp, timeout=timeout)
        if device is None:
            raise RuntimeError("no Wisp advertiser found")
        self.client = self.bleak.BleakClient(device, disconnected_callback=lambda _c: emit(ev="disconnected", reason=0))
        await self.client.connect()
        await self.client.start_notify(TX, lambda _h, data: emit(ev="notify", data=bytes(data).hex()))
        rx = self.client.services.get_characteristic(RX)
        tx = self.client.services.get_characteristic(TX)
        if rx is None or tx is None:
            raise RuntimeError("the Wisp service has no RX/TX characteristic")
        # bleak's mtu_size is the ATT MTU (CoreBluetooth: max write without response + 3).
        emit(ev="connected", mtu=int(self.client.mtu_size), name=device.name, address=device.address,
             props={"rx": 0x04 if "write-without-response" in rx.properties else 0,
                    "tx": 0x10 if "notify" in tx.properties else 0})

    async def write(self, data: bytes) -> None:
        await self.client.write_gatt_char(RX, data, response=False)

    async def scan(self, ms: int) -> None:
        seen = []
        scanner = self.bleak.BleakScanner(detection_callback=lambda d, a: seen.append(d.address)
                                          if self.is_wisp(d, a) else None)
        await scanner.start()
        await asyncio.sleep(ms / 1000)
        await scanner.stop()
        emit(ev="scanned", wisp=len(seen))

    async def disconnect(self) -> None:
        if self.client is not None:
            await self.client.disconnect()


async def serve(central: Central, lines) -> None:
    async for line in lines:
        try:
            cmd = json.loads(line)
            if cmd["cmd"] == "connect":
                await central.connect()
            elif cmd["cmd"] == "write":
                await central.write(bytes.fromhex(cmd["data"]))
            elif cmd["cmd"] == "scan":
                await central.scan(int(cmd.get("ms", 1000)))
            elif cmd["cmd"] == "disconnect":
                await central.disconnect()
        except Exception as e:  # noqa: BLE001 - reported to the driver
            emit(ev="error", message=f"{line.strip()[:40]}: {e!r}")


async def stdin_lines():
    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            return
        yield line


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--address", help="the temple's BLE address (macOS: its CoreBluetooth UUID)")
    a = ap.parse_args()
    import bleak  # noqa: PLC0415 - only on the Mac
    asyncio.run(serve(Central(bleak, a.address), stdin_lines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
