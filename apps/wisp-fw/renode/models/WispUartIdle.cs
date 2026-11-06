// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: an Ambiq/PL011 UART with nothing attached (UART0 = peer temple,
// UART2 = charging case, UART3). FR (0x18) always reads TXFE | RXFE (idle, nothing received), so
// drivers that drain RX until empty or wait for TX to finish do not spin; DR writes are dropped;
// every other offset is plain storage. No interrupt is ever raised.
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispUartIdle : IDoubleWordPeripheral, IBytePeripheral, IWordPeripheral, IKnownSize
    {
        public WispUartIdle(IMachine machine)
        {
            Reset();
        }

        public long Size => 0x1000;

        public ulong TxBytes { get; private set; }

        public void Reset()
        {
            regs = new Dictionary<long, uint>();
        }

        public uint ReadDoubleWord(long o)
        {
            if(o == 0x18)
            {
                return 0x90; // TXFE | RXFE
            }
            if(o == 0x00)
            {
                return 0;
            }
            return regs.TryGetValue(o, out var v) ? v : 0;
        }

        public void WriteDoubleWord(long o, uint v)
        {
            if(o == 0x00)
            {
                TxBytes++;
                return;
            }
            regs[o] = v;
        }

        public byte ReadByte(long o) { return (byte)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 3))); }
        public ushort ReadWord(long o) { return (ushort)(ReadDoubleWord(o & ~3L) >> (int)(8 * (o & 2))); }
        public void WriteByte(long o, byte v) { WriteDoubleWord(o & ~3L, v); }
        public void WriteWord(long o, ushort v) { WriteDoubleWord(o & ~3L, v); }

        private Dictionary<long, uint> regs;
    }
}
