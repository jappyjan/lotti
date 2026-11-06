// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: the Apollo510 boot-ROM helper functions that MRAM programming goes
// through. Both the Even bootloader (installing the main app, clearing the update flag) and Wisp
// Boot (setting it) call nv_program_main2 at 0x0200FF20 — the same entry point AmbiqSuite's
// am_hal_mram_main_program() uses (hal_ambiq am_hal_bootrom_helper.c). The real ROM is Ambiq's
// and is not available, so this model implements the documented behaviour of each entry:
//
//   0x0200FF0C nv_program_info_area(key, src, wordOffset, n)  -> refused: returns 11 (write
//              protected) and logs. Wisp never writes INFO space; neither does the bootloader.
//   0x0200FF20 nv_program_main2(key, program, src|value, wordOffset, n [stack])
//              key must be 0x12344321 (AM_HAL_MRAM_PROGRAM_KEY) else 1; destination
//              0x400000 + 4*wordOffset must lie in [0x400000, 0x800000) else 2/3. program = 1
//              copies n words from src, program = 0 fills n words with value. Returns 0.
//   0x0200FF28 br_util_read_word(addr)       -> *addr
//   0x0200FF2C br_util_write_word(addr, val) -> *addr = val
//   0x0200FF40 valid_address_range(...)      -> 1
//   0x0200FF50 bootrom_delay_cycles(n)       -> returns at once (no virtual time is added)
//   0x0200FF54 otp_program_info_area(...)    -> refused, returns 11
//   0x0200FF5C bootrom_version_info()        -> 0
//
// Install: after the platform is loaded, run `bootrom Install` in the monitor. It writes `bx lr`
// at every entry of the ROM memory region at 0x02000000 and hooks the entries on the CPU.
// Every nv_program_main2 call is appended to Writes as
//   "<n> lr=0x... dst=0x... words=<n> first=0x... key-ok=<bool> status=<s>"
// and can be dumped with `bootrom WriteLog`. CutAfterWritesTo(addr) makes the next completed
// write that covers addr cut power right after it (harness: "power loss right after the flag").
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispBootRom : IDoubleWordPeripheral, IKnownSize
    {
        public WispBootRom(IMachine machine, WispRstGen rstgen)
        {
            this.machine = machine;
            this.rstgen = rstgen;
            Writes = new List<string>();
        }

        public long Size => 0x100;

        public List<string> Writes { get; }
        public int CutAfterWriteIndex { get; set; } = -1;
        public long CutAddress { get; set; } = -1;

        public void Reset()
        {
        }

        public uint ReadDoubleWord(long o)
        {
            return o == 0 ? (uint)Writes.Count : 0;
        }

        public void WriteDoubleWord(long o, uint v)
        {
        }

        public void CutAfterWritesTo(long address)
        {
            CutAddress = address;
        }

        public string WriteLog()
        {
            return string.Join("\n", Writes);
        }

        public void Install()
        {
            var bus = machine.SystemBus;
            foreach(var e in Entries)
            {
                bus.WriteWord(e, 0x4770); // bx lr
                bus.WriteWord(e + 2, 0x4770);
            }
            foreach(var c in bus.GetCPUs())
            {
                if(c is ICPUWithHooks h)
                {
                    h.AddHook(0x0200FF0C, (cpu, a) => Ret(cpu, 11, "nv_program_info_area refused"));
                    h.AddHook(0x0200FF20, (cpu, a) => ProgramMain(cpu));
                    h.AddHook(0x0200FF28, (cpu, a) => Ret(cpu, bus.ReadDoubleWord(Reg(cpu, 0)), null));
                    h.AddHook(0x0200FF2C, (cpu, a) => { bus.WriteDoubleWord(Reg(cpu, 0), (uint)Reg(cpu, 1)); });
                    h.AddHook(0x0200FF40, (cpu, a) => Ret(cpu, 1, null));
                    h.AddHook(0x0200FF54, (cpu, a) => Ret(cpu, 11, "otp_program_info_area refused"));
                    h.AddHook(0x0200FF5C, (cpu, a) => Ret(cpu, 0, null));
                }
            }
        }

        private void ProgramMain(ICpuSupportingGdb cpu)
        {
            var bus = machine.SystemBus;
            var key = (uint)Reg(cpu, 0);
            var program = Reg(cpu, 1);
            var src = Reg(cpu, 2);
            var off = Reg(cpu, 3);
            var sp = Reg(cpu, 13);
            var n = (ulong)bus.ReadDoubleWord(sp);
            var lr = Reg(cpu, 14);
            var dst = 0x400000UL + 4 * off;
            uint status = 0;
            if(key != 0x12344321)
            {
                status = 1;
            }
            else if(dst < 0x400000 || dst >= 0x800000)
            {
                status = 2;
            }
            else if(dst + 4 * n > 0x800000)
            {
                status = 3;
            }
            uint first = 0;
            if(status == 0)
            {
                if(program != 0)
                {
                    var data = bus.ReadBytes(src, (int)(4 * n));
                    bus.WriteBytes(data, dst);
                    first = n > 0 ? BitConverter.ToUInt32(data, 0) : 0;
                }
                else
                {
                    for(ulong i = 0; i < n; i++)
                    {
                        bus.WriteDoubleWord(dst + 4 * i, (uint)src);
                    }
                    first = (uint)src;
                }
            }
            var line = $"{Writes.Count} lr=0x{lr:X} dst=0x{dst:X} words={n} first=0x{first:X8} {(program != 0 ? "program" : "fill")} key-ok={key == 0x12344321} status={status}";
            Writes.Add(line);
            if(dst < 0x438000 || dst >= 0x7F8000)
            {
                this.Log(LogLevel.Info, "MRAM write outside the app region: {0}", line);
            }
            Ret(cpu, status, null);
            var cut = (CutAfterWriteIndex >= 0 && Writes.Count - 1 == CutAfterWriteIndex)
                || (CutAddress >= 0 && status == 0 && (ulong)CutAddress >= dst && (ulong)CutAddress < dst + 4 * n);
            if(cut)
            {
                CutAfterWriteIndex = -1;
                CutAddress = -1;
                rstgen.Request("power-cut after MRAM write " + line);
            }
        }

        private static ulong Reg(ICpuSupportingGdb cpu, int i)
        {
            return cpu.GetRegister(i).RawValue;
        }

        // The hook runs before the `bx lr` stub at the entry, which then returns to the caller.
        private void Ret(ICpuSupportingGdb cpu, ulong r0, string log)
        {
            cpu.SetRegister(0, r0);
            if(log != null)
            {
                this.Log(LogLevel.Warning, "{0} (lr 0x{1:X})", log, Reg(cpu, 14));
            }
        }

        private static readonly ulong[] Entries =
            { 0x0200FF0C, 0x0200FF20, 0x0200FF28, 0x0200FF2C, 0x0200FF40, 0x0200FF50, 0x0200FF54, 0x0200FF5C };

        private readonly IMachine machine;
        private readonly WispRstGen rstgen;
    }
}
