// Golden vectors from packages/wisp-proto/vectors (generated from the C core).
// Field names there are the spec's snake_case; ours are camelCase.
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { test } from 'node:test';
import { decodePixels, encodePixels } from './image/codec.ts';
import { FrameReceiver } from './link/receiver.ts';
import { fromHex, toHex } from './protocol/bytes.ts';
import { crc16 } from './protocol/crc.ts';
import { FrameDecoder, encodeFrame } from './protocol/frame.ts';
import {
  decodeBody,
  encodeBody,
  findMessage,
  payloadStruct,
} from './protocol/messages.ts';
import type { CodecId } from './protocol/constants.ts';
import type { FieldType, Fields } from './protocol/struct.ts';

const DIR =
  process.env.WISP_VECTORS ?? resolve(process.cwd(), '../wisp-proto/vectors');

/** Spec names without a name of their own (`utf8…`) get one in the SDK. */
const ALIASES: Record<string, string> = { utf8: 'text' };
const camel = (s: string) =>
  ALIASES[s] ?? s.replace(/_([a-z0-9])/g, (_, c: string) => c.toUpperCase());
const snake = (s: string) =>
  Object.entries(ALIASES).find(([, v]) => v === s)?.[0] ??
  s.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);

const isBytes = (t: FieldType) =>
  t === 'hash16' || t === 'sha256' || t === 'bytes';

function toSdk(
  fields: Fields,
  json: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(json)) {
    const name = camel(k);
    const t = fields[name];
    if (t === undefined) throw new Error(`unknown field ${k}`);
    if (typeof t !== 'string')
      out[name] = (v as Record<string, unknown>[]).map((i) => toSdk(t.item, i));
    else out[name] = isBytes(t) ? fromHex(v as string) : v;
  }
  return out;
}

function toJson(
  fields: Fields,
  sdk: Record<string, unknown>,
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [name, t] of Object.entries(fields)) {
    const v = sdk[name];
    if (typeof t !== 'string')
      out[snake(name)] = (v as Record<string, unknown>[]).map((i) =>
        toJson(t.item, i),
      );
    else out[snake(name)] = isBytes(t) ? toHex(v as Uint8Array) : v;
  }
  return out;
}

interface Case {
  name: string;
  kind: string;
  hex?: string;
  decode_only?: boolean;
  [k: string]: unknown;
}

const files = existsSync(DIR)
  ? readdirSync(DIR)
      .filter((f) => f.endsWith('.json'))
      .sort()
  : [];

if (!files.length)
  test('golden vectors', (t) => t.skip(`no vectors in ${DIR} yet`));

for (const file of files) {
  const cases = JSON.parse(readFileSync(join(DIR, file), 'utf8')) as Case[];
  for (const c of cases)
    test(`${file}: ${c.name}`, (t) => check(c, t.skip.bind(t)));
}

function check(c: Case, skip: (why: string) => void) {
  switch (c.kind) {
    case 'crc': {
      if (c.algo !== 'crc16-ccitt-false')
        return skip(`${c.algo} is not used by the SDK`);
      const v = crc16(fromHex(c.input_hex as string));
      return assert.equal(toHex(Uint8Array.of(v & 255, v >> 8)), c.hex);
    }
    case 'frame': {
      const body = fromHex(c.body_hex as string);
      const f = {
        svc: c.svc as number,
        route: c.route as number,
        seq: c.seq as number,
        body,
      };
      assert.equal(toHex(encodeFrame(f)), c.hex);
      return assert.deepEqual(new FrameDecoder().push(fromHex(c.hex!)), [
        { ...f, fflags: 0 },
      ]);
    }
    case 'stream': {
      const rx = new FrameReceiver(4096);
      const frames: string[] = [];
      const resyncs: number[] = [];
      for (const chunk of c.chunks as string[])
        for (const e of rx.push(fromHex(chunk))) {
          if (e.kind === 'frame') frames.push(toHex(encodeFrame(e.frame)));
          if (e.kind === 'resync') resyncs.push(e.lastGoodSeq);
        }
      assert.deepEqual(frames, c.frames, 'frames');
      return assert.deepEqual(resyncs, c.resyncs, 'resyncs');
    }
    case 'codec': {
      const w = c.w as number;
      const h = c.h as number;
      const pixels = {
        width: w,
        height: h,
        data: fromHex(c.pixels_hex as string),
      };
      const codec = c.codec as CodecId;
      assert.equal(
        toHex(decodePixels(fromHex(c.hex!), codec, w, h).data),
        c.pixels_hex,
        'decode',
      );
      const own = encodePixels(pixels, codec);
      if (!c.decode_only) assert.equal(toHex(own), c.hex, 'encode');
      return assert.equal(
        toHex(decodePixels(own, codec, w, h).data),
        c.pixels_hex,
        'own round trip',
      );
    }
    case 'message': {
      const s = payloadStruct(
        findMessage(c.svc as number, c.op as number),
        c.mflags as number,
      );
      assert.ok(s, `no layout for ${c.svc}/${c.op} with mflags ${c.mflags}`);
      const header = {
        op: c.op as number,
        mflags: c.mflags as number,
        req: c.req as number,
      };
      const fields = c.fields as Record<string, unknown>;

      const body = decodeBody(fromHex(c.hex!));
      assert.ok(body);
      assert.deepEqual(
        { op: body.op, mflags: body.mflags, req: body.req },
        header,
      );
      const decoded = s.decode(body.payload);
      assert.deepEqual(toJson(s.fields, decoded), fields, 'decode');
      if (!c.decode_only)
        assert.equal(
          toHex(encodeBody(header, s.encode(toSdk(s.fields, fields) as never))),
          c.hex,
          'encode',
        );
      else
        assert.deepEqual(
          s.decode(s.encode(decoded)),
          decoded,
          'own round trip',
        );
      return;
    }
    default:
      return skip(`unknown kind ${c.kind}`);
  }
}
