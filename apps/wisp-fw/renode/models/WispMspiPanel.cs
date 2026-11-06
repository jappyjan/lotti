// SPDX-License-Identifier: MIT
// Wisp Renode model: Apollo510 MSPI0 (register map: hal_ambiq CMSIS apollo510.h, MSPI0_Type) with
// the G2 microLED panel on CE0, as a recorder. Written for the panel driver test
// (tests/display/, docs/wisp/hardware.md "Display").
//
// Controller: the same PIO / DMA / command-queue subset as WispMspiNor (that file is the reference;
// this one is separate so the rung-3 model stays byte-for-byte what rung 3 was signed against).
// Added: the bus mode of every transaction is logged as DEV0CFG.DEVCFG0 / DEV0XIP.XIPMIXED at the
// moment it runs. hal_ambiq runs quad 1-1-4 as DEVCFG0 = 1 (serial CE0) with XIPMIXED = 5 (data on
// four lines), so "1/0" = serial and "1/5" = 1-1-4; a test can check that commands go out serial
// and pixels quad. The HAL writes CQENDIDX before it sets CQCFG.CQEN, so the queue also starts on
// the CQCFG write; a finished queue raises CQCMP and CQUPD (the HAL's completion interrupt).
//
// Panel: JBD4010 (Variant 0, default) or A6N-G (Variant 1; `panel Variant 1` in the monitor).
// Every transaction is appended to a log line
//   <seq> <mode> <op|-> <addr|-> <tx|rx> <len> <hex bytes (first 64)>
// (`<name> SaveLog @file`). Reads answer like a healthy panel (hardware.md "Display"): JBD chip
// ID (0x9F), status 1 (0x05, 0x00; 0x90 would be a fault) and status 2 (0x35, 0x01); A6N-G
// registers {0x78|0x7A, reg, val} writes go to a two-bank register file that reads back through
// {0x79|0x7B, reg} with reset values for the ID/health registers. Pixel writes land in a 640x480
// 4 bpp frame (`<name> SaveFrame @file`, 153 600 bytes, 320 per row, as sent): JBD instruction
// 0x62 quad with the address word ((row << 10 | col) << 8 | 0xFF); A6N-G address 0x32002C00,
// no instruction, whole frames. Counters: Commands, PixelBytes, Commits, Frames.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispMspiPanel : IDoubleWordPeripheral, IBytePeripheral, IWordPeripheral, IKnownSize, IGPIOSender
    {
        public WispMspiPanel(IMachine machine)
        {
            this.machine = machine;
            IRQ = new GPIO();
            frame = new byte[FrameBytes];
            log = new StringBuilder();
            Reset();
        }

        public GPIO IRQ { get; }
        public long Size => 0x1000;
        public int Trace { get; set; }
        public ulong Commands { get; private set; }
        public ulong PixelBytes { get; private set; }
        public ulong Commits { get; private set; }
        public ulong Frames { get; private set; }
        public int Variant { get; set; }
        // JBD status registers; the driver treats SR1 == 0x90 or SR2 == 0 as a fault.
        public int Status1 { get; set; } = 0x00;
        public int Status2 { get; set; } = 0x01;

        public string Log => log.ToString();

        public void SaveLog(string path) { File.WriteAllText(path, log.ToString()); }
        public void SaveFrame(string path) { File.WriteAllBytes(path, frame); }
        public void ClearLog() { log.Clear(); seq = 0; }

        // Controller registers reset with the machine; the recorded log and frame do not.
        public void Reset()
        {
            regs = new Dictionary<long, uint>();
            rx = new Queue<uint>();
            tx = new List<byte>();
            pioActive = false;
            intstat = 0;
            UpdateIrq();
        }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        public void WriteByte(long o, byte v) { WriteDoubleWord(o & ~3L, v); }
        public void WriteWord(long o, ushort v) { WriteDoubleWord(o & ~3L, v); }

        public uint ReadDoubleWord(long o)
        {
            switch(o)
            {
            case CTRL:
                return (Get(CTRL) & ~(START | BUSY)) | (pioActive ? 0 : STATUS);
            case RXFIFO:
                return rx.Count > 0 ? rx.Dequeue() : 0;
            case TXENTRIES:
                return 0;
            case RXENTRIES:
                return (uint)Math.Min(rx.Count, 16);
            case INTSTAT:
                return intstat;
            default:
                return Get(o);
            }
        }

        public void WriteDoubleWord(long o, uint v)
        {
            if(Trace >= 2)
            {
                this.Log(LogLevel.Warning, "W +0x{0:X3} <- 0x{1:X8}", o, v);
            }
            switch(o)
            {
            case CTRL:
                regs[CTRL] = v;
                if((v & START) != 0)
                {
                    StartPio(v);
                }
                return;
            case TXFIFO:
                if(pioActive)
                {
                    for(var i = 0; i < 4 && tx.Count < pioBytes; i++)
                    {
                        tx.Add((byte)(v >> (8 * i)));
                    }
                    if(tx.Count >= pioBytes)
                    {
                        Execute(pioInstr, pioAddr, pioHasAddr, tx.ToArray(), 0, null);
                        pioActive = false;
                        Raise(CMDCMP);
                    }
                }
                return;
            case INTEN:
                regs[INTEN] = v;
                UpdateIrq();
                return;
            case INTCLR:
                intstat &= ~v;
                UpdateIrq();
                return;
            case INTSET:
                Raise(v);
                return;
            case DMACFG:
                regs[DMACFG] = v;
                if((v & DMAEN_MSK) != 0)
                {
                    RunDma();
                }
                return;
            case CQENDIDX:
                regs[CQENDIDX] = v;
                if((Get(CQCFG) & 1) != 0)
                {
                    RunCq();
                }
                return;
            case CQCFG:
                regs[CQCFG] = v;
                if((v & 1) != 0 && (Get(CQENDIDX) & 0xFF) != (Get(CQCURIDX) & 0xFF))
                {
                    RunCq();
                }
                return;
            default:
                regs[o] = v;
                return;
            }
        }

        private uint Get(long o)
        {
            return regs.TryGetValue(o, out var v) ? v : 0;
        }

        private void Raise(uint bits)
        {
            intstat |= bits;
            UpdateIrq();
        }

        private void UpdateIrq()
        {
            IRQ.Set((intstat & Get(INTEN)) != 0);
        }

        private void StartPio(uint ctrl)
        {
            var bytes = (int)(ctrl >> 16);
            var txDir = (ctrl & TXRX) != 0;
            pioInstr = (ctrl & SENDI) != 0 ? (int)(Get(INSTR) & 0xFFFF) : -1;
            pioHasAddr = (ctrl & SENDA) != 0;
            pioAddr = pioHasAddr ? Get(ADDR) : 0;
            rx.Clear();
            tx.Clear();
            if(txDir)
            {
                pioBytes = bytes;
                if(bytes == 0)
                {
                    Execute(pioInstr, pioAddr, pioHasAddr, new byte[0], 0, null);
                    Raise(CMDCMP);
                }
                else
                {
                    pioActive = true;
                }
                return;
            }
            var buf = new byte[bytes];
            Execute(pioInstr, pioAddr, pioHasAddr, null, bytes, buf);
            for(var i = 0; i < bytes; i += 4)
            {
                uint w = 0;
                for(var j = 0; j < 4 && i + j < bytes; j++)
                {
                    w |= (uint)buf[i + j] << (8 * j);
                }
                rx.Enqueue(w);
            }
            Raise(CMDCMP);
        }

        private void RunDma()
        {
            var cfg = Get(DMACFG);
            var toDevice = (cfg & DMADIR) != 0;
            var target = (ulong)Get(DMATARGADDR);
            var dev = Get(DMADEVADDR);
            var count = (int)(Get(DMATOTCOUNT) & 0x00FFFFFF);
            var instr = Get(DEV0INSTR);
            var bus = machine.GetSystemBus(this);
            // DMA instruction and address phases follow DEV0XIP.XIPSENDI0 / XIPSENDA0.
            var hasAddr = (Get(DEV0XIP) & XIPSENDA) != 0;
            var hasInstr = (Get(DEV0XIP) & XIPSENDI) != 0;
            regs[DMASTAT] = DMATIP;
            if(toDevice)
            {
                var data = bus.ReadBytes(target, count);
                Execute(hasInstr ? (int)(instr & 0xFFFF) : -1, dev, hasAddr, data, 0, null);
            }
            else
            {
                var buf = new byte[count];
                Execute(hasInstr ? (int)(instr >> 16) : -1, dev, hasAddr, null, count, buf);
                bus.WriteBytes(buf, target);
            }
            regs[DMASTAT] = DMACPL;
            regs[DMACFG] = cfg & ~DMAEN_MSK;
            Raise(DCMP | CMDCMP);
        }

        private void RunCq()
        {
            var bus = machine.GetSystemBus(this);
            var addr = (ulong)Get(CQADDR);
            var cur = Get(CQCURIDX) & 0xFF;
            var end = Get(CQENDIDX) & 0xFF;
            regs[CQSTAT] = 1;
            var guard = 0;
            while(cur != end && guard++ < 4096)
            {
                var a = bus.ReadDoubleWord(addr);
                var v = bus.ReadDoubleWord(addr + 4);
                addr += 8;
                if(a == BaseAddress() + CQCURIDX)
                {
                    cur = v & 0xFF;
                    regs[CQCURIDX] = cur;
                    continue;
                }
                bus.WriteDoubleWord(a, v);
            }
            regs[CQADDR] = (uint)addr;
            regs[CQCURIDX] = end;
            regs[CQSTAT] = 2;
            Raise(CQCMP | CQUPD);
        }

        private ulong BaseAddress()
        {
            foreach(var r in machine.GetSystemBus(this).GetRegistrationPoints(this))
            {
                return r.Range.StartAddress;
            }
            return 0;
        }

        // ---- the panel ---------------------------------------------------------------------------

        private void Execute(int op, uint addr, bool hasAddr, byte[] txData, int rxLen, byte[] rxBuf)
        {
            var mode = string.Format("{0}/{1}", Get(DEV0CFG) & 0x1F, (Get(DEV0XIP) >> 8) & 0xF);
            if(rxBuf != null)
            {
                Reply(op, addr, hasAddr, rxBuf);
            }
            else if(Variant == 0 && op == JbdPixelWrite && hasAddr)
            {
                Pixels(addr, txData);
            }
            else if(Variant == 1 && op < 0 && hasAddr && addr == A6FrameAddr)
            {
                Array.Copy(txData, frame, Math.Min(txData.Length, frame.Length));
                PixelBytes += (ulong)txData.Length;
                Frames++;
            }
            else if(Variant == 1 && op < 0 && !hasAddr && txData != null && txData.Length == 3 &&
                    (txData[0] == 0x78 || txData[0] == 0x7A))
            {
                a6[(txData[0] == 0x7A ? 0x100 : 0) | txData[1]] = txData[2];
            }
            if(Variant == 0 && op == JbdCommit)
            {
                Commits++;
            }
            Commands++;
            var data = rxBuf ?? txData ?? new byte[0];
            var hex = new StringBuilder();
            for(var i = 0; i < data.Length && i < 64; i++)
            {
                hex.Append(data[i].ToString("X2"));
            }
            log.AppendFormat("{0} {1} {2} {3} {4} {5} {6}\n", seq++, mode, op < 0 ? "-" : op.ToString("X2"),
                hasAddr ? addr.ToString("X8") : "-", rxBuf != null ? "rx" : "tx", data.Length, hex);
            if(Trace > 0)
            {
                this.Log(LogLevel.Warning, "panel op {0:X2} mode {1} addr {2:X8} {3} {4}", op, mode, addr,
                    rxBuf != null ? "rx" : "tx", data.Length);
            }
        }

        private void Reply(int op, uint addr, bool hasAddr, byte[] buf)
        {
            byte[] v;
            if(Variant == 1)
            {
                // {0x79 | 0x7B, reg} as a 2-byte address phase.
                var bank = ((addr >> 8) & 0xFF) == 0x7B ? 0x100 : 0;
                var key = bank | (int)(addr & 0xFF);
                v = new[] { a6.TryGetValue(key, out var r) ? r : A6Reset(key) };
            }
            else
            {
                switch(op)
                {
                case 0x9F: v = JbdChipId; break;
                case 0x05: v = new[] { (byte)Status1 }; break;
                case 0x35: v = new[] { (byte)Status2 }; break;
                case 0x81: v = JbdDieId; break;
                default: v = new byte[] { 0 }; break;
                }
            }
            for(var i = 0; i < buf.Length; i++)
            {
                buf[i] = i < v.Length ? v[i] : (byte)0;
            }
        }

        // JBD 0x62: address word = ((row << 10) | col) << 8 | 0xFF (hardware.md). col is a byte column
        // here (2 pixels per byte) [I]; the frame is stored row-major, 320 bytes per row, as sent.
        private void Pixels(uint addr, byte[] data)
        {
            var word = addr >> 8;
            var row = (int)((word >> 10) & 0x1FF);
            var col = (int)(word & 0x3FF);
            var off = row * RowBytes + col;
            // A whole frame (153 602 bytes) runs on across rows; a row write stops at the row end
            // (its 2 trailing bytes are not pixels).
            var n = data.Length >= FrameBytes ? FrameBytes : Math.Min(data.Length, RowBytes - col);
            for(var i = 0; i < n && off + i < frame.Length; i++)
            {
                frame[off + i] = data[i];
            }
            PixelBytes += (ulong)data.Length;
        }

        private static byte A6Reset(int key)
        {
            switch(key)
            {
            case 0x00: return 0x36; // checked after init
            case 0x06: return 0x01; // chip ID
            case 0x62: return 0x77; // panel health
            case 0xE7: return 0x08; // coarse brightness
            case 0xD8: return 0x20;
            default: return 0;
            }
        }

        private readonly Dictionary<int, byte> a6 = new Dictionary<int, byte>();
        private readonly IMachine machine;
        private readonly byte[] frame;
        private readonly StringBuilder log;
        private ulong seq;
        private Dictionary<long, uint> regs;
        private Queue<uint> rx;
        private List<byte> tx;
        private bool pioActive, pioHasAddr;
        private int pioBytes, pioInstr;
        private uint pioAddr, intstat;

        public const int RowBytes = 320, FrameBytes = 320 * 480;
        private const int JbdPixelWrite = 0x62, JbdCommit = 0x97;
        private const uint A6FrameAddr = 0x32002C00;
        private static readonly byte[] JbdChipId = { 0x00, 0x40, 0x10, 0x00 };
        private static readonly byte[] JbdDieId = { 0x57, 0x49, 0x53, 0x50, 0x2D, 0x52, 0x45, 0x4E, 0x4F, 0x44, 0x45, 0x01 };

        private const long CTRL = 0x000, ADDR = 0x008, INSTR = 0x00C, TXFIFO = 0x010, RXFIFO = 0x014;
        private const long TXENTRIES = 0x018, RXENTRIES = 0x01C, DEV0CFG = 0x084, DEV0XIP = 0x090, DEV0INSTR = 0x094;
        private const long DMACFG = 0x100, DMASTAT = 0x104, DMATARGADDR = 0x108, DMADEVADDR = 0x10C, DMATOTCOUNT = 0x110;
        private const long INTEN = 0x200, INTSTAT = 0x204, INTCLR = 0x208, INTSET = 0x20C;
        private const long CQCFG = 0x2A0, CQADDR = 0x2A8, CQSTAT = 0x2AC, CQCURIDX = 0x2C0, CQENDIDX = 0x2C4;
        private const uint START = 1, STATUS = 2, BUSY = 4, SENDA = 1 << 5, SENDI = 1 << 6, TXRX = 1 << 7;
        private const uint XIPSENDA = 1 << 6, XIPSENDI = 1 << 7;
        private const uint DMAEN_MSK = 3, DMADIR = 4, DMATIP = 1, DMACPL = 2;
        private const uint CMDCMP = 1, DCMP = 1 << 6, CQCMP = 1 << 8, CQUPD = 1 << 9;
    }
}
