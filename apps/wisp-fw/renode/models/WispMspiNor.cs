// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: one Apollo510 MSPI instance (register map: hal_ambiq CMSIS apollo510.h,
// MSPI0_Type) with a Macronix MX25U25643G 32 MiB NOR on CE0, backed by a file.
//
// What is modelled (written for the Even bootloader's AmbiqSuite 5.1 MSPI HAL and Wisp Boot):
//   * PIO transfers (am_hal_mspi_blocking_transfer): CTRL.START latches INSTR/ADDR, SENDI/SENDA,
//     TXRX and XFERBYTES. RX data appears in RXFIFO at once (RXENTRIES > 0 while words remain);
//     TX data is collected from TXFIFO and the command runs once XFERBYTES have arrived.
//     CTRL.STATUS reads 1 when the transfer is done.
//   * DMA transfers (DMACFG.DMAEN): DEV0INSTR read/write opcode, DMADEVADDR, DMATARGADDR,
//     DMATOTCOUNT, DMADIR. Completes at once: DMASTAT.DMACPL, INTSTAT.DCMP|CMDCMP.
//   * Command queue: when CQCFG.CQEN is set and CQENDIDX is written, the {address, value} pairs
//     from CQADDR are executed as bus writes (so DMA starts and flag updates in the list run);
//     CQCURIDX follows CQENDIDX, INTSTAT.CQCMP. Pause/flag waits are not modelled (logged).
//   * Interrupt: IRQ output = (INTSTAT & INTEN) != 0.
//   * NOR: RSTEN/RST, RDID (C2 25 39), RDSR/RDCR/WRSR (QE = SR bit 6, 4BYTE = CR bit 5), WREN/WRDI,
//     EN4B/EX4B, READ/FAST/QUAD reads (3- and 4-byte forms), PP/4PP (AND into the array, wraps
//     in the 256-byte page, needs WEL), SE 4K / BE 32K / BE 64K / CE (needs WEL). Every program
//     and erase completes instantly (WIP never reads 1), so a power cut lands between two NOR
//     operations, never inside one.
//
// The NOR array is non-volatile: Reset() (any machine reset, incl. the Wisp power-cut model)
// clears only the controller registers and the device's volatile state (WEL, 4-byte mode, QE is
// non-volatile and kept). Monitor: `<name> SaveImage @file`, `<name> LoadImage @file`.
// Counters for the harness: Programs, Erases, Reads (bytes).
using System;
using System.Collections.Generic;
using System.IO;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispMspiNor : IDoubleWordPeripheral, IBytePeripheral, IWordPeripheral, IKnownSize, IGPIOSender
    {
        public WispMspiNor(IMachine machine, string image = "", long norSize = 0x2000000)
        {
            this.machine = machine;
            nor = new byte[norSize];
            for(var i = 0L; i < norSize; i++)
            {
                nor[i] = 0xFF;
            }
            IRQ = new GPIO();
            if(!string.IsNullOrEmpty(image))
            {
                LoadImage(image);
            }
            sr = 0;
            Reset();
        }

        public GPIO IRQ { get; }

        public long Size => 0x1000;

        public ulong Programs { get; private set; }

        // Raised after every completed program or erase with the running total (WispProbe).
        public event Action<ulong> OpDone;
        public ulong Erases { get; private set; }
        public ulong Reads { get; private set; }
        public int Trace { get; set; }

        public void LoadImage(string path)
        {
            var data = File.ReadAllBytes(path);
            if(data.Length > nor.Length)
            {
                throw new ArgumentException($"NOR image {path} is {data.Length} bytes, device has {nor.Length}");
            }
            Array.Copy(data, nor, data.Length);
            for(var i = (long)data.Length; i < nor.Length; i++)
            {
                nor[i] = 0xFF;
            }
        }

        public void SaveImage(string path)
        {
            File.WriteAllBytes(path, nor);
        }

        public void Reset()
        {
            regs = new Dictionary<long, uint>();
            rx = new Queue<uint>();
            tx = new List<byte>();
            pioActive = false;
            intstat = 0;
            wel = false;
            fourByte = false;
            UpdateIrq();
        }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        public void WriteByte(long o, byte v) { WriteDoubleWord(o & ~3L, v); }
        public void WriteWord(long o, ushort v) { WriteDoubleWord(o & ~3L, v); }

        public uint ReadDoubleWord(long o)
        {
            if(Trace >= 3 && o != RXFIFO && o != RXENTRIES && o != CTRL)
            {
                this.Log(LogLevel.Warning, "R +0x{0:X3}", o);
            }
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
            case DMASTAT:
                return Get(DMASTAT);
            case CQSTAT:
                return Get(CQSTAT);
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
                        Execute(pioInstr, pioAddr, tx.ToArray(), 0, null);
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

        // ---- PIO ---------------------------------------------------------------------------------

        private void StartPio(uint ctrl)
        {
            var bytes = (int)(ctrl >> 16);
            var txDir = (ctrl & TXRX) != 0;
            pioInstr = (ctrl & SENDI) != 0 ? (int)(Get(INSTR) & 0xFFFF) : -1;
            pioAddr = (ctrl & SENDA) != 0 ? Get(ADDR) : 0;
            pioHasAddr = (ctrl & SENDA) != 0;
            rx.Clear();
            tx.Clear();
            if(txDir)
            {
                pioBytes = bytes;
                if(bytes == 0)
                {
                    Execute(pioInstr, pioAddr, new byte[0], 0, null);
                    pioActive = false;
                    Raise(CMDCMP);
                }
                else
                {
                    pioActive = true;
                }
            }
            else
            {
                var buf = new byte[bytes];
                Execute(pioInstr, pioAddr, null, bytes, buf);
                for(var i = 0; i < bytes; i += 4)
                {
                    uint w = 0;
                    for(var j = 0; j < 4 && i + j < bytes; j++)
                    {
                        w |= (uint)buf[i + j] << (8 * j);
                    }
                    rx.Enqueue(w);
                }
                pioActive = false;
                Raise(CMDCMP);
            }
        }

        // ---- DMA / CQ ----------------------------------------------------------------------------

        private void RunDma()
        {
            var cfg = Get(DMACFG);
            var toDevice = (cfg & DMADIR) != 0;
            var target = (ulong)Get(DMATARGADDR);
            var dev = Get(DMADEVADDR);
            var count = (int)(Get(DMATOTCOUNT) & 0x00FFFFFF);
            var instr = Get(DEV0INSTR);
            var bus = machine.GetSystemBus(this);
            regs[DMASTAT] = DMATIP;
            if(toDevice)
            {
                var data = bus.ReadBytes(target, count);
                Execute((int)(instr & 0xFFFF), dev, data, 0, null);
            }
            else
            {
                var buf = new byte[count];
                Execute((int)(instr >> 16), dev, null, count, buf);
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
            // Execute entries until the list's own write to CQCURIDX (or an index match) ends it.
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
            Raise(CQCMP);
        }

        private ulong BaseAddress()
        {
            foreach(var r in machine.GetSystemBus(this).GetRegistrationPoints(this))
            {
                return r.Range.StartAddress;
            }
            return 0;
        }

        // ---- the NOR device ----------------------------------------------------------------------

        private void Execute(int op, uint rawAddr, byte[] txData, int rxLen, byte[] rxBuf)
        {
            var a = AddressFor(op, rawAddr);
            if(Trace > 0)
            {
                this.Log(LogLevel.Warning, "NOR op 0x{0:X2} addr 0x{1:X7} tx {2} rx {3}", op, a, txData?.Length ?? 0, rxLen);
            }
            switch(op)
            {
            case 0x66: rstEnable = true; return;
            case 0x99:
                if(rstEnable)
                {
                    wel = false;
                    fourByte = false;
                }
                rstEnable = false;
                return;
            case 0x9F: Fill(rxBuf, new byte[] { 0xC2, 0x25, 0x39 }); break;
            case 0x05: Fill(rxBuf, new byte[] { (byte)(sr | (wel ? 2 : 0)) }); break;
            case 0x15: Fill(rxBuf, new byte[] { (byte)(cr | (fourByte ? 0x20 : 0)) }); break;
            case 0x06: wel = true; break;
            case 0x04: wel = false; break;
            case 0xB7: fourByte = true; break;
            case 0xE9: fourByte = false; break;
            case 0x01:
                if(wel && txData != null && txData.Length > 0)
                {
                    sr = (byte)(txData[0] & 0xFC);
                    if(txData.Length > 1)
                    {
                        cr = (byte)(txData[1] & ~0x20);
                    }
                }
                wel = false;
                break;
            case 0x03: case 0x13: case 0x0B: case 0x0C: case 0x3B: case 0x3C:
            case 0x6B: case 0x6C: case 0xBB: case 0xBC: case 0xEB: case 0xEC:
                for(var i = 0; i < rxLen; i++)
                {
                    rxBuf[i] = nor[(a + i) % nor.Length];
                }
                Reads += (ulong)rxLen;
                break;
            case 0x02: case 0x12: case 0x38: case 0x3E:
                if(!wel)
                {
                    this.Log(LogLevel.Warning, "NOR: page program 0x{0:X7} without WREN ignored", a);
                    break;
                }
                var page = a & ~0xFFL;
                for(var i = 0; i < (txData?.Length ?? 0); i++)
                {
                    var p = page + ((a + i) & 0xFF);
                    nor[p] &= txData[i];
                }
                Programs++;
                wel = false;
                OpDone?.Invoke(Programs + Erases);
                break;
            case 0x20: case 0x21: Erase(a, 0x1000); break;
            case 0x52: case 0x5C: Erase(a, 0x8000); break;
            case 0xD8: case 0xDC: Erase(a, 0x10000); break;
            case 0x60: case 0xC7: Erase(0, nor.Length); break;
            default:
                if(op >= 0)
                {
                    this.Log(LogLevel.Warning, "NOR: unmodelled opcode 0x{0:X2} (addr 0x{1:X8}, tx {2}, rx {3})", op, rawAddr, txData?.Length ?? 0, rxLen);
                }
                break;
            }
        }

        private void Erase(long a, long len)
        {
            if(!wel)
            {
                this.Log(LogLevel.Warning, "NOR: erase 0x{0:X7} without WREN ignored", a);
                return;
            }
            var s = a & ~(len - 1);
            for(var i = s; i < s + len && i < nor.Length; i++)
            {
                nor[i] = 0xFF;
            }
            Erases++;
            wel = false;
            OpDone?.Invoke(Programs + Erases);
        }

        private long AddressFor(int op, uint raw)
        {
            var intrinsic4 = op == 0x13 || op == 0x0C || op == 0x3C || op == 0x6C || op == 0xBC || op == 0xEC
                || op == 0x12 || op == 0x3E || op == 0x21 || op == 0x5C || op == 0xDC;
            return (fourByte || intrinsic4) ? (raw & 0x01FFFFFF) : (raw & 0x00FFFFFF);
        }

        private static void Fill(byte[] buf, byte[] src)
        {
            if(buf == null)
            {
                return;
            }
            for(var i = 0; i < buf.Length; i++)
            {
                buf[i] = src[i % src.Length];
            }
        }

        private readonly IMachine machine;
        private readonly byte[] nor;
        private Dictionary<long, uint> regs;
        private Queue<uint> rx;
        private List<byte> tx;
        private bool pioActive, pioHasAddr, wel, fourByte, rstEnable;
        private int pioBytes, pioInstr;
        private uint pioAddr, intstat;
        private byte sr, cr;

        private const long CTRL = 0x000, ADDR = 0x008, INSTR = 0x00C, TXFIFO = 0x010, RXFIFO = 0x014;
        private const long TXENTRIES = 0x018, RXENTRIES = 0x01C, DEV0INSTR = 0x094;
        private const long DMACFG = 0x100, DMASTAT = 0x104, DMATARGADDR = 0x108, DMADEVADDR = 0x10C, DMATOTCOUNT = 0x110;
        private const long INTEN = 0x200, INTSTAT = 0x204, INTCLR = 0x208, INTSET = 0x20C;
        private const long CQCFG = 0x2A0, CQADDR = 0x2A8, CQSTAT = 0x2AC, CQCURIDX = 0x2C0, CQENDIDX = 0x2C4;
        private const uint START = 1, STATUS = 2, BUSY = 4, SENDA = 1 << 5, SENDI = 1 << 6, TXRX = 1 << 7;
        private const uint DMAEN_MSK = 3, DMADIR = 4, DMATIP = 1, DMACPL = 2;
        private const uint CMDCMP = 1, DCMP = 1 << 6, CQCMP = 1 << 8;
    }
}
