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
  native-0      rung4.md W22/G15/W23: install-wisp writes the pinned native-0 (the committed files in
                apps/wisp-recovery/wisp_w18/data/native-0/, accepted first by install-wisp's own
                gate, native.resolve, with the repository's pins) over a running stock app through
                the patched loader, under the armed (scaled) PMIC watchdog with the temple feed; CONT;
                then the patched bootloader hands off to Wisp Boot (observe-only), which runs the
                app. Checked: the image in MRAM and the write order, the final CRC the W24 report
                must show (pins: crc32_aligned_over_stock), the app's arming writes and kicks (no
                PMIC power cycle, nothing else written), Wisp Boot's NOR commands (RDID/RDSR/reads
                only), the case-UART version/status/boot block, boot-watch's own `wisp` protocol
                (wisp_w18/case_uart.py) against the real app, and a case-UART reset that ends in the
                loader's HELO and a second native boot. Since W24 also: no Apollo watchdog bite, the
                app's first PMIC kick within 3 s of each boot's Wisp Boot kick, the PMIC model acting
                on the app's own arming writes (power-on values on expiry), and the strict start-up
                record (tests/boot/strict.py): native-0 FAILS on its writes to unmodelled power,
                clock and trim registers, the list of which is the case's finding
  native-0-recover  rung4.md W24's way back, exit item 4 from a running native image: native-0 in MRAM
                (as install-wisp leaves it over stock) boots behind the patched loader and runs; a
                case reset (the temple's reset line; in Renode a machine reset, `rstgen Request`);
                the loader's HELO is claimed (HOLD, the temple held); the loader-hello checks; the
                app region holds native-0 (its pinned CRC); `recover` writes the full stock 2.4.0.24
                main in one session with recover_fed.bin under the armed PMIC watchdog; the region's
                CRC over the stock image equals the stock pin (9c66404b); CONT; stock boots
  stage-0       rung4.md W24b: install-wisp writes the committed stage-0 (apps/wisp-recovery/wisp_w18/
                data/stage-0/, pinned at W24b-0 and accepted by install-wisp's own gate) over a
                running stock app through the patched loader; CONT; then boot-watch's own `wisp` protocol
                (wisp_w18/case_uart.py) at the relay's cadence (one request every 17.5 ms virtual):
                the boot report on every exchange until one answers, IDENT, every block. Then a
                case-UART RESET and a case reset (the reset line): after each, Wisp Boot's window
                answers the boot report while the requests also flood the patched loader's HELO
                window (which must still boot), naming the previous boot's last stage and the reset
                cause (SRAM kept across warm resets: rstgen RetainRange). Checked: the image and its
                CRC, no watchdog bite and no PMIC power cycle, every PMIC write a kick (Wisp Boot's
                once per boot, stage-0's every second), the clock measurement (LFRC 900 Hz as
                modelled), and no write by Wisp code to an unmodelled power, clock or trim register
  stage-0b      rung4.md W24d: the same as stage-0, with the committed stage-0b (data/stage-0b/, NOT
                pinned: its proposed-pin.json is added to the pin tables in this process only, so that
                install-wisp's own gate runs on the committed files), on the W24d models: the case link
                as ONE half-duplex wire (WispCaseLink HalfDuplex, on in every case here: a byte sent
                while pad 42 is not UART2TX is lost, a byte from the case is received once pad 44 is
                UART2RX, corrupted if pad 42 drives then), MSPICFG's PRSTN/IPRSTN (WispMspiNor: MSPI1
                does nothing while held in reset; any access then fails the case), and the D-cache
                (WispRstGen CacheModel: across a warm reset only lines cleaned by wisp_dcache_clean
                survive). Also checked: Wisp Boot's NOR phase read the MX id with result 0
  stage-0-models the pinned stage-0 (W24b) under the same models: it must FAIL with each of the three
                silicon findings (both pads in UART function by Wisp Boot and stage-0, MSPI1 accessed in
                reset by Wisp Boot, no clean and the peeked record lost: all zeros, as on silicon); the
                row passes when the models catch all three. native-0 and native-0-recover run with the
                half-duplex model off (native-0's Zephyr app keeps both pads in UART function) and list
                the W24d findings with their failures
  temple-wdt-*  the temple's nPM1300 watchdog (renode/models/WispPmicWdt.cs on IOM7), armed at the
                start as the stock app leaves it, with a period scaled to Renode's virtual time
                (PMIC_PERIOD_S): `-unfed` runs drdaeman's programs and is power-cycled mid-session
                (a HELO instead of a reply); `-fed` runs the same work with the temple feed
                (feed.bin, dump_fed.bin) and survives; `recover-fed` writes the dead temple in one
                session with recover_fed.bin under the same armed watchdog. Each checks that every
                PMIC write during the session is the kick 07 04 01
  rung4-reads   rung 4's read-only tools (rung4.md G3) against the real patched bootloader: `peek` of
                every allowlisted region (the NOR record must be the MX one the NOR model answers,
                UART2's table entry and the power callbacks read back as the loader leaves them)
                and `pmic_read.bin` through the bootloader's IOM7 HAL under the armed PMIC
                watchdog: 58 registers back, nothing but kicks written to the PMIC in the session
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
sys.path.insert(0, str(APP_DIR / "scripts"))
import pmic_baseline  # noqa: E402
import strict  # noqa: E402
from rung3 import FIRMWARE_FILES, STOCK_MARK, Lfs, Renode, build_lfs_tool, evenota_components
from wisp_w18 import case_uart as recovery_case_uart
from wisp_w18 import image, native, pins, status
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
STAGE_0_DIR = REPO / "apps/wisp-recovery/wisp_w18/data/stage-0"
STAGE_0B_DIR = REPO / "apps/wisp-recovery/wisp_w18/data/stage-0b"
NATIVE_1_DIR = REPO / "apps/wisp-recovery/wisp_w18/data/native-1"
BASELINE = APP_DIR / "images/pmic-baseline-w21.json"
DIAG_ADDR = 0x20370000
STAGE_APP_IDLE = 0x92
RAILS_ON = ["08 02 01", "04 00 01"]   # LDSW2 on, then BUCK1 on (stock's order, hardware.md "Display")
RAILS_OFF = ["04 01 01", "08 03 01"]  # BUCK1 off, then LDSW2 off
PMIC_ARM = ["07 05 0a", "07 08 00 3c 00", "07 03 01", "07 00 01"]
POWER_ON = APP_DIR / "images/pmic-poweron-w24.json"
RELAY_EXCHANGE_S = 0.0175  # one relay exchange on hardware (W18 F1d: 17.5 ms)
RELAY_POLL_BOUND_S = 31.0  # an unanswered exchange waits this long for a temple frame (recovery.md)
APP_KICK_WITHIN_S = 3.0     # the app's first PMIC kick after Wisp Boot's, every boot


def pmic_realism(run) -> None:
    """The PMIC model acts on the app's arming writes and comes back at the W24 power-on values."""
    run.r.cmd("pmicwdt ActOnWrites true")
    for reg, v in json.loads(POWER_ON.read_text())["registers"].items():
        run.r.cmd(f"pmicwdt SetPowerOn {int(reg, 16):#x} {int(v['value'], 16):#x}")


def virtual_ms(text: str) -> int:
    """Renode's TimeInterval text ("HH:MM:SS.ffffff" or seconds) in ms."""
    parts = text.split(":")
    s = 0.0
    for p_ in parts:
        s = s * 60 + float(p_)
    return int(round(s * 1000))


def liveness(run, fails: list[str]) -> dict:
    """W24 in Renode terms: no Apollo watchdog reset, and after every Wisp Boot entry (probe
    milestone) the app kicks the PMIC within APP_KICK_WITHIN_S, before the next boot."""
    bites = int(run.r.cmd("wdt Bites").split()[0], 0)
    writes = strict.pmic_writes(run.r.cmd("pmicwdt PmicPcLog"))
    (run.dir / "pmic-pc.log").write_text("\n".join(map(str, writes)) + "\n")
    starts = [virtual_ms(l.split(" t=")[1].split()[0]) for l in run.r.cmd("probe Report").splitlines()
              if l.startswith("wisp_boot_main ") and " t=" in l]
    late = []
    for n, t0 in enumerate(starts):
        t1 = starts[n + 1] if n + 1 < len(starts) else None
        app = [e["ms"] for e in writes if not e["wisp_boot"] and e["bytes"] == strict.KICK and e["ms"] >= t0
               and (t1 is None or e["ms"] < t1)]
        if t1 is not None and t1 - t0 < APP_KICK_WITHIN_S * 1000 and not app:
            continue  # a boot cut short on purpose (a reset by the case) before the app's first kick
        if not app or app[0] - t0 > APP_KICK_WITHIN_S * 1000:
            late.append(t0)
    if bites:
        fails.append(f"{bites} Apollo watchdog bite(s)")
    if not starts:
        fails.append("Wisp Boot never ran")
    if late:
        fails.append(f"no app PMIC kick within {APP_KICK_WITHIN_S:g} s of the boot at {late} ms")
    return {"bites": bites, "boots": len(starts), "late_boots": late,
            "wisp_boot_kicks": sum(e["wisp_boot"] for e in writes)}


def strict_check(run, fails: list[str]) -> list[dict]:
    """The strict start-up record: Wisp code's writes to unmodelled power/clock/trim registers."""
    dump = run.r.cmd("probe StrictDump")
    (run.dir / "strict.txt").write_text(dump + "\n")
    bad = strict.unallowed_writes(strict.parse(dump))
    if bad:
        fails.append(f"{len(bad)} write(s) to unmodelled power/clock/trim registers (strict.txt): {strict.describe(bad)}")
    return bad


def nm_all(elf: Path, name: str, kinds: str = "tT") -> list[int]:
    """Every address of a (possibly local, repeated) symbol."""
    out = subprocess.run(["arm-none-eabi-nm", str(elf)], check=True, capture_output=True, text=True).stdout
    return sorted({int(p[0], 16) & ~1 for p in (l.split() for l in out.splitlines())
                   if len(p) == 3 and p[1] in kinds and p[2] == name})


def silicon_findings(run) -> dict:
    """The W24d models' records (rung4.md, "W24d: stage-0b"): who left both case-link pads in UART
    function at once (WispCaseLink, half duplex), MSPI1 accesses while held in reset (WispMspiNor,
    MSPICFG PRSTN/IPRSTN), and the D-cache cleans (WispRstGen)."""
    both = run.r.cmd("uart2 BothUartLog")
    owners = sorted({strict.owner(int(m[1], 16)) + ("" if m[2] == "wisp" else " (not while Wisp ran)")
                     for m in re.finditer(r" pc 0x([0-9A-F]+) (\w+)", both)})
    in_reset = run.r.cmd("nor InResetLog").splitlines()
    (run.dir / "pads.log").write_text(run.r.cmd("uart2 PadLog") + "\n")
    cleans = run.r.cmd("rstgen CleanLog")
    (run.dir / "cleans.log").write_text(cleans + "\n")
    in_reset_pcs = [int(m[1], 16) for m in (re.search(r" pc 0x([0-9A-F]+)", l) for l in in_reset) if m]
    return {"both_uart": owners, "both_uart_wisp": [o for o in owners if o in ("wisp-boot", "app")],
            "wire": run.r.cmd("uart2 WireReport").strip(),
            "nor_in_reset": int(run.r.cmd("nor InResetAccesses").split()[0], 0),
            "nor_in_reset_wisp": [p_ for p_ in in_reset_pcs if strict.owner(p_) in ("wisp-boot", "app")],
            "nor_in_reset_first": in_reset[:1],
            "cleans": int(cleans.split("\n")[0].split("=")[1])}


def silicon_failures(f: dict) -> list[str]:
    out = []
    if f["both_uart_wisp"]:
        out.append(f"half duplex: both case-link pads in UART function at once by {f['both_uart_wisp']}")
    if f["nor_in_reset"]:
        out.append(f"MSPI1 accessed {f['nor_in_reset']} times while held in reset: {f['nor_in_reset_first']}")
    return out


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Run:
    """One Renode machine: the rung-3 platform with WispCaseLink on UART2."""

    def __init__(self, work: Path, name: str, bootloader: bytes, app: bytes | None, flag=(0xFFFFFFFF,) * 4,
                 nor: Path | None = None, panel: bool = False):
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
        if panel:
            # MSPI0 with the microLED panel as a recorder (WispMspiPanel, JBD4010), for native-1's
            # boot screen; the rung-3 platform keeps MSPI0 as plain storage otherwise.
            repl, n = re.subn(r"mspi0: Wisp\.WispTrace @ sysbus 0x40060000\n    size: 0x1000\n    trace: 0\n"
                              r"    baseAddress: 0x40060000",
                              "panel: Wisp.WispMspiPanel @ sysbus 0x40060000\n    IRQ -> nvic@20", repl)
            assert n == 1, "rung-3 platform changed: mspi0 line not found"
        # INFO0 (0x42000000), INFOC (0x400C2000) and CRYPTO (0x400C0000) fall into the rung-3
        # platform's plain periph_hi memory: zeros unless a case writes synthetic contents.
        (self.dir / "w18.repl").write_text(repl)
        resc = (APP_DIR / "renode/boot.resc").read_text().replace("$ORIGIN/", f"@{APP_DIR}/renode/")
        resc = resc.replace(f"include @{APP_DIR}/renode/models/WispUartIdle.cs",
                            f"include @{APP_DIR}/renode/models/WispUartIdle.cs\ninclude @{APP_DIR}/renode/models/WispCaseLink.cs")
        resc = resc.replace(f"include @{APP_DIR}/renode/models/WispProbe.cs",
                            f"include @{APP_DIR}/renode/models/WispProbe.cs\ninclude @{APP_DIR}/renode/models/WispIomTypes.cs\n"
                            f"include @{APP_DIR}/renode/models/WispPmicWdt.cs")
        if panel:
            resc = resc.replace(f"include @{APP_DIR}/renode/models/WispProbe.cs",
                                f"include @{APP_DIR}/renode/models/WispProbe.cs\ninclude @{APP_DIR}/renode/models/WispMspiPanel.cs")
        resc = re.sub(r"machine LoadPlatformDescription .*", f"machine LoadPlatformDescription @{self.dir / 'w18.repl'}", resc)
        (self.dir / "w18.resc").write_text(resc)
        self.r = Renode(self.dir, free_port())
        r = self.r
        out = r.cmd(f"include @{self.dir / 'w18.resc'}")
        if "error" in out.lower() or "could not" in out.lower():
            raise RuntimeError(f"Renode platform failed to load: {out[-800:]}")
        r.cmd("uart2 HostTimeoutMs 600000")
        # The case link is one half-duplex wire (WispCaseLink, rung4.md W24d): the loader turns it round
        # for every send, as Wisp code must. native-0's cases turn the model off (see there).
        r.cmd("uart2 HalfDuplex true")
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

    def frame_count(self) -> int:
        return int(self.r.cmd("uart2 FrameCount").split()[0], 0)

    def frame(self, i: int) -> str:
        out = self.r.cmd(f"uart2 FrameAt {i}").strip()
        if out and not re.fullmatch(r"[0-9a-f]+", out):
            raise RuntimeError(f"uart2 FrameAt failed: {out}")
        return out

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
        line = f"{'PASS' if ok else 'FAIL'} {name}: {state} ({detail})"
        print(line, flush=True)
        with (self.work / "rows.log").open("a") as f:  # survives a run that is stopped before its table
            f.write(line + "\n")

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
            ok = (peek["nor"]["record"] == "0x4336a0" and peek["uart2"]["loader_state"]
                  and peek["power-callbacks"]["zero"] and peek["flag"]["word0"] == "0xffffffff"
                  and len(v["pmic"]) == len(pins.PMIC_READ_REGISTERS) and p["expiries"] == 0
                  and leading >= v["feeds"] + 1 and run.stock_running())
            timer = {f"{a:#06x}": f"{v['pmic'][a]:#04x}" for a in (0x0705, 0x0708, 0x0709, 0x070A)}
            return ok, (f"peek: NOR record {peek['nor']['record']} (MX), UART2 as the loader leaves it, callbacks zero, "
                        f"board strap {peek['board']['strap_mV']} mV; pmic_read: {len(v['pmic'])} registers (timer "
                        f"{timer}); {leading} kicks and no other PMIC write in the session; stock app running"
                        if ok else f"{v} leading={leading} {p}")

        self.session_case("rung4-reads", self.app, body, check, setup=setup, temple_feed=True)

    # --- install-wisp (rung4.md G1) ---
    def wisp_image(self) -> AppImage:
        """A non-stock image install-wisp may write in emulation: the stock app (it boots) with a
        64-byte marker appended, so the region it fills and its hash differ from stock. The writer
        refuses any image that is not pinned with R4-1 approved, so this process (Renode, never a
        case) approves R4-1 and pins it in memory, next to the repository's own pins."""
        data = self.app + b"WISP-RENODE-G1-" * 4 + b"END!"
        pins.R4_1_APPROVED = True
        # Added, not replacing the table: later cases (native-0) use the repository's own pins.
        pins.WISP_IMAGES = {**pins.WISP_IMAGES, "renode-synthetic": {"image_sha256": image.sha(data)}}
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
        try:
            data, facts = self.native_0_pinned()
        except native.NativeRefused as error:
            self.record("native-0", False, f"install-wisp's gate refused the committed native-0: {error}", "")
            return
        app = AppImage("native-0", data, facts["image_sha256"], int(facts["end"], 16), check=native_rule3)
        nor = self.native_nor()
        run = Run(self.work, "native-0", self.patched, self.app, nor=nor)
        # native-0 (pinned, W23) keeps both case-link pads in UART function (its Zephyr pinctrl) and its
        # Wisp Boot writes MSPICFG = 0: the half-duplex wire would only corrupt its queries, so its own
        # checks run on the full-duplex model and the W24d findings are listed with its failures.
        run.r.cmd("uart2 HalfDuplex false")
        run_dir = run.dir
        log = []
        t0 = time.time()
        try:
            self.native_probes(run)
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")
            pmic_realism(run)

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
            # 0.1 s steps: a longer RunFor through the patched loader's boot window (no host
            # attached) can stall Renode, as in rung3.py.
            t += run.run_until(lambda: uart().count(banner) >= 1 and uart().count("wisp: heartbeat", uart().rfind(banner)) >= 3, 40, step=0.1)
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
            st_code, ident = case_uart.decode_reply(ask(case_uart.ident_request()), case_uart.OP_IDENT)
            q["ident"] = case_uart.decode_ident(ident) if st_code == 0 else {"code": st_code}
            raw = case_uart.read_block(ask, case_uart.BLOCK_STATUS)
            q["status"] = case_uart.decode_status(raw) if raw else {}
            block = case_uart.read_block(ask, case_uart.BLOCK_BOOT) or b""
            boot = case_uart.decode_boot_status(block) if len(block) in case_uart.BOOT_STATUS_SIZES.values() else {}
            # boot-watch's own protocol (apps/wisp-recovery wisp_w18/case_uart.py) against the real app.
            hook = recovery_case_uart.WispStatus()
            answers = []
            for i in range(200):  # both blocks, then IDENT until the BLE bring-up has ended
                decoded = hook.decode(ask(hook.request(i)))
                if decoded is not None:
                    answers.append(decoded)
                if hook.complete(answers):
                    break
                if hook.block(case_uart.BLOCK_STATUS) is not None and hook.block(case_uart.BLOCK_BOOT) is not None:
                    run.r.cmd('emulation RunFor "0.25"')
            hook_summary = hook.summary(answers)
            q["boot_watch"] = {"complete": hook.complete(answers), "queries": i + 1}
            # The reset command: the reply, then the patched loader's HELO at the reboot (nobody
            # answers it), then a second native boot.
            helo_before = sum(f.startswith(HELO_PREFIX) for f in run.frames())
            code, _ = case_uart.decode_reply(ask(case_uart.reset_request()), case_uart.OP_RESET)
            banners = uart().count(banner)
            t += run.run_until(lambda: uart().count(banner) > banners and
                               uart().count("wisp: heartbeat", uart().rfind(banner)) >= 2, 40, step=0.1)
            helo_after = sum(f.startswith(HELO_PREFIX) for f in run.frames())
            pm = self.pmic(run)
            mram = run.mram()
            watched = run.r.cmd("nor WatchedLog").split("\n")
            watched_writes = int(run.r.cmd("nor WatchedWrites").split()[0], 0)
            rep = run.r.cmd("probe Report").splitlines()
            boots = sum(l.startswith("wisp_boot_main ") for l in rep)
            handoffs = sum(l.startswith("hw_jump ") for l in rep)
            fails = []
            pc_log = run.r.cmd("pmicwdt PmicPcLog")
            live = liveness(run, fails)
            fails += silicon_failures(silicon_findings(run))
            strict_bad = strict_check(run, fails)
        finally:
            run.close()
        v = result.get("value") or {}
        if mram[0x38000:0x38000 + len(data)] != data:
            fails.append("native-0 not in MRAM")
        want_crc = f"{pins.WISP_IMAGES['native-0']['crc32_aligned_over_stock']:08x}"
        if v.get("crc_after") != want_crc:
            fails.append(f"final CRC {v.get('crc_after')}, pinned for W24 {want_crc}")
        hb = hook_summary.get("boot") or {}
        if not (q["boot_watch"]["complete"] and hook_summary.get("status", {}).get("rev") == q["status"].get("rev")
                and hb.get("staging_id") == boot.get("staging_id") and hb.get("inventory") == boot.get("inventory")):
            fails.append(f"boot-watch's wisp protocol disagrees with the reference: {q['boot_watch']} {hook_summary}")
        if mram[0x10000:0x10000 + len(self.patched)] != self.patched:
            fails.append("bootloader region changed")
        if not (len(writes) > 2 and writes[0] == (pins.APP_BASE, 4) and writes[-1] == (pins.APP_BASE, 4)
                and all(pins.APP_BASE <= d and d + 4 * n <= app.end for d, n in writes)):
            fails.append(f"install write order/bound: first {writes[:2]} last {writes[-1:]}")
        # Wisp Boot's own kicks are checked apart from the app's writes, and left out of them.
        wb_kicks, wb_other = strict.wisp_boot_pmic(pc_log)
        if wb_other:
            fails.append(f"Wisp Boot wrote the PMIC other than the kick: {wb_other}")
        wb_at = {(e["ms"], e["bytes"]) for e in strict.pmic_writes(pc_log) if e["wisp_boot"]}
        kicks_after = [l for l in pm["log"].splitlines() if " ms write " in l
                       and (int(l.split(" ms write ")[0]), l.split(" ms write ")[1].strip()) not in wb_at]
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
        diffs = pmic_baseline.check([bytes.fromhex(w.replace(" ", "")) for w in data_writes])
        if diffs:
            fails.append(f"PMIC writes differ from W21's snapshot: {diffs[:4]}")
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
                 f"and last; Wisp Boot kicked the PMIC {wb_kicks}x (nothing else); {live}; strict clean; CONT -> observe-only Wisp Boot -> app; PMIC armed with stock's writes, "
                 f"{pm['kicks']} kicks, no power cycle; Wisp Boot NOR commands RDID/RDSR/READ only; case UART: "
                 f"{q['version']['id']} version, stage {st.get('stage')}, {len(boot.get('inventory', []))} firmware files, "
                 f"staging {boot.get('staging_id', 0):08x}; reset over the case UART -> loader HELO -> second "
                 f"native boot" if ok else f"{'; '.join(fails)} {result.get('error')!r}")
        self.record("native-0", ok, state, f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
        (run_dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
        (run_dir / "case-uart.json").write_text(json.dumps({"query": q, "boot": boot, "boot_watch": hook_summary},
                                                           indent=2, default=str))

    # --- stage-0 (rung4.md W24b) and stage-0b (W24d) ---
    @staticmethod
    def stage_0_files() -> tuple[bytes, bytes, bytes, dict]:
        """The committed stage-0 (data/stage-0/, pinned at W24b-0), through install-wisp's own
        gate against the repository's pins."""
        data = native.STAGE_0_FILES["image"].read_bytes()
        elf = native.STAGE_0_FILES["elf"].read_bytes()
        map_text = native.STAGE_0_FILES["map"].read_bytes()
        facts = native.resolve(data, elf, map_text, image.sha(data)[:12])
        if facts["name"] != "stage-0":
            raise native.NativeRefused(f"resolved as {facts['name']}, not the stage-0 pin")
        return data, elf, map_text, facts

    @staticmethod
    def stage_0b_files() -> tuple[bytes, bytes, bytes, dict]:
        """The committed stage-0b (data/stage-0b/), NOT pinned (rung4.md W24d: pinning follows an
        independent review). This process (Renode, never a case) adds its proposed pin
        (proposed-pin.json) to the pin tables in memory, next to the repository's own, so that
        install-wisp's whole gate (native.resolve) runs on the committed files as it would after
        pinning. Wisp Boot's status block `st` moved in this build: the peek region is taken from
        the committed wisp_boot.elf, as the pin will have to record it."""
        prop = json.loads((STAGE_0B_DIR / "proposed-pin.json").read_text())
        pin = {k: (tuple(v) if k == "gates" else int(v, 16) if k.startswith("crc32") else v)
               for k, v in prop["image"].items()}
        pins.WISP_IMAGES = {**pins.WISP_IMAGES, "stage-0b": pin}
        pins.WISP_BOOT_PASSED = {**pins.WISP_BOOT_PASSED, pin["wisp_boot_slot_sha256"]: prop["wisp_boot"]}
        st = nm_all(STAGE_0B_DIR / "wisp_boot.elf", "st", kinds="bB")
        if len(st) != 1 or st[0] != int(prop["peek_wisp_boot_status"], 16):
            raise native.NativeRefused(f"`st` in wisp_boot.elf {st} is not proposed-pin.json's peek address")
        _, size, what = pins.PEEK_REGIONS["wisp-boot-status"]
        pins.PEEK_REGIONS = {**pins.PEEK_REGIONS, "wisp-boot-status": (st[0], size, what)}
        data = (STAGE_0B_DIR / "stage-0b.bin").read_bytes()
        elf = (STAGE_0B_DIR / "stage0.elf").read_bytes()
        map_text = (STAGE_0B_DIR / "stage0.map").read_bytes()
        facts = native.resolve(data, elf, map_text, image.sha(data)[:12])
        if facts["name"] != "stage-0b":
            raise native.NativeRefused(f"resolved as {facts['name']}, not stage-0b's proposed pin")
        return data, elf, map_text, facts

    @staticmethod
    def watch(run, hook, seconds: float, until=None, await_helo=False) -> dict:
        """boot-watch's loop (status.watch) as the real relay runs it (case_exchange.c), by
        injection: the protocol times each request (hook.wait), then the exchange is pending until
        the first temple frame or RELAY_POLL_BOUND_S, and nothing else is sent meanwhile; frames
        that come while no exchange is pending are lost (the relay re-arms before each wait). The
        loader's HELO is a reboot and re-anchors the protocol's timing. `await_helo`: the first
        exchange is an empty G2TX (listen only), for a reboot that the harness itself caused."""
        out = {"answers": [], "helo": 0, "foreign": 0, "unanswered": 0, "seconds": 0.0, "exchanges": []}
        t, i = 0.0, 0
        first = True
        while t < seconds:
            listen = first and await_helo
            first = False
            wait = None if listen else hook.wait(t)
            if wait and wait > 0:
                left = min(wait, seconds - t)
                while left > 1e-9:  # short steps: a long RunFor through the loader's window can stall Renode
                    run.step(min(0.1, left))
                    left -= min(0.1, left)
                t += min(wait, seconds - t)
                if t >= seconds:
                    break
            seen = run.frame_count()
            req = b"" if listen else hook.request(i)
            if req:
                run.r.cmd(f'uart2 Inject "{req.hex()}"')
                i += 1
            sent, got = t, None
            while t - sent < RELAY_POLL_BOUND_S and t < seconds:
                run.step(RELAY_EXCHANGE_S)
                t += RELAY_EXCHANGE_S
                if run.frame_count() > seen:
                    got = bytes.fromhex(run.frame(seen))  # the first frame; the relay drops the rest
                    break
            out["exchanges"].append({"t": round(sent, 3), "req": req[4:8].hex(), "waited": round(t - sent, 3),
                                     "got": got[4:12].hex() if got else None})
            if got is None:
                out["unanswered"] += 1
                if t - sent >= RELAY_POLL_BOUND_S:  # not when the watch merely ran out
                    hook.no_answer(t)
            elif status.is_loader_hello(got):
                out["helo"] += 1
                hook.reset()
                hook.reboots += 1
                hook.anchor(t, "helo")
            else:
                hook.at(t)
                d = hook.decode(got)
                if d is None:
                    out["foreign"] += 1
                else:
                    out["answers"].append({"t": round(t, 3), **d})
            if until and until(out):
                break
        out["seconds"] = round(t, 3)
        out["queries"] = i
        return out

    def stage_zero(self, variant: str = "stage-0b"):
        """install-wisp of stage-0b (or the pinned stage-0), boot-watch's wisp protocol, then a
        RESET and a case reset, on the W24d models: the half-duplex wire, MSPICFG's resets and the
        D-cache. stage-0b must pass. The pinned stage-0 (`stage-0-models`) must FAIL with each of
        the three silicon findings; the row passes when the models catch all three."""
        old = variant == "stage-0"
        name = "stage-0-models" if old else "stage-0b"
        d = STAGE_0_DIR if old else STAGE_0B_DIR
        try:
            data, _elf, _map, facts = self.stage_0_files() if old else self.stage_0b_files()
        except (OSError, ValueError, KeyError, native.NativeRefused) as error:
            self.record(name, False, f"{variant} files or install-wisp's gate: {error}", "")
            return
        pin = pins.WISP_IMAGES[facts["name"]]
        app = AppImage(variant, data, facts["image_sha256"], int(facts["end"], 16), check=native_rule3)
        run = Run(self.work, name, self.patched, self.app, nor=self.native_nor())
        log, fails, t0 = [], [], time.time()
        hook = recovery_case_uart.WispStatus()
        summary1, clock, code, report_reset, report_case = {}, {}, None, {}, {}
        first = second = third = {"seconds": 0.0, "helo": 0, "answers": [], "exchanges": [], "queries": 0}
        try:
            self.native_probes(run, d / "wisp_boot.elf")
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")
            pmic_realism(run)
            # Wisp Boot's whole RAM survives warm resets (the record and its status block `st`, which
            # the peek in part 4 reads); the silicon question is the same for both. With the D-cache
            # model, only what Wisp code cleaned survives (every wisp_dcache_clean in both ELFs).
            run.r.cmd("rstgen RetainRange 0x20370000 0x10000")
            run.r.cmd("rstgen CacheModel true")
            for elf in (d / "wisp_boot.elf", d / "stage0.elf"):
                for addr in nm_all(elf, "wisp_dcache_clean"):
                    run.r.cmd(f"rstgen CleanHook {addr:#x}")

            def host(link):
                with Session(link, log=log.append, temple_feed=True) as s:
                    s.require_patched_bootloader(self.patched)
                    return self.wisp_session(s, app)
            thread, result = run.attach(host)
            t = 0.0
            while thread.is_alive() and t < 900:
                run.step(1)
                t += 1
            writes = self.write_log(run)
            # 1. The first boot after CONT: the protocol until it is complete and stage-0 has measured.
            # The harness steps 1 s at a time while the host session runs, so CONT was up to 1 s ago:
            # the report is asked 2 s in, from stage-0 (Wisp Boot's window is aimed in 2 and 3).
            if old:
                # The pinned stage-0: one boot behind the loader is enough for the pad and MSPI findings
                # (nothing answers on the half-duplex wire, so the long watches below would only wait out
                # the relay bound), then the peek after a case reset shows the record lost.
                # Short steps: a long RunFor through the patched loader's window can stall Renode.
                for _ in range(40):
                    run.step(0.1)
                hook.report_at = (0.2,)
                first = self.watch(run, hook, 2)
            else:
                hook.report_at = (2.0,)
                first = self.watch(run, hook, 20, until=lambda o: hook.complete(o["answers"]))
                hook.report_at = recovery_case_uart.WispStatus.REPORT_AT_S
                summary1 = hook.summary(first["answers"])
                # stage-0's first measurement starts 2 s after it started and takes about 1.1 s.
                run.step(3)
                try:
                    raw = case_uart.read_block(lambda r: self.inject(run, r), case_uart.BLOCK_CLOCK)
                except RuntimeError as error:  # no reply (the old stage-0 on the half-duplex wire)
                    raw, summary1["clock_error"] = None, str(error)
                summary1["clock"] = case_uart.decode_clock(raw) if raw else None
                # 2. RESET over the case UART, then the reboot's boot report (through the loader's window).
                n_reports = len(hook.reports)
                try:
                    code, _ = recovery_case_uart.decode_reply(self.inject(run, recovery_case_uart.reset_request()),
                                                              recovery_case_uart.OP_RESET)
                except RuntimeError:
                    code = None
                second = self.watch(run, hook, 10, until=lambda o: len(hook.reports) > n_reports and hook.ident,
                                    await_helo=True)
                report_reset = hook.reports[n_reports] if len(hook.reports) > n_reports else {}
                # 3. The case's reset line (on hardware: the relay's start).
                n_reports = len(hook.reports)
                run.r.cmd('rstgen Request "case-reset"')
                third = self.watch(run, hook, 10, until=lambda o: len(hook.reports) > n_reports and hook.ident,
                                   await_helo=True)
                report_case = hook.reports[n_reports] if len(hook.reports) > n_reports else {}
                run.step(2)
            # 4. The W24b runbook's peek after step 7: a case reset into a held loader, then what the
            # interrupted boot left in Wisp Boot's RAM, read through dump_fed (pins.PEEK_REGIONS).
            def peek_host(link):
                with Session(link, log=log.append, temple_feed=True) as s:
                    s.require_patched_bootloader(self.patched)
                    return {n: s.peek(n) for n in ("ssram-power", "rstgen-stat", "wisp-record", "wisp-boot-status")}
            pthread, presult = run.attach(peek_host)
            run.r.cmd('rstgen Request "case-reset"')
            tp = 0.0
            while pthread.is_alive() and tp < 300:
                run.step(0.5)
                tp += 0.5
            peeked = presult.get("value") or {}
            t += first["seconds"] + second["seconds"] + third["seconds"] + 5 + tp
            live = liveness(run, fails)
            strict_bad = strict_check(run, fails)
            pc_log = run.r.cmd("pmicwdt PmicPcLog")
            pm = self.pmic(run)
            mram = run.mram()
            silicon = silicon_findings(run)
        finally:
            run.close()
        v = result.get("value") or {}
        if mram[0x38000:0x38000 + len(data)] != data:
            fails.append(f"{variant} not in MRAM")
        want_crc = f"{pin['crc32_aligned_over_stock']:08x}"
        if v.get("crc_after") != want_crc:
            fails.append(f"final CRC {v.get('crc_after')}, pinned {want_crc}")
        if mram[0x10000:0x10000 + len(self.patched)] != self.patched:
            fails.append("bootloader region changed")
        if not (len(writes) > 2 and writes[0] == (pins.APP_BASE, 4) and writes[-1] == (pins.APP_BASE, 4)
                and all(pins.APP_BASE <= d and d + 4 * n <= app.end for d, n in writes)):
            fails.append(f"install write order/bound: first {writes[:2]} last {writes[-1:]}")
        wb_kicks, wb_other = strict.wisp_boot_pmic(pc_log)
        others = sorted({e["bytes"] for e in strict.pmic_writes(pc_log) if e["bytes"] != strict.KICK
                         and (e["wisp_boot"] or 0x448000 <= e["pc"] < 0x7F8000)})
        if wb_other or others:
            fails.append(f"Wisp code wrote the PMIC other than the kick: {wb_other or others}")
        if pm["expiries"]:
            fails.append(f"PMIC watchdog expired {pm['expiries']}x")
        ident = summary1.get("ident") or {}
        clock = summary1.get("clock") or {}
        if ident.get("image_kind") != recovery_case_uart.IMAGE_KIND_STAGE0 or ident.get("stage") != "bare-metal":
            fails.append(f"IDENT {ident}")
        if not first["answers"] or (summary1.get("boot_report") or {}).get("source") not in ("wisp-boot", "app"):
            fails.append(f"no boot report on the first boot: {summary1.get('boot_report')}")
        if (summary1.get("boot") or {}).get("version") != 2:
            fails.append(f"Wisp Boot block {summary1.get('boot_error') or summary1.get('boot')}")
        if clock.get("result") != "ok" or not 850 <= clock.get("lfrc_hz", 0) <= 960:
            fails.append(f"clock {clock or summary1.get('clock_error')}")
        if (summary1.get("boot") or {}).get("nor_id") != 0x3925C2 or (summary1.get("boot") or {}).get("nor_result") != 0:
            fails.append(f"Wisp Boot's NOR phase: {summary1.get('boot')}")
        if code != 0 or second["helo"] != 1:
            fails.append(f"RESET: reply {code}, {second['helo']} HELO")
        if report_reset.get("source") != "wisp-boot" or report_reset.get("prev_stage") != "s0-reset-request" \
                or report_reset.get("reset_cause_names") != ["sw-por"]:
            fails.append(f"boot report after RESET: {report_reset}")
        if third["helo"] != 1 or report_case.get("source") != "wisp-boot" or \
                report_case.get("reset_cause_names") != ["external"] or \
                report_case.get("prev_stage") not in ("s0-loop", "s0-measure"):
            fails.append(f"boot report after the case reset ({third['helo']} HELO): {report_case}")
        if not (report_reset.get("boot", 0) + 1 == report_case.get("boot", -1)):
            fails.append(f"boot counter {report_reset.get('boot')} -> {report_case.get('boot')}")
        if report_reset.get("asked_s_after_release") is None:
            fails.append("the report after RESET did not come from Wisp Boot's window at an aimed offset")
        for part, w in (("RESET", second), ("case reset", third)):
            rep = [e["t"] for e in w["exchanges"] if e["req"] == "57535004" and e["got"]]
            idents = [e["t"] for e in w["exchanges"] if e["req"] == "57535001"]
            if not rep or not idents or idents[0] - rep[0] < recovery_case_uart.WispStatus.APP_AFTER_REPORT_S:
                fails.append(f"{part}: IDENT not {recovery_case_uart.WispStatus.APP_AFTER_REPORT_S} s after the report: "
                             f"{w['exchanges'][:4]}")
        peek_record, peek_status = {}, {}
        if "error" in presult or not peeked:
            fails.append(f"peek after the case reset: {presult.get('error')!r}")
        else:
            peek_record = recovery_case_uart.decode_diag_record(peeked["wisp-record"], check=False)
            try:
                peek_status = recovery_case_uart.decode_boot_status(peeked["wisp-boot-status"])
            except ValueError as error:
                peek_status = {"error": str(error)}
            if not (peek_record.get("valid") and peek_record.get("stage") in ("s0-loop", "s0-measure")
                    and peek_record.get("boots") == report_case.get("boot")
                    and peek_record.get("reset_cause_names") == ["external"]):
                fails.append(f"peek of the record after the case reset: {peek_record}")
            if not ((peek_status.get("prev") or {}).get("valid") and peek_status.get("rstgen_stat") == 1):
                fails.append(f"peek of Wisp Boot's status block: {peek_status}")
        silicon_fails = silicon_failures(silicon)
        if old:
            # The models must catch each of the three silicon bugs in the pinned stage-0.
            caught = {k: bool(silicon[k]) for k in ("both_uart_wisp", "nor_in_reset_wisp")}
            caught["record_lost"] = silicon["cleans"] == 0 and not peek_record.get("valid")
            ok = bool(v) and all(caught.values()) and "error" not in result
            state = (f"the pinned stage-0 FAILS the W24d checks, as it must: (1) half duplex: both case-link pads in "
                     f"UART function by {silicon['both_uart']} ({silicon['wire']}); (2) MSPI1 held in reset: "
                     f"{silicon['nor_in_reset']} accesses by Wisp Boot (first: {silicon['nor_in_reset_first']}); (3) D-cache: "
                     f"{silicon['cleans']} cleans, the peeked record valid={peek_record.get('valid')} (all "
                     f"{'zeros' if peeked.get('wisp-record', b'x') == bytes(64) else 'not zeros'}, as on silicon). Its other "
                     f"checks: {'; '.join(fails)[:600]}" if ok else
                     f"the models did NOT catch every bug in the pinned stage-0: {caught}; {silicon}; {result.get('error')!r}")
            self.record(name, ok, state, f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
            (run.dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
            return
        fails += silicon_fails
        ok = bool(v) and not fails and "error" not in result
        state = (f"stage-0b ({len(data)} B, CRC {v.get('crc_after')}) written through the loader, vectors first and last; "
                 f"boot-watch's wisp protocol at 17.5 ms: IDENT kind {ident.get('image_kind')} {ident.get('stage')}, "
                 f"{first['queries']} queries; LFRC {clock.get('lfrc_hz')} Hz (watchdog {clock.get('wdt_period_ms')} ms); "
                 f"RESET -> HELO -> Wisp Boot's report: prev {report_reset.get('prev_stage')} "
                 f"{report_reset.get('prev_stage_ms')} ms, cause {report_reset.get('reset_cause_names')}; case reset -> "
                 f"HELO -> prev {report_case.get('prev_stage')}, cause {report_case.get('reset_cause_names')}, boot "
                 f"{report_case.get('boot')}; Wisp Boot's report asked {report_reset.get('asked_s_after_release')} s after "
                 f"the release; peek after a held case reset: record boot {peek_record.get('boots')} stage "
                 f"{peek_record.get('stage')}, status prev {(peek_status.get('prev') or {}).get('stage')}; "
                 f"PMIC: {wb_kicks} Wisp Boot kicks + stage-0b's, nothing else, no power cycle; "
                 f"{live}; strict clean; half duplex: no pads in UART function together ({silicon['wire']}); "
                 f"MSPI1 never accessed in reset; D-cache: {silicon['cleans']} cleans kept the record" if ok else f"{'; '.join(fails)} {result.get('error')!r}")
        self.record(name, ok, state, f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
        (run.dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
        (run.dir / "boot-watch.json").write_text(json.dumps(
            {"first": first, "second": second, "third": third, "summary": hook.summary(),
             "peek": {k: v.hex() for k, v in peeked.items()}, "peek_record": peek_record,
             "strict_unallowed": strict_bad}, indent=2, default=str))

    @staticmethod
    def inject(run, req: bytes) -> bytes:
        before = run.frame_count()
        run.r.cmd(f'uart2 Inject "{req.hex()}"')
        for _ in range(40):
            run.r.cmd('emulation RunFor "0.025"')
            if run.frame_count() > before:
                return bytes.fromhex(run.frame(before))
        raise RuntimeError(f"no case-UART reply to {req.hex()}")

    # --- the pinned native-0 (W23) and its way back (W24) ---
    def native_0_pinned(self) -> tuple[bytes, dict]:
        """The committed native-0 through install-wisp's own gate (native.resolve, the repository's
        pins: image, ELF, map, gates, Wisp Boot's suites, rule 3 in both implementations)."""
        files = native.NATIVE_0_FILES
        data = files["image"].read_bytes()
        pin = pins.WISP_IMAGES["native-0"]
        facts = native.resolve(data, files["elf"].read_bytes(), files["map"].read_bytes(), pin["image_sha256"][:12])
        return data, facts

    def native_nor(self) -> Path:
        """The NOR as the left temple holds it: the stock 2.4.0.24 staging file and /firmware."""
        nor_dir = self.work / "native-0-nor"   # Run() empties its own run dir
        nor_dir.mkdir(parents=True, exist_ok=True)
        nor = nor_dir / "nor-before.bin"
        lfs = Lfs(build_lfs_tool(self.cache))
        files = {"ota/s200_firmware_ota.bin": self.stock_payload, **self.firmware}
        lfs.build(nor, files, nor_dir)
        return nor

    @staticmethod
    def native_probes(run, boot_elf: Path | None = None) -> None:
        """Wisp Boot's milestones (from the committed, debug-stripped wisp_boot.elf) and its NOR window;
        the strict start-up record from Wisp Boot's entry on."""
        boot_elf = boot_elf or native.NATIVE_0_DIR / "wisp_boot.elf"
        syms = {}
        out = subprocess.run(["arm-none-eabi-nm", str(boot_elf)], capture_output=True, text=True, check=True).stdout
        for line in out.splitlines():
            p_ = line.split()
            if len(p_) == 3 and p_[2] in ("wisp_boot_main", "hw_jump"):
                syms[p_[2]] = int(p_[0], 16) & ~1
        if set(syms) != {"wisp_boot_main", "hw_jump"}:
            raise RuntimeError(f"{boot_elf}: milestones {syms}")
        # Wisp Boot's milestones count only once its services table is in MRAM (WispProbe).
        for name, addr in syms.items():
            run.r.cmd(f'probe Milestone {addr:#x} "{name}"')
        run.r.cmd("nor WatchCode 0x438000 0x448000")
        run.r.cmd('probe StrictFrom "wisp_boot_main"')

    def native_zero_recover(self):
        """W24's way back: native-0 running, a case reset, HELO claimed with the temple held,
        recover writes stock in one session, stock boots."""
        name = "native-0-recover"
        try:
            data, facts = self.native_0_pinned()
        except native.NativeRefused as error:
            self.record(name, False, f"install-wisp's gate refused the committed native-0: {error}", "")
            return
        pin = pins.WISP_IMAGES["native-0"]
        # MRAM as install-wisp leaves it over stock: native-0, then stock's bytes after it.
        start = data + self.app[len(data):]
        run = Run(self.work, name, self.patched, start, nor=self.native_nor())
        # native-0 (pinned, W23) keeps both case-link pads in UART function (its Zephyr pinctrl) and its
        # Wisp Boot writes MSPICFG = 0: the half-duplex wire would only corrupt its queries, so its own
        # checks run on the full-duplex model and the W24d findings are listed with its failures.
        run.r.cmd("uart2 HalfDuplex false")
        log = []
        t0 = time.time()
        banner = "*** Wisp native "
        try:
            self.native_probes(run)
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")
            pmic_realism(run)
            uart = run.uart
            # The patched loader's HELO goes unanswered, Wisp Boot runs the app, the app runs.
            t = run.run_until(lambda: uart().count(banner) >= 1 and
                              uart().count("wisp: heartbeat", uart().rfind(banner)) >= 3, 40, step=0.1)
            native_up = uart().count(banner) == 1 and uart().count("wisp: heartbeat") >= 3
            helo_before = sum(f.startswith(HELO_PREFIX) for f in run.frames())

            def host(link):
                with Session(link, log=log.append, temple_feed=True) as s:
                    s.require_patched_bootloader(self.patched)
                    want = __import__("zlib").crc32(self.patched)
                    out = {"crc": [s.bootloader_crc(), s.bootloader_crc()], "flag": s.flag()}
                    if out["crc"] != [want, want] or out["flag"] != 0xFFFFFFFF:
                        raise SessionError(f"loader-hello gate failed: {out}")
                    out["native_crc"] = s.checksum(pins.APP_BASE, pin["image_bytes"])
                    if out["native_crc"] != pin["crc32"]:
                        raise SessionError(f"app region is not native-0 before recover: {out['native_crc']:08x}")
                    t1 = time.time()
                    out.update(s.write_app(self.app))
                    out["host_s"] = round(time.time() - t1, 1)
                    out["stock_crc"] = s.checksum(pins.APP_BASE, pins.STOCK_MAIN_BYTES)
                    out["feeds"] = s.feeds
                    return out
            thread, result = run.attach(host)
            # The case's reset of the running temple (on hardware: the pogo reset waveform at the
            # relay's start; here the machine reset, which also clears SRAM, as rstgen does).
            run.r.cmd('rstgen Request "case-reset"')
            steps = 0.0
            while thread.is_alive() and steps < 900:
                run.step(1)
                steps += 1
            t += steps
            host_stuck = thread.is_alive()
            resets = run.r.cmd("rstgen ResetLog")
            t += run.run_until(run.stock_running, 60)
            helo_after = sum(f.startswith(HELO_PREFIX) for f in run.frames())
            live_fails = []
            live = liveness(run, live_fails)
            live_fails += silicon_failures(silicon_findings(run))
            strict_check(run, live_fails)
            pm = self.pmic(run)
            mram = run.mram()
            rep = run.r.cmd("probe Report").splitlines()
            boots = sum(l.startswith("wisp_boot_main ") for l in rep)
        finally:
            run.close()
        v = result.get("value") or {}
        fails = []
        if host_stuck:
            fails.append("the recover session did not end within 900 s virtual")
        if not native_up:
            fails.append("native-0 did not come up before the case reset")
        if boots != 1:
            fails.append(f"{boots} Wisp Boot runs (want 1: native-0 once, then stock)")
        if "case-reset" not in resets:
            fails.append(f"no case reset in {resets!r}")
        if helo_after != helo_before + 1:
            fails.append(f"HELO {helo_before} -> {helo_after}")
        if not v:
            fails.append(f"recover session: {result.get('error')!r}")
        else:
            if v.get("native_crc") != pin["crc32"]:
                fails.append("app region was not native-0")
            if v.get("stock_crc") != pins.STOCK_MAIN_CRC32:
                fails.append(f"stock CRC {v.get('stock_crc')}")
        if mram[0x38000:0x38000 + len(self.app)] != self.app:
            fails.append("stock not in MRAM")
        if mram[0x10000:0x10000 + len(self.patched)] != self.patched:
            fails.append("bootloader region changed")
        if pm["expiries"]:
            fails.append(f"PMIC watchdog expired {pm['expiries']}x")
        if not run.stock_running():
            fails.append("stock not running")
        fails += live_fails
        ok = not fails
        state = (f"native-0 ran ({uart().count('wisp: heartbeat')} heartbeats); case reset -> HELO claimed (temple held); "
                 f"loader-hello: CRC twice, flag clear; region CRC {pin['crc32']:08x} = native-0; recover wrote stock "
                 f"in one session ({v.get('bytes')} B, final CRC {v.get('crc_after')}, {v.get('host_s')} s host, "
                 f"{v.get('feeds')} temple feeds, no PMIC power cycle); CRC over {pins.STOCK_MAIN_BYTES} B "
                 f"{pins.STOCK_MAIN_CRC32:08x} = stock pin; bootloader unchanged; stock app running" if ok
                 else "; ".join(fails))
        self.record(name, ok, state, f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
        (run.dir / "host.log").write_text("\n".join(map(str, log)) + "\n")

    # --- native-1 (rung4.md W25): the MVP behind the patched loader ---
    @staticmethod
    def native_1_files() -> tuple[bytes, dict]:
        """The committed native-1 (data/native-1/) through install-wisp's own gate. native-1 is NOT
        pinned in the repository (its review and pin are a separate step): this process pins it,
        and its Wisp Boot slot, in memory only, as the install-wisp case does with its synthetic
        image, so the rest of the gate (ELF and map against the image, the gates the manifest
        records, rule 3 in both implementations) runs on the committed files."""
        data = (NATIVE_1_DIR / "native-1.bin").read_bytes()
        elf = (NATIVE_1_DIR / "zephyr.elf").read_bytes()
        map_text = (NATIVE_1_DIR / "zephyr.map").read_bytes()
        slot = image.sha(data[:pins.WISP_BOOT_SLOT_BYTES])
        pins.R4_1_APPROVED = True
        pins.WISP_IMAGES = {**pins.WISP_IMAGES, "native-1 (w18-test only, not pinned)": {
            "image_sha256": image.sha(data), "image_bytes": len(data), "elf_sha256": image.sha(elf),
            "map_sha256": image.sha(map_text), "gates": pins.WISP_GATES, "wisp_boot_slot_sha256": slot}}
        pins.WISP_BOOT_PASSED = {**pins.WISP_BOOT_PASSED, slot: {
            "build": "observe-only, native-1", "suites": {s_: "w18-test only (rung 3: wisp-fw:boot-test)"
                                                           for s_ in pins.WISP_BOOT_SUITES}}}
        return data, native.resolve(data, elf, map_text, image.sha(data)[:12])

    @staticmethod
    def diag_record(run) -> dict:
        """Wisp Boot's diagnostics record (D1) as it stands in RAM, read from the bus."""
        words = [int(run.r.cmd(f"sysbus ReadDoubleWord {DIAG_ADDR + 4 * i:#x}").split()[0], 0) for i in range(16)]
        return case_uart.decode_diag_record(struct.pack("<16I", *words), check=False)

    @staticmethod
    def panel_frame(run) -> bytes:
        path = run.dir / "panel-frame.bin"
        run.r.cmd(f"panel SaveFrame @{path}")
        return path.read_bytes()

    @staticmethod
    def boot_screen_errors(frame: bytes) -> list[str]:
        """native-1's boot screen (src/display/boot_screen.c) in the panel's frame (320 bytes a row,
        high nibble = left pixel): the 4-pixel frame at the edge, "Wisp" at y 180..259, the 16 grey
        bands at y 380..439 (inside the frame's left and right edges)."""
        def px(x, y):
            b = frame[y * 320 + x // 2]
            return b >> 4 if x % 2 == 0 else b & 0xF
        errors = []
        if len(frame) != 320 * 480:
            return [f"frame of {len(frame)} bytes"]
        edge = [(x, y) for y in (0, 3, 476, 479) for x in range(0, 640, 7)] + \
               [(x, y) for x in (0, 3, 636, 639) for y in range(0, 480, 7)]
        if any(px(x, y) != 15 for x, y in edge):
            errors.append("the edge frame is not value 15")
        bands = [px(20 + 40 * b, 410) for b in range(16)]
        if bands[1:15] != list(range(1, 15)):
            errors.append(f"grey bands read {bands}")
        sys.path.insert(0, str(APP_DIR / "scripts"))
        import gen_boot_font as font  # the generator of the font the firmware draws
        want = sum(row.count("X") for ch in "Wisp" for row in font.GLYPHS[ch]) * font.SCALE ** 2
        lit = sum(px(x, y) == 15 for y in range(180, 260) for x in range(4, 636))
        if lit != want:
            errors.append(f"text area: {lit} pixels of 15, the font draws {want}")
        if any(px(x, y) for y in range(100, 170) for x in range(4, 636)):
            errors.append("pixels set between the edge and the text")
        return errors

    def native_one(self):
        """install-wisp of native-1 over a running stock app, its boots, the case UART under the
        half-duplex model, the boot screen, a case-UART RESET with Wisp Boot's report."""
        name = "native-1"
        try:
            data, facts = self.native_1_files()
        except (OSError, native.NativeRefused) as error:
            self.record(name, False, f"native-1 files or install-wisp's gate: {error}", "")
            return
        app = AppImage("native-1", data, facts["image_sha256"], int(facts["end"], 16), check=native_rule3)
        run = Run(self.work, name, self.patched, self.app, nor=self.native_nor(), panel=True)
        log, fails, q, t0 = [], [], {}, time.time()
        hook = recovery_case_uart.WispStatus()
        try:
            self.native_probes(run, NATIVE_1_DIR / "wisp_boot.elf")
            run.r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")
            pmic_realism(run)
            # The nPM1300 keeps its registers across Apollo resets, starting with what stock left (W21).
            run.r.cmd("pmicwdt KeepRegisters true")
            for reg, v in json.loads(BASELINE.read_text())["registers"].items():
                run.r.cmd(f"pmicwdt SetRegister {int(reg, 16):#x} {int(v['value'], 16):#x}")
            run.r.cmd("rstgen RetainRange 0x20370000 0x10000")
            # The D-cache model: across a warm reset only what Wisp code cleaned survives (every
            # wisp_dcache_clean in Wisp Boot's and the app's ELF).
            run.r.cmd("rstgen CacheModel true")
            for elf in (NATIVE_1_DIR / "wisp_boot.elf", NATIVE_1_DIR / "zephyr.elf"):
                for addr in nm_all(elf, "wisp_dcache_clean"):
                    run.r.cmd(f"rstgen CleanHook {addr:#x}")

            def host(link):
                with Session(link, log=log.append, temple_feed=True) as s:
                    s.require_patched_bootloader(self.patched)
                    return self.wisp_session(s, app)
            thread, result = run.attach(host)
            t = 0.0
            while thread.is_alive() and t < 900:
                run.step(1)
                t += 1
            writes = self.write_log(run)
            # 1. The first boot after CONT: no console; the record's breadcrumbs say how far it got.
            t += run.run_until(lambda: self.diag_record(run).get("stage") == "app-idle", 60, step=0.25)
            rec1 = self.diag_record(run)
            ask = lambda r: self.inject(run, r)  # noqa: E731
            q["version"] = case_uart.decode_version(ask(case_uart.STOCK_VERSION_QUERY))
            code_, ident = case_uart.decode_reply(ask(case_uart.ident_request()), case_uart.OP_IDENT)
            q["ident"] = case_uart.decode_ident(ident) if code_ == 0 else {"code": code_}
            raw = case_uart.read_block(ask, case_uart.BLOCK_STATUS)
            q["status"] = case_uart.decode_status(raw) if raw else {}
            block = case_uart.read_block(ask, case_uart.BLOCK_BOOT) or b""
            q["boot"] = case_uart.decode_boot_status(block) if len(block) in case_uart.BOOT_STATUS_SIZES.values() else {}
            code_, rep = case_uart.decode_reply(ask(case_uart.bootrep_request()), case_uart.OP_BOOTREP)
            q["boot_report_app"] = case_uart.decode_boot_report(rep) if code_ == 0 else {"code": code_}
            raw = case_uart.read_block(ask, case_uart.BLOCK_DIAG)
            q["record"] = case_uart.decode_diag_record(raw, check=False) if raw else {}
            # boot-watch's own protocol (apps/wisp-recovery wisp_w18/case_uart.py) against the app.
            answers = []
            for i in range(200):
                decoded = hook.decode(ask(hook.request(i)))
                if decoded is not None:
                    answers.append(decoded)
                if hook.complete(answers):
                    break
            q["boot_watch"] = {"complete": hook.complete(answers), "queries": i + 1}
            # 2. The boot screen: drawn at boot, the panel off again CONFIG_WISP_BOOT_SCREEN_S later.
            # JBD4010: pixels and commits (the model's Frames counts the A6N-G's whole frames).
            frames = int(run.r.cmd("panel Commits").split()[0], 0)
            pixels = int(run.r.cmd("panel PixelBytes").split()[0], 0)
            frame = self.panel_frame(run)
            screen = self.boot_screen_errors(frame)
            for _ in range(62):
                run.step(1)
            t += 62
            raw = case_uart.read_block(ask, case_uart.BLOCK_STATUS)
            q["status_later"] = case_uart.decode_status(raw) if raw else {}
            # 3. RESET over the case UART: the reply, the loader's HELO (nobody holds it), Wisp Boot,
            # the second boot to app-idle; then the boot report from the app, built from Wisp Boot's
            # block: the previous boot's last breadcrumb, through the reset and the D-cache model.
            # Short steps: a long RunFor through the patched loader's window can stall Renode.
            n_frames = run.frame_count()
            code, _ = recovery_case_uart.decode_reply(ask(recovery_case_uart.reset_request()),
                                                      recovery_case_uart.OP_RESET)
            t_reset = 0.0
            while t_reset < 30 and self.diag_record(run).get("boots", 0) < rec1.get("boots", 0) + 1:
                run.step(0.1)
                t_reset += 0.1
            while t_reset < 40 and self.diag_record(run).get("stage") != "app-idle":
                run.step(0.1)
                t_reset += 0.1
            t += t_reset
            helo_after = sum(run.frame(i).startswith(HELO_PREFIX) for i in range(n_frames, run.frame_count()))
            code_, rep = case_uart.decode_reply(ask(case_uart.bootrep_request()), case_uart.OP_BOOTREP)
            report_reset = case_uart.decode_boot_report(rep) if code_ == 0 else {"code": code_}
            second = {"helo": helo_after, "seconds": round(t_reset, 1)}
            rec2 = self.diag_record(run)
            silicon = silicon_findings(run)
            watched = run.r.cmd("nor WatchedLog").split("\n")
            watched_writes = int(run.r.cmd("nor WatchedWrites").split()[0], 0)
            live = liveness(run, fails)
            strict_bad = strict_check(run, fails)
            pc_log = run.r.cmd("pmicwdt PmicPcLog")
            pm = self.pmic(run)
            mram = run.mram()
        except Exception as error:  # noqa: BLE001 - a case failure, not a harness crash
            (run.dir / "case-uart.json").write_text(json.dumps({"query": q}, indent=2, default=str))
            self.record(name, False, f"stopped: {error!r}; so far {list(q)}", f"{time.time() - t0:.0f} s wall")
            return
        finally:
            run.close()
        v = result.get("value") or {}
        if mram[0x38000:0x38000 + len(data)] != data:
            fails.append("native-1 not in MRAM")
        if mram[0x10000:0x10000 + len(self.patched)] != self.patched:
            fails.append("bootloader region changed")
        if not (len(writes) > 2 and writes[0] == (pins.APP_BASE, 4) and writes[-1] == (pins.APP_BASE, 4)
                and all(pins.APP_BASE <= d and d + 4 * n <= app.end for d, n in writes)):
            fails.append(f"install write order/bound: first {writes[:2]} last {writes[-1:]}")
        if rec1.get("stage") != "app-idle" or rec2.get("stage") != "app-idle":
            fails.append(f"breadcrumbs: first boot {rec1.get('stage')}, after RESET {rec2.get('stage')}")
        ident_ = q.get("ident") or {}
        st = q.get("status") or {}
        if ident_.get("image_kind") != 1 or not q["version"].get("wisp"):
            fails.append(f"IDENT {ident_} version {q['version']}")
        if not {"pmic-wdt", "boot-services", "boot-status", "boot-observe"} <= set(st.get("flags", [])):
            fails.append(f"status {st}")
        boot = q.get("boot") or {}
        if not boot or boot.get("nor_result") != 0 or boot.get("staging_id") != struct.unpack_from("<I", self.stock_payload, 4)[0] \
                or len(boot.get("inventory", [])) != len(self.firmware) or boot.get("action") != "run-app":
            fails.append(f"Wisp Boot's block (the NOR read path): {boot}")
        if (q.get("boot_report_app") or {}).get("source") != "app":
            fails.append(f"BOOTREP from the app: {q.get('boot_report_app')}")
        if (q.get("record") or {}).get("stage") != "app-idle":
            fails.append(f"READ block 4 (the record): {q.get('record')}")
        if not q["boot_watch"]["complete"]:
            fails.append(f"boot-watch's wisp protocol incomplete: {hook.summary(answers)}")
        if st.get("display") != "on" or (q.get("status_later") or {}).get("display") != "off":
            fails.append(f"display state {st.get('display')} ({st.get('display_err')}), later "
                         f"{(q.get('status_later') or {}).get('display')}")
        if frames < 1 or pixels < 320 * 480 or screen:
            fails.append(f"boot screen: {frames} commit(s), {pixels} pixel bytes; {screen}")
        if code != 0 or second["helo"] != 1 or report_reset.get("prev_stage") != "app-reset-request" \
                or report_reset.get("boot") != (rec1.get("boots", 0) + 1) & 0xFF:
            fails.append(f"RESET: reply {code}, {second['helo']} HELO, report {report_reset}")
        fails += silicon_failures(silicon)
        if not re.match(r"tx_lost=0 rx_corrupted=0 ", silicon["wire"]):
            fails.append(f"half duplex: {silicon['wire']}")
        if not silicon["cleans"]:
            fails.append("no D-cache clean by Wisp code (the record would not survive a reset)")
        half = silicon["wire"]
        nor_ops = {l.split()[0] for l in watched if l.strip()}
        if watched_writes or not nor_ops <= {"9f", "05", "13"} or "13" not in nor_ops:
            fails.append(f"Wisp Boot NOR commands {sorted(nor_ops)}")
        wb_kicks, wb_other = strict.wisp_boot_pmic(pc_log)
        if wb_other:
            fails.append(f"Wisp Boot wrote the PMIC other than the kick: {wb_other}")
        wb_at = {(e["ms"], e["bytes"]) for e in strict.pmic_writes(pc_log) if e["wisp_boot"]}
        app_writes = [l.split(" ms write ")[1].strip() for l in pm["log"].splitlines() if " ms write " in l
                      and (int(l.split(" ms write ")[0]), l.split(" ms write ")[1].strip()) not in wb_at]
        data_writes = [w for w in app_writes if len(w.split()) > 2]
        if [w for w in data_writes if w in PMIC_ARM][:4] != PMIC_ARM:
            fails.append("the app did not arm the PMIC watchdog with stock's writes")
        bad = sorted({w for w in data_writes if w not in {"07 04 01", "05 00 01", *PMIC_ARM, *RAILS_ON, *RAILS_OFF}})
        if bad:
            fails.append(f"PMIC writes outside the allowlist: {bad}")
        rails = [w for w in data_writes if w in RAILS_ON + RAILS_OFF]
        if rails[:4] != RAILS_ON + RAILS_OFF:
            fails.append(f"panel rails switched {rails} (want on {RAILS_ON}, off {RAILS_OFF})")
        if pm["expiries"]:
            fails.append(f"PMIC watchdog expired {pm['expiries']}x")
        diffs = pmic_baseline.check([bytes.fromhex(w.replace(" ", "")) for w in data_writes])
        if diffs:
            fails.append(f"PMIC writes differ from W21's snapshot: {diffs[:4]}")
        ok = bool(v) and not fails and "error" not in result
        state = (f"native-1 ({len(data)} B, CRC {v.get('crc_after')}) written through the loader over stock, vectors "
                 f"first and last; CONT -> observe-only Wisp Boot -> app, breadcrumbs to app-idle (no console); case "
                 f"UART half duplex ({half}): IDENT kind {ident_.get('image_kind')} stage {ident_.get('stage')}, both "
                 f"blocks, BOOTREP and the record from the app, boot-watch's protocol complete; Wisp Boot's NOR read "
                 f"(staging {boot.get('staging_id', 0):08x}, {len(boot.get('inventory', []))} firmware files); boot "
                 f"screen drawn ({pixels} pixel bytes, {frames} commits, checked pixel by pixel), rails {RAILS_ON} after the gate, off {RAILS_OFF} after 60 s; PMIC "
                 f"armed with stock's writes, {pm['kicks']} kicks, Wisp Boot {wb_kicks}, no power cycle; RESET -> HELO "
                 f"-> second boot; its report (from the {report_reset.get('source')}) prev {report_reset.get('prev_stage')} cause "
                 f"{report_reset.get('reset_cause_names')}, boot {report_reset.get('boot')}, app-idle again; {live}; strict clean"
                 if ok else f"{'; '.join(fails)} {result.get('error')!r}")
        self.record(name, ok, state, f"{t:.0f} s virtual, {time.time() - t0:.0f} s wall")
        (run.dir / "host.log").write_text("\n".join(map(str, log)) + "\n")
        (run.dir / "case-uart.json").write_text(json.dumps(
            {"query": q, "record_first": rec1, "record_after_reset": rec2, "reset_watch": second,
             "boot_watch": hook.summary(answers), "strict_unallowed": strict_bad, "silicon": silicon},
            indent=2, default=str))

    def legacy_half_duplex(self, name: str, data: bytes, boot_elf: Path):
        """The pinned native-0 in MRAM as install-wisp leaves it over stock, behind the stock 2.4.0.24
        bootloader, under the W24d models (half-duplex wire, MSPICFG's resets): it must fail as it
        did on silicon (W24): its Zephyr pinctrl keeps both case-link pads in UART function, so the
        case's bytes arrive corrupted and nothing is answered, and its Wisp Boot holds MSPI1 in
        reset. A pass here means: it fails, for those reasons. (stage-0's counterpart is
        `stage-0-models`.)"""
        image_ = data + self.app[len(data):]
        # The half-duplex failure does not depend on the bootloader, and the patched loader's boot
        # window runs about 30x slower in Renode.
        run = Run(self.work, name, self.bl24, image_, nor=self.native_nor())
        fails, t0 = [], time.time()
        try:
            self.native_probes(run, boot_elf)
            run.run_until(lambda: False, 12, step=0.1)
            answered = 0
            for req in (case_uart.ident_request(), case_uart.bootrep_request(), case_uart.ident_request()):
                try:
                    self.inject(run, req)
                    answered += 1
                except RuntimeError:
                    pass
            silicon = silicon_findings(run)
            boots = sum(l.startswith("wisp_boot_main ") for l in run.r.cmd("probe Report").splitlines())
        finally:
            run.close()
        if answered:
            fails.append(f"{answered} case-UART request(s) answered")
        if "app" not in silicon["both_uart_wisp"]:
            fails.append(f"the app never left both pads in UART function ({silicon['both_uart']})")
        if not silicon["nor_in_reset_wisp"]:
            fails.append("Wisp Boot never touched MSPI1 while held in reset")
        if not boots:
            fails.append("Wisp Boot never ran")
        ok = not fails
        self.record(name, ok, (f"fails as on silicon (W24): Wisp Boot ran {boots}x; 0 of 3 case-UART requests "
                               f"answered ({silicon['wire']}); both pads in UART function by {silicon['both_uart_wisp']}; "
                               f"MSPI1 accessed {silicon['nor_in_reset']}x while held in reset")
                    if ok else "; ".join(fails), f"{time.time() - t0:.0f} s wall")

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
                                                   "recover-fed", "rung4-reads", "install-wisp", "native-0",
                                                   "native-0-legacy", "native-0-recover", "stage-0b", "stage-0-models",
                                                   "native-1", "install"])
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
    if "native-0" in only:
        h.native_zero()
    if "native-0-legacy" in only:
        h.legacy_half_duplex("native-0-legacy", native.NATIVE_0_FILES["image"].read_bytes(),
                             native.NATIVE_0_DIR / "wisp_boot.elf")
    if "native-0-recover" in only:
        h.native_zero_recover()
    if "stage-0b" in only or "stage-0" in only:
        h.stage_zero("stage-0b")
    if "stage-0-models" in only or "stage-0" in only:
        h.stage_zero("stage-0")
    if "native-1" in only:
        h.native_one()
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
