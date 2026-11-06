# SPDX-License-Identifier: MIT
"""What W18 does through a held loader session: claim, read-only checks, the INFO dump and the
stock main-app recovery. Every write goes through `write_app`, which only accepts the pinned
stock main image at 0x438000 (plus the bytes already there for the 16-byte tail unit).

The write order (body first, its CRC, then the 16 vector bytes, then the full CRC) and the
writer program are drdaeman's (tools/g2patch/recovery.py, src/examples/recover.c, MIT).
"""

from __future__ import annotations

import struct
import zlib

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
    def __init__(self, link, log=print):
        self.link = link
        self.log = log
        self.client: loader.Client | None = None
        self.claimed = False
        self.released = False
        self.step = "claim"  # what the session was doing, for the error report
        self.position: dict = {}  # the running write or read: target, bytes sent, bytes verified
        self.cleanup_errors: list[str] = []

    # --- claim and release [drdaeman link.py claim/continue_boot] ---
    def __enter__(self):
        beacon = self.link.start()
        challenge = loader.decode_hello(beacon)
        self.log(f"HELO from the patched loader (challenge {challenge:#010x})")
        response = self.link.exchange(loader.hold(challenge))
        try:
            loader.check_okay(response, challenge)
        except loader.LoaderError:
            # HOLD may have taken effect even though its acknowledgement is invalid.
            self.claimed = True
            self.release()
            raise
        self.claimed = True
        self.client = loader.Client(self._exchange)
        self.step = "held: read-only checks"
        self.log("boot held (OKAY verified)")
        return self

    def _exchange(self, frame: bytes) -> bytes:
        reply = self.link.exchange(frame)
        if reply[:12] == loader.hello(0)[:12]:
            self.released = True
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
        if self.claimed and not self.released:
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

    # --- read-only primitives ---
    def checksum(self, address: int, length: int) -> int:
        self.client.upload(image.program("checksum"), arg0=address, arg1=length)
        result, data = self.client.execute()
        if data:
            raise SessionError("unexpected checksum output")
        return result

    def dump(self, address: int, length: int, progress=None) -> bytes:
        self.client.upload(image.program("dump"), arg0=address, arg1=length)
        received = 0

        def counted(chunk: bytes) -> None:
            nonlocal received
            received += len(chunk)
            if progress:
                progress(received)

        result, data = self.client.execute(counted if progress else None)
        if result or len(data) != length:
            raise SessionError(f"memory read at {address:#x} failed or returned {len(data)} of {length} bytes")
        return data

    def bootloader_crc(self) -> int:
        return self.checksum(pins.BOOT_BASE, pins.PATCHED_BOOTLOADER_BYTES)

    def require_patched_bootloader(self, patched: bytes) -> None:
        crc = self.bootloader_crc()
        want = zlib.crc32(patched)
        self.log(f"bootloader region CRC-32 {crc:08x} (pinned image {want:08x})")
        if crc != want:
            raise SessionError("the bootloader in MRAM is not the pinned patched image; nothing written")

    def flag(self) -> int:
        return struct.unpack("<I", self.dump(FLAG, 4))[0]

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
    def _write(self, address: int, data: bytes, progress=None) -> None:
        end = address + len(data)
        if (address | len(data)) & 15 or not data:
            raise RefusedError("MRAM writes are 16-byte aligned and non-empty")
        if not pins.RECOVER_BASE <= address < end <= pins.RECOVER_END:
            raise RefusedError(f"write [{address:#x}, {end:#x}) is outside the stock main-app region")
        self.position = {"target": f"{address:#x}+{len(data)}", "sent": 0, "verified": 0}
        self.client.upload(image.program("recover"), arg0=address, arg1=len(data))
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
        if result or count != len(data) or at != len(data):
            raise SessionError(f"MRAM write/readback failed at {address:#x}: writer returned {result:#x}")

    def write_app(self, stock: bytes, progress=None) -> dict:
        """Write the pinned stock main image at 0x438000: body, CRC, vectors, CRC."""
        if image.sha(stock) != pins.STOCK_MAIN_SHA256:
            raise RefusedError("recover only writes the pinned stock 2.4.0.24 main image")
        size = pins.RECOVER_END - pins.RECOVER_BASE
        tail_at = pins.RECOVER_BASE + size - 16
        self.step = "read the image tail unit"
        tail = self.dump(tail_at, 16)  # keep whatever follows the image inside its last unit
        keep = len(stock) - (size - 16)
        target = stock + tail[keep:]
        self.step = "CRC of the app region before"
        before = self.checksum(pins.RECOVER_BASE, size)
        self.log(f"app region CRC-32 before: {before:08x} (stock {zlib.crc32(target):08x})")
        self.step = "RAM API v2 check"
        api = image.program("recover")
        self.client.upload(api)  # length 0 = API check only, programs nothing
        result, output = self.client.execute()
        if result or output:
            raise SessionError("the loader lacks RAM API v2 (recv); nothing written")
        self.step = "write the app body (vectors not yet written)"
        self._write(pins.RECOVER_BASE + 16, target[16:], progress)
        self.step = "CRC of the app body"
        body = self.checksum(pins.RECOVER_BASE + 16, size - 16)
        if body != zlib.crc32(target[16:]):
            raise SessionError("app body CRC mismatch; the vector table was NOT committed")
        self.step = "write the 16 vector bytes"
        self._write(pins.RECOVER_BASE, target[:16])
        self.step = "final CRC"
        final = self.checksum(pins.RECOVER_BASE, size)
        if final != zlib.crc32(target):
            raise SessionError("final app CRC mismatch")
        return {"crc_before": f"{before:08x}", "crc_after": f"{final:08x}", "bytes": size}
