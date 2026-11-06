import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { createHash } from 'node:crypto';
import { WebSocketTransport, WispGlasses, getPixel4 } from '@wisp/sdk';
import { startSim, type Sim } from '../src/server.ts';
import {
  LAYOUT,
  moonImage,
  startHello,
  type Hello,
} from '../examples/hello.ts';

const W = 640;
const px = (fb: Uint8Array, x: number, y: number) => {
  const b = fb[y * (W / 2) + (x >> 1)]!;
  return x & 1 ? b & 15 : b >> 4;
};
const region = (
  fb: Uint8Array,
  r: { x: number; y: number; w: number; h: number },
) => {
  const out: number[] = [];
  for (let y = r.y; y < r.y + r.h; y++)
    for (let x = r.x; x < r.x + r.w; x++) out.push(px(fb, x, y));
  return out;
};
const lit = (
  fb: Uint8Array,
  r: { x: number; y: number; w: number; h: number },
) => region(fb, r).filter((v) => v > 0).length;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const until = async (cond: () => boolean, ms = 3000) => {
  const end = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > end) throw new Error('timed out waiting');
    await sleep(10);
  }
};

let sim: Sim;
before(async () => {
  sim = await startSim({ port: 0 });
});
after(async () => {
  await sim.close();
});

test('the hello example runs headless against the sim and the composed frame shows it', async () => {
  const hello: Hello = await startHello(sim.linkUrl);
  try {
    const core = sim.core;
    // the tween slides the panel in over 600 ms; then the frame is stable except for the spinner
    await sleep(800);
    const fb = core.frame(2);

    // the image layer is opaque RAW4: the panel shows exactly the uploaded pixels
    const moon = moonImage();
    const want: number[] = [];
    for (let y = 0; y < moon.height; y++)
      for (let x = 0; x < moon.width; x++) want.push(getPixel4(moon, x, y));
    assert.deepEqual(region(fb, LAYOUT.image), want);

    // text from the baked font: the title and the counter are lit
    assert.ok(lit(fb, { x: 32, y: 32, w: 60, h: 24 }) > 100, 'title drawn');
    const counterBefore = region(fb, LAYOUT.counter);
    assert.ok(
      counterBefore.some((v) => v === 15),
      'counter drawn',
    );

    // the tween ended where the example wanted the panel: its top edge (level 9) is there, not at the start
    const p = LAYOUT.panel;
    assert.equal(px(fb, p.x + 5, p.y), 9);
    assert.equal(px(fb, p.x + p.w - 1, p.y), 9);
    assert.equal(px(fb, p.x - 1, p.y), 0);

    // the animation plays on its own: the spinner region changes without any message from the phone
    const s1 = region(core.frame(2), LAYOUT.spinner);
    await sleep(160);
    const s2 = region(core.frame(2), LAYOUT.spinner);
    assert.ok(
      s1.some((v) => v > 0) && s1.join() !== s2.join(),
      'spinner animates',
    );

    // the right temple is mirrored to the left lens
    const hash = (b: Uint8Array) =>
      createHash('sha256').update(b).digest('hex');
    await sleep(20);
    assert.equal(
      hash(Buffer.from(region(core.frame(1), LAYOUT.counter))),
      hash(Buffer.from(region(core.frame(2), LAYOUT.counter))),
    );

    // a simulated tap (raw touch through the glasses' gesture recognizer) updates the counter
    const drawn = new Promise<{ taps: number }>((resolve) =>
      hello.on('drawn', resolve),
    );
    core.touch(2, 0, 300);
    await sleep(40);
    core.touch(2, 2, 302);
    assert.equal((await drawn).taps, 1);
    const counterAfter = region(core.frame(2), LAYOUT.counter);
    assert.notEqual(counterAfter.join(), counterBefore.join());

    // a swipe moves the panel by 120 px with a tween
    core.touch(2, 0, 100);
    core.touch(2, 1, 200);
    core.touch(2, 2, 300);
    await until(
      () =>
        core.stats(2).tweens === 0 &&
        px(core.frame(2), p.x + p.w + 110, p.y) === 9,
    );
    assert.equal(px(core.frame(2), p.x + 119, p.y), 0);
    assert.equal(px(core.frame(2), p.x + 120, p.y), 9);

    const st = core.stats(2);
    assert.equal(st.session, 1);
    assert.equal(st.appId, 'dev.wisp.hello');
    assert.equal(st.layers, 5);
    assert.equal(st.animations, 1);
    assert.equal(st.errors, 0);
    assert.equal(st.resyncs, 0);
    assert.equal(core.stats(1).follower, 1);
  } finally {
    await hello.close();
  }
  // BYE ends the session on both lenses; the persisted font stays in storage
  await until(
    () => sim.core.stats(2).session === 0 && sim.core.stats(1).session === 0,
  );
  assert.equal(sim.core.storage.list('dev.wisp.hello').length, 1);
});

test('a second run skips the persisted font upload', async () => {
  const transport = await WebSocketTransport.connect(sim.linkUrl);
  const g = await WispGlasses.connect(transport, { appId: 'dev.wisp.hello' });
  try {
    const list = await g.resources.list();
    assert.equal(list.length, 1);
    assert.equal(list[0]!.res, 1);
  } finally {
    await g.close();
  }
});

test('HTTP API: stats and raw frames', async () => {
  const stats = (await (await fetch(`${sim.url}api/stats`)).json()) as {
    lenses: Record<string, unknown>;
  };
  assert.ok(stats.lenses['1'] && stats.lenses['2']);
  const frame = new Uint8Array(
    await (await fetch(`${sim.url}api/frame?lens=1`)).arrayBuffer(),
  );
  assert.equal(frame.length, (640 / 2) * 480);
  const page = await (await fetch(sim.url)).text();
  assert.match(page, /Wisp simulator/);
});
