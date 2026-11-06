/** Deterministic PRNG (mulberry32) so randomized tests are reproducible. */
export function rng(seed: number) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const int = (lo: number, hi: number) =>
    lo + Math.floor(next() * (hi - lo + 1));
  const bytes = (n: number) =>
    Uint8Array.from({ length: n }, () => int(0, 255));
  return { next, int, bytes };
}
