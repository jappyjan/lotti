# g2emu (vendored subset)

From [ithinkthisiscool/g2emu](https://github.com/ithinkthisiscool/g2emu) at commit
`dcbce06c25869dcb3b6a7221609b08e174423bb6` ("upload codebase"), MIT License — see
[LICENSE](LICENSE) (the upstream file names no copyright holder; it reads
"Copyright (c) 2026 [COPYRIGHT HOLDER]").

| File                 | Upstream path              | Changes |
| -------------------- | -------------------------- | ------- |
| `cs/G2ClkgenRtc.cs`  | `g2emu/cs/G2ClkgenRtc.cs`  | none    |
| `cs/G2Pwrctrl.cs`    | `g2emu/cs/G2Pwrctrl.cs`    | none    |
| `cs/G2Uart1Shell.cs` | `g2emu/cs/G2Uart1Shell.cs` | none    |
| `cs/G2Iom.cs`        | `g2emu/cs/G2Iom.cs`        | none    |

`../../renode/wisp_g2.repl` and `../../renode/wisp_g2_boot.repl` are derived from upstream
`g2emu/apollo510-m1-fast.repl` (same memory map and addresses). `wisp_g2.repl` leaves the ADC, IOM,
MSPI and Nema models out; `wisp_g2_boot.repl` (rung 3) uses `G2Iom.cs` and Wisp's own ADC, MSPI/NOR,
reset, watchdog and boot-ROM models (`../../renode/models/`).

Not vendored: g2emu's other models (ADC board detect, MSPI, Nema GPU stream, pacer),
its GTK app, and its boot recipes — those patch addresses inside Even's stock firmware, which
Wisp never commits (safety rule 9). To update: copy the files again from a newer commit and
bump the SHA here.
