//
// Even G2 Apollo510B -- PWRCTRL @0x40021000 behavioural stub. Native C# port of
// g2emu/py/pwrctrl_stub.py: each *STATUS register mirrors its *EN register, MCUPERFREQ
// reports a settled perf mode 2 when unset, ADCSTATUS/AUDADCSTATUS read "analog ready",
// everything else echoes writes (plain storage keyed by the exact access offset).
//
// Optional (repl `domainStatus: true`, default false = exact Python behaviour): on real silicon
// DEVPWRSTATUS / AUDSSPWRSTATUS report POWER-DOMAIN bits, not per-device bits. The firmware's
// am_hal_pwrctrl_periph_enable (0x489b2c -> poll helper 0x48acaa, the hot `ldr` at 0x48acd0) waits
// for the whole domain mask from its table @0x6fbcb0 (e.g. IOM4..7 -> 0x1e0). With a bit-for-bit
// mirror that mask is never complete, so every enable of a grouped device polls 6 times and returns
// AM_HAL_STATUS_TIMEOUT (~2.4M reads per boot). With domainStatus the status register also reports
// a domain's mask while any of its members is enabled, so the poll succeeds on the first read.
//
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.G2emu
{
    public class G2Pwrctrl : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IQuadWordPeripheral, IKnownSize
    {
        public G2Pwrctrl(IMachine machine, long size = 0x1000, bool domainStatus = false)
        {
            this.size = size;
            this.domainStatus = domainStatus;
            Reset();
        }

        public void Reset()
        {
            mem = new Dictionary<long, ulong>();
        }

        public long Size => size;

        public byte ReadByte(long offset) { return (byte)Read(offset); }
        public ushort ReadWord(long offset) { return (ushort)Read(offset); }
        public uint ReadDoubleWord(long offset) { return (uint)Read(offset); }
        public ulong ReadQuadWord(long offset) { return Read(offset); }
        public void WriteByte(long offset, byte value) { mem[offset] = value; }
        public void WriteWord(long offset, ushort value) { mem[offset] = value; }
        public void WriteDoubleWord(long offset, uint value) { mem[offset] = value; }
        public void WriteQuadWord(long offset, ulong value) { mem[offset] = value; }

        private ulong Get(long o)
        {
            return mem.TryGetValue(o, out var v) ? v : 0;
        }

        private ulong Read(long off)
        {
            switch(off)
            {
            // STATUS register <- mirrors EN register
            case 0x008: return domainStatus ? Domains(Get(0x004), DevDomains) : Get(0x004);   // DEVPWRSTATUS <- DEVPWREN
            case 0x010: return domainStatus ? Domains(Get(0x00C), AudDomains) : Get(0x00C);   // AUDSSPWRSTATUS <- AUDSSPWREN
            case 0x018: return Get(0x014);   // MEMPWRSTATUS   <- MEMPWREN
            case 0x028: return Get(0x024);   // SSRAMPWRST     <- SSRAMPWREN
            case 0x058: return Get(0x050);   // CPUPWRSTATUS   <- CPUPWRCTRL
            case 0x108: return Get(0x100);   // VRSTATUS       <- VRCTRL
            case 0x000:                      // MCUPERFREQ: bits[4:3] = perf mode 2 when unset
                {
                    var v = Get(0x000);
                    return (v & 0x18) != 0 ? v : 0x10;
                }
            case 0x194:                      // ADCSTATUS / AUDADCSTATUS -- analog ready
            case 0x198:
                return 0xFFFFFFFF;
            default:
                return Get(off);
            }
        }

        private static ulong Domains(ulong en, ulong[,] domains)
        {
            var st = en;
            for(var i = 0; i < domains.GetLength(0); i++)
            {
                if((en & domains[i, 0]) != 0)
                {
                    st |= domains[i, 1];
                }
            }
            return st;
        }

        private Dictionary<long, ulong> mem;
        private readonly long size;
        private readonly bool domainStatus;

        // {enable bits of the domain's members, domain status mask} -- firmware table @0x6fbcb0
        private static readonly ulong[,] DevDomains = {
            { 0x30000001, 0x30000001 },      // entries 0-2
            { 0x0000001e, 0x0000001e },      // IOM0-3 (entries 3-6)
            { 0x000001e0, 0x000001e0 },      // IOM4-7 (entries 7-10)
            { 0x00001e00, 0x00001e00 },      // entries 11-14
        };
        private static readonly ulong[,] AudDomains = {
            { 0x000000c0, 0x000000c0 },      // AUDSS entries 31-32
        };
    }
}
