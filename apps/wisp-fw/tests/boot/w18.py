#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""W18 emulation proof (wisp-fw:w18-test). Emulation only; nothing here talks to hardware.

Runs the patched bootloader (drdaeman/g2-bootloader-patch @ 1d22097 on the stock 2.3.2.14
bootloader, rebuilt from the git-ignored .wisp-cache by apps/wisp-recovery) in Renode on the
rung-3 platform, with UART2 replaced by WispCaseLink (renode/models/WispCaseLink.cs). The host
side is the real W18 tool code (apps/wisp-recovery/wisp_w18: Session, loader, SocketLink), so
the same bytes that would cross the case relay cross the emulated UART2. The *-relay cases put
the case relay's own framing in between (G2RQ, G2TX/G2RX, G2EX/G2RS: links.RelayPortLink, the
code CaseRelayLink runs, over relay_model.RelayModel, a port of drdaeman's case_exchange.c).

Cases (end states):
  control-*     stock bootloaders (2.4.0.24, 2.3.2.14) boot the stock 2.4.0.24 app; no UART2 frame
  boot-nohost   patched bootloader, nobody answers HELO: the stock app boots after the window
  hello         loader-hello: HELO/HOLD/OKAY, bootloader CRC twice, flag read, CONT/RLSD, stock boots
  info          info-dump against synthetic INFO0/INFOC/DCU contents
  recover       app region erased (dead temple): recover writes stock 2.4.0.24, stock boots
  recover-relay the same, every frame through the relay framing; the relay exits with status 6
  recover-cut   power cut in the middle of recover; a second recover completes, stock boots
  recover-split recover's write split over many relay sessions (AppWriter with a session-time
                budget): each session resumes after a CRC of the body so far, the temple is reset
                between sessions, the vectors go last; stock boots
  install-*     the post-cut MRAM states of the stock app's bootloader copy (4 KiB chunks, lowest
                first, as reverse-engineered from 2.4.0.24): k of 38 chunks new, the rest old
  install-wisp  install-wisp's write (rung4.md G1) of a synthetic non-stock image (the stock app with
                a marker block appended, so it boots) over a running stock app: the loader-hello gate
                in the same session, rule 3 on the bytes sent, the vectors zeroed first and written
                last, every write inside the image's end bound (the boot ROM's write log); it boots
  install-wisp-cut  the same write cut by a power loss half way: the vectors read zero, the
                bootloader does not hand off to the half-written image, the loader answers again,
                and a second session completes the image, which boots
  native-0      rung4.md W22/G15: install-wisp writes the real native-0 image (built by
                scripts/build_native.sh, pinned in this process only) over a running stock app through
                the patched loader, under the armed (scaled) PMIC watchdog with the temple feed; CONT;
                then the patched bootloader hands off to Wisp Boot (observe-only), which runs the
                app. Checked: the image in MRAM and the write order, the app's arming writes and
                kicks (no PMIC power cycle, nothing else written), Wisp Boot's NOR commands
                (RDID/RDSR/reads only), the case-UART version/status/boot block, and a case-UART
                reset that ends in the loader's HELO and a second native boot
  temple-wdt-*  the temple's nPM1300 watchdog (renode/models/WispPmicWdt.cs on IOM7), armed at the
                start as the stock app leaves it, with a period scaled to Renode's virtual time
                (PMIC_PERIOD_S): `-unfed` runs drdaeman's programs and is power-cycled mid-session
                (a HELO instead of a reply); `-fed` runs the same work with the temple feed
                (feed.bin, dump_fed.bin) and survives; `recover-fed` writes the dead temple in one
                session with recover_fed.bin under the same armed watchdog. Each checks that every
                PMIC write during the session is the kick 07 04 01
"""
import argparse
import hashlib
import json
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_DIR = HERE.parents[1]
REPO = APP_DIR.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "apps/wisp-recovery"))
import case_uart
from rung3 import FIRMWARE_FILES, STOCK_MARK, Lfs, Renode, build_lfs_tool, evenota_components
from wisp_w18 import image, native, pins
from wisp_w18.links import RelayPortLink, SocketLink
from wisp_w18.relay_model import RelayModel
from wisp_w18.session import AppImage, AppWriter, Session, SessionError

native_rule3 = native.rule3

FLAG = 0x7FE000
# The temple watchdog cases. Renode runs a loader exchange in about 12 us of virtual time (the
# pacing shim), not the hardware's 17.5 ms, so a 30.72 s watchdog would need millions of exchanges.
# The model's period is scaled down instead; the programs kick every 1024 RTOS ticks (one virtual
# second), so 2.5 s leaves room for a whole-app checksum (about 1.1 s virtual) between kicks.
PMIC_PERIOD_S = 2.5
JUMP_RE = re.compile(r"(just jump to app|APP jumpaddr app)\(0x438000\)")
HELO_PREFIX = "5aa5ff100001030c48454c4f"


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Run:
    """One Renode machine: the rung-3 platform with WispCaseLink on UART2."""

    def __init__(self, work: Path, name: str, bootloader: bytes, app: bytes | None, flag=(0xFFFFFFFF,) * 4,
                 nor: Path | None = None):
        self.dir = work / "runs" / name
        shutil.rmtree(self.dir, ignore_errors=True)
        self.dir.mkdir(parents=True)
        (self.dir / "bootloader.bin").write_bytes(bootloader)
        repl = (APP_DIR / "renode/wisp_g2_boot.repl").read_text()
        repl, n = re.subn(r"uart2: Wisp\.WispUartIdle @ sysbus 0x4003B000",
                          "uart2: Wisp.WispCaseLink @ sysbus 0x4003B000", repl)
        assert n == 1, "rung-3 platform changed: uart2 line not found"
        # IOM7 (the PMIC's bus) through WispPmicWdt: the same g2emu IOM behind it, plus the
        # nPM1300 watchdog, which only acts when a case arms it.
        # IOM0..6 through WispIomTypes (G2Iom with silicon-like SUBMODCTRL types, which the real
        # Wisp app's I2C driver checks; the stock code does not).
        repl, n = re.subn(r"iom: G2emu\.G2Iom @ sysbus 0x40050000\n    size: 0x8000",
                          "iom: Wisp.WispIomTypes @ sysbus 0x40050000\n    size: 0x7000\n\n"
                          "pmicwdt: Wisp.WispPmicWdt @ sysbus 0x40057000", repl)
        assert n == 1, "rung-3 platform changed: iom line not found"
        # INFO0 (0x42000000), INFOC (0x400C2000) and CRYPTO (0x400C0000) fall into the rung-3
        # platform's plain periph_hi memory: zeros unless a case writes synthetic contents.
        (self.dir / "w18.repl").write_text(repl)
        resc = (APP_DIR / "renode/boot.resc").read_text().replace("$ORIGIN/", f"@{APP_DIR}/renode/")
        resc = resc.replace(f"include @{APP_DIR}/renode/models/WispUartIdle.cs",
                            f"include @{APP_DIR}/renode/models/WispUartIdle.cs\ninclude @{APP_DIR}/renode/models/WispCaseLink.cs")
        resc = resc.replace(f"include @{APP_DIR}/renode/models/WispProbe.cs",
                            f"include @{APP_DIR}/renode/models/WispProbe.cs\ninclude @{APP_DIR}/renode/models/WispIomTypes.cs\n"
                            f"include @{APP_DIR}/renode/models/WispPmicWdt.cs")
        resc = re.sub(r"machine LoadPlatformDescription .*", f"machine LoadPlatformDescription @{self.dir / 'w18.repl'}", resc)
        (self.dir / "w18.resc").write_text(resc)
        self.r = Renode(self.dir, free_port())
        r = self.r
        out = r.cmd(f"include @{self.dir / 'w18.resc'}")
        if "error" in out.lower() or "could not" in out.lower():
            raise RuntimeError(f"Renode platform failed to load: {out[-800:]}")
        r.cmd("uart2 HostTimeoutMs 600000")
        # Skip idle (WFI) time instead of pacing it: the loader spends most of each exchange in
        # FreeRTOS delays. Virtual time stays exact; only wall time shrinks.
        out = r.cmd("emulation SetAdvanceImmediately true")
        if "error" in out.lower():
            raise RuntimeError(out)
        r.cmd(f"sysbus LoadBinary @{self.dir / 'bootloader.bin'} 0x410000")
        if nor is not None:
            r.cmd(f"nor LoadImage @{nor}")
        if app is not None:
            (self.dir / "app.bin").write_bytes(app)
            r.cmd(f"sysbus LoadBinary @{self.dir / 'app.bin'} 0x438000")
        for i, w in enumerate(flag):
            r.cmd(f"sysbus WriteDoubleWord {FLAG + 4 * i:#x} {w:#x}")
        # Model limit: Renode 1.16's Cortex-M55 has no MVE, so the loader trampoline's save and
        # restore of the MVE predicate register (vmrs r7, vpr / vmsr vpr, r7 in drdaeman's
        # boot_ram_invoke, valid on the real Apollo510) would be an UNDEFINSTR UsageFault here.
        # WispCaseLink.MveVprShim emulates both: VPR reads as 0, its restore is a no-op.
        out = r.cmd("uart2 MveVprShim 0x43491C 0x434952 7")
        if out.strip():
            raise RuntimeError(f"MVE shim failed: {out}")
        # Model limit (WispCaseLink.PacingShim): skip the loader worker's own short pacing delays
        # (reply 0x4349D4, receive 0x434A38, transmit 0x4350AC; at most 21 ticks) whose virtual
        # duration drifts upward in Renode. Correctness is untouched; only virtual time shrinks.
        out = r.cmd('uart2 PacingShim 0x416378 "4349D4-434A38,434A38-434B00,4350AC-43511C" 21')
        if out.strip():
            raise RuntimeError(f"pacing shim failed: {out}")
        sp, pc = struct.unpack_from("<II", bootloader, 0)
        r.cmd("cpu VectorTableOffset 0x410000")
        r.cmd(f"cpu SP {sp:#x}")
        r.cmd(f"cpu PC {pc & ~1:#x}")
        self.host_error = None

    def attach(self, body, relay=False):
        """Run `body(link)` on a host thread attached to UART2 before the CPU starts. With
        `relay`, the link is the case relay framing over the relay model over that socket."""
        port = free_port()
        result = {}

        def host():
            try:
                link = SocketLink(port, trace=(self.dir / "uart2-trace.txt").open("w"))
                if relay:
                    link = RelayPortLink(RelayModel(link), "left")
                result["link"] = link
                result["value"] = body(link)
            except BaseException as error:  # noqa: BLE001 - reported by the case
                result["error"] = error
        thread = threading.Thread(target=host, daemon=True)
        thread.start()
        self.r.cmd(f"uart2 Listen {port}")  # returns once the host has connected
        return thread, result

    def uart(self) -> str:
        p = self.dir / "uart1.txt"
        return p.read_text(errors="replace") if p.exists() else ""

    def stock_running(self) -> bool:
        text = self.uart()
        jumps = [m.end() for m in JUMP_RE.finditer(text)]
        return bool(jumps) and STOCK_MARK in text[jumps[-1]:]

    def step(self, seconds: float = 1.0) -> None:
        """RunFor, then the nPM1300 watchdog's power cycle if it fired during it (WispPmicWdt)."""
        self.r.cmd(f'emulation RunFor "{seconds}"')
        if self.r.cmd("pmicwdt PowerCyclePending").strip() == "True":
            self.r.cmd("pmicwdt AckPowerCycle")
            self.r.cmd("rstgen PowerCut")

    def run_until(self, done, budget: float, step: float = 0.5) -> float:
        t = 0.0
        while t < budget and not done():
            self.step(step)
            t += step
        return t

    def frames(self) -> list[str]:
        out = self.r.cmd("uart2 FrameLog").splitlines()
        bad = [l for l in out if l.strip() and not re.fullmatch(r"[0-9a-f]+", l.strip())]
        if bad:
            raise RuntimeError(f"uart2 FrameLog failed: {bad}")
        return [l.strip() for l in out if l.strip()]

    def mram(self) -> bytes:
        out = self.dir / "mram.bin"
        self.r.cmd(f"probe Dump 0x400000 0x400000 @{out}")
        return out.read_bytes()

    def close(self):
        self.r.close()


class Harness:
    def __init__(self, cache: Path):
        self.cache = cache
        self.work = cache / "w18"
        self.work.mkdir(parents=True, exist_ok=True)
        stock = cache / "stock"
        b24 = evenota_components((stock / "g2-2.4.0.24.bin").read_bytes())
        b23 = evenota_components((stock / "g2-2.3.2.14.bin").read_bytes())
        self.bl24, self.bl23 = b24[1], b23[1]
        self.patched = image.build_patched_bootloader(stock)
        self.app = image.stock_main(stock)
        self.stock_payload = b24[0]
        self.firmware = {f"firmware/{n}": b24[t] for t, n in FIRMWARE_FILES.items() if t in b24}
        assert hashlib.sha256(self.bl24).hexdigest().startswith("ecb91896")
        self.rows: list[tuple] = []

    def record(self, name, ok, state, detail):
        self.rows.append((name, ok, state, detail))
        print(f"{'PASS' if ok else 'FAIL'} {name}: {state} ({detail})", flush=True)

    # --- cases ---
    def control(self, name, bootloader):
        run = Run(self.work, name, bootloader, self.app)
        try:
            t = run.run_until(run.stock_running, 30)
            frames = run.frames()
            ok = run.stock_running() and not frames
            self.record(name, ok, "stock app running" if ok else f"stock={run.stock_running()} frames={len(frames)}",
                        f"{t:.1f} s virtual")
        finally:
            run.close()

    def boot_nohost(self):
        run = Run(self.work, "boot-nohost", self.patched, self.app)
        try:
            t = run.run_until(run.stock_running, 30)
            frames = run.frames()
            helo = [f for f in frames if f.startswith(HELO_PREFIX)]
            mram = run.mram()
            ok = run.stock_running() and len(helo) == 1 and len(frames) == 1 and \
                mram[0x10000:0x10000 + len(self.patched)] == self.patched
            self.record("boot-nohost", ok, "HELO sent once, unanswered; stock app running" if ok else
                        f"stock={run.stock_running()} frames={frames}", f"{t:.1f} s virtual")
        finally:
            run.close()

    def session_case(self, name, app, body, check, setup=None, budget=60.0, bootloader=None,
                     session_budget=120.0, relay=False, temple_feed=False):
        run = Run(self.work, name, bootloader or self.patched, app)
        log = []
        try:
            if setup:
                setup(run)

            def host(link):
                with Session(link, log=log.append, temple_feed=temple_feed) as s:
                    s.require_patched_bootloader(self.patched)
                    return body(s)
            t0 = time.time()
            thread, result = run.attach(host, relay=relay)
            t = 0.0
            while thread.is_alive():
                run.step(1)
                t += 1
                if t > session_budget:
                    regs = {r: run.r.cmd(f"cpu GetRegisterUnsafe {i}") for i, r in ((15, "pc"), (14, "lr"), (13, "sp"))}
                    regs["cfsr"] = run.r.cmd("sysbus ReadDoubleWord 0xE000ED28")
                    regs["hfsr"] = run.r.cmd("sysbus ReadDoubleWord 0xE000ED2C")
                    regs["xpsr"] = run.r.cmd("cpu GetRegisterUnsafe 16")
                    self.record(name, False, f"host session stalled: {regs}", f"{t:.0f} s virtual")
                    return {}
            t += run.run_until(run.stock_running, budget)
            ok, state = check(run, result)
            self.record(name, ok, state, f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
            (run.dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
            return result
        finally:
            run.close()

    def hello(self):
        def body(s):
            return {"crc": [s.bootloader_crc(), s.bootloader_crc()], "flag": s.flag()}

        def check(run, result):
            want = __import__("zlib").crc32(self.patched)
            v = result.get("value")
            ok = v and v["crc"] == [want, want] and v["flag"] == 0xFFFFFFFF and run.stock_running()
            return bool(ok), (f"OKAY verified, CRC {want:08x} twice, flag clear, RLSD, stock app running"
                              if ok else f"{result} stock={run.stock_running()}")
        self.session_case("hello", self.app, body, check)

    def info(self):
        def setup(run):
            for i in range(0, 64, 4):
                run.r.cmd(f"sysbus WriteDoubleWord {0x42000000 + i:#x} {0x49300000 + i:#x}")

        def body(s):
            return s.info_dump()

        def check(run, result):
            v = result.get("value") or {}
            info0 = bytes.fromhex(v.get("info0", {}).get("hex", ""))
            ok = (len(info0) == 2048 and struct.unpack_from("<I", info0, 4)[0] == 0x49300004
                  and "skipped" in v.get("infoc", {}) and run.stock_running())
            return ok, ("MCUCTRL/PWRCTRL read, INFO0 (MRAM) 2048 B read back exactly, INFOC/DCU skipped "
                        "(OTP/CRYPTO off), stock app running" if ok else f"{result}")
        self.session_case("info", self.app, body, check, setup=setup)

    def recover(self, name="recover", cut_fraction=None, relay=False):
        dead = None  # app region erased: the stock bootloader has nothing to hand over to
        state = {}

        def setup(run):
            if cut_fraction is not None:
                # recover.bin programs 256-byte blocks (64 words each) through the bootloader's
                # MRAM wrapper -> boot ROM; cut right after this ROM write.
                n = int((pins.STOCK_MAIN_BYTES // 256) * cut_fraction)
                run.r.cmd(f"bootrom CutAfterWriteIndex {n}")
                state["cut_at"] = n

        def body(s):
            t0 = time.time()
            result = s.write_app(self.app)
            result["host_s"] = round(time.time() - t0, 1)
            return result

        def check(run, result):
            mram = run.mram()
            app_ok = mram[0x38000:0x38000 + len(self.app)] == self.app
            boot_ok = mram[0x10000:0x10000 + len(self.patched)] == self.patched
            v = result.get("value")
            ok = bool(v) and app_ok and boot_ok and run.stock_running()
            via = ""
            if relay:
                link = result.get("link")
                exits = [e["relay_exit_status"] for e in getattr(link, "events", []) if "relay_exit_status" in e]
                ok = ok and exits == [6]
                via = f", {link.recent.count} exchanges through the relay framing, exit status {exits}"
            return ok, (f"stock 2.4.0.24 written ({v['bytes']} B, CRC {v['crc_after']}, {v['host_s']} s host{via}), "
                        f"bootloader unchanged, stock app running" if ok else f"app_ok={app_ok} boot_ok={boot_ok} "
                        f"{result} stock={run.stock_running()}")

        if cut_fraction is None:
            return self.session_case(name, dead, body, check, setup=setup, budget=60, relay=relay)

        # Cut case: first session is cut mid-write, the temple resets into the loader again (the
        # app is still dead), and a second, fresh session completes the recovery.
        run = Run(self.work, name, self.patched, None)
        try:
            setup(run)
            log = []
            t0 = time.time()

            def host(link):
                out = {}
                try:
                    with Session(link, log=log.append) as s:
                        s.require_patched_bootloader(self.patched)
                        s.write_app(self.app)
                    out["first"] = "completed (no cut?)"
                except BaseException as error:  # noqa: BLE001
                    out["first"] = repr(error)
                return out
            thread, result = run.attach(host)
            t = 0.0
            while thread.is_alive():
                run.r.cmd('emulation RunFor "1"')
                t += 1
            cut_resets = run.r.cmd("rstgen ResetLog")
            # Second session on the next HELO (the cut reset the temple; the dead app means the
            # bootloader ends up in its loader window again on every boot).
            run.r.cmd("bootrom CutAfterWriteIndex -1")

            def host2(link):
                with Session(link, log=log.append) as s:
                    s.require_patched_bootloader(self.patched)
                    return s.write_app(self.app)
            # A cut leaves the temple rebooting: power-cycle it now so the next HELO meets the host.
            thread, result2 = run.attach(host2)
            run.r.cmd("rstgen PowerCut")
            while thread.is_alive():
                run.r.cmd('emulation RunFor "1"')
                t += 1
            t += run.run_until(run.stock_running, 60)
            mram = run.mram()
            app_ok = mram[0x38000:0x38000 + len(self.app)] == self.app
            ok = ("power-cut" in cut_resets and "first" in result.get("value", {}) and "completed" not in
                  result["value"]["first"] and result2.get("value") and app_ok and run.stock_running())
            self.record(name, bool(ok),
                        (f"cut after ROM write {state['cut_at']}: session 1 stopped ({result['value']['first'][:60]}); "
                         f"session 2 wrote and verified stock; stock app running" if ok else
                         f"result1={result} result2={result2} app_ok={app_ok} stock={run.stock_running()}"),
                        f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
            (run.dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
        finally:
            run.close()

    def recover_split(self, name="recover-split", budget=30.0, max_sessions=400):
        """A dead temple recovered over many short relay sessions, as `recover --max-session-s`
        does on hardware: one AppWriter, a fresh relay session per part (each through the relay
        framing), the temple reset between sessions as the next relay session's reset does. The
        budget is host wall seconds; emulated exchanges are faster than real ones, so it is
        larger than the hardware default but still splits the image into several sessions."""
        run = Run(self.work, name, self.patched, None)
        log = []
        writer = AppWriter(self.app, budget=budget, log=log.append)
        sessions = []
        try:
            t0 = time.time()
            t = 0.0
            while len(sessions) < max_sessions:
                def host(link):
                    with Session(link, log=log.append) as s:
                        s.require_patched_bootloader(self.patched)
                        finished = writer.run(s)
                        return {"finished": finished, "body": writer.done, "elapsed": round(s.elapsed(), 1)}
                thread, result = run.attach(host, relay=True)
                if sessions:
                    run.r.cmd("rstgen PowerCut")  # the next relay session resets the temple
                spent = 0
                while thread.is_alive() and spent < 600:
                    run.r.cmd('emulation RunFor "1"')
                    spent += 1
                t += spent
                if "error" in result or not result.get("value"):
                    self.record(name, False, f"session {len(sessions)}: {result.get('error')!r}",
                                f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
                    return
                exits = [e["relay_exit_status"] for e in result["link"].events if "relay_exit_status" in e]
                sessions.append({**result["value"], "exit": exits})
                if result["value"]["finished"]:
                    break
            t += run.run_until(run.stock_running, 60)
            mram = run.mram()
            app_ok = mram[0x38000:0x38000 + len(self.app)] == self.app
            boot_ok = mram[0x10000:0x10000 + len(self.patched)] == self.patched
            done = bool(sessions) and sessions[-1]["finished"]
            exits_ok = all(s["exit"] == [6] for s in sessions)
            ok = done and len(sessions) > 2 and app_ok and boot_ok and exits_ok and run.stock_running()
            longest = max((s["elapsed"] for s in sessions), default=0)
            self.record(name, ok, (f"stock 2.4.0.24 written over {len(sessions)} relay sessions (longest "
                                   f"{longest} s of the {budget:g} s budget), each resumed after a CRC of the body so "
                                   f"far, vectors last ({writer.result.get('crc_after')}); exit status 6 every "
                                   f"time; bootloader unchanged; stock app running" if ok else
                                   f"done={done} sessions={sessions} app_ok={app_ok} boot_ok={boot_ok} "
                                   f"stock={run.stock_running()}"),
                        f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
            (run.dir / "host.log").write_text("\n".join(map(str, log + sessions)) + "\n")
        finally:
            run.close()

    # --- the temple's nPM1300 watchdog ---
    @staticmethod
    def pmic(run) -> dict:
        def number(command):
            return int(run.r.cmd(f"pmicwdt {command}").split()[0], 0)
        log = run.r.cmd("pmicwdt PmicLog")
        (run.dir / "pmic.log").write_text(log + "\n")
        return {"kicks": number("Kicks"), "expiries": number("Expiries"), "log": log}

    @staticmethod
    def leading_kicks(log: str) -> tuple[int, list[str]]:
        """How many PMIC writes are kicks before the first other write, and every distinct write.
        The session comes first; only after its release does the stock app boot and write the PMIC
        itself, so a session that writes nothing but kicks has all its kicks in that leading run."""
        writes = [line.split(" ms write ")[1].strip() for line in log.splitlines() if " ms write " in line]
        n = 0
        while n < len(writes) and writes[n] == "07 04 01":
            n += 1
        return n, sorted(set(writes))

    def temple_wdt(self, fed: bool):
        """The same work with and without the feed, under an armed (scaled) PMIC watchdog: three
        checksums of the app region (about 1.1 s virtual each) and a 1 MiB dump."""
        name = "temple-wdt-fed" if fed else "temple-wdt-unfed"
        marks = {}

        def setup(run):
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")

        def body(s):
            crcs = [s.checksum(pins.APP_BASE, len(self.app)) for _ in range(3)]
            data = s.dump(pins.APP_BASE, 1 << 20)
            marks["feeds"] = s.feeds
            return {"crcs": crcs, "dump_ok": data == self.app[: 1 << 20]}

        def check(run, result):
            p = self.pmic(run)
            v = result.get("value")
            want = __import__("zlib").crc32(self.app)
            leading, writes = self.leading_kicks(p["log"])
            if fed:
                ok = (bool(v) and v["crcs"] == [want] * 3 and v["dump_ok"] and p["expiries"] == 0
                      and leading >= marks.get("feeds", 99) + 1 and run.stock_running())
                return ok, (f"{leading} kicks in the session, nothing else written to the PMIC ({marks.get('feeds')} "
                            f"by feed.bin, the rest by dump_fed.bin); no power cycle; CRCs and dump right; stock app "
                            f"running (its own PMIC writes after the release: {len(writes)} distinct)"
                            if ok else f"{result} leading={leading} {p}")
            error = result.get("error")
            ok = (error is not None and "temple rebooted" in repr(error) and p["expiries"] == 1
                  and leading == 0 and run.stock_running())
            return ok, (f"power-cycled by the PMIC watchdog mid-session ({error!r:.60}), no kick, stock app "
                        "running after the reboot" if ok else f"{result} {p}")

        self.session_case(name, self.app, body, check, setup=setup, temple_feed=fed, session_budget=600)

    def recover_fed(self):
        """recover in one session with recover_fed.bin, on a dead temple, under the armed watchdog."""
        def setup(run):
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")

        def body(s):
            t0 = time.time()
            result = s.write_app(self.app)
            result["host_s"] = round(time.time() - t0, 1)
            result["feeds"] = s.feeds
            return result

        def check(run, result):
            p = self.pmic(run)
            mram = run.mram()
            app_ok = mram[0x38000:0x38000 + len(self.app)] == self.app
            boot_ok = mram[0x10000:0x10000 + len(self.patched)] == self.patched
            v = result.get("value")
            leading, _writes = self.leading_kicks(p["log"])
            ok = (bool(v) and app_ok and boot_ok and p["expiries"] == 0 and leading >= v["feeds"] + 2
                  and run.stock_running())
            return ok, (f"stock 2.4.0.24 written in one session ({v['bytes']} B, CRC {v['crc_after']}), "
                        f"{leading} kicks and nothing else to the PMIC in the session ({v['feeds']} by feed.bin), no "
                        f"power cycle, bootloader unchanged, stock app running" if ok else
                        f"app_ok={app_ok} boot_ok={boot_ok} {result} leading={leading} {p}")

        self.session_case("recover-fed", None, body, check, setup=setup, temple_feed=True, session_budget=900)

    # --- install-wisp (rung4.md G1) ---
    def wisp_image(self) -> AppImage:
        """A non-stock image install-wisp may write in emulation: the stock app (it boots) with a
        64-byte marker appended, so the region it fills and its hash differ from stock. The writer
        refuses any image that is not pinned with R4-1 approved, so this process (Renode, never a
        case) approves R4-1 and pins it in memory; the repository's table stays empty."""
        data = self.app + b"WISP-RENODE-G1-" * 4 + b"END!"
        pins.R4_1_APPROVED = True
        pins.WISP_IMAGES = {"renode-synthetic": {"image_sha256": image.sha(data)}}
        return AppImage("synthetic", data, image.sha(data), pins.APP_BASE + ((len(data) + 15) & ~15),
                        check=native.rule3)

    def wisp_session(self, s: Session, app: AppImage) -> dict:
        """install-wisp's session: the loader-hello gate (the bootloader CRC a second time and a
        clear flag), then the writer, which reruns rule 3 on the bytes it sends."""
        want = __import__("zlib").crc32(self.patched)
        if s.bootloader_crc() != want or s.flag() != 0xFFFFFFFF:
            raise SessionError("loader-hello gate failed")
        writer = AppWriter(app, log=lambda m: None)
        writer.run(s)
        return writer.result

    @staticmethod
    def write_log(run) -> list[tuple[int, int]]:
        """(destination, words) of every MRAM write through the boot ROM, in order."""
        out = []
        for line in run.r.cmd("bootrom WriteLog").splitlines():
            m = re.search(r"dst=0x([0-9A-F]+) words=(\d+)", line)
            if m:
                out.append((int(m.group(1), 16), int(m.group(2))))
        return out

    def install_wisp(self):
        app = self.wisp_image()
        end = app.end

        def body(s):
            return self.wisp_session(s, app)

        def check(run, result):
            mram = run.mram()
            writes = self.write_log(run)
            v = result.get("value") or {}
            image_ok = mram[0x38000:0x38000 + len(app.data)] == app.data
            boot_ok = mram[0x10000:0x10000 + len(self.patched)] == self.patched
            order_ok = (len(writes) > 2 and writes[0] == (pins.APP_BASE, 4) and writes[-1] == (pins.APP_BASE, 4)
                        and all(d >= pins.APP_BASE + 16 for d, _ in writes[1:-1]))
            bound_ok = all(pins.APP_BASE <= d and d + 4 * n <= end for d, n in writes)
            checks_ok = all(r["ok"] for r in v.get("checks", []))
            ok = bool(v) and v.get("vectors_zeroed") and image_ok and boot_ok and order_ok and bound_ok and checks_ok \
                and run.stock_running()
            return ok, (f"synthetic image written ({len(app.data)} B, CRC {v.get('crc_after')}): vectors zeroed first "
                        f"and written last of {len(writes)} ROM writes, all inside [0x438000, {end:#x}), rule 3 "
                        f"passed on the sent bytes; bootloader unchanged; the image boots" if ok else
                        f"image_ok={image_ok} boot_ok={boot_ok} order_ok={order_ok} bound_ok={bound_ok} "
                        f"checks_ok={checks_ok} first={writes[:2]} last={writes[-1:]} {result} stock={run.stock_running()}")

        self.session_case("install-wisp", self.app, body, check, budget=60)

    # --- native-0 behind the patched loader (rung4.md W22, G15) ---
    def native_zero(self):
        """install-wisp of the real native-0 over a running stock app, then the native boot."""
        native = self.cache / "build/native-0/native-0.bin"
        if not native.exists():
            self.record("native-0", False, f"{native} missing: run scripts/build_native.sh native-0", "")
            return
        data = native.read_bytes()
        boot_elf = self.cache / "build/native-0/boot/wisp_boot.elf"
        # Pinned in this process only (Renode, never a case); the repository's table stays empty.
        pins.R4_1_APPROVED = True
        pins.WISP_IMAGES = {"renode-native-0": {"image_sha256": image.sha(data)}}
        app = AppImage("native-0", data, image.sha(data), pins.APP_BASE + ((len(data) + 15) & ~15),
                       check=native_rule3)
        nor_dir = self.work / "native-0-nor"   # Run() empties its own run dir
        nor_dir.mkdir(parents=True, exist_ok=True)
        nor = nor_dir / "nor-before.bin"
        lfs = Lfs(build_lfs_tool(self.cache))
        files = {"ota/s200_firmware_ota.bin": self.stock_payload, **self.firmware}
        lfs.build(nor, files, nor_dir)
        run = Run(self.work, "native-0", self.patched, self.app, nor=nor)
        run_dir = run.dir
        log = []
        t0 = time.time()
        try:
            syms = {}
            out = subprocess.run(["arm-none-eabi-nm", str(boot_elf)], capture_output=True, text=True, check=True).stdout
            for line in out.splitlines():
                p_ = line.split()
                if len(p_) == 3 and p_[2] in ("wisp_boot_main", "hw_jump"):
                    syms[p_[2]] = int(p_[0], 16) & ~1
            # Wisp Boot's milestones count only once its services table is in MRAM (WispProbe).
            for name, addr in syms.items():
                run.r.cmd(f'probe Milestone {addr:#x} "{name}"')
            run.r.cmd("nor WatchCode 0x438000 0x448000")
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")

            def host(link):
                with Session(link, log=log.append, temple_feed=True) as s:
                    s.require_patched_bootloader(self.patched)
                    result = self.wisp_session(s, app)
                    result["feeds"] = s.feeds
                    return result
            thread, result = run.attach(host)
            t = 0.0
            while thread.is_alive() and t < 900:
                run.step(1)
                t += 1
            writes = self.write_log(run)          # the install's ROM writes, before the app runs
            uart = lambda: run.uart()             # noqa: E731
            banner = "*** Wisp native "
            t += run.run_until(lambda: uart().count(banner) >= 1 and uart().count("wisp: heartbeat", uart().rfind(banner)) >= 3, 40)
            frames0 = len(run.frames())

            def ask(req: bytes) -> bytes:
                before = len(run.frames())
                run.r.cmd(f'uart2 Inject "{req.hex()}"')
                for _ in range(40):
                    run.r.cmd('emulation RunFor "0.05"')
                    fr = run.frames()
                    if len(fr) > before:
                        return bytes.fromhex(fr[before])
                raise RuntimeError(f"no case-UART reply to {req.hex()}")
            q = {"version": case_uart.decode_version(ask(case_uart.STOCK_VERSION_QUERY))}
            st_code, data = case_uart.decode_reply(ask(case_uart.ident_request()), case_uart.OP_IDENT)
            q["ident"] = case_uart.decode_ident(data) if st_code == 0 else {"code": st_code}
            raw = case_uart.read_block(ask, case_uart.BLOCK_STATUS)
            q["status"] = case_uart.decode_status(raw) if raw else {}
            block = case_uart.read_block(ask, case_uart.BLOCK_BOOT) or b""
            boot = case_uart.decode_boot_status(block) if len(block) == case_uart.BOOT_STATUS_SIZE else {}
            # The reset command: the reply, then the patched loader's HELO at the reboot (nobody
            # answers it), then a second native boot.
            helo_before = sum(f.startswith(HELO_PREFIX) for f in run.frames())
            code, _ = case_uart.decode_reply(ask(case_uart.reset_request()), case_uart.OP_RESET)
            banners = uart().count(banner)
            t += run.run_until(lambda: uart().count(banner) > banners and
                               uart().count("wisp: heartbeat", uart().rfind(banner)) >= 2, 40)
            helo_after = sum(f.startswith(HELO_PREFIX) for f in run.frames())
            pm = self.pmic(run)
            mram = run.mram()
            watched = run.r.cmd("nor WatchedLog").split("\n")
            watched_writes = int(run.r.cmd("nor WatchedWrites").split()[0], 0)
            rep = run.r.cmd("probe Report").splitlines()
            boots = sum(l.startswith("wisp_boot_main ") for l in rep)
            handoffs = sum(l.startswith("hw_jump ") for l in rep)
        finally:
            run.close()
        v = result.get("value") or {}
        fails = []
        if mram[0x38000:0x38000 + len(data)] != data:
            fails.append("native-0 not in MRAM")
        if mram[0x10000:0x10000 + len(self.patched)] != self.patched:
            fails.append("bootloader region changed")
        if not (len(writes) > 2 and writes[0] == (pins.APP_BASE, 4) and writes[-1] == (pins.APP_BASE, 4)
                and all(pins.APP_BASE <= d and d + 4 * n <= app.end for d, n in writes)):
            fails.append(f"install write order/bound: first {writes[:2]} last {writes[-1:]}")
        kicks_after = [l for l in pm["log"].splitlines() if " ms write " in l]
        data_writes = [l.split(" ms write ")[1].strip() for l in kicks_after]
        arm = ["07 05 0a", "07 08 00 3c 00", "07 03 01", "07 00 01"]
        if [w for w in data_writes if w in arm][:4] != arm:
            fails.append("the app did not arm the PMIC watchdog with stock's writes")
        allowed = {"07 04 01", "05 00 01", *arm}
        bad = sorted({w for w in data_writes if len(w.split()) > 2 and w not in allowed})
        if bad:
            fails.append(f"PMIC writes outside the allowlist: {bad}")
        if pm["expiries"]:
            fails.append(f"PMIC watchdog expired {pm['expiries']}x")
        # The app's kicks: from its first arming on (before, the loader programs kick), data
        # writes only (2-byte writes are a read's address phase); a gap ending in a boot's first
        # kick (followed at once by the arming) spans the reboot.
        timed = [(int(l.split(" ms write ")[0]), l.split(" ms write ")[1].strip()) for l in kicks_after]
        timed = [(t_, w) for t_, w in timed if len(w.split()) > 2]
        first_arm = next((i for i, (_t, w) in enumerate(timed) if w == arm[0]), len(timed))
        timed = timed[max(first_arm - 1, 0):]
        kick_at = [i for i, (_t, w) in enumerate(timed) if w == "07 04 01"]
        gaps = [timed[j][0] - timed[i][0] for i, j in zip(kick_at, kick_at[1:])
                if not (j + 1 < len(timed) and timed[j + 1][1] == arm[0])]
        if max(gaps, default=0) > 1500:
            fails.append(f"PMIC kicks {max(gaps)} ms apart within one boot")
        nor_ops = {l.split()[0] for l in watched if l.strip()}
        if watched_writes or not nor_ops <= {"9f", "05", "13"} or not {"9f", "05", "13"} <= nor_ops:
            fails.append(f"Wisp Boot NOR commands {sorted({l.split()[0] for l in watched if l.strip()})}")
        if boots != 2 or handoffs != 2:
            fails.append(f"{boots} Wisp Boot runs, {handoffs} hand-offs (want 2 and 2)")
        if not q["version"]["wisp"]:
            fails.append(f"version reply {q['version']}")
        st = q["status"]
        if not {"pmic-wdt", "boot-services", "boot-status", "boot-observe"} <= set(st.get("flags", [])):
            fails.append(f"status {st}")
        if not boot or boot["staging_id"] != struct.unpack_from("<I", self.stock_payload, 4)[0] or \
                len(boot["inventory"]) != len(self.firmware) or boot["action"] != "run-app":
            fails.append(f"boot block {boot}")
        if code != 0 or helo_after != helo_before + 1:
            fails.append(f"reset: reply {code}, HELO {helo_before} -> {helo_after}")
        ok = bool(v) and not fails and "error" not in result
        state = (f"native-0 ({len(data)} B, CRC {v.get('crc_after')}) written through the loader, vectors first "
                 f"and last; CONT -> observe-only Wisp Boot -> app; PMIC armed with stock's writes, "
                 f"{pm['kicks']} kicks, no power cycle; Wisp Boot NOR commands RDID/RDSR/READ only; case UART: "
                 f"{q['version']['id']} version, stage {st.get('stage')}, {len(boot.get('inventory', []))} firmware files, "
                 f"staging {boot.get('staging_id', 0):08x}; reset over the case UART -> loader HELO -> second "
                 f"native boot" if ok else f"{'; '.join(fails)} {result.get('error')!r}")
        self.record("native-0", ok, state, f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
        (run_dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
        (run_dir / "case-uart.json").write_text(json.dumps({"query": q, "boot": boot}, indent=2, default=str))

    def install_wisp_cut(self, fraction=0.5):
        """Power lost half way through install-wisp over a running stock app."""
        app = self.wisp_image()
        name = f"install-wisp-cut-{int(fraction * 100)}pct"
        run = Run(self.work, name, self.patched, self.app)
        try:
            cut_at = 1 + int(((len(app.data) - 16) // 256) * fraction)  # write 0 zeroes the vectors
            run.r.cmd(f"bootrom CutAfterWriteIndex {cut_at}")
            log = []
            t0 = time.time()

            def host(link):
                try:
                    with Session(link, log=log.append) as s:
                        s.require_patched_bootloader(self.patched)
                        self.wisp_session(s, app)
                    return "completed (no cut?)"
                except BaseException as error:  # noqa: BLE001
                    return repr(error)
            thread, first = run.attach(host)
            t = 0.0
            while thread.is_alive():
                run.r.cmd('emulation RunFor "1"')
                t += 1
            run.r.cmd("bootrom CutAfterWriteIndex -1")
            after_cut = run.mram()
            vectors_zero = after_cut[0x38000:0x38010] == bytes(16)
            jumps_before = len(JUMP_RE.findall(run.uart()))
            helo_before = sum(f.startswith(HELO_PREFIX) for f in run.frames())
            # Nobody answers now: the loader's window passes, then the bootloader decides.
            t += run.run_until(lambda: False, 12)
            helo_after = sum(f.startswith(HELO_PREFIX) for f in run.frames())
            jumped = len(JUMP_RE.findall(run.uart())) > jumps_before
            refused = not run.stock_running()

            def host2(link):
                with Session(link, log=log.append) as s:
                    s.require_patched_bootloader(self.patched)
                    return self.wisp_session(s, app)
            thread, second = run.attach(host2)
            run.r.cmd("rstgen PowerCut")
            while thread.is_alive():
                run.r.cmd('emulation RunFor "1"')
                t += 1
            t += run.run_until(run.stock_running, 60)
            mram = run.mram()
            image_ok = mram[0x38000:0x38000 + len(app.data)] == app.data
            boot_ok = mram[0x10000:0x10000 + len(self.patched)] == self.patched
            v2 = second.get("value") or {}
            # The cut rebooted the temple and its loader sent HELO again: session 1 got it instead of
            # a reply (TempleReset), so the frame log holds two (the claim's and the reboot's).
            ok = ("TempleReset" in str(first.get("value")) and helo_before >= 2 and vectors_zero and refused
                  and not jumped
                  and v2.get("crc_after") and not v2.get("vectors_zeroed") and image_ok and boot_ok
                  and run.stock_running())
            self.record(name, bool(ok),
                        (f"cut after ROM write {cut_at}: session 1 stopped ({str(first.get('value'))[:50]}); vectors read "
                         f"zero; the loader sent HELO again at the reboot; then no hand-off to the image (no jump "
                         f"logged, no app in 12 s); session 2 found the vectors zero, wrote the image and verified it; it boots" if ok else
                         f"first={first} vectors_zero={vectors_zero} refused={refused} helo={helo_before}->{helo_after} "
                         f"jumped={jumped} second={second} image_ok={image_ok} boot_ok={boot_ok} "
                         f"stock={run.stock_running()}"),
                        f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
            (run.dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
        finally:
            run.close()

    def install_states(self, old: bytes, label: str, ks):
        """Post-cut MRAM states of the stock app's bootloader copy (chunks of 4 KiB, ascending)."""
        for k in ks:
            mixed = bytearray(old) + b"\xff" * (len(self.patched) - len(old)) if len(old) < len(self.patched) else bytearray(old)
            mixed = bytearray(mixed[: max(len(mixed), len(self.patched))])
            mixed[: k * 4096] = self.patched[: k * 4096]
            name = f"install-{label}-{k:02d}of38"
            run = Run(self.work, name, bytes(mixed), self.app)
            try:
                t = run.run_until(run.stock_running, 12)
                frames = run.frames()
                helo = any(f.startswith(HELO_PREFIX) for f in frames)
                if run.stock_running():
                    state = "boots stock" + (" (loader HELO seen)" if helo else "")
                    brick = False
                else:
                    pc = run.r.cmd("cpu PC")
                    state = f"no stock app within 12 s (PC {pc.strip()}); " + ("HELO seen" if helo else "no HELO")
                    brick = not helo
                self.record(name, True, ("BRICK: " if brick else "") + state, f"{t:.1f} s virtual")
            finally:
                run.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", type=Path, default=REPO / ".wisp-cache")
    ap.add_argument("--only", nargs="*", default=["control", "boot-nohost", "hello", "info", "recover",
                                                   "recover-relay", "recover-cut", "recover-split", "temple-wdt",
                                                   "recover-fed", "install-wisp", "native-0", "install"])
    ap.add_argument("--install-chunks", default="0,1,2,9,10,11,19,29,30,31,35,36,37,38")
    ap.add_argument("--install-old", nargs="*", default=["2.4.0.24", "2.3.2.14"],
                    help="which old bootloader(s) the cut install states start from")
    a = ap.parse_args()
    h = Harness(a.cache.resolve())
    only = set(a.only)
    if "control" in only:
        h.control("control-2.4.0.24", h.bl24)
        h.control("control-2.3.2.14", h.bl23)
    if "boot-nohost" in only:
        h.boot_nohost()
    if "hello" in only:
        h.hello()
    if "info" in only:
        h.info()
    if "recover" in only:
        h.recover()
    if "recover-relay" in only:
        h.recover("recover-relay", relay=True)
    if "recover-cut" in only:
        h.recover("recover-cut-40pct", cut_fraction=0.4)
    if "recover-split" in only:
        h.recover_split()
    if "temple-wdt" in only:
        h.temple_wdt(fed=False)
        h.temple_wdt(fed=True)
    if "recover-fed" in only:
        h.recover_fed()
    if "install-wisp" in only:
        h.install_wisp()
        h.install_wisp_cut()
    if "native-0" in only:
        h.native_zero()
    if "install" in only:
        ks = [int(k) for k in a.install_chunks.split(",")]
        if "2.4.0.24" in a.install_old:
            h.install_states(h.bl24, "over-2.4.0.24", ks)
        if "2.3.2.14" in a.install_old:
            h.install_states(h.bl23, "over-2.3.2.14", ks)
    table = ["| Case | Result | End state | Run |", "| --- | --- | --- | --- |"]
    for name, ok, state, detail in h.rows:
        table.append(f"| `{name}` | {'pass' if ok else '**FAIL**'} | {state} | {detail} |")
    (h.work / "report.md").write_text("\n".join(table) + "\n")
    print("\n".join(table))
    return 0 if all(r[1] for r in h.rows) else 1


if __name__ == "__main__":
    sys.exit(main())
