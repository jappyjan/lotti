export interface Logger {
  info(msg: string, extra?: unknown): void;
  warn(msg: string, extra?: unknown): void;
  error(msg: string, extra?: unknown): void;
}

export const consoleLogger: Logger = {
  info: (m, e) => console.log(`[brain] ${m}`, ...(e === undefined ? [] : [e])),
  warn: (m, e) =>
    console.warn(`[brain] WARN ${m}`, ...(e === undefined ? [] : [e])),
  error: (m, e) =>
    console.error(`[brain] ERROR ${m}`, ...(e === undefined ? [] : [e])),
};

export const silentLogger: Logger = { info() {}, warn() {}, error() {} };
