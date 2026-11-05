// EVENOTA parser. Reads every field and records every deviation from the
// stock layout as an issue; throws only when the bytes cannot be walked at all
// (bad magic, a table or component outside the file). Judging the result is
// the guards' job (guards.ts).

import {
  equalBytes,
  readFixedString,
  readU32,
  type FixedString,
} from './bytes.ts';
import {
  COMPONENT_HEADER_SIZE,
  COMPONENT_MAGIC,
  COMPONENT_PATH_OFFSET,
  COMPONENT_PATH_SIZE,
  EVENOTA_MAGIC,
  EVENOTA_TRAILER,
  HEADER_DATE_OFFSET,
  HEADER_STRING_SIZE,
  HEADER_TIME_OFFSET,
  HEADER_VERSION_OFFSET,
  MAIN_COMPONENT_TYPE,
  MAX_COMPONENTS,
  PREAMBLE_SIZE,
  TOC_ENTRY_SIZE,
  TOC_OFFSET,
  TRAILER_SIZE,
} from './constants.ts';

export class EvenotaFormatError extends Error {
  override name = 'EvenotaFormatError';
}

export interface TocEntry {
  index: number;
  entryId: number;
  /** File offset of the component header. */
  offset: number;
  /** Component header + payload. */
  entrySize: number;
  crc32c: number;
}

export interface ComponentHeader {
  /** `+0x00`, `+0x04`, `+0x10`, `+0x20`: zero in stock. */
  zeroWords: [number, number, number, number];
  /** `+0x18`, `+0x1C`, `+0x2C`: 0xFFFFFFFF in stock. */
  onesWords: [number, number, number];
  payloadSize: number;
  crc32c: number;
  magic: number;
  type: number;
  storageType: number;
  path: FixedString;
}

export interface Component {
  index: number;
  toc: TocEntry;
  header: ComponentHeader;
  /** File offset of the payload. */
  payloadOffset: number;
  payload: Uint8Array;
}

export interface Bundle {
  bytes: Uint8Array;
  componentCount: number;
  /** `+0x0C`, zero in stock. */
  reserved: number;
  buildDate: FixedString;
  buildTime: FixedString;
  version: FixedString;
  components: Component[];
  /** Structural deviations from the stock layout; empty for a well-formed bundle. */
  issues: string[];
}

export interface MainPreamble {
  word0: number;
  flags: number;
  /** 24-bit size, including the 32-byte preamble. */
  declaredSize: number;
  crc32: number;
  /** `+0x08`, `+0x0C`, `+0x18`, `+0x1C`. */
  reserved: [number, number, number, number];
  dataType: number;
  loadAddress: number;
}

export interface MainImage {
  preamble: MainPreamble;
  /** Vector table word 0: initial SP. */
  initialSp: number;
  /** Vector table word 1: reset handler (Thumb bit included). */
  resetVector: number;
  /** Bytes the bootloader programs, i.e. `payload.length - 0x20`. */
  installedSize: number;
  /** `loadAddress + installedSize`, exclusive. */
  appEnd: number;
  /** `loadAddress + declaredSize - 0x20`: what the bootloader trusts. */
  declaredEnd: number;
}

export function parseBundle(bytes: Uint8Array): Bundle {
  if (
    bytes.length < TOC_OFFSET ||
    !equalBytes(bytes.subarray(0, 8), EVENOTA_MAGIC)
  ) {
    throw new EvenotaFormatError(
      'not an EVENOTA bundle (missing EVENOTA magic)',
    );
  }
  const issues: string[] = [];
  const componentCount = readU32(bytes, 0x08);
  if (componentCount < 1 || componentCount > MAX_COMPONENTS) {
    throw new EvenotaFormatError(
      `implausible component count ${componentCount}`,
    );
  }
  const reserved = readU32(bytes, 0x0c);
  if (reserved !== 0)
    issues.push(`header +0x0C is 0x${reserved.toString(16)}, expected 0`);

  const buildDate = readFixedString(
    bytes,
    HEADER_DATE_OFFSET,
    HEADER_STRING_SIZE,
  );
  const buildTime = readFixedString(
    bytes,
    HEADER_TIME_OFFSET,
    HEADER_STRING_SIZE,
  );
  const version = readFixedString(
    bytes,
    HEADER_VERSION_OFFSET,
    HEADER_STRING_SIZE,
  );
  for (const [name, field] of [
    ['build date', buildDate],
    ['build time', buildTime],
    ['version', version],
  ] as const) {
    if (!field.terminated || !field.printable || !field.cleanPadding) {
      issues.push(`header ${name} is not a clean NUL-padded ASCII string`);
    }
  }

  const tocEnd = TOC_OFFSET + componentCount * TOC_ENTRY_SIZE;
  if (tocEnd + TRAILER_SIZE > bytes.length) {
    throw new EvenotaFormatError(
      'table of contents runs past the end of the file',
    );
  }
  if (
    !equalBytes(bytes.subarray(tocEnd, tocEnd + TRAILER_SIZE), EVENOTA_TRAILER)
  ) {
    issues.push('TOC trailer is not "evenota\\0" + 8 zero bytes');
  }

  const components: Component[] = [];
  const seenIds = new Set<number>();
  let expectedOffset = tocEnd + TRAILER_SIZE;
  for (let index = 0; index < componentCount; index++) {
    const at = TOC_OFFSET + index * TOC_ENTRY_SIZE;
    const toc: TocEntry = {
      index,
      entryId: readU32(bytes, at),
      offset: readU32(bytes, at + 4),
      entrySize: readU32(bytes, at + 8),
      crc32c: readU32(bytes, at + 12),
    };
    const label = `component ${index + 1}`;
    if (seenIds.has(toc.entryId))
      issues.push(`${label}: duplicate entry id ${toc.entryId}`);
    seenIds.add(toc.entryId);
    if (
      toc.entrySize < COMPONENT_HEADER_SIZE ||
      toc.offset + toc.entrySize > bytes.length
    ) {
      throw new EvenotaFormatError(`${label} lies outside the file`);
    }
    if (toc.offset !== expectedOffset) {
      issues.push(
        `${label} starts at 0x${toc.offset.toString(16)}, expected 0x${expectedOffset.toString(16)} (contiguous)`,
      );
    }
    const h = toc.offset;
    const header: ComponentHeader = {
      zeroWords: [
        readU32(bytes, h),
        readU32(bytes, h + 0x04),
        readU32(bytes, h + 0x10),
        readU32(bytes, h + 0x20),
      ],
      onesWords: [
        readU32(bytes, h + 0x18),
        readU32(bytes, h + 0x1c),
        readU32(bytes, h + 0x2c),
      ],
      payloadSize: readU32(bytes, h + 0x08),
      crc32c: readU32(bytes, h + 0x0c),
      magic: readU32(bytes, h + 0x14),
      type: readU32(bytes, h + 0x24),
      storageType: readU32(bytes, h + 0x28),
      path: readFixedString(
        bytes,
        h + COMPONENT_PATH_OFFSET,
        COMPONENT_PATH_SIZE,
      ),
    };
    if (header.magic !== COMPONENT_MAGIC)
      issues.push(`${label}: component magic is not "EVEN"`);
    if (header.payloadSize !== toc.entrySize - COMPONENT_HEADER_SIZE) {
      issues.push(
        `${label}: header payload size ${header.payloadSize} != TOC entry size ${toc.entrySize} - 128`,
      );
    }
    if (
      header.zeroWords.some((w) => w !== 0) ||
      header.onesWords.some((w) => w !== 0xffffffff)
    ) {
      issues.push(
        `${label}: reserved header words differ from stock (0 / 0xFFFFFFFF)`,
      );
    }
    if (
      !header.path.terminated ||
      !header.path.printable ||
      !header.path.cleanPadding
    ) {
      issues.push(`${label}: path is not a clean NUL-padded ASCII string`);
    }
    const payloadOffset = h + COMPONENT_HEADER_SIZE;
    components.push({
      index,
      toc,
      header,
      payloadOffset,
      payload: bytes.subarray(payloadOffset, toc.offset + toc.entrySize),
    });
    expectedOffset = toc.offset + toc.entrySize;
  }
  if (expectedOffset !== bytes.length) {
    issues.push(
      `components end at 0x${expectedOffset.toString(16)} but the file is 0x${bytes.length.toString(16)} bytes`,
    );
  }

  return {
    bytes,
    componentCount,
    reserved,
    buildDate,
    buildTime,
    version,
    components,
    issues,
  };
}

/** Components of type 0 (main app). A sendable bundle has exactly one. */
export function mainComponents(bundle: Bundle): Component[] {
  return bundle.components.filter((c) => c.header.type === MAIN_COMPONENT_TYPE);
}

/** Reads the 32-byte preamble and the first two vector table words. */
export function parseMainImage(payload: Uint8Array): MainImage {
  if (payload.length < PREAMBLE_SIZE + 8) {
    throw new EvenotaFormatError(
      `main payload is ${payload.length} bytes; too short for preamble + vectors`,
    );
  }
  const word0 = readU32(payload, 0x00);
  const preamble: MainPreamble = {
    word0,
    flags: word0 >>> 24,
    declaredSize: word0 & 0x00ffffff,
    crc32: readU32(payload, 0x04),
    reserved: [
      readU32(payload, 0x08),
      readU32(payload, 0x0c),
      readU32(payload, 0x18),
      readU32(payload, 0x1c),
    ],
    dataType: readU32(payload, 0x10),
    loadAddress: readU32(payload, 0x14),
  };
  const installedSize = payload.length - PREAMBLE_SIZE;
  return {
    preamble,
    initialSp: readU32(payload, PREAMBLE_SIZE),
    resetVector: readU32(payload, PREAMBLE_SIZE + 4),
    installedSize,
    appEnd: preamble.loadAddress + installedSize,
    declaredEnd: preamble.loadAddress + preamble.declaredSize - PREAMBLE_SIZE,
  };
}
