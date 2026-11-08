// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode harness helper (not a chip block): milestones and power cuts.
//
//   probe Milestone <addr> "<name>"   hook a guest address; every hit appends
//                                     "<name> nor_ops=<n> resets=<r> t=<virtual time>"
//   probe CutAtNorOp <n>              cut power right after the NOR's n-th program/erase
//                                     (counted over the whole run, all boots)
//   probe CutAtMilestone "<name>" <k> cut power when that milestone is hit for the k-th time
//   probe Report                      all milestone lines
//   probe Dump <addr> <len> @<file>   save bus memory (MRAM) to a file
//   probe StrictFrom "<name>"         arm the strict record (WispTrace.cs, WispStrict): it records
//                                     from each hit of that milestone (Wisp Boot's entry) until
//                                     the next reset
//   probe StrictDump                  the record, one line per distinct access
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispProbe : IDoubleWordPeripheral, IKnownSize
    {
        public WispProbe(IMachine machine, WispMspiNor nor, WispRstGen rstgen)
        {
            this.machine = machine;
            this.nor = nor;
            this.rstgen = rstgen;
            lines = new List<string>();
            hits = new Dictionary<string, int>();
            nor.OpDone += OnNorOp;
        }

        public long Size => 0x100;

        public void Reset()
        {
        }

        public uint ReadDoubleWord(long o) { return 0; }
        public void WriteDoubleWord(long o, uint v) { }

        public void Milestone(ulong addr, string name)
        {
            foreach(var c in machine.SystemBus.GetCPUs())
            {
                if(c is ICPUWithHooks h)
                {
                    h.AddHook(addr, (cpu, a) => Hit(name, cpu, addr));
                }
            }
        }

        public void CutAtNorOp(long n)
        {
            cutOp = n;
        }

        public void CutAtMilestone(string name, int k)
        {
            cutName = name;
            cutHit = k;
        }

        // Harness: write [addr, addr+len) of the bus to a file (MRAM after a run).
        public void Dump(ulong addr, int len, string path)
        {
            System.IO.File.WriteAllBytes(path, machine.SystemBus.ReadBytes(addr, len));
        }

        public void StrictFrom(string name)
        {
            WispStrict.Clear();
            WispStrict.FromMilestone = name;
            WispStrict.Armed = true;
        }

        public string StrictDump()
        {
            return WispStrict.Dump();
        }

        public string Report()
        {
            return string.Join("\n", lines);
        }

        private void Hit(string name, ICpuSupportingGdb cpu, ulong addr)
        {
            // Milestones are Wisp Boot addresses; once stock is installed the same addresses hold
            // stock code. Count a hit only while Wisp Boot's services table ("WBS1") is in MRAM.
            if(machine.SystemBus.ReadDoubleWord(0x438200) != 0x31534257)
            {
                return;
            }
            if(WispStrict.Armed && WispStrict.FromMilestone == name)
            {
                WispStrict.InWisp = true;
            }
            var pc = (ulong)cpu.PC;
            var lr = cpu.GetRegister(14).RawValue;
            hits[name] = (hits.TryGetValue(name, out var n) ? n : 0) + 1;
            lines.Add($"{name} pc=0x{pc:X} lr=0x{lr:X} nor_ops={nor.Programs + nor.Erases} resets={rstgen.Resets} t={machine.ElapsedVirtualTime.TimeElapsed}");
            if(cutName == name && hits[name] == cutHit)
            {
                cutName = null;
                lines.Add($"CUT at milestone {name} #{cutHit}");
                rstgen.Request($"power-cut at milestone {name} #{cutHit}");
            }
        }

        private void OnNorOp(ulong total)
        {
            if(cutOp >= 0 && (long)total == cutOp)
            {
                cutOp = -1;
                lines.Add($"CUT after NOR op {total} resets={rstgen.Resets} t={machine.ElapsedVirtualTime.TimeElapsed}");
                rstgen.Request($"power-cut after NOR op {total}");
            }
        }

        private readonly IMachine machine;
        private readonly WispMspiNor nor;
        private readonly WispRstGen rstgen;
        private readonly List<string> lines;
        private readonly Dictionary<string, int> hits;
        private long cutOp = -1;
        private string cutName;
        private int cutHit;
    }
}
