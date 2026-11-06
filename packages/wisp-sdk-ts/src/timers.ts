// The core targets plain ES2022, which has no timer types; every JS runtime
// we support has these globals.
interface Timers {
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}
const g = globalThis as unknown as Timers;

export type TimerHandle = unknown;
export const setTimer = (fn: () => void, ms: number): TimerHandle =>
  g.setTimeout(fn, ms);
export const clearTimer = (h: TimerHandle) => g.clearTimeout(h);
