#!/usr/bin/env node
// wisp-ota CLI: a thin Node wrapper around the library. It never talks to
// glasses; there is no BLE or transfer code in this package.

import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { STOCK_RELEASES, stockReleaseUrl } from './catalog.ts';
import { diffRepack } from './diff.ts';
import { formatDiff, formatInspect, formatVerify } from './format.ts';
import { verifyBundle } from './guards.ts';
import {
  defaultCacheDir,
  fetchStock,
  importStock,
  sha256,
  writeAtomic,
} from './node/stock-cache.ts';
import { packMain, repackMain } from './pack.ts';

const USAGE = `wisp-ota: EVENOTA inspector, packer and verifier (no flashing, no BLE)

  wisp-ota inspect <bundle> [--json]
  wisp-ota verify <bundle> [--json]
  wisp-ota repack-main <stock-bundle> --version <x.y.z.w> -o <out>
  wisp-ota pack-main <app.bin> --version <x.y.z.w> -o <out>
  wisp-ota diff <stock-bundle> <repacked-bundle> [--json]
  wisp-ota fetch <version> [--cache-dir <dir>]
  wisp-ota import <bundle> [--cache-dir <dir>]
  wisp-ota catalog

verify exit codes: 0 sendable, 2 valid but not sendable (e.g. a stock bundle
with non-main components), 1 invalid. No option disables a guard.`;

type Flags = {
  json?: boolean;
  version?: string;
  out?: string;
  cacheDir?: string;
};

/** Strict parser: unknown flags are errors, so no "--force"-style escape hatch can sneak in. */
function parseArgs(argv: string[]): { positional: string[]; flags: Flags } {
  const positional: string[] = [];
  const flags: Flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    const value = (): string => {
      const v = argv[++i];
      if (v === undefined || v.startsWith('-'))
        throw new UsageError(`${arg} needs a value`);
      return v;
    };
    if (arg === '--json') flags.json = true;
    else if (arg === '--version') flags.version = value();
    else if (arg === '-o' || arg === '--out') flags.out = value();
    else if (arg === '--cache-dir') flags.cacheDir = value();
    else if (arg.startsWith('-')) throw new UsageError(`unknown option ${arg}`);
    else positional.push(arg);
  }
  return { positional, flags };
}

class UsageError extends Error {}

async function readBytes(path: string): Promise<Uint8Array> {
  return new Uint8Array(await readFile(path));
}

function need(positional: string[], count: number, what: string): void {
  if (positional.length !== count) throw new UsageError(`expected ${what}`);
}

async function writeOutput(
  out: string | undefined,
  inputs: string[],
  bytes: Uint8Array,
): Promise<string> {
  if (!out) throw new UsageError('-o <out> is required');
  const target = resolve(out);
  if (inputs.some((input) => resolve(input) === target))
    throw new UsageError('refusing to overwrite the input');
  await writeAtomic(target, bytes);
  return target;
}

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  if (
    !command ||
    command === 'help' ||
    command === '--help' ||
    command === '-h'
  ) {
    console.log(USAGE);
    return command ? 0 : 1;
  }
  const { positional, flags } = parseArgs(rest);

  switch (command) {
    case 'inspect': {
      need(positional, 1, 'inspect <bundle>');
      const bytes = await readBytes(positional[0]!);
      if (flags.json) {
        console.log(
          JSON.stringify(
            { sha256: sha256(bytes), ...verifyBundle(bytes) },
            null,
            2,
          ),
        );
      } else {
        console.log(`${positional[0]}\n  sha256      ${sha256(bytes)}`);
        console.log(formatInspect(bytes));
      }
      return 0;
    }
    case 'verify': {
      need(positional, 1, 'verify <bundle>');
      const bytes = await readBytes(positional[0]!);
      const report = verifyBundle(bytes);
      if (flags.json)
        console.log(
          JSON.stringify({ sha256: sha256(bytes), ...report }, null, 2),
        );
      else
        console.log(
          `${positional[0]} sha256 ${sha256(bytes)}\n${formatVerify(report)}`,
        );
      return report.sendable ? 0 : report.ok ? 2 : 1;
    }
    case 'repack-main': {
      need(
        positional,
        1,
        'repack-main <stock-bundle> --version <x.y.z.w> -o <out>',
      );
      if (!flags.version) throw new UsageError('--version is required');
      const stock = await readBytes(positional[0]!);
      const result = repackMain(stock, flags.version);
      const target = await writeOutput(flags.out, positional, result.bytes);
      console.log(
        `repacked ${result.fromVersion} -> ${result.toVersion}: ${target}`,
      );
      console.log(`  sha256  ${sha256(result.bytes)}`);
      console.log(
        `  ${result.versionSites.length} version string(s) rewritten in the main image`,
      );
      console.log(formatDiff(result.diff));
      console.log(formatVerify(verifyBundle(result.bytes)));
      return 0;
    }
    case 'pack-main': {
      need(positional, 1, 'pack-main <app.bin> --version <x.y.z.w> -o <out>');
      if (!flags.version) throw new UsageError('--version is required');
      const app = await readBytes(positional[0]!);
      const result = packMain(app, { version: flags.version });
      const target = await writeOutput(flags.out, positional, result.bytes);
      console.log(
        `packed ${positional[0]} -> ${target}\n  sha256  ${sha256(result.bytes)}`,
      );
      console.log(formatVerify(result.report));
      return 0;
    }
    case 'diff': {
      need(positional, 2, 'diff <stock-bundle> <repacked-bundle>');
      const diff = diffRepack(
        await readBytes(positional[0]!),
        await readBytes(positional[1]!),
      );
      console.log(
        flags.json ? JSON.stringify(diff, null, 2) : formatDiff(diff),
      );
      return diff.ok ? 0 : 1;
    }
    case 'fetch': {
      need(positional, 1, 'fetch <version>');
      const cacheDir = flags.cacheDir
        ? resolve(flags.cacheDir)
        : defaultCacheDir();
      const { record, report, cached } = await fetchStock(
        positional[0]!,
        cacheDir,
      );
      console.log(
        `${cached ? 'already cached' : 'fetched'} ${record.version}: ${record.file}`,
      );
      console.log(
        `  sha256  ${record.sha256} (pinned official: ${record.matchesPinnedOfficial ? 'yes' : 'NO'})`,
      );
      console.log(formatVerify(report));
      return 0;
    }
    case 'import': {
      need(positional, 1, 'import <bundle>');
      const cacheDir = flags.cacheDir
        ? resolve(flags.cacheDir)
        : defaultCacheDir();
      const { record, report } = await importStock(positional[0]!, cacheDir);
      console.log(`imported ${record.version}: ${record.file}`);
      console.log(
        `  sha256  ${record.sha256} (${record.matchesPinnedOfficial ? 'matches the pinned official bundle' : 'NOT in the pinned catalog: unverified origin'})`,
      );
      console.log(formatVerify(report));
      return 0;
    }
    case 'catalog': {
      for (const r of STOCK_RELEASES)
        console.log(
          `${r.version.padEnd(10)} ${r.sha256}  ${stockReleaseUrl(r)}`,
        );
      return 0;
    }
    default:
      throw new UsageError(`unknown command ${command}`);
  }
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (error: unknown) => {
    if (error instanceof UsageError) {
      console.error(`wisp-ota: ${error.message}\n\n${USAGE}`);
      process.exit(64);
    }
    console.error(
      `wisp-ota: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exit(1);
  },
);
