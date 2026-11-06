import { ErrorCode } from '../protocol/messages.ts';

const NAMES = Object.fromEntries(
  Object.entries(ErrorCode).map(([k, v]) => [v, k]),
);

/** An `ERROR` response from the glasses. */
export class WispError extends Error {
  override name = 'WispError';
  constructor(
    readonly code: number,
    readonly detail: string,
    readonly op?: string,
  ) {
    super(
      `${op ? `${op}: ` : ''}${NAMES[code] ?? `error ${code}`}${detail ? ` (${detail})` : ''}`,
    );
  }
}

export class WispTimeoutError extends Error {
  override name = 'WispTimeoutError';
}

export class LinkClosedError extends Error {
  override name = 'LinkClosedError';
  constructor(readonly reason?: Error) {
    super(reason ? `link closed: ${reason.message}` : 'link closed');
  }
}
