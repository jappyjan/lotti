/* SPDX-License-Identifier: MIT
 * stage-0: the Wisp app slot at 0x448000 (behind Wisp Boot's 64 KiB); RAM is the first 64 KiB of
 * DTCM, clear of Wisp Boot's RAM (0x20370000+, the diagnostics record first). */
MEMORY
{
	MRAM (rx) : ORIGIN = 0x00448000, LENGTH = 0x10000
	RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x10000
}
ENTRY(stage0_reset)
SECTIONS
{
	.text : {
		KEEP(*(.vectors))
		*(.text*) *(.rodata*)
		. = ALIGN(8);
	} > MRAM
	.ARM.exidx : { *(.ARM.exidx*) } > MRAM
	__data_load = LOADADDR(.data);
	.data : { __data_start = .; *(.data*) . = ALIGN(8); __data_end = .; } > RAM AT > MRAM
	.bss (NOLOAD) : { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(8); __bss_end = .; } > RAM
	__stack_top = ORIGIN(RAM) + LENGTH(RAM);
	ASSERT(__bss_end + 0x2000 <= __stack_top, "stage-0: less than 8 KiB of stack")
	/DISCARD/ : { *(.ARM.attributes) *(.comment) }
}
