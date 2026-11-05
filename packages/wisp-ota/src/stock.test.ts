// Real stock bundles, when present locally in the git-ignored cache
// (`wisp-ota fetch <version>`). Skipped in CI and on fresh checkouts.

import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { stockRelease } from './catalog.ts';
import { diffRepack } from './diff.ts';
import { verifyBundle } from './guards.ts';
import { defaultCacheDir, sha256 } from './node/stock-cache.ts';
import { repackMain } from './pack.ts';

const stockDir = join(defaultCacheDir(), 'stock');
const files = existsSync(stockDir)
  ? readdirSync(stockDir).filter((f) => f.endsWith('.bin'))
  : [];

describe(
  'cached stock bundles',
  {
    skip: files.length === 0 ? 'no stock bundles in .wisp-cache/stock' : false,
  },
  () => {
    for (const name of files) {
      it(name, () => {
        const bytes = new Uint8Array(readFileSync(join(stockDir, name)));
        const version = name.replace(/^g2-/, '').replace(/\.bin$/, '');
        const pinned = stockRelease(version);
        if (pinned) assert.equal(sha256(bytes), pinned.sha256);

        const report = verifyBundle(bytes);
        assert.equal(report.ok, true, report.failed.join(', '));
        assert.deepEqual(report.failed, ['main-only']);

        const bumped = version.replace(/\d$/, (d) =>
          String((Number(d) + 1) % 10),
        );
        const result = repackMain(bytes, bumped);
        assert.equal(result.report.sendable, true);
        assert.ok(result.versionSites.length > 0);
        assert.equal(diffRepack(bytes, result.bytes).ok, true);
      });
    }
  },
);
