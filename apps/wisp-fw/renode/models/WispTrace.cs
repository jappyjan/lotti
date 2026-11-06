// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: plain register storage that remembers what was written and can log
// every access with the guest PC. Used for the peripheral ranges no Wisp model covers yet, so a
// stall in the stock bootloader shows which register it is polling.
//
//   trace: 0 = silent, 1 = log the first read and first write of each offset, 2 = log everything
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispTrace : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public WispTrace(IMachine machine, long size = 0x1000, int trace = 1)
        {
            this.machine = machine;
            this.size = size;
            Trace = trace;
            Reset();
        }

        public int Trace { get; set; }

        public void Reset()
        {
            mem = new Dictionary<long, uint>();
            seenR = new HashSet<long>();
            seenW = new HashSet<long>();
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
            return v;
        }

        private void Write(long o, uint v)
        {
            mem[o] = v;
            if(Trace >= 2 || (Trace == 1 && seenW.Add(o)))
            {
                this.Log(LogLevel.Warning, "W +0x{0:X4} <- 0x{1:X8} pc 0x{2:X}", o, v, Pc());
            }
        }

        private ulong Pc()
        {
            return machine.SystemBus.TryGetCurrentCPU(out var cpu) ? (ulong)((ICPUWithRegisters)cpu).PC : 0;
        }

        private readonly IMachine machine;
        private readonly long size;
        private Dictionary<long, uint> mem;
        private HashSet<long> seenR, seenW;
    }
}
