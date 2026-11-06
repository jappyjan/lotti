// Wisp simulator viewer: draws both lenses from RAW4 updates and sends input back.
'use strict';

const LENS_W = 640;
const LENS_H = 480;
// The G2's 4-bit green microLED: level 0 is off.
const PALETTE = Array.from({ length: 16 }, (_, v) => [
  Math.round(v * 5.5),
  Math.round(v * 17),
  Math.round(v * 7),
]);

const lenses = {};
for (const el of document.querySelectorAll('.lens')) {
  const lens = Number(el.dataset.lens);
  const canvas = el.querySelector('canvas');
  const ctx = canvas.getContext('2d');
  const image = ctx.createImageData(LENS_W, LENS_H);
  for (let i = 3; i < image.data.length; i += 4) image.data[i] = 255;
  ctx.putImageData(image, 0, 0);
  lenses[lens] = {
    el,
    canvas,
    ctx,
    image,
    panel: el.querySelector('.panel'),
    overlay: el.querySelector('.overlay'),
    stats: el.querySelector('.stats'),
    tag: el.querySelector('.tag'),
  };
}

let ws;
let worn = true;
let target = 2;
const conn = document.getElementById('conn');

function connect() {
  ws = new WebSocket(
    `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/viewer`,
  );
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    conn.textContent = 'connected';
    conn.className = 'pill ok';
  };
  ws.onclose = () => {
    conn.textContent = 'disconnected';
    conn.className = 'pill bad';
    setTimeout(connect, 1000);
  };
  ws.onmessage = (ev) =>
    typeof ev.data === 'string'
      ? onStats(JSON.parse(ev.data))
      : onFrame(new Uint8Array(ev.data));
}

function onFrame(m) {
  if (m[0] !== 1) return;
  const v = new DataView(m.buffer, m.byteOffset);
  const l = lenses[m[1]];
  const x0 = v.getUint16(2, true),
    y0 = v.getUint16(4, true),
    w = v.getUint16(6, true),
    h = v.getUint16(8, true);
  l.panel.classList.toggle('off', m[10] === 0);
  l.overlay.textContent = m[10] === 0 ? 'display off' : '';
  const px = m.subarray(11),
    d = l.image.data,
    bw = w >> 1;
  for (let y = 0; y < h; y++)
    for (let i = 0; i < bw; i++) {
      const b = px[y * bw + i];
      let o = ((y0 + y) * LENS_W + x0 + 2 * i) * 4;
      const a = PALETTE[b >> 4],
        c = PALETTE[b & 15];
      d[o] = a[0];
      d[o + 1] = a[1];
      d[o + 2] = a[2];
      d[o + 4] = c[0];
      d[o + 5] = c[1];
      d[o + 6] = c[2];
    }
  l.ctx.putImageData(l.image, 0, 0, x0, y0, w, h);
}

const kb = (n) =>
  n >= 1 << 20
    ? `${(n / (1 << 20)).toFixed(1)} MiB`
    : `${(n / 1024).toFixed(1)} KiB`;
function onStats(s) {
  document.getElementById('links').textContent =
    `${s.links} link${s.links === 1 ? '' : 's'} · ${s.viewers} viewer${s.viewers === 1 ? '' : 's'} · persisted ${kb(s.persistBytes)}`;
  worn = s.worn;
  wearButton.textContent = worn ? 'Worn' : 'Not worn';
  wearButton.classList.toggle('off', !worn);
  for (const [lens, st] of Object.entries(s.lenses)) {
    const l = lenses[lens];
    l.tag.textContent = st.session
      ? `${st.appId || '(no app id)'}${st.follower ? ' · mirrored' : ''}`
      : 'no session';
    const rows = [
      ['frames', st.frame],
      ['fps', st.fps.toFixed(1)],
      ['layers', st.layers],
      ['animations', st.animations],
      ['tweens', st.tweens],
      ['resources', `${st.resources} · ${kb(st.resourceBytes)}`],
      ['res free', kb(st.resFree)],
      ['gfx free', kb(st.gfxFree)],
      ['messages', st.messages],
      ['errors', st.errors],
      ['rx', kb(st.rxBytes)],
      ['tx', kb(st.txBytes)],
      ['resyncs', `${st.resyncs} / ${st.resends}`],
      ['composed', `${(st.kpxComposed / 1000).toFixed(1)} Mpx`],
      ['input', ['off', 'raw', 'gestures', 'raw+gest.'][st.inputMask]],
      ['display', st.displayOn ? 'on' : 'off'],
    ];
    l.stats.innerHTML = rows
      .map(([k, v]) => `<div><dt>${k}</dt><dd>${v}</dd></div>`)
      .join('');
  }
}

const send = (m) => ws && ws.readyState === 1 && ws.send(JSON.stringify(m));
const gesture = (kind, lens = target) => send({ type: 'gesture', lens, kind });

// Pointer on a lens = finger on that temple; x gives the position along it.
for (const [lens, l] of Object.entries(lenses)) {
  const pos = (ev) => {
    const r = l.canvas.getBoundingClientRect();
    return Math.max(
      0,
      Math.min(
        LENS_W - 1,
        Math.round(((ev.clientX - r.left) / r.width) * LENS_W),
      ),
    );
  };
  l.canvas.addEventListener('pointerdown', (ev) => {
    l.canvas.setPointerCapture(ev.pointerId);
    send({ type: 'touch', lens: Number(lens), phase: 0, pos: pos(ev) });
  });
  l.canvas.addEventListener('pointermove', (ev) => {
    if (ev.buttons)
      send({ type: 'touch', lens: Number(lens), phase: 1, pos: pos(ev) });
  });
  l.canvas.addEventListener('pointerup', (ev) =>
    send({ type: 'touch', lens: Number(lens), phase: 2, pos: pos(ev) }),
  );
}

const targetSelect = document.getElementById('target');
targetSelect.addEventListener(
  'change',
  () => (target = Number(targetSelect.value)),
);
const wearButton = document.getElementById('wear');
wearButton.addEventListener('click', () => send({ type: 'wear', worn: !worn }));
for (const b of document.querySelectorAll('[data-gesture]')) {
  const g = b.dataset.gesture;
  if (g === 'long') {
    b.addEventListener('pointerdown', () => gesture(3));
    b.addEventListener('pointerup', () => gesture(4));
  } else b.addEventListener('click', () => gesture(Number(g)));
}

let longDown = false;
addEventListener('keydown', (ev) => {
  if (
    ev.target instanceof HTMLSelectElement ||
    (ev.repeat && ev.key.toLowerCase() !== 'l')
  )
    return;
  const k = ev.key.toLowerCase();
  if (k === ' ') gesture(1);
  else if (k === 'd') gesture(2);
  else if (k === 'l' && !longDown) {
    longDown = true;
    gesture(3);
  } else if (k === 'arrowleft') gesture(6);
  else if (k === 'arrowright') gesture(5);
  else if (k === 'w') send({ type: 'wear', worn: !worn });
  else if (k === '1' || k === '2') {
    target = Number(k);
    targetSelect.value = k;
  } else return;
  ev.preventDefault();
});
addEventListener('keyup', (ev) => {
  if (ev.key.toLowerCase() === 'l' && longDown) {
    longDown = false;
    gesture(4);
  }
});

connect();
