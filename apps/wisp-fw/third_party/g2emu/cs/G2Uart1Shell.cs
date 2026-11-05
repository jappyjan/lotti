//
// Even G2 Apollo510B -- UART1 @0x4003A000 (IRQ 16) model for the firmware's FreeRTOS+CLI debug
// shell. Native C# port of g2emu/py/uart_shell.py (identical register semantics and side effects).
//
//   RX: the HAL ISR (0x58462e) only hands buffered bytes to the shell on the PL011 RECEIVE-TIMEOUT
//       interrupt (MIS bit6), so every injected byte asserts RXIS|RTIS until the FIFO drains.
//   TX: every DR write completes at once and sets the Ambiq TXCMP bit (MIS bit0), which the HAL
//       waits for after each write.
//
// PL011 subset: DR 0x00, FR 0x18, IMSC 0x38, RIS 0x3C, MIS 0x40, ICR 0x44 (rest = plain storage).
// Emulator-only registers:
//   0xFF0 W  inject ONE byte into RX
//   0xFF4 W  inject up to 4 bytes, little-endian, zero bytes skipped
//   0xFF8 R  total bytes transmitted so far
//   0xFFC R  bytes waiting in the RX FIFO
// TX bytes are appended to $G2_CAPTURE_OUT/uart1.txt (flushed at '\n' and at the '#' prompt).
// Interrupts: pend NVIC IRQ 16 by writing NVIC ISPR0 (as the Python model does).
//
using System;
using System.Collections.Generic;
using System.IO;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.G2emu
{
    public class G2Uart1Shell : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IQuadWordPeripheral, IKnownSize, IDisposable
    {
        public G2Uart1Shell(IMachine machine, long size = 0x1000)
        {
            this.machine = machine;
            this.size = size;
            outDir = "./";                    // fallback: Renode's working directory (g2emu sets G2_CAPTURE_OUT)
            try
            {
                var o = Environment.GetEnvironmentVariable("G2_CAPTURE_OUT");
                if(!string.IsNullOrEmpty(o))
                {
                    outDir = o.EndsWith("/") ? o : o + "/";
                }
            }
            catch(Exception)
            {
            }
            Reset();
        }

        public void Reset()
        {
            mem = new Dictionary<long, ulong>();
            rx = new Queue<byte>();
            ris = 0;
            tx = 0;
            Directory.CreateDirectory(outDir);
        }

        public void Dispose()
        {
            if(file != null)
            {
                file.Flush();
                file.Dispose();
                file = null;
            }
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

        private void Irq()
        {
            if((ris & Get(0x38)) != 0)
            {
                machine.GetSystemBus(this).WriteDoubleWord(NVIC_ISPR0, 1u << IRQ);
            }
        }

        private void RxPush(ulong b)
        {
            rx.Enqueue((byte)b);
            ris |= RXIS | RTIS;
            Irq();
        }

        private void TxByte(ulong b)
        {
            if(file == null)
            {
                file = new FileStream(outDir + "uart1.txt", FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
            }
            var c = (byte)b;
            file.WriteByte(c);
            if(c == (byte)'\n' || c == (byte)'#')       // flush per line / at the shell prompt
            {
                file.Flush();
            }
            tx++;
            ris |= TXCMP;
            Irq();
        }

        private void Write(long o, ulong value)
        {
            var v = value & 0xFFFFFFFF;
            switch(o)
            {
            case 0x00:
                TxByte(v);
                break;
            case 0x44:                                  // ICR
                ris &= ~v;
                if(rx.Count > 0)                        // bytes still waiting -> keep RX/RT asserted
                {
                    ris |= RXIS | RTIS;
                    Irq();
                }
                break;
            case 0x38:                                  // IMSC
                mem[o] = v;
                Irq();
                break;
            case 0xFF0:
                RxPush(v);
                break;
            case 0xFF4:
                for(var i = 0; i < 4; i++)
                {
                    var c = (v >> (8 * i)) & 0xFF;
                    if(c != 0)
                    {
                        RxPush(c);
                    }
                }
                break;
            default:
                mem[o] = v;
                break;
            }
        }

        private ulong Read(long o)
        {
            switch(o)
            {
            case 0x00:
                if(rx.Count > 0)
                {
                    var b = rx.Dequeue();
                    if(rx.Count == 0)
                    {
                        ris &= ~(RXIS | RTIS);
                    }
                    return b;
                }
                return 0;
            case 0x18:                                  // FR: TX always empty/idle, RXFE when no input
                return TXFE | (rx.Count > 0 ? 0UL : RXFE);
            case 0x3C:
                return ris;
            case 0x40:
                return ris & Get(0x38);
            case 0xFF8:
                return tx;
            case 0xFFC:
                return (ulong)rx.Count;
            default:
                return Get(o);
            }
        }

        private readonly IMachine machine;
        private readonly long size;
        private readonly string outDir;
        private Dictionary<long, ulong> mem;
        private Queue<byte> rx;
        private ulong ris;
        private ulong tx;
        private FileStream file;

        private const ulong NVIC_ISPR0 = 0xE000E200;
        private const int IRQ = 16;
        private const ulong RXIS = 0x10, TXIS = 0x20, RTIS = 0x40, TXCMP = 0x01;
        private const ulong RXFE = 0x10, TXFE = 0x80;
    }
}
