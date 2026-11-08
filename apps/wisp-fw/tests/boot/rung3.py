#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Rung 3 fault-injection harness (wisp-fw:boot-test). Emulation only.

Runs the REAL Even bootloader (from the git-ignored .wisp-cache, never committed) in Renode in
front of Wisp Boot, with a littlefs NOR image, and injects boot faults into the Wisp app and power
cuts along the rescue path. Every case asserts an end state:

  STOCK  the stock main app runs from 0x438000: MRAM [0x438000, end) equals the stock image, the
         bootloader's last hand-off went to it and the stock app's own UART line appeared after
         that hand-off ("EM9305 reset status"); the bootloader and NV regions are unchanged except
         the flag record; Wisp Boot's only MRAM write was the documented flag record.
  WISP   (control case) the Wisp app keeps running and no rescue happens.
  SAFE   (rescue impossible) Wisp Boot never wrote the flag, the staging file and MRAM still hold
         the Wisp image, and the Wisp app keeps getting control every boot.
  NATIVE (the real Wisp app, rung4.md G6) the app behind Wisp Boot boots, feeds the locked 8 s
         watchdog (no bite), arms the nPM1300 watchdog with stock's writes and kicks it every
         second, and writes nothing else to the PMIC.
  OBSERVE (the observe-only Wisp Boot of native-0, its own suite) the app behind it gets control
         on every boot whatever Wisp Boot finds; Wisp Boot issues no NOR command but RDID, RDSR
         and reads (the NOR model's code window) and no MRAM write happens at all; its status
         block reports what it found (NOR id, staging, rescue.bin, the /firmware inventory with
         sizes and CRCs, and the decision the fallback build would take). With the real app the
         case-UART status (docs/wisp/case-uart.md) is queried too. With stage-0 (the bare-metal app of
         rung4.md W24b) the whole diagnostics path is exercised: its clock block, the boot report from
         the app, a case-UART RESET, and the boot report from Wisp Boot's window on the next boot.

Every case also checks, since W24 (docs/wisp/rung4.md, "W24 result and analysis"): Wisp Boot's only
PMIC write is the watchdog kick 07 04 01 (PC-attributed, WispPmicWdt PmicPcLog), it kicks once per
boot, and it makes no write to a power, clock or trim register that no model acts on (the strict
record, tests/boot/strict.py). The real app's such writes are listed in the table, not failed on
here (wisp-fw:w18-test fails native-0 on them); stage-0 must make none. The watchdog's LFRC runs at
900 Hz (WispWdt), so Wisp Boot's watchdog is about 9.1 s here, as on silicon.

Two suites (--suite): `fallback` (the Wisp Boot that rescues: the 26 rung-3 cases plus the real app
behind it) and `observe` (native-0's Wisp Boot). Two bootloaders (--bootloader): `stock` (the
stock bundle's own) and `patched` (drdaeman's 87e2d4e0..., what Jan's temples run since W18:
safety.md rule 12 asks for both). The platform always has the case link on UART2 (WispCaseLink,
nobody attached unless a case injects a query) and the nPM1300 watchdog on IOM7 (WispPmicWdt).

Usage: rung3.py --cache .wisp-cache --boot-build .wisp-cache/build/wisp-boot [--suite fallback]
       [--bootloader stock] [--only NAME...] [--list] [--keep]. Writes report.md (the table) into
       <cache>/rung3/<bootloader label>-<suite>/.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import case_uart  # noqa: E402
import strict  # noqa: E402
sys.path.insert(0, str(HERE.parents[1] / "scripts"))
import pmic_baseline  # noqa: E402
APP_DIR = HERE.parents[1]
REPO = APP_DIR.parents[1]
STOCK_VERSION = "2.4.0.24"
MAIN_BASE = 0x438000
FLAG = 0x7FE000
FLAG_SET = [0x55555555, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF]
FLAG_CLEAR = [0xFFFFFFFF] * 4
WISP_BOOT_END = 0x448000
STOCK_MARK = "EM9305 reset status"          # first stock-app (not bootloader) line on UART1
JUMP_RE = re.compile(r"(just jump to app|APP jumpaddr app)\(0x438000\)")
APP_BANNER = "*** Wisp native "             # the real app's first line
APP_BEAT = "wisp: heartbeat "
APP_CEILING = 0x7F8000
SERVICES = 0x438200
# The nPM1300 writes the real app may make (wire bytes: register address high, low, data): stock's
# watchdog arming and kick (power.c, recovery.md) and the ADC task of one VBAT conversion. A 2-byte
# write is the register-address phase of a read.
PMIC_ALLOWED = {"07 04 01", "07 05 0a", "07 08 00 3c 00", "07 03 01", "07 00 01", "05 00 01"}
PMIC_ARM = ["07 05 0a", "07 08 00 3c 00", "07 03 01", "07 00 01"]
PMIC_PERIOD_S = 30.72


# ---- inputs ---------------------------------------------------------------------------------

def evenota_components(bundle: bytes) -> dict[int, bytes]:
    """type -> payload, from an EVENOTA bundle (layout: docs/wisp/hardware.md)."""
    assert bundle[:8] == b"EVENOTA\0", "not an EVENOTA bundle"
    n = struct.unpack_from("<I", bundle, 8)[0]
    out = {}
    for i in range(n):
        _id, off, size, _crc = struct.unpack_from("<IIII", bundle, 0x40 + 16 * i)
        hdr = bundle[off:off + 128]
        assert hdr[0x14:0x18] == b"EVEN"
        out[struct.unpack_from("<I", hdr, 0x24)[0]] = bundle[off + 128:off + size]
    return out


def stock_inputs(cache: Path, version: str) -> tuple[bytes, bytes]:
    bundle_path = cache / "stock" / f"g2-{version}.bin"
    meta_path = cache / "stock" / f"g2-{version}.json"
    if not bundle_path.exists():
        sys.exit(f"rung3: {bundle_path} missing; run: node packages/wisp-ota/dist/cli.js fetch {version}")
    data = bundle_path.read_bytes()
    want = json.loads(meta_path.read_text()).get("sha256")
    got = hashlib.sha256(data).hexdigest()
    if want != got:
        sys.exit(f"rung3: {bundle_path} SHA-256 {got} != pinned {want}")
    comps = evenota_components(data)
    return comps[1], comps[0]  # bootloader (raw, runs at 0x410000), main payload (with preamble)


def wisp_payload(native: Path, work: Path) -> bytes:
    """Pack the native image with wisp-ota (its guards run on it) and return the main payload,
    i.e. exactly what the stock OTA path writes into ota/s200_firmware_ota.bin."""
    cli = REPO / "packages/wisp-ota/dist/cli.js"
    out = work / (native.stem + ".evenota")
    subprocess.run(["node", str(cli), "pack-main", str(native), "--version", "0.3.0.1", "-o", str(out)],
                   check=True, stdout=subprocess.DEVNULL)
    return evenota_components(out.read_bytes())[0]


def zlib_crc(b: bytes) -> int:
    import zlib
    return zlib.crc32(b) & 0xFFFFFFFF


# ---- NOR images -------------------------------------------------------------------------------

class Lfs:
    def __init__(self, tool: Path):
        self.tool = tool

    def run(self, *a, check=True):
        return subprocess.run([str(self.tool), *map(str, a)], check=check, capture_output=True)

    def build(self, path: Path, files: dict[str, bytes], work: Path):
        self.run("format", path)
        for name, data in files.items():
            tmp = work / "put.tmp"
            tmp.write_bytes(data)
            self.run("put", path, name, tmp)

    def get(self, img: Path, name: str, work: Path) -> bytes | None:
        out = work / "get.tmp"
        r = self.run("get", img, name, out, check=False)
        return out.read_bytes() if r.returncode == 0 else None


def build_lfs_tool(cache: Path) -> Path:
    lfs = cache / "west/modules/fs/littlefs"
    out = cache / "rung3/wisp_lfs"
    out.parent.mkdir(parents=True, exist_ok=True)
    # Built under a private name and renamed: several harnesses may start at once.
    tmp = out.with_name(f"wisp_lfs.{os.getpid()}")
    subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-D__ASSERT_ON=1", f"-I{lfs}",
                    f"-I{APP_DIR}/src/boot", str(HERE / "tools/wisp_lfs.c"), str(lfs / "lfs.c"),
                    str(lfs / "lfs_util.c"), "-o", str(tmp)], check=True)
    os.replace(tmp, out)
    return out


# ---- Renode -----------------------------------------------------------------------------------

class Renode:
    PROMPT = re.compile(rb"\((monitor|g2)\) $")

    def __init__(self, run_dir: Path, port: int):
        env = dict(os.environ, G2_CAPTURE_OUT=str(run_dir))
        self.log = (run_dir / "renode.log").open("wb")
        self.transcript = (run_dir / "monitor.log").open("w")
        self.proc = subprocess.Popen(["renode", "--disable-gui", "--plain", "--port", str(port)],
                                     stdout=self.log, stderr=subprocess.STDOUT, env=env, cwd=run_dir)
        for _ in range(600):
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=1200)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError("renode monitor did not come up")
        self.read()

    def read(self) -> str:
        buf = b""
        while not self.PROMPT.search(buf):
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("renode monitor closed")
            buf += chunk
        return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", buf.decode(errors="replace"))

    def cmd(self, line: str) -> str:
        self.transcript.write(f">>> {line}\n")
        self.transcript.flush()
        self.sock.sendall(line.encode() + b"\n")
        out = self.read()
        while line not in out:      # a stray prompt from an earlier command: read on
            out = self.read()
        self.transcript.write(out[-2000:] + "\n")
        self.transcript.flush()
        # drop the echoed command and the prompt
        lines = [l for l in out.replace("\r", "").split("\n")]
        return "\n".join(l for l in lines[1:-1]).strip()

    def close(self):
        try:
            self.sock.sendall(b"quit\n")
        except OSError:
            pass
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()


def free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def platform(run_dir: Path, patched: bool) -> Path:
    """The rung-3 machine with the case link on UART2 and the PMIC watchdog on IOM7 (as
    tests/boot/w18.py builds it). Returns the .resc to include."""
    repl = (APP_DIR / "renode/wisp_g2_boot.repl").read_text()
    repl, n = re.subn(r"uart2: Wisp\.WispUartIdle @ sysbus 0x4003B000",
                      "uart2: Wisp.WispCaseLink @ sysbus 0x4003B000", repl)
    assert n == 1, "rung-3 platform changed: uart2 line not found"
    repl, n = re.subn(r"iom: G2emu\.G2Iom @ sysbus 0x40050000\n    size: 0x8000",
                      "iom: Wisp.WispIomTypes @ sysbus 0x40050000\n    size: 0x7000\n\n"
                      "pmicwdt: Wisp.WispPmicWdt @ sysbus 0x40057000", repl)
    assert n == 1, "rung-3 platform changed: iom line not found"
    (run_dir / "rung3.repl").write_text(repl)
    resc = (APP_DIR / "renode/boot.resc").read_text().replace("$ORIGIN/", f"@{APP_DIR}/renode/")
    resc = resc.replace(f"include @{APP_DIR}/renode/models/WispUartIdle.cs",
                        f"include @{APP_DIR}/renode/models/WispUartIdle.cs\n"
                        f"include @{APP_DIR}/renode/models/WispCaseLink.cs\n"
                        f"include @{APP_DIR}/renode/models/WispIomTypes.cs\n"
                        f"include @{APP_DIR}/renode/models/WispPmicWdt.cs")
    resc = re.sub(r"machine LoadPlatformDescription .*",
                  f"machine LoadPlatformDescription @{run_dir / 'rung3.repl'}", resc)
    out = run_dir / "rung3.resc"
    out.write_text(resc)
    return out


def nm_symbols(elf: Path) -> dict[str, int]:
    out = subprocess.run(["arm-none-eabi-nm", str(elf)], check=True, capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3 and p[1] in "tT":
            syms[p[2]] = int(p[0], 16) & ~1
    return syms


# ---- cases ------------------------------------------------------------------------------------

FIRMWARE_FILES = {3: "touch.bin", 4: "codec.bin", 5: "ble_em9305.bin", 6: "box.bin"}


@dataclass
class Case:
    name: str
    title: str
    app: str                          # good/hang/crash_reset/crash_after/no_feed/erased, or real (the Wisp app)
    expect: str                       # STOCK / WISP / SAFE / NATIVE / OBSERVE
    rescue: str = "ok"                # ok / corrupt / missing
    flag_initially_set: bool = True   # the stock OTA path leaves 0x55555555 behind (hardware.md)
    record: str = "none"              # none / corrupt / unconfirmed (attempts = 3 for this install)
    cut_nor_op: int | None = None     # absolute NOR op count (from the reference run)
    cut_milestone: tuple[str, int] | None = None
    cut_rom_write: int | None = None  # boot-ROM write index
    cut_after_flag: bool = False
    extra_cuts: int = 0               # WISP control: extra power cycles after the confirm
    budget: float = 400.0             # virtual seconds
    staging: str = "wisp"             # wisp: the image's own payload (stock OTA, route a); stock: the
                                      # stock main, as install-wisp leaves it (route b, rung4.md §3)
    firmware: bool = False            # /firmware/* from the stock bundle on the NOR
    cuts_running: int = 0             # power cuts, each once the real app is up (2 heartbeats)
    min_boots: int = 1                # OBSERVE: Wisp Boot runs before the run ends
    rdid: str | None = None           # RDID as Wisp Boot sees it (NOR model code window)
    query: bool = False               # case-UART queries once the real app is up (last boot)
    retain: bool = False              # Wisp Boot's diagnostics record survives warm resets (rstgen RetainRange)
    status: dict = field(default_factory=dict)  # expected status-block fields (OBSERVE, NATIVE)
    result: dict = field(default_factory=dict)


def base_cases() -> list[Case]:
    return [
        Case("good-confirms", "control: app confirms, then 3 power cycles", "good", "WISP", extra_cuts=3,
             budget=60),
        Case("app-hangs", "app hangs (no confirm, no feed)", "hang", "STOCK"),
        Case("app-hangs-flag-clear", "app hangs, flag already cleared before", "hang", "STOCK",
             flag_initially_set=False),
        Case("crash-reset-handler", "app faults in its reset handler", "crash_reset", "STOCK"),
        Case("crash-after-300ms", "app crashes 300 ms after start", "crash_after", "STOCK"),
        Case("wdt-never-fed", "app runs but never feeds the watchdog", "no_feed", "STOCK"),
        Case("app-slot-erased", "no app behind Wisp Boot (slot erased)", "erased", "STOCK"),
        Case("record-corrupt", "boot record corrupt + app hangs", "hang", "STOCK", record="corrupt"),
        Case("rescue-corrupt", "rescue.bin corrupt (one byte) + app hangs", "hang", "SAFE",
             rescue="corrupt", budget=120),
        Case("rescue-missing", "rescue.bin missing + app hangs", "hang", "SAFE", rescue="missing", budget=120),
    ]


def native_cases() -> list[Case]:
    """The real Wisp app (native-0's) behind the fallback Wisp Boot, in the state install-wisp
    leaves (flag clear, the stock main still staged)."""
    return [
        Case("native-app-runs", "real app behind Wisp Boot: boots, feeds both watchdogs, answers the case UART",
             "real", "NATIVE", flag_initially_set=False, staging="stock", firmware=True, query=True, budget=60,
             status={"observe": False, "action": "run-app", "reason": 1}),
        Case("native-app-unconfirmed", "real app never confirms (no BLE): 3 power cuts while it runs, then rescue",
             "real", "STOCK", flag_initially_set=False, staging="stock", cuts_running=3, budget=300),
    ]


def observe_cases() -> list[Case]:
    """native-0's observe-only Wisp Boot: never writes, always runs the app."""
    common = {"observe": True, "log": False, "nor_result": 0, "mount_result": 0, "action": "run-app"}
    return [
        Case("obs-native-0", "native-0 as install-wisp leaves it (stock staged, no rescue.bin), 3 power cuts",
             "real", "OBSERVE", flag_initially_set=False, staging="stock", rescue="missing", firmware=True,
             cuts_running=3, min_boots=4, query=True, budget=120,
             status={**common, "rescue_ok": False, "would_action": "run-app", "reason": 1}),
        Case("obs-would-rescue", "3 unconfirmed boots recorded, rescue.bin valid, app hangs: the fallback build "
             "would rescue; observe-only runs the app every time", "hang", "OBSERVE", flag_initially_set=False,
             staging="stock", record="unconfirmed", firmware=True, min_boots=4, budget=60,
             status={**common, "rescue_ok": True, "would_action": "rescue", "reason": 4}),
        Case("obs-crash-reset", "app faults in its reset handler: Wisp Boot hands over every boot",
             "crash_reset", "OBSERVE", flag_initially_set=False, staging="stock", firmware=True, min_boots=4,
             budget=60, status={**common, "rescue_ok": True, "would_action": "run-app"}),
        Case("obs-no-feed", "app never feeds the watchdog", "no_feed", "OBSERVE", flag_initially_set=False,
             staging="stock", rescue="corrupt", min_boots=3, budget=60,
             status={**common, "rescue_ok": False, "would_action": "run-app"}),
        Case("obs-erased", "no app behind Wisp Boot (slot erased): it resets at once, every boot",
             "erased", "OBSERVE", flag_initially_set=False, staging="stock", min_boots=5, budget=60),
        Case("obs-diag-wdt", "app never feeds the watchdog, SRAM kept across warm resets: each boot's status "
             "carries the previous boot's diagnostics record (D1): it got to the hand-off, the watchdog reset it",
             "no_feed", "OBSERVE", flag_initially_set=False, staging="stock", rescue="corrupt", min_boots=3,
             budget=60, retain=True,
             status={**common, "rescue_ok": False, "prev_valid": True, "prev_stage": "boot-handoff",
                     "reset_cause_names": ["watchdog"]}),
        Case("obs-stage-0", "stage-0 (rung4.md W24b) as install-wisp leaves it: IDENT, its clock measurement, the "
             "boot report, a case-UART RESET, then the boot report from Wisp Boot's window (D1, D2)",
             "stage0", "OBSERVE", flag_initially_set=False, staging="stock", rescue="missing", firmware=True,
             min_boots=1, query=True, budget=60, retain=True,
             status={**common, "rescue_ok": False, "would_action": "run-app", "reason": 1}),
        Case("obs-nor-gd", "Wisp Boot reads another NOR id (GD25LE256H, C8 60 19): no filesystem, app runs",
             "real", "OBSERVE", flag_initially_set=False, staging="stock", firmware=True, rdid="c8 60 19",
             min_boots=1, budget=40,
             status={"observe": True, "nor_id": 0x1960C8, "nor_result": -11, "mount_result": 1,
                     "action": "run-app-degraded", "staging_present": False}),
    ]


def cut_cases(ref: dict) -> list[Case]:
    """Power cuts at every step of the rescue path, positioned from the reference run."""
    m = ref["milestones"]
    copy0 = m["rescue_copy"][0]
    verify1 = m["staged_verify"][0]
    span = verify1 - copy0
    cs = [Case("cut-rescue-start", "power cut: rescue decided, record written, copy not started", "hang",
               "STOCK", cut_milestone=("rescue_copy", 1))]
    for k, frac in enumerate((0.02, 0.25, 0.5, 0.75, 0.98), 1):
        n = copy0 + max(1, int(span * frac))
        cs.append(Case(f"cut-copy-{int(frac * 100)}pct", f"power cut mid staging copy ({int(frac * 100)} %, NOR op {n})",
                       "hang", "STOCK", cut_nor_op=n))
    cs += [
        Case("cut-copy-committed", "power cut: staging copy committed, before verify", "hang", "STOCK",
             cut_milestone=("image_verify", m["staged_verify_hit"][0])),
        Case("cut-copy-committed-flag-clear", "same, flag cleared before (Wisp Boot must resume)", "hang",
             "STOCK", flag_initially_set=False, cut_milestone=("image_verify", m["staged_verify_hit"][0])),
        Case("cut-before-flag", "power cut: copy verified, flag not written", "hang", "STOCK",
             cut_milestone=("hw_flag_set_install", 1)),
        Case("cut-before-flag-flag-clear", "same, flag cleared before (Wisp Boot must resume)", "hang", "STOCK",
             flag_initially_set=False, cut_milestone=("hw_flag_set_install", 1)),
        Case("cut-after-flag", "power cut right after the flag write", "hang", "STOCK", cut_after_flag=True),
    ]
    w0 = ref["first_install_write"]
    wn = ref["last_install_write"]
    for frac in (0.1, 0.5, 0.99):
        i = w0 + int((wn - w0) * frac)
        cs.append(Case(f"cut-install-{int(frac * 100)}pct", f"power cut during the bootloader's stock install ({int(frac * 100)} %)",
                       "hang", "STOCK", cut_rom_write=i))
    cs.append(Case("cut-install-done", "power cut right after the last install write", "hang", "STOCK",
                   cut_rom_write=wn))
    return cs


def record_bytes(image_id: int, attempts: int) -> bytes:
    """A valid wisp/boot.rec (wisp_boot.h): magic, version 2, state RUN, attempts, tries 0, image id."""
    body = struct.pack("<IBBBBI", 0x54424957, 2, 0, attempts, 0, image_id)
    return body + struct.pack("<I", zlib_crc(body))


def patched_bootloader(cache: Path) -> bytes:
    sys.path.insert(0, str(REPO / "apps/wisp-recovery"))
    from wisp_w18 import image  # noqa: PLC0415 - the pinned W18 build, only for --bootloader patched
    return image.build_patched_bootloader(cache / "stock")


class Harness:
    def __init__(self, args):
        self.cache = args.cache.resolve()
        self.build = args.boot_build.resolve()
        self.suite = args.suite
        self.patched = args.bootloader == "patched"
        self.bootloader, self.stock = stock_inputs(self.cache, args.stock_version)
        if self.patched:
            self.bootloader = patched_bootloader(self.cache)
        bl_sha = hashlib.sha256(self.bootloader).hexdigest()
        self.label = f"{'patched' if self.patched else 'stock'}-{bl_sha[:8]}-{self.suite}"
        self.work = self.cache / "rung3" / self.label
        self.work.mkdir(parents=True, exist_ok=True)
        self.keep = args.keep
        self.lfs = Lfs(build_lfs_tool(self.cache))
        (self.work / "bootloader.bin").write_bytes(self.bootloader)
        bundle = (self.cache / "stock" / f"g2-{args.stock_version}.bin").read_bytes()
        comps = evenota_components(bundle)
        self.firmware = {f"firmware/{name}": comps[t] for t, name in FIRMWARE_FILES.items() if t in comps}
        self.syms = nm_symbols(self.build / "wisp_boot.elf")
        self.boot_sha = hashlib.sha256((self.build / "wisp_boot.bin").read_bytes()).hexdigest()
        self.payloads = {}
        apps = ["good", "hang", "crash_reset", "crash_after", "no_feed", "erased"]
        if (self.build / "native_real.bin").exists():
            apps.append("real")
        if (self.build / "native_stage0.bin").exists():
            apps.append("stage0")
        for app in apps:
            self.payloads[app] = wisp_payload(self.build / f"native_{app}.bin", self.work)

    # -- one run --
    def run(self, case: Case) -> dict:
        d = self.work / "runs" / case.name
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        payload = self.payloads[case.app]
        staging = payload if case.staging == "wisp" else self.stock
        stock_rescue = bytearray(self.stock)
        if case.rescue == "corrupt":
            stock_rescue[len(stock_rescue) // 2] ^= 0x01
        files = {"ota/s200_firmware_ota.bin": staging}
        if case.rescue != "missing":
            files["wisp/rescue.bin"] = bytes(stock_rescue)
        if case.record == "corrupt":
            files["wisp/boot.rec"] = b"\x57\x49\x42\x54" + b"\x5a" * 12
        elif case.record == "unconfirmed":
            files["wisp/boot.rec"] = record_bytes(struct.unpack_from("<I", staging, 4)[0], 3)
        if case.firmware:
            files.update(self.firmware)
        nor = d / "nor.bin"
        self.lfs.build(nor, files, d)
        (d / "native.bin").write_bytes(payload[32:])
        flag = FLAG_SET if case.flag_initially_set else FLAG_CLEAR

        r = Renode(d, free_port())
        res = {"files": files}
        try:
            out = r.cmd(f"include @{platform(d, self.patched)}")
            if "error" in out.lower() or "could not" in out.lower():
                raise RuntimeError(f"Renode platform failed to load: {out[-800:]}")
            if self.patched:
                # As tests/boot/w18.py runs it: idle (WFI) time is skipped, not paced (the loader's boot
                # window otherwise stalled the first RunFor); virtual time stays exact. Model limits of
                # the loader: no MVE in Renode's M55, and its short pacing delays drift (both only matter
                # while it holds a session).
                out = r.cmd("emulation SetAdvanceImmediately true")
                if "error" in out.lower():
                    raise RuntimeError(out)
                for line in ("uart2 MveVprShim 0x43491C 0x434952 7",
                             'uart2 PacingShim 0x416378 "4349D4-434A38,434A38-434B00,4350AC-43511C" 21'):
                    out = r.cmd(line)
                    if out.strip():
                        raise RuntimeError(f"{line}: {out}")
            r.cmd(f"nor LoadImage @{nor}")
            r.cmd(f"nor WatchCode {MAIN_BASE:#x} {WISP_BOOT_END:#x}")
            if case.rdid:
                r.cmd(f'nor RdidInWindow "{case.rdid}"')
            r.cmd(f"sysbus LoadBinary @{self.work / 'bootloader.bin'} 0x410000")
            r.cmd(f"sysbus LoadBinary @{d / 'native.bin'} 0x438000")   # Wisp, as installed
            for i, w in enumerate(flag):
                r.cmd(f"sysbus WriteDoubleWord {FLAG + 4 * i:#x} {w:#x}")
            for name in ("wisp_boot_main", "rescue_copy", "image_verify", "hw_flag_set_install", "hw_jump"):
                if name in self.syms:
                    r.cmd(f'probe Milestone {self.syms[name]:#x} "{name}"')
            r.cmd('probe StrictFrom "wisp_boot_main"')
            if case.retain:
                r.cmd("rstgen RetainRange 0x20370000 0x40")
            if case.cut_nor_op is not None:
                r.cmd(f"probe CutAtNorOp {case.cut_nor_op}")
            if case.cut_milestone:
                r.cmd(f'probe CutAtMilestone "{case.cut_milestone[0]}" {case.cut_milestone[1]}')
            if case.cut_rom_write is not None:
                r.cmd(f"bootrom CutAfterWriteIndex {case.cut_rom_write}")
            if case.cut_after_flag:
                r.cmd(f"bootrom CutAfterWritesTo {FLAG:#x}")
            if case.app == "real":
                # As stock leaves it (recovery.md): armed, 30.72 s, its last kick just now.
                r.cmd(f"pmicwdt Arm {PMIC_PERIOD_S}")
            # Cold start: the SBL's hand-off into the bootloader (WispRstGen does the same on
            # every later reset).
            sp, pc = struct.unpack_from("<II", self.bootloader, 0)
            r.cmd("cpu VectorTableOffset 0x410000")
            r.cmd(f"cpu SP {sp:#x}")
            r.cmd(f"cpu PC {pc & ~1:#x}")
            res.update(self.drive(r, case, d))
            res["mram"] = self.dump(r, d)
            res["rom_writes"] = r.cmd("bootrom WriteLog").splitlines()
            res["resets"] = r.cmd("rstgen ResetLog").splitlines()
            res["milestones"] = r.cmd("probe Report").splitlines()
            res["wdt_bites"] = int(r.cmd("wdt Bites") or "0", 0)
            res["nor_watched"] = r.cmd("nor WatchedLog").splitlines()
            res["nor_watched_writes"] = int(r.cmd("nor WatchedWrites").split()[0], 0)
            res["pmic_log"] = r.cmd("pmicwdt PmicLog")
            res["pmic_pc_log"] = r.cmd("pmicwdt PmicPcLog")
            res["strict"] = strict.parse(r.cmd("probe StrictDump"))
            (d / "strict.txt").write_text(r.cmd("probe StrictDump") + "\n")
            res["pmic_expiries"] = int(r.cmd("pmicwdt Expiries").split()[0], 0)
            (d / "pmic.log").write_text(res["pmic_log"] + "\n")
            res["boot_status_raw"] = self.boot_status(r, d)
            r.cmd(f"nor SaveImage @{d / 'nor-after.bin'}")
        finally:
            r.close()
        res["uart"] = (d / "uart1.txt").read_text(errors="replace") if (d / "uart1.txt").exists() else ""
        res["staging"] = self.lfs.get(d / "nor-after.bin", "ota/s200_firmware_ota.bin", d)
        res["files_after"] = {name: self.lfs.get(d / "nor-after.bin", name, d) for name in files}
        return res

    def dump(self, r: Renode, d: Path) -> bytes:
        out = d / "mram.bin"
        r.cmd(f"probe Dump 0x400000 0x400000 @{out}")
        return out.read_bytes()

    def boot_status(self, r: Renode, d: Path) -> bytes | None:
        """Wisp Boot's status block, through its services table (version >= 2)."""
        magic, version, _confirm, ptr = (int(r.cmd(f"sysbus ReadDoubleWord {SERVICES + 4 * i:#x}"), 0)
                                         for i in range(4))
        if magic != 0x31534257 or version < 2 or not 0x20370000 <= ptr < 0x20380000:
            return None
        out = d / "boot-status.bin"
        r.cmd(f"probe Dump {ptr:#x} {case_uart.BOOT_STATUS_SIZE} @{out}")
        return out.read_bytes()

    def boots(self, r: Renode) -> tuple[int, int]:
        """(Wisp Boot runs, hand-offs to the app) so far, from the probe's milestones."""
        rep = r.cmd("probe Report").splitlines()
        return (sum(l.startswith("wisp_boot_main ") for l in rep), sum(l.startswith("hw_jump ") for l in rep))

    def query(self, r: Renode, d: Path) -> dict:
        """The case-UART exchange boot-watch would make: version, status, the boot block."""
        def ask(data: bytes) -> bytes:
            before = len(r.cmd("uart2 FrameLog").split())
            r.cmd(f'uart2 Inject "{data.hex()}"')
            for _ in range(20):
                r.cmd('emulation RunFor "0.05"')
                frames = r.cmd("uart2 FrameLog").split()
                if len(frames) > before:
                    return bytes.fromhex(frames[before])
            raise RuntimeError(f"no case-UART reply to {data.hex()}")
        out = {"version": case_uart.decode_version(ask(case_uart.STOCK_VERSION_QUERY))}
        reply = ask(case_uart.ident_request())
        out["relay_shape"] = len(reply) in case_uart.REPLY_LENGTHS
        st, data = case_uart.decode_reply(reply, case_uart.OP_IDENT)
        out["ident"] = case_uart.decode_ident(data) if st == 0 else {"code": st}
        raw = case_uart.read_block(ask, case_uart.BLOCK_STATUS)
        out["status"] = case_uart.decode_status(raw) if raw else None
        out["status_code"] = 0 if raw else 3
        out["boot_block"] = case_uart.read_block(ask, case_uart.BLOCK_BOOT) or b""
        # The case app's 0x13 poll (deliberately unanswered, case-uart.md), a loader CONT and garbage:
        # none may get an answer.
        before = len(r.cmd("uart2 FrameLog").split())
        junk = bytes.fromhex("13000001e4017d" "7e000104434f4e54ff" "0013e4")
        r.cmd(f'uart2 Inject "{junk.hex()}"')
        r.cmd('emulation RunFor "0.3"')
        out["unanswered_ok"] = len(r.cmd("uart2 FrameLog").split()) == before
        (d / "case-uart.json").write_text(json.dumps({k: v.hex() if isinstance(v, bytes) else v
                                                     for k, v in out.items()}, indent=2, default=str))
        return out

    def query_stage0(self, r: Renode, d: Path) -> dict:
        """stage-0 over the case UART: IDENT, its blocks, the boot report; then RESET, and the boot
        report from Wisp Boot's window right after the next Wisp Boot entry."""
        def frames() -> list[str]:
            return r.cmd("uart2 FrameLog").split()

        def ask(data: bytes, tries: int = 20, step: str = "0.05") -> bytes:
            before = len(frames())
            r.cmd(f'uart2 Inject "{data.hex()}"')
            for _ in range(tries):
                r.cmd(f'emulation RunFor "{step}"')
                got = frames()
                if len(got) > before:
                    return bytes.fromhex(got[before])
            raise RuntimeError(f"no case-UART reply to {data.hex()}")
        out = {}
        st, data = case_uart.decode_reply(ask(case_uart.ident_request()), case_uart.OP_IDENT)
        out["ident"] = case_uart.decode_ident(data) if st == 0 else {"code": st}
        raw = case_uart.read_block(ask, case_uart.BLOCK_STATUS)
        out["status"] = case_uart.decode_status(raw) if raw else None
        out["boot_block"] = case_uart.read_block(ask, case_uart.BLOCK_BOOT) or b""
        # Its first measurement starts 2 s after it started and takes about 1.1 s.
        for _ in range(12):
            clock = case_uart.decode_clock(case_uart.read_block(ask, case_uart.BLOCK_CLOCK))
            if clock["measurements"]:
                break
            r.cmd('emulation RunFor "0.5"')
        out["clock"] = clock
        out["diag"] = case_uart.decode_diag_record(case_uart.read_block(ask, case_uart.BLOCK_DIAG))
        st, data = case_uart.decode_reply(ask(case_uart.bootrep_request()), case_uart.OP_BOOTREP)
        out["report_app"] = case_uart.decode_boot_report(data) if st == 0 else {"code": st}
        runs = self.boots(r)[0]
        st, _ = case_uart.decode_reply(ask(case_uart.reset_request()), case_uart.OP_RESET)
        out["reset_code"] = st
        for _ in range(200):  # until Wisp Boot's entry on the next boot (0.02 s steps)
            r.cmd('emulation RunFor "0.02"')
            if self.boots(r)[0] > runs:
                break
        st, data = case_uart.decode_reply(ask(case_uart.bootrep_request(), tries=10, step="0.02"), case_uart.OP_BOOTREP)
        out["report_boot"] = case_uart.decode_boot_report(data) if st == 0 else {"code": st}
        r.cmd('emulation RunFor "1"')
        st, data = case_uart.decode_reply(ask(case_uart.ident_request()), case_uart.OP_IDENT)
        out["ident_after"] = case_uart.decode_ident(data) if st == 0 else {"code": st}
        (d / "case-uart.json").write_text(json.dumps({k: v.hex() if isinstance(v, bytes) else v
                                                     for k, v in out.items()}, indent=2, default=str))
        return out

    def check_stage0(self, res: dict, fails: list[str]) -> str:
        q = res.get("query") or {}
        ident, clock, rb, ra = q.get("ident", {}), q.get("clock", {}), q.get("report_boot", {}), q.get("report_app", {})
        if ident.get("image_kind") != case_uart.IMAGE_KIND_STAGE0 or ident.get("stage") != "bare-metal":
            fails.append(f"stage-0 IDENT {ident}")
        st = q.get("status") or {}
        if not {"boot-services", "boot-status", "boot-observe"} <= set(st.get("flags", [])) or st.get("pmic_kicks", 0) < 1:
            fails.append(f"stage-0 status {st}")
        if q.get("boot_block") and q["boot_block"] != res.get("boot_status_raw"):
            pass  # the second boot resealed it; compared through the decoded fields below
        if clock.get("result") != "ok" or clock.get("timebase") != "stimer-xt" or \
                not 850 <= clock.get("lfrc_hz", 0) <= 960 or not 8000 <= clock.get("wdt_period_ms", 0) <= 10000:
            fails.append(f"stage-0 clock {clock}")
        diag = q.get("diag", {})
        if diag.get("stage") not in ("s0-loop", "s0-measure"):
            fails.append(f"stage-0 diag record {diag}")
        if ra.get("source") != "app" or "kick-ok" not in ra.get("flags", []):
            fails.append(f"the app's boot report {ra}")
        if q.get("reset_code") != 0:
            fails.append(f"RESET reply {q.get('reset_code')}")
        if rb.get("source") != "wisp-boot" or rb.get("prev_stage") != "s0-reset-request" or \
                rb.get("reset_cause_names") != ["sw-por"] or "prev-valid" not in rb.get("flags", []):
            fails.append(f"Wisp Boot's boot report after RESET {rb}")
        if (q.get("ident_after") or {}).get("image_kind") != case_uart.IMAGE_KIND_STAGE0:
            fails.append(f"stage-0 did not come back after RESET: {q.get('ident_after')}")
        app = [e for e in strict.pmic_writes(res["pmic_pc_log"]) if not e["wisp_boot"]]
        if any(e["bytes"] != strict.KICK for e in app) or len(app) < 3:
            fails.append(f"stage-0 PMIC writes {sorted({e['bytes'] for e in app})} ({len(app)})")
        if res["wdt_bites"]:
            fails.append(f"{res['wdt_bites']} watchdog bites with stage-0")
        return (f"stage-0: kind {ident.get('image_kind')}, {len(app)} PMIC kicks, LFRC {clock.get('lfrc_hz')} Hz "
                f"(watchdog {clock.get('wdt_period_ms')} ms), core {clock.get('core_hz')} Hz; after RESET Wisp Boot "
                f"reported prev {rb.get('prev_stage')} {rb.get('prev_stage_ms')} ms, cause {rb.get('reset_cause_names')}")

    def drive(self, r: Renode, case: Case, d: Path) -> dict:
        uart = d / "uart1.txt"
        t = 0.0
        step = 1.0 if case.app == "real" or case.expect == "OBSERVE" else 2.0
        if self.patched:
            # Through the patched loader's boot window a long RunFor can stall Renode (seen with 1 s
            # and 2 s steps, never with 0.1 s); the window comes back at every reset.
            step = 0.1
        cuts_done = 0
        out = {}
        while t < case.budget:
            r.cmd(f'emulation RunFor "{step}"')
            t += step
            if r.cmd("pmicwdt PowerCyclePending").strip() == "True":
                r.cmd("pmicwdt AckPowerCycle")   # counted in Expiries; the checks fail on it
                r.cmd("rstgen PowerCut")
            text = uart.read_text(errors="replace") if uart.exists() else ""
            last = text.rfind(APP_BANNER)
            app_up = last >= 0 and text.count(APP_BEAT, last) >= 2
            if case.app == "real" and cuts_done < case.cuts_running and app_up \
                    and text.count(APP_BANNER) == cuts_done + 1:
                r.cmd("rstgen PowerCut")
                cuts_done += 1
                continue
            if case.expect == "STOCK":
                jumps = [m.end() for m in JUMP_RE.finditer(text)]
                if jumps and STOCK_MARK in text[jumps[-1]:] and "wisp-boot" not in text[jumps[-1]:] \
                        and cuts_done >= case.cuts_running:
                    break
            elif case.expect == "WISP":
                n = text.count("wisp-app: boot confirmed")
                beat = text.rfind("wisp-app: heartbeat") > text.rfind("wisp-app: boot confirmed")
                if n == cuts_done + 1 and beat:
                    if cuts_done == case.extra_cuts:
                        break
                    r.cmd("rstgen PowerCut")
                    cuts_done += 1
            elif case.expect == "SAFE":
                if text.count("wisp-boot: start") >= 8:
                    break
            elif case.expect == "NATIVE":
                if cuts_done == case.cuts_running and last >= 0 and text.count(APP_BEAT, last) >= 8:
                    break
            elif case.expect == "OBSERVE":
                runs, handoffs = self.boots(r)
                # Stop once the last boot's Wisp Boot is done (its status block sealed): it handed
                # over (or, with no app, it is resetting at once).
                # With the real app: the app of the last hand-off is up (its own banner, not an
                # earlier boot's).
                if runs >= case.min_boots and cuts_done == case.cuts_running and \
                        (case.app != "real" or (app_up and text.count(APP_BANNER) >= handoffs)) and \
                        (handoffs >= runs or case.app == "erased"):
                    break
        if case.query and case.app == "stage0":
            out["query"] = self.query_stage0(r, d)
        elif case.query:
            out["query"] = self.query(r, d)
            r.cmd('emulation RunFor "1"')
        out["virtual_s"] = t
        out["cuts"] = cuts_done
        return out

    # -- assertions --
    def check_pmic(self, res: dict, fails: list[str]) -> str:
        """The real app: stock's arming writes, a kick at least every 1.6 s once it started, nothing
        else written to the PMIC (rung4.md G12, G27), and no PMIC power cycle."""
        # The app's data writes (PmicPcLog has data writes only; Wisp Boot's kicks are checked in check()).
        data = [(e["ms"], e["bytes"]) for e in strict.pmic_writes(res["pmic_pc_log"]) if not e["wisp_boot"]]
        bad = sorted({w for _, w in data if w not in PMIC_ALLOWED})
        if bad:
            fails.append(f"PMIC writes outside the allowlist: {bad}")
        # W21's snapshot (images/pmic-baseline-w21.json): no configuration register changes.
        diffs = pmic_baseline.check([bytes.fromhex(w.replace(" ", "")) for _, w in data])
        if diffs:
            fails.append(f"PMIC writes differ from W21's snapshot: {diffs[:4]}")
        seq = [w for _, w in data if w != "07 04 01" and w != "05 00 01"]
        if [w for w in seq if w in PMIC_ARM][:4] != PMIC_ARM:
            fails.append(f"PMIC watchdog not armed with stock's sequence: {seq[:8]}")
        # Gaps between kicks within one boot. A boot's first kick is followed at once by stock's
        # arming writes; the gap that ends there spans a reboot and is not the app's.
        kick_at = [i for i, (_t, w) in enumerate(data) if w == "07 04 01"]
        gaps = [data[j][0] - data[i][0] for i, j in zip(kick_at, kick_at[1:])
                if not (j + 1 < len(data) and data[j + 1][1] == PMIC_ARM[0])]
        longest = max(gaps, default=0)
        kicks = kick_at
        if len(kicks) < 3:
            fails.append(f"only {len(kicks)} PMIC kicks")
        if longest > 1500:
            fails.append(f"PMIC kicks {longest} ms apart within one boot (want about 1 s)")
        if res["pmic_expiries"]:
            fails.append(f"the PMIC watchdog expired {res['pmic_expiries']} time(s)")
        return f"{len(kicks)} PMIC kicks (at most {longest} ms apart within a boot), PMIC config = W21 snapshot"

    def check_status(self, case: Case, res: dict, fails: list[str]) -> str:
        raw = res.get("boot_status_raw")
        if raw is None:
            fails.append("no Wisp Boot status block")
            return ""
        try:
            st = case_uart.decode_boot_status(raw)
        except ValueError as e:
            fails.append(f"status block: {e}")
            return ""
        files = res["files"]
        want = dict(case.status)
        if want.get("mount_result", 0) == 0 and "staging_present" not in want:
            staging = files["ota/s200_firmware_ota.bin"]
            want.update(staging_present=True, staging_id=struct.unpack_from("<I", staging, 4)[0],
                        staging_size=len(staging), nor_id=want.get("nor_id", 0x3925C2))
            rescue = files.get("wisp/rescue.bin")
            want["rescue_size"] = len(rescue) if rescue else 0
            fw = {n.split("/", 1)[1]: (len(b), zlib_crc(b)) for n, b in files.items() if n.startswith("firmware/")}
            got_fw = {e["name"]: (e["size"], e["crc"]) for e in st["inventory"] if e["result"] == 0}
            if got_fw != fw:
                fails.append(f"status inventory {got_fw} != {fw}")
            if st["inventory_result"] != (0 if fw else st["inventory_result"]):
                fails.append(f"inventory result {st['inventory_result']}")
        if "prev_stage" in want:
            st = {**st, "prev_stage": (st.get("prev") or {}).get("stage")}
        for k, v in want.items():
            if st.get(k) != v:
                fails.append(f"status {k} = {st.get(k)!r}, want {v!r}")
        res["boot_status"] = st
        return (f"status: NOR {st['nor_id']:06x}, staging {st['staging_id']:08x}, rescue.bin "
                f"{'ok' if st['rescue_ok'] else 'not ok'}, {len(st['inventory'])} firmware files, "
                f"action {st['action']}, would {st['would_action']}")

    def check_query(self, case: Case, res: dict, fails: list[str]) -> str:
        q = res.get("query")
        if not q:
            fails.append("no case-UART answers")
            return ""
        st = q.get("status") or {}
        if not q["version"]["wisp"]:
            fails.append(f"version reply is not Wisp's: {q['version']}")
        if not q.get("relay_shape") or q.get("ident", {}).get("image_kind") != 0:
            fails.append(f"IDENT {q.get('ident')} (relay shape {q.get('relay_shape')})")
        need = {"pmic-wdt", "boot-services", "boot-status"} | ({"boot-observe"} if self.suite == "observe" else set())
        if q.get("status_code") != 0 or not need <= set(st.get("flags", [])) or st.get("image_kind") != 0:
            fails.append(f"case-UART status {q.get('status_code')} {st}")
        if st.get("stage") not in ("bt-failed", "bt-up"):
            fails.append(f"case-UART stage {st.get('stage')}")
        if q.get("boot_block") != res.get("boot_status_raw"):
            fails.append("BOOT_BLOCK over the case UART differs from the status block in RAM")
        if not q.get("unanswered_ok"):
            fails.append("the app answered garbage or a loader frame")
        return (f"case UART (relay shapes): IDENT {q['version']['id']} {q['version']['firmware']}, stage {st.get('stage')}, "
                f"bt {st.get('bt_result')}, flags {','.join(st.get('flags', []))}, boot block "
                f"{len(q.get('boot_block', b''))} B")

    def check(self, case: Case, res: dict) -> tuple[bool, str, str]:
        mram, uart = res["mram"], res["uart"]
        fails = []
        bl_end = 0x410000 + len(self.bootloader)
        if mram[0x10000:bl_end - 0x400000] != self.bootloader:
            fails.append("bootloader region changed")
        wisp_writes = []
        for line in res["rom_writes"]:
            m = re.search(r"lr=0x([0-9A-F]+) dst=0x([0-9A-F]+) words=(\d+) first=0x([0-9A-F]+)", line)
            if not m:
                continue
            lr, dst, n, first = int(m[1], 16), int(m[2], 16), int(m[3]), int(m[4], 16)
            if MAIN_BASE <= lr < WISP_BOOT_END + 0x10000 or (case.app == "real" and MAIN_BASE <= lr < APP_CEILING
                                                               and case.expect != "STOCK"):
                wisp_writes.append((dst, n, first))
            elif not (dst == FLAG and n == 4) and not (MAIN_BASE <= dst < 0x7F8000):
                fails.append(f"bootloader wrote MRAM outside app/flag: {line}")
        bad = [w for w in wisp_writes if w != (FLAG, 4, 0x55555555)]
        if bad:
            fails.append(f"Wisp code wrote MRAM other than the flag: {bad}")
        boots = sum(l.startswith("wisp_boot_main ") for l in res["milestones"])
        handoffs = sum(l.startswith("hw_jump ") for l in res["milestones"])
        wb_kicks, wb_other = strict.wisp_boot_pmic(res["pmic_pc_log"])
        if wb_other:
            fails.append(f"Wisp Boot wrote the PMIC other than the kick: {wb_other}")
        if not boots - 1 <= wb_kicks <= boots:  # one kick per run; a power cut may land before it
            fails.append(f"{wb_kicks} PMIC kicks by Wisp Boot in {boots} runs")
        wb_strict = strict.unallowed_writes(res["strict"], owners=("wisp-boot",))
        if wb_strict:
            fails.append(f"Wisp Boot wrote unmodelled power/clock/trim registers: {strict.describe(wb_strict)}")
        detail = (f"{len(res['resets'])} resets, {boots} Wisp Boot runs ({wb_kicks} PMIC kicks), {res['wdt_bites']} WDT bites, "
                  f"{res['virtual_s']:.0f} s virtual")
        extra = []
        if case.expect == "STOCK":
            stock_img = self.stock[32:]
            if mram[MAIN_BASE - 0x400000:MAIN_BASE - 0x400000 + len(stock_img)] != stock_img:
                fails.append("MRAM at 0x438000 is not the stock image")
            jumps = [m.end() for m in JUMP_RE.finditer(uart)]
            if not jumps or STOCK_MARK not in uart[jumps[-1]:]:
                fails.append(f"no stock UART line ('{STOCK_MARK}') after the last hand-off")
            # With the flag still set from the original install, a cut after the staged copy
            # committed hands over without Wisp Boot's own flag write: the bootloader installs
            # the staged rescue after its own CRC check. Otherwise Wisp Boot must have set it.
            if not wisp_writes and not case.flag_initially_set:
                fails.append("Wisp Boot never wrote the flag")
            if res["staging"] != self.stock:
                fails.append("staging file is not the rescue image")
            if case.cuts_running and res["cuts"] != case.cuts_running:
                fails.append(f"{res['cuts']} of {case.cuts_running} power cuts while the app ran")
            if case.cuts_running and uart.count(APP_BANNER) != case.cuts_running:
                fails.append(f"the real app booted {uart.count(APP_BANNER)} times, want {case.cuts_running}")
            how = "Wisp Boot set the flag" if wisp_writes else "flag left set by the install"
            state = f"stock running; {how}"
            if case.cuts_running:
                state = f"real app ran {uart.count(APP_BANNER)} unconfirmed boots, then rescue; {state}"
        elif case.expect == "WISP":
            if wisp_writes:
                fails.append("Wisp Boot wrote the flag in the control case")
            if uart.count("wisp-app: boot confirmed") < case.extra_cuts + 1:
                fails.append("app did not confirm every boot")
            state = "Wisp app running, confirmed"
        elif case.expect == "SAFE":
            if wisp_writes:
                fails.append("Wisp Boot wrote the flag although rescue.bin is unusable")
            payload = self.payloads[case.app]
            if mram[MAIN_BASE - 0x400000:MAIN_BASE - 0x400000 + len(payload) - 32] != payload[32:]:
                fails.append("MRAM no longer holds the Wisp image")
            if res["staging"] != payload:
                fails.append("staging file changed")
            if boots < 6 or "run-app-degraded" not in uart:
                fails.append("expected a degraded app boot loop")
            state = f"no flag; Wisp app keeps booting (degraded every 3rd boot)"
        else:  # NATIVE / OBSERVE: the Wisp image stays, the app keeps getting control
            payload = self.payloads[case.app]
            if mram[MAIN_BASE - 0x400000:MAIN_BASE - 0x400000 + len(payload) - 32] != payload[32:]:
                fails.append("MRAM no longer holds the Wisp image")
            if wisp_writes or res["rom_writes"] and any("dst=" in l for l in res["rom_writes"]):
                fails.append(f"an MRAM write happened: {res['rom_writes'][:3]}")
            changed = [n for n, b in res["files"].items() if res["files_after"].get(n) != b]
            if case.expect == "OBSERVE":
                if changed:
                    fails.append(f"NOR files changed: {changed}")
                if res["nor_watched_writes"]:
                    fails.append(f"Wisp Boot issued {res['nor_watched_writes']} NOR write/erase commands")
                ops = sorted({l.split()[0] for l in res["nor_watched"] if l.strip()})
                need = {"9f"} if case.rdid else {"9f", "05", "13"}   # RDID always; reads once mounted
                if not set(ops) <= {"9f", "05", "13"} or not need <= set(ops):
                    fails.append(f"Wisp Boot NOR commands {ops} (allowed 9f/05/13, required {sorted(need)})")
                extra.append(f"Wisp Boot's NOR commands: {', '.join(ops) or 'none'}")
                want_handoffs = 0 if case.app == "erased" else boots
                if boots < case.min_boots or abs(handoffs - want_handoffs) > 1:
                    fails.append(f"{boots} Wisp Boot runs, {handoffs} hand-offs to the app")
            else:
                if res["wdt_bites"]:
                    fails.append(f"{res['wdt_bites']} watchdog bites: the app does not feed Wisp Boot's WDT")
                if boots != case.cuts_running + 1:
                    fails.append(f"{boots} Wisp Boot runs")
            if case.app == "stage0":
                extra.append(self.check_stage0(res, fails))
                app_strict = strict.unallowed_writes(res["strict"], owners=("app", "itcm"))
                if app_strict:
                    fails.append(f"stage-0 wrote unmodelled power/clock/trim registers: {strict.describe(app_strict)}")
            if case.app == "real":
                app_strict = strict.unallowed_writes(res["strict"], owners=("app", "itcm"))
                extra.append(f"strict: the app wrote {len(app_strict)} unmodelled power/clock/trim register values "
                             f"(listed in strict.txt; wisp-fw:w18-test fails native-0 on them)")
                if uart.count(APP_BANNER) < max(1, case.cuts_running + 1):
                    fails.append(f"the app booted {uart.count(APP_BANNER)} times")
                if case.expect == "OBSERVE" and res["wdt_bites"]:
                    fails.append(f"{res['wdt_bites']} watchdog bites with the real app")
                extra.append(self.check_pmic(res, fails))
            if case.status:
                extra.append(self.check_status(case, res, fails))
            if case.query and case.app != "stage0":
                extra.append(self.check_query(case, res, fails))
            kind = "observe-only Wisp Boot" if case.expect == "OBSERVE" else "Wisp Boot"
            state = (f"{kind} ran {boots}x, {'no app (reset at once)' if case.app == 'erased' else 'the app ran each time'}; "
                     f"no MRAM write; " + "; ".join(e for e in extra if e))
        if case.expect != "OBSERVE" and case.app != "real" and res["pmic_expiries"]:
            fails.append("PMIC power cycle")
        return (not fails), (state if not fails else "; ".join(fails)), detail


def reference_run(h: Harness) -> dict:
    case = Case("reference", "reference: app hangs (positions the cut points)", "hang", "STOCK")
    res = h.run(case)
    ok, state, detail = h.check(case, res)
    if not ok:
        raise SystemExit(f"rung3: reference run failed: {state}")
    ms = {}
    order = []
    for line in res["milestones"]:
        m = re.match(r"(\w+) pc=\S+ lr=\S+ nor_ops=(\d+)", line)
        if m:
            ms.setdefault(m[1], []).append(int(m[2]))
            order.append((m[1], int(m[2]), len(ms[m[1]])))
    # the image_verify hit right after the first rescue_copy is the staged-copy verify
    i = next(k for k, o in enumerate(order) if o[0] == "rescue_copy")
    staged = next(o for o in order[i:] if o[0] == "image_verify")
    ms["staged_verify"] = [staged[1]]
    ms["staged_verify_hit"] = [staged[2]]
    flag_idx = None
    inst = []
    for line in res["rom_writes"]:
        m = re.match(r"(\d+) lr=0x([0-9A-F]+) dst=0x([0-9A-F]+)", line)
        if not m:
            continue
        i, lr, dst = int(m[1]), int(m[2], 16), int(m[3], 16)
        if dst == FLAG and MAIN_BASE <= lr < WISP_BOOT_END:
            flag_idx = i
        elif flag_idx is not None and MAIN_BASE <= dst < 0x7F8000:
            inst.append(i)
    return {"milestones": ms, "first_install_write": inst[0], "last_install_write": inst[-1],
            "case": case, "res": res, "ok": ok, "state": state, "detail": detail}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cache", type=Path, default=REPO / ".wisp-cache")
    ap.add_argument("--boot-build", type=Path, default=REPO / ".wisp-cache/build/wisp-boot")
    ap.add_argument("--stock-version", default=STOCK_VERSION,
                    help="stock bundle in <cache>/stock/ whose main app (and bootloader, with --bootloader stock) is used")
    ap.add_argument("--bootloader", choices=("stock", "patched"), default="stock",
                    help="stock: the bundle's own; patched: drdaeman's 87e2d4e0... (needs g2-2.3.2.14 in the cache)")
    ap.add_argument("--suite", choices=("fallback", "observe"), default="fallback",
                    help="fallback: the rescuing Wisp Boot (26 cases + the real app); observe: native-0's")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--reference-only", action="store_true", help="run only the reference case")
    args = ap.parse_args()
    h = Harness(args)
    rows = []
    if h.suite == "fallback":
        ref = reference_run(h)
        if args.reference_only:
            print(ref["state"], ref["detail"])
            print("\n".join(ref["res"]["milestones"]))
            return 0
        cases = base_cases() + cut_cases(ref) + (native_cases() if "real" in h.payloads else [])
        rows.append(("reference", ref["case"].title, ref["case"].expect, ref["ok"], ref["state"], ref["detail"]))
    else:
        cases = [c for c in observe_cases() if c.app in h.payloads]
    if args.list:
        for c in cases:
            print(c.name, "-", c.title)
        return 0
    if args.only:
        cases = [c for c in cases if c.name in args.only]
    for c in cases:
        t0 = time.time()
        res = h.run(c)
        ok, state, detail = h.check(c, res)
        rows.append((c.name, c.title, c.expect, ok, state, detail))
        print(f"{'PASS' if ok else 'FAIL'} {c.name}: {state} ({detail}, {time.time() - t0:.0f} s wall)", flush=True)
    table = [f"Wisp Boot `wisp_boot.bin` SHA-256 `{h.boot_sha}`, {args.bootloader} bootloader "
             f"`{hashlib.sha256(h.bootloader).hexdigest()}`, suite `{h.suite}`", "",
             "| Case | Fault | Expected | Result | End state | Run |", "| --- | --- | --- | --- | --- | --- |"]
    for name, title, exp, ok, state, detail in rows:
        table.append(f"| `{name}` | {title} | {exp} | {'pass' if ok else '**FAIL**'} | {state} | {detail} |")
    (h.work / "report.md").write_text("\n".join(table) + "\n")
    print("\n".join(table))
    return 0 if all(r[3] for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
