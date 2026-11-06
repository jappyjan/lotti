// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: Apollo510 ADC (0x40038000) just far enough for the Even bootloader's
// "HwConfig" board-detect read (3 single-slot conversions; it polls FIFO.COUNT, bits 27:20, then
// pops FIFOPR). Every conversion returns the same sample, which the stock code turns into about
// 1 V. Register offsets: hal_ambiq CMSIS apollo510.h (ADC_Type). Writes are stored and ignored.
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispAdc : IDoubleWordPeripheral, IKnownSize
    {
        public WispAdc(IMachine machine, uint sample = 3442, uint slot = 3)
        {
            this.sample = sample;
            this.slot = slot;
            Reset();
        }

        public void Reset()
        {
            mem = new Dictionary<long, uint>();
        }

        public long Size => 0x1000;

        public uint ReadDoubleWord(long o)
        {
            switch(o)
            {
            case FIFO:      // COUNT (27:20) = 1, then the sample: slot 30:28? kept as FIFOPR
            case FIFOPR:
                return o == FIFO ? (1u << 20) | Entry() : Entry();
            default:
                return mem.TryGetValue(o, out var v) ? v : 0;
            }
        }

        public void WriteDoubleWord(long o, uint v)
        {
            mem[o] = v;
        }

        // FIFO data: SLOTNUM 30:28, DATA 19:6 (14-bit) as AmbiqSuite am_hal_adc_samples_read decodes it.
        private uint Entry()
        {
            return ((slot & 7) << 28) | ((sample & 0x3FFF) << 6);
        }

        private const long FIFO = 0x38, FIFOPR = 0x3C;
        private readonly uint sample, slot;
        private Dictionary<long, uint> mem;
    }
}
