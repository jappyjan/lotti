import assert from 'node:assert/strict';
import { test } from 'node:test';
import { rng } from '../testing/random.ts';
import { toHex } from './bytes.ts';
import {
  ErrorPayload,
  Messages,
  Session,
  decodeBody,
  encodeBody,
  findMessage,
  type MessageDef,
} from './messages.ts';
import type { FieldType, Fields, Struct, Values } from './struct.ts';
import { decodeSamples } from './constants.ts';

const RANGES: Record<string, [number, number]> = {
  u8: [0, 255],
  i8: [-128, 127],
  u16: [0, 0xffff],
  i16: [-0x8000, 0x7fff],
  u32: [0, 0xffffffff],
  i32: [-0x80000000, 0x7fffffff],
  u64: [0, Number.MAX_SAFE_INTEGER],
};

function randomValues(
  fields: Fields,
  r: ReturnType<typeof rng>,
): Values<Fields> {
  const out: Record<string, unknown> = {};
  for (const [k, t] of Object.entries(fields)) out[k] = randomValue(t, r);
  for (const [k, t] of Object.entries(fields))
    if (typeof t !== 'string') out[t.count] = (out[k] as unknown[]).length;
  return out as Values<Fields>;
}

function randomValue(t: FieldType, r: ReturnType<typeof rng>): unknown {
  if (typeof t !== 'string')
    return Array.from({ length: r.int(0, 4) }, () => randomValues(t.item, r));
  if (t === 'str16')
    return ['', 'a', 'demo', 'exactly sixteen!', 'ü€'][r.int(0, 4)];
  if (t === 'utf8') return ['', 'hello 🙂', 'x'.repeat(100)][r.int(0, 2)];
  if (t === 'hash16') return r.bytes(16);
  if (t === 'sha256') return r.bytes(32);
  if (t === 'bytes') return r.bytes(r.int(0, 50));
  const [lo, hi] = RANGES[t]!;
  return lo + Math.floor(r.next() * (hi - lo));
}

const structs = (): [string, Struct][] =>
  Object.values(Messages).flatMap((g) =>
    (Object.values(g) as MessageDef[]).flatMap((m) =>
      (['request', 'response', 'event'] as const)
        .filter((k) => m[k])
        .map((k): [string, Struct] => [`${m.name}.${k}`, m[k]!]),
    ),
  );

test('every message round trips with random values', () => {
  const r = rng(3);
  for (const [name, s] of structs())
    for (let i = 0; i < 50; i++) {
      const v = randomValues(s.fields, r);
      assert.deepEqual(s.decode(s.encode(v)), v, name);
    }
});

test('append-only: trailing bytes ignored, missing trailing fields defaulted', () => {
  for (const [name, s] of structs()) {
    const fields = Object.values(s.fields);
    if (
      fields.some((t) => t === 'bytes' || t === 'utf8' || typeof t !== 'string')
    )
      continue;
    const r = rng(4);
    const v = randomValues(s.fields, r);
    const bytes = s.encode(v);
    const longer = new Uint8Array(bytes.length + 7).fill(0xee);
    longer.set(bytes);
    assert.deepEqual(s.decode(longer), v, name);
    assert.deepEqual(s.decode(new Uint8Array(0)), s.decode(s.encode({})), name);
  }
  // HELLO from older firmware without session_timeout_ms → the spec default.
  const hello = Session.hello.response!;
  const full = hello.encode({
    maxFrame: 512,
    sessionTimeoutMs: 3000,
    l2capPsm: 0x80,
  });
  const old = hello.decode(full.subarray(0, full.length - 6));
  assert.equal(old.maxFrame, 512);
  assert.equal(old.sessionTimeoutMs, 10_000);
  assert.equal(old.l2capPsm, 0);
});

test('field widths match the spec tables', () => {
  assert.equal(
    Session.hello.request!.encode({}).length,
    1 + 1 + 2 + 4 + 16 + 16,
  );
  assert.equal(
    Session.hello.response!.encode({}).length,
    2 + 2 + 4 + 32 + 1 + 4 + 4 + 1 + 1 + 4 + 4 + 4 + 2,
  );
  assert.equal(Messages.display.layerSet.request!.encode({}).length, 4 + 2 * 8);
  assert.equal(Messages.display.blit.request!.encode({}).length, 2 + 2 * 7);
  assert.equal(
    Messages.resource.putBegin.request!.encode({}).length,
    2 + 3 + 4 + 16,
  );
  assert.equal(
    Messages.system.info.response!.encode({}).length,
    16 * 3 + 4 + 8,
  );
  assert.equal(Messages.update.begin.request!.encode({}).length, 4 + 32 + 16);
  assert.equal(
    toHex(
      Messages.audio.tone.request!.encode({
        steps: [{ freqHz: 0x1234, durationMs: 100, duty: 50 }],
      }),
    ),
    '01' + '3412' + '6400' + '32',
  );
});

test('str16 rejects strings over 16 bytes', () => {
  assert.throws(
    () => Session.hello.request!.encode({ appId: 'seventeen bytes!!' }),
    RangeError,
  );
});

test('message header', () => {
  const body = encodeBody(
    { op: 4, mflags: 1, req: 0x0201 },
    Uint8Array.from([9]),
  );
  assert.equal(toHex(body), '0401010209');
  assert.deepEqual(decodeBody(body), {
    op: 4,
    mflags: 1,
    req: 0x0201,
    payload: Uint8Array.from([9]),
  });
  assert.equal(decodeBody(new Uint8Array(3)), undefined);
  assert.deepEqual(
    ErrorPayload.decode(ErrorPayload.encode({ code: 6, message: 'hash' })),
    { code: 6, message: 'hash' },
  );
  assert.equal(findMessage(2, 8)?.name, 'COMMIT');
  assert.equal(findMessage(9, 9), undefined);
});

test('sensor samples', () => {
  const b = Uint8Array.from([
    0x01, 0x00, 0xff, 0xff, 0x10, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00,
  ]);
  assert.deepEqual(decodeSamples('accelerometer', b), [
    { x: 1, y: -1, z: 16 },
    { x: 2, y: 3, z: 4 },
  ]);
  assert.deepEqual(
    decodeSamples('battery', Uint8Array.from([80, 0x10, 0x0f, 1])),
    [{ soc: 80, mv: 0x0f10, charging: true }],
  );
});
