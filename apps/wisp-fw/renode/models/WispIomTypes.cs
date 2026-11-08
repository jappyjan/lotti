// SPDX-License-Identifier: MIT
// Wisp rung-3 / W18 Renode model: IOM0..6 (0x40050000) as g2emu's G2Iom (third_party/g2emu, MIT,
// unmodified, one private instance doing all the work) with one register made silicon-like:
// SUBMODCTRL (0x11C) reads its submodule types, SMOD0TYPE = 0 (SPI) and SMOD1TYPE = 1 (I2C), on
// top of whatever was written, as the Apollo510's read-only type fields do (hal_ambiq apollo510.h).
// hal_ambiq's am_hal_iom_enable() checks those types before it enables a submodule; G2Iom's plain
// storage reads 0, so Zephyr's I2C driver (the real Wisp app behind Wisp Boot, rung4.md G6) failed
// to enable every bus. The stock bootloader and app never relied on it. IOM7 is WispPmicWdt, which
// does the same.
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.G2emu;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispIomTypes : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public WispIomTypes(IMachine machine, long size = 0x7000)
        {
            this.size = size;
            iom = new G2Iom(machine, size);
        }

        public long Size => size;

        public void Reset() { iom.Reset(); }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        public uint ReadDoubleWord(long o) { return Types(o, iom.ReadDoubleWord(o)); }
        public void WriteByte(long o, byte v) { iom.WriteByte(o, v); }
        public void WriteWord(long o, ushort v) { iom.WriteWord(o, v); }
        public void WriteDoubleWord(long o, uint v) { iom.WriteDoubleWord(o, v); }

        public static uint Types(long o, uint v)
        {
            return (o & 0xFFF) == 0x11C ? (v & ~0xEEu) | (1u << 5) : v;
        }

        private readonly G2Iom iom;
        private readonly long size;
    }
}
