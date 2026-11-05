// One or more failing inputs per guard. Every test builds a synthetic bundle
// that is valid except for the one defect, then checks that verify flags
// exactly that guard (plus guards that necessarily fail with it).

import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { writeU32 } from './bytes.ts';
import {
  APP_END_CEILING,
  MAIN_LOAD_ADDRESS,
  MAX_BUNDLE_SIZE,
  PREAMBLE_SIZE,
  SRAM_END,
} from './constants.ts';
import {
  assertSendable,
  GUARDS,
  GuardError,
  verifyBundle,
  type GuardId,
} from './guards.ts';
import {
  filler,
  mainComponent,
  mainOnly,
  rawBundle,
  syntheticApp,
  syntheticMainPayload,
  syntheticStock,
} from './testing/synthetic.ts';

function validPayload(): Uint8Array {
  return syntheticMainPayload(syntheticApp());
}

/** Asserts the bundle is not sendable and exactly `ids` failed. */
function expectFailures(bytes: Uint8Array, ids: GuardId[]): void {
  const report = verifyBundle(bytes);
  assert.equal(report.sendable, false, 'must not be sendable');
  assert.deepEqual([...report.failed].sort(), [...ids].sort());
  assert.throws(() => assertSendable(bytes), GuardError);
}

/** App size whose install end lands exactly at `end`. */
function appSizeEndingAt(end: number): number {
  return end - MAIN_LOAD_ADDRESS;
}

describe('baseline', () => {
  it('a well-formed main-only bundle passes every guard', () => {
    const report = verifyBundle(mainOnly(validPayload()));
    assert.equal(report.ok, true);
    assert.equal(report.sendable, true);
    assert.deepEqual(report.failed, []);
    assert.deepEqual(
      report.guards.map((g) => g.id).sort(),
      GUARDS.map((g) => g.id).sort(),
      'every guard is reported',
    );
  });

  it('a stock-shaped bundle is valid but not sendable (main-only)', () => {
    const report = verifyBundle(syntheticStock());
    assert.equal(report.ok, true);
    assert.equal(report.sendable, false);
    assert.deepEqual(report.failed, ['main-only']);
    assert.equal(report.components.length, 6);
  });

  it('the report is plain JSON', () => {
    const report = verifyBundle(mainOnly(validPayload()));
    assert.deepEqual(JSON.parse(JSON.stringify(report)), report);
  });
});

describe('guard: container', () => {
  it('rejects a non-EVENOTA file', () => {
    const report = verifyBundle(filler(4096));
    assert.equal(report.ok, false);
    assert.ok(report.failed.includes('container'));
  });

  it('rejects a corrupted TOC trailer', () => {
    const bytes = mainOnly(validPayload());
    bytes[0x50] = 0x45;
    expectFailures(bytes, ['container']);
  });

  it('rejects trailing bytes after the last component', () => {
    const good = mainOnly(validPayload());
    const bytes = new Uint8Array(good.length + 4);
    bytes.set(good);
    expectFailures(bytes, ['container']);
  });

  it('rejects a bad component magic', () => {
    const bytes = mainOnly(validPayload());
    writeU32(bytes, 0x60 + 0x14, 0x4e455646);
    expectFailures(bytes, ['container']);
  });

  it('rejects nonstandard reserved header words', () => {
    const bytes = mainOnly(validPayload());
    writeU32(bytes, 0x60 + 0x18, 0);
    expectFailures(bytes, ['container']);
  });

  it('rejects a truncated file', () => {
    const bytes = mainOnly(validPayload()).subarray(0, 0x100);
    const report = verifyBundle(bytes);
    assert.equal(report.ok, false);
    assert.ok(report.failed.includes('container'));
  });
});

describe('guard: bundle-size', () => {
  it('rejects a bundle above 16 MiB', () => {
    const bytes = rawBundle([
      mainComponent(validPayload()),
      {
        entryId: 7,
        type: 2,
        path: 'font/huge.bin',
        payload: new Uint8Array(MAX_BUNDLE_SIZE),
      },
    ]);
    const report = verifyBundle(bytes);
    assert.equal(report.ok, false);
    assert.deepEqual([...report.failed].sort(), ['bundle-size', 'main-only']);
  });
});

describe('guard: component-crc', () => {
  it('rejects a wrong TOC CRC', () => {
    const payload = validPayload();
    expectFailures(
      rawBundle([{ ...mainComponent(payload), tocCrc: 0x12345678 }]),
      ['component-crc'],
    );
  });

  it('rejects a wrong component header CRC', () => {
    const payload = validPayload();
    expectFailures(
      rawBundle([{ ...mainComponent(payload), headerCrc: 0x12345678 }]),
      ['component-crc'],
    );
  });

  it('rejects a payload byte flipped after packing', () => {
    const bytes = mainOnly(validPayload());
    bytes[bytes.length - 1]! ^= 1;
    expectFailures(bytes, ['component-crc', 'preamble-crc']);
  });
});

describe('guard: main-only', () => {
  for (const type of [1, 2, 3, 4, 5, 6]) {
    it(`rejects a bundle that also carries type ${type}`, () => {
      const bytes = rawBundle([
        {
          entryId: 1,
          type,
          path: 'firmware/other.bin',
          payload: filler(512, type),
        },
        mainComponent(validPayload()),
      ]);
      expectFailures(bytes, ['main-only']);
    });
  }
});

describe('guard: main-present', () => {
  it('rejects a bundle without a main component', () => {
    const bytes = rawBundle([
      { entryId: 1, type: 3, path: 'firmware/touch.bin', payload: filler(512) },
    ]);
    const report = verifyBundle(bytes);
    assert.equal(report.ok, false);
    assert.ok(report.failed.includes('main-present'));
    assert.ok(report.failed.includes('main-only'));
  });

  it('rejects two main components', () => {
    const bytes = rawBundle([
      mainComponent(validPayload(), 5),
      mainComponent(validPayload(), 6),
    ]);
    const report = verifyBundle(bytes);
    assert.ok(report.failed.includes('main-present'));
    assert.equal(report.sendable, false);
  });
});

describe('guard: main-target', () => {
  it('rejects a different staging path', () => {
    const bytes = rawBundle([
      { ...mainComponent(validPayload()), path: 'ota/s200_bootloader.bin' },
    ]);
    expectFailures(bytes, ['main-target']);
  });

  it('rejects a non-littlefs storage type', () => {
    const bytes = rawBundle([
      { ...mainComponent(validPayload()), storageType: 0 },
    ]);
    expectFailures(bytes, ['main-target']);
  });
});

describe('guard: preamble-format', () => {
  it('rejects wrong flags', () => {
    const p = syntheticMainPayload(syntheticApp(), (q) =>
      writeU32(q, 0, ((0x05 << 24) | q.length) >>> 0),
    );
    expectFailures(mainOnly(p), ['preamble-format']);
  });

  it('rejects a wrong data type', () => {
    const p = syntheticMainPayload(syntheticApp(), (q) =>
      writeU32(q, 0x10, 0xcc),
    );
    expectFailures(mainOnly(p), ['preamble-format']);
  });

  it('rejects nonzero reserved words', () => {
    const p = syntheticMainPayload(syntheticApp(), (q) => writeU32(q, 0x18, 1));
    expectFailures(mainOnly(p), ['preamble-format']);
  });
});

describe('guard: load-address', () => {
  it('rejects a load address other than 0x438000', () => {
    const p = syntheticMainPayload(syntheticApp(), (q) =>
      writeU32(q, 0x14, MAIN_LOAD_ADDRESS + 0x1000),
    );
    // The reset vector is then judged against the wrong base too.
    expectFailures(mainOnly(p), ['load-address', 'reset-vector']);
  });
});

describe('guard: preamble-size', () => {
  it('rejects a size field smaller than the payload', () => {
    const p = syntheticMainPayload(syntheticApp(), (q) =>
      writeU32(q, 0, ((0x04 << 24) | (q.length - 4)) >>> 0),
    );
    expectFailures(mainOnly(p), ['preamble-size']);
  });

  it('rejects a size field larger than the payload', () => {
    const p = syntheticMainPayload(syntheticApp(), (q) =>
      writeU32(q, 0, ((0x04 << 24) | (q.length + 4)) >>> 0),
    );
    expectFailures(mainOnly(p), ['preamble-size']);
  });
});

describe('guard: image-size', () => {
  it('rejects a payload without a full vector table', () => {
    const app = new Uint8Array(0x20);
    writeU32(app, 0, 0x2007fb00);
    writeU32(app, 4, MAIN_LOAD_ADDRESS + 0x11);
    const report = verifyBundle(mainOnly(syntheticMainPayload(app)));
    assert.ok(report.failed.includes('image-size'));
    assert.equal(report.sendable, false);
  });
});

describe('guard: app-end', () => {
  it('accepts an app ending exactly at the 0x7F8000 ceiling', () => {
    const p = syntheticMainPayload(
      syntheticApp({ size: appSizeEndingAt(APP_END_CEILING) }),
    );
    assert.equal(verifyBundle(mainOnly(p)).sendable, true);
  });

  it('rejects an app ending 4 bytes past the ceiling', () => {
    const p = syntheticMainPayload(
      syntheticApp({ size: appSizeEndingAt(APP_END_CEILING) + 4 }),
    );
    expectFailures(mainOnly(p), ['app-end']);
  });

  it('judges the declared size too (what the bootloader trusts)', () => {
    const app = syntheticApp({
      size: appSizeEndingAt(APP_END_CEILING) - 0x100,
    });
    const p = syntheticMainPayload(app, (q) =>
      writeU32(q, 0, ((0x04 << 24) | (q.length + 0x200)) >>> 0),
    );
    expectFailures(mainOnly(p), ['preamble-size', 'app-end']);
  });
});

describe('guard: protected-regions', () => {
  it('rejects an image that would land on the Even bootloader', () => {
    const p = syntheticMainPayload(syntheticApp(), (q) =>
      writeU32(q, 0x14, 0x00410000),
    );
    expectFailures(mainOnly(p), [
      'load-address',
      'protected-regions',
      'reset-vector',
    ]);
  });

  it('rejects an image that reaches the update flag at 0x7FE000', () => {
    const p = syntheticMainPayload(
      syntheticApp({ size: appSizeEndingAt(0x007fe000) + 4 }),
    );
    expectFailures(mainOnly(p), ['app-end', 'protected-regions']);
  });
});

describe('guard: sp-vector', () => {
  for (const [name, sp] of [
    ['below SRAM', 0x1fff0000],
    ['MRAM', 0x00500000],
    ['past SRAM', SRAM_END + 8],
    ['not 8-byte aligned', 0x2007fb04],
    ['at the SRAM base (empty stack)', 0x20000000],
  ] as const) {
    it(`rejects an initial SP ${name}`, () => {
      expectFailures(mainOnly(syntheticMainPayload(syntheticApp({ sp }))), [
        'sp-vector',
      ]);
    });
  }

  it('accepts the top of SRAM', () => {
    assert.equal(
      verifyBundle(
        mainOnly(syntheticMainPayload(syntheticApp({ sp: SRAM_END }))),
      ).sendable,
      true,
    );
  });
});

describe('guard: reset-vector', () => {
  it('rejects a non-Thumb (even) reset vector', () => {
    expectFailures(
      mainOnly(
        syntheticMainPayload(
          syntheticApp({ reset: MAIN_LOAD_ADDRESS + 0x200 }),
        ),
      ),
      ['reset-vector'],
    );
  });

  it('rejects a reset vector past the image end', () => {
    const size = 0x4000;
    expectFailures(
      mainOnly(
        syntheticMainPayload(
          syntheticApp({ size, reset: MAIN_LOAD_ADDRESS + size + 1 }),
        ),
      ),
      ['reset-vector'],
    );
  });

  it('rejects a reset vector below the image', () => {
    expectFailures(
      mainOnly(syntheticMainPayload(syntheticApp({ reset: 0x00410001 }))),
      ['reset-vector'],
    );
  });

  it('rejects a reset vector into the vector table', () => {
    expectFailures(
      mainOnly(
        syntheticMainPayload(syntheticApp({ reset: MAIN_LOAD_ADDRESS + 0x9 })),
      ),
      ['reset-vector'],
    );
  });
});

describe('guard: preamble-crc', () => {
  it('rejects a stale preamble CRC (outer CRC-32C still valid)', () => {
    const payload = validPayload();
    payload[PREAMBLE_SIZE + 0x100]! ^= 0xff;
    // rawBundle recomputes the outer CRC-32C, so only the inner layer is wrong.
    expectFailures(mainOnly(payload), ['preamble-crc']);
  });
});

describe('no bypass', () => {
  it('every guard in GUARDS has a failing test above', () => {
    // Keep this list in sync with the describe blocks: adding a guard without a test fails here.
    const tested: GuardId[] = [
      'container',
      'bundle-size',
      'component-crc',
      'main-only',
      'main-present',
      'main-target',
      'preamble-format',
      'load-address',
      'preamble-size',
      'image-size',
      'app-end',
      'protected-regions',
      'sp-vector',
      'reset-vector',
      'preamble-crc',
    ];
    assert.deepEqual([...tested].sort(), GUARDS.map((g) => g.id).sort());
  });

  it('verifyBundle and assertSendable take no options', () => {
    assert.equal(verifyBundle.length, 1);
    assert.equal(assertSendable.length, 1);
  });
});
