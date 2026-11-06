/**
 * Wisp SDK example: connects to the simulator (or any Wisp glasses over a
 * WebSocket), uploads a font, an image and an animation, shows text, plays
 * the animation, slides a panel in with a tween, and reacts to taps and
 * swipes.
 *
 *   pnpm nx run wisp-sim:serve          # in one terminal, open http://127.0.0.1:8360/
 *   node apps/wisp-sim/dist/examples/hello.js [ws://127.0.0.1:8360/link]
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  Emitter,
  WebSocketTransport,
  WispGlasses,
  fontResource,
  packRaw4,
  parseBdf,
  type GestureEvent,
  type Image4,
  type Layer,
} from '@wisp/sdk';

/** Spleen 12×24 (BSD-2-Clause, see examples/fonts/LICENSE.spleen), baked to a Wisp font at startup. */
const FONT = new URL('../../examples/fonts/spleen-12x24.bdf', import.meta.url);

export const LAYOUT = {
  image: { x: 40, y: 150, w: 160, h: 120 },
  spinner: { x: 536, y: 40, w: 64, h: 64 },
  counter: { x: 240, y: 170, w: 360, h: 48 },
  panel: { x: 170, y: 380, w: 300, h: 56, from: -320 },
} as const;

/** A "moon": a lit disc with soft edge, craters and a ring. Greyscale 0–15 per pixel. */
export function moonImage(): Image4 {
  const { w, h } = LAYOUT.image;
  const levels = new Uint8Array(w * h);
  const cx = w / 2,
    cy = h / 2,
    r = 46;
  const craters = [
    [-14, -10, 9],
    [16, 6, 7],
    [-4, 20, 5],
    [20, -18, 4],
  ] as const;
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const dx = x - cx,
        dy = y - cy,
        d = Math.hypot(dx, dy);
      let v = 0;
      if (d < r) {
        v = 13 - Math.round((d / r) * 5) + Math.round((-dx - dy) / 30);
        for (const [ox, oy, cr] of craters)
          if (Math.hypot(dx - ox, dy - oy) < cr) v -= 4;
      }
      const ring = Math.abs(Math.hypot(dx, dy * 3.2) - 72);
      if (ring < 2.2 && (dy > 0 || d > r))
        v = Math.max(v, 9 - Math.round(ring * 3));
      levels[y * w + x] = Math.max(0, Math.min(15, v));
    }
  return packRaw4(w, h, levels);
}

/** A 12-frame spinner: twelve dots, one bright, a fading tail. */
export function spinnerFrames(
  count = 12,
): { image: Image4; durationMs: number }[] {
  const { w, h } = LAYOUT.spinner;
  return Array.from({ length: count }, (_, f) => {
    const levels = new Uint8Array(w * h);
    for (let k = 0; k < count; k++) {
      const a = (k / count) * 2 * Math.PI;
      const px = w / 2 + Math.sin(a) * 24,
        py = h / 2 - Math.cos(a) * 24;
      const age = (f - k + count) % count;
      const v = Math.max(2, 15 - age * 3);
      for (let y = 0; y < h; y++)
        for (let x = 0; x < w; x++)
          if (Math.hypot(x - px, y - py) < 4.2) levels[y * w + x] = v;
    }
    return { image: packRaw4(w, h, levels), durationMs: 70 };
  });
}

export interface Hello extends Emitter<{
  drawn: { taps: number };
  gesture: GestureEvent;
}> {
  readonly glasses: WispGlasses;
  readonly taps: number;
  close(): Promise<void>;
}

export async function startHello(
  url: string,
  opts: { log?: (line: string) => void } = {},
): Promise<Hello> {
  const log = opts.log ?? (() => {});
  const transport = await WebSocketTransport.connect(url);
  const g = await WispGlasses.connect(transport, {
    appId: 'dev.wisp.hello',
    clientName: 'hello example',
  });
  const caps = g.capabilities;
  log(
    `connected: ${caps.firmware.name} ${caps.firmware.version}, ${caps.canvas.width}×${caps.canvas.height}, ` +
      `${caps.maxLayers} layers, ${caps.resourceBytes >> 10} KiB for resources`,
  );

  // Assets: fonts, images and animations are the app's own; persisted ones skip the upload next time.
  const font = await g.resources.put(
    { type: 'font', data: fontResource(parseBdf(readFileSync(FONT, 'utf8'))) },
    { id: 1, persist: caps.has('persist') },
  );
  const moon = await g.resources.put(moonImage(), { id: 2 });
  const spinner = await g.resources.put(
    { type: 'animation', frames: spinnerFrames() },
    { id: 3 },
  );
  log(
    `resources: font ${font.size} B${font.uploaded ? '' : ' (already there)'}, ` +
      `image ${moon.size} B, animation ${spinner.size} B`,
  );

  const { width, height } = caps.canvas;
  const bg = g.layers.create({ id: 0, z: 0, w: width, h: height });
  bg.fill(0)
    .fill(3, { x: 16, y: 16, w: width - 32, h: 2 })
    .fill(3, { x: 16, y: height - 18, w: width - 32, h: 2 })
    .text('Wisp', { font, x: 32, y: 32, value: 15 })
    .text('simulator · SDK example', { font, x: 32, y: 60, value: 7 });

  const L = LAYOUT;
  const image = g.layers.create({ id: 1, z: 1, ...L.image });
  image.blit(moon);

  const spin = g.layers.create({ id: 2, z: 2, ...L.spinner });

  const counter = g.layers.create({ id: 3, z: 3, ...L.counter });
  let taps = 0;
  const drawCounter = (c: Layer) =>
    c
      .fill(0)
      .text(`taps: ${taps}`, { font, x: 0, y: 0, value: 15 })
      .text('double tap resets', { font, x: 0, y: 24, value: 5 });
  drawCounter(counter);

  const panel = g.layers.create({
    id: 4,
    z: 4,
    x: L.panel.from,
    y: L.panel.y,
    w: L.panel.w,
    h: L.panel.h,
  });
  panel
    .fill(2)
    .fill(9, { x: 0, y: 0, w: L.panel.w, h: 2 })
    .text('swipe me  «  »', { font, x: 18, y: 16, value: 15 });

  await g.commit();
  spin.play(spinner, { slot: 0, loops: 0 }); // runs on the glasses, commits by itself
  panel.tween('x', L.panel.x, { durationMs: 600, easing: 'out' });

  const events = new Emitter<{
    drawn: { taps: number };
    gesture: GestureEvent;
  }>();
  await g.input.configure({ gestures: true });
  let panelX: number = L.panel.x;
  g.input.on('gesture', (e) => {
    events.emit('gesture', e);
    log(`gesture ${e.kind} on lens ${e.lens}`);
    if (e.kind === 'tap' || e.kind === 'doubleTap') {
      taps = e.kind === 'tap' ? taps + 1 : 0;
      drawCounter(counter);
      void g.commit().then(() => events.emit('drawn', { taps }));
    } else if (e.kind === 'swipeForward' || e.kind === 'swipeBack') {
      panelX = Math.max(
        16,
        Math.min(
          width - L.panel.w - 16,
          panelX + (e.kind === 'swipeForward' ? 120 : -120),
        ),
      );
      panel.tween('x', panelX, { durationMs: 300, easing: 'inOut' });
    }
  });

  return Object.assign(events, {
    glasses: g,
    get taps() {
      return taps;
    },
    close: () => g.close(),
  }) as Hello;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const url = process.argv[2] ?? 'ws://127.0.0.1:8360/link';
  const hello = await startHello(url, { log: (l) => console.log(l) });
  console.log('running; tap or swipe in the viewer, Ctrl-C to quit');
  process.on('SIGINT', () => void hello.close().then(() => process.exit(0)));
}
