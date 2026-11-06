# SPDX-License-Identifier: MIT
"""A phone's Bluetooth radio for the end-to-end test, in software (Bumble, Apache-2.0).

Two virtual BLE controllers on one virtual link:

  controller "glasses"  served as H4 over TCP (127.0.0.1:<port>); the native_sim build of the
                        firmware attaches to it with --bt-dev=127.0.0.1:<port>, so Zephyr's real
                        host stack, our GATT service and wisp-core run unchanged
  controller "phone"    driven by a Bumble GATT central in this process

The test (e2e.test.mts) drives the central through JSON lines on stdin/stdout:

  in   {"cmd": "connect"}             scan for the Wisp service, connect, ATT MTU 247,
                                      discover RX/TX, enable TX notifications
       {"cmd": "write", "data": hex}  write without response to RX
       {"cmd": "scan", "ms": n}       listen n ms: does anyone advertise the Wisp service?
       {"cmd": "disconnect"}
  out  {"ev": "listening", "port": n}
       {"ev": "connected", "mtu": n, "props": {...}}
       {"ev": "notify", "data": hex}  a TX notification
       {"ev": "scanned", "wisp": n}   Wisp advertisements seen during a scan
       {"ev": "disconnected", "reason": n}
       {"ev": "conn_params", ...}     what the firmware asked for (LE Connection Update)
       {"ev": "phy", ...}, {"ev": "data_length", ...}
       {"ev": "error", "message": s}

Nothing here touches a real radio or a real device.
"""

import argparse
import asyncio
import collections
import json
import logging
import sys

from bumble import hci
from bumble.controller import Controller
from bumble.core import AdvertisingData, UUID
from bumble.device import Device, Peer
from bumble.gatt import GATT_DEVICE_NAME_CHARACTERISTIC
from bumble.hci import Address
from bumble.link import LocalLink
from bumble.transport import open_transport
from bumble.transport.common import AsyncPipeSink

SERVICE = UUID("cf099bf1-f34e-49e2-b353-7f20e02243bc")
RX = UUID("cf099bf2-f34e-49e2-b353-7f20e02243bc")
TX = UUID("cf099bf3-f34e-49e2-b353-7f20e02243bc")


def emit(**msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


class GlassesController(Controller):
    """Bumble's controller plus what a real one (the EM9305 too) does and Bumble's model doesn't:

    - controller-to-host ACL flow control: no more ACL packets to the host than it has
      buffers (Host Buffer Size, Host Number Of Completed Packets). Without it the virtual
      link, which has no air time, floods Zephyr's few RX buffers and Zephyr drops packets.
    - the three link-layer procedures that Zephyr's peripheral starts by itself (connection
      update, PHY, data length). An unanswered async command makes Zephyr assert. Each one
      completes at once, as granted, and is reported to the test.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.flow_control = False
        self.host_credits = 0
        self.acl_backlog = collections.deque()

    def on_hci_set_controller_to_host_flow_control_command(self, command):
        self.flow_control = bool(command.flow_control_enable & 0x01)
        return super().on_hci_set_controller_to_host_flow_control_command(command)

    def on_hci_host_buffer_size_command(self, command):
        self.host_credits = command.host_total_num_acl_data_packets
        return super().on_hci_host_buffer_size_command(command)

    def on_hci_host_number_of_completed_packets_command(self, command):
        p = bytes(command.parameters)
        n = p[0]
        self.host_credits += sum(int.from_bytes(p[1 + 2 * n + 2 * i:3 + 2 * n + 2 * i], "little")
                                 for i in range(n))
        self.flush_acl()
        return None  # no response, by the spec

    def send_hci_packet(self, packet):
        if self.flow_control and isinstance(packet, hci.HCI_AclDataPacket):
            self.acl_backlog.append(packet)
            self.flush_acl()
            return
        super().send_hci_packet(packet)

    def flush_acl(self):
        while self.acl_backlog and self.host_credits > 0:
            self.host_credits -= 1
            super().send_hci_packet(self.acl_backlog.popleft())

    def on_hci_le_connection_update_command(self, command):
        self._send_hci_command_status(hci.HCI_SUCCESS, command.op_code)
        emit(ev="conn_params", interval_min=command.connection_interval_min,
             interval_max=command.connection_interval_max, latency=command.max_latency,
             timeout=command.supervision_timeout)
        self.send_hci_packet(hci.HCI_LE_Connection_Update_Complete_Event(
            status=hci.HCI_SUCCESS, connection_handle=command.connection_handle,
            connection_interval=command.connection_interval_min,
            peripheral_latency=command.max_latency,
            supervision_timeout=command.supervision_timeout))
        return None

    def on_hci_le_set_phy_command(self, command):
        self._send_hci_command_status(hci.HCI_SUCCESS, command.op_code)
        phy = hci.Phy.LE_2M if command.tx_phys & hci.PhyBit.LE_2M else hci.Phy.LE_1M
        emit(ev="phy", tx_phys=int(command.tx_phys), rx_phys=int(command.rx_phys))
        self.send_hci_packet(hci.HCI_LE_PHY_Update_Complete_Event(
            status=hci.HCI_SUCCESS, connection_handle=command.connection_handle,
            tx_phy=phy, rx_phy=phy))
        return None

    def on_hci_le_set_data_length_command(self, command):
        emit(ev="data_length", tx_octets=command.tx_octets, tx_time=command.tx_time)
        asyncio.get_running_loop().call_soon(self.send_hci_packet, hci.HCI_LE_Data_Length_Change_Event(
            connection_handle=command.connection_handle, max_tx_octets=command.tx_octets,
            max_tx_time=command.tx_time, max_rx_octets=251, max_rx_time=2120))
        return hci.HCI_StatusAndConnectionHandleReturnParameters(
            status=hci.HCI_SUCCESS, connection_handle=command.connection_handle)


def advertises_wisp(adv) -> bool:
    for kind in (AdvertisingData.COMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS,
                 AdvertisingData.INCOMPLETE_LIST_OF_128_BIT_SERVICE_CLASS_UUIDS):
        if SERVICE in (adv.data.get(kind) or []):
            return True
    return False


class Central:
    def __init__(self, device: Device):
        self.device = device
        self.connection = None
        self.peer = None
        self.rx = None
        self.wisp_adverts = 0
        self.found = None
        device.on("advertisement", self.on_advertisement)

    def on_advertisement(self, adv):
        if advertises_wisp(adv):
            self.wisp_adverts += 1
            if self.found and not self.found.done():
                self.found.set_result(adv)

    async def connect(self):
        self.found = asyncio.get_running_loop().create_future()
        await self.device.start_scanning(filter_duplicates=False)
        adv = await asyncio.wait_for(self.found, 20)
        await self.device.stop_scanning()
        conn = await self.device.connect(adv.address)
        self.connection = conn
        conn.on("disconnection", lambda reason: self.on_disconnection(reason))
        self.peer = Peer(conn)
        mtu = await self.peer.request_mtu(247)
        services = await self.peer.discover_service(SERVICE)
        if not services:
            raise RuntimeError("Wisp service not found")
        service = services[0]
        await service.discover_characteristics()
        rx = service.get_characteristics_by_uuid(RX)
        tx = service.get_characteristics_by_uuid(TX)
        if not rx or not tx:
            raise RuntimeError("Wisp RX/TX characteristics not found")
        self.rx = rx[0]
        names = await self.peer.read_characteristics_by_uuid(GATT_DEVICE_NAME_CHARACTERISTIC)
        await self.peer.subscribe(tx[0], lambda value: emit(ev="notify", data=bytes(value).hex()))
        emit(ev="connected", mtu=mtu, props={"rx": int(self.rx.properties), "tx": int(tx[0].properties)},
             name=bytes(names[0]).decode() if names else None)

    def on_disconnection(self, reason):
        self.connection = None
        self.peer = None
        emit(ev="disconnected", reason=int(reason))

    async def write(self, data: bytes):
        if not self.peer:
            raise RuntimeError("not connected")
        await self.peer.write_value(self.rx, data, with_response=False)

    async def scan(self, ms: int):
        before = self.wisp_adverts
        await self.device.start_scanning(filter_duplicates=False)
        await asyncio.sleep(ms / 1000)
        await self.device.stop_scanning()
        emit(ev="scanned", wisp=self.wisp_adverts - before)

    async def disconnect(self):
        if self.connection:
            await self.connection.disconnect()


async def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=0, help="TCP port for the firmware's HCI (0 = pick)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)

    port = args.port
    if port == 0:
        probe = await asyncio.start_server(lambda r, w: None, "127.0.0.1", 0)
        port = probe.sockets[0].getsockname()[1]
        probe.close()
        await probe.wait_closed()

    link = LocalLink()
    transport = await open_transport(f"tcp-server:127.0.0.1:{port}")
    # Bumble's virtual LE link routes packets by random address. Without a public address the
    # firmware's Zephyr host makes up a static random identity and sets it, as it would on
    # any controller without one; the central uses its random address too.
    GlassesController("glasses", host_source=transport.source, host_sink=transport.sink, link=link)
    phone = Controller("phone", link=link)
    device = Device.with_hci("phone", Address("C0:FF:EE:00:00:02"), phone, AsyncPipeSink(phone))
    await device.power_on()
    central = Central(device)
    emit(ev="listening", port=port)

    reader = asyncio.StreamReader()
    await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    queue: asyncio.Queue = asyncio.Queue()

    async def worker():
        # Commands run in order, so writes keep their order on the link.
        while True:
            cmd = await queue.get()
            try:
                if cmd["cmd"] == "connect":
                    await central.connect()
                elif cmd["cmd"] == "write":
                    await central.write(bytes.fromhex(cmd["data"]))
                elif cmd["cmd"] == "scan":
                    await central.scan(int(cmd.get("ms", 1000)))
                elif cmd["cmd"] == "disconnect":
                    await central.disconnect()
            except Exception as e:  # reported to the test, which fails on it
                emit(ev="error", message=f"{cmd['cmd']}: {e!r}")

    task = asyncio.create_task(worker())
    while line := await reader.readline():
        queue.put_nowait(json.loads(line))
    task.cancel()
    transport.close()


if __name__ == "__main__":
    asyncio.run(main())
