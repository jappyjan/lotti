// Human-readable output for `inspect`, `verify` and `repack-main`.

import { hex, hex32 } from './bytes.ts';
import {
  APP_END_CEILING,
  COMPONENT_TYPE_NAMES,
  STORAGE_TYPE_NAMES,
} from './constants.ts';
import { crc32cMsb } from './crc.ts';
import type { RepackDiff } from './diff.ts';
import { GUARDS, verifyBundle, type VerifyReport } from './guards.ts';
import { parseBundle } from './parse.ts';

function kib(n: number): string {
  return `${n} B (${(n / 1024).toFixed(1)} KiB)`;
}

/** Full listing of a bundle: header, TOC, components, main preamble and vectors. */
export function formatInspect(bytes: Uint8Array): string {
  const lines: string[] = [];
  const bundle = parseBundle(bytes);
  const report = verifyBundle(bytes);
  lines.push('EVENOTA bundle');
  lines.push(`  size        ${kib(bytes.length)}`);
  lines.push(`  version     ${bundle.version.text}`);
  lines.push(`  built       ${bundle.buildDate.text} ${bundle.buildTime.text}`);
  lines.push(`  components  ${bundle.componentCount}`);
  lines.push('');
  lines.push(
    '  #  id  type                           storage            path                        offset     payload     CRC-32C',
  );
  for (const c of bundle.components) {
    const computed = crc32cMsb(c.payload);
    const ok = computed === c.toc.crc32c && computed === c.header.crc32c;
    const type = `${c.header.type} ${COMPONENT_TYPE_NAMES[c.header.type] ?? 'unknown'}`;
    const storage = `${c.header.storageType} ${STORAGE_TYPE_NAMES[c.header.storageType] ?? 'unknown'}`;
    lines.push(
      `  ${String(c.index + 1).padEnd(2)} ${String(c.toc.entryId).padEnd(3)} ${type.padEnd(30)} ${storage.slice(0, 18).padEnd(18)} ${c.header.path.text.padEnd(27)} ${hex32(c.toc.offset)} ${String(c.payload.length).padStart(9)}   ${hex32(c.toc.crc32c)} ${ok ? 'ok' : `BAD (header ${hex32(c.header.crc32c)}, computed ${hex32(computed)})`}`,
    );
  }
  if (bundle.issues.length > 0) {
    lines.push('');
    lines.push('  layout issues:');
    for (const issue of bundle.issues) lines.push(`    - ${issue}`);
  }
  const m = report.main;
  if (m) {
    lines.push('');
    lines.push('Main app (type 0)');
    lines.push(
      `  preamble    flags ${hex(m.flags)}, size ${m.declaredSize} (payload ${m.payloadSize}), type ${m.dataType}, load ${m.loadAddress}`,
    );
    lines.push(
      `  CRC-32      ${m.crc32} over payload[8:] ${m.crc32 === m.computedCrc32 ? 'ok' : `BAD (computed ${m.computedCrc32})`}`,
    );
    lines.push(`  vectors     SP ${m.initialSp}, reset ${m.resetVector}`);
    lines.push(
      `  installs    [${m.loadAddress}, ${m.appEnd}) = ${kib(m.installedSize)}`,
    );
    lines.push(
      `  headroom    ${kib(Math.max(0, m.headroomBelowCeiling))} below the ${hex32(APP_END_CEILING)} ceiling`,
    );
  }
  lines.push('');
  lines.push(formatVerdict(report));
  return lines.join('\n');
}

export function formatVerdict(report: VerifyReport): string {
  if (report.sendable) return 'verdict: SENDABLE (every guard passes)';
  if (report.ok) {
    const why = report.guards
      .filter((g) => !g.ok)
      .map((g) => `${g.id}: ${g.detail}`);
    return `verdict: VALID, NOT SENDABLE (${why.join('; ')})`;
  }
  return `verdict: INVALID (${report.failed.join(', ')})`;
}

export function formatVerify(report: VerifyReport): string {
  const lines: string[] = [];
  if (report.bundle) {
    lines.push(
      `${report.bundle.version} (${report.bundle.buildDate} ${report.bundle.buildTime}), ${report.bundle.size} bytes, ${report.bundle.componentCount} component(s)`,
    );
  }
  for (const spec of GUARDS) {
    const g = report.guards.find((r) => r.id === spec.id);
    const mark = !g ? 'MISSING' : g.ok ? 'pass' : 'FAIL';
    lines.push(
      `  ${mark.padEnd(7)} ${spec.id.padEnd(18)} rule ${spec.rule.padEnd(5)} ${g?.detail ?? ''}`,
    );
  }
  lines.push(formatVerdict(report));
  return lines.join('\n');
}

export function formatDiff(diff: RepackDiff): string {
  const lines: string[] = [];
  lines.push(
    `structural diff vs stock: ${diff.ok ? 'OK, only version string and CRC fields differ' : 'PROBLEMS'}`,
  );
  lines.push(
    `  header version   ${diff.headerVersion.from} -> ${diff.headerVersion.to}`,
  );
  lines.push(
    `  build date/time  ${diff.buildDateTimeKept ? 'kept' : 'CHANGED'}`,
  );
  lines.push(`  entry id         ${diff.entryIdKept ? 'kept' : 'CHANGED'}`);
  lines.push(
    `  dropped          ${diff.droppedComponents.map((c) => `${c.path} (type ${c.type})`).join(', ') || 'none'}`,
  );
  lines.push(
    `  component header ${diff.componentHeaderChanges.map((c) => `+0x${c.offset.toString(16)}..${c.length}B ${c.kind}`).join(', ') || 'identical'}`,
  );
  lines.push(
    `  CRC-32C          ${diff.crc32c.from} -> ${diff.crc32c.to} (${diff.crc32c.recomputedOk ? 'matches payload' : 'WRONG'})`,
  );
  lines.push(
    `  preamble CRC-32  ${diff.preambleCrc32.from} -> ${diff.preambleCrc32.to} (${diff.preambleCrc32.recomputedOk ? 'matches payload' : 'WRONG'})`,
  );
  const versionSites = diff.payloadChanges.filter(
    (c) => c.kind === 'version-string',
  );
  lines.push(
    `  payload          ${diff.payloadSize} bytes, ${diff.payloadBytesChanged} changed in ${diff.payloadChanges.length} range(s): ` +
      `${diff.payloadChanges.filter((c) => c.kind === 'preamble-crc').length} preamble CRC, ${versionSites.length} version string, ` +
      `${diff.payloadChanges.filter((c) => c.kind === 'unexplained').length} unexplained`,
  );
  for (const c of versionSites)
    lines.push(
      `    version bytes changed at payload 0x${c.offset.toString(16)} (run 0x${(c.offset + 0x437fe0).toString(16)})`,
    );
  for (const p of diff.problems) lines.push(`  PROBLEM: ${p}`);
  return lines.join('\n');
}
