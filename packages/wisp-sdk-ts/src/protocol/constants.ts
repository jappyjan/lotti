import { PayloadError, struct } from './struct.ts';

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

const vec3 = struct({ x: 'i16', y: 'i16', z: 'i16' });
const SAMPLE = {
  accelerometer: vec3,
  gyroscope: vec3,
  magnetometer: vec3,
  ambientLight: struct({ lux: 'u32' }),
  wear: struct({ worn: 'u8' }),
  battery: struct({ soc: 'u8', mv: 'u16', charging: 'u8' }),
  temperature: struct({ centiC: 'i16' }),
};

export function sensorName(id: number): SensorName | undefined {
  return (Object.keys(SensorId) as SensorName[]).find(
    (k) => SensorId[k] === id,
  );
}

/**
 * Splits a `DATA` (or, with `count` 1, a `READ`) sample block into typed
 * samples. `count` is authoritative: each sample is (length / count) bytes,
 * so samples may carry fields this SDK doesn't know yet (skipped) or lack
 * some (0). Throws `PayloadError` when the length doesn't divide.
 */
export function decodeSamples<S extends SensorName>(
  sensor: S,
  bytes: Uint8Array,
  count = 1,
): SensorSample[S][] {
  if (count ? bytes.length % count : bytes.length)
    throw new PayloadError(
      `${bytes.length} bytes don't split into ${count} samples`,
    );
  const stride = count ? bytes.length / count : 0;
  const out: SensorSample[S][] = [];
  for (let i = 0; i < count; i++) {
    const f = SAMPLE[sensor as SensorName].decode(
      bytes.subarray(i * stride, (i + 1) * stride),
    ) as Record<string, number>;
    let v: SensorSample[SensorName];
    switch (sensor as SensorName) {
      case 'wear':
        v = { worn: f.worn !== 0 };
        break;
      case 'battery':
        v = { soc: f.soc!, mv: f.mv!, charging: f.charging !== 0 };
        break;
      default:
        v = f as unknown as SensorSample[SensorName];
    }
    out.push(v as SensorSample[S]);
  }
  return out;
}
