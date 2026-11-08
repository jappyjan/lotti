/* SPDX-License-Identifier: MIT
 * Wisp Boot: [0x438000, 0x448000) in MRAM, the top 64 KiB of SSRAM for data/bss/stack.
 * The first 64 bytes of that RAM are the diagnostics record (wisp_diag.h, WISP_DIAG_ADDR): a
 * NOLOAD slot that the reset handler neither copies nor zeroes, so it survives into the next boot
 * whenever SRAM does.
 * The vector table is first (the Even bootloader hands off to 0x438000), the services table
 * sits at 0x438200 (boot_services.h). */
MEMORY
{
	MRAM (rx) : ORIGIN = 0x00438000, LENGTH = 0x10000
	RAM (rwx) : ORIGIN = 0x20370000, LENGTH = 0x10000
}
ENTRY(reset_handler)
SECTIONS
{
	.text : {
		KEEP(*(.vectors))
		. = 0x200;
		KEEP(*(.services))
		*(.text*) *(.rodata*)
		. = ALIGN(8);
	} > MRAM
	.ARM.exidx : { *(.ARM.exidx*) } > MRAM
	.noinit (NOLOAD) : { __noinit_start = .; KEEP(*(.noinit)) . = ALIGN(64); } > RAM
	ASSERT(__noinit_start == 0x20370000, "Wisp Boot: the diagnostics record must be first in RAM")
	__data_load = LOADADDR(.data);
	.data : { __data_start = .; *(.data*) . = ALIGN(8); __data_end = .; } > RAM AT > MRAM
	.bss (NOLOAD) : { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(8); __bss_end = .; } > RAM
	__stack_top = ORIGIN(RAM) + LENGTH(RAM);
	ASSERT(__bss_end + 0x2000 <= __stack_top, "Wisp Boot: less than 8 KiB of stack")
	/DISCARD/ : { *(.ARM.attributes) *(.comment) }
}
