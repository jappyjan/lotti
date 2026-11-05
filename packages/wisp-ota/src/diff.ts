// Structural diff between a stock bundle and its rung-1 repack. Proves the
// repack changed nothing but the version string and the CRC fields: every
// other byte of the main component (header and payload) must be identical.

import { asciiBytes, equalBytes, hex32, readU32 } from './bytes.ts';
import {
  COMPONENT_HEADER_SIZE,
  COMPONENT_TYPE_NAMES,
  VERSION_PREFIX,
} from './constants.ts';
import { crc32, crc32cMsb } from './crc.ts';
import { mainComponents, parseBundle } from './parse.ts';

export type ChangeKind =
  'preamble-crc' | 'version-string' | 'component-crc' | 'unexplained';

export interface ByteRange {
  /** Offset inside the payload or component header. */
  offset: number;
  length: number;
  kind: ChangeKind;
}

export interface RepackDiff {
  /** True when every difference is an allowed one. */
  ok: boolean;
  problems: string[];
  headerVersion: { from: string; to: string };
  buildDateTimeKept: boolean;
  /** Stock components not carried over (everything but main: rule 2). */
  droppedComponents: { path: string; type: number; typeName: string }[];
  entryIdKept: boolean;
  componentHeaderChanges: ByteRange[];
  payloadSize: number;
  payloadChanges: ByteRange[];
  payloadBytesChanged: number;
  crc32c: { from: string; to: string; recomputedOk: boolean };
  preambleCrc32: { from: string; to: string; recomputedOk: boolean };
}

function changedRanges(
  a: Uint8Array,
  b: Uint8Array,
): { offset: number; length: number }[] {
  const ranges: { offset: number; length: number }[] = [];
  let start = -1;
  for (let i = 0; i <= a.length; i++) {
    const differs = i < a.length && a[i] !== b[i];
    if (differs && start < 0) start = i;
    if (!differs && start >= 0) {
      ranges.push({ offset: start, length: i - start });
      start = -1;
    }
  }
  return ranges;
}

function stripPrefix(version: string): string {
  return version.startsWith(VERSION_PREFIX)
    ? version.slice(VERSION_PREFIX.length)
    : version;
}

export function diffRepack(
  stockBytes: Uint8Array,
  repackedBytes: Uint8Array,
): RepackDiff {
  const stock = parseBundle(stockBytes);
  const repacked = parseBundle(repackedBytes);
  const problems: string[] = [];

  const stockMains = mainComponents(stock);
  const repackedMains = mainComponents(repacked);
  if (stockMains.length !== 1)
    problems.push(`stock has ${stockMains.length} main components`);
  if (repacked.componentCount !== 1 || repackedMains.length !== 1) {
    problems.push(
      `repacked bundle has ${repacked.componentCount} components, expected main only`,
    );
  }
  const from = stock.version.text;
  const to = repacked.version.text;
  const buildDateTimeKept =
    stock.buildDate.text === repacked.buildDate.text &&
    stock.buildTime.text === repacked.buildTime.text;
  if (!buildDateTimeKept) problems.push('build date/time changed');
  if (stock.reserved !== repacked.reserved)
    problems.push('header +0x0C changed');

  const droppedComponents = stock.components
    .filter((c) => c.header.type !== 0)
    .map((c) => ({
      path: c.header.path.text,
      type: c.header.type,
      typeName: COMPONENT_TYPE_NAMES[c.header.type] ?? 'unknown',
    }));

  const empty: RepackDiff = {
    ok: false,
    problems,
    headerVersion: { from, to },
    buildDateTimeKept,
    droppedComponents,
    entryIdKept: false,
    componentHeaderChanges: [],
    payloadSize: 0,
    payloadChanges: [],
    payloadBytesChanged: 0,
    crc32c: { from: '', to: '', recomputedOk: false },
    preambleCrc32: { from: '', to: '', recomputedOk: false },
  };
  if (stockMains.length !== 1 || repackedMains.length !== 1) return empty;
  const s = stockMains[0]!;
  const r = repackedMains[0]!;

  const entryIdKept = s.toc.entryId === r.toc.entryId;
  if (!entryIdKept)
    problems.push(`TOC entry id changed ${s.toc.entryId} → ${r.toc.entryId}`);
  if (s.toc.entrySize !== r.toc.entrySize)
    problems.push('TOC entry size changed');

  const sHeader = stockBytes.subarray(
    s.toc.offset,
    s.toc.offset + COMPONENT_HEADER_SIZE,
  );
  const rHeader = repackedBytes.subarray(
    r.toc.offset,
    r.toc.offset + COMPONENT_HEADER_SIZE,
  );
  const componentHeaderChanges: ByteRange[] = changedRanges(
    sHeader,
    rHeader,
  ).map((range) => ({
    ...range,
    kind:
      range.offset >= 0x0c && range.offset + range.length <= 0x10
        ? 'component-crc'
        : 'unexplained',
  }));

  const oldVersion = stripPrefix(from);
  const newVersion = stripPrefix(to);
  const oldBytes = asciiBytes(oldVersion);
  const newBytes = asciiBytes(newVersion);
  const payloadChanges: ByteRange[] = [];
  let payloadBytesChanged = 0;
  if (s.payload.length !== r.payload.length) {
    problems.push(
      `payload size changed ${s.payload.length} → ${r.payload.length}`,
    );
  } else {
    for (const range of changedRanges(s.payload, r.payload)) {
      payloadBytesChanged += range.length;
      let kind: ChangeKind = 'unexplained';
      if (range.offset >= 4 && range.offset + range.length <= 8) {
        kind = 'preamble-crc';
      } else if (oldBytes.length === newBytes.length && oldBytes.length > 0) {
        // A version site: aligned, NUL-bracketed, old text in stock, new text in the repack.
        const end = range.offset + range.length;
        const first = Math.max(4, Math.ceil((end - oldBytes.length) / 4) * 4);
        for (let site = first; site <= range.offset; site += 4) {
          if (
            s.payload[site - 1] === 0 &&
            s.payload[site + oldBytes.length] === 0 &&
            r.payload[site + oldBytes.length] === 0 &&
            equalBytes(
              s.payload.subarray(site, site + oldBytes.length),
              oldBytes,
            ) &&
            equalBytes(
              r.payload.subarray(site, site + newBytes.length),
              newBytes,
            )
          ) {
            kind = 'version-string';
            break;
          }
        }
      }
      payloadChanges.push({ ...range, kind });
    }
  }

  for (const c of componentHeaderChanges) {
    if (c.kind === 'unexplained')
      problems.push(
        `component header bytes +0x${c.offset.toString(16)}..+${c.length} changed`,
      );
  }
  for (const c of payloadChanges) {
    if (c.kind === 'unexplained')
      problems.push(
        `payload bytes 0x${c.offset.toString(16)} (+${c.length}) changed`,
      );
  }

  const crcFrom = s.header.crc32c;
  const crcTo = r.header.crc32c;
  const crcRecomputed =
    crc32cMsb(r.payload) === crcTo && r.toc.crc32c === crcTo;
  if (!crcRecomputed)
    problems.push('repacked CRC-32C does not match its payload');
  const preFrom = readU32(s.payload, 4);
  const preTo = readU32(r.payload, 4);
  const preRecomputed = crc32(r.payload.subarray(8)) === preTo;
  if (!preRecomputed)
    problems.push('repacked preamble CRC-32 does not match its payload');

  return {
    ok: problems.length === 0,
    problems,
    headerVersion: { from, to },
    buildDateTimeKept,
    droppedComponents,
    entryIdKept,
    componentHeaderChanges,
    payloadSize: r.payload.length,
    payloadChanges,
    payloadBytesChanged,
    crc32c: {
      from: hex32(crcFrom),
      to: hex32(crcTo),
      recomputedOk: crcRecomputed,
    },
    preambleCrc32: {
      from: hex32(preFrom),
      to: hex32(preTo),
      recomputedOk: preRecomputed,
    },
  };
}
