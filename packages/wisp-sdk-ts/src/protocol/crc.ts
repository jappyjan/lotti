const TABLE = (() => {
  const t = new Uint16Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i << 8;
    for (let k = 0; k < 8; k++) c = c & 0x8000 ? (c << 1) ^ 0x1021 : c << 1;
    t[i] = c & 0xffff;
  }
  return t;
})();

/** CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final xor. */
export function crc16(
  data: Uint8Array,
  start = 0,
  end = data.length,
  crc = 0xffff,
): number {
  for (let i = start; i < end; i++)
    crc = ((crc << 8) ^ TABLE[((crc >> 8) ^ data[i]!) & 0xff]!) & 0xffff;
  return crc;
}
