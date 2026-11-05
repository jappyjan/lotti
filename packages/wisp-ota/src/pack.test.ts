import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { readU32, writeU32 } from './bytes.ts';
import { APP_END_CEILING, MAIN_LOAD_ADDRESS, MAIN_PATH } from './constants.ts';
import { crc32 } from './crc.ts';
import { diffRepack } from './diff.ts';
import { GuardError, verifyBundle } from './guards.ts';
import {
  findVersionStrings,
  mainOnlyBundleSize,
  packMain,
  PackError,
  repackMain,
  wrapMainImage,
  type PackMainOptions,
} from './pack.ts';
import { parseBundle, parseMainImage } from './parse.ts';
import {
  filler,
  mainComponent,
  rawBundle,
  syntheticApp,
  syntheticMainPayload,
  syntheticStock,
} from './testing/synthetic.ts';

const AT = new Date(Date.UTC(2026, 10, 5, 12, 34, 56));

function failedGuards(fn: () => unknown): string[] {
  try {
    fn();
  } catch (error) {
    if (error instanceof GuardError) return error.failed.map((g) => g.id);
    throw error;
  }
  assert.fail('expected a GuardError');
}

describe('wrapMainImage', () => {
  it('writes the stock preamble', () => {
    const app = syntheticApp();
    const p = wrapMainImage(app);
    assert.equal(readU32(p, 0), ((0x04 << 24) | (app.length + 0x20)) >>> 0);
    assert.equal(readU32(p, 4), crc32(p.subarray(8)));
    assert.equal(readU32(p, 0x10), 0xcb);
    assert.equal(readU32(p, 0x14), MAIN_LOAD_ADDRESS);
    for (const off of [0x08, 0x0c, 0x18, 0x1c])
      assert.equal(readU32(p, off), 0);
  });

  it('matches the synthetic stock-style payload byte for byte', () => {
    const app = syntheticApp();
    assert.deepEqual(wrapMainImage(app), syntheticMainPayload(app));
  });
});

describe('packMain', () => {
  it('produces a sendable main-only bundle', () => {
    const { bytes, report } = packMain(syntheticApp(), {
      version: '0.1.0.1',
      buildTime: AT,
    });
    assert.equal(report.sendable, true);
    const parsed = parseBundle(bytes);
    assert.equal(parsed.componentCount, 1);
    assert.equal(parsed.components[0]!.header.type, 0);
    assert.equal(parsed.components[0]!.header.path.text, MAIN_PATH);
    assert.equal(parsed.version.text, 's200_v0.1.0.1');
    assert.equal(parsed.buildDate.text, '2026-11-05');
    assert.equal(parsed.buildTime.text, '12:34:56');
    assert.equal(
      bytes.length,
      mainOnlyBundleSize(syntheticApp().length + 0x20),
    );
  });

  it('is deterministic and identical to the stock-layout assembler', () => {
    const app = syntheticApp();
    const a = packMain(app, { version: '0.1.0.1', buildTime: AT }).bytes;
    const b = packMain(app, { version: '0.1.0.1', buildTime: AT }).bytes;
    assert.deepEqual(a, b);
    const reference = rawBundle([mainComponent(syntheticMainPayload(app))], {
      version: 's200_v0.1.0.1',
      buildDate: '2026-11-05',
      buildTime: '12:34:56',
    });
    assert.deepEqual(a, reference);
  });

  // pack-main side of each image guard: the packer refuses before writing anything.
  const cases: [string, Parameters<typeof syntheticApp>[0], string][] = [
    ['SP outside SRAM', { sp: 0x00500000 }, 'sp-vector'],
    ['SP unaligned', { sp: 0x2007fb02 }, 'sp-vector'],
    ['even reset vector', { reset: MAIN_LOAD_ADDRESS + 0x200 }, 'reset-vector'],
    ['reset vector outside image', { reset: 0x00700001 }, 'reset-vector'],
    [
      'app past 0x7F8000',
      { size: APP_END_CEILING - MAIN_LOAD_ADDRESS + 4 },
      'app-end',
    ],
    [
      'app reaching 0x7FE000',
      { size: 0x007fe000 - MAIN_LOAD_ADDRESS + 4 },
      'protected-regions',
    ],
    ['app too small for a vector table', { size: 0x10 }, 'image-size'],
  ];
  for (const [name, options, guard] of cases) {
    it(`refuses: ${name}`, () => {
      const app = name.includes('too small')
        ? new Uint8Array(0x10)
        : syntheticApp(options);
      if (name.includes('too small')) {
        writeU32(app, 0, 0x2007fb00);
        writeU32(app, 4, MAIN_LOAD_ADDRESS + 0x9);
      }
      assert.ok(
        failedGuards(() => packMain(app, { version: '0.1.0.1' })).includes(
          guard,
        ),
      );
    });
  }

  it('refuses an image that overflows the 24-bit size field', () => {
    assert.throws(
      () => packMain(new Uint8Array(0x01000000), { version: '0.1.0.1' }),
      PackError,
    );
  });

  it('refuses a malformed version', () => {
    for (const version of ['', '1.2.3', 'v1.2.3.4', '1.2.3.4 ', '1111.2.3.4']) {
      assert.throws(
        () => packMain(syntheticApp(), { version }),
        PackError,
        version,
      );
    }
  });

  it('ignores unknown options: there is no way to relax a guard', () => {
    const options = {
      version: '0.1.0.1',
      skipGuards: true,
      force: true,
      unsafe: true,
    } as unknown as PackMainOptions;
    assert.ok(
      failedGuards(() => packMain(syntheticApp({ sp: 0 }), options)).includes(
        'sp-vector',
      ),
    );
  });
});

describe('findVersionStrings', () => {
  it('finds only aligned, NUL-bracketed copies', () => {
    const payload = syntheticMainPayload(
      syntheticApp({ version: '2.2.6.10', size: 0x8000, versionCopies: 4 }),
    );
    assert.deepEqual(
      findVersionStrings(payload, '2.2.6.10'),
      [0x1020, 0x1120, 0x1220, 0x1320],
    );
  });
});

describe('repackMain (rung 1)', () => {
  const stock = syntheticStock('2.2.6.10');

  it('changes only the version strings and the CRCs', () => {
    const result = repackMain(stock, '2.2.6.99');
    assert.equal(result.report.sendable, true);
    assert.equal(result.versionSites.length, 3);
    assert.equal(result.diff.ok, true, result.diff.problems.join('; '));
    assert.equal(
      result.diff.payloadChanges.filter((c) => c.kind === 'version-string')
        .length,
      3,
    );
    assert.equal(
      result.diff.payloadChanges.filter((c) => c.kind === 'preamble-crc')
        .length,
      1,
    );
    assert.equal(
      result.diff.payloadChanges.filter((c) => c.kind === 'unexplained').length,
      0,
    );
    assert.deepEqual(
      result.diff.componentHeaderChanges.map((c) => c.kind),
      ['component-crc'],
    );
    assert.equal(result.diff.droppedComponents.length, 5);
    assert.equal(result.diff.buildDateTimeKept, true);

    const out = parseBundle(result.bytes);
    assert.equal(out.version.text, 's200_v2.2.6.99');
    assert.equal(out.componentCount, 1);
    assert.equal(out.components[0]!.toc.entryId, 6);
    const text = String.fromCharCode(...out.components[0]!.payload);
    assert.ok(
      text.includes('master:v2.2.6.10-0-g'),
      'git-describe decoy untouched',
    );
    assert.ok(
      text.includes('\u00002.2.6.10\u0000'),
      'unaligned decoy untouched',
    );
  });

  it('output passes an independent from-scratch verification', () => {
    const { bytes } = repackMain(stock, '9.2.6.10');
    const again = verifyBundle(bytes.slice());
    assert.equal(again.sendable, true);
    assert.equal(diffRepack(stock, bytes).ok, true);
  });

  it('refuses a version of another length', () => {
    assert.throws(() => repackMain(stock, '2.2.6.1'), /same length/);
    assert.throws(() => repackMain(stock, '2.2.6.100'), /same length/);
  });

  it('refuses the unchanged version and malformed versions', () => {
    assert.throws(
      () => repackMain(stock, '2.2.6.10'),
      /equals the stock version/,
    );
    assert.throws(() => repackMain(stock, '2.2.6.a0'), PackError);
    assert.throws(() => repackMain(stock, '22.6.10x'), PackError);
  });

  it('refuses a stock bundle with a bad CRC', () => {
    const broken = stock.slice();
    broken[broken.length - 100]! ^= 1;
    assert.throws(() => repackMain(broken, '2.2.6.99'), GuardError);
  });

  it('refuses a stock bundle whose main image breaks a guard', () => {
    const bad = syntheticStock(
      '2.2.6.10',
      syntheticApp({ version: '2.2.6.10', size: 0x8000, sp: 0x00500000 }),
    );
    assert.throws(() => repackMain(bad, '2.2.6.99'), GuardError);
  });

  it('refuses when the main image carries no standalone version string', () => {
    const plain = syntheticStock('2.2.6.10', syntheticApp({ size: 0x8000 }));
    assert.throws(() => repackMain(plain, '2.2.6.99'), /no standalone/);
  });

  it('refuses a non-stock header version', () => {
    const odd = rawBundle(
      [
        mainComponent(
          syntheticMainPayload(
            syntheticApp({ version: '2.2.6.10', size: 0x8000 }),
          ),
        ),
      ],
      {
        version: 'wisp_2.2.6.10',
      },
    );
    assert.throws(() => repackMain(odd, '2.2.6.99'), /stock form/);
  });

  it('keeps the main entry id of a five-component stock bundle', () => {
    const five = syntheticStock('2.2.4.34', undefined, false);
    assert.equal(parseBundle(five).components[4]!.toc.entryId, 5);
    const result = repackMain(five, '2.2.4.35');
    assert.equal(parseBundle(result.bytes).components[0]!.toc.entryId, 5);
    assert.equal(result.diff.ok, true);
    assert.equal(result.diff.droppedComponents.length, 4);
  });

  it('the repacked image installs at the same place as stock', () => {
    const { bytes } = repackMain(stock, '2.2.6.99');
    const s = parseMainImage(parseBundle(stock).components[5]!.payload);
    const r = parseMainImage(parseBundle(bytes).components[0]!.payload);
    assert.equal(r.appEnd, s.appEnd);
    assert.equal(r.initialSp, s.initialSp);
    assert.equal(r.resetVector, s.resetVector);
  });
});

describe('diffRepack', () => {
  const stock = syntheticStock('2.2.6.10');
  const repacked = repackMain(stock, '2.2.6.99').bytes;

  function rebuildWith(
    edit: (payload: Uint8Array) => void,
    path = MAIN_PATH,
  ): Uint8Array {
    const payload = parseBundle(repacked).components[0]!.payload.slice();
    edit(payload);
    writeU32(payload, 4, crc32(payload.subarray(8)));
    return rawBundle([{ ...mainComponent(payload), path }], {
      version: 's200_v2.2.6.99',
      buildDate: '2026-07-06',
      buildTime: '21:39:36',
    });
  }

  it('flags any extra payload change, even with valid CRCs', () => {
    const tampered = rebuildWith((p) => (p[0x3000]! ^= 0x01));
    assert.equal(
      verifyBundle(tampered).sendable,
      true,
      'guards alone cannot see this',
    );
    const diff = diffRepack(stock, tampered);
    assert.equal(diff.ok, false);
    assert.equal(
      diff.payloadChanges.filter((c) => c.kind === 'unexplained').length,
      1,
    );
  });

  it('flags a component header change', () => {
    const diff = diffRepack(
      stock,
      rebuildWith(() => {}, 'ota/s200_firmware_ota.bix'),
    );
    assert.equal(diff.ok, false);
    assert.ok(
      diff.componentHeaderChanges.some((c) => c.kind === 'unexplained'),
    );
  });

  it('flags a changed build date', () => {
    const payload = parseBundle(repacked).components[0]!.payload;
    const other = rawBundle([mainComponent(payload)], {
      version: 's200_v2.2.6.99',
      buildDate: '2026-07-07',
    });
    assert.equal(diffRepack(stock, other).ok, false);
  });

  it('flags extra components in the repack', () => {
    const payload = parseBundle(repacked).components[0]!.payload;
    const extra = rawBundle(
      [
        {
          entryId: 5,
          type: 1,
          path: 'ota/s200_bootloader.bin',
          payload: filler(100),
        },
        mainComponent(payload),
      ],
      { version: 's200_v2.2.6.99' },
    );
    assert.equal(diffRepack(stock, extra).ok, false);
  });
});
