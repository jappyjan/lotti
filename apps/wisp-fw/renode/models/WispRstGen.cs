// SPDX-License-Identifier: MIT
// Wisp rung-3 Renode model: Apollo510 RSTGEN (0x40000000) plus the reset semantics the fault
// harness needs. Register map: hal_ambiq CMSIS apollo510.h (RSTGEN_Type).
//
//   CFG   0x000  WDREN (bit 1): a watchdog expiry only resets the chip when this is set
//   SWPOI 0x004  write 0x1B -> software POI reset
//   SWPOR 0x008  write 0xD4 -> software POR reset
// Other offsets are plain storage.
//
// Every reset, whatever its source (SWPOI/SWPOR, AIRCR.SYSRESETREQ through Renode's NVIC,
// WispWdt, or the harness's PowerCut()), is a machine reset with these rules:
//   * kept:   MRAM (0x400000-0x800000) and the NOR array (WispMspiNor) — both non-volatile
//   * lost:   every register, the CPU, and all of SRAM: DTCM+SSRAM are filled with 0xA5 after the
//             reset, so nothing may rely on SRAM surviving (pessimistic on purpose: retained SRAM
//             after a warm reset is not guaranteed on the real chip, and a power loss clears it)
//   * restart: the Ambiq SBL is not available, so the model performs its hand-off: VTOR =
//             0x410000, MSP = word 0, PC = word 1 of the Even bootloader's vector table
// The harness reads Resets / LastCause and the reset log (one line per reset) from the monitor.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.CPU;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispRstGen : IDoubleWordPeripheral, IKnownSize
    {
        public WispRstGen(IMachine machine, ulong bootVector = 0x410000, ulong sramBase = 0x20000000, ulong sramSize = 0x00380000)
        {
            this.machine = machine;
            this.bootVector = bootVector;
            this.sramBase = sramBase;
            this.sramSize = sramSize;
            Log = new List<string>();
            pendingCause = "power-on";
            machine.MachineReset += OnMachineReset;
            regs = new Dictionary<long, uint>();
        }

        public long Size => 0x1000;

        public int Resets { get; private set; }
        public string LastCause { get; private set; } = "power-on";
        public List<string> Log { get; }

        // CFG.WDREN, read by WispWdt.
        public bool WatchdogResetEnabled => (Get(0x000) & 2) != 0;

        public void Reset()
        {
            // Registers are volatile; the reset bookkeeping is not part of the chip.
            regs = new Dictionary<long, uint>();
        }

        public uint ReadDoubleWord(long o)
        {
            return Get(o);
        }

        public void WriteDoubleWord(long o, uint v)
        {
            if(o == 0x004 && (v & 0xFF) == 0x1B)
            {
                Request("SWPOI");
                return;
            }
            if(o == 0x008 && (v & 0xFF) == 0xD4)
            {
                Request("SWPOR");
                return;
            }
            regs[o] = v;
        }

        // Harness: cut power now (same as a reset under the rules above).
        public void PowerCut()
        {
            Request("power-cut");
        }

        public void Request(string cause)
        {
            if(resetPending)
            {
                return;
            }
            resetPending = true;
            pendingCause = cause;
            this.Log(LogLevel.Info, "reset requested: {0}", cause);
            machine.RequestReset();
        }

        public string ResetLog()
        {
            return string.Join("\n", Log);
        }

        private void OnMachineReset(IMachine m)
        {
            var cause = resetPending ? pendingCause : "external (NVIC SYSRESETREQ or monitor)";
            resetPending = false;
            Resets++;
            LastCause = cause;
            Log.Add($"{Resets} {cause} at {machine.ElapsedVirtualTime.TimeElapsed}");
            var bus = machine.SystemBus;
            var fill = new byte[0x10000];
            for(var i = 0; i < fill.Length; i++)
            {
                fill[i] = 0xA5;
            }
            for(var a = sramBase; a < sramBase + sramSize; a += (ulong)fill.Length)
            {
                bus.WriteBytes(fill, a);
            }
            foreach(var cpu in bus.GetCPUs())
            {
                if(cpu is CortexM cm)
                {
                    cm.VectorTableOffset = (uint)bootVector;
                    cm.SP = bus.ReadDoubleWord(bootVector);
                    cm.PC = bus.ReadDoubleWord(bootVector + 4) & ~1u;
                }
            }
        }

        private uint Get(long o)
        {
            return regs.TryGetValue(o, out var v) ? v : 0;
        }

        private readonly IMachine machine;
        private readonly ulong bootVector, sramBase, sramSize;
        private Dictionary<long, uint> regs;
        private bool resetPending;
        private string pendingCause;
    }
}
