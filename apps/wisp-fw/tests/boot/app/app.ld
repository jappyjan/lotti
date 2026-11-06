/* SPDX-License-Identifier: MIT
 * Rung-3 fault app: the Wisp app slot at 0x448000; RAM in DTCM, clear of Wisp Boot's RAM. */
MEMORY
{
	MRAM (rx) : ORIGIN = 0x00448000, LENGTH = 0x10000
	RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 0x10000
}
ENTRY(app_reset)
SECTIONS
{
	.text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) . = ALIGN(8); } > MRAM
	.bss (NOLOAD) : { *(.bss*) *(COMMON) } > RAM
	__app_stack = ORIGIN(RAM) + LENGTH(RAM);
	/DISCARD/ : { *(.ARM.attributes) *(.comment) *(.ARM.exidx*) }
}
