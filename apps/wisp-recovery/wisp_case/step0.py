# SPDX-License-Identifier: MIT
"""Recovery step 0 (docs/wisp/recovery.md): prove USB -> case RAM bridge -> pogo UART2 ->
temple with one read-only version query. Writes no flash, option bytes or MRAM anywhere.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from . import bridge as br
from . import pins
from .rom import RomError, read_exact
from .transport import case_banner, enter_rom, find_case_port, serial_opener

PLAN = """\
Recovery step 0: what this tool sends, in order.

  To the case (STM32G0B1 through its CH340, USB-C):
   1. RTS reset pulse, DTR asserted (normal boot); listen 6 s for the
      "****** B200 1.2.57" banner at 1 Mbaud. Nothing is sent.          case MCU reset, read-only
   2. RTS reset pulse, DTR released -> STM32 ROM loader; 0x7F sync,
      Get (0x00), Get ID (0x02); require protocol 0x31, product 0x467.  case MCU reset, read-only
   3. Read Memory (0x11) of the case application, 0x08000000 + 55,752
      bytes; require SHA-256 773b6d4c... (B200 1.2.57). Kept in RAM only. read-only
   4. Write Memory (0x31) to case SRAM only: zeros to 0x20011B00 (8 B)
      and 0x20011A00 (160 B), the pinned 1,720-byte bridge to
      0x20010000; each block read back (0x11).                          RAM-only
   5. Go (0x21) to 0x20010000.                                          RAM-only (runs from SRAM)
   6. Bridge request G2RQ op 2 (version), route <side>.                 RAM-only
      The bridge (webflasher, MIT) then, on its own:
        - reads 10 YHM2510 pogo-switch registers over I2C and stops
          with status 3 (zero writes) unless they match a seated-idle
          profile;                                                      read-only
        - selects the route (YHM regs 3/4, 5, 6, 7) and pulses PA3;     volatile register writes
        - sends the temple 5 bytes: 24 00 01 00 a7 (version query);     temple: read-only query
        - captures the 5A A5 FF reply for ~1 s;                         read-only
        - writes the 5 YHM registers back and re-reads all 10;          volatile register writes
        - reports G2RS, stores its record in SRAM, resets the case.     case MCU reset
   7. RTS reset into the ROM loader again; Get, Get ID; Read Memory of
      the bridge record and proof; Write Memory zeros over all three
      SRAM regions, read back.                                          RAM-only
   8. RTS reset with DTR asserted: normal case app; require the
      "B200 1.2.57" banner again.                                       case MCU reset, read-only

  To the temple: only step 6's 24 00 01 00 a7. No reset, no OTA (0x52-0x55),
  no bootloader traffic. The stock main app answers 5A A5 FF 09 24 ... sum.

  Never sent, refused in code: ROM erase (0x43/0x44), write-protect (0x63/0x73),
  readout-protect (0x82/0x92), Write Memory outside the three SRAM regions or with
  bytes other than the pinned bridge or zeros, Go anywhere but 0x20010000, any
  bridge operation other than version.
"""


class Step0Error(RuntimeError):
    pass


def run(device: str, side: str, opener=serial_opener, sleep=time.sleep, clock=time.monotonic,
        echo=print, report: dict | None = None) -> dict:
    report = {} if report is None else report
    report.update({"device": device, "side": side, "events": [], "case_flash_writes": False,
                   "temple_writes": False, "success": False})

    def log(event):
        report["events"].append(event)
        echo(json.dumps(event))

    image = pins.bridge_image()
    operation = pins.BRIDGE_OP_VERSION
    request = br.make_request(operation, side, image)
    log({"bridge_sha256": pins.BRIDGE_SHA256, "g2rq": request.hex(),
         "temple_request": br.temple_request(operation, image).hex()})

    before = case_banner(device, opener, sleep, clock)
    log({"case_listen_before": {k: before[k] for k in ("version", "fresh_boot", "banner_t", "lines", "chunks")}})
    report["case_version_before"] = before["version"]
    if before["version"] != pins.CASE_VERSION:
        raise Step0Error(f"case reports {before['version']!r}, expected {pins.CASE_VERSION}; nothing loaded")

    bridge_launched = False
    bridge_answered = False
    sram_dirty = False
    try:
        port, loader = enter_rom(device, image, opener, sleep, log)
        try:
            flash = loader.read_range(pins.CASE_IMAGE_BASE, pins.CASE_IMAGE_LENGTH)
            digest = hashlib.sha256(flash).hexdigest()
            del flash  # never stored or printed
            log({"case_image_sha256": digest})
            if digest != pins.CASE_IMAGE_SHA256:
                raise Step0Error("case flash is not the pinned B200 1.2.57 image; bridge not loaded")
            sram_dirty = True
            loader.load_bridge()
            loader.go_bridge()
            bridge_launched = True
            port.timeout = 6.0
            banner = read_exact(port, len(pins.BRIDGE_BANNER), "bridge banner")
            log({"bridge_banner": banner.decode("ascii", "replace")})
            if banner != pins.BRIDGE_BANNER:
                raise Step0Error("bridge banner mismatch")
            port.write(request)
            port.flush()
            port.timeout = 12.0
            head = read_exact(port, 12, "bridge response header")
            tail = read_exact(port, min(head[9], 64) + 1, "bridge response tail")
            log({"g2rs": (head + tail).hex()})
            bridge_answered = True
            response = br.parse_response(head, tail, request)
        finally:
            port.close()
        report["temple_raw"] = response["captured"].hex()
        report["bridge_status"] = response["status"]
        log({"bridge_status": response["status"], "bridge_status_text": response["status_text"],
             "temple_raw": response["captured"].hex(), "uart_errors": response["uart_errors"]})

        sleep(0.3)  # the bridge resets the case after G2RS; let the ROM come up
        port, loader = enter_rom(device, image, opener, sleep, log)
        try:
            proof = loader.read_memory(pins.PROOF_ADDRESS, len(pins.PROOF))
            result = loader.read_memory(pins.RESULT_ADDRESS, pins.RESULT_LENGTH)
            retained = br.validate_retained(result, proof, response, operation, side)
            log({"bridge_record": retained})
            report["bridge_record"] = retained
            loader.clear_sram()
            sram_dirty = False
            log({"case_sram_cleared": True})
        finally:
            port.close()

        if response["status"] != 0:
            raise Step0Error(f"bridge status {response['status']}: {response['status_text']}")
        report["temple"] = br.decode_version(response["captured"])
        log({"temple_version": report["temple"]})
    except BaseException as error:
        report["error"] = repr(error)
        if sram_dirty:
            try:
                if bridge_launched:
                    # Never reset the case under a running bridge: its loops are bounded
                    # (about 6 s worst case) and it restores the YHM route before it
                    # resets itself. Give it that time when its reply never came.
                    sleep(0.3 if bridge_answered else 12.0)
                port, loader = enter_rom(device, image, opener, sleep, log)
                try:
                    loader.clear_sram()
                    log({"case_sram_cleared_after_error": True})
                finally:
                    port.close()
            except Exception as cleanup:  # noqa: BLE001
                log({"cleanup_error": repr(cleanup)})
        raise
    finally:
        after = case_banner(device, opener, sleep, clock)
        report["case_version_after"] = after["version"]
        log({"case_listen_after": {k: after[k] for k in ("version", "fresh_boot", "banner_t", "lines", "chunks")}})
        log({"case_back_to_stock": after["version"] == pins.CASE_VERSION, "case_version": after["version"]})

    if report["case_version_after"] != pins.CASE_VERSION:
        raise Step0Error("case did not come back with its 1.2.57 banner")
    report["success"] = True
    return report


def probe_reset(device: str, out: Path, opener=serial_opener, sleep=time.sleep, clock=time.monotonic,
                echo=print) -> int:
    """Only the app-boot reset (same line sequence as step 0's first listen), listening for
    the whole window. Sends no bytes; never enters the ROM loader."""
    result = case_banner(device, opener, sleep, clock, listen_full=True)
    report = {"mode": "probe-reset", "device": device, **{k: result[k] for k in
              ("version", "fresh_boot", "banner_t", "lines", "chunks")}}
    for line in result["lines"]:
        echo(f"line  t={line['t']:.4f}s  {line['action']}")
    for chunk in result["chunks"]:
        echo(f"rx    t={chunk['t']:.4f}s  {chunk['n']:4d} B  {chunk['text']!r}")
    verdict = (f"fresh boot banner at t={result['banner_t']}s, case version {result['version']}"
               if result["fresh_boot"] else "NO fresh boot banner: the RTS pulse did not visibly reset the case")
    echo(f"probe-reset: {verdict}")
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"probe-reset-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    path.write_text(json.dumps(report, indent=2) + "\n")
    echo(f"report: {path}")
    if not result["fresh_boot"]:
        return 2
    return 0 if result["version"] == pins.CASE_VERSION else 3


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", help="case serial port (default: the only /dev/cu.*usbserial*)")
    p.add_argument("--side", choices=sorted(pins.ROUTES), default="left")
    p.add_argument("--plan", action="store_true", help="print what would be sent, touch nothing")
    p.add_argument("--restore", action="store_true",
                   help="only reset the case into its normal app and print its banner")
    p.add_argument("--probe-reset", action="store_true",
                   help="diagnostic: pulse RTS with DTR in the app-boot state, listen, report "
                        "whether a fresh boot banner appeared; no ROM entry, no loading, no bridge")
    p.add_argument("--out", type=Path, default=Path(__file__).resolve().parents[1] / "runs")
    a = p.parse_args(argv)
    if a.plan:
        print(PLAN.replace("<side>", a.side))
        return 0
    device = a.port or find_case_port()
    if a.probe_reset:
        return probe_reset(device, a.out)
    if a.restore:
        result = case_banner(device, serial_opener)
        print(result["banner"])
        print(f"case version: {result['version']}")
        return 0 if result["version"] == pins.CASE_VERSION else 1
    report: dict = {}
    code = 1
    try:
        run(device, a.side, report=report)
        code = 0
    except (Step0Error, RomError, ValueError) as error:
        print(f"STOPPED: {error}", file=sys.stderr)
    finally:
        a.out.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        path = a.out / f"step0-{stamp}.json"
        path.write_text(json.dumps(report, indent=2, default=str) + "\n")
        print(f"report: {path}")
    if code == 0:
        t = report["temple"]
        print(f"OK: {a.side} temple firmware {t['firmware']}, hardware {t['hardware_revision']}; "
              f"raw {report['temple_raw']}; case {report['case_version_after']} restored")
    return code
