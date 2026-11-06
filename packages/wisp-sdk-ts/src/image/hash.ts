/** Returns the SHA-256 digest (32 bytes) of `data`. */
export type Sha256 = (data: Uint8Array) => Promise<Uint8Array> | Uint8Array;

interface SubtleLike {
  digest(algo: string, data: Uint8Array): Promise<ArrayBuffer>;
}

let injected: Sha256 | undefined;

/**
 * Sets the SHA-256 used for resource hashes. Needed where WebCrypto
 * (`crypto.subtle`) is missing, e.g. React Native without a polyfill.
 */
export function setSha256(fn: Sha256 | undefined) {
  injected = fn;
}

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  if (injected) return injected(data);
  const subtle = (globalThis as { crypto?: { subtle?: SubtleLike } }).crypto
    ?.subtle;
  if (!subtle)
    throw new Error(
      'no WebCrypto here: pass a SHA-256 implementation to setSha256()',
    );
  return new Uint8Array(await subtle.digest('SHA-256', data));
}

/** `hash16`: the first 16 bytes of SHA-256. */
export async function resourceHash(
  data: Uint8Array,
  fn?: Sha256,
): Promise<Uint8Array> {
  const digest = fn ? await fn(data) : await sha256(data);
  return digest.slice(0, 16);
}
