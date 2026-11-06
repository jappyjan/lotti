# Zephyr files carried by Wisp (Apache-2.0)

| File | Upstream | Change |
| --- | --- | --- |
| `i2c_ambiq.c` | `drivers/i2c/i2c_ambiq.c`, AmbiqMicro/ambiqzephyr `ambiq-stable` @ `89c8a36` (Apache-2.0, Antmicro) | multi-byte write-read headers packed highest byte first |

## Why `i2c_ambiq.c` is patched

For a write-then-read (`i2c_write_read()`), the fork's driver puts the register header into the
IOM's offset field with `memcpy(&trans.ui64Instr, hdr, len)`, i.e. little-endian. The Apollo510
IOM sends offset bytes **highest byte first** (`apollo510.h`, `IOM0_CMD.OFFSETCNT`: "Offset bytes
are always transmitted MSB first"), and hal_ambiq passes `ui64Instr` through unchanged
(`am_hal_iom_blocking_transfer`: `OFFSETLO = (uint8_t)ui64Instr`, `OFFSETHI = ui64Instr >> 8`).
A one-byte header is unaffected. A two-byte header `{a, b}` goes out as `b, a`.

The G2's nPM1300 uses 16-bit register addresses (`mfd_npm13xx_reg_read()` sends `{base, offset}`
as the header), so with the upstream driver every PMIC register read would hit the wrong register
on real hardware. Wisp builds this copy instead (`CONFIG_I2C_AMBIQ=n`, `CONFIG_WISP_I2C_AMBIQ=y`).
`renode/models/WispIom.cs` sends offsets the way the datasheet says, and the driver test checks
the PMIC reads (`tests/drivers/`).

Found by reading the code, not on hardware. It should go upstream; until then, to update, copy
the file again from the pinned fork and reapply the two-line change (`i2c_ambiq_hdr_to_offset`).
