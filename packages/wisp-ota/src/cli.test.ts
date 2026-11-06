import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  mainOnly,
  syntheticApp,
  syntheticMainPayload,
  syntheticStock,
} from './testing/synthetic.ts';

const CLI = join(dirname(fileURLToPath(import.meta.url)), 'cli.js');
const dir = mkdtempSync(join(tmpdir(), 'wisp-ota-cli-'));
after(() => rmSync(dir, { recursive: true, force: true }));

function run(...args: string[]): {
  code: number | null;
  stdout: string;
  stderr: string;
} {
  const r = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8' });
  return { code: r.status, stdout: r.stdout, stderr: r.stderr };
}

function file(name: string, bytes: Uint8Array): string {
  const path = join(dir, name);
  writeFileSync(path, bytes);
  return path;
}

describe('wisp-ota CLI', () => {
  const stock = file('stock.bin', syntheticStock('2.2.6.10'));
  const good = file('good.bin', mainOnly(syntheticMainPayload(syntheticApp())));
  const bad = file(
    'bad.bin',
    mainOnly(syntheticMainPayload(syntheticApp({ sp: 0x00500000 }))),
  );

  it('verify: 0 sendable, 2 valid stock, 1 invalid', () => {
    assert.equal(run('verify', good).code, 0);
    const s = run('verify', stock);
    assert.equal(s.code, 2);
    assert.match(s.stdout, /VALID, NOT SENDABLE/);
    const b = run('verify', bad);
    assert.equal(b.code, 1);
    assert.match(b.stdout, /FAIL\s+sp-vector/);
  });

  it('verify --json gives the machine-readable report', () => {
    const report = JSON.parse(run('verify', stock, '--json').stdout);
    assert.equal(report.reportVersion, 1);
    assert.equal(report.ok, true);
    assert.equal(report.sendable, false);
    assert.deepEqual(report.failed, ['main-only']);
    assert.match(report.sha256, /^[0-9a-f]{64}$/);
  });

  it('inspect lists components, CRCs and the vector table', () => {
    const r = run('inspect', stock);
    assert.equal(r.code, 0);
    for (const needle of [
      'ota/s200_firmware_ota.bin',
      'firmware/box.bin',
      'SP 0x2007fb00',
      'reset 0x',
      'installs',
      'ok',
    ]) {
      assert.ok(r.stdout.includes(needle), needle);
    }
  });

  it('repack-main writes a sendable bundle and a clean diff', () => {
    const out = join(dir, 'repacked.bin');
    const r = run('repack-main', stock, '--version', '2.2.6.99', '-o', out);
    assert.equal(r.code, 0, r.stderr);
    assert.match(r.stdout, /only version string and CRC fields differ/);
    assert.equal(run('verify', out).code, 0);
    assert.equal(run('diff', stock, out).code, 0);
  });

  it('pack-main packs a raw app', () => {
    const app = file('app.bin', syntheticApp());
    const out = join(dir, 'packed.bin');
    assert.equal(
      run('pack-main', app, '--version', '0.1.0.1', '-o', out).code,
      0,
    );
    assert.equal(run('verify', out).code, 0);
  });

  it('pack-main refuses an unsafe app and writes nothing', () => {
    const app = file('unsafe.bin', syntheticApp({ reset: 0x00438200 }));
    const out = join(dir, 'unsafe-out.bin');
    const r = run('pack-main', app, '--version', '0.1.0.1', '-o', out);
    assert.equal(r.code, 1);
    assert.match(r.stderr, /reset-vector/);
    assert.throws(() => readFileSync(out));
  });

  it('refuses to overwrite its input', () => {
    const copy = file('stock-copy.bin', syntheticStock('2.2.6.10'));
    assert.equal(
      run('repack-main', copy, '--version', '2.2.6.99', '-o', copy).code,
      64,
    );
  });

  it('rejects every unknown option, including would-be guard bypasses', () => {
    for (const flag of [
      '--force',
      '--skip-guards',
      '--no-verify',
      '--unsafe',
      '--allow-components',
    ]) {
      const r = run('verify', stock, flag);
      assert.equal(r.code, 64, flag);
      assert.match(r.stderr, /unknown option/);
    }
  });
});
