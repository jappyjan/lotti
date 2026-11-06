//
// Even G2 Apollo510B -- IOM0..7 (I2C master) behavioural model, native C# port of
// g2emu/py/iom_i2c.py (same register protocol, same device maps, same side effects).
// Loaded on the fly by Renode: `include @G2Iom.cs` in the .resc BEFORE the platform, then
// `iom: G2emu.G2Iom @ sysbus 0x40050000` (size 0x8000) in the .repl.
//
// Registers (per IOM, offset & 0xFFF; IOM index = offset >> 12):
//   DEVCFG   0x2c4  <- I2C device address (7-bit)
//   FIFOPUSH 0x10c  -> TX bytes, LSB-first
//   CMD      0x120  -> (TSIZE<<8)|DIR ; DIR 1=write, 2=read
//   FIFOPOP  0x108  <- RX bytes, LSB-first
//   STATUS 0x248 = 4 (idle), INTSTAT 0x204 = 1 (CMDCMP), CMDSTAT 0x12c = 0, FIFOPTR 0x100 = 0x00202000
// Everything else is plain storage keyed by the exact access offset (like the Python dict).
//
// Device maps (docs/g2-device-registers.md):
//   nPM1300 PMIC 0x6B (16-bit reg addr, byte regs), ICM-45608 IMU 0x68/0x69 (WHO_AM_I 0x72=0x81),
//   OPT3007 ALS 0x44-0x47 (16-bit regs MSB-first: 0x7F=0x3001, 0x7E=0x5449, 0x01=0xC810);
//   any other address: ACK + zeros (benign stub, NOT faithful).
//
// Bus-completion polls: STATUS/INTSTAT already report "done" on the first read, so every
// blocking transfer costs one poll (as in the Python model).
//
// ICM-45608 (repl `icmModel: true`, the default): the IMU is modelled as an ICM-456xx register file
// instead of plain storage, because the firmware's TDK driver depends on four hardware behaviours:
//   * Indirect registers (IREG): IREG_ADDR_15_8 0x7C / IREG_ADDR_7_0 0x7D latch a 16-bit address,
//     IREG_DATA 0x7E reads/writes that register and auto-increments the address (driver 0x528208
//     read_ireg: write 0x7C+2 bytes, read 0x7E; 0x52827a write_ireg: write 0x7C+3 bytes, 0x7E...).
//   * IPREG_MISC 0xA297 bit 1 (EDMP idle) reads 1: the on-chip eDMP is not emulated, so it is
//     always idle, as on silicon once an on-demand run has finished. The driver's
//     edmp_wait_for_idle (0x527556) polls this bit with a 1 s budget in 5 us steps; with plain
//     storage it never saw the bit and spun all 200,000 passes (each pass an indirect read =
//     two IOM4 transfers + IOM4 power up/down) before giving up with INV_IMU_ERROR_TIMEOUT (-4).
//   * MISC2 0x7F bit 1 SOFT_RST self-clears and resets the register file; INT1_STATUS0 0x19 bit 7
//     (RESET_DONE) is then set, clear-on-read (also set after power-on). The driver's soft reset
//     (0x5251ec..0x525290) returns -1 if it does not see RESET_DONE.
//   * FIFO_CONFIG2 0x20 bit 7 FIFO_FLUSH self-clears (driver 0x52559c polls it, 1 s / 100 us).
//   * eDMP host commands: the driver writes a request block into the indirect space (0x58357c),
//     sets bit 0 of 0xA216 (0x583614) and then waits, WITHOUT a timeout (0x527b50), for bit 5 of
//     INT1_STATUS1 0x1A, then checks the status byte 0xA218 & 0x3D == 0. The model completes the
//     command immediately: START clears, INT1_STATUS1 bit 5 is raised (clear-on-read), status
//     stays 0. Result payloads are not computed (the eDMP firmware is not emulated).
// `icmModel: false` restores the old plain-storage behaviour (byte-identical to the original
// Python model before this change), for A/B comparison.
//
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.G2emu
{
    public class G2Iom : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IQuadWordPeripheral, IKnownSize
    {
        public G2Iom(IMachine machine, long size = 0x8000, bool icmModel = true)
        {
            this.size = size;
            this.icmModel = icmModel;
            Reset();
        }

        public void Reset()
        {
            mem = new Dictionary<long, ulong>();
            push = new Dictionary<long, List<byte>>();
            pend = new Dictionary<long, Pending>();
            lastreg = new Dictionary<long, int>();
            devs = new Dictionary<int, Device>
            {
                { 0x6B, new Device(2, 1, null) },                                          // nPM1300 PMIC
                { 0x68, Imu() },                                                           // ICM-45608 IMU
                { 0x69, Imu() },
                { 0x44, Als() }, { 0x45, Als() }, { 0x46, Als() }, { 0x47, Als() },        // OPT3007 ALS
            };
        }

        private Device Imu()
        {
            return icmModel ? new Icm456xx() : new Device(1, 1, new Dictionary<int, int> { { 0x72, 0x81 } });
        }

        private static Device Als()
        {
            return new Device(1, 2, new Dictionary<int, int> { { 0x7F, 0x3001 }, { 0x7E, 0x5449 }, { 0x01, 0xC810 } });
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

        private void Write(long offset, ulong value)
        {
            mem[offset] = value;
            var off = offset & 0xFFF;
            var iom = offset >> 12;
            if(off == FIFOPUSH_OFF)
            {
                if(!push.TryGetValue(iom, out var b))
                {
                    b = new List<byte>();
                    push[iom] = b;
                }
                b.Add((byte)value); b.Add((byte)(value >> 8)); b.Add((byte)(value >> 16)); b.Add((byte)(value >> 24));
            }
            else if(off == CMD_OFF)
            {
                var direction = (int)(value & 0x3);                 // 1=write, 2=read
                var tsize = (int)((value >> 8) & 0xFFF);
                var devAddr = (int)(Get((iom << 12) | DEVCFG_OFF) & 0x7F);
                devs.TryGetValue(devAddr, out var dev);
                if(direction == 1)                                    // WRITE (register address [+ data])
                {
                    if(!push.TryGetValue(iom, out var pb))
                    {
                        pb = new List<byte>();
                    }
                    push[iom] = new List<byte>();
                    var aw = dev != null ? dev.Aw : 1;
                    var reg = 0;
                    for(var i = 0; i < System.Math.Min(aw, pb.Count); i++)
                    {
                        reg = (reg << 8) | pb[i];
                    }
                    lastreg[iom] = reg;
                    if(dev != null && pb.Count > aw)                  // store written data bytes
                    {
                        var a = reg;
                        // Python: for bval in pb[aw:tsize]
                        var end = System.Math.Min(tsize, pb.Count);
                        for(var i = aw; i < end; i++)
                        {
                            dev.WriteReg(a, pb[i]);
                            a++;
                        }
                    }
                }
                else if(direction == 2)                               // READ (serve device map)
                {
                    lastreg.TryGetValue(iom, out var reg);
                    var outb = new List<byte>(tsize + 1);
                    if(dev != null)
                    {
                        var a = reg;
                        while(outb.Count < tsize)
                        {
                            var val16 = dev.ReadReg(a);
                            if(dev.Rw == 2)                           // 16-bit register, MSB-first
                            {
                                outb.Add((byte)(val16 >> 8));
                                outb.Add((byte)val16);
                            }
                            else
                            {
                                outb.Add((byte)val16);
                            }
                            a++;
                        }
                        if(outb.Count > tsize)
                        {
                            outb.RemoveRange(tsize, outb.Count - tsize);
                        }
                    }
                    else                                              // unknown device -> benign zeros
                    {
                        for(var i = 0; i < tsize; i++)
                        {
                            outb.Add(0);
                        }
                    }
                    pend[iom] = new Pending { Bytes = outb.ToArray(), Pos = 0 };
                }
            }
        }

        private ulong Read(long offset)
        {
            var off = offset & 0xFFF;
            var iom = offset >> 12;
            switch(off)
            {
            case STATUS_OFF:
                return 0x00000004;                                    // IDLEST, not busy, no error
            case INTSTAT_OFF:
                return 0x00000001;                                    // CMDCMP
            case CMDSTAT_OFF:
                return 0x00000000;
            case FIFOPTR_OFF:
                return 0x00202000;                                    // ample write space + read data
            case FIFOPOP_OFF:
                {
                    ulong w = 0;
                    if(pend.TryGetValue(iom, out var p))
                    {
                        for(var k = 0; k < 4; k++)
                        {
                            if(p.Pos + k < p.Bytes.Length)
                            {
                                w |= (ulong)p.Bytes[p.Pos + k] << (8 * k);
                            }
                        }
                        p.Pos += 4;
                    }
                    return w;
                }
            default:
                return Get(offset);
            }
        }

        private class Device
        {
            public Device(int aw, int rw, Dictionary<int, int> regs)
            {
                Aw = aw;
                Rw = rw;
                Regs = regs ?? new Dictionary<int, int>();
            }

            public virtual int ReadReg(int reg)
            {
                Regs.TryGetValue(reg, out var v);
                return v;
            }

            public virtual void WriteReg(int reg, int value)
            {
                Regs[reg] = value;
            }

            public readonly int Aw;
            public readonly int Rw;
            public readonly Dictionary<int, int> Regs;
        }

        // TDK InvenSense ICM-456xx (ICM-45608) register file: bank-0 direct registers plus the
        // 16-bit indirect space behind IREG_ADDR/IREG_DATA. See the header comment.
        private class Icm456xx : Device
        {
            public Icm456xx() : base(1, 1, null)
            {
                PowerOnReset();
            }

            private void PowerOnReset()
            {
                Regs.Clear();
                Regs[WHO_AM_I] = 0x81;
                ireg = new Dictionary<int, int>();
                iregAddr = 0;
                resetDone = true;                                     // POR also reports RESET_DONE
                hostCmdDone = false;
            }

            public override int ReadReg(int reg)
            {
                switch(reg)
                {
                case IREG_DATA:
                    {
                        ireg.TryGetValue(iregAddr, out var v);
                        if(iregAddr == IPREG_MISC)
                        {
                            v |= EDMP_IDLE;                           // eDMP not emulated: always idle
                        }
                        iregAddr = (iregAddr + 1) & 0xFFFF;
                        return v;
                    }
                case INT1_STATUS0:
                    {
                        var v = base.ReadReg(reg) | (resetDone ? RESET_DONE : 0);
                        resetDone = false;                            // clear-on-read
                        return v;
                    }
                case INT1_STATUS1:
                    {
                        var v = base.ReadReg(reg) | (hostCmdDone ? HOST_CMD_DONE : 0);
                        hostCmdDone = false;                          // clear-on-read
                        return v;
                    }
                default:
                    return base.ReadReg(reg);
                }
            }

            public override void WriteReg(int reg, int value)
            {
                switch(reg)
                {
                case IREG_ADDR_15_8:
                    iregAddr = (value << 8) | (iregAddr & 0xFF);
                    break;
                case IREG_ADDR_7_0:
                    iregAddr = (iregAddr & 0xFF00) | value;
                    break;
                case IREG_DATA:
                    if(iregAddr == HOST_CMD_CTRL && (value & HOST_CMD_START) != 0)
                    {
                        // eDMP host command: the request block is in the IREG/SRAM space; the eDMP
                        // runs it, clears START, leaves status 0 (no error) in 0xA218 and raises
                        // the INT1_STATUS1 completion bit. We complete it at once.
                        value &= ~HOST_CMD_START;
                        hostCmdDone = true;
                    }
                    ireg[iregAddr] = value;
                    iregAddr = (iregAddr + 1) & 0xFFFF;
                    break;
                case MISC2:
                    if((value & SOFT_RST) != 0)
                    {
                        PowerOnReset();                               // SOFT_RST self-clears
                    }
                    else
                    {
                        base.WriteReg(reg, value);
                    }
                    break;
                case FIFO_CONFIG2:
                    base.WriteReg(reg, value & ~FIFO_FLUSH);          // flush completes at once
                    break;
                default:
                    base.WriteReg(reg, value);
                    break;
                }
            }

            private Dictionary<int, int> ireg;
            private int iregAddr;
            private bool resetDone;
            private bool hostCmdDone;

            private const int INT1_STATUS0 = 0x19;
            private const int RESET_DONE = 0x80;
            private const int INT1_STATUS1 = 0x1A;
            private const int HOST_CMD_DONE = 0x20;                   // INT1_STATUS1 bit 5
            private const int HOST_CMD_CTRL = 0xA216;                 // bit 0 = start
            private const int HOST_CMD_START = 0x01;
            private const int FIFO_CONFIG2 = 0x20;
            private const int FIFO_FLUSH = 0x80;
            private const int WHO_AM_I = 0x72;
            private const int IREG_ADDR_15_8 = 0x7C;
            private const int IREG_ADDR_7_0 = 0x7D;
            private const int IREG_DATA = 0x7E;
            private const int MISC2 = 0x7F;
            private const int SOFT_RST = 0x02;
            private const int IPREG_MISC = 0xA297;
            private const int EDMP_IDLE = 0x02;
        }

        private class Pending
        {
            public byte[] Bytes;
            public int Pos;
        }

        private Dictionary<long, ulong> mem;
        private Dictionary<long, List<byte>> push;
        private Dictionary<long, Pending> pend;
        private Dictionary<long, int> lastreg;
        private Dictionary<int, Device> devs;
        private readonly long size;
        private readonly bool icmModel;

        private const long STATUS_OFF = 0x248;
        private const long INTSTAT_OFF = 0x204;
        private const long CMDSTAT_OFF = 0x12C;
        private const long FIFOPTR_OFF = 0x100;
        private const long FIFOPOP_OFF = 0x108;
        private const long FIFOPUSH_OFF = 0x10C;
        private const long CMD_OFF = 0x120;
        private const long DEVCFG_OFF = 0x2C4;
    }
}
