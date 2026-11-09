// SPDX-License-Identifier: MIT
// Wisp Renode model: the Apollo510 STIMER (0x40008800), Renode's Apollo4 system timer unchanged,
// plus RSTGEN.STAT. hal_ambiq's apollo510.h puts STAT at RSTGEN + 0x885C = 0x4000885C, which lies
// inside the STIMER's window (STIMER + 0x5C, a reserved word there), so this model serves that one
// word from WispRstGen.Stat (the reset cause). Wisp Boot reads it at every boot (wisp_diag.h, D1).
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Timers;

namespace Antmicro.Renode.Peripherals.Wisp
{
    public class WispStimer : AmbiqApollo4_SystemTimer
    {
        public WispStimer(IMachine machine, WispRstGen rstgen) : base(machine)
        {
            this.rstgen = rstgen;
        }

        public override uint ReadDoubleWord(long offset)
        {
            return offset == StatOffset ? rstgen.Stat : base.ReadDoubleWord(offset);
        }

        public override void WriteDoubleWord(long offset, uint value)
        {
            if(offset == StatOffset)
            {
                this.Log(LogLevel.Warning, "RSTGEN.STAT written: 0x{0:X8}", value);
                WispStrict.Note(machine, 0x4000885C, value, true);
                rstgen.Stat = value;
                return;
            }
            base.WriteDoubleWord(offset, value);
        }

        private const long StatOffset = 0x5C;
        private readonly WispRstGen rstgen;
    }
}
