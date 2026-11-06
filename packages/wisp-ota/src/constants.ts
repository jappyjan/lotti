// EVENOTA and Apollo510 facts. Sources are in docs/wisp/hardware.md; the
// container layout follows openCFW `g2/docs/reference/firmware-formats.md`
// (MIT, kalanihelekunihi/evenRealities-openCFW).

// --- EVENOTA container -------------------------------------------------------

/** `"EVENOTA\0"` at offset 0. */
export const EVENOTA_MAGIC = [
  0x45, 0x56, 0x45, 0x4e, 0x4f, 0x54, 0x41, 0x00,
] as const;
/** `"evenota\0"` + 8 zero bytes, right after the TOC. */
export const EVENOTA_TRAILER = [
  0x65, 0x76, 0x65, 0x6e, 0x6f, 0x74, 0x61, 0x00, 0, 0, 0, 0, 0, 0, 0, 0,
] as const;
export const HEADER_DATE_OFFSET = 0x10;
export const HEADER_TIME_OFFSET = 0x20;
export const HEADER_VERSION_OFFSET = 0x30;
/** Date, time and version are NUL-padded ASCII fields of 16 bytes. */
export const HEADER_STRING_SIZE = 16;
export const TOC_OFFSET = 0x40;
export const TOC_ENTRY_SIZE = 16;
export const TRAILER_SIZE = 16;
export const COMPONENT_HEADER_SIZE = 0x80;
/** `"EVEN"` read as a little-endian u32, at component header `+0x14`. */
export const COMPONENT_MAGIC = 0x4e455645;
export const COMPONENT_PATH_OFFSET = 0x30;
export const COMPONENT_PATH_SIZE =
  COMPONENT_HEADER_SIZE - COMPONENT_PATH_OFFSET;
/** Stock bundles carry 5 or 6 components; anything above this is not a G2 bundle. */
export const MAX_COMPONENTS = 16;
/** Stock bundles are about 4.5 MiB. Anything above this is rejected outright. */
export const MAX_BUNDLE_SIZE = 16 * 1024 * 1024;
/** Stock header version prefix (`s200_v2.2.6.10`). */
export const VERSION_PREFIX = 's200_v';

export const ComponentType = {
  main: 0,
  bootloader: 1,
  font: 2,
  touch: 3,
  codec: 4,
  em9305: 5,
  case: 6,
} as const;

export const COMPONENT_TYPE_NAMES: Readonly<Record<number, string>> = {
  0: 'main (Apollo510 app)',
  1: 'bootloader (Even, Apollo510)',
  2: 'font',
  3: 'touch (PSoC 4000T)',
  4: 'codec (GX8002)',
  5: 'BLE controller (EM9305)',
  6: 'case (STM32G0)',
};

export const STORAGE_TYPE_NAMES: Readonly<Record<number, string>> = {
  0: 'MRAM',
  1: 'XIP NOR (read-back verified)',
  3: 'littlefs file',
};

// --- Main app (component type 0) ---------------------------------------------

/** The only component Wisp ever packs. */
export const MAIN_COMPONENT_TYPE = ComponentType.main;
/** Stock storage type of the main component: a littlefs file on the NOR. */
export const MAIN_STORAGE_TYPE = 3;
/** The staging file the stock app writes and the Even bootloader installs. */
export const MAIN_PATH = 'ota/s200_firmware_ota.bin';
/** Main TOC entry id for `packMain` (6, as in six-component stock bundles). `repackMain` keeps the stock id. */
export const MAIN_ENTRY_ID = 6;
export const PREAMBLE_SIZE = 0x20;
/** Preamble word 0 high byte. */
export const PREAMBLE_FLAGS = 0x04;
/** Preamble `+0x10`. */
export const PREAMBLE_DATA_TYPE = 0xcb;
/** Preamble size field: 24 bits, includes the preamble itself. */
export const PREAMBLE_MAX_SIZE = 0x00ffffff;
/** Where the Even bootloader programs `payload[0x20:]`. */
export const MAIN_LOAD_ADDRESS = 0x00438000;
/** A Cortex-M vector table holds at least SP, reset and 14 more core vectors. */
export const MIN_VECTOR_TABLE_SIZE = 0x40;

// --- Apollo510 memory --------------------------------------------------------

/** Ambiq secure bootloader (ROM side of MRAM). Never written. */
export const SBL_START = 0x00400000;
/** Even bootloader region `0x410000–0x438000`. Never written. */
export const EVEN_BOOTLOADER_START = 0x00410000;
export const EVEN_BOOTLOADER_END = 0x00438000;
/** Hard ceiling for the app's end (g2flash `APP_MAX_END`): margin below the flag. */
export const APP_END_CEILING = 0x007f8000;
/** Bootloader-owned update-flag record. Nothing may be installed at or past it. */
export const UPDATE_FLAG_ADDRESS = 0x007fe000;
export const MRAM_END = 0x00800000;
/** DTCM `0x20000000–0x20080000` followed by 3 MiB SSRAM up to `0x20380000`. */
export const SRAM_START = 0x20000000;
export const SRAM_END = 0x20380000;
