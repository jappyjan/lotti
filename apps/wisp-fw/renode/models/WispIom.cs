// SPDX-License-Identifier: MIT
// Wisp Renode model: Apollo510 IOM0..7 in I2C mode (register map: hal_ambiq CMSIS apollo510.h,
// IOM0_Type) with the G2's I2C devices behind them, for the driver tests (tests/drivers/).
// Written for hal_ambiq's am_hal_iom_blocking_transfer() as Zephyr's i2c_ambiq.c drives it.
//
// Controller (per instance, 0x1000 apart):
//   * SUBMODCTRL reads SMOD0TYPE = 0 (SPI), SMOD1TYPE = 1 (I2C) whatever was written (the HAL's
//     enable path checks the types; plain storage reads 0 and the enable fails).
//   * CMD (CMD 1 = write, 2 = read; TSIZE; OFFSETCNT with OFFSETHI/OFFSETLO) runs the transaction.
//     Offset bytes go out highest byte first, as the datasheet text in apollo510.h says
//     ("Offset bytes are always transmitted MSB first"), so a byte-order bug in a driver shows
//     up here as it would on silicon. TX data comes from FIFOPUSH (before or after CMD), RX data
//     is queued for FIFOPOP at once. STATUS = IDLEST, INTSTAT.CMDCMP when done, INTSTAT.NAK when
//     no device answers at that address.
//   * FIFOPTR: FIFO0REM = 32 (TX room), FIFO1SIZ = queued RX bytes, rounded up to whole words
//     (the HAL only pops a word once FIFO1SIZ >= 4, also for a 1- or 2-byte read).
// Devices: see the classes below. Every transaction is logged as
//   <iom> <addr> <W|R> <hex bytes on the wire after the address byte>
// (`<name> SaveLog @file`). Psoc.ForbiddenSeen counts command bytes 2 (enter DFU) and 7 (EEPROM
// write) that reached the touch controller; the test requires 0.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispIom : IDoubleWordPeripheral, IBytePeripheral, IWordPeripheral, IKnownSize
    {
        public WispIom(IMachine machine, bool imu = true, bool als = true, bool touch = true, bool pmic = true)
        {
            log = new StringBuilder();
            devs = new Dictionary<int, Dictionary<int, I2cDevice>>();
            for(var i = 0; i < 8; i++)
            {
                devs[i] = new Dictionary<int, I2cDevice>();
            }
            Psoc = new PsocTouch();
            Pmic = new Npm1300();
            if(als) { devs[2][0x45] = new Opt3007(); }
            if(imu) { devs[4][0x69] = new Icm45608(); }
            if(touch) { devs[5][0x0C] = Psoc; }
            if(pmic) { devs[7][0x6B] = Pmic; }
            Reset();
        }

        public long Size => 0x8000;
        public PsocTouch Psoc { get; }
        public Npm1300 Pmic { get; }
        public ulong Transactions { get; private set; }
        public int ForbiddenSeen => Psoc.ForbiddenSeen;

        public void SaveLog(string path) { File.WriteAllText(path, log.ToString()); }

        // Queue a 16-byte touch report (hex) for the next command-3 read.
        public void TouchReport(string hex) { Psoc.Queue(Hex(hex)); }

        public void Reset()
        {
            st = new State[8];
            for(var i = 0; i < 8; i++)
            {
                st[i] = new State();
            }
        }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        public void WriteByte(long o, byte v) { WriteDoubleWord(o & ~3L, v); }
        public void WriteWord(long o, ushort v) { WriteDoubleWord(o & ~3L, v); }

        public uint ReadDoubleWord(long offset)
        {
            var s = st[(offset >> 12) & 7];
            var o = offset & 0xFFF;
            switch(o)
            {
            case SUBMODCTRL:
                return (s.Get(o) & 0x11u) | (0u << 1) | (1u << 5);
            case STATUS:
                return IDLEST;
            case INTSTAT:
                return s.IntStat;
            case CMDSTAT:
                return 0;
            case FIFOPTR:
                return (32u << 8) | ((uint)Math.Min(s.Rx.Count, 255) << 16);
            case FIFOPOP:
                uint w = 0;
                for(var i = 0; i < 4; i++)
                {
                    w |= (uint)(s.Rx.Count > 0 ? s.Rx.Dequeue() : 0) << (8 * i);
                }
                return w;
            default:
                return s.Get(o);
            }
        }

        public void WriteDoubleWord(long offset, uint v)
        {
            var idx = (int)((offset >> 12) & 7);
            var s = st[idx];
            var o = offset & 0xFFF;
            switch(o)
            {
            case INTCLR:
                s.IntStat &= ~v;
                return;
            case INTSET:
                s.IntStat |= v;
                return;
            case FIFOPUSH:
                for(var i = 0; i < 4; i++)
                {
                    s.Tx.Add((byte)(v >> (8 * i)));
                }
                TryFinishWrite(idx, s);
                return;
            case CMD:
                s.Regs[o] = v;
                StartCmd(idx, s, v);
                return;
            default:
                s.Regs[o] = v;
                return;
            }
        }

        private void StartCmd(int idx, State s, uint cmd)
        {
            var dir = (int)(cmd & 0xF);
            var tsize = (int)((cmd >> 8) & 0xFFF);
            var ocnt = (int)((cmd >> 4) & 0x7);
            var offset = new List<byte>();
            var hi = s.Get(OFFSETHI);
            for(var i = ocnt - 2; i >= 0; i--)
            {
                offset.Add((byte)(hi >> (8 * i)));
            }
            if(ocnt > 0)
            {
                offset.Add((byte)(cmd >> 24));
            }
            s.Addr = (int)(s.Get(DEVCFG) & 0x7F);
            s.Offset = offset.ToArray();
            s.Rx.Clear();
            if(dir == 2)
            {
                Transactions++;
                if(!devs[idx].TryGetValue(s.Addr, out var dev))
                {
                    Nak(idx, s, "R", s.Offset);
                    return;
                }
                if(s.Offset.Length > 0)
                {
                    dev.Write(s.Offset);
                }
                var data = dev.Read(tsize);
                foreach(var b in data)
                {
                    s.Rx.Enqueue(b);
                }
                // The RX FIFO holds whole words: a 2-byte read shows FIFO1SIZ = 4.
                while((s.Rx.Count & 3) != 0)
                {
                    s.Rx.Enqueue(0);
                }
                Log(idx, s.Addr, s.Offset.Length > 0 ? "W" : null, s.Offset);
                Log(idx, s.Addr, "R", data);
                s.IntStat |= CMDCMP;
                return;
            }
            s.Pending = tsize;
            s.Writing = true;
            TryFinishWrite(idx, s);
        }

        private void TryFinishWrite(int idx, State s)
        {
            if(!s.Writing || s.Tx.Count < s.Pending)
            {
                return;
            }
            s.Writing = false;
            Transactions++;
            var wire = new List<byte>(s.Offset);
            wire.AddRange(s.Tx.GetRange(0, s.Pending));
            s.Tx.Clear();
            if(!devs[idx].TryGetValue(s.Addr, out var dev))
            {
                Nak(idx, s, "W", wire.ToArray());
                return;
            }
            dev.Write(wire.ToArray());
            Log(idx, s.Addr, "W", wire.ToArray());
            s.IntStat |= CMDCMP;
        }

        private void Nak(int idx, State s, string dir, byte[] data)
        {
            Log(idx, s.Addr, dir + "-NAK", data);
            s.IntStat |= CMDCMP | NAK;
            s.Writing = false;
            s.Tx.Clear();
        }

        private void Log(int idx, int addr, string dir, byte[] data)
        {
            if(dir == null)
            {
                return;
            }
            var hex = new StringBuilder();
            foreach(var b in data)
            {
                hex.Append(b.ToString("X2"));
            }
            log.AppendFormat("{0} {1:X2} {2} {3}\n", idx, addr, dir, hex);
        }

        private static byte[] Hex(string s)
        {
            var b = new byte[s.Length / 2];
            for(var i = 0; i < b.Length; i++)
            {
                b[i] = Convert.ToByte(s.Substring(2 * i, 2), 16);
            }
            return b;
        }

        private class State
        {
            public Dictionary<long, uint> Regs = new Dictionary<long, uint>();
            public Queue<byte> Rx = new Queue<byte>();
            public List<byte> Tx = new List<byte>();
            public uint IntStat;
            public int Addr, Pending;
            public bool Writing;
            public byte[] Offset = new byte[0];
            public uint Get(long o) { return Regs.TryGetValue(o, out var v) ? v : 0; }
        }

        private Dictionary<int, Dictionary<int, I2cDevice>> devs;
        private State[] st;
        private readonly StringBuilder log;

        private const long FIFOPTR = 0x100, FIFOPOP = 0x108, FIFOPUSH = 0x10C, SUBMODCTRL = 0x11C;
        private const long CMD = 0x120, OFFSETHI = 0x128, CMDSTAT = 0x12C;
        private const long INTSTAT = 0x204, INTCLR = 0x208, INTSET = 0x20C, STATUS = 0x248, DEVCFG = 0x2C4;
        private const uint IDLEST = 1 << 2, CMDCMP = 1, NAK = 1 << 4;
    }

    // One I2C target: Write gets everything after the address byte of a write transaction (an
    // IOM offset phase arrives as a write of its own, then the read); Read returns n bytes.
    public abstract class I2cDevice
    {
        public abstract void Write(byte[] wire);
        public abstract byte[] Read(int n);
    }

    // 8-bit register file with an 8-bit (or 16-bit) register pointer and auto-increment.
    public class RegFile : I2cDevice
    {
        public RegFile(int addrBytes) { this.addrBytes = addrBytes; }

        public override void Write(byte[] wire)
        {
            if(wire.Length < addrBytes)
            {
                return;
            }
            ptr = 0;
            for(var i = 0; i < addrBytes; i++)
            {
                ptr = (ptr << 8) | wire[i];
            }
            for(var i = addrBytes; i < wire.Length; i++)
            {
                Store(ptr++, wire[i]);
            }
        }

        public override byte[] Read(int n)
        {
            var b = new byte[n];
            for(var i = 0; i < n; i++)
            {
                b[i] = Load(ptr++);
            }
            return b;
        }

        protected virtual void Store(int reg, byte v) { regs[reg] = v; }
        protected virtual byte Load(int reg) { return regs.TryGetValue(reg, out var v) ? v : (byte)0; }

        protected readonly Dictionary<int, byte> regs = new Dictionary<int, byte>();
        private readonly int addrBytes;
        protected int ptr;
    }

    // nPM1300: 16-bit register address {base, offset}, high byte first (Nordic PS), 8-bit regs.
    public class Npm1300 : RegFile
    {
        public Npm1300() : base(2) { }
        public byte Reg(int baseOff) { return Load(baseOff); }
    }

    // TDK ICM-45608: WHO_AM_I 0x72 = 0x81; MISC2 0x7F bit 1 soft reset (self-clears, sets
    // INT1_STATUS0 0x19 bit 7 RESET_DONE, clear on read); data registers 0x00..0x0D return a fixed
    // sample (accel 0, 0, +1 g at ±4 g = 8192; gyro 1, 2, 3; temp 0 = 25 °C) while accel is on.
    public class Icm45608 : RegFile
    {
        public Icm45608() : base(1) { regs[0x72] = 0x81; regs[0x19] = 0x80; }

        protected override void Store(int reg, byte v)
        {
            if(reg == 0x7F && (v & 2) != 0)
            {
                regs.Clear();
                regs[0x72] = 0x81;
                regs[0x19] = 0x80;
                return;
            }
            base.Store(reg, v);
        }

        protected override byte Load(int reg)
        {
            if(reg == 0x19)
            {
                var v = base.Load(reg);
                regs[0x19] = 0;
                return v;
            }
            if(reg <= 0x0D && (base.Load(0x10) & 3) != 0)
            {
                short[] sample = { 0, 0, 8192, 1, 2, 3, 0 };
                var s = sample[reg / 2];
                return (byte)((reg & 1) == 0 ? s & 0xFF : (s >> 8) & 0xFF);
            }
            return base.Load(reg);
        }
    }

    // TI OPT3007: 8-bit pointer, 16-bit registers MSB first. IDs 0x7E = 0x5449, 0x7F = 0x3001.
    // A single-shot conversion (config M = 01) completes at once: CRF set, M back to 00, result
    // 0x3456 = 2^3 * 0x456 * 0.01 lux = 88.88 lux.
    public class Opt3007 : I2cDevice
    {
        public override void Write(byte[] wire)
        {
            if(wire.Length == 0)
            {
                return;
            }
            ptr = wire[0];
            if(wire.Length >= 3)
            {
                var v = (ushort)(wire[1] << 8 | wire[2]);
                if(ptr == 0x01)
                {
                    config = (ushort)(v & 0xFE1F);
                    if(((v >> 9) & 3) == 1)
                    {
                        config = (ushort)((config & ~0x0600) | 0x0080); // single-shot done
                        result = 0x3456;
                    }
                    Writes.Add(v);
                }
            }
        }

        public override byte[] Read(int n)
        {
            ushort v;
            switch(ptr)
            {
            case 0x00: v = result; break;
            case 0x01: v = config; config = (ushort)(config & ~0x0080); break;
            case 0x7E: v = 0x5449; break;
            case 0x7F: v = 0x3001; break;
            default: v = 0; break;
            }
            var b = new byte[n];
            if(n > 0) { b[0] = (byte)(v >> 8); }
            if(n > 1) { b[1] = (byte)v; }
            return b;
        }

        public readonly List<ushort> Writes = new List<ushort>();
        private int ptr;
        private ushort config = 0xC810, result;
    }

    // PSoC 4000T running Even's touch firmware, as the host sees it (hardware.md "Touch"):
    // a write [cmd, body...] selects the reply, a separate read returns it. 1 version (4 B, BE),
    // 3 last report (16 B), 4 diffs (10 B), 5 save baseline (no reply), 6 baseline (2 B),
    // 8 long-press threshold (2 B LE). 2 (DFU) and 7 (EEPROM write) are counted as forbidden.
    public class PsocTouch : I2cDevice
    {
        public override void Write(byte[] wire)
        {
            if(wire.Length == 0)
            {
                return;
            }
            cmd = wire[0];
            Commands.Add(cmd);
            if(cmd == 2 || cmd == 7)
            {
                ForbiddenSeen++;
            }
        }

        public override byte[] Read(int n)
        {
            byte[] v;
            switch(cmd)
            {
            case 1: v = new byte[] { 0x01, 0x00, 0x02, 0x02 }; break;
            case 3: v = reports.Count > 0 ? reports.Dequeue() : new byte[16]; break;
            case 6: v = new byte[] { 0x10, 0x27 }; break;
            case 8: v = new byte[] { 0xE8, 0x03 }; break;
            default: v = new byte[n]; break;
            }
            var b = new byte[n];
            Array.Copy(v, b, Math.Min(n, v.Length));
            return b;
        }

        public void Queue(byte[] report) { reports.Enqueue(report); }

        public int ForbiddenSeen { get; private set; }
        public readonly List<int> Commands = new List<int>();
        private readonly Queue<byte[]> reports = new Queue<byte[]>();
        private int cmd;
    }
}
