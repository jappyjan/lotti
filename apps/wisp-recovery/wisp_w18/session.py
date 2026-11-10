# SPDX-License-Identifier: MIT
"""What W18 does through a held loader session: claim, read-only checks, the INFO dump and the
main-app writes. Every write goes through `AppWriter`, which takes an `AppImage`: the pinned stock
main image (`recover`) or a pinned Wisp image (`install-wisp`, wisp_w18/native.py), each with its
end bound, at 0x438000 (plus the bytes already there for the 16-byte tail unit).

The write order is drdaeman's (tools/g2patch/recovery.py, src/examples/recover.c, MIT), with one
change from rung4.md (R4-1): the 16 vector bytes are zeroed first, then the body, its CRC, the
vectors, the full CRC. An interrupted write then leaves vectors the bootloader refuses to hand
off to, not a mix of old vectors and new code. The writer program is drdaeman's.

`AppWriter` splits that write over as many held sessions as a session-time budget needs: each
session CRC-checks the body written so far before it adds a part, and the vectors are written only
after a CRC of the whole body, in a session that verified it.

With `temple_feed`, the session keeps the temple's nPM1300 watchdog fed (recovery.md, "The
temple's watchdog"): once the bootloader's CRC has been checked, `feed.bin` kicks it, again before
every program that does not kick it itself (`checksum`), and the streams use `dump_fed` and
`recover_fed`, which kick it at most once a second while they run. Without it, the PMIC resets the
temple about 30 s after the stock app's last kick, so a session must end before that.
"""

from __future__ import annotations

import struct
import time
import zlib
from dataclasses import dataclass
from typing import Callable

from . import image, loader, pins

FLAG = 0x007F_E000
BLOCK = 256  # recover.bin's RAM block: one progress report per 256 programmed bytes


class SessionError(RuntimeError):
    pass


class RefusedError(SessionError):
    """The tool refused to send something outside the W18 allowlist."""


class TempleReset(SessionError):
    """A HELO arrived where a reply was expected: the temple rebooted (power cut, reset) in the
    middle of the session. Its loader is in a fresh boot window, so there is nothing to release;
    a new session must claim it again."""


class Session:
    def __init__(self, link, log=print, clock=None, temple_feed=False):
        self.link = link
        self.log = log
        self.temple_feed = temple_feed
        # `hold`: end the session without CONTINUE, leaving the temple held in its loader (the
        # held-temple reset test, rung4.md W21; `loader-hello --no-release`). Only a session that
        # ends without an error keeps it held; after an error the cleanup releases as always.
        self.hold = False
        self.last_kick: float | None = None  # clock time a program that kicks the PMIC last started
        self.hello_at: float | None = None  # clock time the loader's HELO arrived (after the relay's reset)
        self.bootloader_verified = False  # the feeding programs call into it: only after its CRC
        self.feeds = 0  # feed.bin runs in this session
        self.temple_reset_s: float | None = None  # when a HELO came mid-session, s since the relay start
        self.client: loader.Client | None = None
        self.claimed = False
        self.released = False
        self.step = "claim"  # what the session was doing, for the error report
        self.position: dict = {}  # the running write or read: target, bytes sent, bytes verified
        self.cleanup_errors: list[str] = []
        recent = getattr(link, "recent", None)
        self.clock = clock or (recent.clock if recent is not None else time.monotonic)
        self.started: float | None = None

    def elapsed(self) -> float:
        """Seconds since the relay started (the case left its own firmware for our SRAM code), or
        since the session started on a link without a case."""
        return self.clock() - self.started if self.started is not None else 0.0

    # --- claim and release [drdaeman link.py claim/continue_boot] ---
    def __enter__(self):
        """Start the link and claim the loader. If anything here fails, `__exit__` never runs, so
        the same cleanup runs before the error propagates: a case whose relay start or claim
        failed is still put back in its own firmware."""
        try:
            self._claim()
        except BaseException as error:
            self.__exit__(type(error), error, error.__traceback__)
            raise
        return self

    def _claim(self) -> None:
        self.started = self.clock()
        beacon = self.link.start()
        self.hello_at = self.clock()
        self.started = getattr(self.link, "relay_started", None) or self.started
        challenge = loader.decode_hello(beacon)
        self.log(f"HELO from the patched loader (challenge {challenge:#010x})")
        response = self.link.exchange(loader.hold(challenge))
        # HOLD may have taken effect even though its acknowledgement is invalid: release then.
        self.claimed = True
        loader.check_okay(response, challenge)
        self.client = loader.Client(self._exchange)
        self.step = "held: read-only checks"
        self.log("boot held (OKAY verified)")

    def _exchange(self, frame: bytes) -> bytes:
        reply = self.link.exchange(frame)
        if reply[:12] == loader.hello(0)[:12]:
            self.released = True
            self.temple_reset_s = round(self.elapsed(), 3)
            raise TempleReset(f"temple rebooted mid-session (HELO {reply.hex()})")
        return reply

    def release(self) -> None:
        """CONTINUE up to three times, advancing only on valid replies [drdaeman]."""
        for _ in range(3):
            actual = self.link.exchange(loader.cont())
            if actual == loader.released():
                self.released = True
                self.log("boot released (RLSD)")
                return
            loader.decode_reply(actual)
        raise SessionError("boot release unconfirmed after three CONTINUE exchanges")

    def __exit__(self, kind, error, traceback):
        """Release, then close the link, whatever happened. A cleanup failure never replaces the
        error that ended the session: that one propagates, the cleanup failures are attached to
        it (a note, and `cleanup_errors`). Without an earlier error, a cleanup failure raises."""
        failures = []
        if self.claimed and not self.released and (error is not None or not self.hold):
            try:
                self.release()
            except Exception as caught:  # noqa: BLE001 - reported below
                failures.append(caught)
        try:
            self.link.close()
        except Exception as caught:  # noqa: BLE001
            failures.append(caught)
        self.cleanup_errors = [repr(f) for f in failures]
        if error is not None:
            for failure in failures:
                error.add_note(f"cleanup after this error also failed: {failure!r}")
            return False
        if len(failures) == 1:
            raise failures[0]
        if failures:
            raise SessionError("cleanup failed: " + "; ".join(self.cleanup_errors)) from failures[0]
        return False

    # --- the temple's watchdog ---
    @property
    def feeding(self) -> bool:
        return self.temple_feed and self.bootloader_verified

    def feed(self) -> None:
        """One kick of the temple's nPM1300 watchdog (feed.bin). A failed kick stops the session:
        the watchdog would reset the temple within 30 s, so nothing more is started."""
        if not self.bootloader_verified:
            raise RefusedError("feed.bin calls into the bootloader; its CRC must be checked first")
        step, self.step = self.step, "feed the temple watchdog"
        self.client.upload(image.program("feed"))
        self.last_kick = self.clock()
        result, data = self.client.execute()
        self.feeds += 1
        if result or data:
            raise SessionError(f"temple watchdog feed failed: feed.bin status {result:#x} (pmic_kick.h codes); "
                               "nothing more runs in this session. Without the feed (--no-temple-feed) a session "
                               "must end within about 25 s of the relay start (--max-session-s 20)")
        self.step = step

    # --- read-only primitives ---
    def checksum(self, address: int, length: int) -> int:
        if self.feeding:
            self.feed()
        self.client.upload(image.program("checksum"), arg0=address, arg1=length)
        result, data = self.client.execute()
        if data:
            raise SessionError("unexpected checksum output")
        return result

    def dump(self, address: int, length: int, progress=None) -> bytes:
        self.client.upload(image.program("dump_fed" if self.feeding else "dump"), arg0=address, arg1=length)
        if self.feeding:
            self.last_kick = self.clock()  # dump_fed kicks before its first frame
        received = 0

        def counted(chunk: bytes) -> None:
            nonlocal received
            received += len(chunk)
            if progress:
                progress(received)

        result, data = self.client.execute(counted if progress else None)
        if result == 2 and self.feeding:
            raise SessionError(f"temple watchdog feed failed during the read at {address:#x} (dump_fed.bin "
                               f"result 2: IOM7 could not be powered for a kick); stopped after {received} bytes")
        if result or len(data) != length:
            raise SessionError(f"memory read at {address:#x} failed or returned {len(data)} of {length} bytes")
        return data

    def idle_until(self, seconds: float) -> list[float]:
        """Keep the case relay running without temple traffic until `seconds` after it started:
        empty G2TX frames, each answered by the relay after its own poll bound (status 2, no
        temple frame). Read-only; the held loader just keeps waiting. Returns each one's time."""
        ticks = []
        while self.elapsed() < seconds:
            if self.feeding:  # an empty G2TX keeps the temple silent for the relay's poll bound
                self.feed()
            self.step = f"idle pause: {self.elapsed():.1f} of {seconds:g} s since the relay started"
            status, frame, took = self.link.idle()
            ticks.append(round(took, 3))
            if frame[:12] == loader.hello(0)[:12]:
                self.released = True
                self.temple_reset_s = round(self.elapsed(), 3)
                raise TempleReset(f"temple rebooted during the idle pause (HELO {frame.hex()})")
            if status != 2 or frame:
                raise SessionError(f"unexpected answer to an empty G2TX: status {status}, frame {frame.hex()}")
            self.log(f"idle: relay answered after {took:.1f} s (t = {self.elapsed():.1f} s since the relay started)")
        return ticks

    def bootloader_crc(self) -> int:
        return self.checksum(pins.BOOT_BASE, pins.PATCHED_BOOTLOADER_BYTES)

    def require_patched_bootloader(self, patched: bytes) -> None:
        crc = self.bootloader_crc()
        want = zlib.crc32(patched)
        self.log(f"bootloader region CRC-32 {crc:08x} (pinned image {want:08x})")
        if crc != want:
            raise SessionError("the bootloader in MRAM is not the pinned patched image; nothing written")
        self.bootloader_verified = True
        if self.temple_feed:
            self.feed()  # the first kick, and the proof that the feed works before anything long runs

    def flag(self) -> int:
        return struct.unpack("<I", self.dump(FLAG, 4))[0]

    # --- allowlisted reads (rung4.md §4, G3) ---
    def peek(self, name: str) -> bytes:
        """One region of pins.PEEK_REGIONS (the patched bootloader's RAM and MRAM), read with
        dump/dump_fed. Anything else is refused before a byte goes to the temple."""
        if name not in pins.PEEK_REGIONS:
            raise RefusedError(f"peek {name!r} is not in pins.PEEK_REGIONS; nothing read")
        if not self.bootloader_verified:
            raise RefusedError("peek reads the patched bootloader's RAM; its CRC must be checked first")
        if name in pins.PEEK_SSRAM_GATED:
            address, length, _what = pins.PEEK_REGIONS["ssram-power"]
            powered = struct.unpack("<I", self.dump(address, length))[0]
            if not powered & pins.PEEK_SSRAM_GROUP2:
                raise RefusedError(f"peek {name}: PWRCTRL.SSRAMPWRST = {powered:#x}, SSRAM group 2 is not powered "
                                   "in the held loader; not read (nothing of the last boot's record is left)")
        address, length, _what = pins.PEEK_REGIONS[name]
        return self.dump(address, length)

    def pmic_read(self) -> dict[int, int]:
        """The nPM1300 snapshot (pmic_read.bin): one kick, then the registers of
        pins.PMIC_READ_REGISTERS, each by one I2C write-read. Returns {address: value}."""
        if not self.bootloader_verified:
            raise RefusedError("pmic_read.bin calls into the bootloader; its CRC must be checked first")
        step, self.step = self.step, "pmic_read: nPM1300 register snapshot"
        self.client.upload(image.program("pmic_read"))
        self.last_kick = self.clock()
        result, data = self.client.execute()
        if result:
            raise SessionError(f"pmic_read.bin failed: {describe_pmic_read(result)}; nothing more runs in this session")
        if len(data) != len(pins.PMIC_READ_REGISTERS):
            raise SessionError(f"pmic_read.bin sent {len(data)} bytes, expected {len(pins.PMIC_READ_REGISTERS)}")
        self.step = step
        return {address: value for (address, _name, _kind), value in zip(pins.PMIC_READ_REGISTERS, data)}

    def charge_on(self) -> dict[int, int]:
        """charge_on.bin: one kick, then the stock charger settings and charging on
        (pins.CHARGE_ON_WRITES); then pmic_read.bin reads every register back. Returns its snapshot."""
        if not self.bootloader_verified:
            raise RefusedError("charge_on.bin calls into the bootloader; its CRC must be checked first")
        step, self.step = self.step, "charge_on: stock charger settings, charging on"
        self.client.upload(image.program("charge_on"))
        self.last_kick = self.clock()
        result, data = self.client.execute()
        if result:
            raise SessionError(f"charge_on.bin failed: {describe_charge_on(result)}; nothing more runs in this session")
        if data:
            raise SessionError(f"charge_on.bin sent {len(data)} bytes, expected none")
        self.step = step
        return self.pmic_read()

    # --- INFO / debug-lock dump (reads only; each read gated on what the previous ones said) ---
    def info_dump(self) -> dict:
        out: dict = {}
        mcuctrl = {name: struct.unpack("<I", self.dump(0x4002_0000 + off, 4))[0]
                   for name, off in (("CHIPPN", 0x00), ("CHIPREV", 0x0C), ("DEBUGGER", 0x20),
                                     ("BOOTLOADER", 0x1B8), ("SHADOWVALID", 0x1BC))}
        out["mcuctrl"] = {k: f"{v:#010x}" for k, v in mcuctrl.items()}
        pwr_en, pwr_status = struct.unpack("<II", self.dump(0x4002_1004, 8))
        out["pwrctrl"] = {"DEVPWREN": f"{pwr_en:#010x}", "DEVPWRSTATUS": f"{pwr_status:#010x}"}
        otp_on = bool(pwr_status >> 27 & 1)
        crypto_on = bool(pwr_status >> 21 & 1)
        info0_in_otp = bool(mcuctrl["SHADOWVALID"] >> 4 & 1)
        if not info0_in_otp:
            out["info0"] = {"where": "MRAM 0x42000000", "hex": self.dump(0x4200_0000, 2048).hex()}
        elif otp_on:
            out["info0"] = {"where": "OTP 0x42004000", "hex": self.dump(0x4200_4000, 256).hex()}
        else:
            out["info0"] = {"skipped": "INFO0 is in OTP and OTP is powered off (no power-up from this tool)"}
        if otp_on:
            out["infoc"] = {"where": "OTP 0x400C2000", "hex": self.dump(0x400C_2000, 1024).hex()}
        else:
            out["infoc"] = {"skipped": "OTP is powered off (DEVPWRSTATUS bit 27 = 0)"}
        if crypto_on:
            words = struct.unpack("<8I", self.dump(0x400C_1E00, 32))
            lcs = struct.unpack("<I", self.dump(0x400C_1F14, 4))[0]
            out["dcu"] = {"HOSTDCUEN0-3": [f"{w:#010x}" for w in words[:4]],
                          "HOSTDCULOCK0-3": [f"{w:#010x}" for w in words[4:]],
                          "LCSREG": f"{lcs:#010x}"}
        else:
            out["dcu"] = {"skipped": "CRYPTO is powered off (DEVPWRSTATUS bit 21 = 0)"}
        return out

    # --- the one write path ---
    def _write(self, address: int, data: bytes, bound: int, progress=None) -> None:
        """Write `data` at `address`, inside [0x438000, bound). `bound` is the end of the image
        being written (`AppImage.end`), never past the app ceiling 0x7F8000."""
        end = address + len(data)
        if (address | len(data)) & 15 or not data:
            raise RefusedError("MRAM writes are 16-byte aligned and non-empty")
        if bound & 15 or not pins.APP_BASE < bound <= pins.APP_END_CEILING:
            raise RefusedError(f"end bound {bound:#x} is outside the main-app region")
        if not pins.APP_BASE <= address < end <= bound:
            raise RefusedError(f"write [{address:#x}, {end:#x}) is outside the image's region [{pins.APP_BASE:#x}, {bound:#x})")
        self.position = {"target": f"{address:#x}+{len(data)}", "sent": 0, "verified": 0}
        self.client.upload(image.program(self.writer), arg0=address, arg1=len(data))
        if self.writer == "recover_fed":
            self.last_kick = self.clock()
        count = 0

        def checked(chunk: bytes) -> None:
            nonlocal count
            if len(chunk) != 4:
                raise SessionError("invalid writer progress")
            actual = struct.unpack("<I", chunk)[0]
            if actual != min(count + BLOCK, len(data)):
                raise SessionError("unexpected writer progress")
            count = actual
            self.position["verified"] = count
            if progress:
                progress(count)

        at = 0

        def source(capacity: int) -> bytes:
            nonlocal at
            chunk = data[at : at + capacity]
            at += len(chunk)
            self.position["sent"] = at
            return chunk

        result, _output = self.client.execute(checked, source=source)
        if result == 6 and self.writer == "recover_fed":
            raise SessionError(f"temple watchdog feed failed during the write at {address:#x} (recover_fed.bin "
                               f"result 6: IOM7 could not be powered for a kick); stopped cleanly after "
                               f"{count} verified bytes, vectors not written")
        if result or count != len(data) or at != len(data):
            raise SessionError(f"MRAM write/readback failed at {address:#x}: writer returned {result:#x}")

    @property
    def writer(self) -> str:
        """The MRAM writer: recover.bin, or recover_fed.bin while the temple watchdog is fed."""
        return "recover_fed" if self.feeding else "recover"

    def write_app(self, stock: bytes, progress=None) -> dict:
        """Write the pinned stock main image at 0x438000 in this one session: vectors zeroed,
        body, CRC, vectors, CRC. (`AppWriter` with a budget splits the same write over several
        sessions.)"""
        writer = AppWriter(stock, log=self.log)
        writer.run(self, progress=progress)
        return writer.result


def describe_charge_on(result: int) -> str:
    """charge_on.bin's result code in words (programs/charge_on.c): pmic_read's codes, with write
    k >= 1 being pins.CHARGE_ON_WRITES[k - 1] (0 is the kick)."""
    index = result >> 24
    if index == 0:
        where = "the watchdog kick"
    elif index <= len(pins.CHARGE_ON_WRITES):
        address, value, name = pins.CHARGE_ON_WRITES[index - 1]
        where = f"the write {name} ({address:#06x}) = {value:#04x}"
    else:
        where = f"write {index}"
    words = describe_pmic_read(result if result == 0x10 or result >> 8 in (1, 6) else result & 0xFFFFFF)
    # charge_on.c only waits for IOM7 idle (no receive FIFO), and its power-down follows writes
    return (words.replace("the watchdog kick", where).replace(" or receive FIFO not empty", "")
            .replace("after the reads", "after the writes"))


def describe_pmic_read(result: int) -> str:
    """pmic_read.bin's result code in words (programs/pmic_read.c)."""
    if result == 1:
        return "the send to the host failed"
    if result == 0x10:
        return "status 0x10: the I2C table is not the pinned bootloader's (nothing called)"
    if result >> 8 == 1:
        return f"status {result:#x}: IOM7 power-up refused (HAL status {result & 0xFF})"
    if result >> 8 == 6:
        return f"status {result:#x}: IOM7 power-down refused after the reads (HAL status {result & 0xFF})"
    index, code = result >> 24, result & 0xFFFFFF
    what = {0x200: "IOM7 not idle or receive FIFO not empty", 0x300: "no room in the write FIFO",
            0x400: "no completion", 0x800: "no byte received"}.get(code)
    if what is None and code >> 16 == 5:
        what = f"I2C error, INTSTAT {code & 0xFFFF:#x}" + (" (NAK)" if code & 0x10 else "")
    if index == 0:
        where = "the watchdog kick"
    elif index <= len(pins.PMIC_READ_REGISTERS):
        address, name, _kind = pins.PMIC_READ_REGISTERS[index - 1]
        where = f"the read of {name} ({address:#06x})"
    else:
        where = f"transfer {index}"
    return f"status {result:#x}: {where} failed: {what or 'unknown code'}"


ZERO_VECTORS = bytes(16)


@dataclass(frozen=True)
class AppImage:
    """What an AppWriter may write: the image's bytes, the pin they must hash to, the end bound
    of every write (the image's own end, rounded up to the 16-byte unit), and `check`, rerun on
    the exact bytes the writer is about to send, before the first write of every run."""

    name: str
    data: bytes
    sha256: str
    end: int
    check: Callable[[bytes], object] | None = None

    def __post_init__(self):
        # The writer's own gate, whatever the caller checked: the stock pin, or a Wisp image
        # pinned in pins.WISP_IMAGES once R4-1 is approved (safety.md rule 1; rung4.md R4-1).
        wisp = pins.R4_1_APPROVED and any(p["image_sha256"] == self.sha256 for p in pins.WISP_IMAGES.values())
        if self.sha256 != pins.STOCK_MAIN_SHA256 and not wisp:
            raise RefusedError(f"{self.name}: {self.sha256[:16]}... is neither the stock pin nor a pinned Wisp image "
                               "(R4-1 not approved, or not in pins.WISP_IMAGES); nothing written")
        if image.sha(self.data) != self.sha256:
            raise RefusedError(f"{self.name}: the image is not the pinned one ({image.sha(self.data)[:16]}...)")
        if self.end != pins.APP_BASE + ((len(self.data) + 15) & ~15) or self.end > pins.APP_END_CEILING:
            raise RefusedError(f"{self.name}: end bound {self.end:#x} does not match the image or passes 0x7F8000")


def stock_image(stock: bytes) -> AppImage:
    """recover's image: only the pinned stock 2.4.0.24 main, bounded by its own length."""
    if image.sha(stock) != pins.STOCK_MAIN_SHA256:
        raise RefusedError("recover only writes the pinned stock 2.4.0.24 main image")
    return AppImage(f"stock {pins.STOCK_MAIN_VERSION} main", stock, pins.STOCK_MAIN_SHA256, pins.RECOVER_END)


class AppWriter:
    """A main-app image write (recover: the pinned stock image; install-wisp: a pinned Wisp
    image), over one or more held sessions.

    Before the first body byte, the 16 vector bytes at 0x438000 are zeroed (unless they already
    read zero, as after an earlier interrupted run). Every session that continues the write first
    CRC-checks the body written so far against the image (the resume check); a mismatch stops
    before anything else is written. The body goes in parts at 0x438010+; the real vectors are
    written only once the whole body has been CRC-checked in the same session, and never in any
    part. Interrupted at any point after the zeroing, the vectors in MRAM are zero, so the
    bootloader refuses the hand-off (the patched loader still runs first) instead of jumping into
    a mix of old vectors and new code.

    `run(session)` does one session's share and returns True when the image is complete. With
    `budget` (seconds since the relay started), it sizes the part to end inside the budget and
    leaves the vectors to a fresh session; without it, it writes everything in one go.
    """

    FIRST_RATE = 1.5e-3  # s per body byte before any part was measured (hardware: ~1.2 ms)
    FIRST_PART = 4096  # bytes, until a rate is measured
    RESERVE = 1.5  # s kept for the part's CRC, the release and the relay exit

    def __init__(self, app: AppImage | bytes, budget: float | None = None, resume_at: int = 0, log=print):
        self.app = app if isinstance(app, AppImage) else stock_image(app)
        self.stock = self.app.data  # the image's bytes (the name predates install-wisp)
        self.budget = budget
        self.log = log
        self.size = self.app.end - pins.APP_BASE
        self.body_base = pins.APP_BASE + 16
        self.body_len = self.size - 16
        if resume_at % 16 or not 0 <= resume_at <= self.body_len:
            raise RefusedError(f"--resume-at must be a multiple of 16 in [0, {self.body_len}]")
        self.done = resume_at  # body bytes written and CRC-verified (by this run or, with
        self.resumed_at = resume_at  # --resume-at, by an earlier one: checked before any write)
        self.target: bytes | None = None
        self.vectors_zeroed = False  # zero in MRAM: read back so, or written so by this run
        self.rate = self.FIRST_RATE
        self.measured = False
        self.sessions = 0
        self.result: dict = {}

    def _prepare(self, s: Session) -> None:
        s.step = "read the image tail unit"
        tail = s.dump(pins.APP_BASE + self.size - 16, 16)  # keep what follows the image in its last unit
        keep = len(self.stock) - (self.size - 16)
        target = self.stock + tail[keep:]
        # The checks run on the buffer the writer streams from, not on the file it came from.
        sent = target[: len(self.stock)]
        if image.sha(sent) != self.app.sha256 or len(target) != self.size:
            raise RefusedError(f"{self.app.name}: the bytes to send are not the pinned image; nothing written")
        if self.app.check is not None:
            s.step = "rule-3 checks on the bytes to send"
            self.result["checks"] = self.app.check(sent)
        self.target = target
        s.step = "CRC of the app region before"
        before = s.checksum(pins.APP_BASE, self.size)
        self.result["crc_before"] = f"{before:08x}"
        self.log(f"app region CRC-32 before: {before:08x} ({self.app.name} {zlib.crc32(self.target):08x})")
        s.step = "RAM API v2 check"
        s.client.upload(image.program(s.writer))  # length 0 = API check only, programs nothing
        result, output = s.client.execute()
        if result or output:
            raise SessionError("the loader lacks RAM API v2 (recv); nothing written")

    def _zero_vectors(self, s: Session) -> None:
        """Zero the 16 vector bytes before the first body byte of this run (R4-1)."""
        s.step = "read the vector bytes"
        if s.dump(pins.APP_BASE, 16) != ZERO_VECTORS:
            s.step = "zero the 16 vector bytes (before the body)"
            s._write(pins.APP_BASE, ZERO_VECTORS, self.app.end)
            if s.checksum(pins.APP_BASE, 16) != zlib.crc32(ZERO_VECTORS):
                raise SessionError("the zeroed vectors did not read back as zero; nothing else written")
            self.result["vectors_zeroed"] = True
            self.log("vectors zeroed: the bootloader refuses the hand-off until the write completes")
        else:
            self.result.setdefault("vectors_zeroed", False)  # already zero
        self.vectors_zeroed = True

    def _body_crc(self, s: Session, length: int) -> int:
        return s.checksum(self.body_base, length)

    def _part(self, s: Session) -> int:
        remaining = self.body_len - self.done
        if self.budget is None:
            return remaining
        room = self.budget - s.elapsed() - self.RESERVE
        n = int(room / self.rate) // BLOCK * BLOCK
        if not self.measured:
            n = min(n, self.FIRST_PART)
        n = min(n, remaining)
        if n < min(BLOCK, remaining):
            raise SessionError(f"the session's checks used {s.elapsed():.1f} s of the {self.budget:g} s budget; "
                               f"no room for a part (raise --max-session-s); nothing written in this session")
        return n

    def run(self, s: Session, progress=None) -> bool:
        self.sessions += 1
        if self.target is None:
            self._prepare(s)
        target = self.target
        if self.done:
            s.step = f"resume check: CRC of the body written so far ({self.done} bytes)"
            s.position = {"verified_body": self.done}
            crc = self._body_crc(s, self.done)
            want = zlib.crc32(target[16 : 16 + self.done])
            if crc != want:
                raise SessionError(f"resume check failed: body [{self.body_base:#x}, +{self.done}) CRC {crc:08x} != "
                                   f"image {want:08x}; nothing written in this session, vectors untouched")
            self.log(f"resume check: {self.done} body bytes already in MRAM match the image ({crc:08x})")
        if self.done < self.body_len:
            if not self.vectors_zeroed:
                self._zero_vectors(s)
            n = self._part(s)
            at = self.done
            s.step = "write the app body (vectors not yet written)"
            started = s.clock()

            def offset(count: int) -> None:
                if progress:
                    progress(at + count)

            s._write(self.body_base + at, target[16 + at : 16 + at + n], self.app.end, offset)
            took = s.clock() - started
            if n >= BLOCK and took > 0:  # size later parts by the slowest rate seen so far
                self.rate = max(self.rate, took / n) if self.measured else took / n
                self.measured = True
            if at == 0 and n == self.body_len:
                s.step = "CRC of the app body"
                if self._body_crc(s, n) != zlib.crc32(target[16:]):
                    raise SessionError("app body CRC mismatch; the vector table was NOT committed")
                self.done = n
                if self.budget is not None:
                    return False  # vectors in a fresh session, after its own whole-body check
            else:
                s.step = f"CRC of the part just written [{self.body_base + at:#x}, +{n})"
                crc = s.checksum(self.body_base + at, n)
                if crc != zlib.crc32(target[16 + at : 16 + at + n]):
                    raise SessionError(f"part CRC mismatch at {self.body_base + at:#x}+{n}; vectors NOT written")
                self.done = at + n
                self.log(f"part verified: body {self.done}/{self.body_len} bytes")
                if self.budget is not None or self.done < self.body_len:
                    return False  # the vectors wait for a session that CRC-checks the whole body first
                s.step = "CRC of the app body"
                if self._body_crc(s, self.body_len) != zlib.crc32(target[16:]):
                    raise SessionError("app body CRC mismatch; the vector table was NOT committed")
        # Here the whole body was CRC-checked in this session (the resume check or the step above).
        s.step = "write the 16 vector bytes"
        s._write(pins.APP_BASE, target[:16], self.app.end)
        s.step = "final CRC"
        final = s.checksum(pins.APP_BASE, self.size)
        if final != zlib.crc32(target):
            raise SessionError("final app CRC mismatch")
        self.result.update({"crc_after": f"{final:08x}", "bytes": self.size})
        return True
