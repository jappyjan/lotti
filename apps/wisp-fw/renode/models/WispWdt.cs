// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: Apollo510 watchdog (0x40024000). Register map: hal_ambiq CMSIS
// apollo510.h (WDT_Type); semantics as AmbiqSuite am_hal_wdt.c uses them.
//
//   CFG   0x000  WDTEN bit 0, INTEN bit 1, RESEN bit 2, RESVAL 15:8, INTVAL 23:16, CLKSEL 26:24
//   RSTRT 0x004  write 0xB2 -> restart (feed)
//   LOCK  0x008  write 0x3A -> CFG is locked until the next reset
//   COUNT 0x00C  ticks left before the reset fires (read only)
//   0x200..0x20C interrupt enable/status/clear/set (stored; the interrupt is not modelled)
//
// Clock: the LFRC at LfrcHz, 900 Hz by default: hal_ambiq's apollo510.h gives the LFRC as
// "approximately 900Hz" (STIMER_STCFG_CLKSEL_LFRC_NOMINAL; CLKGEN CLKOUT: "LFRC=900Hz"). Until
// 2026-11-08 this model ran it at 1024 Hz, which made Wisp Boot's watchdog 8.0 s here and about
// 9.1 s on silicon (rung4.md, "W24 result and analysis"); stage-0 measures the real rate. The
// harness may set another rate (`wdt LfrcHz <hz>`) to sweep it. CLKSEL 1 = /8, 2 = /64, 3 = /1024,
// 4 = /16384. A reset fires RESVAL ticks after the last restart (or after enabling) when WDTEN and
// RESEN are set and RSTGEN.CFG.WDREN is set; it goes through WispRstGen ("watchdog").
// The timer runs on Renode virtual time (checked every 1 ms of virtual time).
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispWdt : IDoubleWordPeripheral, IKnownSize
    {
        public WispWdt(IMachine machine, WispRstGen rstgen)
        {
            this.machine = machine;
            this.rstgen = rstgen;
            Reset();
            machine.ClockSource.AddClockEntry(new ClockEntry(1, 1000, Tick, this, "wdt-ms", true, Direction.Ascending));
        }

        public long Size => 0x1000;

        public ulong Bites { get; private set; }
        public int LfrcHz { get; set; } = 900;
        public ulong Feeds { get; private set; }

        public void Reset()
        {
            cfg = 0;
            locked = false;
            regs = new Dictionary<long, uint>();
            ticksLeft = 0;
            subTicks = 0;
        }

        public uint ReadDoubleWord(long o)
        {
            switch(o)
            {
            case 0x000: return cfg;
            case 0x00C: return (uint)Math.Max(0, ticksLeft);
            default: return regs.TryGetValue(o, out var v) ? v : 0;
            }
        }

        public void WriteDoubleWord(long o, uint v)
        {
            switch(o)
            {
            case 0x000:
                if(locked)
                {
                    this.Log(LogLevel.Warning, "CFG write 0x{0:X8} ignored: locked", v);
                    return;
                }
                var wasOn = (cfg & 1) != 0;
                cfg = v;
                if(!wasOn && (cfg & 1) != 0)
                {
                    Restart();
                }
                return;
            case 0x004:
                if((v & 0xFF) == 0xB2)
                {
                    Feeds++;
                    Restart();
                }
                return;
            case 0x008:
                if((v & 0xFF) == 0x3A)
                {
                    locked = true;
                }
                return;
            default:
                regs[o] = v;
                return;
            }
        }

        private void Restart()
        {
            ticksLeft = (int)((cfg >> 8) & 0xFF);
            subTicks = 0;
        }

        // Called every 1 ms of virtual time.
        private void Tick()
        {
            if((cfg & 1) == 0)
            {
                return;
            }
            var div = Divider();
            if(div == 0)
            {
                return;
            }
            // One WDT tick every div/LfrcHz s; this runs once a millisecond.
            subTicks += LfrcHz;
            var perTick = (long)div * 1000;
            while(subTicks >= perTick)
            {
                subTicks -= perTick;
                ticksLeft--;
            }
            if(ticksLeft <= 0 && (cfg & 4) != 0)
            {
                if(rstgen.WatchdogResetEnabled)
                {
                    Bites++;
                    this.Log(LogLevel.Info, "watchdog expired -> reset");
                    cfg = 0;
                    rstgen.Request("watchdog");
                }
                else
                {
                    ticksLeft = 0;
                }
            }
        }

        private uint Divider()
        {
            switch((cfg >> 24) & 7)
            {
            case 1: return 8;
            case 2: return 64;
            case 3: return 1024;
            case 4: return 16384;
            default: return 0; // off, or the HF crystal (not used by Wisp; not modelled)
            }
        }

        private readonly IMachine machine;
        private readonly WispRstGen rstgen;
        private Dictionary<long, uint> regs;
        private uint cfg;
        private bool locked;
        private int ticksLeft;
        private long subTicks;
    }
}
