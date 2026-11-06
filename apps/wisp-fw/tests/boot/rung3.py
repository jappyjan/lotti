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

Usage: rung3.py --cache .wisp-cache --boot-build .wisp-cache/build/wisp-boot [--only NAME...]
       [--list] [--keep]. Writes report.md (the table) into <cache>/rung3/<stock version>/.
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
    subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-D__ASSERT_ON=1", f"-I{lfs}",
                    f"-I{APP_DIR}/src/boot", str(HERE / "tools/wisp_lfs.c"), str(lfs / "lfs.c"),
                    str(lfs / "lfs_util.c"), "-o", str(out)], check=True)
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


def nm_symbols(elf: Path) -> dict[str, int]:
    out = subprocess.run(["arm-none-eabi-nm", str(elf)], check=True, capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3 and p[1] in "tT":
            syms[p[2]] = int(p[0], 16) & ~1
    return syms


# ---- cases ------------------------------------------------------------------------------------

@dataclass
class Case:
    name: str
    title: str
    app: str                          # native image variant: good/hang/crash_reset/crash_after/no_feed/erased
    expect: str                       # STOCK / WISP / SAFE
    rescue: str = "ok"                # ok / corrupt / missing
    flag_initially_set: bool = True   # the stock OTA path leaves 0x55555555 behind (hardware.md)
    record: str = "none"              # none / corrupt: initial wisp/boot.rec
    cut_nor_op: int | None = None     # absolute NOR op count (from the reference run)
    cut_milestone: tuple[str, int] | None = None
    cut_rom_write: int | None = None  # boot-ROM write index
    cut_after_flag: bool = False
    extra_cuts: int = 0               # WISP control: extra power cycles after the confirm
    budget: float = 400.0             # virtual seconds
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


class Harness:
    def __init__(self, args):
        self.cache = args.cache.resolve()
        self.build = args.boot_build.resolve()
        self.work = self.cache / "rung3" / args.stock_version
        self.work.mkdir(parents=True, exist_ok=True)
        self.keep = args.keep
        self.lfs = Lfs(build_lfs_tool(self.cache))
        self.bootloader, self.stock = stock_inputs(self.cache, args.stock_version)
        (self.work / "bootloader.bin").write_bytes(self.bootloader)
        self.syms = nm_symbols(self.build / "wisp_boot.elf")
        self.payloads = {}
        for app in ("good", "hang", "crash_reset", "crash_after", "no_feed", "erased"):
            self.payloads[app] = wisp_payload(self.build / f"native_{app}.bin", self.work)
        self.port = 21234

    # -- one run --
    def run(self, case: Case) -> dict:
        d = self.work / "runs" / case.name
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        payload = self.payloads[case.app]
        stock_rescue = bytearray(self.stock)
        if case.rescue == "corrupt":
            stock_rescue[len(stock_rescue) // 2] ^= 0x01
        files = {"ota/s200_firmware_ota.bin": payload}
        if case.rescue != "missing":
            files["wisp/rescue.bin"] = bytes(stock_rescue)
        if case.record == "corrupt":
            files["wisp/boot.rec"] = b"\x57\x49\x42\x54" + b"\x5a" * 12
        nor = d / "nor.bin"
        self.lfs.build(nor, files, d)
        (d / "native.bin").write_bytes(payload[32:])
        flag = FLAG_SET if case.flag_initially_set else FLAG_CLEAR

        self.port += 1
        r = Renode(d, self.port)
        try:
            r.cmd(f"include @{APP_DIR}/renode/boot.resc")
            r.cmd(f"nor LoadImage @{nor}")
            r.cmd(f"sysbus LoadBinary @{self.work / 'bootloader.bin'} 0x410000")
            r.cmd(f"sysbus LoadBinary @{d / 'native.bin'} 0x438000")   # Wisp, as installed
            for i, w in enumerate(flag):
                r.cmd(f"sysbus WriteDoubleWord {FLAG + 4 * i:#x} {w:#x}")
            for name in ("wisp_boot_main", "rescue_copy", "image_verify", "hw_flag_set_install", "hw_jump"):
                if name in self.syms:
                    r.cmd(f'probe Milestone {self.syms[name]:#x} "{name}"')
            if case.cut_nor_op is not None:
                r.cmd(f"probe CutAtNorOp {case.cut_nor_op}")
            if case.cut_milestone:
                r.cmd(f'probe CutAtMilestone "{case.cut_milestone[0]}" {case.cut_milestone[1]}')
            if case.cut_rom_write is not None:
                r.cmd(f"bootrom CutAfterWriteIndex {case.cut_rom_write}")
            if case.cut_after_flag:
                r.cmd(f"bootrom CutAfterWritesTo {FLAG:#x}")
            # Cold start: the SBL's hand-off into the bootloader (WispRstGen does the same on
            # every later reset).
            sp, pc = struct.unpack_from("<II", self.bootloader, 0)
            r.cmd("cpu VectorTableOffset 0x410000")
            r.cmd(f"cpu SP {sp:#x}")
            r.cmd(f"cpu PC {pc & ~1:#x}")
            res = self.drive(r, case, d)
            res["mram"] = self.dump(r, d)
            res["rom_writes"] = r.cmd("bootrom WriteLog").splitlines()
            res["resets"] = r.cmd("rstgen ResetLog").splitlines()
            res["milestones"] = r.cmd("probe Report").splitlines()
            res["wdt_bites"] = int(r.cmd("wdt Bites") or "0", 0)
            r.cmd(f"nor SaveImage @{d / 'nor-after.bin'}")
        finally:
            r.close()
        res["uart"] = (d / "uart1.txt").read_text(errors="replace") if (d / "uart1.txt").exists() else ""
        res["staging"] = self.lfs.get(d / "nor-after.bin", "ota/s200_firmware_ota.bin", d)
        return res

    def dump(self, r: Renode, d: Path) -> bytes:
        out = d / "mram.bin"
        r.cmd(f"probe Dump 0x400000 0x400000 @{out}")
        return out.read_bytes()

    def drive(self, r: Renode, case: Case, d: Path) -> dict:
        uart = d / "uart1.txt"
        t = 0.0
        step = 2.0
        cuts_done = 0
        while t < case.budget:
            r.cmd(f'emulation RunFor "{step}"')
            t += step
            text = uart.read_text(errors="replace") if uart.exists() else ""
            if case.expect == "STOCK":
                jumps = [m.end() for m in JUMP_RE.finditer(text)]
                if jumps and STOCK_MARK in text[jumps[-1]:] and "wisp-boot" not in text[jumps[-1]:]:
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
        return {"virtual_s": t}

    # -- assertions --
    def check(self, case: Case, res: dict) -> tuple[bool, str]:
        mram, uart = res["mram"], res["uart"]
        fails = []
        bl_end = 0x410000 + len(self.bootloader)
        if mram[0x10000:bl_end - 0x400000] != self.bootloader:
            fails.append("bootloader region changed")
        flag = list(struct.unpack_from("<4I", mram, FLAG - 0x400000))
        wisp_writes = []
        for line in res["rom_writes"]:
            m = re.search(r"lr=0x([0-9A-F]+) dst=0x([0-9A-F]+) words=(\d+) first=0x([0-9A-F]+)", line)
            if not m:
                continue
            lr, dst, n, first = int(m[1], 16), int(m[2], 16), int(m[3]), int(m[4], 16)
            if MAIN_BASE <= lr < WISP_BOOT_END + 0x10000:
                wisp_writes.append((dst, n, first))
            elif not (dst == FLAG and n == 4) and not (MAIN_BASE <= dst < 0x7F8000):
                fails.append(f"bootloader wrote MRAM outside app/flag: {line}")
        bad = [w for w in wisp_writes if w != (FLAG, 4, 0x55555555)]
        if bad:
            fails.append(f"Wisp code wrote MRAM other than the flag: {bad}")
        boots = uart.count("wisp-boot: start")
        detail = f"{len(res['resets'])} resets, {boots} Wisp Boot runs, {res['wdt_bites']} WDT bites, {res['virtual_s']:.0f} s virtual"
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
            how = "Wisp Boot set the flag" if wisp_writes else "flag left set by the install"
            state = f"stock running; {how}"
        elif case.expect == "WISP":
            if wisp_writes:
                fails.append("Wisp Boot wrote the flag in the control case")
            if uart.count("wisp-app: boot confirmed") < case.extra_cuts + 1:
                fails.append("app did not confirm every boot")
            state = "Wisp app running, confirmed"
        else:
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
                    help="stock bundle in <cache>/stock/ whose bootloader and main app are used")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--reference-only", action="store_true", help="run only the reference case")
    args = ap.parse_args()
    h = Harness(args)
    ref = reference_run(h)
    if args.reference_only:
        print(ref["state"], ref["detail"])
        print("\n".join(ref["res"]["milestones"]))
        return 0
    cases = base_cases() + cut_cases(ref)
    if args.list:
        for c in cases:
            print(c.name, "-", c.title)
        return 0
    if args.only:
        cases = [c for c in cases if c.name in args.only]
    rows = [("reference", ref["case"].title, ref["case"].expect, ref["ok"], ref["state"], ref["detail"])]
    for c in cases:
        t0 = time.time()
        res = h.run(c)
        ok, state, detail = h.check(c, res)
        rows.append((c.name, c.title, c.expect, ok, state, detail))
        print(f"{'PASS' if ok else 'FAIL'} {c.name}: {state} ({detail}, {time.time() - t0:.0f} s wall)", flush=True)
    table = ["| Case | Fault | Expected | Result | End state | Run |", "| --- | --- | --- | --- | --- | --- |"]
    for name, title, exp, ok, state, detail in rows:
        table.append(f"| `{name}` | {title} | {exp} | {'pass' if ok else '**FAIL**'} | {state} | {detail} |")
    (h.work / "report.md").write_text("\n".join(table) + "\n")
    print("\n".join(table))
    return 0 if all(r[3] for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
