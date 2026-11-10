// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: Apollo510 RSTGEN (0x40000000) plus the reset semantics the fault
// harness needs. Register map: hal_ambiq CMSIS apollo510.h (RSTGEN_Type).
//
//   CFG   0x000  WDREN (bit 1): a watchdog expiry only resets the chip when this is set
//   SWPOI 0x004  write 0x1B -> software POI reset
//   SWPOR 0x008  write 0xD4 -> software POR reset
//   STAT  0x885C the reset cause (apollo510.h RSTGEN_Type; the address falls inside the STIMER's
//                window, so WispStimer serves it from Stat below). Set by every reset from its
//                cause: power-cut -> POASTAT, SWPOR -> SWRSTAT, SWPOI -> POIRSTAT, watchdog ->
//                WDRSTAT, SYSRESETREQ -> AIRCRSTAT, a case reset (the pogo reset line) -> EXRSTAT.
//                Whether the real register accumulates across resets is open [?]; here it holds
//                the last cause only. Writes are stored (the HAL clears BORSTAT after a POA).
// Other offsets are plain storage.
//
// Every reset, whatever its source (SWPOI/SWPOR, AIRCR.SYSRESETREQ through Renode's NVIC,
// WispWdt, or the harness's PowerCut()), is a machine reset with these rules:
//   * kept:   MRAM (0x400000-0x800000) and the NOR array (WispMspiNor) — both non-volatile
//   * lost:   every register, the CPU, and all of SRAM: DTCM+SSRAM are filled with 0xA5 after the
//             reset, so nothing may rely on SRAM surviving (pessimistic on purpose: retained SRAM
//             after a warm reset is not guaranteed on the real chip, and a power loss clears it).
//             Exception, only when a case asks (`rstgen RetainRange <base> <size>`): that range
//             keeps its contents across every reset but a power cut, so the diagnostics record
//             (wisp_diag.h) can be tested end to end. Whether silicon keeps it is open [?].
//             D-cache model (`rstgen CacheModel true`, rung4.md "W24d: stage-0b"): on silicon the
//             bootloader hands off with the D-cache on and SRAM write-back cacheable, so a write
//             reaches SRAM only when its line is cleaned (or evicted, which nothing guarantees).
//             Renode has no cache. With the model on, the retained range keeps across a warm reset
//             only what was cleaned: a shadow copy of the range is taken at every reset, and lines
//             are copied from RAM into it only when Wisp code calls its clean function
//             (`rstgen CleanHook <addr>`, every copy of wisp_dcache_clean by its symbol; r0 = start,
//             r1 = bytes, whole 32-byte lines). At the next warm reset the shadow, not RAM, is what
//             survives. CleanLog lists the cleans (count and ranges).
//   * restart: the Ambiq SBL is not available, so the model performs its hand-off: VTOR =
//             0x410000, MSP = word 0, PC = word 1 of the Even bootloader's vector table
// The harness reads Resets / LastCause and the reset log (one line per reset) from the monitor.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispRstGen : IDoubleWordPeripheral, IKnownSize
    {
        public WispRstGen(IMachine machine, ulong bootVector = 0x410000, ulong sramBase = 0x20000000, ulong sramSize = 0x00380000)
        {
            this.machine = machine;
            this.bootVector = bootVector;
            this.sramBase = sramBase;
            this.sramSize = sramSize;
            Log = new List<string>();
            pendingCause = "power-on";
            machine.MachineReset += OnMachineReset;
            regs = new Dictionary<long, uint>();
        }

        public long Size => 0x1000;

        public int Resets { get; private set; }
        public string LastCause { get; private set; } = "power-on";
        public List<string> Log { get; }

        // RSTGEN.STAT (0x4000885C), served through WispStimer.
        public uint Stat { get; set; } = 0x2; // POASTAT

        public void RetainRange(ulong start, ulong length)
        {
            retainStart = start;
            retainLength = length;
            shadow = null;
        }

        // Set after RetainRange: the range as it is now is what SRAM holds until the first clean.
        public bool CacheModel
        {
            get => cacheModel;
            set
            {
                cacheModel = value;
                shadow = value && retainLength > 0 ? machine.SystemBus.ReadBytes(retainStart, (int)retainLength) : null;
            }
        }
        private bool cacheModel;
        public ulong Cleans { get; private set; }

        public void CleanHook(ulong addr)
        {
            foreach(var c in machine.SystemBus.GetCPUs())
            {
                if(c is ICPUWithHooks h)
                {
                    h.AddHook(addr, (cpu, a) => Clean(cpu.GetRegister(0).RawValue, cpu.GetRegister(1).RawValue));
                }
            }
        }

        public string CleanLog()
        {
            return $"cleans={Cleans}\n" + string.Join("\n", cleanLog);
        }

        private void Clean(ulong start, ulong length)
        {
            if(retainLength == 0 || length == 0 || length > 0x1000)
            {
                return;
            }
            var lo = Math.Max(start & ~31UL, retainStart);
            var hi = Math.Min((start + length + 31) & ~31UL, retainStart + retainLength);
            if(lo >= hi)
            {
                return;
            }
            if(shadow == null)
            {
                shadow = machine.SystemBus.ReadBytes(retainStart, (int)retainLength);
            }
            var bytes = machine.SystemBus.ReadBytes(lo, (int)(hi - lo));
            Array.Copy(bytes, 0, shadow, (int)(lo - retainStart), bytes.Length);
            Cleans++;
            var key = $"0x{lo:X8}+{hi - lo}";
            if(!cleanLog.Contains(key) && cleanLog.Count < 64)
            {
                cleanLog.Add(key);
            }
        }

        public static uint StatFor(string cause)
        {
            if(cause.StartsWith("power")) return 0x2;          // POASTAT
            if(cause.StartsWith("SWPOR")) return 0x8;          // SWRSTAT
            if(cause.StartsWith("SWPOI")) return 0x10;         // POIRSTAT
            if(cause.StartsWith("watchdog")) return 0x40;      // WDRSTAT
            if(cause.StartsWith("case-reset")) return 0x1;     // EXRSTAT (the reset line)
            if(cause.StartsWith("external")) return 0x1000;    // AIRCRSTAT (SYSRESETREQ)
            return 0;                                          // unknown: no bit, so no check passes by accident
        }

        // CFG.WDREN, read by WispWdt.
        public bool WatchdogResetEnabled => (Get(0x000) & 2) != 0;

        public void Reset()
        {
            // Registers are volatile; the reset bookkeeping is not part of the chip.
            regs = new Dictionary<long, uint>();
        }

        public uint ReadDoubleWord(long o)
        {
            return Get(o);
        }

        public void WriteDoubleWord(long o, uint v)
        {
            if(o == 0x004 && (v & 0xFF) == 0x1B)
            {
                Request("SWPOI");
                return;
            }
            if(o == 0x008 && (v & 0xFF) == 0xD4)
            {
                Request("SWPOR");
                return;
            }
            if(o != 0x000)
            {
                WispStrict.Note(machine, 0x40000000 + (ulong)o, v, true); // no behaviour behind it
            }
            regs[o] = v;
        }

        // Harness: cut power now (same as a reset under the rules above).
        public void PowerCut()
        {
            Request("power-cut");
        }

        public void Request(string cause)
        {
            if(resetPending)
            {
                return;
            }
            resetPending = true;
            pendingCause = cause;
            this.Log(LogLevel.Info, "reset requested: {0}", cause);
            machine.RequestReset();
        }

        public string ResetLog()
        {
            return string.Join("\n", Log);
        }

        private void OnMachineReset(IMachine m)
        {
            var cause = resetPending ? pendingCause : "external (NVIC SYSRESETREQ or monitor)";
            resetPending = false;
            Resets++;
            LastCause = cause;
            Log.Add($"{Resets} {cause} at {machine.ElapsedVirtualTime.TimeElapsed}");
            Stat = StatFor(cause);
            WispStrict.InWisp = false;
            var bus = machine.SystemBus;
            var keep = retainLength > 0 && !cause.StartsWith("power") ? bus.ReadBytes(retainStart, (int)retainLength) : null;
            if(keep != null && cacheModel && shadow != null)
            {
                // Only cleaned lines reached SRAM; the rest is what the range held when this boot began.
                keep = shadow;
            }
            var fill = new byte[0x10000];
            for(var i = 0; i < fill.Length; i++)
            {
                fill[i] = 0xA5;
            }
            for(var a = sramBase; a < sramBase + sramSize; a += (ulong)fill.Length)
            {
                bus.WriteBytes(fill, a);
            }
            if(keep != null)
            {
                bus.WriteBytes(keep, retainStart);
            }
            shadow = retainLength > 0 ? bus.ReadBytes(retainStart, (int)retainLength) : null;
            foreach(var cpu in bus.GetCPUs())
            {
                if(cpu is CortexM cm)
                {
                    cm.IsHalted = false; // a stalled bus access (WispMspiNor GatedStall) ends with the reset
                    cm.VectorTableOffset = (uint)bootVector;
                    cm.SP = bus.ReadDoubleWord(bootVector);
                    cm.PC = bus.ReadDoubleWord(bootVector + 4) & ~1u;
                }
            }
        }

        private uint Get(long o)
        {
            return regs.TryGetValue(o, out var v) ? v : 0;
        }

        private readonly IMachine machine;
        private readonly ulong bootVector, sramBase, sramSize;
        private Dictionary<long, uint> regs;
        private bool resetPending;
        private ulong retainStart, retainLength;
        private byte[] shadow;
        private readonly List<string> cleanLog = new List<string>();
        private string pendingCause;
    }
}
