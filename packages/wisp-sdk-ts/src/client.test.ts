import assert from 'node:assert/strict';
import { test } from 'node:test';
import { WispGlasses } from './client.ts';
import { decodePixels } from './image/codec.ts';
import { packRaw4, toRaw4 } from './image/raw4.ts';
import { ByteWriter } from './protocol/bytes.ts';
import { Cap, Codec, ResourceType } from './protocol/constants.ts';
import {
  Display,
  Input,
  Sensor,
  Service,
  System,
} from './protocol/messages.ts';
import { FakeGlasses } from './testing/fake-glasses.ts';
import { createLoopbackPair } from './transports/loopback.ts';

async function setup(tweak?: (g: FakeGlasses) => void) {
  const [a, b] = createLoopbackPair();
  const fake = new FakeGlasses(b);
  tweak?.(fake);
  const glasses = await WispGlasses.connect(a, {
    appId: 'com.example',
    clientName: 'test',
  });
  return { glasses, fake };
}

test('connect: HELLO, typed capabilities', async () => {
  const { glasses, fake } = await setup();
  const hello = fake.named('HELLO')[0]!.fields;
  assert.equal(hello.appId, 'com.example');
  assert.equal(hello.protoMajor, 0);
  const caps = glasses.capabilities;
  assert.deepEqual(caps.canvas, { width: 640, height: 480, bpp: 4 });
  assert.equal(caps.has('lz4'), true);
  assert.equal(caps.has(('mic' + 'Pcm') as 'micPcm'), false);
  assert.deepEqual(caps.codecs, [
    Codec.raw4,
    Codec.rle4,
    Codec.lz4,
    Codec.lz4Rle,
  ]);
  assert.equal((await glasses.system.info()).serial, 'F00');
  await glasses.close();
  assert.equal(fake.named('BYE').length, 1);
});

test('layers and drawing reach the glasses as the spec says', async () => {
  const { glasses, fake } = await setup();
  const bg = glasses.layers.create({ w: 640, h: 480 });
  const hud = glasses.layers.create({
    x: 10,
    y: 20,
    w: 200,
    h: 50,
    blend: 'max',
    alpha: 8,
  });
  assert.deepEqual([bg.id, hud.id], [0, 1]);
  bg.fill(0);
  hud
    .fill(15, { x: 1, y: 2, w: 3, h: 4 })
    .text('hi 🙂', { font: 7, x: 2, maxW: 100 });
  hud.move(30, 40);
  hud.tween('alpha', 0, { durationMs: 300, easing: 'out' });
  const done = await glasses.commit();
  assert.equal(done?.frame, 1);

  const sets = fake.named('LAYER_SET').map((r) => r.fields);
  assert.deepEqual(sets[1], {
    layer: 1,
    z: 1,
    flags: 1 | (1 << 1),
    alpha: 8,
    x: 10,
    y: 20,
    w: 200,
    h: 50,
    contentW: 0,
    contentH: 0,
    scrollX: 0,
    scrollY: 0,
  });
  assert.equal(sets[2]!.x, 30);
  assert.deepEqual(
    fake.named('FILL').map((r) => r.fields),
    [
      { layer: 0, value: 0, x: 0, y: 0, w: 640, h: 480 },
      { layer: 1, value: 15, x: 1, y: 2, w: 3, h: 4 },
    ],
  );
  assert.deepEqual(fake.named('TEXT')[0]!.fields, {
    layer: 1,
    value: 15,
    x: 2,
    y: 0,
    font: 7,
    maxW: 100,
    lineH: 0,
    text: 'hi 🙂',
  });
  assert.deepEqual(fake.named('TWEEN')[0]!.fields, {
    layer: 1,
    prop: 2,
    easing: 2,
    to: 0,
    durationMs: 300,
  });
  assert.throws(() => glasses.layers.create({ id: 8, w: 1, h: 1 }), RangeError);
  await glasses.close();
});

test('inline images: smallest supported codec, split into frame-sized strips', async () => {
  const { glasses, fake } = await setup((f) => (f.caps = 1 << Cap.display)); // RAW4 only
  const noise = toRaw4({
    width: 640,
    height: 100,
    data: Array.from({ length: 64000 }, (_, i) => (i * 2654435761) >>> 24),
  });
  glasses.layers.create({ w: 640, h: 480 }).image(noise, { y: 5 });
  await glasses.commit();
  const strips = fake.named('IMAGE').map((r) => r.fields);
  assert.ok(strips.length > 1);
  const rows = new Uint8Array(noise.data.length);
  let o = 0;
  for (const s of strips) {
    assert.equal(s.codec, Codec.raw4);
    const px = decodePixels(
      s.data as Uint8Array,
      s.codec as number,
      s.w as number,
      s.h as number,
    );
    rows.set(px.data, o);
    o += px.data.length;
  }
  assert.deepEqual(rows, noise.data);
  assert.equal(strips[0]!.y, 5);
  await glasses.close();
});

test('resources.put uploads once, then skips by hash', async () => {
  const { glasses, fake } = await setup();
  const img = packRaw4(
    300,
    40,
    Array.from({ length: 12000 }, (_, i) => (i >> 5) & 15),
  );
  const first = await glasses.resources.put(img, { id: 42, persist: true });
  assert.equal(first.uploaded, true);
  assert.equal(first.type, ResourceType.image);
  const begin = fake.named('PUT_BEGIN')[0]!.fields;
  assert.equal(begin.flags, 1);
  const stored = fake.resources.get(42)!.data;
  assert.equal(stored.length, first.size);
  const codec = stored[5]!;
  assert.deepEqual(decodePixels(stored.subarray(6), codec, 300, 40), img);

  const again = await glasses.resources.put(img, { id: 42, persist: true });
  assert.equal(again.uploaded, false);
  assert.equal(fake.named('PUT_END').length, 1);

  const blob = await glasses.resources.put({
    type: 'blob',
    data: new Uint8Array(20000).fill(3),
  });
  assert.equal(blob.id, 1);
  assert.equal(fake.resources.get(1)!.data.length, 20000);
  // Large uploads switch the link profile to bulk and back.
  assert.deepEqual(
    fake.named('LINK_PROFILE').map((r) => r.fields.profile),
    [2, 1],
  );

  glasses.layers
    .create({ w: 640, h: 480 })
    .blit(first, { x: 3, transparent: true });
  await glasses.commit();
  assert.deepEqual(fake.named('BLIT')[0]!.fields, {
    layer: 0,
    flags: 1,
    x: 3,
    y: 0,
    res: 42,
    srcX: 0,
    srcY: 0,
    w: 0,
    h: 0,
  });
  await glasses.close();
});

test('input, sensor, log and animation events are typed', async () => {
  const { glasses, fake } = await setup();
  await glasses.input.configure({ gestures: true });
  assert.equal(fake.named('CONFIG')[0]!.fields.mask, 2);
  const unsub = await glasses.sensors.subscribe('accelerometer', {
    rateHz: 50,
    batchMs: 100,
  });

  const seen: string[] = [];
  glasses.input.on('gesture', (e) => seen.push(`gesture:${e.kind}:${e.lens}`));
  glasses.sensors.on('accelerometer', (b) =>
    seen.push(`acc:${b.samples.map((s) => s.z).join(',')}:${b.dtUs}`),
  );
  glasses.system.on('log', (l) => seen.push(`log:${l.text}`));
  glasses.on('animationDone', (e) => seen.push(`anim:${e.slot}`));

  const ev = fake.link;
  ev.emitEvent(
    Service.input,
    Input.gesture.op,
    Input.gesture.event!.encode({ lens: 2, kind: 5, tUs: 1 }),
  );
  const samples = new ByteWriter()
    .i16(0)
    .i16(0)
    .i16(1000)
    .i16(0)
    .i16(0)
    .i16(-1000)
    .finish();
  ev.emitEvent(
    Service.sensor,
    Sensor.data.op,
    Sensor.data.event!.encode({
      sensor: 1,
      count: 2,
      t0Us: 0,
      dtUs: 20000,
      samples,
    }),
  );
  ev.emitEvent(
    Service.system,
    System.log.op,
    System.log.event!.encode({ level: 3, tUs: 5, text: 'boot' }),
  );
  ev.emitEvent(
    Service.display,
    Display.animPlay.op,
    Display.animPlay.event!.encode({ slot: 4 }),
  );
  await glasses.system.stats(); // round trip: everything before it has arrived
  assert.deepEqual(seen, [
    'gesture:swipeForward:2',
    'acc:1000,-1000:20000',
    'log:boot',
    'anim:4',
  ]);

  await unsub();
  assert.equal(fake.named('UNSUBSCRIBE')[0]!.fields.sensor, 1);
  await glasses.close();
});

test('syncClock estimates the glasses clock', async () => {
  const { glasses } = await setup();
  const clock = await glasses.syncClock(3);
  const est = clock.toGlassUs(Date.now());
  assert.ok(Math.abs(est - (Date.now() * 1000 + 5e9)) < 50_000);
  await glasses.close();
});

test('connect fails cleanly on a protocol major mismatch', async () => {
  const [a, b] = createLoopbackPair();
  const fake = new FakeGlasses(b);
  fake.override = (m) => {
    if (m.svc !== 0 || m.op !== 1) return false;
    fake.link.respond(m, new Uint8Array([9, 0]));
    return true;
  };
  await assert.rejects(WispGlasses.connect(a, { appId: 'x' }), /protocol 9/);
});
