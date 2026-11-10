// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: plain register storage that remembers what was written and can log
// every access with the guest PC. Used for the peripheral ranges no Wisp model covers yet, so a
// stall in the stock bootloader shows which register it is polling.
//
//   trace: 0 = silent, 1 = log the first read and first write of each offset, 2 = log everything
//   baseAddress: the window's bus address, for the strict record (WispStrict, below)
//
// Also here: WispStrict, the strict start-up record (rung4.md, "W24 result and analysis", Renode
// changes), and the spies on g2emu's PWRCTRL and CLKGEN stubs. W24's native-0 passed every Renode
// case but reboot-looped on silicon, and Renode runs everything without a model as "reads 0,
// writes ignored", so the Ambiq start-up (trims, the SIMO buck, the clock manager) "succeeded" by
// construction. In strict mode every access Wisp code makes to such a register is recorded with
// its PC, and the harness fails a native case on any write to a power, clock or trim block that no
// model acts on, unless an allowlist entry says why it is fine.
using System;
using System.Collections.Generic;
using System.Linq;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.G2emu;

namespace Antmicro.Renode.Peripherals.Wisp
{
    // The strict record: one per Renode process (one machine). Armed by the harness (WispProbe
    // StrictFrom / StrictStart); it records only while Wisp code runs: from the hit of the arming
    // milestone (Wisp Boot's entry) until the next reset (WispRstGen clears InWisp), and again
    // from the next hit. Entries are deduplicated by (block, R/W, address, value, PC).
    public static class WispStrict
    {
        public static bool Armed;
        public static bool InWisp;
        public static string FromMilestone;
        private static readonly Dictionary<string, long> counts = new Dictionary<string, long>();
        private static readonly List<string> order = new List<string>();

        public static void Clear()
        {
            counts.Clear();
            order.Clear();
        }

        // Block names by address (hal_ambiq apollo510.h bases). "power/clock/trim" blocks are
        // the ones the harness fails on: rstgen, clkgen, otp, mcuctrl, pwrctrl.
        public static string Block(ulong a)
        {
            if((a >= 0x40000000 && a < 0x40001000) || a == 0x4000885C) return "rstgen";
            if(a >= 0x40004000 && a < 0x40004800) return "clkgen";
            if(a >= 0x40004800 && a < 0x40005000) return "rtc";
            if(a >= 0x4000C000 && a < 0x4000D000) return "vcomp";
            if(a >= 0x40010000 && a < 0x40011000) return "gpio";
            if(a >= 0x40011000 && a < 0x40012000) return "fpio";
            if(a >= 0x40014800 && a < 0x40015000) return "otp";
            if(a >= 0x40020000 && a < 0x40021000) return "mcuctrl";
            if(a >= 0x40021000 && a < 0x40022000) return "pwrctrl";
            if(a >= 0x40025000 && a < 0x40026000) return "ssc";
            if(a >= 0x40030000 && a < 0x40031000) return "security";
            if(a >= 0x400C0000 && a < 0x400C4000) return "crypto";
            if(a >= 0x42000000 && a < 0x42010000) return "info0";
            return $"periph@{a & ~0xFFFUL:X8}";
        }

        public static void Note(IMachine machine, ulong address, uint value, bool write)
        {
            if(!Armed || !InWisp)
            {
                return;
            }
            var pc = machine.SystemBus.TryGetCurrentCPU(out var cpu) ? (ulong)((ICPUWithRegisters)cpu).PC : 0;
            var key = $"{Block(address)} {(write ? "W" : "R")} 0x{address:X8} 0x{value:X8} pc 0x{pc:X}";
            if(counts.TryGetValue(key, out var n))
            {
                counts[key] = n + 1;
                return;
            }
            counts[key] = 1;
            order.Add(key);
        }

        // One line per distinct access, in first-seen order: "<block> <R|W> <address> <value> pc <pc> x<count>".
        public static string Dump()
        {
            return string.Join("\n", order.Select(k => $"{k} x{counts[k]}"));
        }
    }

    // The case link's two pads (rung4.md, "W24d: stage-0b"): GPIO PINCFG42 (UART2TX in function 4)
    // and PINCFG44 (UART2RX in function 4) sit on ONE pogo wire. GPIO is plain storage (WispTrace);
    // this record watches the two registers: their current function, every write with its virtual
    // time and PC (PadLog), and every write after which both pads are in UART function at once
    // (BothUart: the TX pad drives the wire while the receiver listens; the loader and stock park one
    // before they enable the other). WispCaseLink reads the state to model the half-duplex wire.
    // Cleared by a machine reset (the GPIO block's Reset).
    public static class WispPads
    {
        public const ulong Pincfg42 = 0x400100A8, Pincfg44 = 0x400100B0;
        public const uint UartFunction = 4;
        public static uint Tx, Rx;
        public static long BothUart;
        public static readonly List<string> Log = new List<string>();
        public static readonly List<string> BothUartLog = new List<string>();

        public static bool TxDriving => (Tx & 0xF) == UartFunction;
        public static bool RxListening => (Rx & 0xF) == UartFunction;

        public static void ResetPads()
        {
            Tx = Rx = 0;
        }

        public static void Note(IMachine machine, ulong address, uint value)
        {
            if(address != Pincfg42 && address != Pincfg44)
            {
                return;
            }
            if(address == Pincfg42)
            {
                Tx = value;
            }
            else
            {
                Rx = value;
            }
            var pc = machine.SystemBus.TryGetCurrentCPU(out var cpu) ? (ulong)((ICPUWithRegisters)cpu).PC : 0;
            var t = machine.LocalTimeSource.ElapsedVirtualTime.TotalMilliseconds;
            // "wisp": written while Wisp code runs (WispStrict: from Wisp Boot's entry to the next reset),
            // "other": the bootloader, or stock after a rescue (whose code sits at the same addresses).
            var who = WispStrict.Armed && WispStrict.InWisp ? "wisp" : "other";
            var line = $"{t:F3} pad{(address == Pincfg42 ? 42 : 44)} 0x{value:X} pc 0x{pc:X} {who}";
            if(Log.Count < 4000)
            {
                Log.Add(line);
            }
            if(TxDriving && RxListening)
            {
                BothUart++;
                if(BothUartLog.Count < 64)
                {
                    BothUartLog.Add(line);
                }
            }
        }
    }

    // MSPI1's power and IO clock as PWRCTRL and CLKGEN hold them (rung4.md, "W24e: stage-0c"), for
    // WispMspiNor: DEVPWRSTATUS.PWRSTMSPI1 (bit 15) and CLKGEN.MSPIIOCLKCTRL.MSPI1IOCLKEN (bit 5).
    // Read from the models' storage directly (no strict-record entry, no bus access). Mspi1PowerLost
    // fires when DEVPWREN.PWRENMSPI1 goes from 1 to 0: on silicon the domain's registers are lost.
    // Known is false until both models exist (a platform without them: MSPI1 counts as up).
    public static class WispPower
    {
        public const uint Mspi1Power = 0x8000, Mspi1IoClkEn = 0x20;
        public static WispPwrctrl Pwrctrl;
        public static WispClkgen Clkgen;
        public static event Action Mspi1PowerLost;

        public static bool Known => Pwrctrl != null && Clkgen != null;
        public static bool Mspi1Powered => !Known || (Pwrctrl.Peek(0x008) & Mspi1Power) != 0;
        public static bool Mspi1Clocked => !Known || (Clkgen.Peek(0x110) & Mspi1IoClkEn) != 0;

        public static void NotePwrctrlWrite(uint before, uint after)
        {
            if((before & Mspi1Power) != 0 && (after & Mspi1Power) == 0)
            {
                Mspi1PowerLost?.Invoke();
            }
        }
    }

    public class WispTrace : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public WispTrace(IMachine machine, long size = 0x1000, int trace = 1, ulong baseAddress = 0)
        {
            this.machine = machine;
            this.size = size;
            this.baseAddress = baseAddress;
            Trace = trace;
            Reset();
        }

        public int Trace { get; set; }

        public void Reset()
        {
            mem = new Dictionary<long, uint>();
            seenR = new HashSet<long>();
            seenW = new HashSet<long>();
            if(baseAddress <= WispPads.Pincfg42 && WispPads.Pincfg44 < baseAddress + (ulong)size)
            {
                WispPads.ResetPads();
            }
        }

        public long Size => size;

        public byte ReadByte(long o) { return (byte)(Read(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(Read(o & ~3L) >> (int)(8 * (o & 2))); }
        public uint ReadDoubleWord(long o) { return Read(o); }
        public void WriteByte(long o, byte v) { Merge(o, v, 0xFF); }
        public void WriteWord(long o, ushort v) { Merge(o, v, 0xFFFF); }
        public void WriteDoubleWord(long o, uint v) { Write(o, v); }

        private void Merge(long o, uint v, uint mask)
        {
            var a = o & ~3L;
            var sh = (int)(8 * (o & 3));
            var cur = mem.TryGetValue(a, out var c) ? c : 0;
            Write(a, (cur & ~(mask << sh)) | ((v & mask) << sh));
        }

        private uint Read(long o)
        {
            var v = mem.TryGetValue(o, out var c) ? c : 0;
            if(Trace >= 2 || (Trace == 1 && seenR.Add(o)))
            {
                this.Log(LogLevel.Warning, "R +0x{0:X4} -> 0x{1:X8} pc 0x{2:X}", o, v, Pc());
            }
            if(baseAddress != 0)
            {
                WispStrict.Note(machine, baseAddress + (ulong)o, v, false);
            }
            return v;
        }

        private void Write(long o, uint v)
        {
            mem[o] = v;
            if(baseAddress != 0)
            {
                WispPads.Note(machine, baseAddress + (ulong)o, v);
            }
            if(Trace >= 2 || (Trace == 1 && seenW.Add(o)))
            {
                this.Log(LogLevel.Warning, "W +0x{0:X4} <- 0x{1:X8} pc 0x{2:X}", o, v, Pc());
            }
            if(baseAddress != 0)
            {
                WispStrict.Note(machine, baseAddress + (ulong)o, v, true);
            }
        }

        private ulong Pc()
        {
            return machine.SystemBus.TryGetCurrentCPU(out var cpu) ? (ulong)((ICPUWithRegisters)cpu).PC : 0;
        }

        private readonly IMachine machine;
        private readonly long size;
        private readonly ulong baseAddress;
        private Dictionary<long, uint> mem;
        private HashSet<long> seenR, seenW;
    }

    // g2emu's PWRCTRL stub with a strict record: only DEVPWREN, AUDSSPWREN, MEMPWREN and
    // SSRAMPWREN have a behaviour that the rest of the platform depends on (their status mirrors);
    // every other access (VRCTRL, the SIMO buck, CPUPWRCTRL, ...) is storage, so it is recorded.
    public class WispPwrctrl : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public WispPwrctrl(IMachine machine, long size = 0x1000, bool domainStatus = false, ulong baseAddress = 0x40021000)
        {
            this.machine = machine;
            this.baseAddress = baseAddress;
            inner = new G2Pwrctrl(machine, size, domainStatus);
            WispPower.Pwrctrl = this;
        }

        public long Size => inner.Size;
        public void Reset() { inner.Reset(); }

        // The register as the guest would read it, without a strict-record entry (WispPower).
        public uint Peek(long o) { return inner.ReadDoubleWord(o); }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        public uint ReadDoubleWord(long o)
        {
            var v = inner.ReadDoubleWord(o);
            if((o & ~3L) == VRSTATUS)
            {
                // SIMOBUCKST (bits 5:4) = 3, active, once VRCTRL.SIMOBUCKEN is set: the bootloader's
                // own SIMOBUCK_INIT sets it at every boot, so on silicon the app's
                // am_hal_pwrctrl_control(SIMOBUCK_INIT) finds the buck active and returns at its
                // first check, as stock's does (rung4.md W25). Without this the HAL saw 0 here and
                // ran its 13 VRCTRL/SIMOBUCK writes, which silicon never does.
                return (v & ~0x30u) | ((inner.ReadDoubleWord(VRCTRL) & 1u) != 0 ? 0x30u : 0u);
            }
            if(!Modelled(o))
            {
                WispStrict.Note(machine, baseAddress + (ulong)o, v, false);
            }
            return v;
        }
        private const long VRCTRL = 0x100, VRSTATUS = 0x108;
        public void WriteByte(long o, byte v) { var b = Dev(o); Spy(o, v); inner.WriteByte(o, v); Lost(o, b); }
        public void WriteWord(long o, ushort v) { var b = Dev(o); Spy(o, v); inner.WriteWord(o, v); Lost(o, b); }
        public void WriteDoubleWord(long o, uint v) { var b = Dev(o); Spy(o, v); inner.WriteDoubleWord(o, v); Lost(o, b); }

        private uint Dev(long o) { return (o & ~3L) == 0x004 ? inner.ReadDoubleWord(0x004) : 0; }

        private void Lost(long o, uint before)
        {
            if((o & ~3L) == 0x004)
            {
                WispPower.NotePwrctrlWrite(before, inner.ReadDoubleWord(0x004));
            }
        }

        private void Spy(long o, uint v)
        {
            if(!Modelled(o))
            {
                WispStrict.Note(machine, baseAddress + (ulong)o, v, true);
            }
        }

        // DEVPWREN/STATUS, AUDSSPWREN/STATUS, MEMPWREN/STATUS, SSRAMPWREN/ST.
        private static bool Modelled(long o)
        {
            switch(o & ~3L)
            {
            case 0x004: case 0x008: case 0x00C: case 0x010: case 0x014: case 0x018: case 0x024: case 0x028:
                return true;
            default:
                return false;
            }
        }

        private readonly IMachine machine;
        private readonly ulong baseAddress;
        private readonly G2Pwrctrl inner;
    }

    // g2emu's CLKGEN + RTC stub with a strict record of every CLKGEN access (all of it is storage
    // or a constant "ready"); the RTC half (+0x800) is modelled and not recorded.
    public class WispClkgen : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public WispClkgen(IMachine machine, long size = 0x1000, ulong baseAddress = 0x40004000)
        {
            this.machine = machine;
            this.baseAddress = baseAddress;
            inner = new G2ClkgenRtc(machine, size);
            WispPower.Clkgen = this;
        }

        public long Size => inner.Size;
        public void Reset() { inner.Reset(); }

        // The register as the guest would read it, without a strict-record entry (WispPower).
        public uint Peek(long o) { return inner.ReadDoubleWord(o); }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        public uint ReadDoubleWord(long o)
        {
            var v = inner.ReadDoubleWord(o);
            if(o < 0x800)
            {
                WispStrict.Note(machine, baseAddress + (ulong)o, v, false);
            }
            return v;
        }
        public void WriteByte(long o, byte v) { Spy(o, v); inner.WriteByte(o, v); }
        public void WriteWord(long o, ushort v) { Spy(o, v); inner.WriteWord(o, v); }
        public void WriteDoubleWord(long o, uint v) { Spy(o, v); inner.WriteDoubleWord(o, v); }

        private void Spy(long o, uint v)
        {
            if(o < 0x800)
            {
                WispStrict.Note(machine, baseAddress + (ulong)o, v, true);
            }
        }

        private readonly IMachine machine;
        private readonly ulong baseAddress;
        private readonly G2ClkgenRtc inner;
    }
}
