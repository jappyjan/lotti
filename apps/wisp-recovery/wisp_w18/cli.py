# SPDX-License-Identifier: MIT
"""W18: install drdaeman's patched bootloader once per temple, then use its UART2 loader
through the charging case. docs/wisp/recovery.md, "W18 procedure", is the runbook.

  bootloader-plan     what will be written, where, the hashes, the preconditions (touches nothing)
  bootloader-install  the one bootloader write, over the stock BLE OTA; needs --go <token>
  loader-hello        read-only: claim the loader through the case, CRC the bootloader twice, release
                      (--no-release: end holding the temple in its loader, no CONT)
  held-reset-test     read-only: loader-hello --no-release, then a second session that must reset the
                      held temple and get its HELO (rung4.md W21; stop the plan if it does not)
  peek                read-only: allowlisted bootloader RAM/MRAM (NOR part, board strap, UART2, flag)
  pmic-read           read-only: the nPM1300 register snapshot (pmic_read.bin; first run: Jan's go)
  charge-on           WRITES the PMIC: stock charger settings and charging on (charge_on.bin)
  app-check           read-only: bootloader CRC, update flag, vectors, app region CRC vs known images
  boot-watch          CONT, then status queries to the booting app through the relay before G2EX
  ble-scan            read-only, no case: which Wisp and Even temples advertise near this machine
  info-dump           read-only: MCUCTRL, PWRCTRL, INFO0, INFOC, DCU/LCS (when powered), release
  link-soak           read-only: stream N bytes of the app region out through the loader (dump), as
                      long and as dense a session as recover's write, and check them against its CRC
  recover             write the pinned stock 2.4.0.24 main app to MRAM through the loader
  install-wisp        write a pinned Wisp native image to MRAM through the loader (rung4.md, R4-1,
                      approved 2026-11-08); pinned: native-0 (W23, wisp_w18/data/native-0/)

Two watchdogs limit a session, one in the case and one in the temple (recovery.md, "Long relay
sessions" and "The temple's watchdog"):
  - The case's YHM4005 reset the case about 20 s after the relay started, because only the case
    app fed it. The default relay (observed-33-feed) feeds it.
  - The temple's nPM1300 watchdog (armed by the stock app, 30.72 s, kicked every second by it)
    power-cycles a held temple about 30 s after the relay's reset. By default the session feeds
    it (feed.bin, dump_fed.bin, recover_fed.bin), so a session may last as long as it needs and
    `recover` writes in one session. --no-temple-feed runs drdaeman's programs only; then
    `recover` splits its write into sessions of at most --max-session-s (default 20) seconds
    after the relay starts, each resumed by CRC, as before.

Between two sessions of one command the case app runs SETTLE_S seconds after its banner before
the next ROM entry: right after two quick app restarts the pogo switch is not idle and the relay
refuses to start (status 3, zero writes; W18 F1d split). A refusal is recognised at once and the
session is retried once after the same settle.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import struct
import sys
import time
import zlib
from datetime import UTC, datetime
from pathlib import Path

from . import case_uart, image, native, pins, status
from .links import CaseRelayLink, PogoNotIdle, SocketLink
from .session import BLOCK, AppImage, AppWriter, RefusedError, Session, SessionError

RUNS = Path(__file__).resolve().parents[1] / "runs"
# The left temple's relay sessions stopped 19.5-22.2 s after the relay started (link-soak) and
# about 20 s and 80 s in (recover): the case's watchdog. recovery.md, "Long relay sessions".
# Without the case feed (observed-33) a session must end well inside 20 s. With it, the temple's
# nPM1300 watchdog power-cycled a held temple 30.3-31.4 s after the relay started (2026-11-07);
# without the temple feed a session must end before that: 20 s leaves the time for the part's
# CRC and the release. With both feeds a session has no limit (0).
DEFAULT_MAX_SESSION_S = 12.0
DEFAULT_MAX_SESSION_UNFED_TEMPLE_S = 20.0
# Seconds the case app runs after its banner before a later session (or a retry) enters the ROM.
# The app feeds the case's YHM4005 every 5 s, so this also gives the ROM phase a fresh window.
SETTLE_S = 5.0
POGO_RETRIES = 1  # retries of a session whose relay start was refused with status 3


def default_max_session_s(profile: str, temple_feed: bool = True) -> float:
    if not profile.endswith(pins.RELAY_FEED_SUFFIX):
        return DEFAULT_MAX_SESSION_S
    return 0.0 if temple_feed else DEFAULT_MAX_SESSION_UNFED_TEMPLE_S


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


def temple_feed(args) -> bool:
    return not getattr(args, "no_temple_feed", False)


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


def run_sessions(args, name: str, step, on_stop=None, fields=None, on_session=None) -> int:
    """Run `step(session, patched, index) -> (finished, fields)` in held loader sessions, one
    after the other, until it says finished (most commands need one). Every session claims the
    loader, checks the bootloader CRC and releases it, with every gate of a single session. One
    report: the fields, each session's length, and for a session that stopped, the error that
    stopped it (not whatever the cleanup ran into), its step and position, the cleanup failures
    and its last frames. `on_stop(report)` adds to the report of a stopped run; `on_session(session)`
    sees each Session before it claims the loader.

    Every session after the first lets the case app settle (SETTLE_S) before the ROM entry. A
    relay start refused with status 3 (pogo switch not idle, zero writes) is retried after the
    same settle, at most POGO_RETRIES times, and only when the case's record proved it wrote
    nothing."""
    patched = image.build_patched_bootloader()
    report: dict = {"side": args.side, "command": name, "temple_feed": temple_feed(args), "sessions": [],
                    **(fields or {})}
    code = 1
    link = session = None
    try:
        index = 0
        settle = False
        retries = 0
        while True:
            link = make_link(args)
            if settle and hasattr(link, "settle_s"):
                link.settle_s = SETTLE_S
            session = Session(link, temple_feed=temple_feed(args))
            if on_session:
                on_session(session)
            entry: dict = {"index": index}
            if settle:
                entry["settle_s"] = SETTLE_S
            report["sessions"].append(entry)
            try:
                with session:
                    session.require_patched_bootloader(patched)
                    finished, step_fields = step(session, patched, index)
                    report.update(step_fields or {})
                    entry["relay_seconds"] = round(session.elapsed(), 1)  # before the release
            except PogoNotIdle as refused:
                entry["pogo_not_idle"] = True
                if hasattr(link, "diagnostics"):
                    entry["link"] = link.diagnostics()  # its G2RS and the zero-write record
                report["pogo_not_idle"] = report.get("pogo_not_idle", 0) + 1
                print(f"session {index}: pogo switch not idle (relay status 3), zero writes, nothing sent to the "
                      "temple", file=sys.stderr, flush=True)
                if session.cleanup_errors or retries >= POGO_RETRIES:
                    raise refused
                retries += 1
                settle = True
                print(f"  retrying session {index} after the case app has run {SETTLE_S:g} s", file=sys.stderr,
                      flush=True)
                continue
            entry["exchanges"] = getattr(getattr(link, "recent", None), "count", None)
            entry["feeds"] = session.feeds
            if finished:
                break
            index += 1
            settle = True
            retries = 0
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
            if session.temple_reset_s is not None:  # the temple's watchdog fires 30-31 s in
                report["temple_reset_since_relay_start_s"] = session.temple_reset_s
                print(f"  the temple rebooted {session.temple_reset_s} s after the relay started", file=sys.stderr)
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


def hello_checks(session, side: str) -> dict:
    """loader-hello's reads after the first bootloader CRC: the CRC again and the update flag."""
    second = session.bootloader_crc()
    flag = session.flag()
    print(f"OK: patched loader answers on the {side} temple; bootloader CRC-32 {second:08x} twice; "
          f"update flag {flag:#010x}")
    return {"bootloader_crc32": f"{second:08x}", "flag": f"{flag:#010x}"}


def cmd_hello(args) -> int:
    def body(session, patched):
        fields = hello_checks(session, args.side)
        if args.no_release:
            session.hold = True  # no CONT: the temple stays in its loader until a reset or the PMIC
            fields["held"] = True
            print(f"HELD: the {args.side} temple stays in its loader (no CONT). It boots again at the next case "
                  f"reset, or about {pins.PMIC_WATCHDOG_S:g} s after the last PMIC kick if the stock app had armed "
                  "the watchdog. For the reset test use held-reset-test, which times the second session.")
        return fields

    return with_session(args, "loader-hello", body)


# The held-temple reset test (rung4.md §4, W21). Session 2's HELO must be the answer to the case's
# reset, not to a PMIC power cycle: it has to come within HELD_RESET_HELO_S of the relay start (the
# reset gives the loader's HELO 0.5-0.9 s after it on hardware), and before the PMIC's watchdog
# could have fired, HELD_RESET_MARGIN_S inside 30.72 s after session 1's last kick. `last_kick` is
# when the last kicking program was started, earlier than the kick itself, so the bound is safe.
HELD_RESET_HELO_S = 3.0
HELD_RESET_MARGIN_S = 5.0


def cmd_held_reset(args) -> int:
    if not temple_feed(args):
        print("REFUSED: held-reset-test times the reset against the held session's last PMIC kick; it needs the "
              "temple feed (drop --no-temple-feed)", file=sys.stderr)
        return 2
    held: dict = {}

    def step(session, patched, index):
        fields = hello_checks(session, args.side)
        if index == 0:
            session.hold = True
            held["last_kick"] = session.last_kick
            print(f"session 0: the {args.side} temple is held in its loader (no CONT); next: a new session must "
                  "reset it", flush=True)
            return False, {"held_session": fields}
        after_start = session.hello_at - session.started
        after_kick = session.hello_at - held["last_kick"]
        limit = pins.PMIC_WATCHDOG_S - HELD_RESET_MARGIN_S
        verdict = {"helo_s_after_relay_start": round(after_start, 2), "helo_s_after_last_kick": round(after_kick, 2),
                   "limits_s": [HELD_RESET_HELO_S, limit]}
        if after_start > HELD_RESET_HELO_S:
            held["late"] = True
            raise SessionError(f"STOP: the HELO came {after_start:.1f} s after the relay started, not within "
                               f"{HELD_RESET_HELO_S:g} s as the case's reset gives it ({after_kick:.1f} s after the held "
                               "session's last PMIC kick): the PMIC's watchdog brought it, the case's reset did not. "
                               "Nothing was written.")
        if after_kick >= limit:
            raise SessionError(f"INCONCLUSIVE: the second session started too late: its HELO came {after_kick:.1f} s "
                               f"after the held session's last PMIC kick (limit {limit:g} s), so the PMIC's watchdog may "
                               "have reset the temple first. Nothing was written; rerun held-reset-test.")
        print(f"OK: held-temple reset test passed on the {args.side} temple: the case reset a temple held in its "
              f"loader; its HELO came {after_start:.1f} s after the relay started and {after_kick:.1f} s after the "
              "held session's last PMIC kick, before the PMIC's watchdog could have reset it", flush=True)
        return True, {"reset_session": fields, "verdict": verdict}

    sessions: list = []

    def on_stop(report):
        late = held.get("late")
        no_helo = len(report["sessions"]) > 1 and sessions and sessions[-1].hello_at is None
        if late or no_helo:
            print("STOP (rung4.md §8): " + ("the HELO came late, from the PMIC's watchdog" if late else
                  "if the second session's relay started (its case_uart_registers event is in the report) and the "
                  "boot beacon timed out") + ": the case reset does not reach a temple held in its loader. Do not "
                  "go on with rung 4; report this. The temple boots by itself when the PMIC's watchdog fires, about "
                  "30 s after the held session's last kick.", file=sys.stderr)

    return run_sessions(args, "held-reset-test", step, on_stop, on_session=sessions.append)


def describe_peek(name: str, data: bytes) -> dict:
    out = {"address": f"{pins.PEEK_REGIONS[name][0]:#x}", "hex": data.hex()}
    if name == "nor":
        pointer = struct.unpack("<I", data)[0]
        out["record"] = f"{pointer:#x}"
        out["part"] = pins.PEEK_NOR.get(pointer, "neither record: stop (rung4.md §8)")
    elif name == "board":
        cls, _pad, code, millivolts = struct.unpack_from("<BBHh", data)
        out.update(bootloader_class=cls, bootloader_code=code, strap_mV=millivolts)
        bins = ((950, 1050, 6), (550, 650, 3), (300, 400, 4), (100, 250, 5))
        out["app_hw_version"] = next((hw for low, high, hw in bins if low <= millivolts <= high),
                                     "out of range: the app falls back by the board serial")
    elif name == "uart2":
        handle, pins_table = struct.unpack_from("<II", data, 4)
        callback, awake = struct.unpack_from("<II", data, 20)
        out.update(handle=f"{handle:#x}", pin_table=f"{pins_table:#x}", rx_callback=f"{callback:#x}",
                   awake=awake & 0xFF)
        # The loader required awake == 0 at its check, then woke UART2 itself (0x41F8B4 sets it), so
        # during the hold the state it leaves reads: handle set, the pinned pin table, no callback, awake.
        out["loader_state"] = bool(handle) and pins_table == 0x434210 and not callback and awake & 0xFF == 1
    elif name == "power-callbacks":
        out["zero"] = data == bytes(8)
    elif name == "flag":
        out["word0"] = f"{struct.unpack_from('<I', data)[0]:#010x}"
    elif name == "ssram-power":
        value = struct.unpack("<I", data)[0]
        out.update(groups_powered=[g for g in range(3) if value >> g & 1], wisp_ram_powered=bool(value & 4))
    elif name == "rstgen-stat":
        value = struct.unpack("<I", data)[0]
        out.update(value=f"{value:#010x}", causes=case_uart.rstgen_stat_names(value))
    elif name == "wisp-record":
        out["record"] = case_uart.decode_diag_record(data, check=False)
    elif name.startswith("wisp-boot-status"):
        try:
            boot = case_uart.decode_boot_status(data)
            out["status"] = {k: boot.get(k) for k in ("stage", "action", "would_action", "observe", "nor_off",
                                                      "nor_id", "nor_result", "nor_bound_hit", "mount_result",
                                                      "rstgen_stat", "reset_cause_names", "pmic_kick",
                                                      "window_answers", "window_ms", "uart_result", "prev_valid",
                                                      "prev")}
            # W24d: the NOR fields were missing here. nor_result 1 = never attempted (stage-0c's Wisp Boot
            # sets it at the start), -12 = MSPI1's power never came up, -11 = unknown RDID, -10 = no RDID.
            out["status"]["nor_id"] = f"{boot['nor_id']:#08x}"
        except ValueError as error:
            out["error"] = f"not a sealed v2 status block ({error}): another Wisp Boot, or never written"
    return out


def cmd_peek(args) -> int:
    names = args.what or list(pins.PEEK_REGIONS)

    def body(session, patched):
        found = {}
        for name in names:
            try:
                found[name] = describe_peek(name, session.peek(name))
            except RefusedError as error:
                if name not in pins.PEEK_SSRAM_GATED:
                    raise
                found[name] = {"refused": str(error)}  # SSRAM group 2 off: a finding, not a stop
            print(f"{name}: {json.dumps(found[name])}", flush=True)
        return {"peek": found}

    return with_session(args, "peek", body)


def pmic_table(registers: dict[int, int]) -> dict:
    return {f"{address:#06x}": {"name": name, "kind": kind, "value": f"{registers[address]:#04x}"}
            for address, name, kind in pins.PMIC_READ_REGISTERS}


def pmic_diff(now: dict[int, int], before: dict) -> dict:
    """Config registers that differ from an earlier snapshot (a pmic-read report's `pmic`), and
    separately the watchdog timer's and the live status registers' changes."""
    out: dict = {"config": {}, "watchdog": {}, "status": {}}
    for address, name, kind in pins.PMIC_READ_REGISTERS:
        old = before.get(f"{address:#06x}", {}).get("value")
        new = f"{now[address]:#04x}"
        if old != new:
            out[kind][name] = {"before": old, "now": new}
    return out


def cmd_pmic_read(args) -> int:
    before = None
    if args.compare:
        try:
            before = json.loads(Path(args.compare).read_text())["pmic"]
        except (OSError, KeyError, ValueError) as error:
            print(f"REFUSED: --compare {args.compare}: not a pmic-read report ({error!r})", file=sys.stderr)
            return 2
    differs = [False]

    def body(session, patched):
        registers = session.pmic_read()
        table = pmic_table(registers)
        for address, entry in table.items():
            print(f"{address} {entry['name']:<28} {entry['value']}  ({entry['kind']})")
        fields = {"pmic": table}
        if before is not None:
            diff = pmic_diff(registers, before)
            fields["diff"] = diff
            differs[0] = bool(diff["config"])
            print(f"compared with {args.compare}: {len(diff['config'])} config register(s) differ, "
                  f"{len(diff['watchdog'])} watchdog, {len(diff['status'])} status", flush=True)
            for name, change in diff["config"].items():
                print(f"  DIFFERS {name}: {change['before']} -> {change['now']}", file=sys.stderr)
        return fields

    code = with_session(args, "pmic-read", body)
    if code == 0 and differs[0]:
        print("STOP (rung4.md §8): the PMIC configuration differs from the snapshot beyond the watchdog timer",
              file=sys.stderr)
        return 3
    return code


def cmd_charge_on(args) -> int:
    expected = {address: value for address, value, _name in pins.CHARGE_ON_WRITES}
    mismatch: list[str] = []

    def body(session, patched):
        registers = session.charge_on()
        table = pmic_table(registers)
        for address, entry in table.items():
            want = expected.get(int(address, 16))
            note = "" if want is None else ("  written, ok" if registers[int(address, 16)] == want
                                            else f"  WROTE {want:#04x}")
            print(f"{address} {entry['name']:<28} {entry['value']}  ({entry['kind']}){note}")
            if want is not None and registers[int(address, 16)] != want:
                mismatch.append(entry["name"])
        print(f"OK: charger settings written; BCHARGER.CHG_STAT {registers[0x0334]:#04x}, ERR_REASON "
              f"{registers[0x0336]:#04x}, VBUSIN.STATUS {registers[0x0207]:#04x}", flush=True)
        return {"pmic": table, "written": {f"{a:#06x}": f"{v:#04x}" for a, v in expected.items()}}

    code = with_session(args, "charge-on", body)
    if code == 0 and mismatch:
        print(f"STOP: read back differs from what charge_on.bin wrote: {', '.join(mismatch)}", file=sys.stderr)
        return 3
    return code


def known_images(extra: list[str]) -> list[dict]:
    """Images app-check compares the app region with: the pinned stock main, every pinned Wisp
    image with a CRC, and any --image files (a bundle or a raw image)."""
    out = [{"name": f"stock {pins.STOCK_MAIN_VERSION} main", "bytes": pins.STOCK_MAIN_BYTES,
            "crc32": pins.STOCK_MAIN_CRC32}]
    for name, pin in pins.WISP_IMAGES.items():
        if "crc32" in pin:
            out.append({"name": f"Wisp {name}", "bytes": pin["image_bytes"], "crc32": pin["crc32"]})
    for path in extra:
        data = Path(path).read_bytes()
        if data[:8] == b"EVENOTA\0":
            data = image.main_from_bundle(data)
        out.append({"name": path, "bytes": len(data), "crc32": zlib.crc32(data), "sha256": image.sha(data)})
    for entry in out:  # checksum.bin reads blindly: never past the app ceiling
        if not 16 <= entry["bytes"] <= pins.APP_END_CEILING - pins.APP_BASE:
            raise image.ImageError(f"{entry['name']}: {entry['bytes']} bytes does not fit the app region "
                                   f"[{pins.APP_BASE:#x}, {pins.APP_END_CEILING:#x}); nothing was sent")
    return out


FLAG_VALUES = {0xFFFFFFFF: "clear", 0x55555555: "install pending (the bootloader installs the staged file)"}


def cmd_app_check(args) -> int:
    try:
        images = known_images(args.image or [])
    except (OSError, image.ImageError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    verdict: dict = {}

    def body(session, patched):
        fields = hello_checks(session, args.side)
        flag = int(fields["flag"], 16)
        fields["flag_meaning"] = FLAG_VALUES.get(flag, "undocumented: stop (rung4.md §8)")
        vectors = session.dump(pins.APP_BASE, 16)
        fields["vectors"] = vectors.hex()
        fields["vectors_zero"] = vectors == bytes(16)
        crcs: dict[int, int] = {}
        for entry in images:
            if entry["bytes"] not in crcs:
                session.step = f"CRC of the app region, {entry['bytes']} bytes"
                crcs[entry["bytes"]] = session.checksum(pins.APP_BASE, entry["bytes"])
            entry["region_crc32"] = f"{crcs[entry['bytes']]:08x}"
            entry["matches"] = crcs[entry["bytes"]] == entry["crc32"]
            entry["crc32"] = f"{entry['crc32']:08x}"
        matched = [e["name"] for e in images if e["matches"]]
        fields.update(images=images, matches=matched)
        note = " (zero: an interrupted write; the bootloader does not hand off)" if fields["vectors_zero"] else ""
        print(f"vectors at {pins.APP_BASE:#x}: {vectors.hex()}{note}")
        for entry in images:
            print(f"  {entry['name']}: region CRC-32 {entry['region_crc32']} over {entry['bytes']} B, image "
                  f"{entry['crc32']}: {'MATCH' if entry['matches'] else 'no match'}")
        print(f"update flag {flag:#010x}: {fields['flag_meaning']}")
        print("OK: app region holds " + (" and ".join(matched) if matched else "NONE of the known images"), flush=True)
        verdict.update(matched=bool(matched), flag_ok=flag in FLAG_VALUES)
        return fields

    code = with_session(args, "app-check", body)
    if code == 0 and not (verdict.get("matched") and verdict.get("flag_ok")):
        return 3
    return code


def cmd_ble_scan(args) -> int:
    """rung4.md W24: listen for adverts from the Mac; never connects, touches no case."""
    from . import ble

    result = asyncio.run(ble.scan(args.seconds, args.adapter))
    wisp = [d for d in result["devices"] if d["kind"] == "wisp"]
    for d in result["devices"]:
        gaps = f", gaps {d['gaps_s']}" if d["gaps_s"] else ""
        print(f"{d['kind']:11} {d['address']} {d['name']!r} RSSI max {d['rssi_max']}, {d['adverts']} adverts, seen "
              f"{d['first_s']}-{d['last_s']} s{gaps}")
    report = {"command": "ble-scan", "side": args.side, **result, "wisp_seen": bool(wisp)}
    print(f"report: {save(report, f'w18-ble-scan-{args.side}')}")
    if not wisp:
        print(f"no Wisp advertiser in {result['seconds']} s (service {ble.WISP_SERVICE_UUID}, name 'Wisp')",
              file=sys.stderr)
        return 3
    print(f"OK: {len(wisp)} Wisp advertiser(s)")
    return 0


def cmd_boot_watch(args) -> int:
    factory = status.PROTOCOLS.get(args.protocol)
    if factory is None:
        print(f"REFUSED: no case-UART status protocol {args.protocol!r} (registered: {sorted(status.PROTOCOLS)}). "
              "Nothing was sent", file=sys.stderr)
        return 2
    if args.report_at is not None and factory is not case_uart.WispStatus:
        print(f"REFUSED: --report-at is for --protocol wisp, not {args.protocol!r}. Nothing was sent", file=sys.stderr)
        return 2
    protocol = factory(report_at=args.report_at) if args.report_at is not None else factory()
    if not status.relay_request_ok(factory().request(0)):  # a throwaway: request() may change state
        print(f"REFUSED: {protocol.name}: its first request is not a frame the case relay forwards; nothing was sent",
              file=sys.stderr)
        return 2

    def body(session, patched):
        fields = hello_checks(session, args.side)
        if int(fields["flag"], 16) not in FLAG_VALUES:
            raise SessionError(f"update flag {fields['flag']} is undocumented (rung4.md §8: stop); not watching. The "
                               "session still ends with CONT, as every session does")
        if not hasattr(session.link, "query"):
            raise SessionError("boot-watch needs the case relay (G2TX after CONT); not watching")
        session.step = "release (CONT) and watch the boot"
        session.release()
        print(f"boot released; watching for {args.watch_s:g} s with {protocol.name!r}", flush=True)
        events = status.watch(session.link, protocol, args.watch_s, args.interval_s, clock=session.clock,
                              sleep=WATCH_SLEEP, log=lambda m: print(m, flush=True))
        print(f"boot-watch: {len(events['answers'])} answer(s), {events['unanswered']} unanswered quer(ies), "
              f"{len(events['reboots_s'])} reboot(s) seen in {events['seconds']} s")
        if "summary" in events:
            print_summary(events["summary"])
        return {**fields, "boot_watch": events}

    return with_session(args, "boot-watch", body)


WATCH_SLEEP = time.sleep  # tests replace it with the relay model's virtual clock


def seconds_list(text: str) -> tuple[float, ...]:
    """`--report-at`: comma-separated seconds, each within [-0.6, 5]."""
    try:
        values = tuple(float(v) for v in text.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a list of seconds: {text!r}") from None
    if not values or any(not -0.6 <= v <= 5.0 for v in values):
        raise argparse.ArgumentTypeError(f"each value must be within [-0.6, 5] s: {text!r}")
    return values


def print_summary(summary: dict) -> None:
    """The decoded Wisp status (case_uart.WispStatus.summary), the lines W24's runbook reads."""
    ident, st, boot = summary.get("ident"), summary.get("status"), summary.get("boot")
    if ident:
        print(f"  IDENT: Wisp {'.'.join(map(str, ident['version']))} kind {ident['image_kind']}, stage "
              f"{ident['stage']}, bt_enable {ident['bt_result']}, battery {ident['battery_mv']} mV, flags "
              f"{','.join(ident['flags'])}")
    if st:
        print(f"  app status: rev {st['rev']}, uptime {st['uptime_ms']} ms, reset cause {st['reset_cause']:#010x}, PMIC "
              f"kicks {st['pmic_kicks']} (errors {st['pmic_errors']}), Apollo feeds {st['apollo_feeds']}, VBUS "
              f"{st['vbus_status']:#04x}, charger {st['charger_status']:#04x}, sessions {st['sessions']}")
    for key in ("status_error", "boot_error"):
        if key in summary:
            print(f"  {key}: {summary[key]}")
    if boot:
        print(f"  Wisp Boot: observe {boot['observe']}{', NOR phase switched off' if boot.get('nor_off') else ''}, "
              f"NOR bound {'HIT' if boot.get('nor_bound_hit') else 'ok'}, NOR id {boot['nor_id']:#08x} (result {boot['nor_result']}), "
              f"mount {boot['mount_result']}, action {boot['action']} (would: {boot['would_action']}), staging "
              f"{'present' if boot['staging_present'] else 'absent'} {boot['staging_id']:08x} ({boot['staging_size']} B"
              f"{', = stock 2.4.0.24' if summary.get('staging_is_stock_2_4_0_24') else ''}), rescue.bin ok "
              f"{boot['rescue_ok']}")
        for name, f in summary.get("inventory", {}).items():
            print(f"    /firmware: {name} {f['size']} B crc {f['crc32']} (result {f['result']})")
        if boot.get("version", 1) >= 2:
            print(f"  Wisp Boot diagnostics: reset cause {boot['rstgen_stat']:#06x} {boot['reset_cause_names']}, "
                  f"PMIC kick {boot['pmic_kick']:#x}, boot-report window {boot['window_ms']} ms "
                  f"({boot['window_answers']} answered), UART2 {boot['uart_result']}, STIMER CLKSEL "
                  f"{boot['stimer_clksel']}, previous record {'valid' if boot['prev_valid'] else 'none'}")
            if boot.get("prev"):
                p = boot["prev"]
                print(f"    previous boot #{p['boots']}: last stage {p['stage']} at {p['stage_ms']} ms, its reset cause "
                      f"{p['reset_cause_names']}, fault {p['fault']}")
    # Every boot report of the watch, one per boot (rung4.md W24 analysis, D2).
    for r in summary.get("boot_reports", []):
        if "source" not in r:
            continue
        fault = r["prev_fault"]
        print(f"  boot report (t = {r.get('t', '?')} s, from {r['source']}): boot {r['boot']}, reset cause "
              f"{r['reset_cause']:#06x} {r['reset_cause_names']}, previous boot's last stage {r['prev_stage']} at "
              f"{r['prev_stage_ms']} ms" + (f", FAULT pc {fault['pc']:#010x} lr {fault['lr']:#010x} cfsr "
                                            f"{fault['cfsr']:#010x}" if fault else "")
              + (f"; asked {r['asked_s_after_release']} s after release" if "asked_s_after_release" in r else ""))
    clock = summary.get("clock")
    if clock:
        print(f"  stage-0 clocks: LFRC {clock['lfrc_hz']} Hz (min {clock['lfrc_hz_min']}, max {clock['lfrc_hz_max']}, "
              f"{clock['measurements']} measurement(s), {clock['result']}), so the watchdog's period is "
              f"{clock['wdt_period_ms']} ms; core {clock['core_hz']} Hz; timebase {clock['timebase']}; STCFG "
              f"{clock['stcfg']:#x}, WDT CFG {clock['wdt_cfg']:#x}")
    diag = summary.get("diag")
    if diag:
        print(f"  diagnostics record now: boot #{diag['boots']}, stage {diag['stage']} at {diag['stage_ms']} ms, "
              f"reset cause {diag['reset_cause_names']}")


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
        self.exchanges = 0  # stream exchanges of the parts already finished
        self._running: tuple | None = None  # (link, its count when the running part started)

    @property
    def exchanges_so_far(self) -> int:
        """Stream exchanges up to now, the running part included (for the progress line)."""
        if self._running is None:
            return self.exchanges
        link, count0 = self._running
        return self.exchanges + link.recent.count - count0

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
        self._running = (session.link, count0)
        try:
            part = session.dump(address, n, (lambda c: progress(at + c)) if progress else None)
        finally:
            self._running = None
            self.exchanges += session.link.recent.count - count0
        took = session.clock() - started
        self.seconds += took
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
            print(f"{count}/{length} bytes read ({reader.exchanges_so_far} stream exchanges so far)", flush=True)

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


def write_image(args, name: str, writer: AppWriter, gate, done_text: str, fields=None) -> int:
    """recover's and install-wisp's write: `gate(session, index) -> fields` runs first in every
    session (after the bootloader CRC), then the writer's share of the image. A stopped write
    reports how far the body is verified and the command that continues it."""
    start = time.monotonic()
    first = [True]  # the first verified block shows at once that streaming works
    budget = writer.budget

    def progress(count):
        if first[0] or count % (64 * 1024) == 0 or count >= writer.body_len:
            first[0] = False
            rate = (count - writer.resumed_at) / max(time.monotonic() - start, 1e-3)
            print(f"{count}/{writer.body_len} body bytes written and read back ({rate / 1024:.1f} KiB/s)", flush=True)

    def step(session, patched, index):
        gate_fields = gate(session, index)
        finished = writer.run(session, progress)
        if budget is not None:
            print(f"session {index}: body {writer.done}/{writer.body_len} bytes written and CRC-checked "
                  f"({session.elapsed():.1f} s since the relay started)", flush=True)
        out = {**gate_fields, "body_verified": writer.done, "max_session_s": budget, "resumed_at": writer.resumed_at,
               "vectors_zeroed": writer.result.get("vectors_zeroed")}
        if "checks" in writer.result:
            out["rule3"] = writer.result["checks"]
        if not finished:
            return False, out
        result = {k: v for k, v in writer.result.items() if k != "checks"}
        print(f"OK: {done_text} written and verified ({result['crc_after']}) in {writer.sessions} session(s); "
              "releasing boot")
        return True, {**out, **result, "seconds": round(time.monotonic() - start, 1), "sessions_used": writer.sessions}

    def on_stop(report):
        report["body_verified"] = writer.done
        report["vectors_zeroed"] = writer.result.get("vectors_zeroed")
        report["vectors_written"] = bool(writer.result.get("crc_after"))
        if report["vectors_zeroed"] and not report["vectors_written"]:
            print("  the vectors at 0x438000 are zero: the temple stays in its loader and boots no app until this "
                  "write completes (rerun it; the patched loader still answers)", file=sys.stderr)
        if writer.done and not report["vectors_written"]:
            hint = resume_command(args, name, writer.done, budget)
            report["resume_with"] = hint
            print(f"  {writer.done} body bytes are written and CRC-verified; the vectors are not written. "
                  f"To continue later (it CRC-checks those bytes first): {hint}", file=sys.stderr)

    return run_sessions(args, name, step, on_stop, fields)


def resume_command(args, name: str, done: int, budget) -> str:
    session = f" --max-session-s {budget:g}" if budget else " --max-session-s 0"
    if name == "install-wisp":
        return (f"w18.py install-wisp --side {args.side} --image {args.image} --elf {args.elf} --map {args.map} "
                f"--expect {args.expect} --battery <N|NmV, read again> --resume-at {done}{session}")
    return f"w18.py recover --side {args.side} --image {args.image} --resume-at {done}{session}"


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
        args.max_session_s = default_max_session_s(args.case_profile, temple_feed(args))
    try:
        writer = AppWriter(stock, budget=args.max_session_s or None, resume_at=args.resume_at)
    except SessionError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2

    def gate(session, index):
        flag = session.flag()
        if index == 0:
            print(f"update flag {flag:#010x}")
        if flag == 0x55555555 and not args.allow_pending_flag:
            raise SystemExit("REFUSED: the update flag is set; the bootloader would install the staged OTA "
                             "file after release. Pass --allow-pending-flag if that is intended.")
        return {"flag": f"{flag:#010x}"}

    return write_image(args, "recover", writer, gate, f"stock {pins.STOCK_MAIN_VERSION} main app")


def cmd_install_wisp(args) -> int:
    """rung4.md §3 (G1): a pinned Wisp image into the app region through the case loader."""
    try:
        data = native.read(args.image, "--image")
        facts = native.resolve(data, native.read(args.elf, "--elf"), native.read(args.map, "--map"), args.expect)
    except (native.NativeRefused, OSError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    battery = native.parse_battery(args.battery)
    if not battery["ok"]:
        print(f"REFUSED: --battery {args.battery!r}: needs >= {pins.BATTERY_MIN_PERCENT} (percent, read in the Even app "
              f"while on stock) or >= {pins.BATTERY_MIN_MV}mV (Wisp's status while native)", file=sys.stderr)
        return 2
    if args.max_session_s is None:
        args.max_session_s = default_max_session_s(args.case_profile, temple_feed(args))
    try:
        app = AppImage(f"Wisp {facts['name']}", data, facts["image_sha256"], int(facts["end"], 16), check=native.rule3)
        writer = AppWriter(app, budget=args.max_session_s or None, resume_at=args.resume_at)
    except SessionError as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 2
    print(f"install-wisp: {facts['name']} {facts['image_sha256'][:16]}..., {facts['bytes']} B into "
          f"[{pins.APP_BASE:#x}, {facts['end']}); Wisp Boot {facts['wisp_boot_sha256'][:16]}...", flush=True)

    def gate(session, index):
        """loader-hello in the same session, before any write: the bootloader CRC a second time
        (run_sessions read the first) and a clear update flag. No override."""
        crc = session.bootloader_crc()
        flag = session.flag()
        want = zlib.crc32(image.build_patched_bootloader())
        print(f"session {index}: loader-hello: bootloader CRC-32 {crc:08x} twice, update flag {flag:#010x}", flush=True)
        if crc != want:
            raise SessionError(f"the second bootloader CRC read {crc:08x}, not {want:08x}; nothing written")
        if flag != 0xFFFFFFFF:
            raise SessionError(f"the update flag reads {flag:#010x}, not clear; install-wisp writes only with a clear "
                               "flag (rung4.md R4-1); nothing written")
        return {"flag": f"{flag:#010x}", "loader_hello": {"bootloader_crc32": f"{crc:08x}", "flag": f"{flag:#010x}"}}

    fields = {"image": facts, "expect": args.expect, "battery": battery}
    return write_image(args, "install-wisp", writer, gate, f"Wisp {facts['name']}", fields)


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
            sp.add_argument("--no-temple-feed", action="store_true",
                            help="do not feed the temple's nPM1300 watchdog (drdaeman's programs only); the "
                                 "PMIC then resets a held temple about 30 s after the relay starts, so keep "
                                 "sessions short (recover: --max-session-s 20 is the default then)")
            sp.add_argument("--renode-port", type=int, help=argparse.SUPPRESS)  # emulation only

    common(sub.add_parser("bootloader-plan", help="print the plan; touches nothing"), link=False)
    sp = sub.add_parser("bootloader-install", help="the one bootloader write (stock BLE OTA)")
    common(sp, link=False)
    sp.add_argument("--address", required=True, help="the temple's BLE address/UUID")
    sp.add_argument("--adapter", help="Linux BlueZ adapter (not used on macOS)")
    sp.add_argument("--battery", type=int, help="battery % read in the Even app; must be >= 80")
    sp.add_argument("--case-profile", choices=sorted(pins.RELAY_SHA256), default=pins.DEFAULT_CASE_PROFILE)
    sp.add_argument("--go", required=True, help="the token bootloader-plan prints")
    sp = sub.add_parser("loader-hello", help="read-only loader check through the case")
    common(sp)
    sp.add_argument("--no-release", action="store_true",
                    help="end the session without CONT: the temple stays held in its loader (G25; the "
                         "held-temple reset test, normally run as held-reset-test)")
    common(sub.add_parser("held-reset-test", help="read-only: hold the temple in its loader, then reset it from a "
                                                   "second session and require its HELO (rung4.md W21)"))
    common(sub.add_parser("info-dump", help="read-only INFO0/INFOC/debug-lock dump"))
    sp = sub.add_parser("peek", help="read-only: allowlisted reads of the patched bootloader's RAM and MRAM")
    common(sp)
    sp.add_argument("--what", nargs="+", choices=sorted(pins.PEEK_REGIONS),
                    help="regions to read (default: all of pins.PEEK_REGIONS)")
    sp = sub.add_parser("pmic-read", help="read-only: nPM1300 register snapshot (pmic_read.bin)")
    common(sp)
    sp.add_argument("--compare", help="an earlier pmic-read report: list and stop on config registers that differ")
    common(sub.add_parser("charge-on", help="WRITES the PMIC: stock charger settings and charging on "
                                             "(charge_on.bin), then reads them back"))
    sp = sub.add_parser("app-check", help="read-only: bootloader CRC, flag, app region CRC against known images")
    common(sp)
    sp.add_argument("--image", nargs="+", help="more images to compare with (a bundle or a raw main image)")
    sp = sub.add_parser("boot-watch", help="release the boot (CONT), then ask the booting app for its status "
                                            "through the relay before ending the session")
    common(sp)
    sp.add_argument("--protocol", default="listen",
                    help="the status protocol (wisp_w18/status.py PROTOCOLS): wisp = native-0's case-UART status "
                         "(IDENT, the app's and Wisp Boot's blocks; use --interval-s 0.1); default listen: send "
                         "nothing, record what the temple sends")
    sp.add_argument("--watch-s", type=float, default=60.0, help="how long to watch after CONT (default 60)")
    sp.add_argument("--interval-s", type=float, default=1.0, help="at most one query this often (default 1)")
    sp.add_argument("--report-at", type=seconds_list, default=None,
                    help="wisp only: when to ask for the boot report, in s after the loader releases the boot "
                         "(CONT, or its HELO + 0.512 s), one value per boot, cycling until one is answered "
                         f"(default {','.join(map(str, case_uart.WispStatus.REPORT_AT_S))}); the relay allows one "
                         "try per boot (rung4.md, W24b results)")
    sp = sub.add_parser("ble-scan", help="read-only, no case: listen for Wisp and Even temple adverts from this "
                                          "machine (rung4.md W24); never connects")
    common(sp, link=False)
    sp.add_argument("--seconds", type=float, default=60.0, help="how long to listen (default 60)")
    sp.add_argument("--adapter", help="Linux BlueZ adapter (not used on macOS)")
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
                         f"continues in the next session after a CRC check of what is written (default 0, one "
                         f"session, when both watchdogs are fed; {DEFAULT_MAX_SESSION_UNFED_TEMPLE_S:g} with "
                         f"--no-temple-feed; {DEFAULT_MAX_SESSION_S:g} with the observed-33 relay)")
    sp.add_argument("--resume-at", type=lambda v: int(v, 0), default=0,
                    help="body bytes an earlier recover run wrote and verified (it prints the value); "
                         "they are CRC-checked against the image before anything is written")
    sp = sub.add_parser("install-wisp", help="write a pinned Wisp native image through the loader (rung4.md "
                                              "R4-1; pinned: native-0, wisp_w18/data/native-0/)")
    common(sp)
    sp.add_argument("--image", required=True, help="the combined native image (Wisp Boot slot + app), linked at 0x438000")
    sp.add_argument("--elf", required=True, help="the app's ELF the image was built from (pinned)")
    sp.add_argument("--map", required=True, help="its linker map (pinned)")
    sp.add_argument("--expect", required=True, help="the first 12 or more hex digits of the image's SHA-256: the "
                                                    "image Jan's go names")
    sp.add_argument("--battery", required=True, help="battery: percent read in the Even app while on stock (>= 80), "
                                                     "or millivolts from Wisp's status while native, e.g. 3950mV")
    sp.add_argument("--max-session-s", type=float, default=None,
                    help="as for recover (default 0, one session, when both watchdogs are fed)")
    sp.add_argument("--resume-at", type=lambda v: int(v, 0), default=0,
                    help="body bytes an earlier install-wisp run of the same image wrote and verified")
    a = p.parse_args(argv)
    return {"bootloader-plan": cmd_plan, "bootloader-install": cmd_install, "loader-hello": cmd_hello,
            "held-reset-test": cmd_held_reset, "info-dump": cmd_info, "peek": cmd_peek, "pmic-read": cmd_pmic_read, "charge-on": cmd_charge_on,
            "app-check": cmd_app_check, "boot-watch": cmd_boot_watch, "ble-scan": cmd_ble_scan, "link-soak": cmd_soak,
            "recover": cmd_recover, "install-wisp": cmd_install_wisp}[a.command](a)
