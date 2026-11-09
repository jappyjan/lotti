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
// logged, not acted on, so the stock app's own PMIC set-up after a release cannot reset the run,
// unless a case sets ActOnWrites (rung4.md, "W24 result and analysis", Renode changes): then the
// timer registers act as on the nPM1300. TIMERCONFIG (07 05) MODE bits 2:0 (1 = watchdog warning,
// 2 = watchdog reset) and bit 3 the prescaler (2 ms ticks when set, 16 ms when clear: stock's 0x0a
// with target 0x3c00 is 30.72 s); the target (07 08..0A, MSB first) takes effect on the strobe
// (07 03 01); 07 00 01 starts the timer (armed if MODE is a watchdog), 07 01 01 stops it.
//
// Power cycle (W24): when the watchdog expires the PMIC resets itself, so AckPowerCycle (the
// harness acknowledges the expiry and cuts the Apollo's power) also writes every register given
// by SetPowerOn into the PMIC's register file: the nPM1300's power-on values as the W24 snapshot
// showed them (images/pmic-poweron-w24.json). A pmic_read afterwards sees the charger off and the
// watchdog disarmed, as on the left temple.
//
// PmicPcLog: one line per PMIC data write with the PC that issued its CMD ("<ms> pc 0x<pc>
// wb=<0|1> write <bytes>"), so a case can prove which code made which write (Wisp Boot's only one is the
// kick 07 04 01).
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
// Register file across Apollo resets (KeepRegisters, set by the native-1 case): the nPM1300 is a
// separate chip, so what was written to it (and what SetRegister <reg> <value> preloads, e.g. the
// configuration stock left, images/pmic-baseline-w21.json) is still there after an Apollo reset;
// G2Iom's own register file is rebuilt at every reset, so the model replays it. A power cycle
// replaces it with the power-on values.
//
// Monitor: Arm <s>, Disarm, Armed, Kicks, Expiries, LastKickMs, PowerCyclePending, AckPowerCycle,
// PmicLog (one line per PMIC write), PmicPcLog, ActOnWrites, SetPowerOn <reg> <value>, PeriodMs,
// KeepRegisters, SetRegister <reg> <value>.
using System;
using System.Collections.Generic;
using System.Text;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.G2emu;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispPmicWdt : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public WispPmicWdt(IMachine machine)
        {
            this.machine = machine;
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

        public bool ActOnWrites { get; set; }
        public long PeriodMs => periodMs;

        public void SetPowerOn(int reg, int value)
        {
            powerOn[reg] = (byte)value;
        }

        public bool KeepRegisters { get; set; }

        public void SetRegister(int reg, int value)
        {
            kept[reg] = (byte)value;
            Poke(reg, (byte)value);
        }

        // One register into G2Iom's PMIC register file, as a write transaction no code made.
        private void Poke(int reg, byte value)
        {
            var saved = iom.ReadDoubleWord(0x2C4);
            iom.WriteDoubleWord(0x2C4, 0x6B);
            iom.WriteDoubleWord(0x10C, (uint)(((reg >> 8) & 0xFF) | ((reg & 0xFF) << 8) | (value << 16)));
            iom.WriteDoubleWord(0x120, (3u << 8) | 1);
            iom.WriteDoubleWord(0x2C4, saved);
        }

        public void AckPowerCycle()
        {
            PowerCyclePending = false;
            // The PMIC's own power cycle: its registers back at their power-on values.
            kept.Clear();
            foreach(var kv in powerOn)
            {
                kept[kv.Key] = kv.Value;
                Poke(kv.Key, kv.Value);
            }
            timerConfig = 0;
            target = latched = 0;
            log.AppendLine($"{nowMs} ms power-on values restored ({powerOn.Count} registers)");
        }

        public string PmicPcLog()
        {
            return pcLog.ToString();
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
            if(KeepRegisters)
            {
                foreach(var kv in kept)
                {
                    Poke(kv.Key, kv.Value);
                }
            }
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
            for(var i = 2; i < wire.Count; i++)
            {
                kept[((wire[0] << 8) | wire[1]) + i - 2] = wire[i];
            }
            if(wire.Count > 2)
            {
                var pc = machine.SystemBus.TryGetCurrentCPU(out var cpu) ? (ulong)((ICPUWithRegisters)cpu).PC : 0;
                // wb=1: Wisp Boot's services table is in MRAM, so a PC in [0x438000, 0x448000) is Wisp
                // Boot's (stock's own code lives there once stock is installed).
                var wb = machine.SystemBus.ReadDoubleWord(0x438200) == 0x31534257 ? 1 : 0;
                pcLog.AppendLine($"{nowMs} pc 0x{pc:X} wb={wb} write {hex}");
                if(ActOnWrites && wire[0] == 0x07)
                {
                    Timer(wire);
                }
            }
            if(wire.Count == 3 && wire[0] == 0x07 && wire[1] == 0x04 && wire[2] == 0x01)
            {
                Kicks++;
                LastKickMs = nowMs;
                lastKickMs = nowMs;
            }
        }

        // The nPM1300 TIMER block's registers (ActOnWrites).
        private void Timer(List<byte> wire)
        {
            for(var i = 2; i < wire.Count; i++)
            {
                var reg = wire[1] + i - 2;
                var v = wire[i];
                switch(reg)
                {
                case 0x00: // TASKTIMEREN
                    var mode = timerConfig & 7;
                    if(v == 1 && (mode == 1 || mode == 2))
                    {
                        periodMs = latched * ((timerConfig & 8) != 0 ? 2 : 16);
                        lastKickMs = nowMs;
                        Armed = periodMs > 0;
                        log.AppendLine($"{nowMs} ms armed by a write: {periodMs} ms");
                    }
                    break;
                case 0x01: // TASKTIMERDIS
                    if(v == 1)
                    {
                        Armed = false;
                        log.AppendLine($"{nowMs} ms disarmed by a write");
                    }
                    break;
                case 0x03: // TASKTIMERTARGETSTROBE
                    if(v == 1)
                    {
                        latched = target;
                    }
                    break;
                case 0x05:
                    timerConfig = v;
                    break;
                case 0x08:
                    target = (target & 0x00FFFF) | (v << 16);
                    break;
                case 0x09:
                    target = (target & 0xFF00FF) | (v << 8);
                    break;
                case 0x0A:
                    target = (target & 0xFFFF00) | v;
                    break;
                }
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

        private readonly IMachine machine;
        private readonly G2Iom iom;
        private readonly StringBuilder log;
        private readonly StringBuilder pcLog = new StringBuilder();
        private readonly Dictionary<int, byte> powerOn = new Dictionary<int, byte>();
        private readonly Dictionary<int, byte> kept = new Dictionary<int, byte>();
        private int timerConfig, target, latched;
        private List<byte> push;
        private uint devcfg, offsetHi, rxBytes;
        private long nowMs, lastKickMs, periodMs;
    }
}
