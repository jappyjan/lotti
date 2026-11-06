import { Emitter } from './events.ts';
import { ClockEstimator } from './link/clock.ts';
import { WispLink, type Incoming, type LinkOptions } from './link/link.ts';
import type { Transport } from './link/transport.ts';
import {
  animationResource,
  encodeSmallest,
  imageResource,
  type AnimationFrame,
} from './image/codec.ts';
import { resourceHash, type Sha256 } from './image/hash.ts';
import { stride4, type Image4 } from './image/raw4.ts';
import {
  Blend,
  Cap,
  Codec,
  Easing,
  GestureKind,
  LayerFlag,
  LinkProfile,
  MicCodec,
  PutStatus,
  ResourceType,
  SensorId,
  TouchPhase,
  TweenProp,
  decodeSamples,
  sensorName,
  type CapName,
  type CodecId,
  type SensorName,
  type SensorSample,
} from './protocol/constants.ts';
import {
  Audio,
  Display,
  Input,
  Resource,
  Sensor,
  Service,
  Session,
  System,
  type ResponseOf,
} from './protocol/messages.ts';
import { PayloadError } from './protocol/struct.ts';

export const PROTOCOL_VERSION = { major: 0, minor: 2 } as const;

type Key<T> = keyof T;
const keyOf = <T extends Record<string, number>>(map: T, v: number) =>
  (Object.keys(map) as Key<T>[]).find((k) => map[k] === v);

export interface Capabilities {
  protocol: { major: number; minor: number };
  firmware: { name: string; version: string };
  /** Lens this connection is to (1 left, 2 right). */
  lens: number;
  /** Raw `caps` bits. */
  bits: number;
  canvas: { width: number; height: number; bpp: number };
  maxLayers: number;
  maxFrame: number;
  resourceBytes: number;
  persistBytes: number;
  sessionTimeoutMs: number;
  l2capPsm: number;
  /** Pixel codecs the glasses decode (RAW4 always). */
  codecs: CodecId[];
  has(cap: CapName): boolean;
}

function toCapabilities(h: ResponseOf<typeof Session.hello>): Capabilities {
  const has = (cap: CapName) => ((h.caps >>> Cap[cap]) & 1) === 1;
  const codecs: CodecId[] = [Codec.raw4];
  if (has('rle4')) codecs.push(Codec.rle4);
  if (has('lz4')) codecs.push(Codec.lz4);
  if (has('rle4') && has('lz4')) codecs.push(Codec.lz4Rle);
  return {
    protocol: { major: h.protoMajor, minor: h.protoMinor },
    firmware: { name: h.fwName, version: h.fwVersion },
    lens: h.lens,
    bits: h.caps,
    canvas: { width: h.canvasW, height: h.canvasH, bpp: h.bpp },
    maxLayers: h.maxLayers,
    maxFrame: h.maxFrame,
    resourceBytes: h.resBytes,
    persistBytes: h.persistBytes,
    sessionTimeoutMs: h.sessionTimeoutMs,
    l2capPsm: h.l2capPsm,
    codecs,
    has,
  };
}

export interface ConnectOptions extends LinkOptions {
  /** Namespaces persisted resources; at most 16 bytes of UTF-8. */
  appId: string;
  clientName?: string;
  /** Send `PING`s to keep the session alive. Default true. */
  keepalive?: boolean;
  /** SHA-256 for resource hashes where WebCrypto is missing. */
  sha256?: Sha256;
}

// ── display ──────────────────────────────────────────────────────────────

export interface LayerProps {
  z: number;
  visible: boolean;
  blend: keyof typeof Blend;
  /** 0–15 */
  alpha: number;
  x: number;
  y: number;
  w: number;
  h: number;
  /** Content buffer size; 0 = same as the view. */
  contentW: number;
  contentH: number;
  scrollX: number;
  scrollY: number;
}

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface TextOptions {
  font: ResourceRef | number;
  x?: number;
  y?: number;
  /** Grey level 0–15. Default 15. */
  value?: number;
  /** Wrap width; 0 = no wrap. */
  maxW?: number;
  /** 0 = the font's line height. */
  lineH?: number;
}

const resId = (r: ResourceRef | number) => (typeof r === 'number' ? r : r.id);

/** A layer: a buffer you draw into, shown at a view rect, composited by `z`. */
export class Layer {
  private props: LayerProps;

  constructor(
    private readonly g: WispGlasses,
    readonly id: number,
    props: Partial<LayerProps> & Pick<LayerProps, 'w' | 'h'>,
  ) {
    this.props = {
      z: id,
      visible: true,
      blend: 'over',
      alpha: 15,
      x: 0,
      y: 0,
      contentW: 0,
      contentH: 0,
      scrollX: 0,
      scrollY: 0,
      ...props,
    };
    this.push();
  }

  get state(): Readonly<LayerProps> {
    return this.props;
  }

  /** Updates properties. Position, alpha and scroll changes need no redraw. */
  set(props: Partial<LayerProps>): this {
    Object.assign(this.props, props);
    return this.push();
  }

  move(x: number, y: number): this {
    return this.set({ x, y });
  }

  scrollTo(scrollX: number, scrollY: number): this {
    return this.set({ scrollX, scrollY });
  }

  fill(value: number, rect?: Partial<Rect>): this {
    const p = this.props;
    this.g.link.notify(Display.fill, {
      layer: this.id,
      value,
      x: rect?.x ?? 0,
      y: rect?.y ?? 0,
      w: rect?.w ?? (p.contentW || p.w),
      h: rect?.h ?? (p.contentH || p.h),
    });
    return this;
  }

  /** Draws (part of) an image resource. */
  blit(
    image: ResourceRef | number,
    opts: { x?: number; y?: number; src?: Rect; transparent?: boolean } = {},
  ): this {
    this.g.link.notify(Display.blit, {
      layer: this.id,
      flags: opts.transparent ? 1 : 0,
      x: opts.x ?? 0,
      y: opts.y ?? 0,
      res: resId(image),
      srcX: opts.src?.x ?? 0,
      srcY: opts.src?.y ?? 0,
      w: opts.src?.w ?? 0,
      h: opts.src?.h ?? 0,
    });
    return this;
  }

  /**
   * Draws pixels inline (not cached), with the smallest codec the glasses
   * support. Images too large for one frame go as horizontal strips.
   */
  image(img: Image4, opts: { x?: number; y?: number } = {}): this {
    const x = opts.x ?? 0;
    const y = opts.y ?? 0;
    const stride = stride4(img.width);
    // Sized so even RAW4 fits; the IMAGE header takes 10 bytes.
    const rows = Math.max(
      1,
      Math.floor((this.g.link.maxPayload - 10) / stride),
    );
    for (let top = 0; top < img.height; top += rows) {
      const strip: Image4 = {
        width: img.width,
        height: Math.min(rows, img.height - top),
        data: img.data.subarray(
          top * stride,
          Math.min(img.height, top + rows) * stride,
        ),
      };
      const enc = encodeSmallest(strip, this.g.capabilities.codecs);
      this.g.link.notify(Display.image, {
        layer: this.id,
        codec: enc.codec,
        x,
        y: y + top,
        w: strip.width,
        h: strip.height,
        data: enc.data,
      });
    }
    return this;
  }

  text(text: string, opts: TextOptions): this {
    this.g.link.notify(Display.text, this.textFields(text, opts));
    return this;
  }

  /** Like `text`, and resolves with the size drawn. */
  textMeasured(text: string, opts: TextOptions) {
    return this.g.link.call(Display.text, this.textFields(text, opts));
  }

  private textFields(text: string, o: TextOptions) {
    return {
      layer: this.id,
      value: o.value ?? 15,
      x: o.x ?? 0,
      y: o.y ?? 0,
      font: resId(o.font),
      maxW: o.maxW ?? 0,
      lineH: o.lineH ?? 0,
      text,
    };
  }

  /** Shifts the content buffer, filling the uncovered part with `fill`. */
  scroll(dx: number, dy: number, fill = 0): this {
    this.g.link.notify(Display.scroll, { layer: this.id, dx, dy, fill });
    return this;
  }

  /** Animates a property on the glasses (no radio traffic per frame). */
  tween(
    prop: keyof typeof TweenProp,
    to: number,
    opts: { durationMs: number; easing?: keyof typeof Easing },
  ): this {
    this.g.link.notify(Display.tween, {
      layer: this.id,
      prop: TweenProp[prop],
      easing: Easing[opts.easing ?? 'inOut'],
      to,
      durationMs: opts.durationMs,
    });
    return this;
  }

  /** Plays an animation resource into this layer; it commits by itself. */
  play(
    animation: ResourceRef | number,
    opts: { slot?: number; x?: number; y?: number; loops?: number } = {},
  ): number {
    const slot = opts.slot ?? 0;
    this.g.link.notify(Display.animPlay, {
      slot,
      layer: this.id,
      x: opts.x ?? 0,
      y: opts.y ?? 0,
      res: resId(animation),
      loops: opts.loops ?? 0,
      flags: 0,
    });
    return slot;
  }

  delete() {
    this.g.link.notify(Display.layerDel, { layer: this.id });
    this.g.layers.forget(this.id);
  }

  private push(): this {
    const p = this.props;
    this.g.link.notify(Display.layerSet, {
      layer: this.id,
      z: p.z,
      flags: (p.visible ? LayerFlag.visible : 0) | (Blend[p.blend] << 1),
      alpha: p.alpha,
      x: p.x,
      y: p.y,
      w: p.w,
      h: p.h,
      contentW: p.contentW,
      contentH: p.contentH,
      scrollX: p.scrollX,
      scrollY: p.scrollY,
    });
    return this;
  }
}

export class Layers {
  private readonly byId = new Map<number, Layer>();

  constructor(private readonly g: WispGlasses) {}

  /** Creates a layer (the lowest free id unless given). Defaults: visible, `z = id`. */
  create(
    props: Partial<LayerProps> & Pick<LayerProps, 'w' | 'h'> & { id?: number },
  ): Layer {
    const { id: wanted, ...rest } = props;
    let id = wanted;
    if (id === undefined) {
      id = 0;
      while (this.byId.has(id)) id++;
    }
    if (id >= this.g.capabilities.maxLayers)
      throw new RangeError(
        `layer ${id} ≥ max_layers ${this.g.capabilities.maxLayers}`,
      );
    const layer = new Layer(this.g, id, rest);
    this.byId.set(id, layer);
    return layer;
  }

  get(id: number): Layer | undefined {
    return this.byId.get(id);
  }

  /** Deletes every layer of this session. */
  clear() {
    this.g.link.notify(Display.clearAll);
    this.byId.clear();
  }

  /** @internal */
  forget(id: number) {
    this.byId.delete(id);
  }
}

// ── resources ────────────────────────────────────────────────────────────

export interface ResourceRef {
  id: number;
  type: number;
  size: number;
  hash: Uint8Array;
  /** False when the glasses already had it and the upload was skipped. */
  uploaded: boolean;
}

export interface PutOptions {
  /** Keep across reboots (needs cap `persist`). Use a fixed `id` for those. */
  persist?: boolean;
  /** Resource id; by default the lowest one this session hasn't used. */
  id?: number;
  /** Image only: force a codec instead of the smallest supported one. */
  codec?: CodecId;
}

export type Resourceable =
  | Image4
  | { type: 'animation'; frames: AnimationFrame[]; codec?: CodecId }
  | { type: 'font' | 'blob'; data: Uint8Array };

export class Resources {
  private readonly used = new Set<number>();

  constructor(
    private readonly g: WispGlasses,
    private readonly sha256?: Sha256,
  ) {}

  /** Uploads a resource, skipping the transfer if the glasses already hold it. */
  async put(item: Resourceable, opts: PutOptions = {}): Promise<ResourceRef> {
    const caps = this.g.capabilities;
    let type: number;
    let payload: Uint8Array;
    if ('width' in item) {
      const enc =
        opts.codec !== undefined
          ? encodeSmallest(item, [opts.codec])
          : encodeSmallest(item, caps.codecs);
      type = ResourceType.image;
      payload = imageResource(item, enc);
    } else if (item.type === 'animation') {
      const codec = item.codec ?? caps.codecs[caps.codecs.length - 1]!;
      type = ResourceType.animation;
      payload = animationResource(item.frames, {
        codec,
        delta: caps.has('deltaFrames'),
      });
    } else {
      type = item.type === 'font' ? ResourceType.font : ResourceType.blob;
      payload = item.data;
    }
    const id = opts.id ?? this.nextId();
    this.used.add(id);
    // size and hash cover the payload as uploaded; the codec lives in its header.
    const hash = await resourceHash(payload, this.sha256);
    const ref = { id, type, size: payload.length, hash };

    const link = this.g.link;
    const begin = await link.call(Resource.putBegin, {
      res: id,
      type,
      flags: opts.persist ? 1 : 0,
      size: payload.length,
      hash,
    });
    if (begin.status === PutStatus.exists) return { ...ref, uploaded: false };
    if (begin.status !== PutStatus.sendData)
      throw new Error(`PUT_BEGIN: unexpected status ${begin.status}`);

    const chunk = link.maxPayload - 6;
    const bulk = payload.length > 4 * chunk;
    if (bulk) await this.g.system.linkProfile('bulk');
    try {
      for (let offset = 0; offset < payload.length; offset += chunk)
        link.notify(Resource.putData, {
          res: id,
          offset,
          data: payload.subarray(offset, offset + chunk),
        });
      await link.call(Resource.putEnd, { res: id }, { timeoutMs: 30_000 });
    } finally {
      if (bulk) await this.g.system.linkProfile('interactive');
    }
    return { ...ref, uploaded: true };
  }

  async delete(res: ResourceRef | number) {
    await this.g.link.call(Resource.delete, { res: resId(res) });
    this.used.delete(resId(res));
  }

  /** Deletes every resource of this app, persisted ones included. */
  async deleteAll() {
    await this.g.link.call(Resource.delete, { res: 0xffff });
    this.used.clear();
  }

  async list() {
    return (await this.g.link.call(Resource.list)).entries;
  }

  private nextId(): number {
    let id = 1;
    while (this.used.has(id)) id++;
    return id;
  }
}

// ── input, sensors, audio, system ────────────────────────────────────────

export interface TouchEvent {
  lens: number;
  pad: number;
  phase: keyof typeof TouchPhase;
  pos: number;
  tUs: number;
}
export interface GestureEvent {
  lens: number;
  kind: keyof typeof GestureKind;
  tUs: number;
}

export class InputApi extends Emitter<{
  touch: TouchEvent;
  gesture: GestureEvent;
}> {
  constructor(private readonly g: WispGlasses) {
    super();
  }

  /** Nothing is sent until this is called. Timing values of 0 keep the defaults. */
  configure(opts: {
    touch?: boolean;
    gestures?: boolean;
    tapMaxMs?: number;
    doubleGapMs?: number;
    longMs?: number;
  }) {
    return this.g.link.call(Input.config, {
      mask: (opts.touch ? 1 : 0) | (opts.gestures ? 2 : 0),
      tapMaxMs: opts.tapMaxMs ?? 0,
      doubleGapMs: opts.doubleGapMs ?? 0,
      longMs: opts.longMs ?? 0,
    });
  }

  /** @internal */
  dispatch(m: Incoming) {
    if (m.op === Input.touch.op) {
      const e = Input.touch.event!.decode(m.payload);
      const phase = keyOf(TouchPhase, e.phase);
      if (phase) this.emit('touch', { ...e, phase });
    } else if (m.op === Input.gesture.op) {
      const e = Input.gesture.event!.decode(m.payload);
      const kind = keyOf(GestureKind, e.kind);
      if (kind) this.emit('gesture', { ...e, kind });
    }
  }
}

export interface SensorBatch<S extends SensorName> {
  samples: SensorSample[S][];
  /** Glasses time of the first sample and spacing (µs). */
  t0Us: number;
  dtUs: number;
}

type SensorEvents = { [S in SensorName]: SensorBatch<S> };

export class SensorsApi extends Emitter<SensorEvents> {
  constructor(private readonly g: WispGlasses) {
    super();
  }

  /**
   * Starts a sensor. `rateHz 0` = on change; samples arrive every `batchMs`.
   * Resolves with a function that unsubscribes.
   */
  async subscribe(
    sensor: SensorName,
    opts: { rateHz?: number; batchMs?: number } = {},
  ) {
    await this.g.link.call(Sensor.subscribe, {
      sensor: SensorId[sensor],
      rateHz: opts.rateHz ?? 0,
      batchMs: opts.batchMs ?? 0,
    });
    return () => this.unsubscribe(sensor);
  }

  async unsubscribe(sensor: SensorName) {
    await this.g.link.call(Sensor.unsubscribe, { sensor: SensorId[sensor] });
  }

  async read<S extends SensorName>(sensor: S): Promise<SensorSample[S]> {
    const r = await this.g.link.call(Sensor.read, { sensor: SensorId[sensor] });
    const [sample] = decodeSamples(sensor, r.sample, 1);
    if (!sample) throw new Error(`READ ${sensor}: short sample`);
    return sample;
  }

  /** @internal */
  dispatch(m: Incoming) {
    if (m.op !== Sensor.data.op) return;
    const e = Sensor.data.event!.decode(m.payload);
    const name = sensorName(e.sensor);
    if (!name) return;
    this.emit(name, {
      samples: decodeSamples(name, e.samples, e.count),
      t0Us: e.t0Us,
      dtUs: e.dtUs,
    } as never);
  }
}

export interface MicChunk {
  seq: number;
  tUs: number;
  data: Uint8Array;
}

export class AudioApi extends Emitter<{ mic: MicChunk }> {
  constructor(private readonly g: WispGlasses) {
    super();
  }

  startMic(
    opts: {
      codec?: keyof typeof MicCodec;
      rateHz?: number;
      /** Bit mask of microphones. Default 1. */
      channels?: number;
      frameMs?: number;
      lc3Bytes?: number;
    } = {},
  ) {
    return this.g.link.call(Audio.micStart, {
      codec: MicCodec[opts.codec ?? 'pcm16'],
      rateHz: opts.rateHz ?? 16000,
      channels: opts.channels ?? 1,
      frameMs: opts.frameMs ?? 10,
      lc3Bytes: opts.lc3Bytes ?? 0,
    });
  }

  stopMic() {
    return this.g.link.call(Audio.micStop);
  }

  /** Buzzer pattern; `freqHz 0` is a pause. */
  tone(tones: { freqHz: number; durationMs: number; duty?: number }[]) {
    return this.g.link.call(Audio.tone, {
      steps: tones.map((t) => ({ ...t, duty: t.duty ?? 50 })),
    });
  }

  /** @internal */
  dispatch(m: Incoming) {
    if (m.op === Audio.micData.op)
      this.emit('mic', Audio.micData.event!.decode(m.payload));
  }
}

export interface LogLine {
  level: number;
  tUs: number;
  text: string;
}

export class SystemApi extends Emitter<{ log: LogLine }> {
  constructor(private readonly g: WispGlasses) {
    super();
  }

  info() {
    return this.g.link.call(System.info);
  }
  stats() {
    return this.g.link.call(System.stats);
  }
  /** A level 0–255, or `'auto'`. */
  brightness(level: number | 'auto') {
    return this.g.link.call(
      System.brightness,
      level === 'auto' ? { mode: 1, level: 0 } : { mode: 0, level },
    );
  }
  displayPower(opts: {
    on: boolean;
    offWhenUnworn?: boolean;
    idleOffMs?: number;
  }) {
    return this.g.link.call(System.displayPower, {
      on: opts.on ? 1 : 0,
      offWhenUnworn: opts.offWhenUnworn ? 1 : 0,
      idleOffMs: opts.idleOffMs ?? 0,
    });
  }
  linkProfile(profile: keyof typeof LinkProfile) {
    return this.g.link.call(System.linkProfile, {
      profile: LinkProfile[profile],
    });
  }
  reboot(mode: 'normal' | 'rescue' = 'normal') {
    return this.g.link.call(System.reboot, { mode: mode === 'rescue' ? 1 : 0 });
  }
  /** 0 off … 4 debug; lines arrive as `log` events. */
  setLogLevel(level: number) {
    return this.g.link.call(System.logConfig, { level });
  }

  /** @internal */
  dispatch(m: Incoming) {
    if (m.op === System.log.op)
      this.emit('log', System.log.event!.decode(m.payload));
  }
}

// ── the glasses ──────────────────────────────────────────────────────────

/** One session with one temple (or, with `route`, both through one). */
export class WispGlasses extends Emitter<{
  animationDone: { slot: number };
  close: Error | undefined;
}> {
  readonly layers = new Layers(this);
  readonly resources: Resources;
  readonly input = new InputApi(this);
  readonly sensors = new SensorsApi(this);
  readonly audio = new AudioApi(this);
  readonly system = new SystemApi(this);
  /** Maps phone time to glasses time; feed it with `syncClock`. */
  readonly clock = new ClockEstimator();

  private constructor(
    readonly link: WispLink,
    readonly capabilities: Capabilities,
    sha256?: Sha256,
  ) {
    super();
    this.resources = new Resources(this, sha256);
    link.events.on('event', (m) => this.dispatch(m));
    link.events.on('close', (err) => this.emit('close', err));
  }

  /** Opens a session: `HELLO`, peer limits, keepalive. */
  static async connect(
    transport: Transport,
    opts: ConnectOptions,
  ): Promise<WispGlasses> {
    const link = new WispLink(transport, opts);
    try {
      const hello = await link.call(Session.hello, {
        protoMajor: PROTOCOL_VERSION.major,
        protoMinor: PROTOCOL_VERSION.minor,
        maxFrame: link.maxFrame,
        rxWindow: link.rxWindow,
        appId: opts.appId,
        clientName: opts.clientName ?? '',
      });
      if (hello.protoMajor !== PROTOCOL_VERSION.major)
        throw new Error(
          `glasses speak protocol ${hello.protoMajor}.x, SDK ${PROTOCOL_VERSION.major}.x`,
        );
      link.setPeerLimits({
        maxFrame: hello.maxFrame,
        rxWindow: hello.rxWindow,
      });
      const g = new WispGlasses(link, toCapabilities(hello), opts.sha256);
      if (opts.keepalive !== false)
        link.startKeepalive(
          Math.max(250, Math.floor(hello.sessionTimeoutMs / 3)),
        );
      return g;
    } catch (err) {
      await link.close();
      throw err;
    }
  }

  /**
   * Shows everything drawn since the last commit, tear-free. With `wait`
   * (default) resolves when the frame is on the panel, which paces frames.
   */
  async commit(opts: { wait?: boolean } = {}) {
    if (opts.wait === false) {
      this.link.notify(Display.commit, { flags: 0 });
      return undefined;
    }
    return this.link.call(Display.commit, { flags: 0 });
  }

  stopAnimation(slot: number) {
    this.link.notify(Display.animStop, { slot });
  }

  /** Runs `rounds` `TIME_SYNC` exchanges and feeds `clock`. */
  async syncClock(rounds = 5) {
    for (let i = 0; i < rounds; i++) {
      const sent = Date.now();
      const r = await this.link.call(Session.timeSync, { phoneMs: sent });
      this.clock.addSample(sent, Date.now(), r.glassUs);
    }
    return this.clock;
  }

  /** Ends the session (`BYE`): the glasses stop everything it started. */
  async close() {
    if (this.link.isClosed) return;
    try {
      this.link.notify(Session.bye);
      await this.link.flush();
    } finally {
      await this.link.close();
    }
  }

  private dispatch(m: Incoming) {
    try {
      this.route(m);
    } catch (err) {
      if (!(err instanceof PayloadError)) throw err; // a malformed event is dropped
    }
  }

  private route(m: Incoming) {
    switch (m.svc) {
      case Service.input:
        return this.input.dispatch(m);
      case Service.sensor:
        return this.sensors.dispatch(m);
      case Service.audio:
        return this.audio.dispatch(m);
      case Service.system:
        return this.system.dispatch(m);
      case Service.display:
        if (m.op === Display.animPlay.op)
          this.emit('animationDone', Display.animPlay.event!.decode(m.payload));
    }
  }
}
