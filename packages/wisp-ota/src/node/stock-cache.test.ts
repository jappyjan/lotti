import assert from 'node:assert/strict';
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, describe, it } from 'node:test';
import type { StockRelease } from '../catalog.ts';
import { STOCK_RELEASES } from '../catalog.ts';
import { mainComponents, parseBundle, parseMainImage } from '../parse.ts';
import { syntheticStock } from '../testing/synthetic.ts';
import {
  fetchStock,
  importStock,
  md5,
  sha256,
  type CacheRecord,
} from './stock-cache.ts';

const dir = mkdtempSync(join(tmpdir(), 'wisp-ota-cache-'));
after(() => rmSync(dir, { recursive: true, force: true }));

const bundle = syntheticStock('9.9.9.9');
const release: StockRelease = {
  version: '9.9.9.9',
  md5: md5(bundle),
  size: bundle.length,
  sha256: sha256(bundle),
  mainAppEnd: parseMainImage(mainComponents(parseBundle(bundle))[0]!.payload)
    .appEnd,
};

function fakeFetch(bytes: Uint8Array, seen: string[] = []): typeof fetch {
  return (async (url: string | URL | Request) => {
    seen.push(String(url));
    return new Response(bytes.slice());
  }) as typeof fetch;
}

describe('fetchStock', () => {
  it('downloads from the CDN, pins SHA-256 and records it', async () => {
    const cache = join(dir, 'ok');
    const seen: string[] = [];
    const { record, cached } = await fetchStock('9.9.9.9', cache, {
      releases: [release],
      fetchImpl: fakeFetch(bundle, seen),
    });
    assert.equal(cached, false);
    assert.deepEqual(seen, [
      `https://cdn.evenreal.co/firmware/${release.md5}.bin`,
    ]);
    assert.equal(record.sha256, release.sha256);
    assert.equal(record.matchesPinnedOfficial, true);
    const json = JSON.parse(
      readFileSync(join(cache, 'stock', 'g2-9.9.9.9.json'), 'utf8'),
    ) as CacheRecord;
    assert.equal(json.sha256, release.sha256);
    assert.equal(
      sha256(readFileSync(join(cache, 'stock', 'g2-9.9.9.9.bin'))),
      release.sha256,
    );

    const again = await fetchStock('9.9.9.9', cache, {
      releases: [release],
      fetchImpl: fakeFetch(new Uint8Array(), []),
    });
    assert.equal(again.cached, true);
  });

  it('caches nothing when the SHA-256 does not match', async () => {
    const cache = join(dir, 'sha');
    const tampered = bundle.slice();
    tampered[tampered.length - 1]! ^= 1;
    await assert.rejects(
      fetchStock('9.9.9.9', cache, {
        releases: [release],
        fetchImpl: fakeFetch(tampered),
      }),
      /does not match the pinned/,
    );
    assert.equal(existsSync(join(cache, 'stock', 'g2-9.9.9.9.bin')), false);
  });

  it('caches nothing when the size does not match', async () => {
    const cache = join(dir, 'size');
    await assert.rejects(
      fetchStock('9.9.9.9', cache, {
        releases: [release],
        fetchImpl: fakeFetch(bundle.subarray(1)),
      }),
      /pinned size/,
    );
    assert.equal(existsSync(join(cache, 'stock')), false);
  });

  it('refuses an unknown version', async () => {
    await assert.rejects(
      fetchStock('1.0.0.0', join(dir, 'unknown'), { releases: [release] }),
      /unknown stock version/,
    );
  });

  it("cross-checks the catalog's main app end", async () => {
    const wrong = { ...release, mainAppEnd: release.mainAppEnd + 4 };
    await assert.rejects(
      fetchStock('9.9.9.9', join(dir, 'end'), {
        releases: [wrong],
        fetchImpl: fakeFetch(bundle),
      }),
      /differs from the catalog/,
    );
  });
});

describe('importStock', () => {
  it('imports a pinned bundle', async () => {
    const file = join(dir, 'pinned.bin');
    writeFileSync(file, bundle);
    const { record } = await importStock(file, join(dir, 'imp'), {
      releases: [release],
    });
    assert.equal(record.matchesPinnedOfficial, true);
    assert.equal(record.source, 'import');
  });

  it('imports an unknown version, marked as unverified origin', async () => {
    const file = join(dir, 'unknown.bin');
    writeFileSync(file, bundle);
    const { record } = await importStock(file, join(dir, 'imp2'), {
      releases: [],
    });
    assert.equal(record.matchesPinnedOfficial, false);
  });

  it('refuses a file claiming a pinned version with another hash', async () => {
    const file = join(dir, 'fake.bin');
    writeFileSync(
      file,
      syntheticStock('9.9.9.9', undefined).map((b, i) =>
        i === 0x4000 ? b ^ 1 : b,
      ),
    );
    await assert.rejects(
      importStock(file, join(dir, 'imp3'), { releases: [release] }),
      /not the pinned official/,
    );
  });
});

describe('pinned catalog', () => {
  it('has well-formed, unique entries', () => {
    const versions = new Set<string>();
    for (const r of STOCK_RELEASES) {
      assert.match(r.sha256, /^[0-9a-f]{64}$/);
      assert.match(r.md5, /^[0-9a-f]{32}$/);
      assert.ok(r.mainAppEnd <= 0x7f8000, `${r.version} app end`);
      assert.ok(!versions.has(r.version));
      versions.add(r.version);
    }
  });

  it("agrees with g2flash's build_cfw.sh pin for 2.3.0.24", () => {
    const r = STOCK_RELEASES.find((x) => x.version === '2.3.0.24')!;
    assert.equal(r.md5, '1dbdf37b03a1169c384945e94d671371');
  });
});
