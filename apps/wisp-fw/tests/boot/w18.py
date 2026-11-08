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
  temple-wdt-*  the temple's nPM1300 watchdog (renode/models/WispPmicWdt.cs on IOM7), armed at the
                start as the stock app leaves it, with a period scaled to Renode's virtual time
                (PMIC_PERIOD_S): `-unfed` runs drdaeman's programs and is power-cycled mid-session
                (a HELO instead of a reply); `-fed` runs the same work with the temple feed
                (feed.bin, dump_fed.bin) and survives; `recover-fed` writes the dead temple in one
                session with recover_fed.bin under the same armed watchdog. Each checks that every
                PMIC write during the session is the kick 07 04 01
  rung4-reads   rung 4's read-only tools (rung4.md G3) against the real patched bootloader: `peek` of
                every allowlisted region (the NOR record must be the MX one the NOR model answers,
                the loader's UART2 precondition and power callbacks read back as the loader needs
                them) and `pmic_read.bin` through the bootloader's IOM7 HAL under the armed PMIC
                watchdog: 58 registers back, nothing but kicks written to the PMIC in the session
"""
import argparse
import hashlib
import re
import shutil
import socket
import struct
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_DIR = HERE.parents[1]
REPO = APP_DIR.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "apps/wisp-recovery"))
from rung3 import STOCK_MARK, Renode, evenota_components
from wisp_w18 import image, native, pins
from wisp_w18.links import RelayPortLink, SocketLink
from wisp_w18.relay_model import RelayModel
from wisp_w18.session import AppImage, AppWriter, Session, SessionError

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

    def __init__(self, work: Path, name: str, bootloader: bytes, app: bytes | None, flag=(0xFFFFFFFF,) * 4):
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
        repl, n = re.subn(r"iom: G2emu\.G2Iom @ sysbus 0x40050000\n    size: 0x8000",
                          "iom: G2emu.G2Iom @ sysbus 0x40050000\n    size: 0x7000\n\n"
                          "pmicwdt: Wisp.WispPmicWdt @ sysbus 0x40057000", repl)
        assert n == 1, "rung-3 platform changed: iom line not found"
        # INFO0 (0x42000000), INFOC (0x400C2000) and CRYPTO (0x400C0000) fall into the rung-3
        # platform's plain periph_hi memory: zeros unless a case writes synthetic contents.
        (self.dir / "w18.repl").write_text(repl)
        resc = (APP_DIR / "renode/boot.resc").read_text().replace("$ORIGIN/", f"@{APP_DIR}/renode/")
        resc = resc.replace(f"include @{APP_DIR}/renode/models/WispUartIdle.cs",
                            f"include @{APP_DIR}/renode/models/WispUartIdle.cs\ninclude @{APP_DIR}/renode/models/WispCaseLink.cs")
        resc = resc.replace(f"include @{APP_DIR}/renode/models/WispProbe.cs",
                            f"include @{APP_DIR}/renode/models/WispProbe.cs\ninclude @{APP_DIR}/renode/models/WispPmicWdt.cs")
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
        self.work = cache / "w18"
        self.work.mkdir(parents=True, exist_ok=True)
        stock = cache / "stock"
        b24 = evenota_components((stock / "g2-2.4.0.24.bin").read_bytes())
        b23 = evenota_components((stock / "g2-2.3.2.14.bin").read_bytes())
        self.bl24, self.bl23 = b24[1], b23[1]
        self.patched = image.build_patched_bootloader(stock)
        self.app = image.stock_main(stock)
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

    # --- rung 4's reads (rung4.md G3) ---
    def rung4_reads(self):
        def setup(run):
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")

        def body(s):
            from wisp_w18.cli import describe_peek
            peek = {name: describe_peek(name, s.peek(name)) for name in pins.PEEK_REGIONS}
            return {"peek": peek, "pmic": s.pmic_read(), "feeds": s.feeds}

        def check(run, result):
            p = self.pmic(run)
            v = result.get("value")
            leading, _writes = self.leading_kicks(p["log"])
            if not v:
                return False, f"{result} {p}"
            peek = v["peek"]
            ok = (peek["nor"]["record"] == "0x4336a0" and peek["uart2"]["loader_precondition"]
                  and peek["power-callbacks"]["zero"] and peek["flag"]["word0"] == "0xffffffff"
                  and len(v["pmic"]) == len(pins.PMIC_READ_REGISTERS) and p["expiries"] == 0
                  and leading >= v["feeds"] + 1 and run.stock_running())
            timer = {f"{a:#06x}": f"{v['pmic'][a]:#04x}" for a in (0x0705, 0x0708, 0x0709, 0x070A)}
            return ok, (f"peek: NOR record {peek['nor']['record']} (MX), UART2 precondition holds, callbacks zero, "
                        f"board strap {peek['board']['strap_mV']} mV; pmic_read: {len(v['pmic'])} registers (timer "
                        f"{timer}); {leading} kicks and no other PMIC write in the session; stock app running"
                        if ok else f"{v} leading={leading} {p}")

        self.session_case("rung4-reads", self.app, body, check, setup=setup, temple_feed=True)

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
                                                   "recover-fed", "rung4-reads", "install-wisp", "install"])
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
    if "rung4-reads" in only:
        h.rung4_reads()
    if "install-wisp" in only:
        h.install_wisp()
        h.install_wisp_cut()
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
