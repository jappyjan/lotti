import { ByteReader, ByteWriter } from './bytes.ts';
import {
  empty,
  struct,
  type Fields,
  type Struct,
  type Values,
} from './struct.ts';

export const Service = {
  session: 0x00,
  system: 0x01,
  display: 0x02,
  resource: 0x03,
  input: 0x04,
  sensor: 0x05,
  audio: 0x06,
  update: 0x07,
} as const;

export const MFlags = { response: 1, error: 2, event: 4 } as const;

export const MESSAGE_HEADER_SIZE = 4;

export interface MessageHeader {
  op: number;
  mflags: number;
  /** Correlation id; 0 on a request means "no response wanted". */
  req: number;
}

export interface MessageBody extends MessageHeader {
  payload: Uint8Array;
}

export function encodeBody(h: MessageHeader, payload: Uint8Array): Uint8Array {
  return new ByteWriter(MESSAGE_HEADER_SIZE + payload.length)
    .u8(h.op)
    .u8(h.mflags)
    .u16(h.req)
    .bytes(payload)
    .finish();
}

/** Returns `undefined` for a body shorter than the message header. */
export function decodeBody(body: Uint8Array): MessageBody | undefined {
  if (body.length < MESSAGE_HEADER_SIZE) return undefined;
  const r = new ByteReader(body);
  return { op: r.u8()!, mflags: r.u8()!, req: r.u16()!, payload: r.rest() };
}

export const ErrorCode = {
  unsupportedOp: 1,
  badPayload: 2,
  noSuchId: 3,
  outOfMemory: 4,
  busy: 5,
  hashMismatch: 6,
  notAllowed: 7,
  exists: 8,
} as const;

export const ErrorPayload = struct({ code: 'u16', message: 'utf8' });

export interface MessageDef<
  Req extends Fields = Fields,
  Res extends Fields = Fields,
  Ev extends Fields = Fields,
> {
  readonly svc: number;
  readonly op: number;
  /** Name as in the spec, e.g. `HELLO`. */
  readonly name: string;
  readonly request?: Struct<Req>;
  readonly response?: Struct<Res>;
  readonly event?: Struct<Ev>;
}

export type RequestOf<M> =
  M extends MessageDef<infer R, Fields, Fields> ? Values<R> : never;
export type ResponseOf<M> =
  M extends MessageDef<Fields, infer R, Fields> ? Values<R> : never;
export type EventOf<M> =
  M extends MessageDef<Fields, Fields, infer E> ? Values<E> : never;

function def<
  Req extends Fields = Record<never, never>,
  Res extends Fields = Record<never, never>,
  Ev extends Fields = Record<never, never>,
>(
  svc: number,
  op: number,
  name: string,
  parts: { request?: Struct<Req>; response?: Struct<Res>; event?: Struct<Ev> },
): MessageDef<Req, Res, Ev> {
  return { svc, op, name, ...parts };
}

const s = Service;

export const Session = {
  hello: def(s.session, 1, 'HELLO', {
    request: struct({
      protoMajor: 'u8',
      protoMinor: 'u8',
      maxFrame: 'u16',
      rxWindow: 'u32',
      appId: 'str16',
      clientName: 'str16',
    }),
    response: struct(
      {
        protoMajor: 'u8',
        protoMinor: 'u8',
        maxFrame: 'u16',
        rxWindow: 'u32',
        fwName: 'str16',
        fwVersion: 'str16',
        lens: 'u8',
        caps: 'u32',
        canvasW: 'u16',
        canvasH: 'u16',
        bpp: 'u8',
        maxLayers: 'u8',
        resBytes: 'u32',
        persistBytes: 'u32',
        sessionTimeoutMs: 'u32',
        l2capPsm: 'u16',
      },
      { sessionTimeoutMs: 10_000 },
    ),
  }),
  credit: def(s.session, 2, 'CREDIT', { request: struct({ ackSeq: 'u16' }) }),
  resync: def(s.session, 3, 'RESYNC', {
    request: struct({ lastGoodSeq: 'u16' }),
  }),
  ping: def(s.session, 4, 'PING', {
    request: struct({ token: 'u32' }),
    response: struct({ token: 'u32' }),
  }),
  timeSync: def(s.session, 5, 'TIME_SYNC', {
    request: struct({ phoneMs: 'u64' }),
    response: struct({ phoneMs: 'u64', glassUs: 'u64' }),
  }),
  bye: def(s.session, 6, 'BYE', { request: empty }),
};

export const System = {
  info: def(s.system, 1, 'INFO', {
    request: empty,
    response: struct({
      hwRev: 'str16',
      serial: 'str16',
      panel: 'u8',
      powerBoard: 'u8',
      lens: 'u8',
      bootReason: 'u8',
      bootCount: 'u32',
      uptimeMs: 'u32',
      build: 'str16',
    }),
  }),
  brightness: def(s.system, 2, 'BRIGHTNESS', {
    request: struct({ mode: 'u8', level: 'u8' }),
    response: empty,
  }),
  displayPower: def(s.system, 3, 'DISPLAY_POWER', {
    request: struct({ on: 'u8', offWhenUnworn: 'u8', idleOffMs: 'u32' }),
    response: empty,
  }),
  linkProfile: def(s.system, 4, 'LINK_PROFILE', {
    request: struct({ profile: 'u8' }),
    response: empty,
  }),
  reboot: def(s.system, 5, 'REBOOT', {
    request: struct({ mode: 'u8' }),
    response: empty,
  }),
  logConfig: def(s.system, 6, 'LOG_CONFIG', {
    request: struct({ level: 'u8' }),
    response: empty,
  }),
  log: def(s.system, 7, 'LOG', {
    event: struct({ level: 'u8', tUs: 'u32', text: 'utf8' }),
  }),
  stats: def(s.system, 8, 'STATS', {
    request: empty,
    response: struct({
      heapFree: 'u32',
      heapMin: 'u32',
      cpuPct: 'u8',
      frames: 'u32',
      rxBytes: 'u32',
      txBytes: 'u32',
      resyncs: 'u16',
    }),
  }),
};

export const Display = {
  layerSet: def(s.display, 1, 'LAYER_SET', {
    request: struct({
      layer: 'u8',
      z: 'u8',
      flags: 'u8',
      alpha: 'u8',
      x: 'i16',
      y: 'i16',
      w: 'u16',
      h: 'u16',
      contentW: 'u16',
      contentH: 'u16',
      scrollX: 'i16',
      scrollY: 'i16',
    }),
  }),
  layerDel: def(s.display, 2, 'LAYER_DEL', {
    request: struct({ layer: 'u8' }),
  }),
  fill: def(s.display, 3, 'FILL', {
    request: struct({
      layer: 'u8',
      value: 'u8',
      x: 'i16',
      y: 'i16',
      w: 'u16',
      h: 'u16',
    }),
  }),
  blit: def(s.display, 4, 'BLIT', {
    request: struct({
      layer: 'u8',
      flags: 'u8',
      x: 'i16',
      y: 'i16',
      res: 'u16',
      srcX: 'u16',
      srcY: 'u16',
      w: 'u16',
      h: 'u16',
    }),
  }),
  image: def(s.display, 5, 'IMAGE', {
    request: struct({
      layer: 'u8',
      codec: 'u8',
      x: 'i16',
      y: 'i16',
      w: 'u16',
      h: 'u16',
      data: 'bytes',
    }),
  }),
  text: def(s.display, 6, 'TEXT', {
    request: struct({
      layer: 'u8',
      value: 'u8',
      x: 'i16',
      y: 'i16',
      font: 'u16',
      maxW: 'u16',
      lineH: 'u16',
      text: 'utf8',
    }),
    response: struct({ w: 'u16', h: 'u16', charsDrawn: 'u16' }),
  }),
  scroll: def(s.display, 7, 'SCROLL', {
    request: struct({ layer: 'u8', dx: 'i16', dy: 'i16', fill: 'u8' }),
  }),
  commit: def(s.display, 8, 'COMMIT', {
    request: struct({ flags: 'u8' }),
    response: struct({ frame: 'u32', glassUs: 'u64' }),
  }),
  animPlay: def(s.display, 9, 'ANIM_PLAY', {
    request: struct({
      slot: 'u8',
      layer: 'u8',
      x: 'i16',
      y: 'i16',
      res: 'u16',
      loops: 'u16',
      flags: 'u8',
    }),
    /** `ANIM_DONE` */
    event: struct({ slot: 'u8' }),
  }),
  animStop: def(s.display, 10, 'ANIM_STOP', {
    request: struct({ slot: 'u8' }),
  }),
  tween: def(s.display, 11, 'TWEEN', {
    request: struct({
      layer: 'u8',
      prop: 'u8',
      easing: 'u8',
      to: 'i16',
      durationMs: 'u16',
    }),
  }),
  clearAll: def(s.display, 12, 'CLEAR_ALL', { request: empty }),
};

const resourceEntry = {
  res: 'u16',
  type: 'u8',
  flags: 'u8',
  size: 'u32',
  hash: 'hash16',
} as const;

export const Resource = {
  putBegin: def(s.resource, 1, 'PUT_BEGIN', {
    request: struct({
      res: 'u16',
      type: 'u8',
      codec: 'u8',
      flags: 'u8',
      size: 'u32',
      hash: 'hash16',
    }),
    response: struct({ status: 'u8' }),
  }),
  putData: def(s.resource, 2, 'PUT_DATA', {
    request: struct({ res: 'u16', offset: 'u32', data: 'bytes' }),
  }),
  putEnd: def(s.resource, 3, 'PUT_END', {
    request: struct({ res: 'u16' }),
    response: empty,
  }),
  delete: def(s.resource, 4, 'DELETE', {
    request: struct({ res: 'u16' }),
    response: empty,
  }),
  list: def(s.resource, 5, 'LIST', {
    request: empty,
    response: struct({
      count: 'u16',
      entries: { count: 'count', item: resourceEntry },
    }),
  }),
};

export const Input = {
  config: def(s.input, 1, 'CONFIG', {
    request: struct({
      mask: 'u8',
      tapMaxMs: 'u16',
      doubleGapMs: 'u16',
      longMs: 'u16',
    }),
  }),
  touch: def(s.input, 2, 'TOUCH', {
    event: struct({
      lens: 'u8',
      pad: 'u8',
      phase: 'u8',
      pos: 'u16',
      tUs: 'u32',
    }),
  }),
  gesture: def(s.input, 3, 'GESTURE', {
    event: struct({ lens: 'u8', kind: 'u8', tUs: 'u32' }),
  }),
};

export const Sensor = {
  subscribe: def(s.sensor, 1, 'SUBSCRIBE', {
    request: struct({ sensor: 'u8', rateHz: 'u16', batchMs: 'u16' }),
  }),
  unsubscribe: def(s.sensor, 2, 'UNSUBSCRIBE', {
    request: struct({ sensor: 'u8' }),
  }),
  data: def(s.sensor, 3, 'DATA', {
    event: struct({
      sensor: 'u8',
      count: 'u8',
      t0Us: 'u32',
      dtUs: 'u32',
      samples: 'bytes',
    }),
  }),
  read: def(s.sensor, 4, 'READ', {
    request: struct({ sensor: 'u8' }),
    /** Decode `sample` with `decodeSamples`. */
    response: struct({ sample: 'bytes' }),
  }),
};

export const Audio = {
  micStart: def(s.audio, 1, 'MIC_START', {
    request: struct({
      codec: 'u8',
      rateHz: 'u16',
      channels: 'u8',
      frameMs: 'u8',
      lc3Bytes: 'u8',
    }),
  }),
  micStop: def(s.audio, 2, 'MIC_STOP', { request: empty }),
  micData: def(s.audio, 3, 'MIC_DATA', {
    event: struct({ seq: 'u16', tUs: 'u32', data: 'bytes' }),
  }),
  tone: def(s.audio, 4, 'TONE', {
    request: struct({
      count: 'u8',
      steps: {
        count: 'count',
        item: { freqHz: 'u16', durationMs: 'u16', duty: 'u8' },
      },
    }),
  }),
};

export const Update = {
  begin: def(s.update, 1, 'BEGIN', {
    request: struct({ size: 'u32', sha256: 'sha256', version: 'str16' }),
    response: empty,
  }),
  data: def(s.update, 2, 'DATA', {
    request: struct({ offset: 'u32', data: 'bytes' }),
  }),
  end: def(s.update, 3, 'END', { request: empty, response: empty }),
  apply: def(s.update, 4, 'APPLY', { request: empty, response: empty }),
  status: def(s.update, 5, 'STATUS', {
    request: empty,
    response: struct({
      state: 'u8',
      confirmed: 'u8',
      version: 'str16',
      rescuePresent: 'u8',
    }),
  }),
};

export const Messages = {
  session: Session,
  system: System,
  display: Display,
  resource: Resource,
  input: Input,
  sensor: Sensor,
  audio: Audio,
  update: Update,
};

const BY_ID = new Map<number, MessageDef>();
for (const group of Object.values(Messages))
  for (const m of Object.values(group) as MessageDef[])
    BY_ID.set((m.svc << 8) | m.op, m);

export function findMessage(svc: number, op: number): MessageDef | undefined {
  return BY_ID.get((svc << 8) | op);
}

/** The payload layout of a body with these flags (`ERROR` fits any op). */
export function payloadStruct(
  m: MessageDef | undefined,
  mflags: number,
): Struct | undefined {
  if (mflags & MFlags.error) return ErrorPayload as unknown as Struct;
  if (!m) return undefined;
  if (mflags & MFlags.event) return m.event;
  if (mflags & MFlags.response) return m.response;
  return m.request;
}
