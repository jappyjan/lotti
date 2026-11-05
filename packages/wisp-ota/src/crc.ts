// The two CRC layers of an EVENOTA main component, each in two independent
// implementations: a table-driven one used to compute, and a bit-at-a-time one
// used to re-verify (safety.md rule 3: "re-verified by an independent second
// implementation"). The bitwise forms follow openCFW `g2/tools/open_cfw.py`
// `crc32c_msb` and webflasher `firmware.js` `crc32c`/`crc32` (both MIT).
//
// Check values (input "123456789"): CRC-32C MSB-first/init 0/xorout 0 =
// 0xc052a8c8 (openCFW), zlib CRC-32 = 0xcbf43926.

/** CRC-32C (Castagnoli) polynomial, non-reflected. */
export const CRC32C_POLY = 0x1edc6f41;
/** zlib CRC-32 polynomial 0x04C11DB7, reflected. */
export const CRC32_POLY_REFLECTED = 0xedb88320;

const CRC32C_MSB_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let byte = 0; byte < 256; byte++) {
    let crc = byte << 24;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 0x80000000 ? (crc << 1) ^ CRC32C_POLY : crc << 1;
    }
    table[byte] = crc >>> 0;
  }
  return table;
})();

const CRC32_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let byte = 0; byte < 256; byte++) {
    let crc = byte;
    for (let bit = 0; bit < 8; bit++) {
      crc = crc & 1 ? (crc >>> 1) ^ CRC32_POLY_REFLECTED : crc >>> 1;
    }
    table[byte] = crc >>> 0;
  }
  return table;
})();

/** EVENOTA payload CRC (TOC and component header): CRC-32C, MSB-first, init 0, xorout 0. */
export function crc32cMsb(data: Uint8Array): number {
  let crc = 0;
  for (let i = 0; i < data.length; i++) {
    crc = (crc << 8) ^ CRC32C_MSB_TABLE[((crc >>> 24) ^ data[i]!) & 0xff]!;
  }
  return crc >>> 0;
}

/** Second implementation of {@link crc32cMsb}: shifts one bit at a time, no table. */
export function crc32cMsbBitwise(data: Uint8Array): number {
  let crc = 0;
  for (let i = 0; i < data.length; i++) {
    crc = (crc ^ (data[i]! << 24)) >>> 0;
    for (let bit = 0; bit < 8; bit++) {
      crc = ((crc << 1) ^ (crc & 0x80000000 ? CRC32C_POLY : 0)) >>> 0;
    }
  }
  return crc >>> 0;
}

/** Main-app preamble CRC: zlib CRC-32 (reflected, init and xorout 0xFFFFFFFF). */
export function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = (crc >>> 8) ^ CRC32_TABLE[(crc ^ data[i]!) & 0xff]!;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** Second implementation of {@link crc32}: shifts one bit at a time, no table. */
export function crc32Bitwise(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) {
    crc = (crc ^ data[i]!) >>> 0;
    for (let bit = 0; bit < 8; bit++) {
      crc = ((crc >>> 1) ^ (crc & 1 ? CRC32_POLY_REFLECTED : 0)) >>> 0;
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}
