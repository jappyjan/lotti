# SPDX-License-Identifier: MIT
"""W18: install drdaeman's patched bootloader once per temple, then use its UART2 loader
through the charging case. docs/wisp/recovery.md, "W18 procedure", is the runbook.

  bootloader-plan     what will be written, where, the hashes, the preconditions (touches nothing)
  bootloader-install  the one bootloader write, over the stock BLE OTA; needs --go <token>
  loader-hello        read-only: claim the loader through the case, CRC the bootloader twice, release
  info-dump           read-only: MCUCTRL, PWRCTRL, INFO0, INFOC, DCU/LCS (when powered), release
  link-soak           read-only: stream N bytes of the app region out through the loader (dump), as
                      long and as dense a session as recover's write, and check them against its CRC
  recover             write the pinned stock 2.4.0.24 main app to MRAM through the loader
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
import zlib
from datetime import UTC, datetime
from pathlib import Path

from . import image, pins
from .links import CaseRelayLink, SocketLink
from .session import BLOCK, Session, SessionError

RUNS = Path(__file__).resolve().parents[1] / "runs"


def plan_text(side: str, patched: bytes) -> str:
    pages = len(patched) // 4096
    crc = zlib.crc32(patched)
    return f"""\
W18 bootloader install, {side} temple: what gets written, where, and what must hold first.

Image   drdaeman/g2-bootloader-patch @ 1d22097 (MIT) applied to the stock 2.3.2.14 bootloader
        stock input   ota/s200_bootloader.bin from bundle 2.3.2.14 (sha256 {pins.BUNDLE_2_3_2_14_SHA256[:16]}...)
                      {pins.STOCK_BOOTLOADER_BYTES} bytes, sha256 {pins.STOCK_BOOTLOADER_SHA256}
        changes       0x42E656: 4 bytes  fff789ff -> {pins.HOOK_NEW.hex()}  (bl 0x43511c: loader, then the stock flag check)
                      0x434900-0x435B6B: 4,716 bytes appended (patch.bin sha256 {pins.PATCH_BIN_SHA256[:16]}..., MIT)
                      0x435B6C-0x435FFF: 0xFF padding to the page
        output        {len(patched)} bytes = {pages} x 4 KiB, sha256 {image.sha(patched)}
                      CRC-32 {crc:08x} (what loader-hello reads back)
Where   MRAM [0x410000, 0x{0x410000 + len(patched):06X}) only. The SBL (0x400000-0x410000), the main app
        (0x438000-) and the update flag (0x7FE000) are not touched.
How     the stock 2.4.0.24 app's BLE OTA, nothing else:
          auth (sid 0x80) -> BEGIN -> FILE_CHECK type 1, storage 3, ota/s200_bootloader.bin,
          {len(patched)} B, CRC-32C {image.crc32c_fast(patched):08x} -> {pages} DATA blocks of 4096 B (one ack
          each) -> END. The app re-reads the staged file (size, CRC-32C), answers 8, and then
          copies it to MRAM 0x410000 in {pages} chunks of 4 KiB, lowest address first. No reset.
Window  from the first chunk at 0x410000 to the last: the app's synchronous copy, about one
        second [I]. A reset or power loss inside it leaves a mixed bootloader: SWD-only.
        Before END: nothing in MRAM changed (a dropped link or a cut is harmless).
        After the copy: the old bootloader is gone; the new one runs at the next reset.

Preconditions (bootloader-install checks the ones marked *):
  * the image above rebuilds from the cached bundle and matches every pin
  * the 2.4.0.24 bundle is cached and its main app matches its pin (rule 7: stock offline)
  * the case relay rebuilds and matches its pin ({pins.RELAY_SHA256['observed-33'][:16]}..., observed-33)
  * a passed step-0 report for the {side} temple from the last 24 h: case 1.2.57,
    temple app 2.4.0.24, hardware 5
  * the BLE device advertises as the {side} temple (name ..._{side[0].upper()}_xxxxxx), MTU >= 243,
    stock authentication passes
  * --battery N with N >= 80 (read it in the Even app first)
  * --go {pins.go_token(side)}  (Jan's per-flash go, rule 4)
    the {side} temple OUT of the case, flat on the table, nothing that can bump it; phone
    Bluetooth off; Even app and Lotti force-quit; the whole pair out of the case

After it: put the {side} temple in the case and run `w18.py loader-hello --side {side}`.
"""


def save(report: dict, name: str) -> Path:
    RUNS.mkdir(parents=True, exist_ok=True)
    path = RUNS / f"{name}-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}.json"
    path.write_text(json.dumps(report, indent=2, default=str) + "\n")
    return path


def latest_step0(side: str, max_age_h: float = 24.0) -> dict:
    reports = sorted(RUNS.glob("step0-*.json"))
    for path in reversed(reports):
        data = json.loads(path.read_text())
        if data.get("side") != side:
            continue
        age = time.time() - path.stat().st_mtime
        if not data.get("success"):
            raise SystemExit(f"latest step-0 report for {side} ({path.name}) did not pass")
        if age > max_age_h * 3600:
            raise SystemExit(f"latest step-0 report for {side} is {age / 3600:.0f} h old; rerun step 0")
        temple = data.get("temple", {})
        if (data.get("case_version_after"), temple.get("firmware"), temple.get("hardware_revision")) != (
            "1.2.57", pins.STOCK_MAIN_VERSION, 5
        ):
            raise SystemExit(f"step-0 report {path.name} is not case 1.2.57 / app 2.4.0.24 / hardware 5")
        return {"report": path.name, "profile": data.get("bridge_profile")}
    raise SystemExit(f"no step-0 report for the {side} temple in {RUNS}; run step0.py --side {side} first")


def make_link(args):
    if args.renode_port:
        return SocketLink(args.renode_port)
    from wisp_case.transport import find_case_port

    return CaseRelayLink(args.port or find_case_port(), args.side, args.case_profile, log=lambda e: print(json.dumps(e)))


def cmd_plan(args) -> int:
    patched = image.build_patched_bootloader()
    image.stock_main()
    image.build_relay("observed-33")
    print(plan_text(args.side, patched))
    return 0


def cmd_install(args) -> int:
    patched = image.build_patched_bootloader()
    image.stock_main()
    image.build_relay(args.case_profile)
    report = {"side": args.side, "image_sha256": image.sha(patched), "bytes": len(patched), "battery": args.battery}
    if args.go != pins.go_token(args.side):
        print(f"REFUSED: --go must be exactly {pins.go_token(args.side)} (bootloader-plan prints it)", file=sys.stderr)
        return 2
    if args.battery is None or args.battery < 80:
        print("REFUSED: --battery must be >= 80 (read it in the Even app)", file=sys.stderr)
        return 2
    report["step0"] = latest_step0(args.side)
    from .ble import BleakGatt, StockOta, side_of

    async def run() -> int:
        async with BleakGatt(args.address, args.adapter) as gatt:
            report["ble_name"], report["mtu"] = gatt.name, gatt.mtu
            if side_of(gatt.name) != args.side:
                raise SystemExit(f"REFUSED: {gatt.name!r} is not the {args.side} temple; nothing sent")
            if gatt.mtu < 243:
                raise SystemExit(f"REFUSED: MTU {gatt.mtu} < 243; nothing sent")
            ota = StockOta(gatt)
            await ota.authenticate()
            print(f"connected to {gatt.name}, MTU {gatt.mtu}, stock auth OK; sending {len(patched)} B")
            try:
                status = await ota.install(patched)
            finally:
                report["blocks_acked"], report["end_status"] = ota.blocks_acked, ota.end_status
            print(f"END status {status}: the app is copying the file to MRAM 0x410000 now")
        report["liveness"] = await liveness(args)
        return 0

    try:
        code = asyncio.run(run())
        report["success"] = code == 0
    except BaseException as error:  # noqa: BLE001 - reported, then exit 1
        report["error"] = repr(error)
        print(f"STOPPED: {error!r}", file=sys.stderr)
        if report.get("end_status") == 8:
            print("END was accepted, so the MRAM copy ran or is running. Do NOT resend. Leave the temple "
                  "powered; follow recovery.md 'If the install stops after END'.", file=sys.stderr)
        code = 1
    print(f"report: {save(report, f'w18-install-{args.side}')}")
    if code == 0:
        print(f"NEXT: put the {args.side} temple in the case, then: w18.py loader-hello --side {args.side}")
    return code


LIVENESS_DELAY = 5.0  # s after END 8; the copy is synchronous in the app's OTA task (~1 s)


async def liveness(args) -> dict:
    """After END 8: does the main app still serve a stock request? On a NEW BLE connection:
    re-authenticating on the install connection times out on hardware (2026-11-06, step C),
    though the app is fine. Informational only; it sends nothing that changes the temple, and
    step D (loader-hello) is the proof of what is in MRAM."""
    from .ble import BleakGatt, StockOta, side_of

    await asyncio.sleep(LIVENESS_DELAY)
    try:
        async with BleakGatt(args.address, args.adapter) as gatt:
            if side_of(gatt.name) != args.side:
                raise RuntimeError(f"reconnected to {gatt.name!r}, not the {args.side} temple")
            await StockOta(gatt, log=lambda m: None).authenticate()
        print("main app still answers after the copy (new BLE connection, stock authentication OK)")
        return {"ok": True}
    except Exception as error:  # noqa: BLE001 - informational
        print(f"NOTE: the liveness check got no answer ({error!r}). By itself this is not a failure: END "
              "status 8 was accepted and the copy runs inside the app. Do NOT resend. Leave the temple on "
              "the table for a minute, then go to step D (loader-hello), which proves what is in MRAM.",
              file=sys.stderr)
        return {"ok": False, "error": repr(error)}


def short_frames(recent: list[dict], n: int = 6) -> list[str]:
    out = []
    for e in recent[-n:]:
        got = e.get("received")
        out.append(f"#{e['n']} t={e['t']}s > {e['sent'][:64]} < {got[:64] if got else e.get('error', 'no reply')}")
    return out


def with_session(args, name: str, body) -> int:
    patched = image.build_patched_bootloader()
    report: dict = {"side": args.side, "command": name}
    code = 1
    link = session = None
    try:
        link = make_link(args)
        session = Session(link)
        with session:
            session.require_patched_bootloader(patched)
            report.update(body(session, patched) or {})
        report["success"] = True
        code = 0
    except BaseException as error:  # noqa: BLE001 - reported
        # The error that ended the session, not whatever the cleanup ran into afterwards.
        report["error"] = repr(error)
        print(f"STOPPED: {error!r}", file=sys.stderr)
        if session is not None:
            report["stopped_in"] = session.step
            report["position"] = session.position
            report["cleanup_errors"] = session.cleanup_errors
            print(f"  while: {session.step} {session.position or ''}", file=sys.stderr)
            for failure in session.cleanup_errors:
                print(f"  cleanup also failed: {failure}", file=sys.stderr)
    finally:
        if link is not None and hasattr(link, "diagnostics"):
            report["link"] = link.diagnostics()
            if not report.get("success"):
                print("  last frames (> host, < temple):", file=sys.stderr)
                for line in short_frames(report["link"]["recent"]):
                    print(f"    {line}", file=sys.stderr)
    print(f"report: {save(report, f'w18-{name}-{args.side}')}")
    return code


def cmd_hello(args) -> int:
    def body(session, patched):
        second = session.bootloader_crc()
        flag = session.flag()
        print(f"OK: patched loader answers on the {args.side} temple; bootloader CRC-32 {second:08x} twice; "
              f"update flag {flag:#010x}")
        return {"bootloader_crc32": f"{second:08x}", "flag": f"{flag:#010x}"}

    return with_session(args, "loader-hello", body)


def cmd_info(args) -> int:
    def body(session, patched):
        info = session.info_dump()
        print(json.dumps(info, indent=2))
        return {"info": info}

    return with_session(args, "info-dump", body)


def cmd_soak(args) -> int:
    length = args.bytes
    if not 16 <= length <= pins.RECOVER_END - pins.RECOVER_BASE or length % 16:
        print(f"REFUSED: --bytes must be a multiple of 16 in [16, {pins.RECOVER_END - pins.RECOVER_BASE}]",
              file=sys.stderr)
        return 2

    def body(session, patched):
        start = time.monotonic()
        last = [0]

        def progress(count):
            if count - last[0] >= 64 * 1024 or count == length:
                last[0] = count
                rate = count / max(time.monotonic() - start, 1e-3)
                print(f"{count}/{length} bytes read ({rate / 1024:.2f} KiB/s, "
                      f"{session.link.recent.count} exchanges)", flush=True)

        session.step = f"stream {length} bytes out (dump)"
        session.position = {"target": f"{pins.RECOVER_BASE:#x}+{length}"}
        data = session.dump(pins.RECOVER_BASE, length, progress)
        seconds = time.monotonic() - start
        session.step = "CRC of the same range"
        crc = session.checksum(pins.RECOVER_BASE, length)
        if crc != zlib.crc32(data):
            raise SessionError(f"streamed bytes CRC {zlib.crc32(data):08x} != temple CRC {crc:08x}")
        exchanges = session.link.recent.count
        print(f"OK: {length} bytes streamed and matched the temple's CRC ({crc:08x}) in {seconds:.0f} s, "
              f"{exchanges} exchanges, {1000 * seconds / max(exchanges, 1):.1f} ms each; releasing boot")
        return {"bytes": length, "crc32": f"{crc:08x}", "seconds": round(seconds, 1), "exchanges": exchanges}

    return with_session(args, "link-soak", body)


def cmd_recover(args) -> int:
    data = Path(args.image).read_bytes()
    try:
        stock = image.main_from_bundle(data) if data[:8] == b"EVENOTA\0" else data
    except image.ImageError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    if image.sha(stock) != pins.STOCK_MAIN_SHA256:
        print("REFUSED: --image is not the pinned stock 2.4.0.24 main app (bundle or raw image)", file=sys.stderr)
        return 2

    def body(session, patched):
        flag = session.flag()
        print(f"update flag {flag:#010x}")
        if flag == 0x55555555 and not args.allow_pending_flag:
            raise SystemExit("REFUSED: the update flag is set; the bootloader would install the staged OTA "
                             "file after release. Pass --allow-pending-flag if that is intended.")
        start = time.monotonic()
        first = BLOCK  # the first verified block shows at once that streaming works

        def progress(count):
            if count == first or count % (64 * 1024) == 0 or count >= len(stock) - 16:
                rate = count / max(time.monotonic() - start, 1e-3)
                print(f"{count}/{len(stock)} bytes written and read back ({rate / 1024:.1f} KiB/s)", flush=True)

        result = session.write_app(stock, progress)
        print(f"OK: stock {pins.STOCK_MAIN_VERSION} main app written and verified ({result['crc_after']}); releasing boot")
        return {"flag": f"{flag:#010x}", **result, "seconds": round(time.monotonic() - start, 1)}

    return with_session(args, "recover", body)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    def common(sp, link=True):
        sp.add_argument("--side", choices=pins.SIDES, required=True)
        if link:
            sp.add_argument("--port", help="case serial port (default: the only /dev/cu.*usbserial*)")
            sp.add_argument("--case-profile", choices=sorted(pins.RELAY_SHA256), default="observed-33",
                            help="YHM baseline table of the case (Jan's case: observed-33, from step 0)")
            sp.add_argument("--renode-port", type=int, help=argparse.SUPPRESS)  # emulation only

    common(sub.add_parser("bootloader-plan", help="print the plan; touches nothing"), link=False)
    sp = sub.add_parser("bootloader-install", help="the one bootloader write (stock BLE OTA)")
    common(sp, link=False)
    sp.add_argument("--address", required=True, help="the temple's BLE address/UUID")
    sp.add_argument("--adapter", help="Linux BlueZ adapter (not used on macOS)")
    sp.add_argument("--battery", type=int, help="battery % read in the Even app; must be >= 80")
    sp.add_argument("--case-profile", choices=sorted(pins.RELAY_SHA256), default="observed-33")
    sp.add_argument("--go", required=True, help="the token bootloader-plan prints")
    common(sub.add_parser("loader-hello", help="read-only loader check through the case"))
    common(sub.add_parser("info-dump", help="read-only INFO0/INFOC/debug-lock dump"))
    sp = sub.add_parser("link-soak", help="read-only: stream the app region out through the loader")
    common(sp)
    sp.add_argument("--bytes", type=lambda v: int(v, 0), default=1 << 20,
                    help="bytes of the app region to stream (default 1 MiB, about 65,536 exchanges)")
    sp = sub.add_parser("recover", help="write the pinned stock main app through the loader")
    common(sp)
    sp.add_argument("--image", required=True, help="the 2.4.0.24 bundle (.wisp-cache/stock/g2-2.4.0.24.bin) or its raw main image")
    sp.add_argument("--allow-pending-flag", action="store_true")
    a = p.parse_args(argv)
    return {"bootloader-plan": cmd_plan, "bootloader-install": cmd_install, "loader-hello": cmd_hello,
            "info-dump": cmd_info, "link-soak": cmd_soak, "recover": cmd_recover}[a.command](a)
