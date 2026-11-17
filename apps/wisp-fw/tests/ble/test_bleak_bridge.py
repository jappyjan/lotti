# SPDX-License-Identifier: MIT
"""bleak_bridge.py against a fake bleak (no radio): the JSON-lines protocol session.mts speaks."""
import asyncio
import io
import json
import sys
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bleak_bridge as bb  # noqa: E402


class Char:
    def __init__(self, props):
        self.properties = props


class FakeClient:
    instances = []

    def __init__(self, device, disconnected_callback=None):
        self.device, self.on_disc, self.writes, self.mtu_size = device, disconnected_callback, [], 247
        self.services = types.SimpleNamespace(get_characteristic=lambda u: {
            bb.RX: Char(["write-without-response", "write"]), bb.TX: Char(["notify"])}.get(u))
        FakeClient.instances.append(self)

    async def connect(self):
        pass

    async def start_notify(self, uuid, cb):
        self.notify = cb

    async def write_gatt_char(self, uuid, data, response):
        self.writes.append((uuid, bytes(data), response))
        self.notify(None, bytearray(b"\x01\x02"))

    async def disconnect(self):
        self.on_disc(self)


def fake_bleak(adverts):
    async def find(flt, timeout):
        return next((d for d, a in adverts if flt(d, a)), None)

    class Scanner:
        find_device_by_filter = staticmethod(find)

        def __init__(self, detection_callback):
            self.cb = detection_callback

        async def start(self):
            for d, a in adverts:
                self.cb(d, a)

        async def stop(self):
            pass
    return types.SimpleNamespace(BleakScanner=Scanner, BleakClient=FakeClient)


def dev(name, address, uuids):
    return (types.SimpleNamespace(name=name, address=address), types.SimpleNamespace(service_uuids=uuids))


def drive(adverts, cmds, address=None):
    async def lines():
        for c in cmds:
            yield json.dumps(c) + "\n"
    out = io.StringIO()
    with redirect_stdout(out):
        asyncio.run(bb.serve(bb.Central(fake_bleak(adverts), address), lines()))
    return [json.loads(line) for line in out.getvalue().splitlines()]


class BleakBridge(unittest.TestCase):
    def test_connect_write_notify_scan_disconnect(self):
        ads = [dev("G2_L_stock", "aa", ["0000fe59-0000-1000-8000-00805f9b34fb"]), dev("Wisp", "bb", [bb.SERVICE])]
        ev = drive(ads, [{"cmd": "connect"}, {"cmd": "write", "data": "0a0b"}, {"cmd": "scan", "ms": 1},
                         {"cmd": "disconnect"}])
        self.assertEqual([e["ev"] for e in ev], ["connected", "notify", "scanned", "disconnected"])
        self.assertEqual((ev[0]["name"], ev[0]["address"], ev[0]["mtu"]), ("Wisp", "bb", 247))
        self.assertEqual(ev[0]["props"], {"rx": 0x04, "tx": 0x10})
        self.assertEqual(FakeClient.instances[-1].writes, [(bb.RX, b"\x0a\x0b", False)])
        self.assertEqual(ev[1]["data"], "0102")
        self.assertEqual(ev[2]["wisp"], 1)

    def test_no_wisp_advertiser_is_an_error_event(self):
        ev = drive([dev("G2_L_stock", "aa", [])], [{"cmd": "connect"}])
        self.assertEqual(ev[0]["ev"], "error")
        self.assertIn("no Wisp advertiser", ev[0]["message"])

    def test_address_selects_the_temple(self):
        ads = [dev("Wisp", "bb", [bb.SERVICE]), dev("Wisp", "cc", [bb.SERVICE])]
        ev = drive(ads, [{"cmd": "connect"}], address="CC")
        self.assertEqual(ev[0]["address"], "cc")


if __name__ == "__main__":
    unittest.main()
