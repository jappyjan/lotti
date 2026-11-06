interface Sample {
  /** Phone time halfway between send and receive (ms). */
  phoneMs: number;
  glassUs: number;
  rttMs: number;
}

/**
 * Maps phone time (ms, `Date.now()`) to glasses time (µs) from `TIME_SYNC`
 * round trips: keeps the samples with the shortest round trips and fits
 * `glass = offset + rate · phone` by least squares, which gives the drift.
 */
export class ClockEstimator {
  private samples: Sample[] = [];

  constructor(private readonly maxSamples = 32) {}

  addSample(sentMs: number, receivedMs: number, glassUs: number) {
    const rttMs = Math.max(0, receivedMs - sentMs);
    this.samples.push({ phoneMs: (sentMs + receivedMs) / 2, glassUs, rttMs });
    if (this.samples.length > this.maxSamples) this.samples.shift();
  }

  get sampleCount(): number {
    return this.samples.length;
  }

  private fit(): { phone0: number; glass0: number; rate: number } | undefined {
    if (!this.samples.length) return undefined;
    const minRtt = Math.min(...this.samples.map((s) => s.rttMs));
    const good = this.samples.filter((s) => s.rttMs <= minRtt * 1.5 + 2);
    const phone0 = good.reduce((a, s) => a + s.phoneMs, 0) / good.length;
    const glass0 = good.reduce((a, s) => a + s.glassUs, 0) / good.length;
    let sxx = 0;
    let sxy = 0;
    for (const s of good) {
      const dx = s.phoneMs - phone0;
      sxx += dx * dx;
      sxy += dx * (s.glassUs - glass0);
    }
    // Under a second of spread says nothing about drift.
    const spread =
      Math.max(...good.map((s) => s.phoneMs)) -
      Math.min(...good.map((s) => s.phoneMs));
    const rate = spread >= 1000 && sxx > 0 ? sxy / sxx : 1000;
    return { phone0, glass0, rate };
  }

  /** Glasses clock drift relative to the phone, in ppm (0 until estimable). */
  get driftPpm(): number {
    const f = this.fit();
    return f ? (f.rate / 1000 - 1) * 1e6 : 0;
  }

  /** Best estimate of the glasses clock (µs) at phone time `phoneMs`. */
  toGlassUs(phoneMs: number): number {
    const f = this.fit();
    if (!f) throw new Error('no TIME_SYNC samples yet');
    return f.glass0 + (phoneMs - f.phone0) * f.rate;
  }

  /** Phone time (ms) at which the glasses clock reads `glassUs`. */
  toPhoneMs(glassUs: number): number {
    const f = this.fit();
    if (!f) throw new Error('no TIME_SYNC samples yet');
    return f.phone0 + (glassUs - f.glass0) / f.rate;
  }
}
