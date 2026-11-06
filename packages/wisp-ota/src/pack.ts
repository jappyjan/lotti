// Producing main-only bundles. Both entry points end the same way: assemble,
// then re-parse the output from scratch and run every guard on it (with the
// second CRC implementations). Nothing leaves this module unverified, and
// nothing here takes an option that relaxes a guard.

import { asciiBytes, equalBytes, writeFixedString, writeU32 } from './bytes.ts';
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
  MAIN_ENTRY_ID,
  MAIN_LOAD_ADDRESS,
  MAIN_PATH,
  MAIN_STORAGE_TYPE,
  PREAMBLE_DATA_TYPE,
  PREAMBLE_FLAGS,
  PREAMBLE_MAX_SIZE,
  PREAMBLE_SIZE,
  TOC_ENTRY_SIZE,
  TOC_OFFSET,
  TRAILER_SIZE,
  VERSION_PREFIX,
} from './constants.ts';
import { crc32, crc32cMsb } from './crc.ts';
import { diffRepack, type RepackDiff } from './diff.ts';
import {
  assertSendable,
  checkMainPayload,
  GuardError,
  verifyBundle,
  type VerifyReport,
} from './guards.ts';
import { mainComponents, parseBundle } from './parse.ts';

/** Stock firmware versions look like `2.2.6.10`. */
export const FIRMWARE_VERSION_PATTERN = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,4}$/;

export class PackError extends Error {
  override name = 'PackError';
}

/** Size of a main-only bundle carrying a `payloadSize`-byte main payload. */
export function mainOnlyBundleSize(payloadSize: number): number {
  return (
    TOC_OFFSET +
    TOC_ENTRY_SIZE +
    TRAILER_SIZE +
    COMPONENT_HEADER_SIZE +
    payloadSize
  );
}

/** Prepends the 32-byte main-app preamble to a raw image linked at 0x438000. */
export function wrapMainImage(app: Uint8Array): Uint8Array {
  const total = PREAMBLE_SIZE + app.length;
  if (total > PREAMBLE_MAX_SIZE) {
    throw new PackError(
      `image of ${app.length} bytes overflows the 24-bit preamble size field`,
    );
  }
  const payload = new Uint8Array(total);
  writeU32(payload, 0x00, ((PREAMBLE_FLAGS << 24) | total) >>> 0);
  writeU32(payload, 0x10, PREAMBLE_DATA_TYPE);
  writeU32(payload, 0x14, MAIN_LOAD_ADDRESS);
  payload.set(app, PREAMBLE_SIZE);
  writeU32(payload, 0x04, crc32(payload.subarray(8)));
  return payload;
}

interface HeaderFields {
  version: string;
  buildDate: string;
  buildTime: string;
  /** TOC entry id: 6 in six-component stock bundles, 5 in five-component ones. */
  entryId: number;
}

function assembleMainOnly(
  payload: Uint8Array,
  strings: HeaderFields,
): Uint8Array {
  const out = new Uint8Array(mainOnlyBundleSize(payload.length));
  out.set(EVENOTA_MAGIC, 0);
  writeU32(out, 0x08, 1);
  writeFixedString(
    out,
    HEADER_DATE_OFFSET,
    HEADER_STRING_SIZE,
    strings.buildDate,
  );
  writeFixedString(
    out,
    HEADER_TIME_OFFSET,
    HEADER_STRING_SIZE,
    strings.buildTime,
  );
  writeFixedString(
    out,
    HEADER_VERSION_OFFSET,
    HEADER_STRING_SIZE,
    strings.version,
  );

  const componentOffset = TOC_OFFSET + TOC_ENTRY_SIZE + TRAILER_SIZE;
  const checksum = crc32cMsb(payload);
  writeU32(out, TOC_OFFSET, strings.entryId);
  writeU32(out, TOC_OFFSET + 4, componentOffset);
  writeU32(out, TOC_OFFSET + 8, COMPONENT_HEADER_SIZE + payload.length);
  writeU32(out, TOC_OFFSET + 12, checksum);
  out.set(EVENOTA_TRAILER, TOC_OFFSET + TOC_ENTRY_SIZE);

  const h = componentOffset;
  writeU32(out, h + 0x08, payload.length);
  writeU32(out, h + 0x0c, checksum);
  writeU32(out, h + 0x14, COMPONENT_MAGIC);
  writeU32(out, h + 0x18, 0xffffffff);
  writeU32(out, h + 0x1c, 0xffffffff);
  writeU32(out, h + 0x24, MAIN_COMPONENT_TYPE);
  writeU32(out, h + 0x28, MAIN_STORAGE_TYPE);
  writeU32(out, h + 0x2c, 0xffffffff);
  writeFixedString(
    out,
    h + COMPONENT_PATH_OFFSET,
    COMPONENT_PATH_SIZE,
    MAIN_PATH,
  );
  out.set(payload, h + COMPONENT_HEADER_SIZE);
  return out;
}

/** Re-parses `bundle` from scratch and runs every guard; throws on any failure. */
function finalCheck(bundle: Uint8Array, payloadSize: number): VerifyReport {
  const report = assertSendable(bundle);
  if (bundle.length !== mainOnlyBundleSize(payloadSize)) {
    throw new PackError(
      `output is ${bundle.length} bytes, expected exactly ${mainOnlyBundleSize(payloadSize)}`,
    );
  }
  return report;
}

function checkPayloadOrThrow(payload: Uint8Array, what: string): void {
  const failed = checkMainPayload(payload).filter((g) => !g.ok);
  if (failed.length > 0)
    throw new GuardError(`${what} fails the main-image guards`, failed);
}

function headerVersion(version: string): string {
  const text = `${VERSION_PREFIX}${version}`;
  if (
    !FIRMWARE_VERSION_PATTERN.test(version) ||
    text.length >= HEADER_STRING_SIZE
  ) {
    throw new PackError(
      `version "${version}" must look like 1.2.3.4 and fit the 16-byte header field`,
    );
  }
  return text;
}

function two(n: number): string {
  return String(n).padStart(2, '0');
}

export interface PackMainOptions {
  /** Firmware version, e.g. `0.1.0.1`; written as `s200_v<version>`. */
  version: string;
  /** Build timestamp for the header; defaults to now. Written in UTC. */
  buildTime?: Date;
}

export interface PackResult {
  bytes: Uint8Array;
  report: VerifyReport;
}

/** Packs a raw Wisp app image (linked at 0x438000, vector table first) into a main-only bundle. */
export function packMain(
  app: Uint8Array,
  options: PackMainOptions,
): PackResult {
  const payload = wrapMainImage(app);
  checkPayloadOrThrow(payload, 'app image');
  const at = options.buildTime ?? new Date();
  const bytes = assembleMainOnly(payload, {
    version: headerVersion(options.version),
    buildDate: `${at.getUTCFullYear()}-${two(at.getUTCMonth() + 1)}-${two(at.getUTCDate())}`,
    buildTime: `${two(at.getUTCHours())}:${two(at.getUTCMinutes())}:${two(at.getUTCSeconds())}`,
    entryId: MAIN_ENTRY_ID,
  });
  return { bytes, report: finalCheck(bytes, payload.length) };
}

/** Offsets in a main payload where `version` sits as its own NUL-terminated string. */
export function findVersionStrings(
  payload: Uint8Array,
  version: string,
): number[] {
  const needle = asciiBytes(version);
  const sites: number[] = [];
  if (needle.length === 0) return sites;
  // Word-aligned, NUL before and after: a standalone C string constant. This
  // skips git-describe strings ("master:v2.2.6.10-0-g…"), "Launch:2.2.6.10"
  // and accidental matches inside compressed data.
  for (let at = PREAMBLE_SIZE; at + needle.length < payload.length; at += 4) {
    if (payload[at - 1] !== 0 || payload[at + needle.length] !== 0) continue;
    if (equalBytes(payload.subarray(at, at + needle.length), needle))
      sites.push(at);
  }
  return sites;
}

/** `s200_v2.2.6.10` → `2.2.6.10`; throws for anything that is not a stock-style version. */
export function stockVersionFromHeader(header: string): string {
  if (
    !header.startsWith(VERSION_PREFIX) ||
    !FIRMWARE_VERSION_PATTERN.test(header.slice(VERSION_PREFIX.length))
  ) {
    throw new PackError(
      `bundle version "${header}" is not of the stock form ${VERSION_PREFIX}1.2.3.4`,
    );
  }
  return header.slice(VERSION_PREFIX.length);
}

export interface RepackResult extends PackResult {
  fromVersion: string;
  toVersion: string;
  /** Payload offsets of the rewritten version strings. */
  versionSites: number[];
  diff: RepackDiff;
}

/**
 * Rung 1 of the safety ladder: the stock main payload with only its version
 * string changed (same length, so no byte moves), both CRC layers recomputed,
 * as a main-only bundle. The other stock components are dropped (rule 2).
 */
export function repackMain(
  stock: Uint8Array,
  newVersion: string,
): RepackResult {
  const stockReport = verifyBundle(stock);
  if (!stockReport.ok) {
    throw new GuardError(
      'stock bundle fails verification',
      stockReport.guards.filter((g) => !g.ok && g.scope === 'integrity'),
    );
  }
  const parsed = parseBundle(stock);
  const fromVersion = stockVersionFromHeader(parsed.version.text);
  if (!FIRMWARE_VERSION_PATTERN.test(newVersion)) {
    throw new PackError(
      `new version "${newVersion}" must look like ${fromVersion}`,
    );
  }
  if (newVersion.length !== fromVersion.length) {
    throw new PackError(
      `new version "${newVersion}" must have the same length as "${fromVersion}" (${fromVersion.length} characters), so no byte moves`,
    );
  }
  if (newVersion === fromVersion) {
    throw new PackError(
      `new version equals the stock version "${fromVersion}"; nothing would show the repack was installed`,
    );
  }

  const main = mainComponents(parsed)[0]!;
  const payload = main.payload.slice();
  const versionSites = findVersionStrings(payload, fromVersion);
  if (versionSites.length === 0) {
    throw new PackError(
      `no standalone "${fromVersion}" string found in the main image`,
    );
  }
  const replacement = asciiBytes(newVersion);
  for (const at of versionSites) payload.set(replacement, at);
  writeU32(payload, 0x04, crc32(payload.subarray(8)));
  checkPayloadOrThrow(payload, 'repacked main image');

  const bytes = assembleMainOnly(payload, {
    version: headerVersion(newVersion),
    buildDate: parsed.buildDate.text,
    buildTime: parsed.buildTime.text,
    entryId: main.toc.entryId,
  });
  const report = finalCheck(bytes, payload.length);
  const diff = diffRepack(stock, bytes);
  if (!diff.ok) {
    throw new PackError(
      `repacked bundle differs from stock beyond version string and CRCs: ${diff.problems.join('; ')}`,
    );
  }
  return {
    bytes,
    report,
    fromVersion,
    toVersion: newVersion,
    versionSites,
    diff,
  };
}

export interface StockMainResult extends PackResult {
  version: string;
  /** Structural diff against the stock bundle: proves nothing in the main component changed. */
  diff: RepackDiff;
}

/**
 * The round trip back from rung 1: the stock main component **unchanged**
 * (component header and payload byte-identical, same version, same CRCs), as
 * a main-only bundle, so the stock OTA sender (which only sends main-only
 * bundles) can put pure stock back. The other stock components are dropped
 * (rule 2). Refuses unless the structural diff shows zero changed bytes.
 */
export function stockMainOnly(stock: Uint8Array): StockMainResult {
  const stockReport = verifyBundle(stock);
  if (!stockReport.ok) {
    throw new GuardError(
      'stock bundle fails verification',
      stockReport.guards.filter((g) => !g.ok && g.scope === 'integrity'),
    );
  }
  const parsed = parseBundle(stock);
  const version = stockVersionFromHeader(parsed.version.text);
  const main = mainComponents(parsed)[0]!;
  const payload = main.payload.slice();
  checkPayloadOrThrow(payload, 'stock main image');
  const bytes = assembleMainOnly(payload, {
    version: headerVersion(version),
    buildDate: parsed.buildDate.text,
    buildTime: parsed.buildTime.text,
    entryId: main.toc.entryId,
  });
  const report = finalCheck(bytes, payload.length);
  const diff = diffRepack(stock, bytes);
  if (
    !diff.ok ||
    diff.payloadBytesChanged !== 0 ||
    diff.componentHeaderChanges.length !== 0
  ) {
    throw new PackError(
      `stock main-only bundle differs from stock: ${diff.problems.join('; ') || 'changed bytes'}`,
    );
  }
  const out = parseBundle(bytes);
  if (
    !equalBytes(
      bytes.subarray(
        out.components[0]!.toc.offset,
        out.components[0]!.toc.offset + COMPONENT_HEADER_SIZE,
      ),
      stock.subarray(main.toc.offset, main.toc.offset + COMPONENT_HEADER_SIZE),
    )
  ) {
    throw new PackError('component header differs from stock');
  }
  return { bytes, report, version, diff };
}
