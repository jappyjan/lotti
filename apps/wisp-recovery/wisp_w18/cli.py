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

Case relay sessions stalled on hardware about 20 s after the relay started: the case's YHM4005
watchdog reset the case, because only the case app fed it (recovery.md, "Long relay sessions").
The default relay (observed-33-feed) feeds it, so session length no longer matters. `recover`
still splits its write into sessions of at most --max-session-s seconds after the relay starts,
resuming each by CRC, so a stop costs at most one part; `link-soak` can do the same. With the
old observed-33 relay (--case-profile observed-33) keep sessions short, as before.
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
from .session import BLOCK, AppWriter, Session, SessionError

RUNS = Path(__file__).resolve().parents[1] / "runs"
# The left temple's relay sessions stopped 19.5-22.2 s after the relay started (link-soak) and
# about 20 s and 80 s in (recover): the case's watchdog. recovery.md, "Long relay sessions".
# Without the feed (observed-33) a session must end well inside 20 s; with it, parts are only a
# resume granularity: ten minutes of writing, about 500 KiB at 17.5 ms per exchange (17 exchanges
# per 256 body bytes).
DEFAULT_MAX_SESSION_S = 12.0
DEFAULT_MAX_SESSION_FEED_S = 600.0


def default_max_session_s(profile: str) -> float:
    return DEFAULT_MAX_SESSION_FEED_S if profile.endswith(pins.RELAY_FEED_SUFFIX) else DEFAULT_MAX_SESSION_S


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
  * the case relay rebuilds and matches its pin ({pins.RELAY_SHA256[pins.DEFAULT_CASE_PROFILE][:16]}..., {pins.DEFAULT_CASE_PROFILE})
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
    image.build_relay(pins.DEFAULT_CASE_PROFILE)
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


def stall_summary(diagnostics: dict) -> dict | None:
    """Where the first failed exchange of a session happened, in seconds since the relay started
    (the frames' `t` minus `relay_started_t`): what decides between a wall-time and a per-exchange
    cause of a stall."""
    failed = next((e for e in diagnostics.get("recent", []) if e.get("error")), None)
    if failed is None:
        return None
    out = {"exchange": failed["n"], "t": failed["t"]}
    if diagnostics.get("relay_started_t") is not None:
        out["since_relay_start_s"] = round(failed["t"] - diagnostics["relay_started_t"], 3)
    return out


def run_sessions(args, name: str, step, on_stop=None) -> int:
    """Run `step(session, patched, index) -> (finished, fields)` in held loader sessions, one
    after the other, until it says finished (most commands need one). Every session claims the
    loader, checks the bootloader CRC and releases it, with every gate of a single session. One
    report: the fields, each session's length, and for a session that stopped, the error that
    stopped it (not whatever the cleanup ran into), its step and position, the cleanup failures
    and its last frames. `on_stop(report)` adds to the report of a stopped run."""
    patched = image.build_patched_bootloader()
    report: dict = {"side": args.side, "command": name, "sessions": []}
    code = 1
    link = session = None
    try:
        index = 0
        while True:
            link = make_link(args)
            session = Session(link)
            entry: dict = {"index": index}
            report["sessions"].append(entry)
            with session:
                session.require_patched_bootloader(patched)
                finished, fields = step(session, patched, index)
                report.update(fields or {})
                entry["relay_seconds"] = round(session.elapsed(), 1)  # before the release
            entry["exchanges"] = getattr(getattr(link, "recent", None), "count", None)
            if finished:
                break
            index += 1
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
        if on_stop:
            on_stop(report)
    finally:
        if link is not None and hasattr(link, "diagnostics"):
            report["link"] = link.diagnostics()
            stall = stall_summary(report["link"])
            if stall:
                report["stall"] = stall
            if not report.get("success"):
                if stall and "since_relay_start_s" in stall:
                    print(f"  first failed exchange: #{stall['exchange']}, {stall['since_relay_start_s']} s "
                          f"after the relay started", file=sys.stderr)
                print("  last frames (> host, < temple):", file=sys.stderr)
                for line in short_frames(report["link"]["recent"]):
                    print(f"    {line}", file=sys.stderr)
    print(f"report: {save(report, f'w18-{name}-{args.side}')}")
    return code


def with_session(args, name: str, body) -> int:
    return run_sessions(args, name, lambda session, patched, index: (True, body(session, patched)))


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


class StreamCheck:
    """link-soak's read: [0x438000, +length) streamed out with `dump` and checked against the
    temple's CRC of the same bytes, in one session or, with a budget, in parts that each end
    inside it (every part CRC-checked in its own session)."""

    FIRST_RATE, FIRST_PART, RESERVE = 1.5e-3, 4096, 1.5  # as AppWriter

    def __init__(self, length: int, budget: float | None = None):
        self.length, self.budget = length, budget
        self.data = bytearray()
        self.rate, self.measured = self.FIRST_RATE, False
        self.seconds = 0.0
        self.exchanges = 0

    def _part(self, session) -> int:
        remaining = self.length - len(self.data)
        if self.budget is None:
            return remaining
        n = int((self.budget - session.elapsed() - self.RESERVE) / self.rate) // 16 * 16
        n = min(n if self.measured else min(n, self.FIRST_PART), remaining)
        if n < 16:
            raise SessionError(f"the session's checks used {session.elapsed():.1f} s of the {self.budget:g} s budget; "
                               "no room for a part (raise --max-session-s)")
        return n

    def run(self, session, progress=None) -> bool:
        at = len(self.data)
        n = self._part(session)
        address = pins.RECOVER_BASE + at
        whole = at == 0 and n == self.length
        session.step = f"stream {n} bytes out (dump)" if whole else f"stream bytes [{at}, {at + n}) of {self.length} out (dump)"
        session.position = {"target": f"{address:#x}+{n}", "streamed_before": at}
        count0 = session.link.recent.count
        started = session.clock()
        part = session.dump(address, n, (lambda c: progress(at + c)) if progress else None)
        took = session.clock() - started
        self.seconds += took
        self.exchanges += session.link.recent.count - count0
        if n >= 256 and took > 0:  # size later parts by the slowest rate seen so far
            self.rate = max(self.rate, took / n) if self.measured else took / n
            self.measured = True
        session.step = "CRC of the same range"
        crc = session.checksum(address, n)
        if crc != zlib.crc32(part):
            raise SessionError(f"streamed bytes CRC {zlib.crc32(part):08x} != temple CRC {crc:08x} at {address:#x}+{n}")
        self.data += part
        return len(self.data) == self.length


def cmd_soak(args) -> int:
    length = args.bytes
    if not 16 <= length <= pins.RECOVER_END - pins.RECOVER_BASE or length % 16:
        print(f"REFUSED: --bytes must be a multiple of 16 in [16, {pins.RECOVER_END - pins.RECOVER_BASE}]",
              file=sys.stderr)
        return 2
    budget = args.max_session_s or None
    if budget is not None and args.idle_s:
        print("REFUSED: --idle-s is a single-session experiment; leave out --max-session-s", file=sys.stderr)
        return 2
    reader = StreamCheck(length, budget)
    last = [0]

    def progress(count):
        if count - last[0] >= 64 * 1024 or count == length:
            last[0] = count
            print(f"{count}/{length} bytes read ({reader.exchanges} stream exchanges so far)", flush=True)

    def step(session, patched, index):
        fields = {}
        if index == 0 and args.idle_s:
            print(f"idle pause: no temple traffic until {args.idle_s:g} s after the relay started", flush=True)
            fields["idle_ticks_s"] = session.idle_until(args.idle_s)
            fields["idle_until_s"] = round(session.elapsed(), 1)
        finished = reader.run(session, progress)
        if budget is not None:
            print(f"session {index}: {len(reader.data)}/{length} bytes streamed and CRC-checked "
                  f"({session.elapsed():.1f} s since the relay started)", flush=True)
        if not finished:
            return False, fields
        crc = zlib.crc32(reader.data)
        ms = 1000 * reader.seconds / max(reader.exchanges, 1)
        print(f"OK: {length} bytes streamed and matched the temple's CRC ({crc:08x}) in {reader.seconds:.0f} s, "
              f"{reader.exchanges} exchanges, {ms:.1f} ms each, {index + 1} session(s); releasing boot")
        return True, {**fields, "bytes": length, "crc32": f"{crc:08x}", "seconds": round(reader.seconds, 1),
                      "exchanges": reader.exchanges, "ms_per_exchange": round(ms, 2), "max_session_s": budget}

    def on_stop(report):
        report["streamed_and_checked"] = len(reader.data)

    return run_sessions(args, "link-soak", step, on_stop)


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
    if args.max_session_s is None:
        args.max_session_s = default_max_session_s(args.case_profile)
    budget = args.max_session_s or None
    try:
        writer = AppWriter(stock, budget=budget, resume_at=args.resume_at)
    except SessionError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    start = time.monotonic()
    first = [True]  # the first verified block shows at once that streaming works

    def progress(count):
        if first[0] or count % (64 * 1024) == 0 or count >= writer.body_len:
            first[0] = False
            rate = (count - writer.resumed_at) / max(time.monotonic() - start, 1e-3)
            print(f"{count}/{writer.body_len} body bytes written and read back ({rate / 1024:.1f} KiB/s)", flush=True)

    def step(session, patched, index):
        flag = session.flag()
        if index == 0:
            print(f"update flag {flag:#010x}")
        if flag == 0x55555555 and not args.allow_pending_flag:
            raise SystemExit("REFUSED: the update flag is set; the bootloader would install the staged OTA "
                             "file after release. Pass --allow-pending-flag if that is intended.")
        finished = writer.run(session, progress)
        if budget is not None:
            print(f"session {index}: body {writer.done}/{writer.body_len} bytes written and CRC-checked "
                  f"({session.elapsed():.1f} s since the relay started)", flush=True)
        fields = {"flag": f"{flag:#010x}", "body_verified": writer.done, "max_session_s": budget,
                  "resumed_at": writer.resumed_at}
        if not finished:
            return False, fields
        result = writer.result
        print(f"OK: stock {pins.STOCK_MAIN_VERSION} main app written and verified ({result['crc_after']}) in "
              f"{writer.sessions} session(s); releasing boot")
        return True, {**fields, **result, "seconds": round(time.monotonic() - start, 1), "sessions_used": writer.sessions}

    def on_stop(report):
        report["body_verified"] = writer.done
        report["vectors_written"] = bool(writer.result.get("crc_after"))
        if writer.done and not report["vectors_written"]:
            hint = (f"w18.py recover --side {args.side} --image {args.image} --resume-at {writer.done}"
                    + (f" --max-session-s {budget:g}" if budget else " --max-session-s 0"))
            report["resume_with"] = hint
            print(f"  {writer.done} body bytes are written and CRC-verified; the vectors are not written. "
                  f"To continue later (it CRC-checks those bytes first): {hint}", file=sys.stderr)

    return run_sessions(args, "recover", step, on_stop)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    def common(sp, link=True):
        sp.add_argument("--side", choices=pins.SIDES, required=True)
        if link:
            sp.add_argument("--port", help="case serial port (default: the only /dev/cu.*usbserial*)")
            sp.add_argument("--case-profile", choices=sorted(pins.RELAY_SHA256), default=pins.DEFAULT_CASE_PROFILE,
                            help="the case relay: YHM baseline table of the case (Jan's case: observed-33, from "
                                 "step 0), '-feed' = it feeds the case's YHM4005 watchdog (default "
                                 f"{pins.DEFAULT_CASE_PROFILE}; observed-33 is the old relay, for comparison)")
            sp.add_argument("--renode-port", type=int, help=argparse.SUPPRESS)  # emulation only

    common(sub.add_parser("bootloader-plan", help="print the plan; touches nothing"), link=False)
    sp = sub.add_parser("bootloader-install", help="the one bootloader write (stock BLE OTA)")
    common(sp, link=False)
    sp.add_argument("--address", required=True, help="the temple's BLE address/UUID")
    sp.add_argument("--adapter", help="Linux BlueZ adapter (not used on macOS)")
    sp.add_argument("--battery", type=int, help="battery % read in the Even app; must be >= 80")
    sp.add_argument("--case-profile", choices=sorted(pins.RELAY_SHA256), default=pins.DEFAULT_CASE_PROFILE)
    sp.add_argument("--go", required=True, help="the token bootloader-plan prints")
    common(sub.add_parser("loader-hello", help="read-only loader check through the case"))
    common(sub.add_parser("info-dump", help="read-only INFO0/INFOC/debug-lock dump"))
    sp = sub.add_parser("link-soak", help="read-only: stream the app region out through the loader")
    common(sp)
    sp.add_argument("--bytes", type=lambda v: int(v, 0), default=1 << 20,
                    help="bytes of the app region to stream (default 1 MiB, about 65,536 exchanges)")
    sp.add_argument("--max-session-s", type=float, default=0.0,
                    help="split the stream into sessions that end within this many seconds after the relay "
                         "starts (default 0: one session)")
    sp.add_argument("--idle-s", type=float, default=0.0,
                    help="experiment: before streaming, keep the relay running without temple traffic (empty "
                         "G2TX) until this many seconds after it started; read-only")
    sp = sub.add_parser("recover", help="write the pinned stock main app through the loader")
    common(sp)
    sp.add_argument("--image", required=True, help="the 2.4.0.24 bundle (.wisp-cache/stock/g2-2.4.0.24.bin) or its raw main image")
    sp.add_argument("--allow-pending-flag", action="store_true")
    sp.add_argument("--max-session-s", type=float, default=None,
                    help=f"end every session within this many seconds after the relay starts; the write "
                         f"continues in the next session after a CRC check of what is written (default "
                         f"{DEFAULT_MAX_SESSION_FEED_S:g} with a feeding relay, {DEFAULT_MAX_SESSION_S:g} with "
                         f"observed-33; 0: one session)")
    sp.add_argument("--resume-at", type=lambda v: int(v, 0), default=0,
                    help="body bytes an earlier recover run wrote and verified (it prints the value); "
                         "they are CRC-checked against the image before anything is written")
    a = p.parse_args(argv)
    return {"bootloader-plan": cmd_plan, "bootloader-install": cmd_install, "loader-hello": cmd_hello,
            "info-dump": cmd_info, "link-soak": cmd_soak, "recover": cmd_recover}[a.command](a)
