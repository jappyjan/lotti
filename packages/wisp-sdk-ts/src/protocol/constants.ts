import { ByteReader } from './bytes.ts';

/** `HELLO` capability bits. */
export const Cap = {
  display: 0,
  animation: 1,
  tween: 2,
  text: 3,
  persist: 4,
  touchRaw: 5,
  gestures: 6,
  imu: 7,
  magnetometer: 8,
  ambientLight: 9,
  wear: 10,
  micPcm: 11,
  micLc3: 12,
  buzzer: 13,
  update: 14,
  l2cap: 15,
  forward: 16,
  rle4: 17,
  lz4: 18,
  deltaFrames: 19,
} as const;
export type CapName = keyof typeof Cap;

export const Codec = { raw4: 0, rle4: 1, lz4: 2, lz4Rle: 3 } as const;
export type CodecId = (typeof Codec)[keyof typeof Codec];

export const ResourceType = {
  image: 1,
  animation: 2,
  font: 3,
  blob: 4,
} as const;

/** `PUT_BEGIN` response status. */
export const PutStatus = { sendData: 0, exists: 1 } as const;

export const LayerFlag = { visible: 1 } as const;
export const Blend = { over: 0, max: 1, add: 2 } as const;
export const TweenProp = {
  x: 0,
  y: 1,
  alpha: 2,
  scrollX: 3,
  scrollY: 4,
} as const;
export const Easing = { linear: 0, in: 1, out: 2, inOut: 3 } as const;

export const TouchPhase = { down: 0, move: 1, up: 2 } as const;
export const GestureKind = {
  tap: 1,
  doubleTap: 2,
  longStart: 3,
  longEnd: 4,
  swipeForward: 5,
  swipeBack: 6,
} as const;

export const LinkProfile = { idle: 0, interactive: 1, bulk: 2 } as const;
export const MicCodec = { pcm16: 0, lc3: 1 } as const;

export const SensorId = {
  accelerometer: 1,
  gyroscope: 2,
  magnetometer: 3,
  ambientLight: 4,
  wear: 5,
  battery: 6,
  temperature: 7,
} as const;
export type SensorName = keyof typeof SensorId;

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}
export interface SensorSample {
  /** mg */
  accelerometer: Vec3;
  /** 0.1 °/s */
  gyroscope: Vec3;
  /** 0.1 µT */
  magnetometer: Vec3;
  ambientLight: { lux: number };
  wear: { worn: boolean };
  battery: { soc: number; mv: number; charging: boolean };
  temperature: { centiC: number };
}

const SAMPLE_SIZE: Record<SensorName, number> = {
  accelerometer: 6,
  gyroscope: 6,
  magnetometer: 6,
  ambientLight: 4,
  wear: 1,
  battery: 4,
  temperature: 2,
};

export function sensorName(id: number): SensorName | undefined {
  return (Object.keys(SensorId) as SensorName[]).find(
    (k) => SensorId[k] === id,
  );
}

/** Splits a `DATA` (or `READ`) sample block into typed samples. */
export function decodeSamples<S extends SensorName>(
  sensor: S,
  bytes: Uint8Array,
  count = Math.floor(bytes.length / SAMPLE_SIZE[sensor]),
): SensorSample[S][] {
  const r = new ByteReader(bytes);
  const out: SensorSample[S][] = [];
  for (let i = 0; i < count && r.remaining >= SAMPLE_SIZE[sensor]; i++) {
    let v: SensorSample[SensorName];
    switch (sensor as SensorName) {
      case 'accelerometer':
      case 'gyroscope':
      case 'magnetometer':
        v = { x: r.i16()!, y: r.i16()!, z: r.i16()! };
        break;
      case 'ambientLight':
        v = { lux: r.u32()! };
        break;
      case 'wear':
        v = { worn: r.u8()! !== 0 };
        break;
      case 'battery':
        v = { soc: r.u8()!, mv: r.u16()!, charging: r.u8()! !== 0 };
        break;
      case 'temperature':
        v = { centiC: r.i16()! };
        break;
    }
    out.push(v as SensorSample[S]);
  }
  return out;
}
