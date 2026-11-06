//
// Even G2 Apollo510B -- CLKGEN @0x40004000 stub + a RUNNING RTC at +0x800. Native C# port of
// g2emu/py/clkgen_rtc.py.
//
//   CLKGEN: 0x030/0x034/0x038 (clock-ready status) and 0x054 (HF2VAL) read 0xFFFFFFFF;
//           everything else echoes writes.
//   RTC (BCD, local calendar time, advancing with the machine's VIRTUAL clock):
//     +0x820 CTRLOW  hour[29:24] | min[22:16] | sec[14:8] | hundredths[7:0]
//     +0x824 CTRUP   weekday[26:24] (0=Sun) | year[23:16] (since 2000) | month[12:8] | date[5:0]
//   Start time: host DateTime.Now at init; emulator-only 0xff0 W = seconds since 2000-01-01 00:00
//   (0 = host now); a firmware write of CTRUP (after CTRLOW) re-bases the clock.
//
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.G2emu
{
    public class G2ClkgenRtc : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IQuadWordPeripheral, IKnownSize
    {
        public G2ClkgenRtc(IMachine machine, long size = 0x1000)
        {
            this.machine = machine;
            this.size = size;
            Reset();
        }

        public void Reset()
        {
            mem = new Dictionary<long, ulong>();
            rtcBase = DateTime.Now;
            vt0 = 0.0;
        }

        public long Size => size;

        public byte ReadByte(long offset) { return (byte)Read(offset); }
        public ushort ReadWord(long offset) { return (ushort)Read(offset); }
        public uint ReadDoubleWord(long offset) { return (uint)Read(offset); }
        public ulong ReadQuadWord(long offset) { return Read(offset); }
        public void WriteByte(long offset, byte value) { Write(offset, value); }
        public void WriteWord(long offset, ushort value) { Write(offset, value); }
        public void WriteDoubleWord(long offset, uint value) { Write(offset, value); }
        public void WriteQuadWord(long offset, ulong value) { Write(offset, value); }

        private ulong Get(long o)
        {
            return mem.TryGetValue(o, out var v) ? v : 0;
        }

        private double VSec()
        {
            try
            {
                return machine.LocalTimeSource.ElapsedVirtualTime.TotalSeconds;
            }
            catch(Exception)
            {
                return 0.0;
            }
        }

        private static ulong Bcd(long v)
        {
            return (ulong)(((v / 10) << 4) | (v % 10));
        }

        private static int UnBcd(ulong b)
        {
            return (int)(((b >> 4) & 0xF) * 10 + (b & 0xF));
        }

        private DateTime Now()
        {
            return rtcBase.Add(TimeSpan.FromSeconds(VSec() - vt0));
        }

        private void Rebase(DateTime dt)
        {
            rtcBase = dt;
            vt0 = VSec();
        }

        private static ulong CtrLow(DateTime t)
        {
            return (Bcd(t.Hour) << 24) | (Bcd(t.Minute) << 16) | (Bcd(t.Second) << 8) | Bcd(t.Millisecond / 10);
        }

        private static ulong CtrUp(DateTime t)
        {
            return (Bcd((int)t.DayOfWeek) << 24) | (Bcd(t.Year - 2000) << 16) | (Bcd(t.Month) << 8) | Bcd(t.Day);
        }

        private static DateTime? FromRegs(ulong lo, ulong up)
        {
            try
            {
                return new DateTime(2000 + UnBcd((up >> 16) & 0xFF), UnBcd((up >> 8) & 0x1F), UnBcd(up & 0x3F),
                                    UnBcd((lo >> 24) & 0x3F), UnBcd((lo >> 16) & 0x7F), UnBcd((lo >> 8) & 0x7F));
            }
            catch(Exception)
            {
                return null;
            }
        }

        private void Write(long off, ulong value)
        {
            mem[off] = value;
            if(off == RTC_SET2000)
            {
                var v = (long)value;
                Rebase(v != 0 ? Epoch2000.AddSeconds((double)v) : DateTime.Now);   // 0 = host local time now
                this.Log(LogLevel.Info, "RTC set by script: {0}", Now().ToString("yyyy-MM-dd HH:mm:ss"));
            }
            else if(off == CTRUP)                          // firmware time-set writes CTRLOW then CTRUP
            {
                var dt = FromRegs(Get(CTRLOW), value);
                if(dt.HasValue)
                {
                    Rebase(dt.Value);
                    this.Log(LogLevel.Info, "RTC set by firmware: {0}", dt.Value.ToString("yyyy-MM-dd HH:mm:ss"));
                }
            }
        }

        private ulong Read(long off)
        {
            switch(off)
            {
            case 0x030:
            case 0x034:
            case 0x038:
            case 0x054:                                     // HF2VAL -- locked/valid
                return 0xFFFFFFFF;
            case CTRLOW:
                return CtrLow(Now());
            case CTRUP:
                return CtrUp(Now());
            default:
                return Get(off);
            }
        }

        private readonly IMachine machine;
        private readonly long size;
        private Dictionary<long, ulong> mem;
        private DateTime rtcBase;
        private double vt0;

        private static readonly DateTime Epoch2000 = new DateTime(2000, 1, 1, 0, 0, 0);
        private const long CTRLOW = 0x820, CTRUP = 0x824, RTC_SET2000 = 0xff0;
    }
}
