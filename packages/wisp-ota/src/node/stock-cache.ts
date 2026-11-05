// Node-only: the git-ignored local cache of stock bundles (safety.md rules 7
// and 9). Bundles land in `<cache>/stock/g2-<version>.bin`, next to a JSON
// record with the SHA-256 they were pinned by.

import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import {
  STOCK_RELEASES,
  stockReleaseUrl,
  type StockRelease,
} from '../catalog.ts';
import { verifyBundle, type VerifyReport } from '../guards.ts';
import { mainComponents, parseBundle, parseMainImage } from '../parse.ts';
import { stockVersionFromHeader } from '../pack.ts';

export const CACHE_DIR_NAME = '.wisp-cache';

export function sha256(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

export function md5(bytes: Uint8Array): string {
  return createHash('md5').update(bytes).digest('hex');
}

/** `.wisp-cache` at the workspace root (the nearest parent with pnpm-workspace.yaml or .git). */
export function defaultCacheDir(from: string = process.cwd()): string {
  let dir = resolve(from);
  for (;;) {
    if (
      existsSync(join(dir, 'pnpm-workspace.yaml')) ||
      existsSync(join(dir, '.git'))
    ) {
      return join(dir, CACHE_DIR_NAME);
    }
    const parent = dirname(dir);
    if (parent === dir) return resolve(from, CACHE_DIR_NAME);
    dir = parent;
  }
}

export interface CacheRecord {
  version: string;
  file: string;
  size: number;
  sha256: string;
  md5: string;
  source: 'fetch' | 'import';
  url?: string;
  importedFrom?: string;
  /** True when the SHA-256 equals the pinned official one in catalog.ts. */
  matchesPinnedOfficial: boolean;
  recordedAt: string;
}

export async function writeAtomic(
  path: string,
  bytes: Uint8Array | string,
): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.tmp-${process.pid}`;
  await writeFile(tmp, bytes);
  await rename(tmp, path);
}

function stockPaths(
  cacheDir: string,
  version: string,
): { bin: string; json: string } {
  const base = join(cacheDir, 'stock', `g2-${version}`);
  return { bin: `${base}.bin`, json: `${base}.json` };
}

export interface CacheOptions {
  /** Pinned releases; defaults to catalog.ts. */
  releases?: readonly StockRelease[];
  fetchImpl?: typeof fetch;
}

function findRelease(
  releases: readonly StockRelease[],
  version: string,
): StockRelease | undefined {
  return releases.find((r) => r.version === version);
}

async function store(
  releases: readonly StockRelease[],
  cacheDir: string,
  version: string,
  bytes: Uint8Array,
  extra: Pick<CacheRecord, 'source' | 'url' | 'importedFrom'>,
): Promise<{ record: CacheRecord; report: VerifyReport }> {
  const report = verifyBundle(bytes);
  if (!report.ok) {
    throw new Error(
      `refusing to cache: bundle fails verification (${report.failed.join(', ')})`,
    );
  }
  const digest = sha256(bytes);
  const pinned = findRelease(releases, version);
  const paths = stockPaths(cacheDir, version);
  const record: CacheRecord = {
    version,
    file: paths.bin,
    size: bytes.length,
    sha256: digest,
    md5: md5(bytes),
    ...extra,
    matchesPinnedOfficial: pinned?.sha256 === digest,
    recordedAt: new Date().toISOString(),
  };
  await writeAtomic(paths.bin, bytes);
  await writeAtomic(paths.json, `${JSON.stringify(record, null, 2)}\n`);
  return { record, report };
}

/** Cross-check against webflasher's independently computed main-app end. */
function checkPinnedAppEnd(release: StockRelease, bytes: Uint8Array): void {
  const main = mainComponents(parseBundle(bytes))[0];
  if (!main) throw new Error('bundle has no main component');
  const end = parseMainImage(main.payload).appEnd;
  if (end !== release.mainAppEnd) {
    throw new Error(
      `main app end 0x${end.toString(16)} differs from the catalog's 0x${release.mainAppEnd.toString(16)}`,
    );
  }
}

/** Downloads an official bundle from Even's CDN, checks size + SHA-256 against the pin, caches it. */
export async function fetchStock(
  version: string,
  cacheDir: string,
  options: CacheOptions = {},
): Promise<{ record: CacheRecord; report: VerifyReport; cached: boolean }> {
  const releases = options.releases ?? STOCK_RELEASES;
  const fetchImpl = options.fetchImpl ?? fetch;
  const release = findRelease(releases, version);
  if (!release) {
    throw new Error(
      `unknown stock version "${version}"; known: see \`wisp-ota catalog\`, or use \`wisp-ota import <file>\``,
    );
  }
  const paths = stockPaths(cacheDir, version);
  if (existsSync(paths.bin)) {
    const bytes = new Uint8Array(await readFile(paths.bin));
    if (sha256(bytes) === release.sha256) {
      const record = JSON.parse(
        await readFile(paths.json, 'utf8').catch(() => 'null'),
      ) as CacheRecord | null;
      if (record) return { record, report: verifyBundle(bytes), cached: true };
    }
    await rm(paths.bin, { force: true });
  }
  const url = stockReleaseUrl(release);
  const response = await fetchImpl(url);
  if (!response.ok) throw new Error(`GET ${url}: HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length !== release.size) {
    throw new Error(
      `GET ${url}: ${bytes.length} bytes, pinned size is ${release.size}; nothing cached`,
    );
  }
  const digest = sha256(bytes);
  if (digest !== release.sha256) {
    throw new Error(
      `GET ${url}: SHA-256 ${digest} does not match the pinned ${release.sha256}; nothing cached`,
    );
  }
  checkPinnedAppEnd(release, bytes);
  const header = stockVersionFromHeader(parseBundle(bytes).version.text);
  if (header !== version)
    throw new Error(`bundle header says ${header}, expected ${version}`);
  const stored = await store(releases, cacheDir, version, bytes, {
    source: 'fetch',
    url,
  });
  return { ...stored, cached: false };
}

/** Copies a stock bundle you already have into the cache, keyed by its header version. */
export async function importStock(
  file: string,
  cacheDir: string,
  options: CacheOptions = {},
): Promise<{ record: CacheRecord; report: VerifyReport }> {
  const releases = options.releases ?? STOCK_RELEASES;
  const bytes = new Uint8Array(await readFile(file));
  const version = stockVersionFromHeader(parseBundle(bytes).version.text);
  const release = findRelease(releases, version);
  if (release && sha256(bytes) !== release.sha256) {
    throw new Error(
      `${file} says ${version} but its SHA-256 is not the pinned official one (${release.sha256}); not importing`,
    );
  }
  if (release) checkPinnedAppEnd(release, bytes);
  return store(releases, cacheDir, version, bytes, {
    source: 'import',
    importedFrom: resolve(file),
  });
}
