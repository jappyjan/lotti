// SPDX-License-Identifier: MIT
// Wisp W18 Renode model: IOM7 (0x40057000) with the nPM1300's watchdog behind it, for the temple
// watchdog cases of tests/boot/w18.py (docs/wisp/recovery.md, "The temple's watchdog").
//
// Every access is forwarded unchanged to a private g2emu G2Iom (third_party/g2emu/cs/G2Iom.cs,
// one IOM, the same device map with the PMIC at 0x6B), so IOM7 behaves exactly as in the rest of
// the platform. On top of that the model decodes each write transaction to 0x6B into its wire
// bytes (FIFOPUSH words low byte first, OFFSETCNT offset bytes highest first, as the datasheet
// text in apollo510.h says) and logs it. The bytes 07 04 01 (TIMER TASKWDOGKICK = 1) are a kick.
//
// The watchdog: on silicon the stock app arms the nPM1300 timer (reset mode, 30.72 s) and kicks it
// every second; an Apollo510 reset does not stop it. Here the harness arms it from the monitor
// (`pmicwdt Arm <seconds>`: as if the app had kicked it just now) with a period in virtual time.
// Renode runs a loader exchange in microseconds of virtual time, not 17.5 ms, so the harness uses
// a short period; the kick interval of the RAM programs (1024 RTOS ticks, one second) is real.
// When the period passes without a kick, the PMIC power-cycles the temple: the model disarms
// (the PMIC's registers are reset by its own power cycle) and sets PowerCyclePending; the harness
// then cuts power from the monitor (`rstgen PowerCut`, between two RunFor steps, so up to one step
// late). A reset requested from this model's clock entry while a lockstep host was attached left
// the emulation stalled after the host detached, so the reset goes the harness's well-trodden
// way. An Apollo510 reset leaves the watchdog as it is: the PMIC is a separate chip. Writes that arm or reconfigure the timer (07 00, 07 01, 07 05, 07 08..0A) are
// logged, not acted on, so the stock app's own PMIC set-up after a release cannot reset the run.
//
// Reads (for pmic_read.bin, rung4.md G3): G2Iom serves a READ from the register the previous
// write named and always reports FIFOPTR = 0x00202000. The stock app reads that way (an address
// write, then a READ). pmic_read.bin uses the IOM's offset phase instead (READ with OFFSETCNT 2:
// OFFSETHI, then OFFSETLO, a repeated start, the data), so for such a READ this model first hands
// G2Iom the offset bytes as an address write of its own (not logged: no write reaches the PMIC),
// and FIFOPTR's FIFO1SIZ counts the bytes of the last READ (whole words, as the HAL pops them)
// down to 0 as FIFOPOP is read, so a program can see an empty or a filled receive FIFO.
//
// SUBMODCTRL reads its submodule types as on silicon (WispIomTypes.cs explains why).
//
// Monitor: Arm <s>, Disarm, Armed, Kicks, Expiries, LastKickMs, PowerCyclePending, AckPowerCycle,
// PmicLog (one line per PMIC write).
using System;
using System.Collections.Generic;
using System.Text;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.G2emu;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispPmicWdt : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public WispPmicWdt(IMachine machine)
        {
            iom = new G2Iom(machine, 0x1000);
            log = new StringBuilder();
            push = new List<byte>();
            machine.ClockSource.AddClockEntry(new ClockEntry(1, 1000, Tick, this, "pmic-wdt-ms", true, Direction.Ascending));
        }

        public long Size => 0x1000;

        public bool Armed { get; private set; }
        public ulong Kicks { get; private set; }
        public ulong Expiries { get; private set; }
        public long LastKickMs { get; private set; } = -1;
        public bool PowerCyclePending { get; private set; }

        public void AckPowerCycle()
        {
            PowerCyclePending = false;
        }

        public void Arm(double seconds)
        {
            periodMs = (long)Math.Round(seconds * 1000);
            lastKickMs = nowMs;
            Armed = true;
            log.AppendLine($"{nowMs} ms armed {periodMs} ms");
        }

        public void Disarm()
        {
            Armed = false;
            log.AppendLine($"{nowMs} ms disarmed");
        }

        public string PmicLog()
        {
            return log.ToString();
        }

        // An Apollo510 reset resets IOM7, not the PMIC: the watchdog state stays.
        public void Reset()
        {
            iom.Reset();
            push.Clear();
            devcfg = 0;
            offsetHi = 0;
            rxBytes = 0;
        }

        // Byte and halfword reads go through ReadDoubleWord, so FIFOPTR, FIFOPOP and SUBMODCTRL
        // behave the same at every width.
        public byte ReadByte(long offset) { return (byte)(ReadDoubleWord(offset & ~3L) >> (int)(8 * (offset & 3))); }
        public ushort ReadWord(long offset) { return (ushort)(ReadDoubleWord(offset & ~3L) >> (int)(8 * (offset & 2))); }
        public uint ReadDoubleWord(long offset)
        {
            switch(offset & 0xFFF)
            {
            case 0x100: // FIFOPTR: FIFO1SIZ (bits 23:16) from the last READ
                return (iom.ReadDoubleWord(offset) & 0xFF00FFFFu) | (Math.Min(rxBytes, 0xFFu) << 16);
            case 0x108: // FIFOPOP: one word out of the receive FIFO
                rxBytes = rxBytes >= 4 ? rxBytes - 4 : 0;
                return iom.ReadDoubleWord(offset);
            case 0x11C: // SUBMODCTRL: the submodule types, SMOD0 = SPI (0), SMOD1 = I2C (1)
                return (iom.ReadDoubleWord(offset) & ~0xEEu) | (1u << 5);
            }
            return iom.ReadDoubleWord(offset);
        }
        public void WriteByte(long offset, byte value) { Observe(offset, value, 1); iom.WriteByte(offset, value); }
        public void WriteWord(long offset, ushort value) { Observe(offset, value, 2); iom.WriteWord(offset, value); }
        public void WriteDoubleWord(long offset, uint value) { Observe(offset, value, 4); iom.WriteDoubleWord(offset, value); }

        private void Observe(long offset, uint value, int width)
        {
            switch(offset & 0xFFF)
            {
            case 0x10C: // FIFOPUSH: like G2Iom, a whole word of bytes per write, low byte first
                for(var i = 0; i < 4; i++)
                {
                    push.Add((byte)(value >> (8 * i)));
                }
                return;
            case 0x128: // OFFSETHI
                offsetHi = value;
                return;
            case 0x2C4: // DEVCFG
                devcfg = value & 0x7F;
                return;
            case 0x120: // CMD
                if((value & 0xF) == 2)
                {
                    Read(value);
                }
                Command(value);
                return;
            }
        }

        private void Read(uint cmd)
        {
            var tsize = (cmd >> 8) & 0xFFF;
            var offsetCount = (int)((cmd >> 4) & 7);
            rxBytes = (tsize + 3) & ~3u;
            if(offsetCount == 0)
            {
                return;
            }
            uint word = 0;
            var n = 0;
            for(var i = offsetCount - 1; i >= 1; i--, n++)
            {
                word |= ((offsetHi >> (8 * (i - 1))) & 0xFF) << (8 * n);
            }
            word |= (cmd >> 24) << (8 * n);
            iom.WriteDoubleWord(0x10C, word);
            iom.WriteDoubleWord(0x120, ((uint)offsetCount << 8) | 1);
        }

        private void Command(uint cmd)
        {
            var data = push;
            push = new List<byte>();
            if((cmd & 0xF) != 1 || devcfg != 0x6B)
            {
                return;
            }
            var tsize = (int)((cmd >> 8) & 0xFFF);
            var offsetCount = (int)((cmd >> 4) & 7);
            var wire = new List<byte>();
            for(var i = offsetCount - 1; i >= 1; i--)
            {
                wire.Add((byte)(offsetHi >> (8 * (i - 1))));
            }
            if(offsetCount > 0)
            {
                wire.Add((byte)(cmd >> 24));
            }
            for(var i = 0; i < Math.Min(tsize, data.Count); i++)
            {
                wire.Add(data[i]);
            }
            var hex = BitConverter.ToString(wire.ToArray()).Replace("-", " ").ToLowerInvariant();
            log.AppendLine($"{nowMs} ms write {hex}");
            if(wire.Count == 3 && wire[0] == 0x07 && wire[1] == 0x04 && wire[2] == 0x01)
            {
                Kicks++;
                LastKickMs = nowMs;
                lastKickMs = nowMs;
            }
        }

        // Every 1 ms of virtual time.
        private void Tick()
        {
            nowMs++;
            if(Armed && nowMs - lastKickMs >= periodMs)
            {
                Armed = false;
                Expiries++;
                log.AppendLine($"{nowMs} ms expired: power cycle");
                this.Log(LogLevel.Info, "nPM1300 watchdog expired -> power cycle");
                PowerCyclePending = true;
            }
        }

        private readonly G2Iom iom;
        private readonly StringBuilder log;
        private List<byte> push;
        private uint devcfg, offsetHi, rxBytes;
        private long nowMs, lastKickMs, periodMs;
    }
}
